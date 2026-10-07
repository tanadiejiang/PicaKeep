import 'dart:io';
import 'dart:typed_data';

import 'archive_errors.dart';
import 'archive_backend.dart';
import 'archive_memory_cache.dart';
import 'archive_models.dart';
import 'archive_password_store.dart';
import 'archive_registry.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';

class ArchiveReadingService {
  ArchiveReadingService._();
  static final ArchiveReadingService instance = ArchiveReadingService._();

  final ArchiveRegistry _registry = ArchiveRegistry.instance;
  final ArchivePasswordStore _passwords = ArchivePasswordStore.instance;
  final ArchiveMemoryCache _cache = ArchiveMemoryCache.instance;

  final Map<String, ({int fileSize, int mtimeMillis})> _fingerprints = {};

  Future<ArchiveIndex> getIndex(
    String archivePath, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cached = _cache.getIndex(archivePath);
      if (cached != null) {
        final fp = await fingerprintForPath(archivePath);
        if (fp != null &&
            fp.fileSize == cached.fileSize &&
            fp.mtimeMillis == cached.mtimeMillis) {
          return ArchiveIndex(
            archivePath: archivePath,
            format: archiveFormatForPath(archivePath),
            isEncrypted: cached.isEncrypted,
            entries: cached.imageEntryPaths
                .map((p) => ArchiveEntry(
                      path: p,
                      size: 0,
                      isEncrypted: cached.isEncrypted,
                      isDirectory: false,
                    ))
                .toList(),
            fileSize: cached.fileSize,
            mtimeMillis: cached.mtimeMillis,
          );
        }
      }
    }

    final backend = _registry.backendForOrThrow(archivePath);
    final password = _passwords.getSessionPassword(archivePath);
    final index = await backend.openIndex(archivePath, password: password);

    _cache.putIndex(ArchiveIndexCacheEntry(
      archivePath: archivePath,
      fileSize: index.fileSize,
      mtimeMillis: index.mtimeMillis,
      imageEntryPaths: index.imageEntries.map((e) => e.path).toList(),
      isEncrypted: index.isEncrypted,
    ));

    _fingerprints[archivePath] = (
      fileSize: index.fileSize,
      mtimeMillis: index.mtimeMillis,
    );

