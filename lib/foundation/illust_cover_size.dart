/// 插画卡片的**封面尺寸**解析：有界读文件头 → 解析 → 按 `路径 + 时间戳` 缓存。
///
/// ## 为什么读"封面"而不是"第一页"
///
/// 32 号计划原本设想读**第一页图片**的头。真机实测（见该计划回写区）否掉了这条路：
///
/// - 走 `download.db` 元数据路径的记录，`episodeFiles` **只从扫描缓存里取**
///   （`local_library_scan.dart:328-329`），缓存里没有就恒为空 `{}`。
///   真机三条 Pixiv 记录里有 **2 条** `episodeFiles` 为空 —— 拿不到第一页路径。
/// - 而**封面路径本来就已解析好**：`LocalLibraryManager.resolveCoverPathForItem`
///   带目录扫描兜底、特权通道与 `noCoverSentinel`，卡片显示的也正是这张图。
/// - 实测三张真机封面与对应第一页的比例一致（0.53128/0.53167、0.71312/0.71333、
///   0.57143/0.57167，差值来自缩放取整）。
///
/// 结论：**卡片渲染哪张图，就量哪张图**。这条比"作品级首图尺寸"更贴近
/// "图不被裁切"这个验收点，也更少依赖扫描链路的字段是否被填上。
///
/// ## 读字节必须走特权通道
///
/// 目标设备有 root / Shizuku，外部路径下 `File.existsSync()` 会误报 true 而
/// `readAsBytes()` 静默失败（根因见 `local_library.dart:1213-1220`）。
/// 所以这里的读法与那位"既有的正确做法"同构：**先 dart:io，读到空再回退
/// `PrivilegedStorageAccess`** —— 绝不写"只走 dart:io"的裸读。
///
/// 区别只在**有界**：应用沙箱内用 `File.open()` + `read(maxBytes)` 只取头部，
/// 不必把一个 6 MB 的封面整个读进内存；只有 dart:io 读不到（root/Shizuku 下的
/// 外部路径）才退到"整读再截断"的特权通道 —— 那条通道没有偏移/长度参数。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'package:picakeep/foundation/image_header_size.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/foundation/privileged_storage_access.dart';

/// 读头部字节的上限。
///
/// 256 KB 足够覆盖所有现实情况，且只占封面体积的零头：
/// - PNG 的 `IHDR` 在固定偏移 16；
/// - GIF 在偏移 6；WebP 的块头在 12~30；
/// - JPEG 必须先跳过 `APPn` 段，而 Pixiv 原图带 XMP/EXIF 时 `APP1` 能到几十 KB
///   —— 留 256 KB 是为了那种图也能在**一次**读里扫到 `SOF`，不必二次读。
///
/// ⚠️ 不要为了"保险"调成整个文件大小：那等于每张图都整读一遍，几百张就会把
/// 首次进视图的耗时拉到秒级。头部扫不到就按"尺寸未知"降级，比慢更可接受。
const int illustHeaderReadBytes = 256 * 1024;

/// 缓存文件的版本号。解析/存储格式变了就 +1，老缓存自动作废。
const int illustCoverSizeCacheVersion = 1;

/// 封面尺寸缓存：`「路径::时间戳」→ 宽高`，可选落盘。
///
/// 缓存的是**已解析出来的尺寸**而不是图片字节：几百条路径 + 两个整数，
/// 文件只有几十 KB，读一次比读几百张图的头便宜得多。
class IllustCoverSizeCache {
  IllustCoverSizeCache._(this._file, this._entries);

  /// 纯内存缓存（测试与"缓存文件不可用"时使用）。
  factory IllustCoverSizeCache.inMemory() =>
      IllustCoverSizeCache._(null, <String, ImageHeaderSize>{});

  /// 文件支撑的缓存。
  ///
  /// 生产走 [sharedIllustCoverSizeCache]（路径固定在应用支持目录下）；
  /// 这个工厂存在的意义是**让落盘往返可测** —— 缓存格式写错时症状是
  /// "每次进视图都重新读一遍所有封面头"（慢，但不报错），不上真机量不出来。
  factory IllustCoverSizeCache.atFile(File file) =>
      IllustCoverSizeCache._(file, <String, ImageHeaderSize>{});

  final File? _file;
  final Map<String, ImageHeaderSize> _entries;
  bool _dirty = false;
  bool _loadedFromDisk = false;

  int get length => _entries.length;

  ImageHeaderSize? lookup(String key) => _entries[key];

