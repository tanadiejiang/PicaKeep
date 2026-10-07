/// 统一本地封面缓存（plan/12）。
///
/// ## 为什么需要它
///
/// 在这之前，本地封面在这一处落盘、那一处落盘，谁都不是"唯一真相"：
///
/// - `LocalLibraryManager._localCacheRoot()` 用 `getApplicationSupportDirectory()`，
///   而应用数据可能被 `dataPathOverride` 切到别处（测试、桌面自定义数据目录），
///   两者**不保证同一目录**；
/// - `ArchiveReadingService._archiveCoverCacheDir()` 默认落在
///   `Directory.systemTemp`（Android 上是 `<pkg>/cache`），**不是应用数据目录**；
/// - `CoverThumbnailCache.thumbnailPathForCover()` 直接把 `cover_thumb_720.png`
///   写在**原封面旁边** —— 原封面在用户下载目录时，就往用户目录里写文件；
/// - `__no_cover__` 这类"永久失败标记"一旦落下就不再重试。
///
/// 本模块把这些收敛成**一个写入位置 + 一份版本化索引 + 一套可重试规则**。
///
/// ## 契约（改这里之前先读）
///
/// 1. **唯一写入位置**：`<App.dataPath>/local_library_cache/covers`。
///    下载目录、压缩包、单图**只作为来源**，永不写入。
/// 2. **条目键**：`sourceId::originalId::<源相对标识>`，由 [entryKeyFor] 生成。
///    必须能区分"同一作品 id 出现在多个下载根"的情况，**不得只用标题或裸 id**。
/// 3. **指纹**：源路径 + 长度 + 修改时间（[fingerprintFor]）。指纹变了要生成
///    新缓存文件，且**旧文件要被清掉**，否则会一直显示旧图。
/// 4. **原子写入**：先写 `<name>.part` 再 rename；中断只会留下 `.part`，
///    由 [sweepPartFiles] 在下次启动清理。
/// 5. **读侧自愈**：索引指向的文件不存在 → 视为无缓存并**顺手修索引**，
///    绝不把"索引说有、磁盘说没有"这种状态留给上层。
/// 6. **失败不永久化**：失败只记 [negativeTtl] 范围内的短期负缓存；
///    过期后照常重试。这是对 `__no_cover__` 永久短路的替换。
library;

import 'dart:convert';
import 'dart:io';
import 'image_pipeline/derived_image_store.dart';
import 'image_pipeline/image_disk_quota.dart';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log.dart';

/// 索引格式版本。**改动索引结构时必须递增** —— 旧版本会被整体丢弃重建，
/// 而不是尝试兼容解析（缓存是可再生的，兼容旧格式不值得）。
const int kLocalCoverCacheIndexVersion = 1;

/// 负缓存有效期。
///
/// 选 10 分钟：足够挡住"一屏卡片反复重建"造成的重复探测，又足够短，
/// 让"用户刚补上封面文件/刚恢复权限"能在一次页面重进或手动刷新后生效。
/// **不得改成"永久"** —— 那正是本模块要消灭的行为。
const Duration kLocalCoverNegativeTtl = Duration(minutes: 10);
// Less than the page queue's 5s bounded retry interval.
const Duration kLocalCoverReadFailureTtl = Duration(seconds: 4);

/// 缓存根目录名（位于 `App.dataPath` 下）。
const String kLocalCoverCacheDirName = 'covers';

/// 索引文件名（位于 `local_library_cache` 下）。
const String kLocalCoverCacheIndexName = 'covers_index.json';

/// 一条缓存条目的索引记录。
class LocalCoverCacheEntry {
  const LocalCoverCacheEntry({
    required this.relativePath,
    required this.fingerprint,
    required this.updatedAt,
  });

  /// 相对缓存根的文件名（只存文件名，不存绝对路径 —— 应用数据目录整体搬家后
  /// 仍然有效，这是"迁移后封面还在"的关键）。
  final String relativePath;
  final String fingerprint;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'file': relativePath,
        'fp': fingerprint,
        'at': updatedAt.millisecondsSinceEpoch,
      };

  static LocalCoverCacheEntry? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final file = raw['file']?.toString().trim() ?? '';
    if (file.isEmpty) {
      return null;
    }
    final at = raw['at'];
    return LocalCoverCacheEntry(
      relativePath: file,
      fingerprint: raw['fp']?.toString() ?? '',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        at is int ? at : 0,
      ),
    );
  }
}

