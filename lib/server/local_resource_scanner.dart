import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:picakeep/foundation/archive/archive_episode_builder.dart';
import 'package:picakeep/foundation/archive/archive_models.dart';
import 'package:picakeep/foundation/archive/archive_password_store.dart';
import 'package:picakeep/foundation/archive/archive_reading_service.dart';
import 'package:picakeep/foundation/local_library_settings.dart'
    show normalizeLocalCollectionShellPathKey;
import 'package:picakeep/foundation/privileged_storage_access.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';

part 'local_resource_scanner_managed.dart';
part 'local_resource_scanner_custom.dart';
part 'local_resource_scanner_metadata.dart';
part 'local_resource_scanner_cover.dart';
part 'local_resource_scanner_io.dart';
part 'local_resource_scanner_text.dart';

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

class _ParsedDownloadRecord {
  const _ParsedDownloadRecord({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.directory,
    required this.tags,
    required this.episodeTitles,
    required this.coverPath,
    required this.sourceDisplayName,
    required this.comicSizeMb,
    required this.data,
  });

  final String id;
  final String name;
  final String subtitle;
  final String directory;
  final List<String> tags;
  final List<String> episodeTitles;
  final String coverPath;
  final String sourceDisplayName;
  final double? comicSizeMb;
  final Map<String, dynamic> data;
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
    Map<String, bool> customLibraryCollectionShellModes =
        const <String, bool>{},
  }) async {
    _metadataCacheByRoot.clear();
    final roots = <ServerResourceRootSummary>[];
    final items = <ServerResourceItemSummary>[];

    final allRoots =
        <({String id, String title, String path, bool collectionShellEnabled})>[
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
}
