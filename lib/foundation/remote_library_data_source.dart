import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/archive/archive_models.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/image_favorites.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
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

class RemoteFavoriteFolder {
  const RemoteFavoriteFolder({
    required this.name,
    required this.count,
  });

  final String name;
  final int count;

  factory RemoteFavoriteFolder.fromJson(Map<String, dynamic> json) {
    return RemoteFavoriteFolder(
      name: _readText(json['name']),
      count: _readInt(json['count']) ?? 0,
    );
  }
}

class RemoteFavoriteItem {
  const RemoteFavoriteItem({
    required this.name,
    required this.author,
    required this.type,
    required this.tags,
    required this.target,
    required this.time,
    required this.coverUrl,
  });

  final String name;
  final String author;
  final FavoriteType type;
  final List<String> tags;
  final String target;
  final String time;
  final String coverUrl;

  FavoriteItem toLocalFavoriteItem() {
    return FavoriteItem(
      target: target,
      name: name,
      coverPath: '',
      author: author,
      type: type,
      tags: tags,
    )..time = time;
  }

  factory RemoteFavoriteItem.fromJson(
    Map<String, dynamic> json,
    RemoteLibraryClient client,
  ) {
    return RemoteFavoriteItem(
      name: _readText(json['name']),
      author: _readText(json['author']),
      type: FavoriteType(_readInt(json['type']) ?? 0),
      tags: _readStringList(json['tags']),
      target: _readText(json['target']),
      time: _readText(json['time']),
      coverUrl: client.resolveUrlString(_readText(json['coverUrl'])),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'author': author,
        'type': type.key,
        'tags': tags,
        'target': target,
        'time': time,
      };
}

class RemoteImageFavorite {
  const RemoteImageFavorite({
    required this.id,
    required this.title,
    required this.ep,
    required this.page,
    required this.otherInfo,
    required this.imageUrl,
  });

  final String id;
  final String title;
  final int ep;
  final int page;
  final Map<String, dynamic> otherInfo;
  final String imageUrl;

  ImageFavorite toLocalImageFavorite() {
    return ImageFavorite(id, '', title, ep, page, otherInfo);
  }

