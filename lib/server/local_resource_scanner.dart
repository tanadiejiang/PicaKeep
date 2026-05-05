import 'dart:convert';
import 'dart:io';

class ServerResourceRootSummary {
  const ServerResourceRootSummary({
    required this.id,
    required this.title,
    required this.path,
    required this.exists,
    required this.itemCount,
    required this.totalBytes,
  });

  final String id;
  final String title;
  final String path;
  final bool exists;
  final int itemCount;
  final int totalBytes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'exists': exists,
        'itemCount': itemCount,
        'totalBytes': totalBytes,
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
  });

  final int index;
  final String title;
  final String path;
  final int imageCount;
  final int totalBytes;
  final String? coverPath;
  final List<String> imagePaths;

  Map<String, dynamic> toJson() => {
        'index': index,
        'title': title,
        'path': path,
        'imageCount': imageCount,
        'totalBytes': totalBytes,
        'coverPath': coverPath,
      };
}

class ServerResourceItemSummary {
  const ServerResourceItemSummary({
    required this.id,
    required this.rootId,
    required this.sourceTitle,
    required this.title,
    required this.path,
    required this.imageCount,
    required this.totalBytes,
    required this.coverPath,
    required this.episodes,
  });

  final String id;
  final String rootId;
  final String sourceTitle;
  final String title;
  final String path;
  final int imageCount;
  final int totalBytes;
  final String? coverPath;
  final List<ServerResourceEpisodeSummary> episodes;

  bool get hasMultipleEpisodes => episodes.length > 1;

