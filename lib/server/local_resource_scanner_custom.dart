part of 'local_resource_scanner.dart';

extension LocalResourceScannerCustom on LocalResourceScanner {
  bool _isCollectionShellEnabledForPath(
    String path,
    Map<String, bool> values,
  ) {
    final key = normalizeLocalCollectionShellPathKey(path);
    if (key.isEmpty) {
      return false;
    }
    return values[key] == true;
  }

  Future<List<ServerResourceItemSummary>> _scanCustomRootItems(
    String rootId,
    String rootTitle,
    String rootPath, {
    required bool collectionShellEnabled,
  }) async {
    final results = <ServerResourceItemSummary>[];
    if (collectionShellEnabled) {
      final shellDirectories = await _listDirectories(rootPath);
      if (shellDirectories.isEmpty) {
        results.addAll(await _scanCustomLeafAlbumItems(
          rootId,
          rootTitle,
          rootPath,
        ));
      } else {
        for (final shellPath in shellDirectories) {
          final shellItem = await _buildCustomCollectionShellItem(
            rootId: rootId,
            rootTitle: rootTitle,
            shellPath: shellPath,
          );
          if (shellItem != null) {
            results.add(shellItem);
            continue;
          }
          results.addAll(await _scanCustomLeafAlbumItems(
            rootId,
            rootTitle,
            shellPath,
          ));
        }
      }
      if (results.isEmpty) {
        results.addAll(await _scanCustomLeafAlbumItems(
          rootId,
          rootTitle,
          rootPath,
        ));
      }
    } else {
      results.addAll(await _scanCustomLeafAlbumItems(
        rootId,
        rootTitle,
        rootPath,
      ));
    }

    final archiveFiles = await _collectArchiveFiles(rootPath);
    for (final archivePath in archiveFiles) {
      final item = await _scanCustomArchiveItem(
        rootId: rootId,
        rootTitle: rootTitle,
        archivePath: archivePath,
      );
      if (item != null) {
        results.add(item);
      }
    }
    return results;
  }

  Future<List<ServerResourceItemSummary>> _scanCustomLeafAlbumItems(
    String rootId,
    String rootTitle,
    String rootPath,
  ) async {
    final results = <ServerResourceItemSummary>[];
    final directories = await _collectLeafAlbumDirectories(rootPath);
    for (final directory in directories) {
      final images = await _listDirectVisibleImages(directory);
      final displayTitle = _albumDisplayTitleForLeafDirectory(directory);
      final episodeTitle =
          _episodeTitleForLeafDirectory(directory, displayTitle);
      final episode = await _buildEpisodeSummary(
        index: 1,
        title: episodeTitle,
        directory: directory,
        images: images,
        includeTotalBytes: true,
      );
      if (episode == null) {
        continue;
      }
      results.add(
        ServerResourceItemSummary(
          id: _buildItemId(rootId, directory),
          rootId: rootId,
          sourceTitle: rootTitle,
          sourceDisplayName: '图集',
          title: displayTitle,
          displayId: displayTitle,
          subtitle: '',
          tags: const <String>[],
          path: directory,
          imageCount: episode.imageCount,
          totalBytes: episode.totalBytes,
          coverPath: episode.coverPath,
          episodes: [episode],
          updatedAt: await _directoryUpdatedAt(directory),
        ),
      );
    }
    return results;
  }