  factory RemoteImageFavorite.fromJson(
    Map<String, dynamic> json,
    RemoteLibraryClient client,
  ) {
    return RemoteImageFavorite(
      id: _readText(json['id']),
      title: _readText(json['title']),
      ep: _readInt(json['ep']) ?? 0,
      page: _readInt(json['page']) ?? 0,
      otherInfo: _readNestedMap(json['otherInfo']),
      imageUrl: client.resolveUrlString(_readText(json['imageUrl'])),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'ep': ep,
        'page': page,
        'otherInfo': otherInfo,
      };
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
    this.isArchive = false,
    this.archiveEncrypted = false,
    this.archivePasswordMatched = true,
    this.archiveFormat = ArchiveFormat.unknown,
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
  final bool isArchive;
  final bool archiveEncrypted;
  bool archivePasswordMatched;
  final ArchiveFormat archiveFormat;

  @override
  double? comicSize;

  bool get needsArchivePassword =>
      isArchive && archiveEncrypted && !archivePasswordMatched;

  String get archiveFormatDisplay {
    final encrypted = archiveEncrypted ? '加密 ' : '';
    return switch (archiveFormat) {
      ArchiveFormat.cbz => '${encrypted}CBZ',
      ArchiveFormat.zip => '${encrypted}ZIP',
      ArchiveFormat.unknown => '$encrypted压缩包',
    };
  }

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
    if (displayId.isNotEmpty) {
      yield displayId;
    }
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
    bool? archivePasswordMatched,
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
      isArchive: isArchive,
      archiveEncrypted: archiveEncrypted,
      archivePasswordMatched:
          archivePasswordMatched ?? this.archivePasswordMatched,
      archiveFormat: archiveFormat,
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
      isArchive: json['isArchive'] == true ||
          _readText(json['itemKind']).toLowerCase() == 'archive',
      archiveEncrypted: json['archiveEncrypted'] == true,
      archivePasswordMatched: json['archivePasswordMatched'] != false,
      archiveFormat: _readArchiveFormat(json['archiveFormat']),
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
  String get subTitle => subtitle.trim();

  @override
  List<String> get tags => metadataTags;

  @override
  String get sourceDisplayName {
    if (isArchive) {
      return archiveEncrypted ? '加密压缩包' : '压缩包';
    }
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
        'itemKind': isArchive ? 'archive' : 'directory',
        'isArchive': isArchive,
        'archiveEncrypted': archiveEncrypted,
        'archivePasswordMatched': archivePasswordMatched,
        'archiveFormat': archiveFormat.name,
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

/// Thrown when a remote cover/image is known to be unavailable (e.g. the
/// server has no image file for this favorite). It is consumed by the
/// widget-level `errorBuilder` to show a placeholder, and is intentionally
/// lightweight so it does not spam the console.
class RemoteCoverUnavailableException implements Exception {
  const RemoteCoverUnavailableException();

  @override
  String toString() => 'RemoteCoverUnavailableException';
}

class _RemoteLibraryCoverDiskCache {
  static final Map<String, Future<File>> _pending = <String, Future<File>>{};

  /// Negative cache: URLs whose download recently failed. Keyed by url, value
  /// is the time the failure expires. While present and unexpired, we skip the
  /// network entirely so a screen full of missing covers cannot flood the
  /// server with doomed requests (which would starve the /status probe and
  /// make remote tabs look "offline").
  static final Map<String, DateTime> _failureUntil = <String, DateTime>{};

  /// 404 (server genuinely has no file) is unlikely to fix itself quickly, so
  /// it gets a longer cooldown than transient errors (timeouts, socket drops),
  /// which deserve a quick retry.
  static const Duration _notFoundCooldown = Duration(minutes: 10);
  static const Duration _transientCooldown = Duration(seconds: 20);

  /// Coalesces [_trimToLimit] so a burst of cover downloads cannot trigger a
  /// burst of full-tree disk scans on the event loop.
  static const Duration _trimMinInterval = Duration(seconds: 30);
  static bool _trimInFlight = false;
  static DateTime? _lastTrimAt;

  static bool _isInFailureWindow(String url) {
    final until = _failureUntil[url];
    if (until == null) {
      return false;
    }
    if (DateTime.now().isAfter(until)) {
      _failureUntil.remove(url);
      return false;
    }
    return true;
  }

  static void _recordFailure(String url, Object error) {
    final isNotFound =
        error is RemoteLibraryRequestException && error.statusCode == 404;
    _failureUntil[url] =
        DateTime.now().add(isNotFound ? _notFoundCooldown : _transientCooldown);
  }

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

    // Recently failed (e.g. server has no image for this favorite): skip the
    // network so a grid full of missing covers does not flood the server.
    if (_isInFailureWindow(url)) {
      throw const RemoteCoverUnavailableException();
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
      // Route cover downloads through the BULK image pool (_httpClient), NOT
      // the control pool. Covers and the JSON control calls (folder list, item
      // list, /status probe) are shown together — a grid loads N cover streams
      // while the page also needs to fetch its list. If covers sat on the small
      // control pool they would occupy all its connections and the list/detail
      // calls would time out ("远程加载失败" on both favorites pages, and a tap
      // throwing "远程服务响应超时"). The reader's full-page streams (also bulk)
      // are never on screen at the same time as a cover grid, so they do not
      // contend. lightweight=false keeps covers off the control plane;
      // isCover=true makes them draw from the browse concurrency budget.
      await for (final chunk
          in client.loadImage(url, lightweight: false, isCover: true)) {
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
      _failureUntil.remove(url);
      return target;
    } catch (error) {
      _recordFailure(url, error);
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await temp.exists()) {
          await temp.delete();
        }
      } catch (_) {}
      // Collapse to a quiet, expected failure so the widget errorBuilder can
      // show a placeholder without the console being spammed by 404s.
      throw const RemoteCoverUnavailableException();
    }
  }

  static Future<void> _trimToLimit({required String protectedPath}) async {
    // This walks the entire cache tree (twice) reading every file's size. It is
    // invoked after every cover download, so when a grid loads dozens of covers
    // at once it would otherwise run dozens of full-disk scans back to back,
    // saturating the event loop (visible as "doing too much work on its main
    // thread" / skipped frames) and starving the .timeout() timers that the
    // list requests depend on — which is exactly when the remote tabs appear to
    // hang on the loading spinner. Coalesce: never overlap, and run at most once
    // per interval. Trimming is best-effort eviction, so a slightly stale run is
    // harmless.
    if (_trimInFlight) {
      return;
    }
    final lastTrim = _lastTrimAt;
    if (lastTrim != null &&
        DateTime.now().difference(lastTrim) < _trimMinInterval) {
      return;
    }
    _trimInFlight = true;
    try {
      await _trimToLimitInner(protectedPath: protectedPath);
    } finally {
      _lastTrimAt = DateTime.now();
      _trimInFlight = false;
    }
  }

  static Future<void> _trimToLimitInner({required String protectedPath}) async {
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

/// A simple async semaphore: at most N holders run concurrently (N is read
/// live via [_permitsResolver]); the rest await in FIFO order. Used to cap how many remote image requests are
/// in flight at once so they never exceed the HttpClient connection pool. When
/// they would, the surplus piles up inside `getUrl` and fails with a 5s
/// "couldn't acquire a connection" timeout — and because that timeout cannot
/// cancel the queued connection attempt, the orphaned attempts churn the pool
/// forever, poisoning every remote tab. Capping in front of `getUrl` removes
/// that failure mode entirely.
///
/// The permit count is read live on each acquire so a settings change takes
/// effect immediately (it only affects newly acquired permits, never revokes
/// ones already held).
class _ImageConcurrencyLimiter {
  _ImageConcurrencyLimiter(this._permitsResolver);

  final int Function() _permitsResolver;
  int _active = 0;
  final _waiters = <Completer<void>>[];

  Future<void> acquire() {
    if (_active < _permitsResolver()) {
      _active++;
      return Future<void>.value();
    }
    // At capacity: queue. The permit is handed to us by release() without
    // changing _active, so we must NOT increment here (doing so would let a
    // synchronous acquire() in the gap before our microtask runs double-count
    // the freed slot and exceed the limit).
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    // Prefer to hand this holder's permit straight to the next waiter (keep
    // _active unchanged). Only when no waiter can be admitted under the current
    // (possibly just-lowered) limit do we actually free the permit.
    if (_waiters.isNotEmpty && _active <= _permitsResolver()) {
      final next = _waiters.removeAt(0);
      if (!next.isCompleted) {
        next.complete();
        return;
      }
    }
    if (_active > 0) {
      _active--;
    }
  }
}

class RemoteLibraryClient {
  RemoteLibraryClient._({
    required this.baseUrl,
    required this.baseUri,
  })  : _httpClient = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5)
          ..idleTimeout = const Duration(seconds: 20)
          // Must be >= the sum of both image concurrency limiters' maximums
          // (reader up to 12 + browse up to 12 = 24). The limiters already cap
          // how many requests we launch; sizing the pool to match guarantees a
          // launched request never has to queue inside getUrl, so the 5s
          // "acquire a connection" timeout — and the orphaned-connection pool
          // exhaustion it used to cause — cannot happen under normal use.
          ..maxConnectionsPerHost = 24,
        // Separate client for control-plane requests (JSON list/detail/
        // favorites) so the bulk image pool used by the reader cannot starve
        // them. Reader sessions can hold dozens of in-flight image streams
        // and saturate _httpClient; lightweight metadata calls would then time
        // out, breaking favorites lists and remote tab loads.
        _controlClient = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5)
          ..idleTimeout = const Duration(seconds: 20)
          ..maxConnectionsPerHost = 6;

  static final Map<String, RemoteLibraryClient> _instances = {};

  final String baseUrl;
  final Uri baseUri;
  final HttpClient _httpClient;
  final HttpClient _controlClient;

  // Caps in-flight remote image requests so they never exceed the connection
  // pool. Reader pages and browse covers get separate budgets because they are
  // never on screen at the same time. Limits are read live from settings.
  final _ImageConcurrencyLimiter _readerImageLimiter = _ImageConcurrencyLimiter(
    () => normalizeRemoteReaderImageConcurrency(
      appdata.settings[remoteReaderImageConcurrencySettingIndex],
    ),
  );
  final _ImageConcurrencyLimiter _browseImageLimiter = _ImageConcurrencyLimiter(
    () => normalizeRemoteBrowseImageConcurrency(
      appdata.settings[remoteBrowseImageConcurrencySettingIndex],
    ),
  );

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

  Future<List<RemoteFavoriteFolder>> fetchFavoriteFolders() async {
    final payload = await _getJsonMap('/api/library/favorites');
    final foldersValue = payload['folders'];
    if (foldersValue is! List) {
      return const <RemoteFavoriteFolder>[];
    }
    return foldersValue
        .whereType<Map>()
        .map(
          (folder) => RemoteFavoriteFolder.fromJson(
            folder.map((key, value) => MapEntry(key.toString(), value)),
          ),
        )
        .toList(growable: false);
  }

  Future<List<RemoteFavoriteItem>> fetchFavoritesInFolder(String folder) async {
    final payload = await _getJsonMap(
      '/api/library/favorites/${Uri.encodeComponent(folder)}',
    );
    final itemsValue = payload['items'];
    if (itemsValue is! List) {
      return const <RemoteFavoriteItem>[];
    }
    return itemsValue
        .whereType<Map>()
        .map(
          (item) => RemoteFavoriteItem.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
            this,
          ),
        )
        .toList(growable: false);
  }

