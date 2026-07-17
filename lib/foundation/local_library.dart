import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Row;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/privileged_storage_access.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

import '../base.dart';
import 'archive/archive_episode_builder.dart';
import 'archive/archive_image_provider.dart';
import 'archive/archive_models.dart';
import 'archive/archive_password_store.dart';
import 'archive/archive_reading_service.dart';
import 'download_model.dart';
import 'download_author_resolver.dart';
import 'local_data_source.dart';
import 'local_favorites.dart';
import 'local_library_settings.dart';
import 'local_trash_store.dart';

part 'local_library_manager_settings.dart';
part 'local_library_query.dart';
part 'local_library_cover.dart';
part 'local_library_archive.dart';
part 'local_library_scan.dart';
part 'local_library_static.dart';

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
    this.collectionShellEnabled = false,
  });

  final String id;
  final String title;
  final String path;
  final LocalLibrarySourceKind kind;
  final bool collectionShellEnabled;

  bool get isCustom => kind == LocalLibrarySourceKind.customPath;

  bool get isManagedDownload => !isCustom;

  bool get supportsCollectionShell => isCustom;
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

class _LocalAlbumScanResult {
  const _LocalAlbumScanResult({
    required this.children,
    required this.totalSize,
  });

  final List<LocalLibraryStorageChildEntry> children;
  final double totalSize;
}

class _CollectionShellEpisode {
  const _CollectionShellEpisode({
    required this.title,
    required this.files,
  });

  final String title;
  final List<String> files;
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

