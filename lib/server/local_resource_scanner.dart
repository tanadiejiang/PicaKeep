import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:picakeep/foundation/archive/archive_episode_builder.dart';
import 'package:picakeep/foundation/archive/archive_models.dart';
import 'package:picakeep/foundation/archive/archive_password_store.dart';
import 'package:picakeep/foundation/archive/archive_reading_service.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/privileged_storage_access.dart';

const _serverTrashDirectoryName = '.picakeep_trash';

class ServerResourceRootSummary {
  const ServerResourceRootSummary({
    required this.id,
    required this.title,
    required this.path,
    required this.exists,
    required this.itemCount,
    required this.totalBytes,
    this.supportsCollectionShell = false,
    this.collectionShellEnabled = false,
  });

  final String id;
  final String title;
  final String path;
  final bool exists;
  final int itemCount;
  final int totalBytes;
  final bool supportsCollectionShell;
  final bool collectionShellEnabled;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'exists': exists,
        'itemCount': itemCount,
        'totalBytes': totalBytes,
        'supportsCollectionShell': supportsCollectionShell,
        'collectionShellEnabled': collectionShellEnabled,
      };
}

class ServerResourceImageSize {
  const ServerResourceImageSize({
    required this.width,
    required this.height,
  });

  final int width;
  final int height;

  Map<String, dynamic> toJson() => {
        'width': width,
        'height': height,
      };
}

class ServerResourceEpisodeSummary {
  const ServerResourceEpisodeSummary({
    required this.index,
    required this.title,
    required this.path,
    required this.imageCount,
    required this.totalBytes,
    required this.coverPath,
    required this.imagePaths,
    required this.imageSizes,
  });

  final int index;
  final String title;
  final String path;
  final int imageCount;
  final int totalBytes;
  final String? coverPath;
  final List<String> imagePaths;
  final List<ServerResourceImageSize?> imageSizes;

  Map<String, dynamic> toJson() => {
        'index': index,
        'title': title,
        'path': path,
        'imageCount': imageCount,
        'totalBytes': totalBytes,
        'coverPath': coverPath,
      };
}

class _ServerResourceMetadata {
  const _ServerResourceMetadata({
    required this.title,
    required this.subtitle,
    required this.displayId,
    required this.tags,
    required this.coverPath,
    required this.sourceDisplayName,
    required this.episodeTitles,
    required this.updatedAt,
  });

  final String title;
  final String subtitle;
  final String displayId;
  final List<String> tags;
  final String coverPath;
  final String sourceDisplayName;
  final List<String> episodeTitles;
  final DateTime? updatedAt;
}

class _ManagedRootRecord {
  const _ManagedRootRecord({
    required this.rawId,
    required this.directoryPath,
    required this.metadata,
    required this.comicSizeMb,
  });

  final String rawId;
  final String directoryPath;
  final _ServerResourceMetadata metadata;
  final double? comicSizeMb;
}

class ServerResourceItemSummary {
  const ServerResourceItemSummary({
    required this.id,
    required this.rootId,
    required this.sourceTitle,
    required this.sourceDisplayName,
    required this.title,
    required this.displayId,
    required this.subtitle,
    required this.tags,
    required this.path,
    required this.imageCount,
    required this.totalBytes,
    required this.coverPath,
    required this.episodes,
    required this.updatedAt,
    this.isArchive = false,
    this.archiveEncrypted = false,
    this.archivePasswordMatched = true,
    this.archiveFormat = '',
    this.archivePath,
  });

  final String id;
  final String rootId;
  final String sourceTitle;
  final String sourceDisplayName;
  final String title;
  final String displayId;
  final String subtitle;
  final List<String> tags;
  final String path;
  final int imageCount;
  final int totalBytes;
  final String? coverPath;
  final List<ServerResourceEpisodeSummary> episodes;
  final DateTime updatedAt;
  final bool isArchive;
  final bool archiveEncrypted;
  final bool archivePasswordMatched;
  final String archiveFormat;
  final String? archivePath;

  bool get hasMultipleEpisodes => episodes.length > 1;