  Future<List<RemoteImageFavorite>> fetchImageFavorites() async {
    final payload = await _getJsonMap('/api/library/image-favorites');
    final itemsValue = payload['items'];
    if (itemsValue is! List) {
      return const <RemoteImageFavorite>[];
    }
    return itemsValue
        .whereType<Map>()
        .map(
          (item) => RemoteImageFavorite.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
            this,
          ),
        )
        .toList(growable: false);
  }

  Future<void> createRemoteFolder(String name) async {
    await _sendRequest(
      'POST',
      '/api/library/favorites',
      body: {'name': name},
    );
    _clearCaches();
  }

  Future<void> deleteRemoteFolder(String folder) async {
    await _sendRequest(
      'DELETE',
      '/api/library/favorites/${Uri.encodeComponent(folder)}',
    );
    _clearCaches();
  }

  Future<void> renameRemoteFolder(String folder, String newName) async {
    await _sendRequest(
      'PUT',
      '/api/library/favorites/${Uri.encodeComponent(folder)}',
      body: {'newName': newName},
    );
    _clearCaches();
  }

  Future<void> addRemoteFavorite(String folder, FavoriteItem item) async {
    await _sendRequest(
      'POST',
      '/api/library/favorites/${Uri.encodeComponent(folder)}',
      body: item.toJson(),
    );
    _clearCaches();
  }