  /// 清除所有"无封面"标记（coverPath == noCoverSentinel），使下次加载重新探测。
  /// 用于用户主动刷新/重扫——可能手动添加了封面文件。
  bool clearNoCoverSentinels() {
    bool changed = false;
    final keysToUpdate = <String>[];
    for (final entry in items.entries) {
      if (entry.value.coverPath == LocalLibraryManager.noCoverSentinel) {
        keysToUpdate.add(entry.key);
      }
    }
    for (final key in keysToUpdate) {
      final existing = items[key]!;
      items[key] = _LocalLibraryCachedItem(
        coverPath: null,
        episodeFiles: existing.episodeFiles,
      );
      changed = true;
    }
    return changed;
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

class LocalLibraryRestoredFileMetadata {
  const LocalLibraryRestoredFileMetadata({
    required this.episodeFiles,
    required this.coverPath,
    required this.sizeMb,
    required this.downloadedEps,
    required this.eps,
  });

  final Map<int, List<String>> episodeFiles;
  final String? coverPath;
  final double sizeMb;
  final List<int> downloadedEps;
  final List<String> eps;
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
  String? _localCoverPath;
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
      itemId.startsWith('local_album::') ||
      itemId.startsWith('local_archive::') ||
      sourceDisplayName == '图集';

  bool get isArchiveItem => itemId.startsWith('local_archive::');

  bool _archiveEncrypted = false;
  bool _archivePasswordMatched = false;
  ArchiveFormat _archiveFormat = ArchiveFormat.unknown;
  List<String>? _archiveChapterRealNames;

  bool get archiveEncrypted => _archiveEncrypted;
  bool get archivePasswordMatched => _archivePasswordMatched;
  ArchiveFormat get archiveFormat => _archiveFormat;

  bool get needsArchivePassword =>
      isArchiveItem && _archiveEncrypted && !_archivePasswordMatched;

  String get archiveFormatDisplay {
    final enc = _archiveEncrypted ? '加密 ' : '';
    switch (_archiveFormat) {
      case ArchiveFormat.cbz:
        return '${enc}CBZ';
      case ArchiveFormat.zip:
        return '${enc}ZIP';
      case ArchiveFormat.unknown:
        return '$enc压缩包';
    }
  }

  void markArchiveUnlocked(String password) {
    _archivePasswordMatched = true;
    ArchivePasswordStore.instance.setSessionPassword(
      _fileSystemPath,
      password,
    );
  }

  void markArchiveLocked() {
    _archivePasswordMatched = false;
    _localCoverPath = null;
  }

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

  String _displayEpisodeTitle(String title) {
    if (_sourceDisplayName != '合集图集') {
      return title;
    }
    final itemTitle = _name.trim();
    final normalizedTitle = title.trim();
    if (itemTitle.isEmpty || !normalizedTitle.startsWith(itemTitle)) {
      return title;
    }
    final rest = normalizedTitle.substring(itemTitle.length).trimLeft();
    final cleaned =
        rest.replaceFirst(RegExp(r'^[\s/_\\\-—:：]+'), '').trimLeft();
    return cleaned.isEmpty ? title : cleaned;
  }

  @override
  Widget createReadingPage({int? ep, int? page}) {
    final hasEp = hasMultipleEpisodes;
    final epsMap = hasEp
        ? {
            for (int i = 0; i < _eps.length; i++)
              '${i + 1}': _displayEpisodeTitle(_eps[i]),
          }
        : null;
    final data = LocalPathReadingData(
      title: name,
      id: id,
      downloadId: id,
      sourceKey: _sourceKeyForDownloadType(type),
      directoryPath: fileSystemPath ?? '',
      hasEp: hasEp,
      comicType: comicTypeForDownloadType(type),
      eps: epsMap,
      favoriteType: _favoriteTypeForDownloadType(type),
      tagSource: _sourceKeyForDownloadType(type),
      tagComicId: originalId.isEmpty ? itemId : originalId,
      tagFlatTags: tags,
      episodeFiles: episodeFiles,
      downloadedEpisodeIndexes: downloadedEps,
      supportsImageSort: isAlbum && !isArchiveItem,
      archiveChapterRealNames: isArchiveItem ? _archiveChapterRealNames : null,
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
    this.tagSource,
    this.tagComicId,
    this.tagFlatTags = const <String>[],
    this.tagCategorizedTags = const <String, List<String>>{},
    required Map<int, List<String>> episodeFiles,
    required Iterable<int> downloadedEpisodeIndexes,
    this.supportsImageSort = false,
    this.archiveChapterRealNames,
  }) : _episodeFiles = {
          for (final entry in episodeFiles.entries)
            entry.key: List<String>.from(entry.value),
        } {
    downloadedEps = List<int>.from(downloadedEpisodeIndexes);
  }

  final Map<int, List<String>> _episodeFiles;

  final String directoryPath;

  final bool supportsImageSort;

  final List<String>? archiveChapterRealNames;

  @override
  String epDisplayName(int index) {
    final defaultNames =
        eps?.values.toList(growable: false) ?? const <String>[];
    return LocalLibraryManager.buildArchiveChapterDisplayName(
      index: index,
      defaultNames: defaultNames,
      realNames: archiveChapterRealNames,
    );
  }

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
  String? get untranslatedTagSource {
    final normalized = tagSource?.trim().toLowerCase() ?? '';
    return normalized == 'ehentai' || normalized == 'nhentai'
        ? normalized
        : null;
  }

  @override
  String get untranslatedTagComicId =>
      tagComicId?.trim().isNotEmpty == true ? tagComicId!.trim() : id;

  @override
  Iterable<String> get untranslatedTagFlatTags => tagFlatTags;

  @override
  Map<String, List<String>> get untranslatedTagCategorizedTags =>
      tagCategorizedTags;

  @override
  final bool hasEp;

  @override
  final Map<String, String>? eps;

  final String? tagSource;
  final String? tagComicId;
  final List<String> tagFlatTags;
  final Map<String, List<String>> tagCategorizedTags;

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
      _episodeFiles[key] = await _buildDownloadedEpisodeFilesForEp(
        directoryPath,
        key,
      );
    }
    final files = List<String>.from(_episodeFiles[key] ?? const <String>[]);
    if (!supportsImageSort) {
      return files;
    }
    return await _sortImagePathsAsync(
      files,
      sortMode: localImageSortMode,
    );
  }

  @override
  Stream<List<int>> loadImage(int ep, int page, String url) async* {
    if (isArchiveUri(url)) {
      final bytes =
          await ArchiveReadingService.instance.readEntryBytesByUri(url);
      yield bytes;
      return;
    }
    final bytes = await _readFileBytes(url);
    yield bytes ?? const <int>[];
  }

  @override
  ImageProvider createImageProvider(
    int ep,
    int page,
    String url, {
    StreamImageAbortSignal? abortSignal,
  }) {
    if (isArchiveUri(url)) {
      final parsed = parseArchiveUri(url)!;
      final fp = ArchiveReadingService.instance
          .fingerprintCachedFor(parsed.archivePath);
      final fileSize = fp?.fileSize ?? 0;
      final mtimeMillis = fp?.mtimeMillis ?? 0;
      return ArchiveImageProvider(
        archivePath: parsed.archivePath,
        entryPath: parsed.entryPath,
        fileSize: fileSize,
        mtimeMillis: mtimeMillis,
      );
    }
    return LocalLibraryManager.instance.imageProviderForLocalPath(url);
  }

