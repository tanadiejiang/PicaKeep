import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

class RemoteLibraryDataSourceException implements Exception {
  const RemoteLibraryDataSourceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class RemoteLibraryRequestException extends RemoteLibraryDataSourceException {
  const RemoteLibraryRequestException(super.message, this.statusCode);

  final int statusCode;
}

class RemoteLibraryBatchResult {
  const RemoteLibraryBatchResult({
    required this.ok,
    required this.requested,
    required this.succeeded,
    required this.failed,
  });

  final bool ok;
  final int requested;
  final int succeeded;
  final List<Map<String, String>> failed;

  factory RemoteLibraryBatchResult.fromJson(Map<String, dynamic> json) {
    final failedValue = json['failed'];
    return RemoteLibraryBatchResult(
      ok: json['ok'] == true,
      requested: _readInt(json['requested']) ?? 0,
      succeeded: _readInt(json['succeeded']) ?? 0,
      failed: failedValue is! List
          ? const <Map<String, String>>[]
          : failedValue
              .whereType<Map>()
              .map(
                (entry) => entry.map(
                  (key, value) => MapEntry(key.toString(), value.toString()),
                ),
              )
              .toList(growable: false),
    );
  }

  static RemoteLibraryBatchResult allSucceeded(int count) {
    return RemoteLibraryBatchResult(
      ok: true,
      requested: count,
      succeeded: count,
      failed: const <Map<String, String>>[],
    );
  }
}

class RemoteLibraryEpisode {
  const RemoteLibraryEpisode({
    required this.index,
    required this.title,
    required this.path,
    required this.imageCount,
    required this.totalBytes,
    required this.coverUrl,
    required this.pages,
    this.pageSizes = const <Size?>[],
  });

  final int index;
  final String title;
  final String path;
  final int imageCount;
  final int totalBytes;
  final String coverUrl;
  final List<String> pages;
  final List<Size?> pageSizes;

  bool get hasPages => pages.isNotEmpty;

  RemoteLibraryEpisode copyWith({
    String? coverUrl,
    List<String>? pages,
    List<Size?>? pageSizes,
  }) {
    return RemoteLibraryEpisode(
      index: index,
      title: title,
      path: path,
      imageCount: imageCount,
      totalBytes: totalBytes,
      coverUrl: coverUrl ?? this.coverUrl,
      pages: pages ?? this.pages,
      pageSizes: pageSizes ?? this.pageSizes,
    );
  }

  factory RemoteLibraryEpisode.fromJson(
    Map<String, dynamic> json,
    RemoteLibraryClient client,
  ) {
    return RemoteLibraryEpisode(
      index: _readInt(json['index']) ?? 1,
      title: _readText(json['title'], fallback: '未命名章节'),
      path: _readText(json['path']),
      imageCount: _readInt(json['imageCount']) ?? 0,
      totalBytes: _readInt(json['totalBytes']) ?? 0,
      coverUrl: client.resolveUrlString(_readText(json['coverUrl'])),
      pages: _readStringList(json['pages'])
          .map(client.resolveUrlString)
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      pageSizes: _readPageSizes(json['pageSizes']),
    );
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'title': title,
        'path': path,
        'imageCount': imageCount,
        'totalBytes': totalBytes,
        'coverUrl': coverUrl,
        'pages': pages,
        'pageSizes': pageSizes
            .map((size) => size == null
                ? null
                : {
                    'width': size.width.round(),
                    'height': size.height.round(),
                  })
            .toList(growable: false),
      };
}

class RemoteLibraryRootSummary {
  const RemoteLibraryRootSummary({
    required this.id,
    required this.title,
    required this.path,
    required this.exists,
    required this.itemCount,
    required this.totalBytes,
    this.previewCoverUrls = const <String>[],
  });

  final String id;
  final String title;
  final String path;
  final bool exists;
  final int itemCount;
  final int totalBytes;
  final List<String> previewCoverUrls;

  bool get isManagedDownloadRoot =>
      id == 'current_download' || id == 'original_download';

  bool get isCustomLibraryRoot => id.startsWith('custom_');

  String get displayTitle {
    final normalized = path.replaceAll('\\', '/');
    final parts =
        normalized.split('/').where((entry) => entry.isNotEmpty).toList();
    final fallback = title.trim();
    if (parts.isEmpty) {
      return fallback.isNotEmpty ? fallback : id;
    }
    final leaf = parts.last.trim();
    return leaf.isNotEmpty ? leaf : (fallback.isNotEmpty ? fallback : id);
  }

  factory RemoteLibraryRootSummary.fromJson(
    Map<String, dynamic> json,
    RemoteLibraryClient client,
  ) {
    return RemoteLibraryRootSummary(
      id: _readText(json['id']),
      title: _readText(json['title'], fallback: '远程目录'),
      path: _readText(json['path']),
      exists: json['exists'] != false,
      itemCount: _readInt(json['itemCount']) ?? 0,
      totalBytes: _readInt(json['totalBytes']) ?? 0,
      previewCoverUrls: _readStringList(json['previewCoverUrls'])
          .map(client.resolveUrlString)
          .where((entry) => entry.isNotEmpty)
          .toList(growable: false),
    );
  }
}

class RemoteLibraryRootItem extends DownloadedItem {
  RemoteLibraryRootItem({
    required this.client,
    required this.root,
    this.coverUrl,
  }) {
    comicSize = root.totalBytes > 0 ? root.totalBytes / (1024 * 1024) : null;
  }

  final RemoteLibraryClient client;
  final RemoteLibraryRootSummary root;
  final String? coverUrl;

  List<String> get previewCoverUrls => root.previewCoverUrls;

  @override
  double? comicSize;

  @override
  DownloadType get type => DownloadType.other;