  Future<void> deleteRemoteFavorite(
      String folder, RemoteFavoriteItem item) async {
    await _sendRequest(
      'DELETE',
      '/api/library/favorites/${Uri.encodeComponent(folder)}/${Uri.encodeComponent(item.target)}',
    );
    _clearCaches();
  }

  Future<void> addRemoteImageFavorite(ImageFavorite item) async {
    await _sendRequest(
      'POST',
      '/api/library/image-favorites',
      body: {
        'id': item.id,
        'imagePath': item.imagePath,
        'title': item.title,
        'ep': item.ep,
        'page': item.page,
        'otherInfo': item.otherInfo,
      },
    );
    _clearCaches();
  }

  Future<void> deleteRemoteImageFavorite(RemoteImageFavorite item) async {
    await _sendRequest(
      'DELETE',
      '/api/library/image-favorites/${Uri.encodeComponent(item.id)}/${item.ep}/${item.page}',
    );
    _clearCaches();
  }

  Future<void> rescanLibrary() async {
    await _sendRequest(
      'POST',
      '/api/library/items/refresh',
    );
    _clearCaches();
  }

  Future<bool> unlockArchive(String itemId, String password) async {
    final payload = await _sendRequest(
      'POST',
      '/api/library/items/${Uri.encodeComponent(itemId)}/archive/unlock',
      body: {'password': password},
    );
    final ok = payload['ok'] == true && payload['passwordMatched'] == true;
    if (ok) {
      _clearCaches();
    }
    return ok;
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

  /// Opens an HTTP connection with a timeout that does NOT leak the socket.
  ///
  /// `future.timeout(d)` only abandons the *front-end* future — the underlying
  /// `HttpClient` keeps trying to open the connection. If it eventually
  /// succeeds AFTER we have given up, the returned [HttpClientRequest] is owned
  /// by no one: nobody calls close()/abort(), so its socket stays pinned in the
  /// keep-alive pool forever. A handful of these and `maxConnectionsPerHost` is
  /// exhausted by orphans → every later request times out trying to acquire a
  /// connection → all remote image loading dies until the isolate is rebuilt
  /// (hot restart / app relaunch), which is exactly the observed symptom.
  ///
  /// Here we keep the orphan future and, if the timeout wins, attach a
  /// continuation that aborts the request whenever it finally resolves, handing
  /// the connection straight back to the pool.
  static Future<HttpClientRequest> _openWithTimeout(
    Future<HttpClientRequest> connecting,
    Duration timeout,
  ) {
    return connecting.timeout(
      timeout,
      onTimeout: () {
        // Reclaim the connection once (if) it eventually opens.
        unawaited(connecting.then(
          (request) {
            try {
              request.abort();
            } catch (_) {}
          },
          onError: (_) {},
        ));
        throw TimeoutException('connection acquisition timed out', timeout);
      },
    );
  }

  Future<StreamImageLoadResult> loadImageWithProgress(
    String url, {
    bool lightweight = false,
    bool isCover = false,
  }) async {
    final client = lightweight ? _controlClient : _httpClient;
    // Acquire a concurrency permit BEFORE touching getUrl. This is the core
    // fix: without it, a reader/grid that fires dozens of image requests at
    // once overflows the connection pool, the surplus blocks inside getUrl, and
    // each fails with a 5s timeout that cannot cancel its queued connection
    // attempt — orphaned attempts then churn the singleton pool forever and
    // every remote tab dies. Capping here means getUrl is only ever called when
    // a connection is actually available, so it returns promptly.
    final limiter = isCover ? _browseImageLimiter : _readerImageLimiter;
    await limiter.acquire();
    var permitReleased = false;
    void releasePermit() {
      if (!permitReleased) {
        permitReleased = true;
        limiter.release();
      }
    }

    HttpClientRequest? request;
    try {
      request = await _openWithTimeout(
        client.getUrl(resolveUri(url)),
        const Duration(seconds: 5),
      );
      final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // A non-2xx response (e.g. a 404 for a missing cover) STILL has a live
        // body and an attached socket. dart:io only returns that socket to the
        // keep-alive pool once the body is fully consumed. request.abort() here
        // is unreliable after close() — the socket is owned by the response by
        // now — so the connection leaks. Scrolling a folder full of missing
        // covers then leaks one connection per cover; after maxConnectionsPerHost
        // (24) the pool is exhausted and EVERY later image (covers AND reader
        // pages, which share _httpClient) hangs until the isolate is rebuilt
        // (hot restart). drain() reads/discards the body so the connection is
        // cleanly recycled. A short timeout guards against a 404 whose body
        // itself stalls — only then do we fall back to abort.
        try {
          await response.drain<void>().timeout(const Duration(seconds: 5));
        } catch (_) {
          try {
            request.abort();
          } catch (_) {}
        }
        releasePermit();
        throw RemoteLibraryRequestException(
          '远程图片请求失败：${response.statusCode}',
          response.statusCode,
        );
      }
      // Permit ownership transfers to the body stream — released in its finally
      // (on normal completion, error, or consumer cancellation).
      return StreamImageLoadResult(
        stream: _guardedImageBody(request, response, releasePermit),
        expectedTotalBytes:
            response.contentLength >= 0 ? response.contentLength : null,
      );
    } on TimeoutException {
      // Critical: a front-end .timeout() does NOT cancel the underlying
      // socket. Without abort(), timed-out reader image requests keep the
      // connection pinned in the pool — after a few comics the pool fills up
      // and every later request times out at "5s to get a connection",
      // producing a screen of broken covers and unreadable comics. abort()
      // releases the socket back to the pool.
      try {
        request?.abort();
      } catch (_) {}
      releasePermit();
      rethrow;
    } on SocketException {
      try {
        request?.abort();
      } catch (_) {}
      releasePermit();
      throw const RemoteLibraryDataSourceException('无法连接远程图片资源');
    } catch (_) {
      // Any other failure before the stream is handed off must still free the
      // permit, or the limiter would leak slots and eventually deadlock.
      releasePermit();
      rethrow;
    }
  }