  Map<String, dynamic> toJson() => {
        'id': id,
        'rootId': rootId,
        'sourceTitle': sourceTitle,
        'title': title,
        'path': path,
        'imageCount': imageCount,
        'totalBytes': totalBytes,
        'coverPath': coverPath,
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
  Future<ServerResourceSnapshot> scan({
    required String currentDownloadRoot,
    required String originalDownloadRoot,
    required List<String> customLibraryRoots,
  }) async {
    final roots = <ServerResourceRootSummary>[];
    final items = <ServerResourceItemSummary>[];

    final allRoots = <({String id, String title, String path})>[
      (
        id: 'current_download',
        title: '本应用下载目录',
        path: currentDownloadRoot.trim(),
      ),
      (
        id: 'original_download',
        title: '原应用下载目录',
        path: originalDownloadRoot.trim(),
      ),
      for (var i = 0; i < customLibraryRoots.length; i++)
        (
          id: 'custom_$i',
          title: '自定义路径 ${i + 1}',
          path: customLibraryRoots[i].trim(),
        ),
    ].where((e) => e.path.isNotEmpty).toList();

    for (final root in allRoots) {
      final directory = Directory(root.path);
      if (!await directory.exists()) {
        roots.add(
          ServerResourceRootSummary(
            id: root.id,
            title: root.title,
            path: root.path,
            exists: false,
            itemCount: 0,
            totalBytes: 0,
          ),
        );
        continue;
      }

      final discoveredItems = await _scanRootItems(root.id, root.title, directory);
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

  Future<List<ServerResourceItemSummary>> _scanRootItems(
    String rootId,
    String rootTitle,
    Directory root,
  ) async {
    final results = <ServerResourceItemSummary>[];
    final rootItem = await _scanComicItem(rootId, rootTitle, root);
    if (rootItem != null) {
      results.add(rootItem);
      return results;
    }

    final children = await _listDirectories(root);
    for (final child in children) {
      final item = await _scanComicItem(rootId, rootTitle, child);
      if (item != null) {
        results.add(item);
      }
    }

    return results;
  }

  Future<ServerResourceItemSummary?> _scanComicItem(
    String rootId,
    String rootTitle,
    Directory directory,
  ) async {
    final directImages = await _listImageFiles(directory, recursive: false);
    final episodes = <ServerResourceEpisodeSummary>[];

    if (directImages.isNotEmpty) {
      final images = await _listImageFiles(directory, recursive: true);
      final episode = await _buildEpisodeSummary(
        index: 1,
        title: _directoryTitle(directory),
        directory: directory,
        images: images,
      );
      if (episode != null) {
        episodes.add(episode);
      }
    } else {
      final children = await _listDirectories(directory);
      for (final child in children) {
        final images = await _listImageFiles(child, recursive: true);
        final episode = await _buildEpisodeSummary(
          index: episodes.length + 1,
          title: _directoryTitle(child),
          directory: child,
          images: images,
        );
        if (episode != null) {
          episodes.add(episode);
        }
      }

      if (episodes.isEmpty) {
        final images = await _listImageFiles(directory, recursive: true);
        final episode = await _buildEpisodeSummary(
          index: 1,
          title: _directoryTitle(directory),
          directory: directory,
          images: images,
        );
        if (episode != null) {
          episodes.add(episode);
        }
      }
    }

    if (episodes.isEmpty) {
      return null;
    }

    final imageCount = episodes.fold<int>(0, (sum, item) => sum + item.imageCount);
    final totalBytes = episodes.fold<int>(0, (sum, item) => sum + item.totalBytes);
    return ServerResourceItemSummary(
      id: _buildItemId(rootId, directory.path),
      rootId: rootId,
      sourceTitle: rootTitle,
      title: _directoryTitle(directory),
      path: directory.path,
      imageCount: imageCount,
      totalBytes: totalBytes,
      coverPath: episodes.first.coverPath,
      episodes: episodes,
    );
  }

  Future<ServerResourceEpisodeSummary?> _buildEpisodeSummary({
    required int index,
    required String title,
    required Directory directory,
    required List<File> images,
  }) async {
    if (images.isEmpty) {
      return null;
    }

    return ServerResourceEpisodeSummary(
      index: index,
      title: title,
      path: directory.path,
      imageCount: images.length,
      totalBytes: await _calculateTotalBytes(images),
      coverPath: images.first.path,
      imagePaths: images.map((e) => e.path).toList(growable: false),
    );
  }

  Future<int> _calculateTotalBytes(List<File> files) async {
    var totalBytes = 0;
    for (final file in files) {
      try {
        totalBytes += await file.length();
      } catch (_) {}
    }
    return totalBytes;
  }

  Future<List<Directory>> _listDirectories(Directory directory) async {
    final results = <Directory>[];
    await for (final entity in directory.list(recursive: false, followLinks: false)) {
      if (entity is Directory) {
        results.add(entity);
      }
    }
    results.sort(_compareEntityPath);
    return results;
  }

  Future<List<File>> _listImageFiles(
    Directory directory, {
    required bool recursive,
  }) async {
    final results = <File>[];
    await for (final entity in directory.list(
      recursive: recursive,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      if (!_isImageFile(entity.path)) {
        continue;
      }
      results.add(entity);
    }
    results.sort(_compareEntityPath);
    return results;
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

  String _directoryTitle(Directory directory) {
    final normalized = directory.path.replaceAll('\\', '/');
    final parts = normalized.split('/').where((e) => e.isNotEmpty).toList();
    return parts.isEmpty ? directory.path : parts.last;
  }

  int _compareEntityPath(FileSystemEntity a, FileSystemEntity b) {
    return _naturalCompare(_normalizePath(a.path), _normalizePath(b.path));
  }

  String _normalizePath(String path) {
    return path.replaceAll('\\', '/').toLowerCase();
  }

  int _naturalCompare(String a, String b) {
    final aTokens = _naturalTokens(a);
    final bTokens = _naturalTokens(b);
    final length = aTokens.length < bTokens.length ? aTokens.length : bTokens.length;
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

  List<Object> _naturalTokens(String value) {
    final matches = RegExp(r'(\d+|\D+)').allMatches(value);
    return matches.map((match) {
      final part = match.group(0)!;
      final number = int.tryParse(part);
      return number ?? part;
    }).toList(growable: false);
  }
}