  @override
  String get name => root.displayTitle;

  @override
  List<String> get eps => const [];

  @override
  List<int> get downloadedEps => const [];

  @override
  String get id => 'remote_root::${root.id}';

  @override
  String get subTitle {
    final count = root.itemCount;
    if (root.isManagedDownloadRoot) {
      return '$count 部漫画';
    }
    return '$count 个项目';
  }

  @override
  List<String> get tags => const [];

  @override
  String get sourceDisplayName =>
      root.isManagedDownloadRoot ? '远程已下载' : '远程资源库';

  @override
  bool get canDelete => false;

  @override
  String? get fileSystemPath => root.path;

  @override
  String? get localCoverPath => null;

  ImageProvider<Object>? get coverImageProvider {
    final trimmed = coverUrl?.trim() ?? '';
    if (trimmed.isEmpty) {
      return null;
    }
    return client.coverImageProviderForUrl(trimmed);
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'rootId': root.id,
        'title': name,
        'path': root.path,
        'itemCount': root.itemCount,
        'totalBytes': root.totalBytes,
        'coverUrl': coverUrl,
        'previewCoverUrls': previewCoverUrls,
      };

  @override
  Widget createReadingPage({int? ep, int? page}) {
    throw const RemoteLibraryDataSourceException('远程目录不支持直接阅读');
  }
}

class RemoteLibraryTrashItem {
  const RemoteLibraryTrashItem({
    required this.id,
    required this.itemId,
    required this.rootId,
    required this.title,
    required this.subtitle,
    required this.sourceDisplayName,
    required this.tags,
    required this.imageCount,
    required this.totalBytes,
    required this.originalPath,
    required this.coverUrl,
    required this.deletedAt,
    required this.isAlbum,
  });

  final String id;
  final String itemId;
  final String rootId;
  final String title;
  final String subtitle;
  final String sourceDisplayName;
  final List<String> tags;
  final int imageCount;
  final int totalBytes;
  final String originalPath;
  final String coverUrl;
  final DateTime deletedAt;
  final bool isAlbum;

  factory RemoteLibraryTrashItem.fromJson(
    Map<String, dynamic> json,
    RemoteLibraryClient client,
  ) {
    final rawItemKind = _readText(json['itemKind']);
    final rootId = _readText(json['rootId']);
    return RemoteLibraryTrashItem(
      id: _readText(json['id']),
      itemId: _readText(json['itemId']),
      rootId: rootId,
      title: _readText(json['title'], fallback: '未命名项目'),
      subtitle: _readText(json['subtitle']),
      sourceDisplayName: _readText(json['sourceDisplayName']),
      tags: _readStringList(json['tags']),
      imageCount: _readInt(json['imageCount']) ?? 0,
      totalBytes: _readInt(json['totalBytes']) ?? 0,
      originalPath: _readText(json['originalPath']),
      coverUrl: client.resolveUrlString(_readText(json['coverUrl'])),
      deletedAt: DateTime.tryParse(_readText(json['deletedAt'])) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      isAlbum: rawItemKind == 'album' || rootId.startsWith('custom_'),
    );
  }
}

class RemoteLibraryComicItem extends DownloadedItem {
  RemoteLibraryComicItem({
    required this.client,
    required this.remoteId,
    required this.rootId,
    required this.title,
    required this.sourceTitle,
    required this.remotePath,
    required this.coverUrl,
    required this.detailUrl,
    required this.episodesData,
    required this.imageCount,
    required this.totalBytes,
    DateTime? updatedAt,
    this.subtitle = '',
    this.displayId = '',
    this.metadataTags = const <String>[],
    this.metadataSourceDisplayName = '',
  }) {
    comicSize = totalBytes > 0 ? totalBytes / (1024 * 1024) : null;
    directory = null;
    time = updatedAt;
  }

  final RemoteLibraryClient client;
  final String remoteId;
  final String rootId;
  final String title;
  final String sourceTitle;
  final String remotePath;
  final String coverUrl;
  final String detailUrl;
  final List<RemoteLibraryEpisode> episodesData;
  final int imageCount;
  final int totalBytes;
  final String subtitle;
  final String displayId;
  final List<String> metadataTags;
  final String metadataSourceDisplayName;

  @override
  double? comicSize;

  bool get hasMultipleEpisodes => episodesData.length > 1;

  bool get hasCompletePages =>
      episodesData.every((episode) => episode.hasPages);

  bool get hasMetadataTags => metadataTags.any((tag) => tag.trim().isNotEmpty);

  bool get hasMeaningfulEpisodeTitles {
    if (episodesData.isEmpty) {
      return false;
    }
    final itemTitle = title.trim();
    for (final episode in episodesData) {
      final episodeTitle = episode.title.trim();
      if (episodeTitle.isEmpty || episodeTitle == '未命名章节') {
        continue;
      }
      if (itemTitle.isEmpty || episodeTitle != itemTitle) {
        return true;
      }
    }
    return false;
  }

  bool get hasUsableDetailPayload =>
      hasCompletePages && hasMetadataTags && hasMeaningfulEpisodeTitles;

  bool get isManagedDownloadRoot =>
      rootId == 'current_download' || rootId == 'original_download';

  bool get isCustomLibraryRoot => rootId.startsWith('custom_');

  ImageProvider<Object>? get coverImageProvider {
    if (coverUrl.trim().isEmpty) {
      return null;
    }
    return client.coverImageProviderForUrl(coverUrl.trim());
  }

  List<String> get pageUrls => [
        for (final episode in episodesData) ...episode.pages,
      ];

  Iterable<String> get candidateValues sync* {
    yield remoteId;
    yield title;
    if (detailUrl.isNotEmpty) {
      yield detailUrl;
    }
    if (remotePath.isNotEmpty) {
      yield remotePath;
    }
  }