  Map<String, dynamic> toJson() => {
        'id': id,
        'rootId': rootId,
        'sourceTitle': sourceTitle,
        'sourceDisplayName': sourceDisplayName,
        'title': title,
        'displayId': displayId,
        'subtitle': subtitle,
        'tags': tags,
        'path': path,
        'imageCount': imageCount,
        'totalBytes': totalBytes,
        'coverPath': coverPath,
        'updatedAt': updatedAt.toIso8601String(),
        'itemKind': isArchive ? 'archive' : 'directory',
        'isArchive': isArchive,
        'archiveEncrypted': archiveEncrypted,
        'archivePasswordMatched': archivePasswordMatched,
        'archiveFormat': archiveFormat,
        'archivePath': archivePath,
        'episodeCount': episodes.length,
        'hasMultipleEpisodes': hasMultipleEpisodes,
        'episodes': episodes.map((e) => e.toJson()).toList(),
      };
}

class ServerResourceSnapshot {
  const ServerResourceSnapshot({
    required this.generatedAt,
    required this.totalComicCount,
    required this.totalBytes,
    required this.roots,
    required this.items,
  });

  final DateTime generatedAt;
  final int totalComicCount;
  final int totalBytes;
  final List<ServerResourceRootSummary> roots;
  final List<ServerResourceItemSummary> items;