  void store(String key, ImageHeaderSize size) {
    if (_entries[key] == size) {
      return;
    }
    _entries[key] = size;
    _dirty = true;
  }

  /// 从磁盘加载（只做一次，尽力而为：读不到就当空缓存）。
  Future<void> load() async {
    final file = _file;
    if (file == null || _loadedFromDisk) {
      return;
    }
    _loadedFromDisk = true;
    try {
      if (!file.existsSync()) {
        return;
      }
      final decoded = _decodeCacheFile(await file.readAsString());
      if (decoded != null) {
        _entries.addAll(decoded);
      }
    } catch (_) {}
  }

  /// 落盘（尽力而为）。缓存写不进去只是下次多读几遍文件头，**不该升级成异常**。
  Future<void> save() async {
    final file = _file;
    if (file == null || !_dirty) {
      return;
    }
    _dirty = false;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(<String, Object>{
          'version': illustCoverSizeCacheVersion,
          'sizes': <String, Object>{
            for (final entry in _entries.entries)
              entry.key: <int>[entry.value.width, entry.value.height],
          },
        }),
        flush: true,
      );
    } catch (_) {}
  }

  /// 解析缓存文件；版本不符 / 结构不对 / 坏 JSON 一律返回 `null`（当空缓存重建）。
  ///
  /// 缓存是**可丢的加速层**：任何异常都不该让调用方失败，因此这里把"格式不对"
  /// 与"读不到"合并成同一种结果 —— 返回 null，调用方照常重新读图片头。
  static Map<String, ImageHeaderSize>? _decodeCacheFile(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      if (decoded['version'] != illustCoverSizeCacheVersion) {
        return null;
      }
      final sizes = decoded['sizes'];
      if (sizes is! Map) {
        return null;
      }
      final result = <String, ImageHeaderSize>{};
      for (final entry in sizes.entries) {
        final value = entry.value;
        if (value is List && value.length == 2) {
          final width = value[0];
          final height = value[1];
          if (width is int && height is int && width > 0 && height > 0) {
            result[entry.key.toString()] = ImageHeaderSize(width, height);
          }
        }
      }
      return result;
    } catch (_) {
      return null;
    }
  }
}

/// 一次解析任务要补的字段。
class IllustResolvedInfo {
  const IllustResolvedInfo({this.width, this.height, this.pageCount});

  /// 原图宽高（读到了才有）。
  final int? width;
  final int? height;

  /// 作品图片张数（目录形态才数得出来）。
  final int? pageCount;

  bool get hasSize => width != null && height != null;

  bool get isEmpty => width == null && height == null && pageCount == null;
}

/// 读文件头字节（可注入，便于测试）。
typedef IllustHeadReader = Future<Uint8List?> Function(
    String path, int maxBytes);

/// 读文件的"时间戳"标识（可注入）。读不到返回 null。
typedef IllustStampReader = Future<String?> Function(String path);

/// 列目录（可注入）。
typedef IllustDirectoryLister = Future<List<LocalDirectoryEntry>> Function(
    String path);

/// 解析封面的本地路径（可注入）。
typedef IllustCoverPathResolver = Future<String?> Function(
    LocalLibraryComicItem item);

/// 进程内共享的尺寸缓存。
///
/// 必须是共享的：同一个封面在"进插画视图 → 返回 → 再进"之间不该重读文件头。
IllustCoverSizeCache? _sharedCache;

/// 取共享缓存（首次调用时建好并尝试从磁盘加载）。
Future<IllustCoverSizeCache> sharedIllustCoverSizeCache() async {
  final existing = _sharedCache;
  if (existing != null) {
    return existing;
  }
  final cache = await _openFileCache();
  _sharedCache = cache;
  return cache;
}

/// 仅供测试：清掉共享缓存，避免用例之间互相污染。
void resetSharedIllustCoverSizeCacheForTest() {
  _sharedCache = null;
}

Future<IllustCoverSizeCache> _openFileCache() async {
  try {
    final support = await getApplicationSupportDirectory();
    final file = File(
      '${support.path}${Platform.pathSeparator}local_library_cache'
      '${Platform.pathSeparator}illust_cover_sizes.json',
    );
    final cache = IllustCoverSizeCache._(file, <String, ImageHeaderSize>{});
    await cache.load();
    return cache;
  } catch (_) {
    return IllustCoverSizeCache.inMemory();
  }
}