  bool matchesCandidates(Set<String> candidates) {
    for (final value in candidateValues) {
      final normalized = value.trim();
      if (normalized.isNotEmpty && candidates.contains(normalized)) {
        return true;
      }
    }
    return false;
  }

  RemoteLibraryEpisode? episodeForReading(int ep) {
    if (episodesData.isEmpty) {
      return null;
    }
    if (!hasMultipleEpisodes) {
      return episodesData.first;
    }
    if (ep <= 0) {
      return episodesData.first;
    }
    for (final episode in episodesData) {
      if (episode.index == ep) {
        return episode;
      }
    }
    return null;
  }

  RemoteLibraryComicItem copyWith({
    String? coverUrl,
    String? detailUrl,
    List<RemoteLibraryEpisode>? episodesData,
  }) {
    return RemoteLibraryComicItem(
      client: client,
      remoteId: remoteId,
      rootId: rootId,
      title: title,
      sourceTitle: sourceTitle,
      remotePath: remotePath,
      coverUrl: coverUrl ?? this.coverUrl,
      detailUrl: detailUrl ?? this.detailUrl,
      episodesData: episodesData ?? this.episodesData,
      imageCount: imageCount,
      totalBytes: totalBytes,
      updatedAt: time,
      subtitle: subtitle,
      displayId: displayId,
      metadataTags: metadataTags,
      metadataSourceDisplayName: metadataSourceDisplayName,
    );
  }

  factory RemoteLibraryComicItem.fromJson(
    Map<String, dynamic> json,
    RemoteLibraryClient client,
  ) {
    final nestedComicItem = _readNestedMap(json['comicItem']);
    final itemId = _readText(json['id']);
    final title = _readText(
      json['title'],
      fallback: _readText(nestedComicItem['title'], fallback: '未命名漫画'),
    );
    final detailUrl = client.resolveUrlString(_readText(json['detailUrl']));
    final episodes = _readEpisodeList(json['episodes'], client, title);
    final coverUrl = client.resolveUrlString(
      _readText(
        json['coverUrl'],
        fallback: _readText(
          nestedComicItem['coverUrl'],
          fallback: episodes.isEmpty ? '' : episodes.first.coverUrl,
        ),
      ),
    );

    return RemoteLibraryComicItem(
      client: client,
      remoteId: itemId.isEmpty ? title : itemId,
      rootId: _readText(json['rootId']),
      title: title,
      sourceTitle: _readText(
        json['sourceTitle'],
        fallback: _readText(
          nestedComicItem['sourceTitle'],
          fallback: '远程资源',
        ),
      ),
      remotePath: _readText(json['path']),
      coverUrl: coverUrl,
      detailUrl: detailUrl,
      episodesData: episodes,
      imageCount: _readInt(json['imageCount']) ??
          episodes.fold<int>(0, (sum, episode) => sum + episode.imageCount),
      totalBytes: _readInt(json['totalBytes']) ??
          episodes.fold<int>(0, (sum, episode) => sum + episode.totalBytes),
      updatedAt: DateTime.tryParse(_readText(json['updatedAt'])) ??
          DateTime.tryParse(_readText(json['time'])),
      subtitle: _readText(
        json['subtitle'],
        fallback: _readText(
          json['author'],
          fallback: _readText(
            nestedComicItem['subtitle'],
            fallback: _readText(nestedComicItem['author']),
          ),
        ),
      ),
      displayId: _readText(
        json['displayId'],
        fallback: _readText(
          nestedComicItem['displayId'],
          fallback: _readText(
            nestedComicItem['comicId'],
            fallback: _readText(nestedComicItem['id']),
          ),
        ),
      ),
      metadataTags: _readFirstStringList([
        json['tags'],
        json['tagList'],
        json['metadataTags'],
        nestedComicItem['tags'],
        nestedComicItem['tagList'],
        nestedComicItem['metadataTags'],
      ]),
      metadataSourceDisplayName: _readText(
        json['sourceDisplayName'],
        fallback: _readText(
          json['metadataSourceDisplayName'],
          fallback: _readText(
            nestedComicItem['sourceDisplayName'],
            fallback: _readText(nestedComicItem['metadataSourceDisplayName']),
          ),
        ),
      ),
    );
  }

  @override
  DownloadType get type => DownloadType.other;

  @override
  String get name => title;

  @override
  List<String> get eps =>
      episodesData.map((episode) => episode.title).toList(growable: false);

  @override
  List<int> get downloadedEps => const [];

  @override
  String get id => remoteId;

  @override
  String get subTitle {
    final label = subtitle.trim();
    if (label.isNotEmpty) {
      return label;
    }
    return hasMultipleEpisodes
        ? '${episodesData.length} 个章节'
        : '$imageCount 张图片';
  }

  @override
  List<String> get tags => metadataTags;

  @override
  String get sourceDisplayName {
    if (isCustomLibraryRoot) {
      return '图集';
    }
    final metadataLabel = metadataSourceDisplayName.trim();
    if (metadataLabel.isNotEmpty) {
      return metadataLabel;
    }
    final label = sourceTitle.trim();
    if (label.isNotEmpty) {
      return label;
    }
    return isManagedDownloadRoot ? '远程已下载' : '远程资源';
  }

  @override
  bool get canDelete => false;

  @override
  String? get fileSystemPath => remotePath.trim().isEmpty ? null : remotePath;

  @override
  String? get localCoverPath => null;