  ServerResourceItemSummary? findItemById(String id) {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      return null;
    }
    for (final item in items) {
      if (item.id == normalizedId) {
        return item;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'generatedAt': generatedAt.toIso8601String(),
        'totalComicCount': totalComicCount,
        'totalBytes': totalBytes,
        'roots': roots.map((e) => e.toJson()).toList(),
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class LocalResourceScanner {
  final Map<String, Map<String, _ServerResourceMetadata>> _metadataCacheByRoot =
      <String, Map<String, _ServerResourceMetadata>>{};

  Future<ServerResourceSnapshot> scan({
    required String currentDownloadRoot,
    required String originalDownloadRoot,
    required List<String> customLibraryRoots,
    Map<String, bool> customLibraryCollectionShellModes = const <String, bool>{},
  }) async {
    _metadataCacheByRoot.clear();
    final roots = <ServerResourceRootSummary>[];
    final items = <ServerResourceItemSummary>[];

    final allRoots = <({String id, String title, String path, bool collectionShellEnabled})>[
      (
        id: 'current_download',
        title: '本应用下载目录',
        path: currentDownloadRoot.trim(),
        collectionShellEnabled: false,
      ),
      (
        id: 'original_download',
        title: '原应用下载目录',
        path: originalDownloadRoot.trim(),
        collectionShellEnabled: false,
      ),
      for (var i = 0; i < customLibraryRoots.length; i++)
        (
          id: 'custom_$i',
          title: '自定义路径 ${i + 1}',
          path: customLibraryRoots[i].trim(),
          collectionShellEnabled: _isCollectionShellEnabledForPath(
            customLibraryRoots[i],
            customLibraryCollectionShellModes,
          ),
        ),
    ].where((e) => e.path.isNotEmpty).toList();

    for (final root in allRoots) {
      if (!await PrivilegedStorageAccess.directoryExists(root.path)) {
        roots.add(
          ServerResourceRootSummary(
            id: root.id,
            title: root.title,
            path: root.path,
            exists: false,
            itemCount: 0,
            totalBytes: 0,
            supportsCollectionShell: root.id.startsWith('custom_'),
            collectionShellEnabled: root.collectionShellEnabled,
          ),
        );
        continue;
      }

      final discoveredItems = await _scanRootItems(
        root.id,
        root.title,
        root.path,
        collectionShellEnabled: root.collectionShellEnabled,
      );
      final totalBytes = discoveredItems.fold<int>(
        0,
        (sum, item) => sum + item.totalBytes,
      );
      roots.add(
        ServerResourceRootSummary(
          id: root.id,
          title: root.title,
          path: root.path,
          exists: true,
          itemCount: discoveredItems.length,
          totalBytes: totalBytes,
          supportsCollectionShell: root.id.startsWith('custom_'),
          collectionShellEnabled: root.collectionShellEnabled,
        ),
      );
      items.addAll(discoveredItems);
    }

    return ServerResourceSnapshot(
      generatedAt: DateTime.now(),
      totalComicCount: items.length,
      totalBytes: items.fold<int>(0, (sum, item) => sum + item.totalBytes),
      roots: roots,
      items: items,
    );
  }

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

  Future<String> resolveCoverPathOnly(
    ServerResourceItemSummary shallow, {
    required String? rootPath,
  }) async {
    final metadataCoverPath = shallow.coverPath?.trim() ?? '';
    if (metadataCoverPath.isNotEmpty &&
        await PrivilegedStorageAccess.fileExists(metadataCoverPath)) {
      return metadataCoverPath;
    }

    final directCover = await _findCoverLikeImage(shallow.path);
    if (directCover != null) {
      return directCover;
    }

    final directImages = await _listDirectVisibleImages(shallow.path);
    if (directImages.isNotEmpty) {
      return directImages.first;
    }

    final children = await _listDirectories(shallow.path);
    if (children.isEmpty) {
      return '';
    }
    final firstChildImages = await _listDirectVisibleImages(children.first);
    if (firstChildImages.isNotEmpty) {
      return firstChildImages.first;
    }
    return '';
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
      final episodeTitle = _episodeTitleForLeafDirectory(directory, displayTitle);
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
    if (normalizedShell.isEmpty || !normalizedTitle.startsWith(normalizedShell)) {
      return title;
    }
    final rest = normalizedTitle.substring(normalizedShell.length).trimLeft();
    final cleaned = rest.replaceFirst(RegExp(r'^[\s/_\\\-—:：]+'), '').trimLeft();
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

  String _episodeTitleForLeafDirectory(String directoryPath, String displayTitle) {
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

  Future<List<String>> _listDirectContentImages(String directoryPath) async {
    final images = await _listDirectVisibleImages(directoryPath);
    return images.where((path) => !_isCoverLikeFile(path)).toList();
  }

  Future<List<String>> _listContentImages(
    String directoryPath, {
    required bool recursive,
  }) async {
    final images = await _listImageFiles(directoryPath, recursive: recursive);
    return images.where((path) => !_isCoverLikeFile(path)).toList();
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
        final parsedItem = parseDownloadedItemRecordJson(
          rawId,
          rawJson,
          time: itemTime,
          directory: rawDirectory,
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
        final comicSizeMb = _normalizeComicSizeMb(parsedItem?.comicSize) ??
            _extractComicSizeMb(data);
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

  Future<File?> _writeDatabaseSnapshot(
      String rootPath, List<int> dbBytes) async {
    try {
      final supportDir = await getApplicationSupportDirectory();
      final dbDir = Directory(
          '${supportDir.path}${Platform.pathSeparator}server_db_snapshots');
      await dbDir.create(recursive: true);
      final safeName = _safeCacheName(rootPath);
      final snapshotFile =
          File('${dbDir.path}${Platform.pathSeparator}$safeName.db');
      await snapshotFile.writeAsBytes(dbBytes, flush: true);
      return snapshotFile;
    } catch (_) {
      return null;
    }
  }

  String _safeCacheName(String value) {
    final sanitized = value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return sanitized.isEmpty ? 'default' : sanitized;
  }

  Future<_ServerResourceMetadata> _extractDownloadMetadata({
    required String id,
    required String title,
    required String subtitle,
    required DateTime? updatedAt,
    required Map<String, dynamic>? data,
    required DownloadedItem? parsedItem,
    required String fallbackSourceDisplayName,
  }) async {
    final comicItem = data?['comicItem'];
    final comicItemMap = comicItem is Map
        ? comicItem.map((key, value) => MapEntry(key.toString(), value))
        : null;
    final parsedJson = parsedItem?.toJson();
    final parsedTags = parsedItem?.tags
            .map((entry) => entry.trim())
            .where((entry) => entry.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    final parsedEpisodeTitles = _parsedEpisodeTitles(parsedItem);
    return _ServerResourceMetadata(
      title: _firstNonEmptyValue([
        parsedItem?.name,
        title,
        data?['title']?.toString(),
        comicItemMap?['title']?.toString(),
      ]),
      subtitle: _firstNonEmptyValue([
        parsedItem?.subTitle,
        subtitle,
        data?['subtitle']?.toString(),
        data?['subTitle']?.toString(),
        data?['author']?.toString(),
        comicItemMap?['subTitle']?.toString(),
        comicItemMap?['author']?.toString(),
      ]),
      displayId: _firstNonEmptyValue([
        data?['displayId']?.toString(),
        data?['comicId']?.toString(),
        parsedJson?['displayId']?.toString(),
        parsedJson?['comicId']?.toString(),
        parsedJson?['comicID']?.toString(),
        comicItemMap?['displayId']?.toString(),
        comicItemMap?['comicId']?.toString(),
        comicItemMap?['id']?.toString(),
        parsedItem?.id,
        id,
      ]),
      tags: parsedTags.isNotEmpty
          ? parsedTags
          : _extractTagValues(data, comicItemMap),
      coverPath: _extractCoverPath(data, comicItemMap, parsedItem),
      sourceDisplayName: _firstNonEmptyValue([
        data?['sourceDisplayName']?.toString(),
        parsedItem?.sourceDisplayName,
        _inferSourceDisplayName(id, data),
        fallbackSourceDisplayName,
      ]),
      episodeTitles: parsedEpisodeTitles.isNotEmpty
          ? parsedEpisodeTitles
          : _extractEpisodeTitles(data, comicItemMap),
      updatedAt: updatedAt,
    );
  }

  String _resolveManagedDirectoryPathFromMetadata({
    required String rootPath,
    required String rawId,
    required String rawDirectory,
    required DownloadedItem? parsedItem,
  }) {
    final candidates = <String>[
      rawDirectory.trim(),
      parsedItem?.directory?.trim() ?? '',
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

  Future<Set<String>> _listRootDirectoryNames(String rootPath) async {
    final names = <String>{};
    final entries =
        await PrivilegedStorageAccess.listDirectoryEntries(rootPath);
    for (final entry in entries) {
      if (!entry.isDirectory ||
          _basename(entry.path) == _serverTrashDirectoryName) {
        continue;
      }
      names.add(entry.name.toLowerCase());
    }
    return names;
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

  String _sanitizePathSegment(String value) {
    final sanitized = value.trim().replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    return sanitized.isEmpty ? '' : sanitized;
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

  List<String> _metadataLookupKeysForStoredRecord(
    String rootPath,
    String rawId,
    String rawDirectory,
  ) {
    final keys = <String>[];

    void add(String value) {
      final normalized = value.trim();
      if (normalized.isEmpty || keys.contains(normalized)) {
        return;
      }
      keys.add(normalized);
    }

    final normalizedDirectoryPath =
        _normalizeManagedDirectoryPath(rootPath, rawDirectory);
    final relativeDirectoryPath =
        _relativeManagedDirectoryPath(rootPath, normalizedDirectoryPath);

    add('id::${rawId.trim()}');
    add(normalizedDirectoryPath);
    add(relativeDirectoryPath);
    add(_normalizePath(rawDirectory));
    add(_normalizePath(_basename(rawDirectory)));
    add(_normalizePath(_basename(normalizedDirectoryPath)));
    add(_normalizePath(_basename(relativeDirectoryPath)));
    return keys;
  }

  List<String> _metadataLookupKeysForResolvedDirectory(
    String rootPath,
    String directoryPath,
  ) {
    final keys = <String>[];

    void add(String value) {
      final normalized = value.trim();
      if (normalized.isEmpty || keys.contains(normalized)) {
        return;
      }
      keys.add(normalized);
    }

    final normalizedDirectoryPath = _normalizePath(directoryPath);
    final relativeDirectoryPath =
        _relativeManagedDirectoryPath(rootPath, normalizedDirectoryPath);

    add(normalizedDirectoryPath);
    add(relativeDirectoryPath);
    add(_normalizePath(_basename(directoryPath)));
    add(_normalizePath(_basename(normalizedDirectoryPath)));
    add(_normalizePath(_basename(relativeDirectoryPath)));
    return keys;
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

  Map<String, dynamic>? _decodeJsonMap(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {}
    return null;
  }

  List<String> _parsedEpisodeTitles(DownloadedItem? parsedItem) {
    if (parsedItem == null) {
      return const <String>[];
    }
    final titles = parsedItem.eps
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
    if (titles.isEmpty) {
      return const <String>[];
    }
    if (titles.length == 1 && titles.first == parsedItem.name.trim()) {
      return const <String>[];
    }
    return titles;
  }

  Iterable<Map<String, dynamic>> _candidateMetadataMaps(
    Map<String, dynamic>? data,
    Map<String, dynamic>? comicItemMap,
  ) sync* {
    for (final map in [
      data,
      comicItemMap,
      _asStringDynamicMap(data?['comic']),
      _asStringDynamicMap(data?['gallery']),
      _asStringDynamicMap(data?['metadata']),
      _asStringDynamicMap(data?['detail']),
      _asStringDynamicMap(comicItemMap?['comic']),
      _asStringDynamicMap(comicItemMap?['gallery']),
      _asStringDynamicMap(comicItemMap?['metadata']),
      _asStringDynamicMap(comicItemMap?['detail']),
    ]) {
      if (map != null) {
        yield map;
      }
    }
  }

  Map<String, dynamic>? _asStringDynamicMap(Object? raw) {
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  List<String> _extractTagValues(
    Map<String, dynamic>? data,
    Map<String, dynamic>? comicItemMap,
  ) {
    for (final map in _candidateMetadataMaps(data, comicItemMap)) {
      for (final key in const [
        'tagList',
        'tags',
        'metadataTags',
        'categories',
        'category',
        'groups',
        'labels',
        'keywords',
      ]) {
        final tags = _normalizeTagValues(map[key]);
        if (tags.isNotEmpty) {
          return tags;
        }
      }
    }
    return const <String>[];
  }

  List<String> _normalizeTagValues(Object? raw) {
    if (raw is List) {
      return raw
          .map(_tagValueFromEntry)
          .map((entry) => entry.trim())
          .where((entry) => entry.isNotEmpty)
          .toSet()
          .toList(growable: false);
    }
    if (raw is Map) {
      return raw.values
          .expand(_normalizeTagValues)
          .map((entry) => entry.trim())
          .where((entry) => entry.isNotEmpty)
          .toSet()
          .toList(growable: false);
    }
    if (raw is String) {
      final normalized = raw.trim();
      if (normalized.isEmpty) {
        return const <String>[];
      }
      if (normalized.startsWith('[') && normalized.endsWith(']')) {
        final decoded = _decodeJsonMap('{"tags":$normalized}')?['tags'];
        if (decoded != null) {
          return _normalizeTagValues(decoded);
        }
      }
      if (normalized.startsWith('{') && normalized.endsWith('}')) {
        final decoded = _decodeJsonMap(normalized);
        if (decoded != null) {
          return _normalizeTagValues(decoded);
        }
      }
      return normalized
          .split(RegExp(r'\s*[,，]\s*'))
          .map((entry) => entry.trim())
          .where((entry) => entry.isNotEmpty)
          .toSet()
          .toList(growable: false);
    }
    final single = raw?.toString().trim() ?? '';
    if (single.isEmpty) {
      return const <String>[];
    }
    return <String>[single];
  }

  String _tagValueFromEntry(Object? raw) {
    if (raw == null) {
      return '';
    }
    if (raw is Map) {
      final mapped = raw.map((key, value) => MapEntry(key.toString(), value));
      return _firstNonEmptyValue([
        mapped['tag']?.toString(),
        mapped['name']?.toString(),
        mapped['title']?.toString(),
        mapped['value']?.toString(),
      ]);
    }
    return raw.toString().trim();
  }

  List<String> _extractEpisodeTitles(
    Map<String, dynamic>? data,
    Map<String, dynamic>? comicItemMap,
  ) {
    for (final map in _candidateMetadataMaps(data, comicItemMap)) {
      for (final key in const [
        'chapters',
        'eps',
        'episodes',
        'episodeList',
        'chapterList',
        'epList',
        'epNames',
      ]) {
        final titles = _normalizeEpisodeTitles(map[key]);
        if (titles.isNotEmpty) {
          return titles;
        }
      }
    }
    return const <String>[];
  }

  double? _extractComicSizeMb(Map<String, dynamic>? data) {
    if (data == null) {
      return null;
    }
    for (final map in _candidateMetadataMaps(
        data, _asStringDynamicMap(data['comicItem']))) {
      final value = _normalizeComicSizeMb(
        map['comicSize'] ?? map['size'] ?? map['totalSize'],
      );
      if (value != null) {
        return value;
      }
    }
    return null;
  }

  double? _normalizeComicSizeMb(Object? raw) {
    if (raw is num) {
      final value = raw.toDouble();
      return value > 0 ? value : null;
    }
    if (raw is String) {
      final value = double.tryParse(raw.trim());
      if (value != null && value > 0) {
        return value;
      }
    }
    return null;
  }

  int _comicSizeMbToBytes(double? comicSizeMb) {
    if (comicSizeMb == null || comicSizeMb <= 0) {
      return 0;
    }
    return (comicSizeMb * 1024 * 1024).round();
  }

  List<String> _normalizeEpisodeTitles(Object? raw) {
    if (raw is List) {
      return raw
          .map((entry) => _episodeTitleFromValue(entry))
          .where((entry) => entry.isNotEmpty)
          .toList(growable: false);
    }
    if (raw is Map) {
      final entries = raw.entries.toList()
        ..sort((a, b) => (int.tryParse(a.key.toString()) ?? 0).compareTo(
              int.tryParse(b.key.toString()) ?? 0,
            ));
      return entries
          .map((entry) => _episodeTitleFromValue(entry.value))
          .where((entry) => entry.isNotEmpty)
          .toList(growable: false);
    }
    final single = _episodeTitleFromValue(raw);
    return single.isEmpty ? const <String>[] : <String>[single];
  }

  String _episodeTitleFromValue(Object? raw) {
    if (raw == null) {
      return '';
    }
    if (raw is String) {
      return raw.trim();
    }
    if (raw is Map) {
      final mapped = raw.map((key, value) => MapEntry(key.toString(), value));
      return _firstNonEmptyValue([
        mapped['title']?.toString(),
        mapped['name']?.toString(),
        mapped['chapter']?.toString(),
        mapped['epName']?.toString(),
        mapped['shortTitle']?.toString(),
        mapped['value']?.toString(),
      ]);
    }
    return raw.toString().trim();
  }

  List<ServerResourceEpisodeSummary> _applyEpisodeTitles(
    List<ServerResourceEpisodeSummary> episodes,
    List<String> titles,
  ) {
    if (episodes.isEmpty || titles.isEmpty) {
      return episodes;
    }
    return [
      for (var i = 0; i < episodes.length; i++)
        ServerResourceEpisodeSummary(
          index: episodes[i].index,
          title: i < titles.length && titles[i].trim().isNotEmpty
              ? titles[i].trim()
              : episodes[i].title,
          path: episodes[i].path,
          imageCount: episodes[i].imageCount,
          totalBytes: episodes[i].totalBytes,
          coverPath: episodes[i].coverPath,
          imagePaths: episodes[i].imagePaths,
          imageSizes: episodes[i].imageSizes,
        ),
    ];
  }

  String _firstNonEmptyValue(Iterable<String?> values) {
    for (final value in values) {
      final normalized = value?.trim() ?? '';
      if (normalized.isNotEmpty) {
        return normalized;
      }
    }
    return '';
  }

  String _inferSourceDisplayName(String id, Map<String, dynamic>? data) {
    final sourceKey =
        (data?['sourceKey']?.toString() ?? '').trim().toLowerCase();
    if (sourceKey == 'copy_manga') return '拷贝漫画';
    if (sourceKey == 'komiic') return 'Komiic';
    if (sourceKey == 'jm') return '禁漫';
    if (sourceKey == 'hitomi') return 'Hitomi';
    if (sourceKey == 'nhentai') return 'NHentai';
    if (sourceKey == 'htmanga') return '绅士漫画';
    if (sourceKey == 'ehentai') return 'E-Hentai';
    if (sourceKey == 'picacg') return '哔咔';

    final normalizedId = id.trim().toLowerCase();
    if (normalizedId.startsWith('jm')) return '禁漫';
    if (normalizedId.startsWith('hitomi')) return 'Hitomi';
    if (normalizedId.startsWith('nhentai')) return 'NHentai';
    if (normalizedId.startsWith('ht')) return '绅士漫画';
    if (normalizedId.contains('-')) {
      final prefix = normalizedId.split('-').first;
      if (prefix == 'copy_manga') return '拷贝漫画';
      if (prefix == 'komiic') return 'Komiic';
    }
    if (RegExp(r'^[0-9a-f]{24}$').hasMatch(normalizedId)) return '哔咔';
    if (RegExp(r'^\d+$').hasMatch(normalizedId)) return 'E-Hentai';
    return '';
  }

  Future<ServerResourceEpisodeSummary?> _buildEpisodeSummary({
    required int index,
    required String title,
    required String directory,
    required List<String> images,
    required bool includeTotalBytes,
  }) async {
    if (images.isEmpty) {
      return null;
    }

    return ServerResourceEpisodeSummary(
      index: index,
      title: title,
      path: directory,
      imageCount: images.length,
      totalBytes: includeTotalBytes ? await _calculateTotalBytes(images) : 0,
      coverPath: await _resolveEpisodeCoverPath(directory, images),
      imagePaths: images,
      imageSizes: List<ServerResourceImageSize?>.filled(images.length, null),
    );
  }

  String _extractCoverPath(
    Map<String, dynamic>? data,
    Map<String, dynamic>? comicItemMap,
    DownloadedItem? parsedItem,
  ) {
    final parsedCover = parsedItem?.localCoverPath?.trim() ?? '';
    if (parsedCover.isNotEmpty) {
      return parsedCover;
    }

    for (final map in _candidateMetadataMaps(data, comicItemMap)) {
      for (final key in const ['coverPath', 'cover', 'localCoverPath']) {
        final raw = map[key]?.toString().trim() ?? '';
        if (raw.isNotEmpty) {
          return raw;
        }
      }
    }
    return '';
  }

  String _resolveShallowItemCoverPath(
    String? metadataCoverPath,
    String directoryPath,
  ) {
    final normalizedMetadataPath = metadataCoverPath?.trim() ?? '';
    if (normalizedMetadataPath.isNotEmpty) {
      return normalizedMetadataPath;
    }
    return '';
  }

  Future<String> _resolveItemCoverPath(
    String? metadataCoverPath,
    String directoryPath,
    List<ServerResourceEpisodeSummary> episodes,
  ) async {
    final normalizedMetadataPath = metadataCoverPath?.trim() ?? '';
    if (normalizedMetadataPath.isNotEmpty &&
        await PrivilegedStorageAccess.fileExists(normalizedMetadataPath)) {
      return normalizedMetadataPath;
    }

    final coverFile = await _findCoverLikeImage(directoryPath);
    if (coverFile != null) {
      return coverFile;
    }

    for (final episode in episodes) {
      final coverPath = episode.coverPath?.trim() ?? '';
      if (coverPath.isNotEmpty) {
        return coverPath;
      }
    }
    return '';
  }

  Future<String> _resolveEpisodeCoverPath(
    String directoryPath,
    List<String> images,
  ) async {
    final coverFile = await _findCoverLikeImage(directoryPath);
    if (coverFile != null) {
      return coverFile;
    }
    return images.first;
  }

  Future<String?> _findCoverLikeImage(String directoryPath) async {
    final entries =
        await PrivilegedStorageAccess.listDirectoryEntries(directoryPath);
    for (final entry in entries) {
      if (entry.isDirectory) {
        continue;
      }
      if (!_isImageFile(entry.path) || _isInServerTrash(entry.path)) {
        continue;
      }
      if (_isCoverLikeFile(entry.path)) {
        return entry.path;
      }
    }
    return null;
  }

  Future<int> _calculateTotalBytes(List<String> filePaths) async {
    var totalBytes = 0;
    for (final filePath in filePaths) {
      final length = await PrivilegedStorageAccess.fileLength(filePath);
      if (length != null) {
        totalBytes += length;
      }
    }
    return totalBytes;
  }

  Future<DateTime> _directoryUpdatedAt(String directoryPath) async {
    try {
      return (await Directory(directoryPath).stat()).modified;
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  Future<List<String>> _listDirectories(String directoryPath) async {
    final results = <String>[];
    final entries =
        await PrivilegedStorageAccess.listDirectoryEntries(directoryPath);
    for (final entry in entries) {
      if (entry.isDirectory &&
          _basename(entry.path) != _serverTrashDirectoryName) {
        results.add(entry.path);
      }
    }
    results
        .sort((a, b) => _naturalCompare(_normalizePath(a), _normalizePath(b)));
    return results;
  }

  Future<List<String>> _listImageFiles(
    String directoryPath, {
    required bool recursive,
  }) async {
    final results = <String>[];
    await _collectImageFiles(directoryPath,
        recursive: recursive, sink: results);
    results
        .sort((a, b) => _naturalCompare(_normalizePath(a), _normalizePath(b)));
    final visibleFiles =
        results.where((file) => !_isCoverLikeFile(file)).toList();
    return visibleFiles.isNotEmpty ? visibleFiles : results;
  }

  Future<void> _collectImageFiles(
    String directoryPath, {
    required bool recursive,
    required List<String> sink,
  }) async {
    final entries =
        await PrivilegedStorageAccess.listDirectoryEntries(directoryPath);
    for (final entry in entries) {
      if (_isInServerTrash(entry.path)) {
        continue;
      }
      if (entry.isDirectory) {
        if (recursive) {
          await _collectImageFiles(entry.path, recursive: true, sink: sink);
        }
        continue;
      }
      if (!_isImageFile(entry.path)) {
        continue;
      }
      sink.add(entry.path);
    }
  }

  Future<List<String>> _listDirectVisibleImages(String directoryPath) async {
    final results = <String>[];
    final entries =
        await PrivilegedStorageAccess.listDirectoryEntries(directoryPath);
    for (final entry in entries) {
      if (entry.isDirectory || _isInServerTrash(entry.path)) {
        continue;
      }
      if (!_isImageFile(entry.path)) {
        continue;
      }
      results.add(entry.path);
    }
    results
        .sort((a, b) => _naturalCompare(_normalizePath(a), _normalizePath(b)));
    final visibleFiles =
        results.where((file) => !_isCoverLikeFile(file)).toList();
    return visibleFiles.isNotEmpty ? visibleFiles : results;
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

  bool _isInServerTrash(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized
        .split('/')
        .any((segment) => segment == _serverTrashDirectoryName);
  }

  bool _isCoverLikeFile(String path) {
    final name = _basename(path).toLowerCase();
    return name == 'cover.jpg' ||
        name == 'cover.jpeg' ||
        name == 'cover.png' ||
        name == 'cover.webp';
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts =
        normalized.split('/').where((entry) => entry.isNotEmpty).toList();
    return parts.isEmpty ? normalized : parts.last;
  }

  String _basenameWithoutExtension(String name) {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex > 0) {
      return name.substring(0, dotIndex);
    }
    return name;
  }

  String _buildItemId(String rootId, String path) {
    final raw = utf8.encode('$rootId::$path');
    return base64Url.encode(raw).replaceAll('=', '');
  }

  bool _isImageFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.bmp');
  }

  String _directoryTitle(String directoryPath) {
    final normalized = directoryPath.replaceAll('\\', '/');
    final parts = normalized.split('/').where((e) => e.isNotEmpty).toList();
    return parts.isEmpty ? directoryPath : parts.last;
  }

  String _normalizePath(String path) {
    return path.replaceAll('\\', '/').toLowerCase();
  }

  int _naturalCompare(String a, String b) {
    final aTokens = _naturalTokens(a);
    final bTokens = _naturalTokens(b);
    final length =
        aTokens.length < bTokens.length ? aTokens.length : bTokens.length;
    for (var i = 0; i < length; i++) {
      final left = aTokens[i];
      final right = bTokens[i];
      if (left is int && right is int) {
        final compare = left.compareTo(right);
        if (compare != 0) {
          return compare;
        }
        continue;
      }
      final compare = left.toString().compareTo(right.toString());
      if (compare != 0) {
        return compare;
      }
    }
    return aTokens.length.compareTo(bTokens.length);
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

  List<Object> _naturalTokens(String value) {
    final matches = RegExp(r'(\d+|\D+)').allMatches(value);
    return matches.map((match) {
      final part = match.group(0)!;
      final number = int.tryParse(part);
      return number ?? part;
    }).toList(growable: false);
  }
}