/// 统一本地封面缓存。
///
/// 全部是静态方法：它是**无状态的服务**，状态只有磁盘上的索引与文件。
/// 这样调用方（页面、扫描器、压缩包服务）不需要持有实例，也就不会出现
/// "两个实例各有一份索引"的分裂。
class LocalCoverCache {
  LocalCoverCache._();

  /// 索引内存副本（按根目录缓存，根目录变化时失效）。
  static Map<String, LocalCoverCacheEntry>? _entries;
  static Map<String, _NegativeRecord>? _negatives;
  static String? _loadedRoot;
  static Future<void>? _loading;
  static int _publicationGeneration = 0;

  static void invalidatePendingPublications() {
    _publicationGeneration++;
  }

  /// Only files registered as reproducible copies are deletion candidates.
  static Future<Set<String>> registeredReproduciblePaths() async {
    await _ensureLoaded();
    final root = rootDirectory().path;
    return {
      for (final entry in (_entries ?? <String, LocalCoverCacheEntry>{}).values)
        if (p.isWithin(root, p.join(root, entry.relativePath)))
          p.normalize(p.absolute(p.join(root, entry.relativePath)))
    };
  }

  /// 缓存根：`<App.dataPath>/local_library_cache/covers`。
  ///
  /// **延迟解析**：`App.dataPath` 在 `App.init` 之前不可读，所以这里绝不能在
  /// 静态初始化阶段调用（计划风险第 1 条）。
  static Directory rootDirectory() {
    return Directory(
      p.join(App.dataPath, 'local_library_cache', kLocalCoverCacheDirName),
    );
  }

  static File _indexFile() {
    return File(
      p.join(App.dataPath, 'local_library_cache', kLocalCoverCacheIndexName),
    );
  }

  /// 生成条目键。
  ///
  /// 三段：**来源** + **原始条目 id** + **源相对标识**。第三段让"同一作品 id
  /// 出现在两个下载根"可以区分（这是 [dedupeDownloadItemsById] 之外的另一层
  /// 保险：即便去重没生效，两边的封面也不会互相覆盖）。
  static String entryKeyFor({
    required String sourceId,
    required String originalId,
    required String sourceRelative,
  }) {
    final sid = sourceId.trim();
    final oid = originalId.trim();
    final rel = sourceRelative.trim().replaceAll('\\', '/');
    return '$sid::$oid::$rel';
  }

  /// 源指纹：源路径 + 长度 + 修改时间。
  ///
  /// **故意不读内容哈希**：封面可能是几 MB，每次进页面都全量哈希会把首屏拖垮。
  /// 长度 + mtime 足以捕捉"文件被替换/截断"这一我们要防的情况；
  /// 真出现"长度与 mtime 都没变但内容变了"的极端场景，用户可以手动刷新，
  /// 手动刷新会走 [invalidateAll] 全量重建。
  static String fingerprintFor(File file) {
    try {
      final stat = file.statSync();
      return '${file.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    } catch (_) {
      return '${file.path}|0|0';
    }
  }

  /// Use during preparation, never synchronously probe storage from a builder.
  static Future<String> fingerprintForAsync(File file) async {
    try {
      final stat = await file.stat();
      return '${file.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    } catch (_) {
      // The privileged channel may still be able to read this source.
      return '${file.path}|0|0';
    }
  }

  /// 读取（必要时加载）索引。
  static Future<void> _ensureLoaded() async {
    final root = rootDirectory().path;
    if (_loadedRoot == root && _entries != null && _negatives != null) {
      return;
    }
    // 并发去重：同一次页面加载会并发问很多条，不能各读一遍索引。
    final inflight = _loading;
    if (inflight != null && _loadedRoot == root) {
      await inflight;
      return;
    }
    late final Future<void> task;
    task = _load().whenComplete(() {
      if (identical(_loading, task)) {
        _loading = null;
      }
    });
    _loading = task;
    await task;
  }

