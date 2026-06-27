part of 'local_resource_scanner.dart';

extension LocalResourceScannerManaged on LocalResourceScanner {
  Future<List<ServerResourceItemSummary>> _scanRootItems(
    String rootId,
    String rootTitle,
    String rootPath, {
    required bool collectionShellEnabled,
  }) async {
    if (rootId.startsWith('custom_')) {
      return _scanCustomRootItems(
        rootId,
        rootTitle,
        rootPath,
        collectionShellEnabled: collectionShellEnabled,
      );
    }

    return _scanManagedRootItems(rootId, rootTitle, rootPath);
  }

  Future<List<ServerResourceItemSummary>> _scanManagedRootItems(
    String rootId,
    String rootTitle,
    String rootPath,
  ) async {
    final records = await _loadManagedRootRecords(rootTitle, rootPath);
    _cacheManagedRootMetadata(rootPath, records);
    final results = <ServerResourceItemSummary>[];
    final seenPaths = <String>{};

    if (records.isNotEmpty) {
      final sourceDirectoryNames = await _listRootDirectoryNames(rootPath);
      for (final record in records) {
        if (!_managedDirectoryExistsInIndex(
          rootPath,
          record.directoryPath,
          sourceDirectoryNames,
        )) {
          continue;
        }
        final dedupeKey = _normalizePath(record.directoryPath);
        if (!seenPaths.add(dedupeKey)) {
          continue;
        }
        final item = await _buildManagedShallowItem(
          rootId: rootId,
          rootTitle: rootTitle,
          directoryPath: record.directoryPath,
          metadata: record.metadata,
          comicSizeMb: record.comicSizeMb,
        );
        if (item != null) {
          results.add(item);
        }
      }
      return results;
    }

    final children = await _listDirectories(rootPath);
    for (final child in children) {
      final item = await _buildManagedFallbackShallowItem(
        rootId: rootId,
        rootTitle: rootTitle,
        directoryPath: child,
      );
      if (item != null) {
        results.add(item);
      }
    }
    if (results.isNotEmpty) {
      return results;
    }

    final rootItem = await _buildManagedFallbackShallowItem(
      rootId: rootId,
      rootTitle: rootTitle,
      directoryPath: rootPath,
    );
    if (rootItem != null) {
      results.add(rootItem);
    }
    return results;
  }

  Future<ServerResourceItemSummary?> deepScanItem(
    ServerResourceItemSummary shallow, {
    required String rootPath,
  }) async {
    if (shallow.rootId.startsWith('custom_')) {
      return shallow;
    }

    final metadataByDirectory = await _loadManagedRootMetadata(
      shallow.sourceTitle,
      rootPath,
    );
    return await _scanComicItem(
          shallow.rootId,
          shallow.sourceTitle,
          rootPath,
          shallow.path,
          metadataByDirectory,
          includeTotalBytes: false,
          fallbackTotalBytes: shallow.totalBytes,
        ) ??
        shallow;
  }