  /// Streams an HTTP response body while guaranteeing the socket is released.
  ///
  /// The front-end `.timeout()` in [loadImageWithProgress] only bounds
  /// connection setup and header arrival. The body itself can either stall
  /// (server sent headers then hung) or be abandoned by the consumer (image
  /// evicted from the cache, reader/favorites page disposed). In both cases a
  /// bare `await for` over the raw response leaves the socket pinned in the
  /// keep-alive pool forever. After a handful of these the small _controlClient
  /// pool — shared with the favorites / image-favorites list calls — is fully
  /// consumed by zombie sockets, so every later control request times out and
  /// the remote tabs look "stuck loading", even after leaving and re-entering
  /// the page (the poisoned pool lives in the client singleton).
  ///
  /// An idle timeout aborts a stalled transfer; the `finally` aborts when the
  /// stream is cancelled or errors before completing. A normally-completed body
  /// is left untouched so its connection can be reused (keep-alive). The
  /// concurrency permit acquired in [loadImageWithProgress] is released here
  /// exactly once, whichever way the stream ends.
  Stream<List<int>> _guardedImageBody(
    HttpClientRequest request,
    HttpClientResponse response,
    void Function() releasePermit,
  ) async* {
    var completed = false;
    try {
      yield* response.timeout(
        const Duration(seconds: 15),
        onTimeout: (sink) {
          try {
            request.abort();
          } catch (_) {}
          sink.addError(
            const RemoteLibraryDataSourceException('远程图片传输超时'),
          );
          sink.close();
        },
      );
      completed = true;
    } finally {
      if (!completed) {
        try {
          request.abort();
        } catch (_) {}
      }
      releasePermit();
    }
  }