  Future<ServerResourceItemSummary?> _buildCustomCollectionShellItem({
    required String rootId,
    required String rootTitle,
    required String shellPath,
  }) async {
    final directImages = await _listDirectContentImages(shellPath);
    if (directImages.isNotEmpty) {
      return null;
    }

    final formalDirectories = await _listDirectories(shellPath);
    if (formalDirectories.isEmpty) {
      return null;
    }

    final shellTitle = _directoryTitle(shellPath);
    final episodes = <ServerResourceEpisodeSummary>[];
    for (final formalPath in formalDirectories) {
      final nextEpisodes = await _buildCollectionShellEpisodesForFormalPath(
        formalPath,
        shellTitle: shellTitle,
        startIndex: episodes.length + 1,
      );
      episodes.addAll(nextEpisodes);
    }
    if (episodes.isEmpty) {
      return null;
    }

    final imageCount =
        episodes.fold<int>(0, (sum, episode) => sum + episode.imageCount);
    final totalBytes =
        episodes.fold<int>(0, (sum, episode) => sum + episode.totalBytes);
    final title = _directoryTitle(shellPath);
    return ServerResourceItemSummary(
      id: _buildItemId(rootId, shellPath),
      rootId: rootId,
      sourceTitle: rootTitle,
      sourceDisplayName: '合集图集',
      title: title,
      displayId: title,
      subtitle: episodes.length > 1 ? '${episodes.length} 个章节' : '',
      tags: const <String>[],
      path: shellPath,
      imageCount: imageCount,
      totalBytes: totalBytes,
      coverPath: await _resolveCollectionShellCoverPath(
        shellPath,
        formalDirectories,
        episodes,
      ),
      episodes: episodes,
      updatedAt: await _collectionShellUpdatedAt(shellPath, episodes),
    );
  }

  Future<List<ServerResourceEpisodeSummary>>
      _buildCollectionShellEpisodesForFormalPath(
    String formalPath, {
    required String shellTitle,
    required int startIndex,
  }) async {
    final formalTitle = _stripCollectionShellParentPrefix(
      shellTitle,
      _directoryTitle(formalPath),
    );
    final episodes = <ServerResourceEpisodeSummary>[];
    final directImages = await _listDirectContentImages(formalPath);
    if (directImages.isNotEmpty) {
      final episode = await _buildEpisodeSummary(
        index: startIndex,
        title: formalTitle,
        directory: formalPath,
        images: directImages,
        includeTotalBytes: true,
      );
      if (episode != null) {
        episodes.add(episode);
      }
    }

    final chapterDirectories = await _listDirectories(formalPath);
    for (final chapterPath in chapterDirectories) {
      final images = await _listContentImages(chapterPath, recursive: true);
      final episode = await _buildEpisodeSummary(
        index: startIndex + episodes.length,
        title: _collectionShellEpisodeTitle(
          formalTitle,
          _directoryTitle(chapterPath),
        ),
        directory: chapterPath,
        images: images,
        includeTotalBytes: true,
      );
      if (episode != null) {
        episodes.add(episode);
      }
    }
    return episodes;
  }

  Future<String> _resolveCollectionShellCoverPath(
    String shellPath,
    List<String> formalDirectories,
    List<ServerResourceEpisodeSummary> episodes,
  ) async {
    final shellCover = await _findCoverLikeImage(shellPath);
    if (shellCover != null) {
      return shellCover;
    }
    for (final formalPath in formalDirectories) {
      final formalCover = await _findCoverLikeImage(formalPath);
      if (formalCover != null) {
        return formalCover;
      }
    }
    for (final episode in episodes) {
      final coverPath = episode.coverPath?.trim() ?? '';
      if (coverPath.isNotEmpty) {
        return coverPath;
      }
    }
    return '';
  }

  Future<DateTime> _collectionShellUpdatedAt(
    String shellPath,
    List<ServerResourceEpisodeSummary> episodes,
  ) async {
    var updatedAt = await _directoryUpdatedAt(shellPath);
    for (final episode in episodes) {
      final episodeUpdatedAt = await _directoryUpdatedAt(episode.path);
      if (episodeUpdatedAt.isAfter(updatedAt)) {
        updatedAt = episodeUpdatedAt;
      }
    }
    return updatedAt;
  }

  String _collectionShellEpisodeTitle(String formalTitle, String chapterTitle) {
    final normalizedFormal = formalTitle.trim();
    final normalizedChapter = chapterTitle.trim();
    if (normalizedFormal.isEmpty) {
      return normalizedChapter;
    }
    if (normalizedChapter.isEmpty || normalizedChapter == normalizedFormal) {
      return normalizedFormal;
    }
    final numeric = int.tryParse(normalizedChapter);
    if (numeric != null) {
      return '$normalizedFormal 第$numeric话';
    }
    return normalizedChapter;
  }

