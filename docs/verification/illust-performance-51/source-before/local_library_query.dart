part of 'local_library.dart';

extension LocalLibraryQuery on LocalLibraryManager {
  Future<void> refresh() {
    final activeTask = _refreshTask;
    if (activeTask != null) {
      return activeTask;
    }

    late final Future<void> task;
    task = _refreshInternal().whenComplete(() {
      if (identical(_refreshTask, task)) {
        _refreshTask = null;
      }
    });
    _refreshTask = task;
    return task;
  }

  Future<void> ensureLoaded() async {
    if (_loaded) {
      return;
    }
    await refresh();
  }

  Future<List<LocalLibrarySource>> getSources() async {
    return List<LocalLibrarySource>.from(await _buildSources());
  }

  Future<List<LocalLibraryComicItem>> getManagedDownloads() {
    final activeTask = _managedDownloadsLoadTask;
    if (activeTask != null) {
      return activeTask;
    }

    late final Future<List<LocalLibraryComicItem>> task;
    task = _loadManagedDownloadsInternal().whenComplete(() {
      if (identical(_managedDownloadsLoadTask, task)) {
        _managedDownloadsLoadTask = null;
      }
    });
    _managedDownloadsLoadTask = task;
    return task;
  }

  Future<int> get downloadCount async {
    await ensureLoaded();
    return cachedDownloadCount;
  }

  int get cachedDownloadCount =>
      _items.where((item) => item.isManagedDownloadItem).length;

  int get cachedAlbumCount => _items.where((item) => item.isAlbum).length;

  /// 图集列表页每个源卡片点进去展示的就是 `entry.children`，此处对所有作为
  /// 卡片出现的源（`supportsCollectionShell`）的子项数求和，使「我」页面计数
  /// 与列表卡片子项之和一致（例如 `.qq` 合集源算它的 8 个子项，而非算 1 个源）。
  int get cachedAlbumChildrenCount => _storageEntries
      .where((entry) => entry.source.supportsCollectionShell)
      .fold<int>(0, (sum, entry) => sum + entry.comicCount);

  int get cachedVisibleCount {
    final albumOnly =
        appdata.settings[localLibraryAlbumOnlySettingIndex] != '0';
    return albumOnly ? cachedAlbumChildrenCount : cachedCount;
  }

  Future<List<LocalLibraryStorageEntry>> getStorageEntries() async {
    await ensureLoaded();
    return List<LocalLibraryStorageEntry>.from(_storageEntries);
  }

  LocalLibraryComicItem? findCachedById(String id) {
    return _idIndex[id] ?? _aliasIndex[id];
  }

  LocalLibraryComicItem? findCachedByCandidates(Iterable<String> candidates) {
    for (final candidate in candidates) {
      final normalized = candidate.trim();
      if (normalized.isEmpty) {
        continue;
      }
      final item = _idIndex[normalized] ?? _aliasIndex[normalized];
      if (item != null) {
        return item;
      }
    }
    return null;
  }

  /// 立即从内存缓存中驱逐与 [candidates] 匹配的条目。
  ///
  /// 用于删除操作完成后立即使旧缓存失效，避免 [checkDownloadedState]
  /// 在 [LocalLibraryManager.refresh] 完成前读到旧数据。
  /// 下一次 [refresh] 或 [ensureLoaded] 后缓存会被完整重建，无需额外处理。
  void evictCachedCandidates(Iterable<String> candidates) {
    LocalLibraryComicItem? found;
    for (final candidate in candidates) {
      final normalized = candidate.trim();
      if (normalized.isEmpty) continue;
      found = _idIndex[normalized] ?? _aliasIndex[normalized];
      if (found != null) break;
    }
    if (found == null) return;
    _items.remove(found);
    _idIndex.remove(found.id);
    for (final alias in found.aliases) {
      _aliasIndex.remove(alias);
    }
  }

  Future<LocalLibraryComicItem?> findById(String id) async {
    await ensureLoaded();
    return findCachedById(id);
  }

  Future<LocalLibraryComicItem?> findByCandidates(
      Iterable<String> candidates) async {
    await ensureLoaded();
    return findCachedByCandidates(candidates);
  }

  Future<int> get totalCount async => (await getAll()).length;

  int get cachedCount => _items.length;

  bool get isLoaded => _loaded;
}
