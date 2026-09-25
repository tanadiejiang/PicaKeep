part of 'local_library.dart';

extension LocalLibrarySettings on LocalLibraryManager {
  String? get configuredOriginalDownloadPath {
    final path = appdata.settings[originalDownloadDirSettingIndex].trim();
    return path.isEmpty ? null : path;
  }

  /// Pixiv 专属下载目录（`settings[152]`）；未设置时返回 `null`。
  ///
  /// 它与 [configuredOriginalDownloadPath] **对称**：都是一个"额外的下载根"，
  /// 各自成为一个 `LocalLibrarySourceKind.currentDownload` 源，
  /// 从而让"已下载列表"能列出落在里面的内容。
  ///
  /// ⚠️ 这是读取侧的一半；写入侧在 `online_download_manager._runPixivTask`
  /// （按同一个设置决定 Pixiv 的落盘根）。两边少接任一处，症状都是
  /// **"下载成功、但列表里看不到"**。
  String? get configuredPixivDownloadPath {
    final path = appdata.settings[pixivDownloadDirSettingIndex].trim();
    return path.isEmpty ? null : path;
  }

  List<String> get configuredLocalComicPaths =>
      decodeLocalComicPathList(appdata.settings[localComicPathsSettingIndex]);

  String get localAlbumImageSort => normalizeLocalAlbumImageSort(
      appdata.settings[localAlbumImageSortSettingIndex]);

  String get localLibraryListSort => normalizeLocalLibraryListSort(
      appdata.settings[localLibraryListSortSettingIndex]);

  bool get showAllDatabaseRecords =>
      appdata.settings[localLibraryShowAllDatabaseRecordsSettingIndex] == '1';

  Future<void> setConfiguredLocalComicPaths(List<String> paths) async {
    appdata.settings[localComicPathsSettingIndex] =
        encodeLocalComicPathList(paths);
    await appdata.updateSettings();
  }

  Future<void> addConfiguredLocalComicPath(String path) async {
    final normalized = path.trim();
    if (normalized.isEmpty) {
      return;
    }
    final paths = configuredLocalComicPaths.toList();
    if (!paths.contains(normalized)) {
      paths.add(normalized);
      await setConfiguredLocalComicPaths(paths);
    }
  }

  Future<void> removeConfiguredLocalComicPath(String path) async {
    final paths = configuredLocalComicPaths.where((e) => e != path).toList();
    await setConfiguredLocalComicPaths(paths);
  }

  bool isCollectionShellEnabledForLocalComicPath(String path) {
    return isLocalCollectionShellPathEnabled(
      path,
      appdata.settings[localLibraryCollectionShellSettingIndex],
    );
  }

  Future<void> setCollectionShellEnabledForLocalComicPath(
    String path,
    bool enabled,
  ) async {
    appdata.settings[localLibraryCollectionShellSettingIndex] =
        setLocalCollectionShellPathEnabled(
      appdata.settings[localLibraryCollectionShellSettingIndex],
      path,
      enabled,
    );
    await appdata.updateSettings();
    _loaded = false;
  }

  /// 清除所有源缓存中的"无封面"标记，使下次加载重新探测。
  /// 在用户主动下拉刷新时调用——可能手动添加了封面文件到漫画目录。
  Future<void> invalidateNoCoverSentinels() async {
    for (final source in await _buildSources()) {
      if (!source.isManagedDownload) {
        continue;
      }
      final cache = await _loadSourceCache(source);
      if (cache.clearNoCoverSentinels()) {
        await cache.save();
      }
    }
  }
}