  Future<ServerResourceItemSummary?> _scanComicItem(
    String rootId,
    String rootTitle,
    String rootPath,
    String directoryPath,
    Map<String, _ServerResourceMetadata> metadataByDirectory, {
    required bool includeTotalBytes,
    int fallbackTotalBytes = 0,
  }) async {
    final directImages = await _listImageFiles(directoryPath, recursive: false);
    final episodes = <ServerResourceEpisodeSummary>[];

    if (directImages.isNotEmpty) {
      final images = await _listImageFiles(directoryPath, recursive: true);
      final episode = await _buildEpisodeSummary(
        index: 1,
        title: _directoryTitle(directoryPath),
        directory: directoryPath,
        images: images,
        includeTotalBytes: includeTotalBytes,
      );
      if (episode != null) {
        episodes.add(episode);
      }
    } else {
      final children = await _listDirectories(directoryPath);
      for (final child in children) {
        final images = await _listImageFiles(child, recursive: true);
        final episode = await _buildEpisodeSummary(
          index: episodes.length + 1,
          title: _directoryTitle(child),
          directory: child,
          images: images,
          includeTotalBytes: includeTotalBytes,
        );
        if (episode != null) {
          episodes.add(episode);
        }
      }

      if (episodes.isEmpty) {
        final images = await _listImageFiles(directoryPath, recursive: true);
        final episode = await _buildEpisodeSummary(
          index: 1,
          title: _directoryTitle(directoryPath),
          directory: directoryPath,
          images: images,
          includeTotalBytes: includeTotalBytes,
        );
        if (episode != null) {
          episodes.add(episode);
        }
      }
    }

    if (episodes.isEmpty) {
      return null;
    }

    final imageCount =
        episodes.fold<int>(0, (sum, item) => sum + item.imageCount);
    final computedTotalBytes =
        episodes.fold<int>(0, (sum, item) => sum + item.totalBytes);
    final totalBytes =
        includeTotalBytes ? computedTotalBytes : fallbackTotalBytes;
    final metadata = _resolveManagedMetadata(
      metadataByDirectory,
      rootPath,
      directoryPath,
    );
    final titledEpisodes = _applyEpisodeTitles(
      episodes,
      metadata?.episodeTitles ?? const <String>[],
    );
    final fallbackSubtitle =
        titledEpisodes.length > 1 ? '${titledEpisodes.length} 个章节' : '';
    final subtitle = _firstNonEmptyValue([
      metadata?.subtitle,
      fallbackSubtitle,
    ]);
    final sourceDisplayName = _firstNonEmptyValue([
      metadata?.sourceDisplayName,
      rootTitle,
    ]);
    final title = _firstNonEmptyValue([
      metadata?.title,
      _directoryTitle(directoryPath),
    ]);
    final displayId = _firstNonEmptyValue([
      metadata?.displayId,
      _buildItemId(rootId, directoryPath),
    ]);
    final updatedAt =
        metadata?.updatedAt ?? await _directoryUpdatedAt(directoryPath);
    return ServerResourceItemSummary(
      id: _buildItemId(rootId, directoryPath),
      rootId: rootId,
      sourceTitle: rootTitle,
      sourceDisplayName: sourceDisplayName,
      title: title,
      displayId: displayId,
      subtitle: subtitle,
      tags: metadata?.tags ?? const <String>[],
      path: directoryPath,
      imageCount: imageCount,
      totalBytes: totalBytes,
      coverPath: await _resolveItemCoverPath(
        metadata?.coverPath,
        directoryPath,
        titledEpisodes,
      ),
      episodes: titledEpisodes,
      updatedAt: updatedAt,
    );
  }

  Future<Map<String, _ServerResourceMetadata>> _loadManagedRootMetadata(
    String rootTitle,
    String rootPath,
  ) async {
    final cached = _metadataCacheByRoot[rootPath];
    if (cached != null) {
      return cached;
    }
    final records = await _loadManagedRootRecords(rootTitle, rootPath);
    return _cacheManagedRootMetadata(rootPath, records);
  }

  Map<String, _ServerResourceMetadata> _cacheManagedRootMetadata(
    String rootPath,
    List<_ManagedRootRecord> records,
  ) {
    final results = <String, _ServerResourceMetadata>{};
    for (final record in records) {
      final lookupKeys = _metadataLookupKeysForStoredRecord(
        rootPath,
        record.rawId,
        record.directoryPath,
      );
      if (lookupKeys.isEmpty) {
        continue;
      }
      for (final key in lookupKeys) {
        if (key.contains('/') || key.startsWith('id::')) {
          results[key] = record.metadata;
        } else {
          results.putIfAbsent(key, () => record.metadata);
        }
      }
    }
    _metadataCacheByRoot[rootPath] = results;
    return results;
  }