  static Future<void> _load() async {
    final file = _indexFile();
    _loadedRoot = rootDirectory().path;
    _entries = <String, LocalCoverCacheEntry>{};
    _negatives = <String, _NegativeRecord>{};
    try {
      if (!await file.exists()) {
        return;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return;
      }
      if (decoded['version'] != kLocalCoverCacheIndexVersion) {
        // 版本不符：整体丢弃重建（缓存可再生，兼容旧格式不值得）。
        return;
      }
      final rawEntries = decoded['entries'];
      if (rawEntries is Map) {
        for (final e in rawEntries.entries) {
          final parsed = LocalCoverCacheEntry.fromJson(e.value);
          if (parsed != null) {
            _entries![e.key.toString()] = parsed;
          }
        }
      }
      final rawNegatives = decoded['missing'];
      if (rawNegatives is Map) {
        for (final e in rawNegatives.entries) {
          final rec = _NegativeRecord.fromJson(e.value);
          if (rec != null) {
            _negatives![e.key.toString()] = rec;
          }
        }
      }
    } catch (e) {
      // 索引坏了不影响使用：当作空索引，后续会自然重建。
      LogManager.addLog(
        LogLevel.warning,
        'LocalCoverCache',
        '索引解析失败，按空索引继续：$e',
      );
    }
    // **索引读完再接管旧缓存**：顺序反了会把旧条目当成"已登记"而跳过。
    // 放在这里（而不是让调用方记得调）是因为它必须"只跑一次且尽早跑"：
    // 漏跑的后果是旧封面在索引重建后全部消失。
    await _adoptLegacyCoversInternal();
    if (_adoptedDirty) {
      _adoptedDirty = false;
      await _save();
    }
  }

  static bool _adoptedDirty = false;

  static Future<void> _saveTail = Future<void>.value();
  static Future<void> _save() {
    final next = _saveTail.then((_) => _saveNow());
    _saveTail = next.catchError((Object _) {});
    return next;
  }