  @override
  Map<String, dynamic> toJson() => {
        'itemId': remoteId,
        'id': remoteId,
        'rootId': rootId,
        'title': title,
        'sourceTitle': sourceTitle,
        'sourceDisplayName': metadataSourceDisplayName,
        'subtitle': subtitle,
        'displayId': displayId,
        'tags': metadataTags,
        'path': remotePath,
        'coverUrl': coverUrl,
        'detailUrl': detailUrl,
        'imageCount': imageCount,
        'totalBytes': totalBytes,
        'episodeCount': episodesData.length,
        'hasMultipleEpisodes': hasMultipleEpisodes,
        'episodes': episodesData.map((episode) => episode.toJson()).toList(),
      };

  @override
  Widget createReadingPage({int? ep, int? page}) {
    return ComicReadingPage(
      RemoteLibraryReadingData(item: this),
      page ?? 1,
      ep ?? (hasMultipleEpisodes ? 1 : 0),
    );
  }

  static List<RemoteLibraryEpisode> _readEpisodeList(
    Object? value,
    RemoteLibraryClient client,
    String itemTitle,
  ) {
    if (value is List) {
      final episodes = value
          .whereType<Map>()
          .map(
            (episode) => RemoteLibraryEpisode.fromJson(
              episode.map((key, value) => MapEntry(key.toString(), value)),
              client,
            ),
          )
          .toList(growable: false);
      if (episodes.isNotEmpty) {
        return episodes;
      }
    }

    final pages = _readStringList(value)
        .map(client.resolveUrlString)
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (pages.isEmpty) {
      return const [];
    }
    return [
      RemoteLibraryEpisode(
        index: 1,
        title: itemTitle,
        path: '',
        imageCount: pages.length,
        totalBytes: 0,
        coverUrl: pages.first,
        pages: pages,
      ),
    ];
  }
}

class RemoteLibraryReadingData extends ReadingData {
  RemoteLibraryReadingData({required this.item});

  final RemoteLibraryComicItem item;

  @override
  final FavoriteType favoriteType = const FavoriteType(0);

  @override
  ComicType get comicType => ComicType.other;

  @override
  String get title => item.title;

  @override
  String get id => item.id;

  @override
  String get downloadId => 'remote::${item.id}';

  @override
  String get sourceKey => 'remote_library';

  @override
  bool get hasEp => item.hasMultipleEpisodes;

  @override
  Map<String, String>? get eps => hasEp
      ? {
          for (var i = 0; i < item.episodesData.length; i++)
            '${i + 1}': item.episodesData[i].title,
        }
      : null;

  @override
  bool get downloaded => false;

  @override
  Future<List<String>> loadEpNetwork(int ep) async {
    final cachedEpisode = item.episodeForReading(ep);
    if (cachedEpisode != null && cachedEpisode.hasPages) {
      return cachedEpisode.pages;
    }

    final detail = await item.client.fetchItemDetail(item.id);
    final episode = detail.episodeForReading(ep);
    if (episode == null) {
      throw const RemoteLibraryDataSourceException('远程章节不存在');
    }
    return episode.pages;
  }

  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) async* {
    yield* item.client.loadImage(url);
  }

  @override
  ImageProvider createImageProvider(int ep, int page, String url) {
    return StreamImageProvider.withProgress(
      () => item.client.loadImageWithProgress(url),
      buildImageKey(ep, page, url),
    );
  }

  @override
  Size? imageSize(int ep, int page, String url) {
    final episode = item.episodeForReading(ep);
    if (episode == null || page < 0 || page >= episode.pageSizes.length) {
      return null;
    }
    return episode.pageSizes[page];
  }

  @override
  String buildImageKey(int ep, int page, String url) =>
      'remote::$ep::$page::${item.client.resolveUrlString(url)}';
}

class _RemoteLibrarySnapshot {
  const _RemoteLibrarySnapshot({
    required this.roots,
    required this.items,
    required this.signature,
  });

  final List<RemoteLibraryRootSummary> roots;
  final List<RemoteLibraryComicItem> items;
  final String signature;
}

class _RemoteLibraryCoverDiskCache {
  static final Map<String, Future<File>> _pending = <String, Future<File>>{};

  static Directory get _cacheDirectory => Directory(
        '${App.dataPath}${Platform.pathSeparator}cache'
        '${Platform.pathSeparator}remote_library_covers',
      );

  static File cachedFileFor(String url) {
    final uri = Uri.tryParse(url);
    final extension = _normalizedExtension(uri?.path ?? '');
    final hash = _stableHash(url);
    return File(
      '${_cacheDirectory.path}${Platform.pathSeparator}$hash$extension',
    );
  }

  static Future<File> ensureDownloaded(
    RemoteLibraryClient client,
    String url,
  ) async {
    final target = cachedFileFor(url);
    if (await _isUsable(target)) {
      return target;
    }

    final key = target.path;
    final pending = _pending[key];
    if (pending != null) {
      return pending;
    }

    final future = _download(client, url, target).whenComplete(() {
      _pending.remove(key);
    });
    _pending[key] = future;
    return future;
  }

