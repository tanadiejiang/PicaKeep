import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Row;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

import '../base.dart';
import 'download_model.dart';
import 'local_data_source.dart';
import 'local_favorites.dart';
import 'local_library_settings.dart';
import 'local_trash_store.dart';

const _localTrashDirectoryName = '.picakeep_trash';

enum LocalLibrarySourceKind {
  currentDownload,
  originalDownload,
  customPath,
}

enum ManagedSourceAccessRequirement {
  ok,
  shizukuPermissionMissing,
  rootRequired,
}

class LocalLibrarySource {
  const LocalLibrarySource({
    required this.id,
    required this.title,
    required this.path,
    required this.kind,
  });

  final String id;
  final String title;
  final String path;
  final LocalLibrarySourceKind kind;

  bool get isCustom => kind == LocalLibrarySourceKind.customPath;

  bool get isManagedDownload => !isCustom;
}

class LocalLibraryStorageEntry {
  const LocalLibraryStorageEntry({
    required this.id,
    required this.title,
    required this.path,
    required this.sizeMb,
    required this.comicCount,
    required this.children,
    required this.source,
  });

  final String id;
  final String title;
  final String path;
  final double sizeMb;
  final int comicCount;
  final List<LocalLibraryStorageChildEntry> children;
  final LocalLibrarySource source;
}

class LocalLibraryStorageChildEntry {
  const LocalLibraryStorageChildEntry({
    required this.id,
    required this.title,
    required this.path,
    required this.sizeMb,
    required this.sourceDisplayName,
  });

  final String id;
  final String title;
  final String path;
  final double sizeMb;
  final String sourceDisplayName;
}

class _LocalDirectoryEntry {
  const _LocalDirectoryEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
  });

  final String name;
  final String path;
  final bool isDirectory;
}

class _LocalLibraryCachedItem {
  const _LocalLibraryCachedItem({
    this.coverPath,
    this.episodeFiles = const <int, List<String>>{},
  });

  final String? coverPath;
  final Map<int, List<String>> episodeFiles;

  factory _LocalLibraryCachedItem.fromJson(Map<String, dynamic> json) {
    final episodes = <int, List<String>>{};
    final rawEpisodes = json['episodeFiles'];
    if (rawEpisodes is Map) {
      for (final entry in rawEpisodes.entries) {
        final key = int.tryParse(entry.key.toString());
        final value = entry.value;
        if (key != null && value is List) {
          episodes[key] = value.map((e) => e.toString()).toList();
        }
      }
    }
    final cover = json['coverPath']?.toString().trim();
    return _LocalLibraryCachedItem(
      coverPath: cover == null || cover.isEmpty ? null : cover,
      episodeFiles: episodes,
    );
  }

  Map<String, dynamic> toJson() => {
        'coverPath': coverPath,
        'episodeFiles': {
          for (final entry in episodeFiles.entries)
            entry.key.toString(): entry.value,
        },
      };
}

class _LocalLibrarySourceCache {
  _LocalLibrarySourceCache(this.file, this.items);

  final File file;
  final Map<String, _LocalLibraryCachedItem> items;

  _LocalLibraryCachedItem? itemFor(String rawId, String directoryPath) {
    return items[_cacheItemKey(rawId, directoryPath)];
  }

  void setItem(
    String rawId,
    String directoryPath,
    _LocalLibraryCachedItem item,
  ) {
    items[_cacheItemKey(rawId, directoryPath)] = item;
  }

  Future<void> save() async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'version': 1,
          'items': {
            for (final entry in items.entries) entry.key: entry.value.toJson(),
          },
        }),
        flush: true,
      );
    } catch (_) {}
  }

  static String _cacheItemKey(String rawId, String directoryPath) {
    final id = rawId.trim();
    final path = directoryPath.trim();
    if (id.isNotEmpty && path.isNotEmpty) {
      return 'id::$id::path::$path';
    }
    if (id.isNotEmpty) {
      return 'id::$id';
    }
    return 'path::$path';
  }
}

class LocalLibraryComicItem extends DownloadedItem {
  LocalLibraryComicItem({
    required this.itemId,
    required this.originalId,
    required DownloadType type,
    required String name,
    required String subTitle,
    required List<String> tags,
    required String sourceDisplayName,
    required String fileSystemPath,
    required this.episodeFiles,
    required List<int> downloadedEps,
    required List<String> eps,
    required String? localCoverPath,
    required bool localStorageExists,
    required bool canDelete,
    required this.aliases,
    this.favoriteTarget,
    this.comicSize,
    this.sourceDbPath,
    this.sourceDbId,
    this.sourceDirectory,
    this.sourceDbRowId,
    this.sourceRowJson,
    this.sourceRowTimeMillis,
  })  : _type = type,
        _name = name,
        _subTitle = subTitle,
        _tags = tags,
        _sourceDisplayName = sourceDisplayName,
        _fileSystemPath = fileSystemPath,
        _downloadedEps = downloadedEps,
        _eps = eps,
        _localCoverPath = localCoverPath,
        _localStorageExists = localStorageExists,
        _canDelete = canDelete;

  final String itemId;
  final String originalId;
  final DownloadType _type;
  final String _name;
  final String _subTitle;
  final List<String> _tags;
  final String _sourceDisplayName;
  final String _fileSystemPath;
  final Map<int, List<String>> episodeFiles;
  final List<int> _downloadedEps;
  final List<String> _eps;
  final String? _localCoverPath;
  final bool _localStorageExists;
  final bool _canDelete;
  final List<String> aliases;
  final String? favoriteTarget;
  final String? sourceDbPath;
  final String? sourceDbId;
  final String? sourceDirectory;
  final int? sourceDbRowId;
  final String? sourceRowJson;
  final int? sourceRowTimeMillis;

  @override
  double? comicSize;

  @override
  DownloadType get type => _type;

  @override
  String get name => _name;

  @override
  List<String> get eps => _eps;

  @override
  List<int> get downloadedEps => _downloadedEps;

  @override
  String get id => itemId;

  @override
  String get subTitle => _subTitle;

  @override
  List<String> get tags => _tags;

  @override
  String get sourceDisplayName => _sourceDisplayName;

  @override
  String? get localCoverPath => _localCoverPath;

  @override
  String? get fileSystemPath => _fileSystemPath;

  bool get localStorageExists => _localStorageExists;

  @override
  bool get canDelete => _canDelete;

  bool get hasMultipleEpisodes =>
      episodeFiles.length > 1 ||
      (!episodeFiles.containsKey(0) && episodeFiles.containsKey(1)) ||
      _eps.length > 1 ||
      _downloadedEps.length > 1;

  bool get isAlbum =>
      itemId.startsWith('local_album::') || sourceDisplayName == '图集';

  bool get isManagedDownloadItem =>
      itemId.startsWith('local_download::current_download::') ||
      itemId.startsWith('local_download::original_download::');

  @override
  Map<String, dynamic> toJson() => {
        'itemId': itemId,
        'originalId': originalId,
        'type': type.name,
        'name': name,
        'subTitle': subTitle,
        'tags': tags,
        'sourceDisplayName': sourceDisplayName,
        'fileSystemPath': fileSystemPath,
        'episodeFiles': {
          for (final entry in episodeFiles.entries)
            entry.key.toString(): entry.value,
        },
        'downloadedEps': downloadedEps,
        'eps': eps,
        'localCoverPath': localCoverPath,
        'localStorageExists': localStorageExists,
        'favoriteTarget': favoriteTarget,
        'sourceDbPath': sourceDbPath,
        'sourceDbId': sourceDbId,
        'sourceDirectory': sourceDirectory,
        'sourceDbRowId': sourceDbRowId,
        'sourceRowJson': sourceRowJson,
        'sourceRowTimeMillis': sourceRowTimeMillis,
        'comicSize': comicSize,
      };

  @override
  Widget createReadingPage({int? ep, int? page}) {
    LocalLibraryManager.pauseBackgroundCoverCache();
    final hasEp = hasMultipleEpisodes;
    final epsMap = hasEp
        ? {
            for (int i = 0; i < _eps.length; i++) '${i + 1}': _eps[i],
          }
        : null;
    final data = LocalPathReadingData(
      title: name,
      id: id,
      downloadId: id,
      sourceKey: LocalLibraryManager._sourceKeyForDownloadType(type),
      directoryPath: fileSystemPath ?? '',
      hasEp: hasEp,
      comicType: comicTypeForDownloadType(type),
      eps: epsMap,
      favoriteType: LocalLibraryManager._favoriteTypeForDownloadType(type),
      episodeFiles: episodeFiles,
      downloadedEpisodeIndexes: downloadedEps,
      supportsImageSort: isAlbum,
    );
    return ComicReadingPage(data, page ?? 1, ep ?? (hasEp ? 1 : 0));
  }
}

class LocalPathReadingData extends ReadingData {
  LocalPathReadingData({
    required this.title,
    required this.id,
    required this.downloadId,
    required this.sourceKey,
    required this.directoryPath,
    required this.hasEp,
    required this.comicType,
    this.eps,
    this.favoriteType = const FavoriteType(0),
    required Map<int, List<String>> episodeFiles,
    required Iterable<int> downloadedEpisodeIndexes,
    this.supportsImageSort = false,
  }) : _episodeFiles = {
          for (final entry in episodeFiles.entries)
            entry.key: List<String>.from(entry.value),
        } {
    downloadedEps = List<int>.from(downloadedEpisodeIndexes);
  }

  final Map<int, List<String>> _episodeFiles;

  final String directoryPath;

  final bool supportsImageSort;

  @override
  bool get supportsLocalImageSort => supportsImageSort;

  @override
  String get localImageSortMode =>
      LocalLibraryManager.instance.localAlbumImageSort;

  @override
  Future<void> setLocalImageSortMode(String value) async {
    appdata.settings[localAlbumImageSortSettingIndex] =
        normalizeLocalAlbumImageSort(value);
    await appdata.updateSettings();
  }

  @override
  final String title;

  @override
  final String id;

  @override
  final String downloadId;

  @override
  final String sourceKey;

  @override
  final bool hasEp;

  @override
  final Map<String, String>? eps;

  @override
  final FavoriteType favoriteType;

  @override
  final ComicType comicType;

  @override
  bool get downloaded => false;

  @override
  Future<List<String>> loadEp(int ep) async {
    final key = hasEp ? ep : 0;
    if (!_episodeFiles.containsKey(key) && directoryPath.isNotEmpty) {
      _episodeFiles[key] =
          await LocalLibraryManager._buildDownloadedEpisodeFilesForEp(
        directoryPath,
        key,
      );
    }
    final files = List<String>.from(_episodeFiles[key] ?? const <String>[]);
    if (!supportsImageSort) {
      return files;
    }
    return await LocalLibraryManager._sortImagePathsAsync(
      files,
      sortMode: localImageSortMode,
    );
  }

  @override
  Stream<List<int>> loadImage(int ep, int page, String url) async* {
    final bytes = await LocalLibraryManager._readFileBytes(url);
    yield bytes ?? const <int>[];
  }

  @override
  ImageProvider createImageProvider(int ep, int page, String url) {
    return LocalLibraryManager.instance.imageProviderForLocalPath(url);
  }