  String _stripCollectionShellParentPrefix(String shellTitle, String title) {
    final normalizedShell = shellTitle.trim();
    final normalizedTitle = title.trim();
    if (normalizedShell.isEmpty ||
        !normalizedTitle.startsWith(normalizedShell)) {
      return title;
    }
    final rest = normalizedTitle.substring(normalizedShell.length).trimLeft();
    final cleaned =
        rest.replaceFirst(RegExp(r'^[\s/_\\\-—:：]+'), '').trimLeft();
    return cleaned.isEmpty ? title : cleaned;
  }

  String _albumDisplayTitleForLeafDirectory(String directoryPath) {
    final leafTitle = _directoryTitle(directoryPath).trim();
    if (!_isPlainNumericTitle(leafTitle)) {
      return leafTitle;
    }
    final parentTitle = _parentDirectoryTitle(directoryPath).trim();
    return parentTitle.isEmpty ? leafTitle : parentTitle;
  }

  String _episodeTitleForLeafDirectory(
      String directoryPath, String displayTitle) {
    final leafTitle = _directoryTitle(directoryPath).trim();
    final normalizedDisplay = displayTitle.trim();
    if (_isPlainNumericTitle(leafTitle)) {
      final numeric = int.tryParse(leafTitle);
      if (numeric != null && normalizedDisplay.isNotEmpty) {
        return '$normalizedDisplay 第$numeric话';
      }
    }
    return '全部';
  }