  static Future<File> _download(
    RemoteLibraryClient client,
    String url,
    File target,
  ) async {
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.part');
    IOSink? sink;
    try {
      sink = temp.openWrite();
      await for (final chunk in client.loadImage(url)) {
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (await target.exists()) {
        await target.delete();
      }
      await temp.rename(target.path);
      await _trimToLimit(protectedPath: target.path);
      return target;
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await temp.exists()) {
          await temp.delete();
        }
      } catch (_) {}
      rethrow;
    }
  }

  static Future<void> _trimToLimit({required String protectedPath}) async {
    final limitBytes = appdata.appSettings.cacheLimit * 1024 * 1024;
    if (limitBytes <= 0 || !await _cacheDirectory.exists()) {
      return;
    }
    final files = <File>[];
    var totalBytes = await _directorySize(Directory(App.cachePath));
    totalBytes += await _directorySize(
      Directory('${App.dataPath}${Platform.pathSeparator}cache'),
      collectFilesUnder: _cacheDirectory.path,
      collectedFiles: files,
    );
    if (totalBytes <= limitBytes || files.isEmpty) {
      return;
    }

    final normalizedProtected = _normalizePath(protectedPath);
    final removableFiles = <({File file, DateTime modified, int size})>[];
    for (final file in files) {
      try {
        if (_normalizePath(file.path) == normalizedProtected) {
          continue;
        }
        final stat = await file.stat();
        if (stat.type == FileSystemEntityType.file && stat.size > 0) {
          removableFiles
              .add((file: file, modified: stat.modified, size: stat.size));
        }
      } catch (_) {}
    }
    removableFiles.sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in removableFiles) {
      if (totalBytes <= limitBytes) {
        break;
      }
      try {
        await entry.file.delete();
        totalBytes -= entry.size;
      } catch (_) {}
    }
  }

  static Future<int> _directorySize(
    Directory directory, {
    String? collectFilesUnder,
    List<File>? collectedFiles,
  }) async {
    if (!await directory.exists()) {
      return 0;
    }
    final normalizedCollectRoot = collectFilesUnder == null
        ? null
        : '${_normalizePath(collectFilesUnder)}${Platform.pathSeparator}';
    var totalBytes = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      try {
        totalBytes += await entity.length();
        if (normalizedCollectRoot != null &&
            '${_normalizePath(entity.parent.path)}${Platform.pathSeparator}'
                .startsWith(normalizedCollectRoot)) {
          collectedFiles?.add(entity);
        }
      } catch (_) {}
    }
    return totalBytes;
  }

  static String _normalizePath(String path) {
    return path.trim().replaceAll('\\', Platform.pathSeparator);
  }

  static Future<bool> _isUsable(File file) async {
    try {
      return await file.exists() && await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  static String _normalizedExtension(String path) {
    final lower = path.toLowerCase();
    for (final ext in const [
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.gif',
      '.bmp'
    ]) {
      if (lower.endsWith(ext)) {
        return ext;
      }
    }
    return '.img';
  }

  static String _stableHash(String input) {
    var hash = 1469598103934665603;
    for (final unit in utf8.encode(input)) {
      hash ^= unit;
      hash = (hash * 1099511628211) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16);
  }
}

class _RemoteLibraryCoverImageProvider
    extends BaseImageProvider<_RemoteLibraryCoverImageProvider> {
  const _RemoteLibraryCoverImageProvider({
    required this.client,
    required this.url,
  });

  final RemoteLibraryClient client;
  final String url;

  @override
  String get key => 'remote_cover::$url';

  @override
  Future<_RemoteLibraryCoverImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) {
    return SynchronousFuture<_RemoteLibraryCoverImageProvider>(this);
  }

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) async {
    File file = _RemoteLibraryCoverDiskCache.cachedFileFor(url);
    if (!await _RemoteLibraryCoverDiskCache._isUsable(file)) {
      file = await _RemoteLibraryCoverDiskCache.ensureDownloaded(client, url);
    }

    final totalBytes = await file.length();
    final bytesBuilder = BytesBuilder(copy: false);
    var cumulativeBytesLoaded = 0;
    await for (final chunk in file.openRead()) {
      bytesBuilder.add(chunk);
      cumulativeBytesLoaded += chunk.length;
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: cumulativeBytesLoaded,
          expectedTotalBytes: totalBytes > 0 ? totalBytes : null,
        ),
      );
    }
    return bytesBuilder.takeBytes();
  }
}

class RemoteLibraryDataSource {
  const RemoteLibraryDataSource();

  Future<List<RemoteLibraryComicItem>> fetchItems({
    bool forceRefresh = false,
  }) async {
    return RemoteLibraryClient.fromCurrentSettings().fetchItems(
      forceRefresh: forceRefresh,
    );
  }

  Future<List<RemoteLibraryComicItem>> fetchItemsForRoot(
    String rootId, {
    bool forceRefresh = false,
  }) async {
    return RemoteLibraryClient.fromCurrentSettings().fetchItemsForRoot(
      rootId,
      forceRefresh: forceRefresh,
    );
  }

  Future<List<RemoteLibraryRootItem>> fetchRootItems({
    bool managedDownloadOnly = false,
    bool customLibraryOnly = false,
    bool forceRefresh = false,
  }) async {
    return RemoteLibraryClient.fromCurrentSettings().fetchRootItems(
      managedDownloadOnly: managedDownloadOnly,
      customLibraryOnly: customLibraryOnly,
      forceRefresh: forceRefresh,
    );
  }

  Future<RemoteLibraryComicItem?> findByCandidates(
    Iterable<String> candidates, {
    bool fetchDetail = false,
  }) {
    return RemoteLibraryClient.fromCurrentSettings().findItemByCandidates(
      candidates,
      fetchDetail: fetchDetail,
    );
  }
}

