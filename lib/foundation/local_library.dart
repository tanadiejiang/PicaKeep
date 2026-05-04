import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

import '../base.dart';
import 'download_model.dart';
import 'local_data_source.dart';
import 'local_favorites.dart';
import 'local_library_settings.dart';

enum LocalLibrarySourceKind {
  currentDownload,
  originalDownload,
  customPath,
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
    required bool canDelete,
    required this.aliases,
    this.favoriteTarget,
    this.comicSize,
  })  : _type = type,
        _name = name,
        _subTitle = subTitle,
        _tags = tags,
        _sourceDisplayName = sourceDisplayName,
        _fileSystemPath = fileSystemPath,
        _downloadedEps = downloadedEps,
        _eps = eps,
        _localCoverPath = localCoverPath,
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
  final bool _canDelete;
  final List<String> aliases;
  final String? favoriteTarget;

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

  @override
  bool get canDelete => _canDelete;

  bool get hasMultipleEpisodes =>
      episodeFiles.length > 1 ||
      (!episodeFiles.containsKey(0) && episodeFiles.containsKey(1));

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
        'favoriteTarget': favoriteTarget,
        'comicSize': comicSize,
      };

  @override
  Widget createReadingPage({int? ep, int? page}) {
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
    final files = hasEp
        ? List<String>.from(_episodeFiles[ep] ?? const <String>[])
        : List<String>.from(_episodeFiles[0] ?? const <String>[]);
    if (!supportsImageSort) {
      return files;
    }
    return LocalLibraryManager._sortImagePaths(
      files,
      sortMode: localImageSortMode,
    );
  }

  @override
  Stream<List<int>> loadImage(int ep, int page, String url) async* {
    final file = File(url);
    if (await file.exists()) {
      yield await file.readAsBytes();
    } else {
      yield const <int>[];
    }
  }

  @override
  ImageProvider createImageProvider(int ep, int page, String url) {
    return FileImage(File(url));
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

  factory LocalLibraryManager() => instance;

  LocalLibraryManager._();

  bool _loaded = false;
  Future<void>? _refreshTask;
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
      final directory = Directory(source.path);
      if (!directory.existsSync()) {
        continue;
      }
      if (source.isManagedDownload || _isDownloadDirectory(source.path)) {
        _scanDownloadSource(source);
      } else {
        _scanAlbumSource(source);
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
      if (!(source.isManagedDownload || _isDownloadDirectory(source.path))) {
        continue;
      }
      final directory = Directory(source.path);
      if (!directory.existsSync()) {
        if (!source.isManagedDownload) {
          continue;
        }
        try {
          directory.createSync(recursive: true);
        } catch (_) {
          continue;
        }
      }
      count += _rescanManagedDownloadSource(source.path);
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

  void _scanDownloadSource(LocalLibrarySource source) {
    final dbPath = _joinPath(source.path, 'download.db');
    final file = File(dbPath);
    if (!file.existsSync()) {
      _storageEntries.add(
        LocalLibraryStorageEntry(
          id: source.id,
          title: source.title,
          path: source.path,
          sizeMb: _computeDirectorySizeMb(Directory(source.path)),
          comicCount: 0,
          children: const <LocalLibraryStorageChildEntry>[],
          source: source,
        ),
      );
      return;
    }

    final db = sqlite3.open(dbPath);
    try {
      final rows = db
          .select('select id, time, directory, json from download order by time desc')
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
        );
        if (baseItem == null) {
          continue;
        }

        final showAllDatabaseRecords =
            appdata.settings[localLibraryShowAllDatabaseRecordsSettingIndex] ==
                '1';
        final itemDirectory =
            _resolveDownloadItemDirectory(source.path, rawId, rawDirectory);
        final dedupeKey = itemDirectory.toLowerCase();
        if (!seenDirectories.add(dedupeKey)) {
          continue;
        }
        final itemDirectoryExists = Directory(itemDirectory).existsSync();
        if (!itemDirectoryExists && !showAllDatabaseRecords) {
          continue;
        }

        final episodeFiles = itemDirectoryExists
            ? _buildDownloadedEpisodeFiles(itemDirectory, baseItem)
            : const <int, List<String>>{};
        if (episodeFiles.isEmpty && !showAllDatabaseRecords) {
          continue;
        }

        final coverPath = itemDirectoryExists
            ? _pickCoverPath(itemDirectory, episodeFiles[0] ?? const <String>[])
            : null;
        final localType = _effectiveDownloadTypeForLocalItem(baseItem, rawId);
        final item = LocalLibraryComicItem(
          itemId: 'local_download::${source.id}::$rawId',
          originalId: rawId,
          type: localType,
          name: baseItem.name,
          subTitle: baseItem.subTitle,
          tags: List<String>.from(baseItem.tags),
          sourceDisplayName:
              _displayNameForDownloaded(baseItem, rawId, localType),
          fileSystemPath: itemDirectory,
          episodeFiles: episodeFiles,
          downloadedEps:
              List<int>.generate(episodeFiles.length, (index) => index),
          eps: _buildDisplayedEpisodes(baseItem, episodeFiles.length),
          localCoverPath: coverPath,
          canDelete: false,
          aliases: [rawId],
          favoriteTarget: _favoriteTargetForDownloaded(baseItem, rawId),
          comicSize: itemDirectoryExists
              ? (baseItem.comicSize ??
                  _computeDirectorySizeMb(Directory(itemDirectory)))
              : (baseItem.comicSize ?? 0),
        )..time = baseItem.time;

        _indexItem(item);
        _items.add(item);
        final sizeMb = item.comicSize ?? 0;
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
          sizeMb: totalSize > 0
              ? totalSize
              : _computeDirectorySizeMb(Directory(source.path)),
          comicCount: children.length,
          children: children,
          source: source,
        ),
      );
    } finally {
      db.dispose();
    }
  }

  void _scanAlbumSource(LocalLibrarySource source) {
    final root = Directory(source.path);
    if (!root.existsSync()) {
      return;
    }

    final albumDirs = _collectLeafAlbumDirectories(root);
    final children = <LocalLibraryStorageChildEntry>[];

    for (final dir in albumDirs) {
      final imageFiles = _sortedAlbumImages(dir);
      if (imageFiles.isEmpty) {
        continue;
      }
      final coverPath = _pickCoverPath(dir.path, imageFiles);
      final sizeMb = _computeDirectorySizeMb(dir);
      final item = LocalLibraryComicItem(
        itemId: 'local_album::${dir.path}',
        originalId: dir.path,
        type: DownloadType.favorite,
        name: _basename(dir.path),
        subTitle: '',
        tags: const <String>[],
        sourceDisplayName: '图集',
        fileSystemPath: dir.path,
        episodeFiles: {0: imageFiles},
        downloadedEps: const <int>[0],
        eps: const <String>['全部'],
        localCoverPath: coverPath,
        canDelete: false,
        aliases: [dir.path],
        comicSize: sizeMb,
      )..time = _computeAlbumTime(dir, imageFiles);
      _indexItem(item);
      _items.add(item);
      children.add(
        LocalLibraryStorageChildEntry(
          id: item.id,
          title: item.name,
          path: dir.path,
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
        sizeMb: _computeDirectorySizeMb(root),
        comicCount: children.length,
        children: children,
        source: source,
      ),
    );
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

  static bool _isDownloadDirectory(String path) {
    return File(_joinPath(path, 'download.db')).existsSync();
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

  static List<String> _buildDisplayedEpisodes(
      DownloadedItem item, int episodeCount) {
    if (episodeCount <= 1) {
      return item.eps.isNotEmpty ? [item.eps.first] : const <String>[];
    }
    if (item.eps.length == episodeCount) {
      return List<String>.from(item.eps);
    }
    return List<String>.generate(episodeCount, (index) => '第${index + 1}章');
  }

  static String _resolveDownloadItemDirectory(
    String rootPath,
    String rawId,
    String rawDirectory,
  ) {
    final candidates = <String>[
      if (rawDirectory.trim().isNotEmpty) rawDirectory.trim(),
      rawId,
      _sanitizeFileName(rawDirectory.trim().isNotEmpty ? rawDirectory : rawId),
    ];

    for (final candidate in candidates) {
      final path = _joinPath(rootPath, candidate);
      if (_directoryExistsSync(path)) {
        return path;
      }
    }

    return _joinPath(rootPath, _sanitizeFileName(rawId));
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
      for (final entry in _safeList(root).whereType<Directory>()) {
        final dirName = _basename(entry.path);
        if (dirName.isEmpty ||
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

  static Map<int, List<String>> _buildDownloadedEpisodeFiles(
    String itemDirectory,
    DownloadedItem item,
  ) {
    final directory = Directory(itemDirectory);
    final childDirs = directory
        .listSync()
        .whereType<Directory>()
        .where((e) => _containsVisibleImages(e))
        .toList()
      ..sort((a, b) => _naturalCompare(_basename(a.path), _basename(b.path)));

    final result = <int, List<String>>{};
    if (childDirs.isNotEmpty) {
      for (int i = 0; i < childDirs.length; i++) {
        final files = _sortedImageFiles(childDirs[i],
            sortMode: localAlbumImageSortNameAsc);
        if (files.isNotEmpty) {
          result[i + 1] = files;
        }
      }
      return result;
    }

    final files =
        _sortedImageFiles(directory, sortMode: localAlbumImageSortNameAsc);
    if (files.isNotEmpty) {
      result[0] = files;
    }
    return result;
  }

  static List<Directory> _collectLeafAlbumDirectories(Directory root) {
    final result = <Directory>[];

    bool visit(Directory dir) {
      final children = _safeList(dir);
      final hasImages = children.any(_isVisibleImageFile);
      var hasAlbumDescendant = false;
      for (final subDir in children.whereType<Directory>()) {
        if (visit(subDir)) {
          hasAlbumDescendant = true;
        }
      }
      if (hasImages && !hasAlbumDescendant) {
        result.add(dir);
        return true;
      }
      return hasImages || hasAlbumDescendant;
    }

    visit(root);
    result.sort((a, b) => a.path.compareTo(b.path));
    return result;
  }

  static List<String> _sortedAlbumImages(Directory dir) {
    return _sortedImageFiles(dir,
        sortMode: LocalLibraryManager.instance.localAlbumImageSort);
  }

  static List<String> _sortImagePaths(
    Iterable<String> paths, {
    required String sortMode,
  }) {
    final files = paths
        .map((path) => File(path))
        .where((file) => file.existsSync())
        .toList();
    files.sort((a, b) {
      switch (normalizeLocalAlbumImageSort(sortMode)) {
        case localAlbumImageSortNameDesc:
          return -_naturalCompare(_basename(a.path), _basename(b.path));
        case localAlbumImageSortTimeAsc:
          return a.statSync().modified.compareTo(b.statSync().modified);
        case localAlbumImageSortTimeDesc:
          return b.statSync().modified.compareTo(a.statSync().modified);
        case localAlbumImageSortNameAsc:
        default:
          return _naturalCompare(_basename(a.path), _basename(b.path));
      }
    });
    return files.map((file) => file.path).toList();
  }

  static List<String> _sortedImageFiles(Directory dir,
      {required String sortMode}) {
    final files =
        _safeList(dir).whereType<File>().where(_isVisibleImageFile).toList();
    if (files.isEmpty) {
      return const <String>[];
    }

    files.sort((a, b) {
      switch (normalizeLocalAlbumImageSort(sortMode)) {
        case localAlbumImageSortNameDesc:
          return -_naturalCompare(_basename(a.path), _basename(b.path));
        case localAlbumImageSortTimeAsc:
          return a.statSync().modified.compareTo(b.statSync().modified);
        case localAlbumImageSortTimeDesc:
          return b.statSync().modified.compareTo(a.statSync().modified);
        case localAlbumImageSortNameAsc:
        default:
          return _naturalCompare(_basename(a.path), _basename(b.path));
      }
    });

    final visibleFiles =
        files.where((file) => !_isCoverLikeFile(file)).toList();
    if (visibleFiles.isNotEmpty) {
      return visibleFiles.map((e) => e.path).toList();
    }
    return files.map((e) => e.path).toList();
  }

  static bool _containsVisibleImages(Directory dir) {
    return _safeList(dir).whereType<File>().any(_isVisibleImageFile);
  }

  static String? _pickCoverPath(String dirPath, List<String> orderedImages) {
    for (final candidate in [
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
      'cover.webp'
    ]) {
      final path = _joinPath(dirPath, candidate);
      if (File(path).existsSync()) {
        return path;
      }
    }
    return orderedImages.isNotEmpty ? orderedImages.first : null;
  }

  static DateTime _computeAlbumTime(Directory dir, List<String> images) {
    DateTime latest = dir.statSync().modified;
    for (final path in images) {
      final modified = File(path).statSync().modified;
      if (modified.isAfter(latest)) {
        latest = modified;
      }
    }
    return latest;
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

  static bool _directoryExistsSync(String path) {
    try {
      return Directory(path).existsSync();
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
    final name = _basename(entity.path).toLowerCase();
    return name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.png') ||
        name.endsWith('.webp');
  }

  static bool _isCoverLikeFile(File file) {
    final name = _basename(file.path).toLowerCase();
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