  @override
  String buildImageKey(int ep, int page, String url) {
    if (isArchiveUri(url)) {
      final parsed = parseArchiveUri(url)!;
      final fp = ArchiveReadingService.instance
          .fingerprintCachedFor(parsed.archivePath);
      final fileSize = fp?.fileSize ?? 0;
      final mtimeMillis = fp?.mtimeMillis ?? 0;
      return 'archive::${fileSize}_$mtimeMillis::${parsed.archivePath}::${parsed.entryPath}';
    }
    return url;
  }

  @override
  Future<List<String>> loadEpNetwork(int ep) async {
    return loadEp(ep);
  }

  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) async* {
    yield* loadImage(ep, page, url);
  }
}

bool readArchiveUseChapterNumber() =>
    appdata.settings[archiveUseChapterNumberSettingIndex] == '1';

Future<void> writeArchiveUseChapterNumber(bool value) async {
  appdata.settings[archiveUseChapterNumberSettingIndex] = value ? '1' : '0';
  await appdata.updateSettings();
}

class LocalLibraryManager {
  static final LocalLibraryManager instance = LocalLibraryManager._();

  /// 持久化标记：source cache 的 coverPath 存此值表示"已探测、确认无可用封面"。
  /// 下次加载读到此值即跳过解析，直接渲染占位图标，不走 root 特权通道。
  /// 只有显式刷新/重扫时清除（reload 重建 cache 或手动 invalidate）。
  static const String noCoverSentinel = '__no_cover__';

  factory LocalLibraryManager() => instance;

  LocalLibraryManager._();

  bool _loaded = false;
  Future<void>? _refreshTask;
  Future<List<LocalLibraryComicItem>>? _managedDownloadsLoadTask;
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

  Future<LocalLibraryRestoredFileMetadata> buildRestoredFileMetadata(
    String itemDirectory,
  ) async {
    final episodeFiles =
        await _buildDownloadedEpisodeFiles(itemDirectory, null);
    final orderedEpisodes = episodeFiles.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final coverPath = await _pickCoverPath(
      itemDirectory,
      orderedEpisodes.isEmpty ? const <String>[] : orderedEpisodes.first.value,
    );
    final sizeMb = await _computeDirectorySizeMbForPath(itemDirectory);
    return LocalLibraryRestoredFileMetadata(
      episodeFiles: episodeFiles,
      coverPath: coverPath,
      sizeMb: sizeMb,
      downloadedEps: List<int>.from(orderedEpisodes.map((entry) => entry.key)),
      eps: _buildLocalEpisodeNames(episodeFiles.length),
    );
  }

  Future<void> persistRestoredFileMetadataCache({
    required String sourceDbPath,
    required String sourceDbId,
    required String itemDirectory,
    required LocalLibraryRestoredFileMetadata metadata,
  }) async {
    final normalizedDbPath = sourceDbPath.trim();
    final normalizedId = sourceDbId.trim();
    final normalizedDirectory = itemDirectory.trim();
    if (normalizedDbPath.isEmpty ||
        normalizedId.isEmpty ||
        normalizedDirectory.isEmpty) {
      return;
    }

    final normalizedTargetDbPath =
        normalizedDbPath.replaceAll('\\', '/').toLowerCase();
    LocalLibrarySource? source;
    for (final candidate in await _buildSources()) {
      if (!candidate.isManagedDownload) {
        continue;
      }
      final candidateDbPath = _joinPath(candidate.path, 'download.db')
          .replaceAll('\\', '/')
          .toLowerCase();
      if (candidateDbPath == normalizedTargetDbPath) {
        source = candidate;
        break;
      }
    }
    if (source == null) {
      return;
    }

    final cache = await _loadSourceCache(source);
    cache.setItem(
      normalizedId,
      normalizedDirectory,
      _LocalLibraryCachedItem(
        coverPath: metadata.coverPath,
        episodeFiles: metadata.episodeFiles,
      ),
    );
    await cache.save();
  }