  Future<List<_ManagedRootRecord>> _loadManagedRootRecords(
    String rootTitle,
    String rootPath,
  ) async {
    final dbPath = '$rootPath${Platform.pathSeparator}download.db';
    final dbBytes = await PrivilegedStorageAccess.readFileBytes(dbPath);
    if (dbBytes == null || dbBytes.isEmpty) {
      return const <_ManagedRootRecord>[];
    }

    final snapshotFile = await _writeDatabaseSnapshot(rootPath, dbBytes);
    if (snapshotFile == null) {
      return const <_ManagedRootRecord>[];
    }

    Database? db;
    final results = <_ManagedRootRecord>[];
    try {
      db = sqlite3.open(snapshotFile.path);
      final rows = db.select(
        'select id, title, subtitle, time, directory, json from download',
      );
      for (final row in rows) {
        final rawId = row['id']?.toString() ?? '';
        final rawDirectory = row['directory']?.toString() ?? '';
        final rawJson = row['json']?.toString() ?? '';
        final rawTime = (row['time'] as num?)?.toInt();
        final itemTime = rawTime == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(rawTime);
        final data = _decodeJsonMap(rawJson);
        final parsedItem = _parseDownloadedRecord(
          rawId,
          data,
          directory: rawDirectory,
          fallbackTitle: row['title']?.toString() ?? '',
          fallbackSubtitle: row['subtitle']?.toString() ?? '',
          fallbackSourceDisplayName: rootTitle,
        );
        final metadata = await _extractDownloadMetadata(
          id: rawId,
          title: row['title']?.toString() ?? '',
          subtitle: row['subtitle']?.toString() ?? '',
          updatedAt: itemTime,
          data: data,
          parsedItem: parsedItem,
          fallbackSourceDisplayName: rootTitle,
        );
        final directoryPath = _resolveManagedDirectoryPathFromMetadata(
          rootPath: rootPath,
          rawId: rawId,
          rawDirectory: rawDirectory,
          parsedItem: parsedItem,
        );
        if (directoryPath.isEmpty) {
          continue;
        }
        final comicSizeMb =
            parsedItem?.comicSizeMb ?? _extractComicSizeMb(data);
        results.add(
          _ManagedRootRecord(
            rawId: rawId,
            directoryPath: directoryPath,
            metadata: metadata,
            comicSizeMb: comicSizeMb,
          ),
        );
      }
    } catch (_) {
      return const <_ManagedRootRecord>[];
    } finally {
      db?.dispose();
      try {
        snapshotFile.deleteSync();
      } catch (_) {}
    }
    return results;
  }

  String _resolveManagedDirectoryPathFromMetadata({
    required String rootPath,
    required String rawId,
    required String rawDirectory,
    required _ParsedDownloadRecord? parsedItem,
  }) {
    final candidates = <String>[
      rawDirectory.trim(),
      parsedItem?.directory.trim() ?? '',
      rawId.trim(),
      parsedItem?.id.trim() ?? '',
      _basename(rawDirectory),
      _sanitizePathSegment(rawId),
      _sanitizePathSegment(parsedItem?.name ?? ''),
    ];
    for (final candidate in candidates) {
      final normalized = candidate.trim();
      if (normalized.isEmpty) {
        continue;
      }
      final resolved = _joinManagedPath(rootPath, normalized);
      if (resolved.isNotEmpty) {
        return resolved;
      }
    }
    return '';
  }

