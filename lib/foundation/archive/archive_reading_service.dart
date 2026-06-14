import 'dart:io';
import 'dart:typed_data';

import 'archive_errors.dart';
import 'archive_memory_cache.dart';
import 'archive_models.dart';
import 'archive_password_store.dart';
import 'archive_registry.dart';

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
        await backend.readEntry(
          archivePath,
          encryptedEntries.first.path,
          password: password,
        );
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
    _clearArchiveCoverCache();
  }

  Future<String?> extractCoverToCache(
    String archivePath,
    String entryPath,
  ) async {
    try {
      final bytes = await _readEntryBytesUncached(archivePath, entryPath);
      if (bytes.isEmpty) return null;
      final cacheDir = await _archiveCoverCacheDir();
      final hash = _stableHash('$archivePath::$entryPath');
      final ext = _extensionForPath(entryPath);
      final file = File('${cacheDir.path}/$hash$ext');
      await cacheDir.create(recursive: true);
      final temp = File('${file.path}.part');
      await temp.writeAsBytes(bytes, flush: true);
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _readEntryBytesUncached(
    String archivePath,
    String entryPath,
  ) async {
    return _readEntryWithPasswordFallback(archivePath, entryPath);
  }

  Future<Directory> _archiveCoverCacheDir() async {
    final root = Platform.environment['PICAKEEP_CACHE_DIR']?.trim();
    final base = root == null || root.isEmpty
        ? '${Directory.systemTemp.path}${Platform.pathSeparator}picakeep'
        : root;
    return Directory(
      '$base${Platform.pathSeparator}local_library_cache${Platform.pathSeparator}archive_covers',
    );
  }

  void _clearArchiveCoverCache() async {
    try {
      final dir = await _archiveCoverCacheDir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

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