  Stream<List<int>> loadImage(
    String url, {
    bool lightweight = false,
    bool isCover = false,
  }) async* {
    final result = await loadImageWithProgress(
      url,
      lightweight: lightweight,
      isCover: isCover,
    );
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
    HttpClientRequest? request;
    try {
      request = await _openWithTimeout(
        _controlClient.openUrl(method, resolveUri(path)),
        const Duration(seconds: 5),
      );
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
    } on RemoteLibraryRequestException {
      rethrow;
    } on TimeoutException {
      // Without abort(), a timed-out HTTP request keeps its socket pinned in
      // the connection pool. After a few timeouts the small _controlClient
      // pool (maxConnectionsPerHost=6) is fully consumed by zombie sockets
      // and ALL subsequent control-plane requests (favorites list, item
      // details, etc.) start timing out. abort() returns the socket to the
      // pool. Mirror the same fix in loadImageWithProgress.
      try {
        request?.abort();
      } catch (_) {}
      throw const RemoteLibraryDataSourceException('远程服务响应超时');
    } on SocketException {
      try {
        request?.abort();
      } catch (_) {}
      throw const RemoteLibraryDataSourceException('无法连接远程服务');
    } on FormatException {
      try {
        request?.abort();
      } catch (_) {}
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

ArchiveFormat _readArchiveFormat(Object? value) {
  return switch (_readText(value).toLowerCase()) {
    'zip' => ArchiveFormat.zip,
    'cbz' => ArchiveFormat.cbz,
    _ => ArchiveFormat.unknown,
  };
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
