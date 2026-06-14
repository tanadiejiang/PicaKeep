import 'dart:collection';
import 'dart:typed_data';

class ArchiveIndexCacheEntry {
  ArchiveIndexCacheEntry({
    required this.archivePath,
    required this.fileSize,
    required this.mtimeMillis,
    required this.imageEntryPaths,
    required this.isEncrypted,
  });

  final String archivePath;
  final int fileSize;
  final int mtimeMillis;
  final List<String> imageEntryPaths;
  final bool isEncrypted;
}

class ArchiveMemoryCache {
  ArchiveMemoryCache._();
  static final ArchiveMemoryCache instance = ArchiveMemoryCache._();

  static const int _indexCacheMaxEntries = 32;

  final LinkedHashMap<String, ArchiveIndexCacheEntry> _indexCache =
      LinkedHashMap<String, ArchiveIndexCacheEntry>();

  final LinkedHashMap<String, Uint8List> _entryCache =
      LinkedHashMap<String, Uint8List>();
  int _entryCacheBytes = 0;

  int _limitMb = 32;

  int get limitBytes {
    return _limitMb.clamp(8, 256) * 1024 * 1024;
  }

  void setLimitMB(int mb) {
    _limitMb = mb.clamp(8, 256);
    _evictEntriesToLimit();
  }

  // Index cache

  ArchiveIndexCacheEntry? getIndex(String archivePath) {
    final entry = _indexCache.remove(archivePath);
    if (entry == null) return null;
    _indexCache[archivePath] = entry;
    return entry;
  }

  void putIndex(ArchiveIndexCacheEntry entry) {
    _indexCache.remove(entry.archivePath);
    _indexCache[entry.archivePath] = entry;
    while (_indexCache.length > _indexCacheMaxEntries) {
      _indexCache.remove(_indexCache.keys.first);
    }
  }

  void evictIndex(String archivePath) {
    _indexCache.remove(archivePath);
  }

  // Entry bytes cache

  Uint8List? getEntry(String cacheKey) {
    final data = _entryCache.remove(cacheKey);
    if (data == null) return null;
    _entryCache[cacheKey] = data;
    return data;
  }

  void putEntry(String cacheKey, Uint8List data) {
    if (data.length > limitBytes) return;
    final existing = _entryCache.remove(cacheKey);
    if (existing != null) _entryCacheBytes -= existing.length;
    _entryCache[cacheKey] = data;
    _entryCacheBytes += data.length;
    _evictEntriesToLimit();
  }

  void evictAllForArchive(String archivePath) {
    final keysToRemove = _entryCache.keys
        .where((k) => k.startsWith('entry::$archivePath::'))
        .toList();
    for (final key in keysToRemove) {
      final data = _entryCache.remove(key);
      if (data != null) _entryCacheBytes -= data.length;
    }
    _indexCache.remove(archivePath);
  }

  void clearAll() {
    _entryCache.clear();
    _entryCacheBytes = 0;
    _indexCache.clear();
  }

  void _evictEntriesToLimit() {
    while (_entryCacheBytes > limitBytes && _entryCache.isNotEmpty) {
      final key = _entryCache.keys.first;
      final data = _entryCache.remove(key);
      if (data != null) _entryCacheBytes -= data.length;
    }
    if (_entryCacheBytes < 0) _entryCacheBytes = 0;
  }

  static String entryCacheKey(
      String archivePath, String entryPath, int fileSize, int mtimeMillis) {
    return 'entry::$archivePath::${fileSize}_$mtimeMillis::$entryPath';
  }
}