class RemoteLibraryClient {
  RemoteLibraryClient._({
    required this.baseUrl,
    required this.baseUri,
  }) : _httpClient = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5)
          ..idleTimeout = const Duration(seconds: 20)
          ..maxConnectionsPerHost = 12;

  static final Map<String, RemoteLibraryClient> _instances = {};

  final String baseUrl;
  final Uri baseUri;
  final HttpClient _httpClient;
  final Map<String, RemoteLibraryComicItem> _detailCache = {};
  final Map<String, Future<RemoteLibraryComicItem>> _pendingDetailRequests = {};
  Future<_RemoteLibrarySnapshot>? _pendingSnapshotRequest;
  _RemoteLibrarySnapshot? _snapshotCache;
  int? _lastLocalDataVersion;
  int? _lastServiceConfigVersion;
  int? _lastServiceRuntimeVersion;

  void _invalidateCachesForAppStateIfNeeded() {
    final localDataVersion = App.localDataVersion.value;
    final serviceConfigVersion = App.serviceConfigVersion.value;
    final serviceRuntimeVersion = App.serviceRuntimeVersion.value;
    final shouldInvalidate = _lastLocalDataVersion != localDataVersion ||
        _lastServiceConfigVersion != serviceConfigVersion ||
        _lastServiceRuntimeVersion != serviceRuntimeVersion;
    _lastLocalDataVersion = localDataVersion;
    _lastServiceConfigVersion = serviceConfigVersion;
    _lastServiceRuntimeVersion = serviceRuntimeVersion;
    if (!shouldInvalidate) {
      return;
    }
    _clearCaches();
  }

  void _clearCaches() {
    _snapshotCache = null;
    _pendingSnapshotRequest = null;
    _detailCache.clear();
    _pendingDetailRequests.clear();
  }

  factory RemoteLibraryClient.fromCurrentSettings() {
    final rawAddress = appdata.settings[remoteServerAddressSettingIndex];
    final normalizedAddress = normalizeRemoteServerAddressValue(rawAddress);
    if (normalizedAddress.isEmpty) {
      throw const RemoteLibraryDataSourceException('请先填写有效的远程服务地址');
    }
    final baseUri = Uri.tryParse(normalizedAddress);
    if (baseUri == null || !baseUri.hasAuthority) {
      throw const RemoteLibraryDataSourceException('当前远程服务地址格式无效');
    }
    return _instances.putIfAbsent(
      normalizedAddress,
      () => RemoteLibraryClient._(
        baseUrl: normalizedAddress,
        baseUri: baseUri,
      ),
    );
  }

  ImageProvider<Object>? coverImageProviderForUrl(String url) {
    final resolved = resolveUrlString(url);
    if (resolved.isEmpty) {
      return null;
    }
    return _RemoteLibraryCoverImageProvider(
      client: this,
      url: resolved,
    );
  }

  Future<List<RemoteLibraryComicItem>> fetchItems(
      {bool forceRefresh = false}) async {
    return (await _fetchSnapshot(forceRefresh: forceRefresh)).items;
  }

  String? get currentSignature {
    final signature = _snapshotCache?.signature.trim() ?? '';
    return signature.isEmpty ? null : signature;
  }

  static RemoteLibraryClient? tryFromCurrentSettings() {
    try {
      return RemoteLibraryClient.fromCurrentSettings();
    } catch (_) {
      return null;
    }
  }

  Future<List<RemoteLibraryComicItem>> fetchItemsForRoot(
    String rootId, {
    bool forceRefresh = false,
  }) async {
    final normalized = rootId.trim();
    if (normalized.isEmpty) {
      return const <RemoteLibraryComicItem>[];
    }
    final items = await fetchItems(forceRefresh: forceRefresh);
    return items
        .where((item) => item.rootId == normalized)
        .toList(growable: false);
  }

  Future<List<RemoteLibraryRootItem>> fetchRootItems({
    bool managedDownloadOnly = false,
    bool customLibraryOnly = false,
    bool forceRefresh = false,
  }) async {
    final snapshot = await _fetchSnapshot(forceRefresh: forceRefresh);
    return _buildRootItemsFromSnapshot(
      snapshot,
      managedDownloadOnly: managedDownloadOnly,
      customLibraryOnly: customLibraryOnly,
    );
  }

  Future<List<RemoteLibraryTrashItem>> fetchTrashItems() async {
    final payload = await _getJsonMap('/api/library/trash');
    final itemsValue = payload['items'];
    if (itemsValue is! List) {
      return const <RemoteLibraryTrashItem>[];
    }
    return itemsValue
        .whereType<Map>()
        .map(
          (item) => RemoteLibraryTrashItem.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
            this,
          ),
        )
        .toList(growable: false);
  }

  Future<void> rescanLibrary() async {
    await _sendRequest(
      'POST',
      '/api/library/items/refresh',
    );
    _clearCaches();
  }

  Future<void> trashItem(String itemId) async {
    await _sendRequest(
      'POST',
      '/api/library/items/${Uri.encodeComponent(itemId)}/trash',
    );
    _clearCaches();
  }

  Future<void> deleteItemPermanently(String itemId) async {
    await _sendRequest(
      'DELETE',
      '/api/library/items/${Uri.encodeComponent(itemId)}',
    );
    _clearCaches();
  }

  Future<void> restoreTrashItem(String trashId) async {
    await _sendRequest(
      'POST',
      '/api/library/trash/${Uri.encodeComponent(trashId)}/restore',
    );
    _clearCaches();
  }

  Future<void> purgeTrashItem(String trashId) async {
    await _sendRequest(
      'DELETE',
      '/api/library/trash/${Uri.encodeComponent(trashId)}',
    );
    _clearCaches();
  }

  Future<RemoteLibraryBatchResult> trashItems(Iterable<String> itemIds) async {
    return _batchIdOperation(
      ids: itemIds,
      batchPath: '/api/library/items/batch-trash',
      bodyKey: 'itemIds',
      fallback: (id) => _sendRequest(
        'POST',
        '/api/library/items/${Uri.encodeComponent(id)}/trash',
      ),
    );
  }

  Future<RemoteLibraryBatchResult> deleteItemsPermanently(
    Iterable<String> itemIds,
  ) async {
    return _batchIdOperation(
      ids: itemIds,
      batchPath: '/api/library/items/batch-delete',
      bodyKey: 'itemIds',
      fallback: (id) => _sendRequest(
        'DELETE',
        '/api/library/items/${Uri.encodeComponent(id)}',
      ),
    );
  }

  Future<RemoteLibraryBatchResult> restoreTrashItems(
    Iterable<String> trashIds,
  ) async {
    return _batchIdOperation(
      ids: trashIds,
      batchPath: '/api/library/trash/batch-restore',
      bodyKey: 'trashIds',
      fallback: (id) => _sendRequest(
        'POST',
        '/api/library/trash/${Uri.encodeComponent(id)}/restore',
      ),
    );
  }

  Future<RemoteLibraryBatchResult> purgeTrashItems(
    Iterable<String> trashIds,
  ) async {
    return _batchIdOperation(
      ids: trashIds,
      batchPath: '/api/library/trash/batch-purge',
      bodyKey: 'trashIds',
      fallback: (id) => _sendRequest(
        'DELETE',
        '/api/library/trash/${Uri.encodeComponent(id)}',
      ),
    );
  }

  Future<RemoteLibraryBatchResult> _batchIdOperation({
    required Iterable<String> ids,
    required String batchPath,
    required String bodyKey,
    required Future<void> Function(String id) fallback,
  }) async {
    final normalizedIds = ids
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (normalizedIds.isEmpty) {
      return RemoteLibraryBatchResult.allSucceeded(0);
    }
    try {
      final payload = await _sendRequest(
        'POST',
        batchPath,
        body: {bodyKey: normalizedIds},
      );
      _clearCaches();
      return RemoteLibraryBatchResult.fromJson(payload);
    } on RemoteLibraryRequestException catch (e) {
      if (e.statusCode != 404 && e.statusCode != 405) {
        rethrow;
      }
    }

    final failed = <Map<String, String>>[];
    var succeeded = 0;
    for (final id in normalizedIds) {
      try {
        await fallback(id);
        succeeded += 1;
      } catch (e) {
        failed.add({'id': id, 'error': e.toString()});
      }
    }
    _clearCaches();
    return RemoteLibraryBatchResult(
      ok: failed.isEmpty,
      requested: normalizedIds.length,
      succeeded: succeeded,
      failed: failed,
    );
  }

  Future<_RemoteLibrarySnapshot> _fetchSnapshot({
    bool forceRefresh = false,
  }) async {
    _invalidateCachesForAppStateIfNeeded();
    if (!forceRefresh) {
      final cached = _snapshotCache;
      if (cached != null) {
        return cached;
      }
      final pending = _pendingSnapshotRequest;
      if (pending != null) {
        return pending;
      }
    }

    final request = _fetchSnapshotFromNetwork();
    _pendingSnapshotRequest = request;
    try {
      final snapshot = await request;
      _snapshotCache = snapshot;
      for (final item in snapshot.items) {
        _detailCache[item.id] = item;
      }
      return snapshot;
    } finally {
      if (identical(_pendingSnapshotRequest, request)) {
        _pendingSnapshotRequest = null;
      }
    }
  }

  Future<_RemoteLibrarySnapshot> _fetchSnapshotFromNetwork() async {
    final payload = await _getJsonMap('/api/library/items');
    final itemsValue = payload['items'];
    final items = itemsValue is! List
        ? const <RemoteLibraryComicItem>[]
        : itemsValue
            .whereType<Map>()
            .map(
              (item) => RemoteLibraryComicItem.fromJson(
                item.map((key, value) => MapEntry(key.toString(), value)),
                this,
              ),
            )
            .toList(growable: false);
    final roots = _readRoots(payload['roots'], items);
    final signature = _readText(payload['librarySignature']);
    return _RemoteLibrarySnapshot(
      roots: roots,
      items: items,
      signature: signature,
    );
  }

  List<RemoteLibraryRootItem> _buildRootItemsFromSnapshot(
    _RemoteLibrarySnapshot snapshot, {
    required bool managedDownloadOnly,
    required bool customLibraryOnly,
  }) {
    final roots = snapshot.roots.where((root) {
      if (!root.exists || root.itemCount <= 0) {
        return false;
      }
      if (managedDownloadOnly && !root.isManagedDownloadRoot) {
        return false;
      }
      if (customLibraryOnly && !root.isCustomLibraryRoot) {
        return false;
      }
      return true;
    }).toList(growable: false);

    return roots.map((root) {
      String? coverUrl;
      final previewCoverUrls = <String>[
        ...root.previewCoverUrls,
      ];
      for (final item in snapshot.items) {
        if (item.rootId != root.id) {
          continue;
        }
        final value = item.coverUrl.trim();
        if (value.isNotEmpty) {
          coverUrl ??= value;
          if (!previewCoverUrls.contains(value) &&
              previewCoverUrls.length < 4) {
            previewCoverUrls.add(value);
          }
        }
      }
      return RemoteLibraryRootItem(
        client: this,
        root: RemoteLibraryRootSummary(
          id: root.id,
          title: root.title,
          path: root.path,
          exists: root.exists,
          itemCount: root.itemCount,
          totalBytes: root.totalBytes,
          previewCoverUrls: previewCoverUrls,
        ),
        coverUrl: coverUrl,
      );
    }).toList(growable: false);
  }

  List<RemoteLibraryRootSummary> _readRoots(
    Object? value,
    List<RemoteLibraryComicItem> items,
  ) {
    if (value is List) {
      final roots = value
          .whereType<Map>()
          .map(
            (root) => RemoteLibraryRootSummary.fromJson(
              root.map((key, value) => MapEntry(key.toString(), value)),
              this,
            ),
          )
          .toList(growable: false);
      if (roots.isNotEmpty) {
        return roots;
      }
    }
    return _deriveRoots(items);
  }

  List<RemoteLibraryRootSummary> _deriveRoots(
    List<RemoteLibraryComicItem> items,
  ) {
    final grouped = <String, List<RemoteLibraryComicItem>>{};
    for (final item in items) {
      grouped
          .putIfAbsent(item.rootId, () => <RemoteLibraryComicItem>[])
          .add(item);
    }
    final roots = <RemoteLibraryRootSummary>[];
    grouped.forEach((rootId, groupItems) {
      if (groupItems.isEmpty) {
        return;
      }
      final first = groupItems.first;
      roots.add(
        RemoteLibraryRootSummary(
          id: rootId,
          title: first.sourceTitle,
          path: first.remotePath,
          exists: true,
          itemCount: groupItems.length,
          totalBytes: groupItems.fold<int>(
            0,
            (sum, item) => sum + item.totalBytes,
          ),
          previewCoverUrls: groupItems
              .map((item) => item.coverUrl.trim())
              .where((item) => item.isNotEmpty)
              .take(4)
              .toList(growable: false),
        ),
      );
    });
    roots.sort((a, b) => a.displayTitle.compareTo(b.displayTitle));
    return roots.toList(growable: false);
  }

  Future<RemoteLibraryComicItem?> findItemByCandidates(
    Iterable<String> candidates, {
    bool fetchDetail = false,
  }) async {
    final normalized = candidates
        .map((candidate) => candidate.trim())
        .where((candidate) => candidate.isNotEmpty)
        .toSet();
    if (normalized.isEmpty) {
      return null;
    }

    final items = await fetchItems();
    for (final item in items) {
      if (!item.matchesCandidates(normalized)) {
        continue;
      }
      if (fetchDetail) {
        return await fetchItemDetail(item.id);
      }
      return item;
    }
    return null;
  }

  Future<RemoteLibraryComicItem> fetchItemDetail(String itemId) async {
    final cached = _detailCache[itemId];
    if (cached != null && cached.hasUsableDetailPayload) {
      return cached;
    }

    final pending = _pendingDetailRequests[itemId];
    if (pending != null) {
      return pending;
    }

    final request = _fetchItemDetailFromNetwork(itemId);
    _pendingDetailRequests[itemId] = request;
    try {
      return await request;
    } finally {
      if (identical(_pendingDetailRequests[itemId], request)) {
        _pendingDetailRequests.remove(itemId);
      }
    }
  }

  Future<RemoteLibraryComicItem> _fetchItemDetailFromNetwork(
      String itemId) async {
    final payload = await _getJsonMap(
      '/api/library/items/${Uri.encodeComponent(itemId)}',
    );
    final detail = RemoteLibraryComicItem.fromJson(payload, this);
    _detailCache[itemId] = detail;
    return detail;
  }

  Future<StreamImageLoadResult> loadImageWithProgress(String url) async {
    try {
      final request = await _httpClient.getUrl(resolveUri(url)).timeout(
            const Duration(seconds: 5),
          );
      final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw RemoteLibraryDataSourceException(
          '远程图片请求失败：${response.statusCode}',
        );
      }
      return StreamImageLoadResult(
        stream: response,
        expectedTotalBytes:
            response.contentLength >= 0 ? response.contentLength : null,
      );
    } on SocketException {
      throw const RemoteLibraryDataSourceException('无法连接远程图片资源');
    }
  }

  Stream<List<int>> loadImage(String url) async* {
    final result = await loadImageWithProgress(url);
    yield* result.stream;
  }

  Uri resolveUri(String value) {
    final resolved = resolveUrlString(value);
    final uri = Uri.tryParse(resolved);
    if (uri == null) {
      throw RemoteLibraryDataSourceException('服务端返回了无效地址：$value');
    }
    return uri;
  }

  String resolveUrlString(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme && uri.hasAuthority) {
      return uri.toString();
    }
    return baseUri.resolve(trimmed).toString();
  }

  Future<Map<String, dynamic>> _getJsonMap(String path) async {
    return _sendRequest('GET', path);
  }

  Future<Map<String, dynamic>> _sendRequest(
    String method,
    String path, {
    Object? body,
  }) async {
    try {
      final request = await _httpClient
          .openUrl(method, resolveUri(path))
          .timeout(const Duration(seconds: 5));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        request.headers.set(
            HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
            const Duration(seconds: 8),
          );
      final bodyText = await utf8.decoder.bind(response).join().timeout(
            const Duration(seconds: 8),
          );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw RemoteLibraryRequestException(
          '远程资源请求失败：${response.statusCode}',
          response.statusCode,
        );
      }
      if (bodyText.trim().isEmpty) {
        return const <String, dynamic>{};
      }
      final decoded = jsonDecode(bodyText);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
      throw const RemoteLibraryDataSourceException('服务端返回了无效数据');
    } on TimeoutException {
      throw const RemoteLibraryDataSourceException('远程服务响应超时');
    } on SocketException {
      throw const RemoteLibraryDataSourceException('无法连接远程服务');
    } on FormatException {
      throw const RemoteLibraryDataSourceException('服务端返回了不可解析的数据');
    }
  }
}

int? _readInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}

String _readText(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

List<String> _readStringList(Object? value) {
  if (value is List) {
    return value
        .map((entry) => entry.toString().trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }
  return const [];
}

List<Size?> _readPageSizes(Object? value) {
  if (value is! List) {
    return const <Size?>[];
  }
  return value.map((entry) {
    if (entry is! Map) {
      return null;
    }
    final width = _readInt(entry['width']);
    final height = _readInt(entry['height']);
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return Size(width.toDouble(), height.toDouble());
  }).toList(growable: false);
}

Map<String, dynamic> _readNestedMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, entry) => MapEntry(key.toString(), entry));
  }
  return const <String, dynamic>{};
}

List<String> _readFirstStringList(Iterable<Object?> values) {
  for (final value in values) {
    final entries = _readStringList(value);
    if (entries.isNotEmpty) {
      return entries;
    }
  }
  return const <String>[];
}