  Future<String?> _ensureManagedDownloadCoverCache(
    LocalLibraryComicItem item,
    String? existingCachePath,
  ) async {
    final normalizedExisting = existingCachePath?.trim() ?? '';
    // 已持久化"无封面"标记：跳过全部 root 探测，直接返回 null（调用方渲染占位）。
    if (normalizedExisting == noCoverSentinel) {
      return null;
    }
    if (await _hasUsableManagedCoverCache(item, normalizedExisting)) {
      return normalizedExisting;
    }
    final sourcePath = await _resolveManagedDownloadSourceCoverPath(item);
    if (sourcePath == null || sourcePath.isEmpty) {
      // 源目录没有任何可用封面，持久化标记避免下次进页面再走 root 通道。
      await _persistManagedDownloadCoverCachePath(item, noCoverSentinel);
      return null;
    }
    final bytes = await _readFileBytes(sourcePath);
    if (bytes == null || bytes.isEmpty) {
      await _persistManagedDownloadCoverCachePath(item, noCoverSentinel);
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

  /// 为本地漫画项返回封面 provider，与「异步预解析时序」解耦。
  ///
  /// 退出再进列表时，item 的 localCoverPath 可能尚未被 _prefetchLocalCovers 回写
  /// （首帧为 null），若此时 provider 取空就会出现「有时不显示封面」。这里改为
  /// 惰性 provider：localCoverPath 已有值时直接用；为空时返回一个 StreamImageProvider，
  /// 其 loader 内部先 resolveCoverPathForItem（含目录扫描兜底、走特权通道、并回写
  /// item._localCoverPath）再读字节——封面由 provider 自拉，不再依赖外部 setState 时序。
  /// key 用稳定的 item.id，imageCache 跨进出页面命中，避免重复解析与闪烁。
  ImageProvider<Object>? coverImageProviderForItem(LocalLibraryComicItem item) {
    if (!item.localStorageExists) {
      return null;
    }
    final cached = item.localCoverPath?.trim();
    if (cached == noCoverSentinel) {
      return null;
    }
    if (cached != null && cached.isNotEmpty) {
      return imageProviderForLocalPath(cached);
    }
    return StreamImageProvider(
      () async {
        final resolved = await resolveCoverPathForItem(item);
        if (resolved == null || resolved.isEmpty) {
          return Stream<List<int>>.value(const <int>[]);
        }
        final bytes = await _readFileBytes(resolved);
        return Stream<List<int>>.value(bytes ?? const <int>[]);
      },
      'local_cover::${item.id}',
    );
  }

  ImageProvider<Object> imageProviderForLocalPath(String path) {
    // 关键：root/shizuku 模式下，对 /storage/emulated/0/... 外部路径，
    // File.existsSync() 会因挂载点可见而返回 true，但 FileImage 内部的
    // readAsBytes() 受 scoped storage 限制静默失败 → 破图。若此时按 existsSync
    // 走 FileImage 快路径，特权通道（StreamImageProvider → _readFileBytes）就
    // 永远不触发——这正是「封面没能用上 root/shizuku 权限」的根因。
    // 因此特权模式启用时一律走 StreamImageProvider：其 _readFileBytes 已是
    // dart:io 优先、读到空再回退特权通道（见第六轮修正），full-access / 应用
    // 沙箱内仍走 dart:io 命中，无回归；root/shizuku 下才真正落到特权通道。
    if (!_isAndroidPrivilegedAccessEnabled()) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          return FileImage(file);
        }
      } catch (_) {}
    }
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
      // noCoverSentinel 已在 _ensureManagedDownloadCoverCache 内处理（直接返回 null），
      // 同时该标记意味着后续 _resolveNamedCoverPath / _sortedImageFilesForPath 也不
      // 可能有结果（同目录、同设备——不可能 dart:io 失败而 root 通道也失败后突然能
      // 用 dart:io 读到），因此直接终止，不再走后续 fallback。
      if (cached == noCoverSentinel) {
        return null;
      }
      final managedCached =
          await _ensureManagedDownloadCoverCache(item, cached);
      if (managedCached != null && managedCached.isNotEmpty) {
        return managedCached;
      }
      // _ensureManagedDownloadCoverCache 已在失败时持久化 noCoverSentinel，
      // 后续 fallback 对同目录做相同探测不会有不同结果，跳过。
      return null;
    } else if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    final dirPath = item.fileSystemPath?.trim();
    if (dirPath == null || dirPath.isEmpty) {
      return null;
    }
    // 非 managed 项（图集 / 本地扫描）：目录扫描兜底解析封面。解析成功后
    // 回写 item._localCoverPath，使同步路径（详情页 resolveLocalComicCoverPath、
    // 图集页 _coverFile）下次能直接命中——否则那些项首帧 episodeFiles 可能为空、
    // localCoverPath 为 null，同步路径找不到封面而破图，只有本异步路径能扫出来。
    final resolved = await _resolveNonManagedCoverPath(item, dirPath);
    if (resolved != null && resolved.isNotEmpty) {
      item._localCoverPath = resolved;
    }
    return resolved;
  }

  Future<String?> _resolveNonManagedCoverPath(
    LocalLibraryComicItem item,
    String dirPath,
  ) async {
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

  Future<List<_CollectionShellEpisode>>
      _buildCollectionShellEpisodesForFormalPath(
    String formalPath,
    String formalTitle,
  ) async {
    final episodes = <_CollectionShellEpisode>[];
    final directImages = await _sortedContentImagesForPath(formalPath);
    if (directImages.isNotEmpty) {
      episodes.add(
        _CollectionShellEpisode(
          title: formalTitle,
          files: directImages,
        ),
      );
    }

    final chapterEntries = (await _listDirectoryEntries(formalPath))
        .where((entry) => entry.isDirectory)
        .where((entry) => entry.name != _localTrashDirectoryName)
        .toList()
      ..sort((a, b) => _naturalCompare(a.name, b.name));
    for (final chapterEntry in chapterEntries) {
      final files =
          await _sortedRecursiveContentImagesForPath(chapterEntry.path);
      if (files.isEmpty) {
        continue;
      }
      episodes.add(
        _CollectionShellEpisode(
          title: _collectionShellEpisodeTitle(formalTitle, chapterEntry.name),
          files: files,
        ),
      );
    }
    return episodes;
  }

  Future<List<String>> _sortedContentImagesForPath(String dirPath) async {
    final files = await _sortedImageFilesForPath(
      dirPath,
      sortMode: localAlbumImageSortNameAsc,
    );
    return files.where((path) => !_isCoverLikePath(path)).toList();
  }

  Future<List<String>> _sortedRecursiveContentImagesForPath(
    String dirPath,
  ) async {
    final files = <String>[];
    await _collectRecursiveImageFiles(dirPath, files);
    files.sort((a, b) => _compareImagePaths(a, b, localAlbumImageSortNameAsc));
    return files.where((path) => !_isCoverLikePath(path)).toList();
  }

  Future<void> _collectRecursiveImageFiles(
    String dirPath,
    List<String> sink,
  ) async {
    final entries = await _listDirectoryEntries(dirPath);
    for (final entry in entries) {
      if (entry.name == _localTrashDirectoryName) {
        continue;
      }
      if (entry.isDirectory) {
        await _collectRecursiveImageFiles(entry.path, sink);
        continue;
      }
      if (_isVisibleImagePath(entry.path)) {
        sink.add(entry.path);
      }
    }
  }

  Future<double> _computeTotalSizeMbForFiles(List<String> filePaths) async {
    var total = 0;
    for (final path in filePaths) {
      total += await _fileLength(path);
    }
    return total / (1024 * 1024);
  }

  static List<String> archiveDisplayChapterNames(LocalLibraryComicItem item) {
    if (!item.isArchiveItem) return item.eps;
    return List<String>.generate(
      item.eps.length,
      (index) => buildArchiveChapterDisplayName(
        index: index,
        defaultNames: item.eps,
        realNames: item._archiveChapterRealNames,
      ),
    );
  }

  static String buildArchiveChapterDisplayName({
    required int index,
    required List<String> defaultNames,
    required List<String>? realNames,
  }) {
    if (index < 0 || index >= defaultNames.length) {
      return '';
    }
    final fallback = defaultNames[index];
    final realName = realNames != null && index < realNames.length
        ? realNames[index].trim()
        : '';
    if (realName.isEmpty) {
      return fallback;
    }
    if (!readArchiveUseChapterNumber()) {
      return realName;
    }
    if (fallback.trim().isEmpty || fallback == '全部') {
      return realName;
    }
    return '$fallback $realName';
  }
}

class _Semaphore {
  _Semaphore(int maxCount) : _count = maxCount;

  int _count;
  final List<Completer<void>> _waiters = [];

  Future<void> acquire() async {
    if (_count > 0) {
      _count--;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      final next = _waiters.removeAt(0);
      next.complete();
    } else {
      _count++;
    }
  }
}