  static Future<void> _saveNow() async {
    final file = _indexFile();
    ImageDiskReservation? disk;
    File? temp;
    void Function()? releaseTemp;
    try {
      await file.parent.create(recursive: true);
      final payload = <String, Object?>{
        'version': kLocalCoverCacheIndexVersion,
        'entries': <String, Object?>{
          for (final e in (_entries ?? const {}).entries)
            e.key: e.value.toJson(),
        },
        'missing': <String, Object?>{
          for (final e in (_negatives ?? const {}).entries)
            e.key: e.value.toJson(),
        },
      };
      final encoded = utf8.encode(jsonEncode(payload));
      // The index is shared state and can grow with every cover. Give it its
      // own persistent ticket so its replacement peak is counted alongside
      // the cover body, while keeping the index itself protected from trim.
      disk = await ImageDiskQuota.shared
          .admitManagedIndex(file.path, maximumBytes: encoded.length);
      temp = File('${file.path}.part');
      releaseTemp = DerivedImageStore.protectTemporaryPath(temp.path);
      await temp.writeAsBytes(encoded, flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await temp.rename(file.path);
      temp = null;
      await disk.commit([file.path]);
    } catch (e) {
      LogManager.addLog(
        LogLevel.warning,
        'LocalCoverCache',
        '索引写入失败（不影响已生成的封面文件）：$e',
      );
    } finally {
      releaseTemp?.call();
      if (temp != null) {
        try {
          if (await temp.exists()) await temp.delete();
        } catch (_) {}
      }
      await disk?.abort();
    }
  }

  /// 查一条可用缓存。
  ///
  /// 返回绝对路径；不存在 / 指纹不符 / 文件已被删（**读侧自愈**）都返回 null。
  static Future<String?> lookup(
    String entryKey, {
    String? fingerprint,
  }) async {
    await _ensureLoaded();
    final entry = _entries?[entryKey];
    if (entry == null) {
      return null;
    }
    if (fingerprint != null &&
        fingerprint.isNotEmpty &&
        entry.fingerprint != fingerprint) {
      // 源变了：旧缓存作废（文件留着，等新的一次覆盖写时按名清理）。
      return null;
    }
    if (!await _isUsableFile(entry.relativePath)) {
      // 索引说有、磁盘说没有 —— 顺手修掉，别把不一致留给上层。
      _entries?.remove(entryKey);
      await _save();
      return null;
    }
    return p.join(rootDirectory().path, entry.relativePath);
  }

  static Future<bool> _isUsableFile(String relativePath) async {
    if (relativePath.isEmpty) {
      return false;
    }
    try {
      final file = File(p.join(rootDirectory().path, relativePath));
      if (!await file.exists()) {
        return false;
      }
      return await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// 写入一份封面字节，返回缓存文件绝对路径。
  ///
  /// [extension] 传来源的真实扩展名（含点）；不确定时传 null，
  /// 会退化成 `.img`（Flutter 按内容解码，不依赖扩展名）。
  static final Map<String, Future<String?>> _stores = {};
  static Future<String?> storeBytes({
    required String entryKey,
    required Uint8List bytes,
    required String fingerprint,
    String? extension,
  }) {
    final previous = _stores[entryKey];
    late final Future<String?> next;
    next = (previous ?? Future<String?>.value())
        .then((_) => _storeBytes(
              entryKey: entryKey,
              bytes: bytes,
              fingerprint: fingerprint,
              extension: extension,
            ))
        .whenComplete(() {
      if (identical(_stores[entryKey], next)) _stores.remove(entryKey);
    });
    _stores[entryKey] = next;
    return next;
  }

  static Future<String?> _storeBytes({
    required String entryKey,
    required Uint8List bytes,
    required String fingerprint,
    String? extension,
  }) async {
    if (bytes.isEmpty) {
      return null;
    }
    await _ensureLoaded();
    final root = rootDirectory();
    final ext = _normalizeExtension(extension);
    final name = '${_stableHash(entryKey)}$ext';
    final generation = _publicationGeneration;
    ImageDiskReservation? disk;
    File? staged;
    try {
      await root.create(recursive: true);
      final target = File(p.join(root.path, name));
      final temp = File('${target.path}.part');
      staged = temp;
      disk = await ImageDiskQuota.shared
          .admitPublication(target.path, maximumBytes: bytes.length);
      await temp.writeAsBytes(bytes, flush: true);
      if (generation != _publicationGeneration ||
          root.path != rootDirectory().path) {
        await temp.delete();
        return null;
      }
      if (await target.exists()) {
        await target.delete();
      }
      if (generation != _publicationGeneration ||
          root.path != rootDirectory().path) {
        await temp.delete();
        return null;
      }
      await temp.rename(target.path);
      staged = null;
      if (!await target.exists() || await target.length() == 0) {
        return null;
      }
      // 文件名只由条目键决定：指纹变化时是**原地覆盖**同一个文件，
      // 不会随刷新在磁盘上堆垃圾，也不会出现"新旧两份哪份才对"的问题。
      // （因此这里只在"文件名确实变了"时清理旧引用 —— 那条分支留给
      //  未来若改成"键含指纹"的实现，属防御性代码。）
      final previous = _entries?[entryKey];
      _entries?[entryKey] = LocalCoverCacheEntry(
        relativePath: name,
        fingerprint: fingerprint,
        updatedAt: DateTime.now(),
      );
      _negatives?.remove(entryKey);
      await _save();
      if (previous != null && previous.relativePath != name) {
        await _deleteQuietly(p.join(root.path, previous.relativePath));
      }
      await disk.commit([target.path]);
      return target.path;
    } catch (e) {
      LogManager.addLog(
        LogLevel.warning,
        'LocalCoverCache',
        '封面写入失败 entry=$entryKey：$e',
      );
      return null;
    } finally {
      if (staged != null) await _deleteQuietly(staged.path);
      await disk?.abort();
    }
  }

  /// 该条目当前是否处于"已知没有封面"的负缓存有效期内。
  static Future<bool> isKnownMissing(
    String entryKey, {
    String? fingerprint,
  }) async {
    await _ensureLoaded();
    final rec = _negatives?[entryKey];
    if (rec == null) {
      return false;
    }
    if (fingerprint != null &&
        fingerprint.isNotEmpty &&
        rec.fingerprint != fingerprint) {
      // 源变了，旧结论不再适用。
      return false;
    }
    final ttl =
        rec.transient ? kLocalCoverReadFailureTtl : kLocalCoverNegativeTtl;
    if (DateTime.now().difference(rec.at) >= ttl) {
      // 过期：**允许重试**（这正是取代 `__no_cover__` 永久短路的地方）。
      _negatives?.remove(entryKey);
      await _save();
      return false;
    }
    return true;
  }

  /// 记一条短期负缓存（取代 `__no_cover__`）。
  static Future<void> markMissing(
    String entryKey, {
    String fingerprint = '',
    bool transient = false,
  }) async {
    await _ensureLoaded();
    _negatives?[entryKey] = _NegativeRecord(
      fingerprint: fingerprint,
      at: DateTime.now(),
      transient: transient,
    );
    await _save();
  }

  /// 全量失效（用户手动刷新 / 下载根迁移 / Pixiv 归位之后调用）。
  ///
  /// **只清索引与负缓存，不删封面文件** —— 文件还在时下次 [lookup] 仍能命中，
  /// 只是"指纹与负缓存判定"重新走一遍。这样"源文件暂时读不到"不会演变成
  /// "封面被自己删光"。
  static Future<void> invalidateAll() async {
    await _ensureLoaded();
    _negatives?.clear();
    await _save();
  }

  /// Explicit rescan can discover external changes inside a directory without
  /// relying on the directory's mtime. Only discard index entries, not files.
  static Future<void> revalidateSources() async {
    await _ensureLoaded();
    _entries?.clear();
    _negatives?.clear();
    await _save();
  }

  /// 清掉所有负缓存（等价于旧 `clearNoCoverSentinels` 的语义）。
  static Future<int> clearNegatives() async {
    await _ensureLoaded();
    final count = _negatives?.length ?? 0;
    _negatives?.clear();
    if (count > 0) {
      await _save();
    }
    return count;
  }

  /// 清理中断留下的 `.part` 文件（启动时调一次即可）。
  static Future<int> sweepPartFiles() async {
    final root = rootDirectory();
    var removed = 0;
    try {
      if (!await root.exists()) {
        return 0;
      }
      await for (final entity in root.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.part')) {
          await _deleteQuietly(entity.path);
          removed++;
        }
      }
      final indexPart = File('${_indexFile().path}.part');
      if (await indexPart.exists()) {
        await _deleteQuietly(indexPart.path);
        removed++;
      }
    } catch (_) {}
    return removed;
  }

  /// 把旧缓存目录里的文件**引用**接管进统一索引，返回新接管的条目数。
  ///
  /// ## 迁移规则
  ///
  /// - 旧 `managed_download_covers` / `archive_covers` 里的文件**原地不动**
  ///   （它们在应用目录内，没必要搬家，搬了反而多一次失败机会），
  ///   只在索引里登记一条"该文件可用"的记录；
  /// - 因此 [lookup] 命中这类条目时返回的是**旧路径**，调用方照常可读；
  /// - 这满足"迁移可重入、原子、失败不删除源文件"：
  ///   任何一步失败都只是"少登记一条"，不影响已有文件；
  /// - **重复执行是幂等的**：已登记的键会被跳过。
  ///
  /// 说明：刻意不采用"复制到新目录再改索引" —— 那会让同一张封面在磁盘上
  /// 有两份，且复制失败时新旧都不完整。登记引用更简单也更安全。
  ///
  /// 通常不需要手动调用：[_load] 在首次读索引时会自动跑一遍。
  static Future<int> adoptLegacyCovers() async {
    await _ensureLoaded();
    final adopted = await _adoptLegacyCoversInternal();
    if (adopted > 0) {
      await _save();
    }
    return adopted;
  }

  static Future<int> _adoptLegacyCoversInternal() async {
    final entries = _entries;
    if (entries == null) {
      return 0;
    }
    final legacyDirs = <String>[
      // 旧 managed download 封面目录（`LocalLibraryManager` 曾用它）。
      p.join(App.dataPath, 'local_library_cache', 'managed_download_covers'),
      // 旧压缩包封面目录（`ArchiveReadingService` 曾在 App.dataPath 下用它）。
      p.join(App.dataPath, 'local_library_cache', 'archive_covers'),
      // 旧压缩包封面目录的**真实默认位置**：`Directory.systemTemp/picakeep/...`
      //（Android 上是 `<pkg>/cache`）。它会被系统清理，所以这里只是"能救就救"。
      p.join(
        Directory.systemTemp.path,
        'picakeep',
        'local_library_cache',
        'archive_covers',
      ),
    ];
    var adopted = 0;
    for (final dirPath in legacyDirs) {
      final dir = Directory(dirPath);
      try {
        if (!await dir.exists()) {
          continue;
        }
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) {
            continue;
          }
          final name = p.basename(entity.path);
          if (name.endsWith('.part')) {
            continue;
          }
          // 键用"文件名"派生的稳定值：旧文件没有留存它原本的条目键，
          // 只能按文件名接管。这不完美（新写入的条目仍走精确键），
          // 但足以让**旧图继续可见**，而新解析会自然覆盖。
          final key = 'legacy::$name';
          if (entries.containsKey(key)) {
            continue;
          }
          entries[key] = LocalCoverCacheEntry(
            relativePath: _relativeToRootOrAbsolute(entity.path),
            fingerprint: fingerprintFor(entity),
            updatedAt: DateTime.now(),
          );
          adopted++;
        }
      } catch (_) {
        // 单个目录失败不影响其它目录，也不影响已有缓存。
      }
    }
    if (adopted > 0) {
      _adoptedDirty = true;
    }
    return adopted;
  }