    return index;
  }

  ({int fileSize, int mtimeMillis})? fingerprintCachedFor(String archivePath) =>
      _fingerprints[archivePath];

  Future<bool> tryUnlock(String archivePath, String password) async {
    final backend = _registry.backendForOrThrow(archivePath);
    try {
      final index = await backend.openIndex(archivePath, password: password);
      final encryptedEntries = index.entries
          .where((e) => e.isEncrypted && !e.isDirectory && e.size > 0)
          .toList();
      encryptedEntries.sort((a, b) {
        final imageCompare = (_isImageEntry(b.path) ? 1 : 0)
            .compareTo(_isImageEntry(a.path) ? 1 : 0);
        if (imageCompare != 0) return imageCompare;
        return a.size.compareTo(b.size);
      });

      if (encryptedEntries.isNotEmpty) {
        if (backend is StreamingArchiveBackend) {
          final bytes = encryptedEntries.first.size;
          ImageTemporaryReservation? reservation;
          Directory? directory;
          try {
            directory = await Directory.systemTemp
                .createTemp('picakeep-archive-unlock-');
            reservation = await ImageTemporaryPool.shared.reserveOnDisk(bytes,
                purpose: 'archive-password-validation',
                path: '${directory.path}/verify.bin');
            await (backend as StreamingArchiveBackend).materializeEntry(
              archivePath,
              encryptedEntries.first.path,
              File('${directory.path}/verify.bin'),
              password: password,
              maxBytes: bytes,
            );
          } finally {
            try {
              if (directory != null && await directory.exists()) {
                await directory.delete(recursive: true);
              }
            } finally {
              reservation?.release();
            }
          }
        } else {
          if (encryptedEntries.first.size > 8 * 1024 * 1024) {
            throw const ArchiveFailure(
                code: ArchiveErrorCode.entryTooLarge,
                debugMessage: 'Backend lacks bounded password validation');
          }
          await backend.readEntry(archivePath, encryptedEntries.first.path,
              password: password);
        }
        _passwords.setSessionPassword(archivePath, password);
        _cache.evictIndex(archivePath);
        return true;
      }

      if (index.imageEntries.isNotEmpty ||
          index.entries.any((e) => !e.isDirectory)) {
        _passwords.setSessionPassword(archivePath, password);
        _cache.evictIndex(archivePath);
        return true;
      }
      return false;
    } on ArchiveFailure catch (f) {
      if (f.code == ArchiveErrorCode.wrongPassword ||
          f.code == ArchiveErrorCode.passwordRequired) {
        return false;
      }
      rethrow;
    }
  }

  Future<Uint8List> readEntryBytesByUri(String uriString) async {
    final parsed = parseArchiveUri(uriString);
    if (parsed == null) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.entryNotFound,
        debugMessage: 'Invalid archive URI: $uriString',
      );
    }
    return readEntryBytes(parsed.archivePath, parsed.entryPath);
  }

  Future<File> materializeEntry(
    String archivePath,
    String entryPath,
    File destination, {
    String? passwordArchivePath,
    int maxBytes = 2 * 1024 * 1024 * 1024,
    bool Function()? isCancelled,
  }) async {
    final backend = _registry.backendForOrThrow(archivePath);
    if (backend is! StreamingArchiveBackend) {
      throw ArchiveFailure(
          code: ArchiveErrorCode.unsupportedFormat,
          debugMessage:
              'Backend does not support bounded extraction: ${backend.id}');
    }
    final candidates =
        _passwords.passwordCandidates(passwordArchivePath ?? archivePath);
    ArchiveFailure? lastFailure;
    for (final password in candidates) {
      try {
        return await (backend as StreamingArchiveBackend).materializeEntry(
          archivePath,
          entryPath,
          destination,
          password: password,
          maxBytes: maxBytes,
          isCancelled: isCancelled,
        );
      } on ArchiveFailure catch (failure) {
        if (failure.code == ArchiveErrorCode.wrongPassword ||
            failure.code == ArchiveErrorCode.passwordRequired) {
          lastFailure = failure;
          continue;
        }
        rethrow;
      }
    }
    throw lastFailure ??
        const ArchiveFailure(
          code: ArchiveErrorCode.passwordRequired,
          debugMessage: 'No valid password for archive entry',
        );
  }

  Future<Uint8List> readEntryBytes(
    String archivePath,
    String entryPath,
  ) async {
    final fp = await fingerprintForPath(archivePath);
    if (fp != null) {
      final cacheKey = ArchiveMemoryCache.entryCacheKey(
        archivePath,
        entryPath,
        fp.fileSize,
        fp.mtimeMillis,
      );
      final cached = _cache.getEntry(cacheKey);
      if (cached != null) return cached;

      final data = await _readEntryWithPasswordFallback(archivePath, entryPath);
      _cache.putEntry(cacheKey, data);
      return data;
    }
    return _readEntryWithPasswordFallback(archivePath, entryPath);
  }

  Future<Uint8List> _readEntryWithPasswordFallback(
    String archivePath,
    String entryPath,
  ) async {
    final backend = _registry.backendForOrThrow(archivePath);
    final candidates = _passwords.passwordCandidates(archivePath);

    ArchiveFailure? lastFailure;
    for (final password in candidates) {
      try {
        return await backend.readEntry(
          archivePath,
          entryPath,
          password: password,
        );
      } on ArchiveFailure catch (f) {
        if (f.code == ArchiveErrorCode.wrongPassword ||
            f.code == ArchiveErrorCode.passwordRequired) {
          lastFailure = f;
          continue;
        }
        rethrow;
      }
    }
    throw lastFailure ??
        ArchiveFailure(
          code: ArchiveErrorCode.passwordRequired,
          debugMessage: 'No valid password for $archivePath',
        );
  }

  void disposeReadingSession(String archivePath) {
    _cache.evictAllForArchive(archivePath);
  }

  void clearAllReadingState() {
    _cache.clearAll();
    // plan/12：压缩包封面已并入统一缓存（`LocalCoverCache`），
    // "清阅读状态"不再删除封面文件 —— 它们是可复用的正式缓存，
    // 删了会让所有压缩包封面在下次进入页面时重新解一遍。
    // 需要真正失效时走 `LocalCoverCache.invalidateAll()`。
  }

  Future<String?> extractCoverToCache(
    String archivePath,
    String entryPath,
  ) async {
    try {
      final archive = File(archivePath);
      FileStat? sourceStat;
      try {
        final stat = await archive.stat();
        if (stat.type == FileSystemEntityType.file && stat.size > 0) {
          sourceStat = stat;
        }
      } catch (_) {
        // Keep the backend's existing access/password fallback when direct
        // source identity cannot be verified; never trust a 0|0 fingerprint.
      }

      bool sameSource(FileStat current) =>
          sourceStat != null &&
          current.type == FileSystemEntityType.file &&
          current.size == sourceStat.size &&
          current.modified == sourceStat.modified &&
          current.changed == sourceStat.changed;

      if (sourceStat != null) {
        try {
          // stat alone does not prove the source is still readable. This opens
          // no member and allocates no whole-archive byte buffer.
          final handle = await archive.open();
          await handle.close();
          final index = await getIndex(archivePath);
          final member = entryPath.replaceAll('\\', '/');
          final hasMember = isValidArchiveEntryPath(entryPath) &&
              isValidArchiveEntryPath(member) &&
              index.entries
                  .any((entry) => !entry.isDirectory && entry.path == member);
          // Encrypted archives still validate the current password by reading
          // the member. A cached cover must not bypass forget/wrong-password.
          if (!index.isEncrypted &&
              hasMember &&
              index.fileSize == sourceStat.size &&
              index.mtimeMillis == sourceStat.modified.millisecondsSinceEpoch) {
            final key = LocalCoverCache.entryKeyFor(
              sourceId: 'archive_cover',
              originalId: _stableHash(archivePath),
              sourceRelative: entryPath,
            );
            final fingerprint = '$archivePath|${sourceStat.size}|'
                '${sourceStat.modified.millisecondsSinceEpoch}';
            final existing =
                await LocalCoverCache.lookup(key, fingerprint: fingerprint);
            if (existing != null && existing.isNotEmpty) {
              return sameSource(await archive.stat()) ? existing : null;
            }
          }
        } catch (_) {
          // Index/access uncertainty follows the original recovery
          // contract rather than publishing cached pixels without validation.
        }
      }
      final bytes = await _readEntryBytesUncached(archivePath, entryPath);
      if (bytes.isEmpty) return null;
      if (sourceStat != null && !sameSource(await archive.stat())) return null;
      return _storeCoverBytesToUnifiedCache(
        archivePath: archivePath,
        entryPath: entryPath,
        bytes: bytes,
      );
    } catch (_) {
      return null;
    }
  }

  /// 把压缩包内封面的字节写进**统一封面缓存**（plan/12）。
  ///
  /// 改动前这里默认写 `Directory.systemTemp/picakeep/...`（Android 上是
  /// `<pkg>/cache`）：它既不随应用数据目录迁移，又会被系统在存储紧张时清掉，
  /// 于是"同一张封面一会儿有一会儿没有"。现在统一进
  /// `App.dataPath/local_library_cache/covers`。
  ///
  /// 条目键用 `archive_cover::<包路径哈希>::<条目路径>`：同一压缩包的不同条目
  /// 分开缓存，不同压缩包互不干扰；指纹取包的长度 + mtime，
  /// **包被替换后不会再显示旧封面**。
  Future<String?> _storeCoverBytesToUnifiedCache({
    required String archivePath,
    required String entryPath,
    required Uint8List bytes,
  }) async {
    final key = LocalCoverCache.entryKeyFor(
      sourceId: 'archive_cover',
      originalId: _stableHash(archivePath),
      sourceRelative: entryPath,
    );
    final fingerprint = _archiveFingerprint(archivePath);
    final existing =
        await LocalCoverCache.lookup(key, fingerprint: fingerprint);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    return LocalCoverCache.storeBytes(
      entryKey: key,
      bytes: bytes,
      fingerprint: fingerprint,
      extension: _extensionForPath(entryPath),
    );
  }

  String _archiveFingerprint(String archivePath) {
    try {
      final stat = File(archivePath).statSync();
      return '$archivePath|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    } catch (_) {
      return '$archivePath|0|0';
    }
  }

  Future<Uint8List> _readEntryBytesUncached(
    String archivePath,
    String entryPath,
  ) async {
    return _readEntryWithPasswordFallback(archivePath, entryPath);
  }

  // plan/12：原 `_archiveCoverCacheDir` / `_clearArchiveCoverCache` 已删除。
  //
  // 它们把封面写到 `Directory.systemTemp/picakeep/local_library_cache/archive_covers`
  //（Android 上是 `<pkg>/cache`）—— 既不随应用数据目录迁移，又会被系统在
  // 存储紧张时清掉。现在统一由 `LocalCoverCache` 落进
  // `App.dataPath/local_library_cache/covers`，旧目录里的文件由
  // `LocalCoverCache.adoptLegacyCovers()` 登记接管（不搬迁、不删除）。

  String _stableHash(String input) {
    var hash = 1469598103934665603;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 1099511628211) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16);
  }

  String _extensionForPath(String path) {
    final lower = path.toLowerCase();
    for (final ext in ['.jpg', '.jpeg', '.png', '.webp']) {
      if (lower.endsWith(ext)) return ext;
    }
    return '.img';
  }

  bool _isImageEntry(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp');
  }
}
