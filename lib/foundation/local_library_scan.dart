part of 'local_library.dart';

extension LocalLibraryScan on LocalLibraryManager {
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
    await _autoUnlockEncryptedArchives();
  }

  Future<List<LocalLibraryComicItem>> getAll() async {
    await ensureLoaded();
    final items = List<LocalLibraryComicItem>.from(_items);
    _sortItems(items, localLibraryListSort);
    return items;
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
    final collectionShellModes = decodeLocalCollectionShellPathMap(
      appdata.settings[localLibraryCollectionShellSettingIndex],
    );
    for (int i = 0; i < customPaths.length; i++) {
      final path = customPaths[i].trim();
      if (path.isEmpty) {
        continue;
      }
      final key = normalizeLocalCollectionShellPathKey(path);
      sources.add(
        LocalLibrarySource(
          id: 'custom_path_$i',
          title: _basename(path),
          path: path,
          kind: LocalLibrarySourceKind.customPath,
          collectionShellEnabled:
              key.isNotEmpty && collectionShellModes[key] == true,
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
        .map((entry) => Platform.isWindows ? entry.name.toLowerCase() : entry.name)
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

            final itemDirectory = await _resolveDownloadItemDirectoryFromMetadata(
              source.path,
              rawId,
              rawDirectory,
              baseItem,
              sourceDirectoryNames,
              trustStorageFromDatabase: trustStorageFromDatabase,
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
            // trustStorageFromDatabase=true（root 模式）时：
            // 不再一律标 true，而是用加载开头已经列出的 sourceDirectoryNames
            // 做纯内存匹配——目录名在 set 里的才是真正有本地内容的项，不在的
            // 是 db 有记录但本地已删除/不存在的，标为 false 使其只显示不走通道。
            // 这个检查不走 root 通道（纯字符串比对），零额外 I/O。
            final localStorageExists = trustStorageFromDatabase
                ? _managedDownloadDirectoryExistsInIndex(
                    source.path,
                    itemDirectory,
                    sourceDirectoryNames,
                  )
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
      return _loadDirectoryOnlyDownloadSourceMetadata(source);
    }
    if (items.isEmpty && trustStorageFromDatabase) {
      return _loadDirectoryOnlyDownloadSourceMetadata(source);
    }
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
        .map((entry) => Platform.isWindows ? entry.name.toLowerCase() : entry.name)
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

        final itemDirectory = await _resolveDownloadItemDirectoryFromMetadata(
          source.path,
          rawId,
          rawDirectory,
          baseItem,
          sourceDirectoryNames,
          trustStorageFromDatabase: trustStorageFromDatabase,
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
            ? _managedDownloadDirectoryExistsInIndex(
                source.path,
                itemDirectory,
                sourceDirectoryNames,
              )
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
      // Still scan for archive files even when the directory itself is a single album
      final entries = await _listDirectoryEntries(source.path);
      final hasArchives =
          entries.any((e) => !e.isDirectory && isArchivePath(e.path));
      if (hasArchives) {
        await _scanArchiveFilesUnder(source, const [], 0);
      }
      return;
    }

    if (source.collectionShellEnabled) {
      final scanResult = await _scanCollectionShellAlbumSource(source);
      if (scanResult != null) {
        await _scanArchiveFilesUnder(
          source,
          scanResult.children,
          scanResult.totalSize,
        );
        return;
      }
    }

    final scanResult = await _scanLeafAlbumSource(source);

    // Scan archive files (.zip/.cbz) in the same source directory
    await _scanArchiveFilesUnder(
      source,
      scanResult.children,
      scanResult.totalSize,
    );
  }

  Future<_LocalAlbumScanResult> _scanLeafAlbumSource(
    LocalLibrarySource source,
  ) async {
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
      final displayTitle = _albumDisplayTitleForLeafDirectory(dirPath);
      final episodeTitle = _episodeTitleForLeafDirectory(dirPath, displayTitle);
      final item = LocalLibraryComicItem(
        itemId: 'local_album::$dirPath',
        originalId: dirPath,
        type: DownloadType.favorite,
        name: displayTitle,
        subTitle: '',
        tags: const <String>[],
        sourceDisplayName: '图集',
        fileSystemPath: dirPath,
        episodeFiles: {0: imageFiles},
        downloadedEps: const <int>[0],
        eps: <String>[episodeTitle],
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

    return _LocalAlbumScanResult(
      children: children,
      totalSize: totalSize,
    );
  }

  Future<_LocalAlbumScanResult?> _scanCollectionShellAlbumSource(
    LocalLibrarySource source,
  ) async {
    final children = <LocalLibraryStorageChildEntry>[];
    final hiddenIndex = await LocalTrashStore.instance.hiddenIndex();
    double totalSize = 0;
    final shellEntries = (await _listDirectoryEntries(source.path))
        .where((entry) => entry.isDirectory)
        .toList()
      ..sort((a, b) => _naturalCompare(a.name, b.name));
    if (shellEntries.isEmpty) {
      return null;
    }

    for (final shellEntry in shellEntries) {
      if (shellEntry.name == _localTrashDirectoryName ||
          hiddenIndex.matchesPath(shellEntry.path)) {
        continue;
      }
      final item = await _buildCollectionShellAlbumItem(shellEntry.path);
      if (item != null) {
        _indexItem(item);
        _items.add(item);
        final sizeMb = item.comicSize ?? 0;
        totalSize += sizeMb;
        children.add(
          LocalLibraryStorageChildEntry(
            id: item.id,
            title: item.name,
            path: shellEntry.path,
            sizeMb: sizeMb,
            sourceDisplayName: item.sourceDisplayName,
          ),
        );
        continue;
      }

      final fallbackSource = LocalLibrarySource(
        id: source.id,
        title: source.title,
        path: shellEntry.path,
        kind: source.kind,
      );
      final fallback = await _scanLeafAlbumSourceWithoutStorageEntry(
        fallbackSource,
        hiddenIndex,
      );
      totalSize += fallback.totalSize;
      children.addAll(fallback.children);
    }

    if (children.isEmpty) {
      return null;
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

    return _LocalAlbumScanResult(
      children: children,
      totalSize: totalSize,
    );
  }

  Future<_LocalAlbumScanResult> _scanLeafAlbumSourceWithoutStorageEntry(
    LocalLibrarySource source,
    LocalTrashHiddenIndex hiddenIndex,
  ) async {
    final albumDirs = await _collectLeafAlbumDirectoryPaths(source.path);
    final children = <LocalLibraryStorageChildEntry>[];
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
      final displayTitle = _albumDisplayTitleForLeafDirectory(dirPath);
      final episodeTitle = _episodeTitleForLeafDirectory(dirPath, displayTitle);
      final item = LocalLibraryComicItem(
        itemId: 'local_album::$dirPath',
        originalId: dirPath,
        type: DownloadType.favorite,
        name: displayTitle,
        subTitle: '',
        tags: const <String>[],
        sourceDisplayName: '图集',
        fileSystemPath: dirPath,
        episodeFiles: {0: imageFiles},
        downloadedEps: const <int>[0],
        eps: <String>[episodeTitle],
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

    return _LocalAlbumScanResult(
      children: children,
      totalSize: totalSize,
    );
  }

  Future<LocalLibraryComicItem?> _buildCollectionShellAlbumItem(
    String shellPath,
  ) async {
    final directImages = await _sortedContentImagesForPath(shellPath);
    if (directImages.isNotEmpty) {
      return null;
    }

    final formalEntries = (await _listDirectoryEntries(shellPath))
        .where((entry) => entry.isDirectory)
        .where((entry) => entry.name != _localTrashDirectoryName)
        .toList()
      ..sort((a, b) => _naturalCompare(a.name, b.name));
    if (formalEntries.isEmpty) {
      return null;
    }

    final episodeFiles = <int, List<String>>{};
    final episodeNames = <String>[];
    final shellTitle = _basename(shellPath);
    for (final formalEntry in formalEntries) {
      final formalEpisodes = await _buildCollectionShellEpisodesForFormalPath(
        formalEntry.path,
        _stripCollectionShellParentPrefix(shellTitle, formalEntry.name),
      );
      for (final episode in formalEpisodes) {
        final key = episodeFiles.length + 1;
        episodeFiles[key] = episode.files;
        episodeNames.add(episode.title);
      }
    }
    if (episodeFiles.isEmpty) {
      return null;
    }

    final orderedImages = episodeFiles.values.expand((entry) => entry).toList();
    final coverPath = await _pickCollectionShellCoverPath(
      shellPath,
      formalEntries,
      orderedImages,
    );
    final sizeMb = await _computeTotalSizeMbForFiles(orderedImages);
    final downloadedEps = episodeFiles.keys.toList()..sort();
    return LocalLibraryComicItem(
      itemId: 'local_album::$shellPath',
      originalId: shellPath,
      type: DownloadType.favorite,
      name: _basename(shellPath),
      subTitle: '',
      tags: const <String>[],
      sourceDisplayName: '合集图集',
      fileSystemPath: shellPath,
      episodeFiles: episodeFiles,
      downloadedEps: downloadedEps,
      eps: episodeNames,
      localCoverPath: coverPath,
      localStorageExists: true,
      canDelete: false,
      aliases: [shellPath],
      comicSize: sizeMb,
    )..time = await _computeAlbumTimeForPath(shellPath, orderedImages);
  }

  Future<void> _scanArchiveFilesUnder(
    LocalLibrarySource source,
    List<LocalLibraryStorageChildEntry> existingChildren,
    double existingTotalSize,
  ) async {
    final hiddenIndex = await LocalTrashStore.instance.hiddenIndex();
    final entries = await _listDirectoryEntries(source.path);
    final archiveFiles =
        entries.where((e) => !e.isDirectory && isArchivePath(e.path)).toList();
    if (archiveFiles.isEmpty) return;

    final archiveChildren = <LocalLibraryStorageChildEntry>[];
    double archiveTotalSize = 0;

    // Limit concurrency to 2
    final semaphore = _Semaphore(2);
    final futures = archiveFiles.map((entry) async {
      await semaphore.acquire();
      try {
        if (hiddenIndex.matchesPath(entry.path)) return;
        await _scanSingleArchiveFile(
          source,
          entry,
          archiveChildren,
          (size) => archiveTotalSize += size,
        );
      } finally {
        semaphore.release();
      }
    });
    await Future.wait(futures);

    if (archiveChildren.isNotEmpty) {
      // Update the existing storage entry to include archive items
      final existingIdx = _storageEntries.indexWhere((e) => e.id == source.id);
      if (existingIdx >= 0) {
        final existing = _storageEntries[existingIdx];
        _storageEntries[existingIdx] = LocalLibraryStorageEntry(
          id: existing.id,
          title: existing.title,
          path: existing.path,
          sizeMb: existing.sizeMb + archiveTotalSize,
          comicCount: existing.comicCount + archiveChildren.length,
          children: [...existing.children, ...archiveChildren],
          source: existing.source,
        );
      }
    }
  }

  Future<void> _scanSingleArchiveFile(
    LocalLibrarySource source,
    _LocalDirectoryEntry entry,
    List<LocalLibraryStorageChildEntry> sink,
    void Function(double) addSize,
  ) async {
    try {
      final format = archiveFormatForPath(entry.path);
      if (format == ArchiveFormat.unknown) return;

      final ArchiveIndex? probe;
      try {
        probe = await ArchiveReadingService.instance.getIndex(entry.path);
      } catch (e) {
        return;
      }
      if (probe.imageEntries.isEmpty) return;

      final stat = await File(entry.path).stat();
      final sizeMb = stat.size / (1024 * 1024);
      final isEncrypted = probe.isEncrypted;
      final built = buildArchiveEpisodes(probe);
      final episodeFiles = built.episodeFiles;
      final itemId = 'local_archive::${entry.path}';

      String? coverPath;
      final hasSessionPassword = isEncrypted &&
          ArchivePasswordStore.instance.getSessionPassword(entry.path) != null;
      if (!isEncrypted || hasSessionPassword) {
        final coverEntry = pickArchiveCoverEntry(probe);
        if (coverEntry != null) {
          coverPath = await ArchiveReadingService.instance.extractCoverToCache(
            entry.path,
            coverEntry,
          );
        }
      }

      final item = LocalLibraryComicItem(
        itemId: itemId,
        originalId: entry.path,
        type: DownloadType.favorite,
        name: _basenameWithoutExtension(entry.name),
        subTitle: '',
        tags: const <String>[],
        sourceDisplayName: isEncrypted ? '加密压缩包' : '压缩包',
        fileSystemPath: entry.path,
        episodeFiles: episodeFiles,
        downloadedEps: episodeFiles.keys.toList()..sort(),
        eps: _buildLocalEpisodeNames(episodeFiles.length),
        localCoverPath: coverPath,
        localStorageExists: true,
        canDelete: false,
        aliases: [entry.path],
        comicSize: sizeMb,
      )..time = stat.modified;

      item._archiveFormat = format;
      item._archiveEncrypted = isEncrypted;
      item._archivePasswordMatched = !isEncrypted ||
          ArchivePasswordStore.instance.getSessionPassword(entry.path) != null;
      item._archiveChapterRealNames = built.realNames;

      _indexItem(item);
      _items.add(item);
      addSize(sizeMb);
      sink.add(LocalLibraryStorageChildEntry(
        id: item.id,
        title: item.name,
        path: entry.path,
        sizeMb: sizeMb,
        sourceDisplayName: item.sourceDisplayName,
      ));
    } catch (e) {
      // Ignore malformed archive entries and keep indexing the rest.
    }
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
}