  @override
  String buildImageKey(int ep, int page, String url) => url;

  @override
  Future<List<String>> loadEpNetwork(int ep) async {
    return loadEp(ep);
  }

  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) async* {
    yield* loadImage(ep, page, url);
  }
}

class LocalLibraryManager {
  static final LocalLibraryManager instance = LocalLibraryManager._();
  static const MethodChannel _storageAccessChannel =
      MethodChannel('lingxue.picakeep/storage_access');

  factory LocalLibraryManager() => instance;

  LocalLibraryManager._();

  bool _loaded = false;
  Future<void>? _refreshTask;
  Future<List<LocalLibraryComicItem>>? _managedDownloadsLoadTask;
  Future<void> _backgroundCacheTask = Future<void>.value();
  final List<LocalLibraryComicItem> _items = [];
  final List<LocalLibraryStorageEntry> _storageEntries = [];
  final Map<String, LocalLibraryComicItem> _idIndex = {};
  final Map<String, LocalLibraryComicItem> _aliasIndex = {};

  Future<String> resolveCurrentDownloadPath() async {
    final configured = appdata.settings[22].trim();
    if (configured.isNotEmpty) {
      return configured;
    }
    final support = await getApplicationSupportDirectory();
    return _joinPath(support.path, 'download');
  }

  Future<bool> shouldUseShizukuFallbackForCurrentDownloads() async {
    final currentPath = await resolveCurrentDownloadPath();
    final enabled = await _shouldUsePrivilegedFallbackForDirectory(currentPath);
    print(
      '[PicaKeep][Privileged] current downloads path=$currentPath fallback=$enabled',
    );
    return enabled;
  }

  Future<bool> shouldBypassDirectDownloadManagerForCurrentDownloads() async {
    final mode = normalizeManagedDataSourceMode(
      appdata.settings[managedDataSourceModeSettingIndex],
    );
    if (mode == managedDataSourceModeOriginalOnly) {
      return false;
    }
    return shouldUseShizukuFallbackForCurrentDownloads();
  }

  Future<bool> shouldUseDirectCurrentDownloadManager() async {
    final mode = normalizeManagedDataSourceMode(
      appdata.settings[managedDataSourceModeSettingIndex],
    );
    if (mode == managedDataSourceModeOriginalOnly) {
      return false;
    }
    return !await shouldUseShizukuFallbackForCurrentDownloads();
  }

  Future<bool> shouldUsePrivilegedManagedDownloadHandling() async {
    final sources = await _buildSources();
    for (final source in sources) {
      if (!source.isManagedDownload) {
        continue;
      }
      if (await _shouldUsePrivilegedFallbackForDirectory(source.path)) {
        return true;
      }
    }
    return false;
  }

  Future<ManagedSourceAccessRequirement> getManagedSourceAccessRequirement(
      String mode,
      {bool refreshAccess = false}) async {
    final normalizedMode = normalizeManagedDataSourceMode(mode);
    final currentPath = await resolveCurrentDownloadPath();
    final originalPath = configuredOriginalDownloadPath;
    final paths = <String>[
      switch (normalizedMode) {
        managedDataSourceModeCurrentOnly => currentPath,
        managedDataSourceModeOriginalOnly => originalPath ?? '',
        managedDataSourceModeCurrentAndOriginal => currentPath,
        _ => currentPath,
      },
      if (normalizedMode == managedDataSourceModeCurrentAndOriginal &&
          originalPath != null &&
          originalPath.isNotEmpty &&
          originalPath != currentPath)
        originalPath,
    ].map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();

    if (paths.isEmpty) {
      return ManagedSourceAccessRequirement.ok;
    }

    final rootEnabled = normalizeAndroidRootMode(
            appdata.settings[androidRootModeSettingIndex]) ==
        '1';
    final shizukuEnabled = normalizeAndroidShizukuMode(
          appdata.settings[androidShizukuModeSettingIndex],
        ) ==
        '1';
    final rootGranted =
        rootEnabled ? await _hasRootAccess(forceRefresh: refreshAccess) : false;
    final shizukuGranted = shizukuEnabled
        ? await _hasShizukuPermission(forceRefresh: refreshAccess)
        : false;

    for (final path in paths) {
      if (_canAccessDirectoryWithDartIo(path)) {
        continue;
      }
      if (!Platform.isAndroid) {
        continue;
      }
      if (rootGranted) {
        continue;
      }
      if (!shizukuEnabled || !shizukuGranted) {
        return ManagedSourceAccessRequirement.shizukuPermissionMissing;
      }
      if (await _existsWithShizukuAccess(path)) {
        continue;
      }
      if (_looksLikeRootOnlyPath(path)) {
        return ManagedSourceAccessRequirement.rootRequired;
      }
      return ManagedSourceAccessRequirement.shizukuPermissionMissing;
    }

    return ManagedSourceAccessRequirement.ok;
  }

  Future<List<LocalLibraryComicItem>>
      getCurrentDownloadsWithShizukuFallback() async {
    final source = await _currentDownloadSource();
    if (!await _directoryExists(source.path)) {
      print(
        '[PicaKeep][Privileged] current downloads source missing: ${source.path}',
      );
      return const <LocalLibraryComicItem>[];
    }
    final items = await _loadManagedDownloadSourceMetadata(
      source,
      trustStorageFromDatabase: true,
    );
    print(
      '[PicaKeep][Privileged] current downloads loaded ${items.length} items from ${source.path}',
    );
    _sortItems(items, localLibraryListSort);
    return items;
  }

  Future<int> refreshCurrentDownloadsWithShizukuFallback() async {
    return (await getCurrentDownloadsWithShizukuFallback()).length;
  }