/// 页数记忆：跨"重新取数"保住已经数出来的页数，并避免对同一作品反复列目录。
///
/// ## 为什么需要它（两条都是执行中真踩到的）
///
/// 1. **页数会凭空消失**：页数只能靠列目录数出来，而 `buildIllustEntries` 每次都
///    重建条目（`pageCount` 恒为 null）。页面的 `_loadIllust` 在本地数据变更、
///    手动刷新、切视图时都会被再调一次 —— 不回填的话，用户看到的是
///    "页数显示了一会儿，刷新一下就没了"。
/// 2. **不能靠一个布尔量"补过就不再补"**：那样用户先在没勾「页数」的配置下进过
///    视图、之后再去设置里勾上，页数就**永远补不上**（且不报错）。所以判据必须是
///    "**这一条**的页数是否已知 / 是否试过"，而不是"这个页面补过没有"。
///
/// 对"数不出来"的条目（压缩包形态、目录读不到）会记下"试过"，避免每次刷新都白扫
/// 一遍目录 —— 那不是"永远补不上"，而是"这次读不出来就别反复试"。
class IllustPageCountMemo {
  final Map<String, int> _counts = <String, int>{};
  final Set<String> _attempted = <String>{};

  /// 记住的页数条数（测试与诊断用）。
  int get rememberedCount => _counts.length;

  int? countFor(String id) => _counts[id];

  /// 该条目的页数是否还需要去数。
  bool needsCount(String id) =>
      !_counts.containsKey(id) && !_attempted.contains(id);

  /// 标记"已经尝试过"（不论成功与否）。
  void markAttempted(String id) {
    _attempted.add(id);
  }

  /// 记下数出来的页数（`null` / 非正数表示这次没数出来）。
  void record(String id, int? count) {
    markAttempted(id);
    if (count != null && count > 0) {
      _counts[id] = count;
    }
  }

  /// 把记下的页数**回填**到新取到的一批条目上。
  List<IllustLibraryEntry> apply(List<IllustLibraryEntry> entries) {
    if (_counts.isEmpty) {
      return entries;
    }
    return <IllustLibraryEntry>[
      for (final entry in entries)
        _counts[entry.id] == null
            ? entry
            : entry.withResolvedInfo(pageCount: _counts[entry.id]),
    ];
  }
}

/// 从一批条目里挑出**需要补信息**的那些（页面在 `_loadIllust` 之后调它）。
///
/// 抽成纯函数有两个理由：
/// 1. **可测** —— "哪些条目该读文件"是这条链路的开关，判错会表现为
///    "老记录永远等高"（该补的没补）或"新记录每次进视图都重读一遍封面头"
///    （不该补的补了），两种都不报错；
/// 2. 页面（`local_library_page.dart`，3000 行）里少一段分支逻辑。
///
/// [wantPageCount] 为真时，**宽高已齐全**的条目也可能被选中 —— 它们只缺页数；
/// 但已经数出来过（[pageCountMemo] 有记录）或已试过的不再重复选中。
List<IllustLibraryEntry> illustEntriesNeedingResolution(
  Iterable<IllustLibraryEntry> entries, {
  required bool wantPageCount,
  IllustPageCountMemo? pageCountMemo,
}) {
  return <IllustLibraryEntry>[
    for (final entry in entries)
      if (entry.needsSizeResolution ||
          (wantPageCount &&
              entry.pageCount == null &&
              (pageCountMemo?.needsCount(entry.id) ?? true)))
        entry,
  ];
}

/// 把补齐结果合并回条目列表（页面 `setState` 时调它）。
///
/// 语义：
/// - 结果里没有的 id → **原样保留**（占位比例，卡片不会因此变坏）；
/// - `withResolvedInfo` 保证**宽高只增不减**（db 里的作品级尺寸是权威值）；
/// - **按当前列表顺序**产出新列表，不改顺序、不丢条目 ——
///   这是"后台补齐"能被安全地 `setState` 回界面的前提。
///
/// ⚠️ 不要写成"用结果直接替换整个列表"：补齐是可能**部分失败**的
/// （一条封面读不到不该让其它条目退回占位）。
List<IllustLibraryEntry> applyIllustResolvedInfo(
  List<IllustLibraryEntry> entries,
  Map<String, IllustResolvedInfo> resolved,
) {
  if (resolved.isEmpty) {
    return entries;
  }
  return <IllustLibraryEntry>[
    for (final entry in entries)
      resolved[entry.id] == null
          ? entry
          : entry.withResolvedInfo(
              width: resolved[entry.id]!.width,
              height: resolved[entry.id]!.height,
              pageCount: resolved[entry.id]!.pageCount,
            ),
  ];
}