  /// 索引里存的多半是"缓存根下的文件名"；旧缓存的文件在别处，
  /// 这时存绝对路径。`p.isAbsolute` 让两种都能被 [lookup] 还原。
  static String _relativeToRootOrAbsolute(String path) {
    final root = rootDirectory().path;
    if (p.isWithin(root, path)) {
      return p.relative(path, from: root);
    }
    return path;
  }

  /// [lookup] 用 `p.join(root, relativePath)` 还原；绝对路径 join 后仍是它自己，
  /// 所以旧缓存（绝对路径）不需要特殊分支。
  static Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  static String _normalizeExtension(String? extension) {
    final ext = extension?.trim() ?? '';
    if (ext.isEmpty) {
      return '.img';
    }
    final withDot = ext.startsWith('.') ? ext : '.$ext';
    final lower = withDot.toLowerCase();
    for (final allowed in const ['.jpg', '.jpeg', '.png', '.webp', '.gif']) {
      if (lower == allowed) {
        return allowed;
      }
    }
    // 未知扩展名统一成 .img：**不要把来源里的奇怪后缀带进文件名**
    //（它可能含分隔符，导致写到缓存根之外）。
    return '.img';
  }

  static String _stableHash(String input) {
    var hash = 1469598103934665603;
    for (final unit in utf8.encode(input)) {
      hash ^= unit;
      hash = (hash * 1099511628211) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16);
  }

  /// 供同层缓存（如 `CoverThumbnailCache`）复用的稳定哈希。
  ///
  /// 公开它而不是让对方各写一份：缓存文件名一旦出现两套哈希实现，
  /// "同一份数据两个名字"就会立刻导致缓存永不命中的隐性浪费。
  static String stableHashForFileName(String input) => _stableHash(input);

  /// 仅供测试：丢弃内存索引，强制下次重新读盘。
  static void debugResetForTest() {
    _entries = null;
    _negatives = null;
    _loadedRoot = null;
    _loading = null;
  }
}

/// 负缓存记录。
class _NegativeRecord {
  const _NegativeRecord(
      {required this.fingerprint, required this.at, this.transient = false});

  final String fingerprint;
  final DateTime at;
  final bool transient;

  Map<String, Object?> toJson() => <String, Object?>{
        'fp': fingerprint,
        'at': at.millisecondsSinceEpoch,
        'transient': transient,
      };

  static _NegativeRecord? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final at = raw['at'];
    return _NegativeRecord(
      fingerprint: raw['fp']?.toString() ?? '',
      at: DateTime.fromMillisecondsSinceEpoch(at is int ? at : 0),
      transient: raw['transient'] == true,
    );
  }
}