  Future<Directory> _localCacheRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(_joinPath(support.path, 'local_library_cache'));
  }

  Future<LocalLibrarySource> _currentDownloadSource() async {
    return LocalLibrarySource(
      id: 'current_download',
      title: '本应用下载目录',
      path: await resolveCurrentDownloadPath(),
      kind: LocalLibrarySourceKind.currentDownload,
    );
  }

  Future<_LocalLibrarySourceCache> _loadSourceCache(
    LocalLibrarySource source,
  ) async {
    final root = await _localCacheRoot();
    final file =
        File(_joinPath(root.path, '${_safeCacheName(source.id)}.json'));
    if (!file.existsSync()) {
      return _LocalLibrarySourceCache(
          file, <String, _LocalLibraryCachedItem>{});
    }
    try {
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final rawItems = data['items'];
      final items = <String, _LocalLibraryCachedItem>{};
      if (rawItems is Map) {
        for (final entry in rawItems.entries) {
          final value = entry.value;
          if (value is Map) {
            items[entry.key.toString()] = _LocalLibraryCachedItem.fromJson(
              Map<String, dynamic>.from(value),
            );
          }
        }
      }
      return _LocalLibrarySourceCache(file, items);
    } catch (_) {
      return _LocalLibrarySourceCache(
          file, <String, _LocalLibraryCachedItem>{});
    }
  }

  Future<File> _writeDatabaseSnapshot(
    LocalLibrarySource source,
    Uint8List dbBytes,
  ) async {
    final root = await _localCacheRoot();
    final dbDir = Directory(_joinPath(root.path, 'db'));
    await dbDir.create(recursive: true);
    final file = File(_joinPath(dbDir.path, '${_safeCacheName(source.id)}.db'));
    await file.writeAsBytes(dbBytes, flush: true);
    return file;
  }

  void _warmManagedDownloadCache(
    LocalLibrarySource source,
    _LocalLibrarySourceCache cache,
    List<LocalLibraryComicItem> items, {
    required int eagerCount,
  }) {
    Future<void> run() async {
      var changed = false;
      for (int i = 0; i < items.length; i++) {
        if (_isCoverCachePaused) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          i--;
          continue;
        }
        final item = items[i];
        final rawId = item.originalId;
        final dirPath = item.fileSystemPath?.trim() ?? '';
        if (dirPath.isEmpty || !item.localStorageExists) {
          continue;
        }
        final existing = cache.itemFor(rawId, dirPath);
        if (await _hasUsableManagedCoverCache(
            item, existing?.coverPath?.trim())) {
          continue;
        }
        await Future<void>.delayed(
          Duration(milliseconds: i < eagerCount ? 1500 : 5000),
        );
        if (_isCoverCachePaused) {
          i--;
          continue;
        }
        final coverPath = await _resolveCoverPathForCacheOnly(item, existing);
        if (coverPath == null || coverPath.trim().isEmpty) {
          continue;
        }
        cache.setItem(
          rawId,
          dirPath,
          _LocalLibraryCachedItem(
            coverPath: coverPath,
            episodeFiles: existing?.episodeFiles ?? const <int, List<String>>{},
          ),
        );
        changed = true;
        if (i % 8 == 0) {
          await cache.save();
          changed = false;
        }
      }
      if (changed) {
        await cache.save();
      }
    }

    _backgroundCacheTask = _backgroundCacheTask.then((_) => run());
  }

  Future<String?> _resolveNamedCoverPath(String dirPath) async {
    for (final candidate in const [
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
      'cover.webp',
    ]) {
      final path = _joinPath(dirPath, candidate);
      if (await _fileExists(path)) {
        return path;
      }
    }
    return null;
  }

  static DateTime? _coverCachePausedUntil;

  static bool get _isCoverCachePaused {
    final until = _coverCachePausedUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  static void pauseBackgroundCoverCache({
    Duration duration = const Duration(minutes: 30),
  }) {
    _coverCachePausedUntil = DateTime.now().add(duration);
  }

  static void resumeBackgroundCoverCache() {
    _coverCachePausedUntil = null;
  }

  Future<String?> _resolveCoverPathForCacheOnly(
    LocalLibraryComicItem item,
    _LocalLibraryCachedItem? existing,
  ) async {
    if (item.isManagedDownloadItem) {
      return _ensureManagedDownloadCoverCache(
          item, existing?.coverPath?.trim());
    }
    final dirPath = item.fileSystemPath?.trim() ?? '';
    if (dirPath.isEmpty || !item.localStorageExists) {
      return null;
    }
    for (final candidate in const [
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
      'cover.webp',
    ]) {
      final path = _joinPath(dirPath, candidate);
      if (await _fileExists(path)) {
        return path;
      }
    }
    final ep = item.hasMultipleEpisodes ? 1 : 0;
    final files = await _buildDownloadedEpisodeFilesForEp(dirPath, ep);
    if (files.isEmpty) {
      return null;
    }
    return files.first;
  }

  Future<String?> _ensureManagedDownloadCoverCache(
    LocalLibraryComicItem item,
    String? existingCachePath,
  ) async {
    final normalizedExisting = existingCachePath?.trim() ?? '';
    if (await _hasUsableManagedCoverCache(item, normalizedExisting)) {
      return normalizedExisting;
    }
    final sourcePath = await _resolveManagedDownloadSourceCoverPath(item);
    if (sourcePath == null || sourcePath.isEmpty) {
      return null;
    }
    final bytes = await _readFileBytes(sourcePath);
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    final target = await _managedDownloadCoverCacheFile(item, sourcePath);
    try {
      await target.parent.create(recursive: true);
      final temp = File('${target.path}.part');
      await temp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) {
        await target.delete();
      }
      await temp.rename(target.path);
      await _persistManagedDownloadCoverCachePath(item, target.path);
      return target.path;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _hasUsableManagedCoverCache(
    LocalLibraryComicItem item,
    String? coverPath,
  ) async {
    final normalized = coverPath?.trim() ?? '';
    if (normalized.isEmpty || !await _fileExists(normalized)) {
      return false;
    }
    return _isManagedDownloadCoverCachePath(normalized);
  }

  Future<bool> _isManagedDownloadCoverCachePath(String path) async {
    final root = await _localCacheRoot();
    final managedCoverRoot = _joinPath(root.path, 'managed_download_covers')
        .replaceAll('\\', '/')
        .toLowerCase();
    final normalizedPath = path.replaceAll('\\', '/').toLowerCase();
    return normalizedPath.startsWith(managedCoverRoot);
  }

  Future<void> _persistManagedDownloadCoverCachePath(
    LocalLibraryComicItem item,
    String coverPath,
  ) async {
    final sourceId = _managedDownloadSourceIdForItem(item);
    if (sourceId == null) {
      return;
    }
    final cache = await _loadSourceCache(
      LocalLibrarySource(
        id: sourceId,
        title: '',
        path: '',
        kind: sourceId == 'original_download'
            ? LocalLibrarySourceKind.originalDownload
            : LocalLibrarySourceKind.currentDownload,
      ),
    );
    final dirPath = item.fileSystemPath?.trim() ?? '';
    if (dirPath.isEmpty) {
      return;
    }
    final existing = cache.itemFor(item.originalId, dirPath);
    cache.setItem(
      item.originalId,
      dirPath,
      _LocalLibraryCachedItem(
        coverPath: coverPath,
        episodeFiles: existing?.episodeFiles ?? item.episodeFiles,
      ),
    );
    await cache.save();
  }

  String? _managedDownloadSourceIdForItem(LocalLibraryComicItem item) {
    const prefix = 'local_download::';
    final id = item.id;
    if (!id.startsWith(prefix)) {
      return null;
    }
    final remaining = id.substring(prefix.length);
    final separatorIndex = remaining.indexOf('::');
    if (separatorIndex <= 0) {
      return null;
    }
    return remaining.substring(0, separatorIndex);
  }

  Future<String?> _resolveManagedDownloadSourceCoverPath(
    LocalLibraryComicItem item,
  ) async {
    final dirPath = item.fileSystemPath?.trim() ?? '';
    if (dirPath.isEmpty || !item.localStorageExists) {
      return null;
    }
    for (final candidate in const [
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
      'cover.webp',
    ]) {
      final path = _joinPath(dirPath, candidate);
      if (await _fileExists(path)) {
        return path;
      }
    }
    final ep = item.hasMultipleEpisodes ? 1 : 0;
    final files = await _buildDownloadedEpisodeFilesForEp(dirPath, ep);
    if (files.isEmpty) {
      return null;
    }
    return files.first;
  }

  Future<File> _managedDownloadCoverCacheFile(
    LocalLibraryComicItem item,
    String sourcePath,
  ) async {
    final root = await _localCacheRoot();
    final coverDir = Directory(_joinPath(root.path, 'managed_download_covers'));
    final extension = _coverCacheExtensionForPath(sourcePath);
    final dirPath = item.fileSystemPath?.trim() ?? '';
    final key = _managedDownloadCoverCacheKey(item.originalId, dirPath);
    return File(_joinPath(coverDir.path, '$key$extension'));
  }

  String _managedDownloadCoverCacheKey(String rawId, String directoryPath) {
    final composite =
        _LocalLibrarySourceCache._cacheItemKey(rawId, directoryPath);
    return _stableHash(composite);
  }

  String _stableHash(String input) {
    var hash = 1469598103934665603;
    for (final unit in utf8.encode(input)) {
      hash ^= unit;
      hash = (hash * 1099511628211) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16);
  }

  String _coverCacheExtensionForPath(String path) {
    final lower = _basename(path).toLowerCase();
    for (final ext in const ['.jpg', '.jpeg', '.png', '.webp']) {
      if (lower.endsWith(ext)) {
        return ext;
      }
    }
    return '.img';
  }

  String? get configuredOriginalDownloadPath {
    final path = appdata.settings[originalDownloadDirSettingIndex].trim();
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

  Future<void> _refreshInternal() async {
    _loaded = false;
    _items.clear();
    _storageEntries.clear();
    _idIndex.clear();
    _aliasIndex.clear();

    final sources = await _buildSources();
    for (final source in sources) {
      final sourceExists = await _directoryExists(source.path);
      if (!sourceExists) {
        continue;
      }
      final looksLikeDownload = source.isManagedDownload ||
          await _isDownloadDirectoryAsync(source.path);
      if (looksLikeDownload) {
        await _scanDownloadSource(source);
      } else {
        await _scanAlbumSource(source);
      }
    }

    _loaded = true;
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

  Future<List<LocalLibraryComicItem>> getAll() async {
    await ensureLoaded();
    final items = List<LocalLibraryComicItem>.from(_items);
    _sortItems(items, localLibraryListSort);
    return items;
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

  Future<List<LocalLibraryComicItem>> _loadManagedDownloadsInternal() async {
    final items = <LocalLibraryComicItem>[];
    final sources = await _buildSources();
    for (final source in sources.where((source) => source.isManagedDownload)) {
      if (!await _directoryExists(source.path)) {
        continue;
      }
      final trustStorageFromDatabase =
          await _shouldUsePrivilegedFallbackForDirectory(source.path);
      items.addAll(await _loadManagedDownloadSourceMetadata(
        source,
        trustStorageFromDatabase: trustStorageFromDatabase,
      ));
    }
    _sortItems(items, localLibraryListSort);
    return items;
  }

  String coverPathForDisplay(String path) {
    return path;
  }

  ImageProvider<Object> imageProviderForLocalPath(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) {
        return FileImage(file);
      }
    } catch (_) {}
    return StreamImageProvider(
      () async {
        final bytes = await _readFileBytes(path);
        return Stream<List<int>>.value(bytes ?? const <int>[]);
      },
      'local_file::$path',
    );
  }

  Future<String?> resolveCoverPathForItem(LocalLibraryComicItem item) async {
    if (!item.localStorageExists) {
      return null;
    }
    final cached = item.localCoverPath?.trim();
    if (item.isManagedDownloadItem) {
      final managedCached =
          await _ensureManagedDownloadCoverCache(item, cached);
      if (managedCached != null && managedCached.isNotEmpty) {
        return managedCached;
      }
    } else if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    final dirPath = item.fileSystemPath?.trim();
    if (dirPath == null || dirPath.isEmpty) {
      return null;
    }
    final namedCover = await _resolveNamedCoverPath(dirPath);
    if (namedCover != null && namedCover.isNotEmpty) {
      return namedCover;
    }
    for (final files in item.episodeFiles.values) {
      if (files.isNotEmpty) {
        return files.first;
      }
    }
    final flatImages = await _sortedImageFilesForPath(
      dirPath,
      sortMode: localAlbumImageSortNameAsc,
    );
    if (flatImages.isNotEmpty) {
      return flatImages.first;
    }
    return null;
  }

  Future<int> get downloadCount async {
    await ensureLoaded();
    return cachedDownloadCount;
  }

  int get cachedDownloadCount =>
      _items.where((item) => item.isManagedDownloadItem).length;

  int get cachedAlbumCount => _items.where((item) => item.isAlbum).length;

  int get cachedVisibleCount {
    final albumOnly =
        appdata.settings[localLibraryAlbumOnlySettingIndex] != '0';
    return albumOnly ? cachedAlbumCount : cachedCount;
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

  Future<LocalLibraryComicItem?> findById(String id) async {
    await ensureLoaded();
    return findCachedById(id);
  }

  Future<LocalLibraryComicItem?> findByCandidates(
      Iterable<String> candidates) async {
    await ensureLoaded();
    return findCachedByCandidates(candidates);
  }

  Future<int> rescan() async {
    final sources = await _buildSources();
    var count = 0;
    for (final source in sources) {
      final sourceLooksLikeDownload = source.isManagedDownload ||
          await _isDownloadDirectoryAsync(source.path);
      if (!sourceLooksLikeDownload) {
        continue;
      }
      if (!await _directoryExists(source.path)) {
        if (!source.isManagedDownload) {
          continue;
        }
        if (await _shouldUsePrivilegedFallbackForDirectory(source.path)) {
          continue;
        }
        try {
          Directory(source.path).createSync(recursive: true);
        } catch (_) {}
        if (!await _directoryExists(source.path)) {
          continue;
        }
      }
      if (Directory(source.path).existsSync()) {
        count += _rescanManagedDownloadSource(source.path);
      }
    }
    await refresh();
    return count;
  }

  Future<int> get totalCount async => (await getAll()).length;

  int get cachedCount => _items.length;

  bool get isLoaded => _loaded;

  Future<List<LocalLibrarySource>> _buildSources() async {
    final sources = <LocalLibrarySource>[];
    final currentPath = await resolveCurrentDownloadPath();
    final originalPath = configuredOriginalDownloadPath;

    switch (normalizeManagedDataSourceMode(managedDataSourceMode)) {
      case managedDataSourceModeCurrentAndOriginal:
        sources.add(
          LocalLibrarySource(
            id: 'current_download',
            title: '本应用下载目录',
            path: currentPath,
            kind: LocalLibrarySourceKind.currentDownload,
          ),
        );
        if (originalPath != null && originalPath != currentPath) {
          sources.add(
            LocalLibrarySource(
              id: 'original_download',
              title: '原应用下载目录',
              path: originalPath,
              kind: LocalLibrarySourceKind.originalDownload,
            ),
          );
        }
        break;
      case managedDataSourceModeOriginalOnly:
        if (originalPath != null && originalPath.isNotEmpty) {
          sources.add(
            LocalLibrarySource(
              id: 'original_download',
              title: '原应用下载目录',
              path: originalPath,
              kind: LocalLibrarySourceKind.originalDownload,
            ),
          );
        }
        break;
      case managedDataSourceModeCurrentOnly:
      default:
        sources.add(
          LocalLibrarySource(
            id: 'current_download',
            title: '本应用下载目录',
            path: currentPath,
            kind: LocalLibrarySourceKind.currentDownload,
          ),
        );
        break;
    }

    final customPaths = configuredLocalComicPaths;
    for (int i = 0; i < customPaths.length; i++) {
      final path = customPaths[i].trim();
      if (path.isEmpty) {
        continue;
      }
      sources.add(
        LocalLibrarySource(
          id: 'custom_path_$i',
          title: _basename(path),
          path: path,
          kind: LocalLibrarySourceKind.customPath,
        ),
      );
    }

    return sources;
  }

  Future<List<LocalLibraryComicItem>> _loadManagedDownloadSourceMetadata(
    LocalLibrarySource source, {
    bool trustStorageFromDatabase = false,
  }) async {
    final dbPath = _joinPath(source.path, 'download.db');
    final dbBytes = await _readFileBytes(dbPath);
    if (dbBytes == null || dbBytes.isEmpty) {
      return _loadDirectoryOnlyDownloadSourceMetadata(source);
    }

    final cache = await _loadSourceCache(source);
    final hiddenIndex = await LocalTrashStore.instance.hiddenIndex();
    final sourceDirectoryNames = (await _listDirectoryEntries(source.path))
        .where((entry) => entry.isDirectory)
        .where((entry) => entry.name != _localTrashDirectoryName)
        .map((entry) => entry.name.toLowerCase())
        .toSet();
    final openDbPath = (await _writeDatabaseSnapshot(source, dbBytes)).path;

    final items = <LocalLibraryComicItem>[];
    try {
      final db = sqlite3.open(openDbPath);
      try {
        final rows = db
            .select(
              'select rowid as __rowid__, * from download order by time desc',
            )
            .toList()
          ..sort((a, b) {
            final score = _downloadRowPriority(
              (b['id'] as String? ?? '').trim(),
              (b['directory'] as String? ?? '').trim(),
            ).compareTo(_downloadRowPriority(
              (a['id'] as String? ?? '').trim(),
              (a['directory'] as String? ?? '').trim(),
            ));
            if (score != 0) {
              return score;
            }
            return ((b['time'] as int?) ?? 0)
                .compareTo((a['time'] as int?) ?? 0);
          });
        final seenDirectories = <String>{};

        for (final row in rows) {
          try {
            final rawId = (row['id'] as String? ?? '').trim();
            final jsonText = row['json'] as String? ?? '{}';
            final timeValue = row['time'] as int? ?? 0;
            final rawDirectory = (row['directory'] as String? ?? '').trim();
            final baseItem = _parseDownloadedItem(
                  rawId,
                  jsonText,
                  DateTime.fromMillisecondsSinceEpoch(timeValue),
                  rawDirectory,
                ) ??
                _downloadedItemFromDbRow(
                  row,
                  DateTime.fromMillisecondsSinceEpoch(timeValue),
                  rawDirectory,
                );
            if (baseItem == null) {
              continue;
            }

            final itemDirectory = _resolveDownloadItemDirectoryFromMetadata(
              source.path,
              rawId,
              rawDirectory,
              baseItem,
            );
            final localItemId = 'local_download::${source.id}::$rawId';
            if (hiddenIndex.matchesManagedDownload(
              itemId: localItemId,
              sourceDbPath: dbPath,
              sourceDbId: rawId,
              sourceDirectory:
                  rawDirectory.isNotEmpty ? rawDirectory : itemDirectory,
              originalPath: itemDirectory,
            )) {
              continue;
            }
            final dedupeKey = itemDirectory.toLowerCase();
            if (!seenDirectories.add(dedupeKey)) {
              continue;
            }

            final localType =
                _effectiveDownloadTypeForLocalItem(baseItem, rawId);
            final eps = baseItem.eps.isNotEmpty
                ? List<String>.from(baseItem.eps)
                : _buildLocalEpisodeNames(baseItem.downloadedEps.length);
            final downloadedEps = baseItem.downloadedEps.isNotEmpty
                ? List<int>.from(baseItem.downloadedEps)
                : List<int>.generate(eps.length, (index) => index);
            final cachedItem = cache.itemFor(rawId, itemDirectory);
            final localStorageExists = trustStorageFromDatabase
                ? true
                : await _managedDownloadDirectoryExists(
                    source.path,
                    itemDirectory,
                    sourceDirectoryNames,
                  );
            if (!localStorageExists && !showAllDatabaseRecords) {
              continue;
            }
            final item = LocalLibraryComicItem(
              itemId: localItemId,
              originalId: rawId,
              type: localType,
              name: _metadataTitleForDownloadedRow(row, baseItem),
              subTitle:
                  _metadataAuthorForDownloadedRow(row, jsonText, baseItem),
              tags: _metadataTagsForDownloadedRow(row, jsonText, baseItem),
              sourceDisplayName:
                  _displayNameForDownloaded(baseItem, rawId, localType),
              fileSystemPath: itemDirectory,
              episodeFiles:
                  cachedItem?.episodeFiles ?? const <int, List<String>>{},
              downloadedEps: downloadedEps,
              eps: eps,
              localCoverPath: localStorageExists ? cachedItem?.coverPath : null,
              localStorageExists: localStorageExists,
              canDelete: false,
              aliases: [rawId, itemDirectory],
              favoriteTarget: _favoriteTargetForDownloaded(baseItem, rawId),
              comicSize: baseItem.comicSize,
              sourceDbPath: dbPath,
              sourceDbId: rawId,
              sourceDirectory:
                  rawDirectory.isNotEmpty ? rawDirectory : itemDirectory,
              sourceDbRowId: (row['__rowid__'] as int?) ?? 0,
              sourceRowJson: jsonText,
              sourceRowTimeMillis: timeValue,
            )..time = baseItem.time;
            items.add(item);
          } catch (e) {
            print(
                '[PicaKeep] Skip invalid download row for ${source.path}: $e');
          }
        }
      } finally {
        db.dispose();
      }
    } catch (e) {
      print('[PicaKeep] Failed to load download.db for ${source.path}: $e');
      return _loadDirectoryOnlyDownloadSourceMetadata(source);
    }
    if (items.isEmpty && trustStorageFromDatabase) {
      return _loadDirectoryOnlyDownloadSourceMetadata(source);
    }
    _warmManagedDownloadCache(source, cache, items, eagerCount: 24);
    return items;
  }

  Future<List<LocalLibraryComicItem>> _loadDirectoryOnlyDownloadSourceMetadata(
    LocalLibrarySource source,
  ) async {
    if (await _shouldTreatAsSingleAlbumSource(source.path)) {
      final item = await _buildSingleAlbumItem(source);
      if (item == null) {
        return const <LocalLibraryComicItem>[];
      }
      return [item];
    }

    final entries = await _listDirectoryEntries(source.path);
    final hiddenIndex = await LocalTrashStore.instance.hiddenIndex();
    final items = <LocalLibraryComicItem>[];
    for (final entry in entries.where((entry) => entry.isDirectory)) {
      if (entry.name == _localTrashDirectoryName ||
          hiddenIndex.matchesPath(entry.path)) {
        continue;
      }
      final episodeFiles = await _buildDownloadedEpisodeFiles(entry.path, null);
      if (episodeFiles.isEmpty) {
        continue;
      }
      final orderedEpisodes = episodeFiles.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final coverPath = await _pickCoverPath(
        entry.path,
        orderedEpisodes.isEmpty
            ? const <String>[]
            : orderedEpisodes.first.value,
      );
      final sizeMb = await _computeDirectorySizeMbForPath(entry.path);
      final itemId = 'local_download::${source.id}::${entry.name}';
      final item = LocalLibraryComicItem(
        itemId: itemId,
        originalId: entry.name,
        type: DownloadType.other,
        name: entry.name,
        subTitle: '',
        tags: const <String>[],
        sourceDisplayName: '本地扫描',
        fileSystemPath: entry.path,
        episodeFiles: episodeFiles,
        downloadedEps:
            List<int>.from(orderedEpisodes.map((entry) => entry.key)),
        eps: _buildLocalEpisodeNames(episodeFiles.length),
        localCoverPath: coverPath,
        localStorageExists: true,
        canDelete: false,
        aliases: [entry.name, entry.path],
        comicSize: sizeMb,
      )..time = DateTime.now();
      items.add(item);
    }
    return items;
  }

  Future<void> _scanDownloadSource(LocalLibrarySource source) async {
    final dbPath = _joinPath(source.path, 'download.db');
    final dbBytes = await _readFileBytes(dbPath);
    if (dbBytes == null || dbBytes.isEmpty) {
      await _scanDirectoryOnlyDownloadSource(source);
      return;
    }

    final trustStorageFromDatabase =
        await _shouldUsePrivilegedFallbackForDirectory(source.path);
    final cache = await _loadSourceCache(source);
    final hiddenIndex = await LocalTrashStore.instance.hiddenIndex();
    final sourceDirectoryNames = (await _listDirectoryEntries(source.path))
        .where((entry) => entry.isDirectory)
        .where((entry) => entry.name != _localTrashDirectoryName)
        .map((entry) => entry.name.toLowerCase())
        .toSet();
    final openDbPath = (await _writeDatabaseSnapshot(source, dbBytes)).path;

    final db = sqlite3.open(openDbPath);
    final sourceItems = <LocalLibraryComicItem>[];
    try {
      final rows = db
          .select(
            'select rowid as __rowid__, * from download order by time desc',
          )
          .toList()
        ..sort((a, b) {
          final score = _downloadRowPriority(
            (b['id'] as String? ?? '').trim(),
            (b['directory'] as String? ?? '').trim(),
          ).compareTo(_downloadRowPriority(
            (a['id'] as String? ?? '').trim(),
            (a['directory'] as String? ?? '').trim(),
          ));
          if (score != 0) {
            return score;
          }
          return ((b['time'] as int?) ?? 0).compareTo((a['time'] as int?) ?? 0);
        });
      final children = <LocalLibraryStorageChildEntry>[];
      final seenDirectories = <String>{};
      double totalSize = 0;

      for (final row in rows) {
        final rawId = (row['id'] as String? ?? '').trim();
        final jsonText = row['json'] as String? ?? '{}';
        final timeValue = row['time'] as int? ?? 0;
        final rawDirectory = (row['directory'] as String? ?? '').trim();
        final baseItem = _parseDownloadedItem(
              rawId,
              jsonText,
              DateTime.fromMillisecondsSinceEpoch(timeValue),
              rawDirectory,
            ) ??
            _downloadedItemFromDbRow(
              row,
              DateTime.fromMillisecondsSinceEpoch(timeValue),
              rawDirectory,
            );
        if (baseItem == null) {
          continue;
        }

        final itemDirectory = _resolveDownloadItemDirectoryFromMetadata(
          source.path,
          rawId,
          rawDirectory,
          baseItem,
        );
        final localItemId = 'local_download::${source.id}::$rawId';
        if (hiddenIndex.matchesManagedDownload(
          itemId: localItemId,
          sourceDbPath: dbPath,
          sourceDbId: rawId,
          sourceDirectory:
              rawDirectory.isNotEmpty ? rawDirectory : itemDirectory,
          originalPath: itemDirectory,
        )) {
          continue;
        }
        final dedupeKey = itemDirectory.toLowerCase();
        if (!seenDirectories.add(dedupeKey)) {
          continue;
        }

        final localType = _effectiveDownloadTypeForLocalItem(baseItem, rawId);
        final sizeMb = baseItem.comicSize ?? 0;
        final displayedEps = baseItem.eps.isNotEmpty
            ? List<String>.from(baseItem.eps)
            : const <String>['全部'];
        final downloadedEps = baseItem.downloadedEps.isNotEmpty
            ? List<int>.from(baseItem.downloadedEps)
            : const <int>[0];
        final cachedItem = cache.itemFor(rawId, itemDirectory);
        final localStorageExists = trustStorageFromDatabase
            ? true
            : await _managedDownloadDirectoryExists(
                source.path,
                itemDirectory,
                sourceDirectoryNames,
              );
        if (!localStorageExists && !showAllDatabaseRecords) {
          continue;
        }
        final item = LocalLibraryComicItem(
          itemId: localItemId,
          originalId: rawId,
          type: localType,
          name: _metadataTitleForDownloadedRow(row, baseItem),
          subTitle: _metadataAuthorForDownloadedRow(row, jsonText, baseItem),
          tags: _metadataTagsForDownloadedRow(row, jsonText, baseItem),
          sourceDisplayName:
              _displayNameForDownloaded(baseItem, rawId, localType),
          fileSystemPath: itemDirectory,
          episodeFiles: cachedItem?.episodeFiles ?? const <int, List<String>>{},
          downloadedEps: downloadedEps,
          eps: displayedEps,
          localCoverPath: localStorageExists ? cachedItem?.coverPath : null,
          localStorageExists: localStorageExists,
          canDelete: false,
          aliases: [rawId, itemDirectory],
          favoriteTarget: _favoriteTargetForDownloaded(baseItem, rawId),
          comicSize: sizeMb,
          sourceDbPath: dbPath,
          sourceDbId: rawId,
          sourceDirectory:
              rawDirectory.isNotEmpty ? rawDirectory : itemDirectory,
          sourceDbRowId: (row['__rowid__'] as int?) ?? 0,
          sourceRowJson: jsonText,
          sourceRowTimeMillis: timeValue,
        )..time = baseItem.time;

        _indexItem(item);
        _items.add(item);
        sourceItems.add(item);
        totalSize += sizeMb;
        children.add(
          LocalLibraryStorageChildEntry(
            id: item.id,
            title: item.name,
            path: itemDirectory,
            sizeMb: sizeMb,
            sourceDisplayName: item.sourceDisplayName,
          ),
        );
      }

      _storageEntries.add(
        LocalLibraryStorageEntry(
          id: source.id,
          title: source.title,
          path: source.path,
          sizeMb: totalSize,
          comicCount: children.length,
          children: children,
          source: source,
        ),
      );
    } finally {
      db.dispose();
    }
    _warmManagedDownloadCache(source, cache, sourceItems, eagerCount: 24);
  }

  Future<void> _scanDirectoryOnlyDownloadSource(
    LocalLibrarySource source,
  ) async {
    if (await _shouldTreatAsSingleAlbumSource(source.path)) {
      final item = await _buildSingleAlbumItem(source);
      if (item == null) {
        return;
      }
      _indexItem(item);
      _items.add(item);
      _storageEntries.add(
        LocalLibraryStorageEntry(
          id: source.id,
          title: source.title,
          path: source.path,
          sizeMb: item.comicSize ?? 0,
          comicCount: 1,
          children: [
            LocalLibraryStorageChildEntry(
              id: item.id,
              title: item.name,
              path: source.path,
              sizeMb: item.comicSize ?? 0,
              sourceDisplayName: item.sourceDisplayName,
            ),
          ],
          source: source,
        ),
      );
      return;
    }

    final children = <LocalLibraryStorageChildEntry>[];
    double totalSize = 0;
    final entries = await _listDirectoryEntries(source.path);
    final hiddenIndex = await LocalTrashStore.instance.hiddenIndex();
    for (final entry in entries.where((entry) => entry.isDirectory)) {
      if (entry.name == _localTrashDirectoryName ||
          hiddenIndex.matchesPath(entry.path)) {
        continue;
      }
      final episodeFiles = await _buildDownloadedEpisodeFiles(
        entry.path,
        null,
      );
      if (episodeFiles.isEmpty) {
        continue;
      }
      final sizeMb = await _computeDirectorySizeMbForPath(entry.path);
      final coverPath = await _pickCoverPath(
        entry.path,
        episodeFiles[0] ?? const <String>[],
      );
      final itemId = 'local_download::${source.id}::${entry.name}';
      final item = LocalLibraryComicItem(
        itemId: itemId,
        originalId: entry.name,
        type: DownloadType.other,
        name: entry.name,
        subTitle: '',
        tags: const <String>[],
        sourceDisplayName: '本地扫描',
        fileSystemPath: entry.path,
        episodeFiles: episodeFiles,
        downloadedEps:
            List<int>.generate(episodeFiles.length, (index) => index),
        eps: _buildLocalEpisodeNames(episodeFiles.length),
        localCoverPath: coverPath,
        localStorageExists: true,
        canDelete: false,
        aliases: [entry.name, entry.path],
        comicSize: sizeMb,
      )..time = DateTime.now();
      _indexItem(item);
      _items.add(item);
      totalSize += sizeMb;
      children.add(
        LocalLibraryStorageChildEntry(
          id: item.id,
          title: item.name,
          path: entry.path,
          sizeMb: sizeMb,
          sourceDisplayName: item.sourceDisplayName,
        ),
      );
    }

    _storageEntries.add(
      LocalLibraryStorageEntry(
        id: source.id,
        title: source.title,
        path: source.path,
        sizeMb: totalSize,
        comicCount: children.length,
        children: children,
        source: source,
      ),
    );
  }

  Future<void> _scanAlbumSource(LocalLibrarySource source) async {
    if (!await _directoryExists(source.path)) {
      return;
    }

    if (await _shouldTreatAsSingleAlbumSource(source.path)) {
      await _scanSingleAlbumSource(source);
      return;
    }

    final albumDirs = await _collectLeafAlbumDirectoryPaths(source.path);
    final children = <LocalLibraryStorageChildEntry>[];
    final hiddenIndex = await LocalTrashStore.instance.hiddenIndex();
    double totalSize = 0;

    for (final dirPath in albumDirs) {
      if (hiddenIndex.matchesPath(dirPath)) {
        continue;
      }
      final imageFiles = await _sortedAlbumImagesForPath(dirPath);
      if (imageFiles.isEmpty) {
        continue;
      }
      final coverPath = await _pickCoverPath(dirPath, imageFiles);
      final sizeMb = await _computeDirectorySizeMbForPath(dirPath);
      final item = LocalLibraryComicItem(
        itemId: 'local_album::$dirPath',
        originalId: dirPath,
        type: DownloadType.favorite,
        name: _basename(dirPath),
        subTitle: '',
        tags: const <String>[],
        sourceDisplayName: '图集',
        fileSystemPath: dirPath,
        episodeFiles: {0: imageFiles},
        downloadedEps: const <int>[0],
        eps: const <String>['全部'],
        localCoverPath: coverPath,
        localStorageExists: true,
        canDelete: false,
        aliases: [dirPath],
        comicSize: sizeMb,
      )..time = await _computeAlbumTimeForPath(dirPath, imageFiles);
      _indexItem(item);
      _items.add(item);
      totalSize += sizeMb;
      children.add(
        LocalLibraryStorageChildEntry(
          id: item.id,
          title: item.name,
          path: dirPath,
          sizeMb: sizeMb,
          sourceDisplayName: item.sourceDisplayName,
        ),
      );
    }

    _storageEntries.add(
      LocalLibraryStorageEntry(
        id: source.id,
        title: source.title,
        path: source.path,
        sizeMb: totalSize,
        comicCount: children.length,
        children: children,
        source: source,
      ),
    );
  }

  Future<void> _scanSingleAlbumSource(LocalLibrarySource source) async {
    final hiddenIndex = await LocalTrashStore.instance.hiddenIndex();
    if (hiddenIndex.matchesPath(source.path)) {
      return;
    }
    final episodeFiles = await _buildDownloadedEpisodeFiles(source.path, null);
    if (episodeFiles.isEmpty) {
      return;
    }
    final orderedEntries = episodeFiles.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final orderedImages =
        orderedEntries.expand((entry) => entry.value).toList();
    final coverPath = await _pickCoverPath(
      source.path,
      orderedEntries.isEmpty ? const <String>[] : orderedEntries.first.value,
    );
    final sizeMb = await _computeDirectorySizeMbForPath(source.path);
    final downloadedEps =
        orderedEntries.map((entry) => entry.key).toList(growable: false);
    final item = LocalLibraryComicItem(
      itemId: 'local_album::${source.path}',
      originalId: source.path,
      type: DownloadType.favorite,
      name: _basename(source.path),
      subTitle: '',
      tags: const <String>[],
      sourceDisplayName: '图集',
      fileSystemPath: source.path,
      episodeFiles: episodeFiles,
      downloadedEps: downloadedEps.isEmpty ? const <int>[0] : downloadedEps,
      eps: _buildLocalEpisodeNames(episodeFiles.length),
      localCoverPath: coverPath,
      localStorageExists: true,
      canDelete: false,
      aliases: [source.path],
      comicSize: sizeMb,
    )..time = await _computeAlbumTimeForPath(source.path, orderedImages);
    _indexItem(item);
    _items.add(item);
    _storageEntries.add(
      LocalLibraryStorageEntry(
        id: source.id,
        title: source.title,
        path: source.path,
        sizeMb: sizeMb,
        comicCount: 1,
        children: [
          LocalLibraryStorageChildEntry(
            id: item.id,
            title: item.name,
            path: source.path,
            sizeMb: sizeMb,
            sourceDisplayName: item.sourceDisplayName,
          ),
        ],
        source: source,
      ),
    );
  }

  Future<LocalLibraryComicItem?> _buildSingleAlbumItem(
    LocalLibrarySource source,
  ) async {
    final hiddenIndex = await LocalTrashStore.instance.hiddenIndex();
    if (hiddenIndex.matchesPath(source.path)) {
      return null;
    }
    final episodeFiles = await _buildDownloadedEpisodeFiles(source.path, null);
    if (episodeFiles.isEmpty) {
      return null;
    }
    final orderedEntries = episodeFiles.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final orderedImages =
        orderedEntries.expand((entry) => entry.value).toList();
    final coverPath = await _pickCoverPath(
      source.path,
      orderedEntries.isEmpty ? const <String>[] : orderedEntries.first.value,
    );
    final sizeMb = await _computeDirectorySizeMbForPath(source.path);
    final downloadedEps =
        orderedEntries.map((entry) => entry.key).toList(growable: false);
    return LocalLibraryComicItem(
      itemId: 'local_album::${source.path}',
      originalId: source.path,
      type: DownloadType.favorite,
      name: _basename(source.path),
      subTitle: '',
      tags: const <String>[],
      sourceDisplayName: '图集',
      fileSystemPath: source.path,
      episodeFiles: episodeFiles,
      downloadedEps: downloadedEps.isEmpty ? const <int>[0] : downloadedEps,
      eps: _buildLocalEpisodeNames(episodeFiles.length),
      localCoverPath: coverPath,
      localStorageExists: true,
      canDelete: false,
      aliases: [source.path],
      comicSize: sizeMb,
    )..time = await _computeAlbumTimeForPath(source.path, orderedImages);
  }

  void _indexItem(LocalLibraryComicItem item) {
    _idIndex[item.id] = item;
    for (final alias in item.aliases) {
      final normalized = alias.trim();
      if (normalized.isNotEmpty) {
        _aliasIndex[normalized] = item;
      }
    }
  }

  static bool _isRescannedLocalRecord(DownloadedItem item, String rawId) {
    if (item is CustomDownloadedItem) {
      return false;
    }
    if (item is DownloadedComic) {
      return !RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(rawId.trim());
    }
    return false;
  }

  static DownloadType _effectiveDownloadTypeForLocalItem(
    DownloadedItem item,
    String rawId,
  ) {
    if (_isRescannedLocalRecord(item, rawId)) {
      return DownloadType.other;
    }
    return item.type;
  }

  static String _displayNameForDownloaded(
    DownloadedItem item,
    String rawId,
    DownloadType resolvedType,
  ) {
    if (item is CustomDownloadedItem) {
      return item.sourceDisplayName;
    }
    if (_isRescannedLocalRecord(item, rawId)) {
      return '本地扫描';
    }
    return downloadTypeDisplayName(resolvedType);
  }

  static int _rescanManagedDownloadSource(String rootPath) {
    final root = Directory(rootPath);
    if (!root.existsSync()) {
      return 0;
    }

    final db = sqlite3.open(_joinPath(rootPath, 'download.db'));
    try {
      db.execute('''
        create table if not exists download(
          id text primary key,
          title text,
          subtitle text,
          time int,
          directory text,
          size int,
          json text
        )
      ''');

      final knownIds = db
          .select('select id from download')
          .map((row) => (row['id'] as String? ?? '').trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      final knownDirectories = db
          .select('select directory from download')
          .map((row) => (row['directory'] as String? ?? '').trim())
          .where((directory) => directory.isNotEmpty)
          .toSet();

      var count = 0;
      final hiddenIndex = LocalTrashStore.instance.hiddenIndexSync();
      for (final entry in _safeList(root).whereType<Directory>()) {
        final dirName = _basename(entry.path);
        if (dirName.isEmpty ||
            dirName == _localTrashDirectoryName ||
            hiddenIndex.matchesPath(entry.path) ||
            knownIds.contains(dirName) ||
            knownDirectories.contains(dirName)) {
          continue;
        }

        final subEntries = _safeList(entry);
        final chapterDirs = subEntries
            .whereType<Directory>()
            .where(_containsVisibleImages)
            .toList()
          ..sort(
              (a, b) => _naturalCompare(_basename(a.path), _basename(b.path)));
        final hasFlatImages = subEntries.any(_isVisibleImageFile);
        if (chapterDirs.isEmpty && !hasFlatImages) {
          continue;
        }

        final chapters = <String>[];
        final downloadedChapters = <int>[];
        if (chapterDirs.isNotEmpty) {
          for (final chapterDir in chapterDirs) {
            chapters.add(_basename(chapterDir.path));
            downloadedChapters.add(chapters.length - 1);
          }
        } else {
          chapters.add('第1章');
          downloadedChapters.add(0);
        }

        final comic = DownloadedComic(
          comicId: dirName,
          title: dirName,
          author: '',
          chapters: chapters,
          downloadedChapters: downloadedChapters,
          size: _computeDirectorySizeMb(entry),
          tagList: const <String>[],
        )
          ..time = DateTime.now()
          ..directory = dirName;

        db.execute('''
          insert or replace into download
          values (?,?,?,?,?,?,?)
        ''', [
          comic.id,
          comic.name,
          comic.subTitle,
          comic.time!.millisecondsSinceEpoch,
          dirName,
          comic.comicSize,
          jsonEncode(comic.toJson()),
        ]);
        knownIds.add(dirName);
        knownDirectories.add(dirName);
        count++;
      }

      return count;
    } finally {
      db.dispose();
    }
  }

  static Future<Map<int, List<String>>> _buildDownloadedEpisodeFiles(
    String itemDirectory,
    DownloadedItem? _,
  ) async {
    final entries = await _listDirectoryEntries(itemDirectory);
    final childDirs = entries.where((entry) => entry.isDirectory).toList();
    final chapterDirs = <_LocalDirectoryEntry>[];
    for (final childDir in childDirs) {
      if (await _containsVisibleImagesForPath(childDir.path)) {
        chapterDirs.add(childDir);
      }
    }
    chapterDirs.sort((a, b) => _naturalCompare(a.name, b.name));

    final result = <int, List<String>>{};
    if (chapterDirs.isNotEmpty) {
      for (int i = 0; i < chapterDirs.length; i++) {
        final files = await _sortedImageFilesForPath(
          chapterDirs[i].path,
          sortMode: localAlbumImageSortNameAsc,
        );
        if (files.isNotEmpty) {
          result[i + 1] = files;
        }
      }
      return result;
    }

    final files = await _sortedImageFilesForPath(
      itemDirectory,
      sortMode: localAlbumImageSortNameAsc,
    );
    if (files.isNotEmpty) {
      result[0] = files;
    }
    return result;
  }

  static Future<List<String>> _buildDownloadedEpisodeFilesForEp(
    String itemDirectory,
    int ep,
  ) async {
    final entries = await _listDirectoryEntries(itemDirectory);
    final childDirs = entries.where((entry) => entry.isDirectory).toList()
      ..sort((a, b) => _naturalCompare(a.name, b.name));
    if (childDirs.isNotEmpty) {
      final exact =
          childDirs.where((entry) => entry.name == ep.toString()).toList();
      final target = exact.isNotEmpty
          ? exact.first
          : (ep > 0 && ep <= childDirs.length ? childDirs[ep - 1] : null);
      if (target != null) {
        return _sortedImageFilesForPath(
          target.path,
          sortMode: localAlbumImageSortNameAsc,
        );
      }
      if (childDirs.length == 1 && (ep == 0 || ep == 1)) {
        return _sortedImageFilesForPath(
          childDirs.first.path,
          sortMode: localAlbumImageSortNameAsc,
        );
      }
    }
    if (ep == 0 || ep == 1) {
      return _sortedImageFilesForPath(
        itemDirectory,
        sortMode: localAlbumImageSortNameAsc,
      );
    }
    return const <String>[];
  }

  static List<String> _buildLocalEpisodeNames(int episodeCount) {
    if (episodeCount <= 1) {
      return const <String>['全部'];
    }
    return List<String>.generate(episodeCount, (index) => '第${index + 1}章');
  }

  static Future<List<String>> _collectLeafAlbumDirectoryPaths(
    String rootPath,
  ) async {
    final result = <String>[];

    Future<bool> visit(String path) async {
      if (_basename(path) == _localTrashDirectoryName) {
        return false;
      }
      final children = await _listDirectoryEntries(path);
      final hasImages = children.any(
        (entry) => !entry.isDirectory && _isVisibleImagePath(entry.path),
      );
      var hasAlbumDescendant = false;
      for (final subDir in children.where((entry) => entry.isDirectory)) {
        if (subDir.name == _localTrashDirectoryName) {
          continue;
        }
        if (await visit(subDir.path)) {
          hasAlbumDescendant = true;
        }
      }
      if (hasImages && !hasAlbumDescendant) {
        result.add(path);
        return true;
      }
      return hasImages || hasAlbumDescendant;
    }

    await visit(rootPath);
    result.sort();
    return result;
  }

  static Future<bool> _shouldTreatAsSingleAlbumSource(String rootPath) async {
    final children = await _listDirectoryEntries(rootPath);
    if (children.isEmpty) {
      return false;
    }
    if (children.any(
        (entry) => !entry.isDirectory && _isVisibleImagePath(entry.path))) {
      return true;
    }
    final childDirs =
        children.where((entry) => entry.isDirectory).toList(growable: false);
    if (childDirs.isEmpty) {
      return false;
    }
    final imageBearingDirs = <_LocalDirectoryEntry>[];
    for (final childDir in childDirs) {
      if (await _containsVisibleImagesForPath(childDir.path)) {
        imageBearingDirs.add(childDir);
      }
    }
    if (imageBearingDirs.isEmpty ||
        imageBearingDirs.length != childDirs.length) {
      return false;
    }
    return imageBearingDirs.every(
      (entry) => _looksLikeEpisodeDirectoryName(entry.name),
    );
  }

  static bool _looksLikeEpisodeDirectoryName(String name) {
    final normalized = name.trim().toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }
    return RegExp(r'^\d+$').hasMatch(normalized) ||
        RegExp(r'^0\d+$').hasMatch(normalized) ||
        RegExp(r'^第?\d+[话話章节卷卷集册冊]$').hasMatch(normalized) ||
        normalized.startsWith('ep') ||
        normalized.startsWith('episode') ||
        normalized.startsWith('chapter') ||
        normalized.startsWith('chap') ||
        normalized.startsWith('vol');
  }

  static Future<List<String>> _sortedAlbumImagesForPath(String dirPath) {
    return _sortedImageFilesForPath(
      dirPath,
      sortMode: LocalLibraryManager.instance.localAlbumImageSort,
    );
  }

  static Future<List<String>> _sortImagePathsAsync(
    Iterable<String> paths, {
    required String sortMode,
  }) async {
    final existing = <String>[];
    for (final path in paths) {
      if (await _fileExists(path)) {
        existing.add(path);
      }
    }
    existing.sort((a, b) => _compareImagePaths(a, b, sortMode));
    return existing;
  }

  static Future<List<String>> _sortedImageFilesForPath(
    String dirPath, {
    required String sortMode,
  }) async {
    final files = (await _listDirectoryEntries(dirPath))
        .where((entry) => !entry.isDirectory && _isVisibleImagePath(entry.path))
        .map((entry) => entry.path)
        .toList();
    if (files.isEmpty) {
      return const <String>[];
    }

    files.sort((a, b) => _compareImagePaths(a, b, sortMode));

    final visibleFiles =
        files.where((path) => !_isCoverLikePath(path)).toList();
    if (visibleFiles.isNotEmpty) {
      return visibleFiles;
    }
    return files;
  }

  static int _compareImagePaths(String a, String b, String sortMode) {
    switch (normalizeLocalAlbumImageSort(sortMode)) {
      case localAlbumImageSortNameDesc:
        return -_naturalCompare(_basename(a), _basename(b));
      case localAlbumImageSortTimeAsc:
        return _compareFileModifiedTime(a, b);
      case localAlbumImageSortTimeDesc:
        return _compareFileModifiedTime(b, a);
      case localAlbumImageSortNameAsc:
      default:
        return _naturalCompare(_basename(a), _basename(b));
    }
  }

  static int _compareFileModifiedTime(String a, String b) {
    try {
      return File(a).statSync().modified.compareTo(File(b).statSync().modified);
    } catch (_) {
      return _naturalCompare(_basename(a), _basename(b));
    }
  }

  static Future<bool> _containsVisibleImagesForPath(String dirPath) async {
    return (await _listDirectoryEntries(dirPath))
        .any((entry) => !entry.isDirectory && _isVisibleImagePath(entry.path));
  }

  static bool _containsVisibleImages(Directory dir) {
    return _safeList(dir).whereType<File>().any(_isVisibleImageFile);
  }

  static Future<String?> _pickCoverPath(
    String dirPath,
    List<String> orderedImages,
  ) async {
    for (final candidate in [
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
      'cover.webp'
    ]) {
      final path = _joinPath(dirPath, candidate);
      if (await _fileExists(path)) {
        return path;
      }
    }
    return orderedImages.isNotEmpty ? orderedImages.first : null;
  }

  static Future<DateTime> _computeAlbumTimeForPath(
    String dirPath,
    List<String> images,
  ) async {
    try {
      var latest = Directory(dirPath).statSync().modified;
      for (final path in images) {
        final modified = File(path).statSync().modified;
        if (modified.isAfter(latest)) {
          latest = modified;
        }
      }
      return latest;
    } catch (_) {
      return DateTime.now();
    }
  }

  static double _computeDirectorySizeMb(Directory dir) {
    double bytes = 0;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File) {
        try {
          bytes += entity.lengthSync();
        } catch (_) {}
      }
    }
    return bytes / 1024 / 1024;
  }

  static Future<double> _computeDirectorySizeMbForPath(String path) async {
    try {
      if (Directory(path).existsSync()) {
        return _computeDirectorySizeMb(Directory(path));
      }
    } catch (_) {}

    double bytes = 0;
    Future<void> visit(String dirPath) async {
      for (final entry in await _listDirectoryEntries(dirPath)) {
        if (entry.isDirectory) {
          await visit(entry.path);
        } else {
          bytes += await _fileLength(entry.path);
        }
      }
    }

    try {
      await visit(path);
    } catch (_) {}
    return bytes / 1024 / 1024;
  }

  static String _resolveDownloadItemDirectoryFromMetadata(
    String rootPath,
    String rawId,
    String rawDirectory,
    DownloadedItem item,
  ) {
    final candidates = <String>[
      if (rawDirectory.trim().isNotEmpty) rawDirectory.trim(),
      if (item.directory?.trim().isNotEmpty == true) item.directory!.trim(),
      rawId,
      item.id,
      _sanitizeFileName(rawDirectory.trim().isNotEmpty ? rawDirectory : rawId),
      _sanitizeFileName(item.name),
    ];

    String? candidate;
    for (final value in candidates) {
      final normalized = value.trim();
      if (normalized.isNotEmpty) {
        candidate = normalized;
        break;
      }
    }
    if (candidate == null) {
      return rootPath;
    }
    return candidate.startsWith('/')
        ? candidate
        : _joinPath(rootPath, candidate);
  }

  static bool _managedDownloadDirectoryExistsInIndex(
    String rootPath,
    String itemDirectory,
    Set<String> sourceDirectoryNames,
  ) {
    if (sourceDirectoryNames.isEmpty) {
      return false;
    }
    final normalizedRoot =
        rootPath.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');
    final normalizedItem =
        itemDirectory.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');
    final candidateName = normalizedItem.startsWith('$normalizedRoot/')
        ? normalizedItem.substring(normalizedRoot.length + 1).split('/').first
        : _basename(normalizedItem);
    return sourceDirectoryNames.contains(candidateName.toLowerCase());
  }

  static Future<bool> _managedDownloadDirectoryExists(
    String rootPath,
    String itemDirectory,
    Set<String> sourceDirectoryNames,
  ) async {
    if (_managedDownloadDirectoryExistsInIndex(
      rootPath,
      itemDirectory,
      sourceDirectoryNames,
    )) {
      return true;
    }
    return _directoryExists(itemDirectory);
  }

  static Future<bool> _directoryExists(String path) async {
    try {
      if (Directory(path).existsSync()) {
        return true;
      }
    } catch (_) {}
    return _existsWithPrivilegedAccess(path);
  }

  static Future<bool> _fileExists(String path) async {
    try {
      if (File(path).existsSync()) {
        return true;
      }
    } catch (_) {}
    return _existsWithPrivilegedAccess(path);
  }

  static Future<bool> _isDownloadDirectoryAsync(String path) {
    return _fileExists(_joinPath(path, 'download.db'));
  }

  static Future<Uint8List?> _readFileBytes(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) {
        return await file.readAsBytes();
      }
    } catch (_) {}
    return _readFileWithPrivilegedAccess(path);
  }

  static Future<int> _fileLength(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) {
        return await file.length();
      }
    } catch (_) {}
    final bytes = await _readFileWithPrivilegedAccess(path);
    return bytes?.length ?? 0;
  }

  static Future<List<_LocalDirectoryEntry>> _listDirectoryEntries(
    String path,
  ) async {
    try {
      final directory = Directory(path);
      if (directory.existsSync()) {
        return directory
            .listSync(followLinks: false)
            .where((entity) => entity is Directory || entity is File)
            .map(
              (entity) => _LocalDirectoryEntry(
                name: _basename(entity.path),
                path: entity.path,
                isDirectory: entity is Directory,
              ),
            )
            .toList();
      }
    } catch (_) {}
    return _listDirectoryEntriesWithPrivilegedAccess(path);
  }

  static Future<List<_LocalDirectoryEntry>>
      _listDirectoryEntriesWithPrivilegedAccess(String path) async {
    if (!Platform.isAndroid) {
      return const <_LocalDirectoryEntry>[];
    }
    final method = _androidPrivilegedAccessMethod('listDirectoryEntries');
    if (method == null) {
      return const <_LocalDirectoryEntry>[];
    }
    try {
      final result = await _storageAccessChannel.invokeListMethod<Object>(
        method,
        {'path': path},
      );
      return (result ?? const <Object>[])
          .whereType<Map>()
          .map((item) {
            final name = item['name']?.toString().trim() ?? '';
            if (name.isEmpty) {
              return null;
            }
            final type = item['type']?.toString();
            return _LocalDirectoryEntry(
              name: name,
              path: _joinPath(path, name),
              isDirectory: type == 'directory',
            );
          })
          .whereType<_LocalDirectoryEntry>()
          .toList();
    } catch (_) {
      return const <_LocalDirectoryEntry>[];
    }
  }

  static Future<Uint8List?> _readFileWithPrivilegedAccess(String path) async {
    if (!Platform.isAndroid) {
      return null;
    }
    final method = _androidPrivilegedAccessMethod('readFile');
    if (method == null) {
      return null;
    }
    try {
      final result = await _storageAccessChannel.invokeMethod<Object>(
        method,
        {'path': path},
      );
      if (result is Uint8List) {
        return result;
      }
      if (result is ByteData) {
        return result.buffer.asUint8List();
      }
      if (result is List) {
        return Uint8List.fromList(result.cast<int>());
      }
    } catch (_) {}
    return null;
  }

  static Future<bool> _existsWithPrivilegedAccess(String path) async {
    if (!Platform.isAndroid) {
      return false;
    }
    final method = _androidPrivilegedAccessMethod('exists');
    if (method == null) {
      return false;
    }
    try {
      return await _storageAccessChannel.invokeMethod<bool>(
            method,
            {'path': path},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static String? _androidPrivilegedAccessMethod(String operation) {
    final rootEnabled = normalizeAndroidRootMode(
            appdata.settings[androidRootModeSettingIndex]) ==
        '1';
    if (rootEnabled) {
      switch (operation) {
        case 'listDirectoryEntries':
          return 'listDirectoryEntriesWithRoot';
        case 'readFile':
          return 'readFileWithRoot';
        case 'exists':
          return 'existsWithRoot';
      }
    }

    final shizukuEnabled = normalizeAndroidShizukuMode(
          appdata.settings[androidShizukuModeSettingIndex],
        ) ==
        '1';
    if (shizukuEnabled) {
      switch (operation) {
        case 'listDirectoryEntries':
          return 'listDirectoryEntriesWithShizuku';
        case 'readFile':
          return 'readFileWithShizuku';
        case 'exists':
          return 'existsWithShizuku';
      }
    }
    return null;
  }

  static Future<bool> _shouldUsePrivilegedFallbackForDirectory(
    String path,
  ) async {
    if (!Platform.isAndroid) {
      return false;
    }
    if (!_isAndroidPrivilegedAccessEnabled()) {
      return false;
    }
    if (_canAccessDirectoryWithDartIo(path)) {
      return false;
    }
    return true;
  }

  static bool _looksLikeRootOnlyPath(String path) {
    final normalized = path.trim().replaceAll('\\', '/').toLowerCase();
    return normalized == '/data' ||
        normalized.startsWith('/data/') ||
        normalized.startsWith('/apex/') ||
        normalized.startsWith('/system/');
  }

  static Future<bool> _existsWithShizukuAccess(String path) async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      return await _storageAccessChannel.invokeMethod<bool>(
            'existsWithShizuku',
            {'path': path},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _hasShizukuPermission({
    bool forceRefresh = false,
  }) async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      return await _storageAccessChannel.invokeMethod<bool>(
            'hasShizukuPermission',
            {'forceRefresh': forceRefresh},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _hasRootAccess({
    bool forceRefresh = false,
  }) async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      return await _storageAccessChannel.invokeMethod<bool>(
            'hasRootAccess',
            {'forceRefresh': forceRefresh},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static bool _isAndroidPrivilegedAccessEnabled() {
    final rootEnabled = normalizeAndroidRootMode(
            appdata.settings[androidRootModeSettingIndex]) ==
        '1';
    if (rootEnabled) {
      return true;
    }
    return normalizeAndroidShizukuMode(
          appdata.settings[androidShizukuModeSettingIndex],
        ) ==
        '1';
  }

  static bool _canAccessDirectoryWithDartIo(String path) {
    try {
      final directory = Directory(path);
      if (!directory.existsSync()) {
        return false;
      }
      directory.listSync(followLinks: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  static List<FileSystemEntity> _safeList(Directory dir) {
    try {
      return dir.listSync();
    } catch (_) {
      return const <FileSystemEntity>[];
    }
  }

  static bool _isVisibleImageFile(FileSystemEntity entity) {
    if (entity is! File) {
      return false;
    }
    return _isVisibleImagePath(entity.path);
  }

  static bool _isVisibleImagePath(String path) {
    final name = _basename(path).toLowerCase();
    return name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.png') ||
        name.endsWith('.webp');
  }

  static bool _isCoverLikePath(String path) {
    final name = _basename(path).toLowerCase();
    return name == 'cover.jpg' ||
        name == 'cover.jpeg' ||
        name == 'cover.png' ||
        name == 'cover.webp';
  }

  static int _naturalCompare(String a, String b) {
    final aa = _splitNatural(a.toLowerCase());
    final bb = _splitNatural(b.toLowerCase());
    final len = aa.length < bb.length ? aa.length : bb.length;
    for (int i = 0; i < len; i++) {
      final left = aa[i];
      final right = bb[i];
      final leftNum = int.tryParse(left);
      final rightNum = int.tryParse(right);
      if (leftNum != null && rightNum != null) {
        final diff = leftNum.compareTo(rightNum);
        if (diff != 0) {
          return diff;
        }
      } else {
        final diff = left.compareTo(right);
        if (diff != 0) {
          return diff;
        }
      }
    }
    return aa.length.compareTo(bb.length);
  }

  static List<String> _splitNatural(String value) {
    return RegExp(r'\d+|\D+')
        .allMatches(value)
        .map((e) => e.group(0)!)
        .toList();
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/').where((e) => e.isNotEmpty).toList();
    return segments.isEmpty ? path : segments.last;
  }

  static String _joinPath(String base, String child) {
    if (base.isEmpty) {
      return child;
    }
    return '$base${Platform.pathSeparator}$child';
  }

  static String _sanitizeFileName(String name) {
    var sanitized = name.trim();
    sanitized = sanitized.replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001F]'), '_');
    if (sanitized.isEmpty) {
      return 'unknown';
    }
    return sanitized;
  }

  static String _safeCacheName(String value) {
    final sanitized = value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return sanitized.isEmpty ? 'default' : sanitized;
  }

  static bool _looksLikeCanonicalDownloadId(String id) {
    final value = id.trim();
    return value.contains('-') ||
        value.startsWith('jm') ||
        value.startsWith('hitomi') ||
        value.startsWith('nhentai') ||
        value.startsWith('Ht') ||
        RegExp(r'^\d+$').hasMatch(value) ||
        RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(value);
  }

  static int _downloadRowPriority(String id, String directory) {
    final normalizedId = id.trim();
    final normalizedDirectory = directory.trim();
    if (normalizedId.isEmpty) {
      return -1;
    }
    if (_looksLikeCanonicalDownloadId(normalizedId) &&
        normalizedId != normalizedDirectory) {
      return 2;
    }
    if (_looksLikeCanonicalDownloadId(normalizedId)) {
      return 1;
    }
    return 0;
  }

  static DownloadedItem? _parseDownloadedItem(
    String id,
    String json,
    DateTime time,
    String? directory,
  ) {
    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      DownloadedItem? comic;
      if (id.contains('-')) {
        comic = CustomDownloadedItem.fromJson(data);
      } else if (id.startsWith('jm')) {
        comic = DownloadedJmComic.fromMap(data);
      } else if (id.startsWith('hitomi')) {
        comic = DownloadedHitomiComic.fromMap(data);
      } else if (id.startsWith('nhentai')) {
        comic = NhentaiDownloadedComic.fromJson(data);
      } else if (id.startsWith('Ht')) {
        comic = DownloadedHtComic.fromJson(data);
      } else if (RegExp(r'^\d+$').hasMatch(id)) {
        comic = DownloadedGallery.fromJson(data);
      } else {
        comic = RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(id.trim())
            ? DownloadedComic.fromJson(data)
            : ScannedDownloadedComic.fromJson(data);
      }
      comic.time = time;
      comic.directory = directory;
      return comic;
    } catch (_) {
      return null;
    }
  }

  static DownloadedItem? _downloadedItemFromDbRow(
    Row row,
    DateTime time,
    String directory,
  ) {
    final rawId = _downloadRowText(row, const ['id']) ?? '';
    if (rawId.isEmpty) {
      return null;
    }
    final title = _downloadRowText(row, const [
          'title',
          'name',
          'comicTitle',
          'galleryTitle',
          'label',
        ]) ??
        _basename(directory.isNotEmpty ? directory : rawId);
    final author = _downloadRowText(row, const [
          'subtitle',
          'subTitle',
          'author',
          'artist',
          'artists',
          'uploader',
          'user',
          'creator',
          'group',
          'circle',
        ]) ??
        '';
    final tags = _downloadRowTags(row, const [
      'tags',
      'tag',
      'tagList',
      'metadataTags',
      'categories',
      'category',
      'labels',
    ]);
    final size =
        _downloadRowDouble(row, const ['size', 'comicSize', 'totalSize']);
    final comic = ScannedDownloadedComic(
      comicId: rawId,
      title: title,
      author: author,
      chapters: const <String>['全部'],
      downloadedChapters: const <int>[0],
      size: size,
      tagList: tags,
    )
      ..time = time
      ..directory = directory;
    return comic;
  }

  static double? _downloadRowDouble(Row row, Iterable<String> keys) {
    for (final key in keys) {
      try {
        final raw = row[key];
        if (raw is num) {
          return raw.toDouble();
        }
        final value = double.tryParse(raw?.toString().trim() ?? '');
        if (value != null) {
          return value;
        }
      } catch (_) {}
    }
    return null;
  }

  static String _metadataTitleForDownloadedRow(
    Row row,
    DownloadedItem fallback,
  ) {
    final fromRow = _downloadRowText(row, const [
      'title',
      'name',
      'comicTitle',
      'galleryTitle',
      'label',
    ]);
    if (fromRow != null) {
      return fromRow;
    }
    return fallback.name;
  }

  static String? _downloadRowText(Row row, Iterable<String> keys) {
    for (final key in keys) {
      try {
        final value = row[key]?.toString().trim();
        if (value != null && value.isNotEmpty) {
          return value;
        }
      } catch (_) {}
    }
    return null;
  }

  static List<String> _parseTagValues(Object? raw) {
    if (raw == null) {
      return const <String>[];
    }
    if (raw is List) {
      return raw
          .map((entry) => entry.toString().trim())
          .where((entry) => entry.isNotEmpty)
          .toList(growable: false);
    }
    final text = raw.toString().trim();
    if (text.isEmpty) {
      return const <String>[];
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) {
        final values = decoded
            .map((entry) => entry.toString().trim())
            .where((entry) => entry.isNotEmpty)
            .toList(growable: false);
        if (values.isNotEmpty) {
          return values;
        }
      }
    } catch (_) {}
    return text
        .split(RegExp(r'[,，;；|]'))
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }

  static List<String> _downloadRowTags(Row row, Iterable<String> keys) {
    for (final key in keys) {
      try {
        final values = _parseTagValues(row[key]);
        if (values.isNotEmpty) {
          return values;
        }
      } catch (_) {}
    }
    return const <String>[];
  }

  static String _metadataAuthorForDownloadedRow(
    Row row,
    String json,
    DownloadedItem fallback,
  ) {
    final fromRow = _downloadRowText(row, const [
      'subtitle',
      'subTitle',
      'author',
      'artist',
      'uploader',
      'user',
    ]);
    if (fromRow != null) {
      return fromRow;
    }
    return _metadataAuthorForDownloadedJson(json, fallback);
  }

  static List<String> _metadataTagsForDownloadedRow(
    Row row,
    String json,
    DownloadedItem fallback,
  ) {
    final fromRow = _downloadRowTags(row, const [
      'tags',
      'tag',
      'tagList',
      'metadataTags',
    ]);
    if (fromRow.isNotEmpty) {
      return fromRow;
    }
    return _metadataTagsForDownloadedJson(json, fallback);
  }

  static String _metadataAuthorForDownloadedJson(
    String json,
    DownloadedItem fallback,
  ) {
    final direct = fallback.subTitle.trim();
    if (direct.isNotEmpty) {
      return direct;
    }

    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      String? pick(Map data, Iterable<String> keys) {
        for (final key in keys) {
          final value = data[key]?.toString().trim();
          if (value != null && value.isNotEmpty) {
            return value;
          }
        }
        return null;
      }

      final root = pick(data, const [
        'subtitle',
        'subTitle',
        'author',
        'artist',
        'uploader',
        'user',
      ]);
      if (root != null) {
        return root;
      }

      for (final nestedKey in const ['comicItem', 'comic', 'metadata']) {
        final nested = data[nestedKey];
        if (nested is Map) {
          final value = pick(nested, const [
            'subtitle',
            'subTitle',
            'author',
            'artist',
            'uploader',
            'user',
          ]);
          if (value != null) {
            return value;
          }
        }
      }
    } catch (_) {}
    return '';
  }

  static List<String> _metadataTagsForDownloadedJson(
    String json,
    DownloadedItem fallback,
  ) {
    if (fallback.tags.isNotEmpty) {
      return List<String>.from(fallback.tags);
    }

    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      List<String>? pick(Map data, Iterable<String> keys) {
        for (final key in keys) {
          final raw = data[key];
          if (raw is List) {
            final values = raw
                .map((entry) => entry.toString().trim())
                .where((entry) => entry.isNotEmpty)
                .toList(growable: false);
            if (values.isNotEmpty) {
              return values;
            }
          }
        }
        return null;
      }

      final root = pick(data, const ['tags', 'tagList', 'metadataTags']);
      if (root != null) {
        return root;
      }

      for (final nestedKey in const ['comicItem', 'comic', 'metadata']) {
        final nested = data[nestedKey];
        if (nested is Map) {
          final values =
              pick(nested, const ['tags', 'tagList', 'metadataTags']);
          if (values != null) {
            return values;
          }
        }
      }
    } catch (_) {}
    return const <String>[];
  }

  static String? _favoriteTargetForDownloaded(
      DownloadedItem comic, String rawId) {
    final json = comic.toJson();
    String? nonEmpty(Object? value) {
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? null : text;
    }

    switch (comic.type) {
      case DownloadType.ehentai:
      case DownloadType.hitomi:
        return nonEmpty(json['link']) ?? rawId;
      case DownloadType.jm:
        return rawId.startsWith('jm') ? rawId.substring(2) : rawId;
      case DownloadType.htmanga:
        if (rawId.startsWith('Ht') || rawId.startsWith('ht')) {
          return rawId.substring(2);
        }
        return rawId;
      case DownloadType.nhentai:
        return rawId.startsWith('nhentai') ? rawId.substring(7) : rawId;
      case DownloadType.other:
      case DownloadType.copyManga:
      case DownloadType.komiic:
        return nonEmpty(json['comicId']) ?? rawId;
      case DownloadType.picacg:
      case DownloadType.favorite:
        return rawId;
    }
  }

  static String _sourceKeyForDownloadType(DownloadType type) {
    switch (type) {
      case DownloadType.picacg:
        return 'picacg';
      case DownloadType.ehentai:
        return 'ehentai';
      case DownloadType.jm:
        return 'jm';
      case DownloadType.hitomi:
        return 'hitomi';
      case DownloadType.htmanga:
        return 'htmanga';
      case DownloadType.nhentai:
        return 'nhentai';
      case DownloadType.copyManga:
        return 'copy_manga';
      case DownloadType.komiic:
        return 'Komiic';
      case DownloadType.favorite:
        return 'local_album';
      case DownloadType.other:
        return 'other';
    }
  }

  static FavoriteType _favoriteTypeForDownloadType(DownloadType type) {
    switch (type) {
      case DownloadType.picacg:
        return FavoriteType.picacg;
      case DownloadType.ehentai:
        return FavoriteType.ehentai;
      case DownloadType.jm:
        return FavoriteType.jm;
      case DownloadType.hitomi:
        return FavoriteType.hitomi;
      case DownloadType.htmanga:
        return FavoriteType.htManga;
      case DownloadType.nhentai:
        return FavoriteType.nhentai;
      case DownloadType.copyManga:
        return FavoriteType.copyManga;
      case DownloadType.komiic:
        return FavoriteType.komiic;
      case DownloadType.favorite:
      case DownloadType.other:
        return const FavoriteType(0);
    }
  }

  static void _sortItems(List<LocalLibraryComicItem> items, String sortMode) {
    switch (normalizeLocalLibraryListSort(sortMode)) {
      case 'time_asc':
        items.sort((a, b) => (a.time ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(b.time ?? DateTime.fromMillisecondsSinceEpoch(0)));
        break;
      case 'name_asc':
        items.sort((a, b) => a.name.compareTo(b.name));
        break;
      case 'name_desc':
        items.sort((a, b) => b.name.compareTo(a.name));
        break;
      case 'size_asc':
        items.sort((a, b) => (a.comicSize ?? 0).compareTo(b.comicSize ?? 0));
        break;
      case 'size_desc':
        items.sort((a, b) => (b.comicSize ?? 0).compareTo(a.comicSize ?? 0));
        break;
      case 'time_desc':
      default:
        items.sort((a, b) => (b.time ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(a.time ?? DateTime.fromMillisecondsSinceEpoch(0)));
        break;
    }
  }
}
