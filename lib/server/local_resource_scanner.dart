import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

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

class _ServerResourceMetadata {
  const _ServerResourceMetadata({
    required this.title,
    required this.subtitle,
    required this.displayId,
    required this.tags,
    required this.sourceDisplayName,
    required this.episodeTitles,
  });

  final String title;
  final String subtitle;
  final String displayId;
  final List<String> tags;
  final String sourceDisplayName;
  final List<String> episodeTitles;
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
    if (rootId.startsWith('custom_')) {
      return _scanCustomRootItems(rootId, rootTitle, root);
    }

    final metadataByDirectory = _loadManagedRootMetadata(rootTitle, root);
    final results = <ServerResourceItemSummary>[];
    final children = await _listDirectories(root);
    for (final child in children) {
      final item = await _scanComicItem(
        rootId,
        rootTitle,
        child,
        metadataByDirectory,
      );
      if (item != null) {
        results.add(item);
      }
    }
    if (results.isNotEmpty) {
      return results;
    }

    final rootItem = await _scanComicItem(
      rootId,
      rootTitle,
      root,
      metadataByDirectory,
    );
    if (rootItem != null) {
      results.add(rootItem);
    }
    return results;
  }

  Future<List<ServerResourceItemSummary>> _scanCustomRootItems(
    String rootId,
    String rootTitle,
    Directory root,
  ) async {
    final results = <ServerResourceItemSummary>[];
    final directories = _collectLeafAlbumDirectories(root);
    for (final directory in directories) {
      final images = _listDirectVisibleImages(directory);
      final episode = await _buildEpisodeSummary(
        index: 1,
        title: _directoryTitle(directory),
        directory: directory,
        images: images,
      );
      if (episode == null) {
        continue;
      }
      results.add(
        ServerResourceItemSummary(
          id: _buildItemId(rootId, directory.path),
          rootId: rootId,
          sourceTitle: rootTitle,
          sourceDisplayName: '图集',
          title: _directoryTitle(directory),
          displayId: _directoryTitle(directory),
          subtitle: '${episode.imageCount} 张图片',
          tags: const <String>[],
          path: directory.path,
          imageCount: episode.imageCount,
          totalBytes: episode.totalBytes,
          coverPath: episode.coverPath,
          episodes: [episode],
        ),
      );
    }
    return results;
  }

  Future<ServerResourceItemSummary?> _scanComicItem(
    String rootId,
    String rootTitle,
    Directory directory,
    Map<String, _ServerResourceMetadata> metadataByDirectory,
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
    final normalizedDirectoryPath = _normalizePath(directory.path);
    final metadata = metadataByDirectory[normalizedDirectoryPath] ??
        metadataByDirectory[_normalizePath(_basename(directory.path))];
    final titledEpisodes = _applyEpisodeTitles(
      episodes,
      metadata?.episodeTitles ?? const <String>[],
    );
    final fallbackSubtitle = titledEpisodes.length > 1
        ? '${titledEpisodes.length} 个章节'
        : '$imageCount 张图片';
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
      _directoryTitle(directory),
    ]);
    final displayId = _firstNonEmptyValue([
      metadata?.displayId,
      _buildItemId(rootId, directory.path),
    ]);
    return ServerResourceItemSummary(
      id: _buildItemId(rootId, directory.path),
      rootId: rootId,
      sourceTitle: rootTitle,
      sourceDisplayName: sourceDisplayName,
      title: title,
      displayId: displayId,
      subtitle: subtitle,
      tags: metadata?.tags ?? const <String>[],
      path: directory.path,
      imageCount: imageCount,
      totalBytes: totalBytes,
      coverPath: titledEpisodes.first.coverPath,
      episodes: titledEpisodes,
    );
  }

  Map<String, _ServerResourceMetadata> _loadManagedRootMetadata(
    String rootTitle,
    Directory root,
  ) {
    final dbFile = File('${root.path}${Platform.pathSeparator}download.db');
    if (!dbFile.existsSync()) {
      return const <String, _ServerResourceMetadata>{};
    }

    Database? db;
    final results = <String, _ServerResourceMetadata>{};
    try {
      db = sqlite3.open(dbFile.path);
      final rows = db.select(
        'select id, title, subtitle, directory, json from download',
      );
      for (final row in rows) {
        final rawDirectory = row['directory']?.toString() ?? '';
        final normalizedDirectoryPath =
            _normalizeManagedDirectoryPath(root.path, rawDirectory);
        final normalizedBasename = _normalizePath(_basename(rawDirectory));
        if (normalizedDirectoryPath.isEmpty && normalizedBasename.isEmpty) {
          continue;
        }
        final data = _decodeJsonMap(row['json']?.toString());
        final metadata = _extractDownloadMetadata(
          id: row['id']?.toString() ?? '',
          title: row['title']?.toString() ?? '',
          subtitle: row['subtitle']?.toString() ?? '',
          data: data,
          fallbackSourceDisplayName: rootTitle,
        );
        if (normalizedDirectoryPath.isNotEmpty) {
          results[normalizedDirectoryPath] = metadata;
        }
        if (normalizedBasename.isNotEmpty) {
          results.putIfAbsent(normalizedBasename, () => metadata);
        }
      }
    } catch (_) {
      return const <String, _ServerResourceMetadata>{};
    } finally {
      db?.dispose();
    }
    return results;
  }

  _ServerResourceMetadata _extractDownloadMetadata({
    required String id,
    required String title,
    required String subtitle,
    required Map<String, dynamic>? data,
    required String fallbackSourceDisplayName,
  }) {
    final comicItem = data?['comicItem'];
    final comicItemMap = comicItem is Map
        ? comicItem.map((key, value) => MapEntry(key.toString(), value))
        : null;
    return _ServerResourceMetadata(
      title: _firstNonEmptyValue([
        data?['title']?.toString(),
        comicItemMap?['title']?.toString(),
        title,
      ]),
      subtitle: _firstNonEmptyValue([
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
        comicItemMap?['displayId']?.toString(),
        comicItemMap?['comicId']?.toString(),
        comicItemMap?['id']?.toString(),
        id,
      ]),
      tags: _normalizeTagValues(
        data?['tagList'] ??
            data?['tags'] ??
            data?['metadataTags'] ??
            comicItemMap?['tagList'] ??
            comicItemMap?['tags'],
      ),
      sourceDisplayName: _firstNonEmptyValue([
        data?['sourceDisplayName']?.toString(),
        _inferSourceDisplayName(id, data),
        fallbackSourceDisplayName,
      ]),
      episodeTitles: _extractEpisodeTitles(data, comicItemMap),
    );
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

  List<String> _normalizeTagValues(Object? raw) {
    if (raw is List) {
      return raw
          .map((entry) => entry.toString().trim())
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

  List<String> _extractEpisodeTitles(
    Map<String, dynamic>? data,
    Map<String, dynamic>? comicItemMap,
  ) {
    for (final raw in [
      data?['chapters'],
      data?['eps'],
      comicItemMap?['chapters'],
      comicItemMap?['eps'],
    ]) {
      final titles = _normalizeEpisodeTitles(raw);
      if (titles.isNotEmpty) {
        return titles;
      }
    }
    return const <String>[];
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
        ..sort((a, b) =>
            (int.tryParse(a.key.toString()) ?? 0).compareTo(
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
    final sourceKey = (data?['sourceKey']?.toString() ?? '').trim().toLowerCase();
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

  List<File> _listDirectVisibleImages(Directory directory) {
    final results = <File>[];
    for (final entity in _safeList(directory)) {
      if (entity is! File) {
        continue;
      }
      if (!_isImageFile(entity.path)) {
        continue;
      }
      results.add(entity);
    }
    results.sort(_compareEntityPath);
    final visibleFiles = results.where((file) => !_isCoverLikeFile(file.path)).toList();
    return visibleFiles.isNotEmpty ? visibleFiles : results;
  }

  List<Directory> _collectLeafAlbumDirectories(Directory root) {
    final results = <Directory>[];

    bool visit(Directory directory) {
      final children = _safeList(directory);
      final hasImages = children.any(_isVisibleImageFile);
      var hasAlbumDescendant = false;
      for (final child in children.whereType<Directory>()) {
        if (visit(child)) {
          hasAlbumDescendant = true;
        }
      }
      if (hasImages && !hasAlbumDescendant) {
        results.add(directory);
        return true;
      }
      return hasImages || hasAlbumDescendant;
    }

    visit(root);
    results.sort(_compareEntityPath);
    return results;
  }

  List<FileSystemEntity> _safeList(Directory directory) {
    try {
      return directory.listSync(recursive: false, followLinks: false);
    } catch (_) {
      return const <FileSystemEntity>[];
    }
  }

  bool _isVisibleImageFile(FileSystemEntity entity) {
    return entity is File &&
        _isImageFile(entity.path) &&
        !_basename(entity.path).startsWith('.');
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
    final parts = normalized.split('/').where((entry) => entry.isNotEmpty).toList();
    return parts.isEmpty ? normalized : parts.last;
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