/// 为一批插画条目补齐"缺的"展示信息。
///
/// ## 输入输出
///
/// - 入参 [entries] 是**待补**的条目（调用方自己筛出"缺宽高 / 需页数"的那批）；
/// - 返回 `条目 id → IllustResolvedInfo`；**取不到信息的 id 不出现在结果里**，
///   调用方据此保持原样（占位比例）。
///
/// ## 失败处理
///
/// 任何一步失败（路径解析不出、文件读不到、头认不出来、目录列不出来）都只让
/// **这一条**拿不到信息，不影响同批其它条目，也不抛异常 —— 瀑布流宁可有一条
/// 用占位比例，也不该整页报错。
///
/// ## 为什么要限制并发
///
/// 一屏可能几十条，全部并发会让 root/Shizuku 通道上瞬间堆几十个平台通道调用；
/// 而完全串行又太慢。取 4 是"够快且不压垮通道"的折中。
Future<Map<String, IllustResolvedInfo>> resolveIllustEntryInfo({
  required List<IllustLibraryEntry> entries,
  required IllustCoverPathResolver resolveCoverPath,
  bool needPageCount = false,
  IllustHeadReader? readHead,
  IllustStampReader? readStamp,
  IllustDirectoryLister? listDirectory,
  IllustCoverSizeCache? cache,
  int concurrency = 4,
}) async {
  if (entries.isEmpty) {
    return const <String, IllustResolvedInfo>{};
  }
  final effectiveCache = cache ?? await sharedIllustCoverSizeCache();
  final headReader = readHead ?? readFileHeadBytes;
  final stampReader = readStamp ?? readFileStamp;
  final lister = listDirectory ?? PrivilegedStorageAccess.listDirectoryEntries;

  final results = <String, IllustResolvedInfo>{};
  await _forEachConcurrent<IllustLibraryEntry>(
    entries,
    concurrency < 1 ? 1 : concurrency,
    (entry) async {
      var width = entry.width;
      var height = entry.height;
      int? pageCount;

      if (width == null || height == null) {
        String? coverPath;
        try {
          coverPath = await resolveCoverPath(entry.item);
        } catch (_) {
          coverPath = null;
        }
        final path = coverPath?.trim() ?? '';
        if (path.isNotEmpty) {
          final size = await _resolveSizeForPath(
            path,
            cache: effectiveCache,
            readHead: headReader,
            readStamp: stampReader,
          );
          if (size != null) {
            width = size.width;
            height = size.height;
          }
        }
      }

      if (needPageCount) {
        pageCount = await _resolvePageCount(entry, listDirectory: lister);
      }

      final info = IllustResolvedInfo(
        width: width,
        height: height,
        pageCount: pageCount,
      );
      if (!info.isEmpty) {
        results[entry.id] = info;
      }
    },
  );
  unawaited(effectiveCache.save());
  return results;
}

/// 单个文件：查缓存 → 未命中则读头 → 回填缓存。
Future<ImageHeaderSize?> _resolveSizeForPath(
  String path, {
  required IllustCoverSizeCache cache,
  required IllustHeadReader readHead,
  required IllustStampReader readStamp,
}) async {
  final stamp = await readStamp(path);
  final key = stamp == null || stamp.isEmpty ? path : '$path::$stamp';
  final cached = cache.lookup(key);
  if (cached != null) {
    return cached;
  }
  final bytes = await readHead(path, illustHeaderReadBytes);
  if (bytes == null || bytes.isEmpty) {
    return null;
  }
  final size = parseImageHeaderSize(bytes);
  if (size == null) {
    return null;
  }
  cache.store(key, size);
  return size;
}

/// 数一条作品的图片张数。
///
/// 只在三种形态下给得出：
/// - **目录形态**（默认）：列目录数图片文件；
/// - **单文件形态**（`settings[154]` 打开后的单图作品）：恒为 1；
/// - **压缩包形态**：给不出（要么解压要么读 zip 中央目录，成本与本功能不匹配），
///   返回 null → 卡片不渲染「页数」这一项。
///
/// `episodeFiles` 不再作为来源：真机实测它只从扫描缓存取（见文件头注释），
/// 2/3 的记录是空的，拿它当来源会让「页数」时有时无。
Future<int?> _resolvePageCount(
  IllustLibraryEntry entry, {
  required IllustDirectoryLister listDirectory,
}) async {
  final item = entry.item;
  final path = (item.fileSystemPath ?? '').trim();
  if (path.isEmpty) {
    return null;
  }
  final lower = path.toLowerCase();
  if (lower.endsWith('.zip') || lower.endsWith('.cbz')) {
    return null;
  }
  if (isIllustImageFileName(lower)) {
    return 1;
  }
  try {
    final entries = await listDirectory(path);
    if (entries.isEmpty) {
      return null;
    }
    final count = countIllustPageImages(
      entries.where((e) => !e.isDirectory).map((e) => e.name),
    );
    return count > 0 ? count : null;
  } catch (_) {
    return null;
  }
}