  String _parentDirectoryTitle(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.length < 2) {
      return '';
    }
    return parts[parts.length - 2];
  }

  bool _isPlainNumericTitle(String value) {
    return RegExp(r'^\d+$').hasMatch(value.trim());
  }

  Future<ServerResourceItemSummary?> _scanCustomArchiveItem({
    required String rootId,
    required String rootTitle,
    required String archivePath,
  }) async {
    final format = archiveFormatForPath(archivePath);
    if (format == ArchiveFormat.unknown) {
      return null;
    }

    final ArchiveIndex index;
    try {
      index = await ArchiveReadingService.instance.getIndex(archivePath);
    } catch (_) {
      return null;
    }
    if (index.imageEntries.isEmpty) {
      return null;
    }

    final built = buildArchiveEpisodes(index);
    if (built.episodeFiles.isEmpty) {
      return null;
    }

    final fileStat = await File(archivePath).stat();
    final isEncrypted = index.isEncrypted;
    final hasSessionPassword =
        ArchivePasswordStore.instance.getSessionPassword(archivePath) != null;
    final archivePasswordMatched = !isEncrypted || hasSessionPassword;
    final coverEntry = pickArchiveCoverEntry(index);
    final coverUri = coverEntry == null
        ? null
        : buildArchiveUri(archivePath, coverEntry).toString();
    final sortedEpisodeIndexes = built.episodeFiles.keys.toList()..sort();
    final episodes = <ServerResourceEpisodeSummary>[
      for (var i = 0; i < sortedEpisodeIndexes.length; i++)
        ServerResourceEpisodeSummary(
          index: i + 1,
          title: _archiveEpisodeTitle(
            archivePath,
            i,
            built.realNames,
            built.episodeFiles.length,
          ),
          path: archivePath,
          imageCount: built.episodeFiles[sortedEpisodeIndexes[i]]?.length ?? 0,
          totalBytes: 0,
          coverPath: coverUri,
          imagePaths:
              built.episodeFiles[sortedEpisodeIndexes[i]] ?? const <String>[],
          imageSizes: List<ServerResourceImageSize?>.filled(
            built.episodeFiles[sortedEpisodeIndexes[i]]?.length ?? 0,
            null,
          ),
        ),
    ];
    final imageCount =
        episodes.fold<int>(0, (sum, episode) => sum + episode.imageCount);

    return ServerResourceItemSummary(
      id: _buildItemId(rootId, archivePath),
      rootId: rootId,
      sourceTitle: rootTitle,
      sourceDisplayName: isEncrypted ? '加密压缩包' : '压缩包',
      title: _basenameWithoutExtension(_basename(archivePath)),
      displayId: _basenameWithoutExtension(_basename(archivePath)),
      subtitle: episodes.length > 1 ? '${episodes.length} 个章节' : '',
      tags: const <String>[],
      path: archivePath,
      imageCount: imageCount,
      totalBytes: fileStat.size,
      coverPath: coverUri,
      episodes: episodes,
      updatedAt: fileStat.modified,
      isArchive: true,
      archiveEncrypted: isEncrypted,
      archivePasswordMatched: archivePasswordMatched,
      archiveFormat: format.name,
      archivePath: archivePath,
    );
  }

  List<ServerResourceEpisodeSummary> _buildPlaceholderEpisodes(
    String directoryPath,
    List<String> episodeTitles,
  ) {
    final titles = episodeTitles
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
    if (titles.isEmpty) {
      return [
        ServerResourceEpisodeSummary(
          index: 1,
          title: _directoryTitle(directoryPath),
          path: directoryPath,
          imageCount: 0,
          totalBytes: 0,
          coverPath: '',
          imagePaths: const <String>[],
          imageSizes: const <ServerResourceImageSize?>[],
        ),
      ];
    }
    return [
      for (var i = 0; i < titles.length; i++)
        ServerResourceEpisodeSummary(
          index: i + 1,
          title: titles[i],
          path: directoryPath,
          imageCount: 0,
          totalBytes: 0,
          coverPath: '',
          imagePaths: const <String>[],
          imageSizes: const <ServerResourceImageSize?>[],
        ),
    ];
  }

  Future<List<String>> _collectLeafAlbumDirectories(String rootPath) async {
    final results = <String>[];

    Future<bool> visit(String directoryPath) async {
      final children =
          await PrivilegedStorageAccess.listDirectoryEntries(directoryPath);
      final hasImages = children.any((entry) =>
          !entry.isDirectory &&
          !_isInServerTrash(entry.path) &&
          _isImageFile(entry.path) &&
          !_basename(entry.path).startsWith('.'));
      var hasAlbumDescendant = false;
      for (final child in children.where((entry) => entry.isDirectory)) {
        if (_basename(child.path) == _serverTrashDirectoryName) {
          continue;
        }
        if (await visit(child.path)) {
          hasAlbumDescendant = true;
        }
      }
      if (hasImages && !hasAlbumDescendant) {
        results.add(directoryPath);
        return true;
      }
      return hasImages || hasAlbumDescendant;
    }

    await visit(rootPath);
    results
        .sort((a, b) => _naturalCompare(_normalizePath(a), _normalizePath(b)));
    return results;
  }

  Future<List<String>> _collectArchiveFiles(String rootPath) async {
    final results = <String>[];

    Future<void> visit(String directoryPath) async {
      final entries =
          await PrivilegedStorageAccess.listDirectoryEntries(directoryPath);
      for (final entry in entries) {
        if (_isInServerTrash(entry.path)) {
          continue;
        }
        if (entry.isDirectory) {
          await visit(entry.path);
          continue;
        }
        if (isArchivePath(entry.path) &&
            !_basename(entry.path).startsWith('.')) {
          results.add(entry.path);
        }
      }
    }

    await visit(rootPath);
    results
        .sort((a, b) => _naturalCompare(_normalizePath(a), _normalizePath(b)));
    return results;
  }

  String _archiveEpisodeTitle(
    String archivePath,
    int displayIndex,
    List<String> realNames,
    int episodeCount,
  ) {
    final realName = displayIndex >= 0 && displayIndex < realNames.length
        ? realNames[displayIndex].trim()
        : '';
    if (realName.isNotEmpty) {
      return realName;
    }
    if (episodeCount <= 1) {
      return _basenameWithoutExtension(_basename(archivePath));
    }
    return '第 ${displayIndex + 1} 章';
  }
}