  Future<ServerResourceItemSummary?> _buildManagedShallowItem({
    required String rootId,
    required String rootTitle,
    required String directoryPath,
    required _ServerResourceMetadata metadata,
    required double? comicSizeMb,
  }) async {
    final episodes =
        _buildPlaceholderEpisodes(directoryPath, metadata.episodeTitles);
    if (episodes.isEmpty) {
      return null;
    }
    final title = _firstNonEmptyValue([
      metadata.title,
      _directoryTitle(directoryPath),
    ]);
    final fallbackSubtitle =
        episodes.length > 1 ? '${episodes.length} 个章节' : '';
    final subtitle = _firstNonEmptyValue([
      metadata.subtitle,
      fallbackSubtitle,
    ]);
    final sourceDisplayName = _firstNonEmptyValue([
      metadata.sourceDisplayName,
      rootTitle,
    ]);
    final displayId = _firstNonEmptyValue([
      metadata.displayId,
      _directoryTitle(directoryPath),
      _buildItemId(rootId, directoryPath),
    ]);
    final totalBytes = _comicSizeMbToBytes(comicSizeMb);
    final coverPath = _resolveShallowItemCoverPath(
      metadata.coverPath,
      directoryPath,
    );
    return ServerResourceItemSummary(
      id: _buildItemId(rootId, directoryPath),
      rootId: rootId,
      sourceTitle: rootTitle,
      sourceDisplayName: sourceDisplayName,
      title: title,
      displayId: displayId,
      subtitle: subtitle,
      tags: metadata.tags,
      path: directoryPath,
      imageCount: 0,
      totalBytes: totalBytes,
      coverPath: coverPath,
      episodes: episodes,
      updatedAt: metadata.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Future<bool> _hasManagedFallbackContent(String directoryPath) async {
    final entries =
        await PrivilegedStorageAccess.listDirectoryEntries(directoryPath);
    final childDirectories = <String>[];
    for (final entry in entries) {
      if (_isInServerTrash(entry.path)) {
        continue;
      }
      if (entry.isDirectory) {
        childDirectories.add(entry.path);
        continue;
      }
      if (_isImageFile(entry.path)) {
        return true;
      }
    }

    for (final childDirectory in childDirectories) {
      final childEntries = await PrivilegedStorageAccess.listDirectoryEntries(
        childDirectory,
      );
      for (final childEntry in childEntries) {
        if (childEntry.isDirectory || _isInServerTrash(childEntry.path)) {
          continue;
        }
        if (_isImageFile(childEntry.path)) {
          return true;
        }
      }
    }

    return false;
  }

  Future<ServerResourceItemSummary?> _buildManagedFallbackShallowItem({
    required String rootId,
    required String rootTitle,
    required String directoryPath,
  }) async {
    if (!await _hasManagedFallbackContent(directoryPath)) {
      return null;
    }
    final episodes = _buildPlaceholderEpisodes(directoryPath, const <String>[]);
    if (episodes.isEmpty) {
      return null;
    }
    final title = _directoryTitle(directoryPath);
    return ServerResourceItemSummary(
      id: _buildItemId(rootId, directoryPath),
      rootId: rootId,
      sourceTitle: rootTitle,
      sourceDisplayName: rootTitle,
      title: title,
      displayId: title,
      subtitle: episodes.length > 1 ? '${episodes.length} 个章节' : '',
      tags: const <String>[],
      path: directoryPath,
      imageCount: 0,
      totalBytes: 0,
      coverPath: '',
      episodes: episodes,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  bool _managedDirectoryExistsInIndex(
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

  String _normalizeManagedDirectoryPath(String rootPath, String directory) {
    final normalizedDirectory = directory.trim();
    if (normalizedDirectory.isEmpty) {
      return '';
    }

    final unifiedDirectory = normalizedDirectory.replaceAll('\\', '/');
    final isAbsolute = unifiedDirectory.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:/').hasMatch(unifiedDirectory);
    if (isAbsolute) {
      return _normalizePath(unifiedDirectory);
    }

    final normalizedRoot = rootPath.trim().replaceAll('\\', '/');
    if (normalizedRoot.isEmpty) {
      return _normalizePath(unifiedDirectory);
    }
    final joinedRoot = normalizedRoot.endsWith('/')
        ? normalizedRoot.substring(0, normalizedRoot.length - 1)
        : normalizedRoot;
    return _normalizePath('$joinedRoot/$unifiedDirectory');
  }

  String _joinManagedPath(String rootPath, String directory) {
    final normalizedDirectory = directory.trim();
    if (normalizedDirectory.isEmpty) {
      return '';
    }

    final unifiedDirectory = normalizedDirectory.replaceAll('\\', '/');
    final isAbsolute = unifiedDirectory.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:/').hasMatch(unifiedDirectory);
    if (isAbsolute) {
      return unifiedDirectory;
    }

    final normalizedRoot = rootPath.trim().replaceAll('\\', '/');
    if (normalizedRoot.isEmpty) {
      return unifiedDirectory;
    }
    final joinedRoot = normalizedRoot.endsWith('/')
        ? normalizedRoot.substring(0, normalizedRoot.length - 1)
        : normalizedRoot;
    return '$joinedRoot/$unifiedDirectory';
  }

  String _relativeManagedDirectoryPath(String rootPath, String directoryPath) {
    final normalizedRoot = _normalizePath(rootPath);
    final normalizedDirectory = _normalizePath(directoryPath);
    if (normalizedRoot.isEmpty || normalizedDirectory.isEmpty) {
      return '';
    }
    if (normalizedDirectory == normalizedRoot) {
      return '';
    }
    final prefix = '$normalizedRoot/';
    if (!normalizedDirectory.startsWith(prefix)) {
      return '';
    }
    return normalizedDirectory.substring(prefix.length);
  }

  _ServerResourceMetadata? _resolveManagedMetadata(
    Map<String, _ServerResourceMetadata> metadataByDirectory,
    String rootPath,
    String directoryPath,
  ) {
    for (final key in _metadataLookupKeysForResolvedDirectory(
      rootPath,
      directoryPath,
    )) {
      final metadata = metadataByDirectory[key];
      if (metadata != null) {
        return metadata;
      }
    }
    return null;
  }
}