/// 图片扩展名（与项目别处的口径一致：正文只有 jpg/jpeg/png/webp/gif）。
const List<String> _illustImageExtensions = <String>[
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
];

/// 是否像一张图片文件（给的是**已小写**的文件名或路径）。
bool isIllustImageFileName(String lowerPath) {
  for (final ext in _illustImageExtensions) {
    if (lowerPath.endsWith(ext)) {
      return true;
    }
  }
  return false;
}

/// 目录里的**图片张数**（用于「页数」）。
///
/// **排除封面**：封面是列表用来展示的图，不是作品的一页。真机目录里
/// `1.jpg` + `cover.jpg` 是标准形态，不排除就会把单图作品数成 2 页。
int countIllustPageImages(Iterable<String> fileNames) {
  var count = 0;
  for (final name in fileNames) {
    final lower = name.toLowerCase();
    if (!isIllustImageFileName(lower)) {
      continue;
    }
    if (lower.split('/').last.startsWith('cover.')) {
      continue;
    }
    count++;
  }
  return count;
}

/// 有界读文件头。
///
/// 顺序与 `PrivilegedStorageAccess.readFileBytes` 一致（**dart:io 优先、
/// 特权通道兜底**），只是 dart:io 这一层不整读：
///
/// 1. `File.open()` + `read(maxBytes)` —— 应用沙箱内（本应用下载目录）命中，
///    只取头部，不把整个封面读进内存；
/// 2. 读到的字节为空（root/Shizuku 下外部路径被 scoped storage 静默拦截）→
///    回退 `PrivilegedStorageAccess.readFileBytes` 再截断。那条通道没有偏移
///    参数，只能整读，但它是既有代码，行为已被真机验证过。
Future<Uint8List?> readFileHeadBytes(String path, int maxBytes) async {
  if (maxBytes <= 0) {
    return null;
  }
  RandomAccessFile? handle;
  try {
    final file = File(path);
    if (file.existsSync()) {
      handle = await file.open();
      final length = await handle.length();
      final want = length < maxBytes ? length : maxBytes;
      if (want > 0) {
        final bytes = await handle.read(want);
        if (bytes.isNotEmpty) {
          return bytes;
        }
      }
    }
  } catch (_) {
    // 落到特权通道。
  } finally {
    try {
      await handle?.close();
    } catch (_) {}
  }
  final bytes = await PrivilegedStorageAccess.readFileBytes(path);
  if (bytes == null || bytes.isEmpty) {
    return null;
  }
  return bytes.length <= maxBytes
      ? bytes
      : Uint8List.sublistView(bytes, 0, maxBytes);
}

/// 文件的"时间戳"标识：优先 mtime，取不到退到长度。
///
/// 为什么要有这一层：缓存键必须能在文件被替换后失效。mtime 最直接，但特权通道
/// 只提供"存在 / 读字节 / 列目录"，**没有 stat**，所以 root/Shizuku 下的外部路径
/// 拿不到 mtime —— 此时用文件长度代替。长度变化的概率远高于"换了内容但长度恰好
/// 一样"，作为降级判据足够；真出现同长度替换，最坏结果是沿用旧比例，不会报错。
Future<String?> readFileStamp(String path) async {
  try {
    final file = File(path);
    if (file.existsSync()) {
      return 'm${file.lastModifiedSync().millisecondsSinceEpoch}';
    }
  } catch (_) {}
  try {
    final length = await PrivilegedStorageAccess.fileLength(path);
    if (length != null) {
      return 'l$length';
    }
  } catch (_) {}
  return null;
}

/// 固定并发地跑一批异步任务。
Future<void> _forEachConcurrent<T>(
  List<T> items,
  int concurrency,
  Future<void> Function(T item) run,
) async {
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final index = next;
      next++;
      if (index >= items.length) {
        return;
      }
      await run(items[index]);
    }
  }

  final workers = <Future<void>>[];
  for (var i = 0; i < concurrency && i < items.length; i++) {
    workers.add(worker());
  }
  await Future.wait(workers);
}
