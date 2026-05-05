import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

class RemoteLibraryDataSourceException implements Exception {
  const RemoteLibraryDataSourceException(this.message);

  final String message;

  @override
  String toString() => message;
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
  });

  final int index;
  final String title;
  final String path;
  final int imageCount;
  final int totalBytes;
  final String coverUrl;
  final List<String> pages;

  bool get hasPages => pages.isNotEmpty;

  RemoteLibraryEpisode copyWith({
    String? coverUrl,
    List<String>? pages,
  }) {
    return RemoteLibraryEpisode(
      index: index,
      title: title,
      path: path,
      imageCount: imageCount,
      totalBytes: totalBytes,
      coverUrl: coverUrl ?? this.coverUrl,
      pages: pages ?? this.pages,
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
  }) {
    comicSize = totalBytes > 0 ? totalBytes / (1024 * 1024) : null;
    directory = null;
    time = null;
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

  @override
  double? comicSize;

  bool get hasMultipleEpisodes => episodesData.length > 1;

  bool get hasCompletePages => episodesData.every((episode) => episode.hasPages);

  ImageProvider<Object>? get coverImageProvider {
    if (coverUrl.trim().isEmpty) {
      return null;
    }
    return NetworkImage(coverUrl.trim());
  }

  List<String> get pageUrls => [
        for (final episode in episodesData) ...episode.pages,
      ];

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
    );
  }

  factory RemoteLibraryComicItem.fromJson(
    Map<String, dynamic> json,
    RemoteLibraryClient client,
  ) {
    final itemId = _readText(json['id']);
    final title = _readText(json['title'], fallback: '未命名漫画');
    final detailUrl = client.resolveUrlString(_readText(json['detailUrl']));
    final episodes = _readEpisodeList(json['episodes'], client, title);
    final coverUrl = client.resolveUrlString(
      _readText(
        json['coverUrl'],
        fallback: episodes.isEmpty ? '' : episodes.first.coverUrl,
      ),
    );

    return RemoteLibraryComicItem(
      client: client,
      remoteId: itemId.isEmpty ? title : itemId,
      rootId: _readText(json['rootId']),
      title: title,
      sourceTitle: _readText(json['sourceTitle'], fallback: '远程资源'),
      remotePath: _readText(json['path']),
      coverUrl: coverUrl,
      detailUrl: detailUrl,
      episodesData: episodes,
      imageCount: _readInt(json['imageCount']) ??
          episodes.fold<int>(0, (sum, episode) => sum + episode.imageCount),
      totalBytes: _readInt(json['totalBytes']) ??
          episodes.fold<int>(0, (sum, episode) => sum + episode.totalBytes),
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
  String get subTitle =>
      hasMultipleEpisodes ? '${episodesData.length} 个章节' : '$imageCount 张图片';

  @override
  List<String> get tags => const [];

  @override
  String get sourceDisplayName => sourceTitle;

  @override
  bool get canDelete => false;

  @override
  String? get fileSystemPath => null;

  @override
  String? get localCoverPath => null;

  @override
  Map<String, dynamic> toJson() => {
        'itemId': remoteId,
        'id': remoteId,
        'rootId': rootId,
        'title': title,
        'sourceTitle': sourceTitle,
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
  String buildImageKey(int ep, int page, String url) =>
      'remote::$ep::$page::${item.client.resolveUrlString(url)}';
}

class RemoteLibraryDataSource {
  const RemoteLibraryDataSource();

  Future<List<RemoteLibraryComicItem>> fetchItems() async {
    return RemoteLibraryClient.fromCurrentSettings().fetchItems();
  }
}

class RemoteLibraryClient {
  RemoteLibraryClient._({
    required this.baseUrl,
    required this.baseUri,
  });

  final String baseUrl;
  final Uri baseUri;
  final Map<String, RemoteLibraryComicItem> _detailCache = {};

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
    return RemoteLibraryClient._(
      baseUrl: normalizedAddress,
      baseUri: baseUri,
    );
  }

  Future<List<RemoteLibraryComicItem>> fetchItems() async {
    final payload = await _getJsonMap('/api/library/items');
    final items = payload['items'];
    if (items is! List) {
      return const [];
    }
    return items
        .whereType<Map>()
        .map(
          (item) => RemoteLibraryComicItem.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
            this,
          ),
        )
        .toList(growable: false);
  }

  Future<RemoteLibraryComicItem> fetchItemDetail(String itemId) async {
    final cached = _detailCache[itemId];
    if (cached != null && cached.hasCompletePages) {
      return cached;
    }
    final payload = await _getJsonMap(
      '/api/library/items/${Uri.encodeComponent(itemId)}',
    );
    final detail = RemoteLibraryComicItem.fromJson(payload, this);
    _detailCache[itemId] = detail;
    return detail;
  }

  Stream<List<int>> loadImage(String url) async* {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(resolveUri(url)).timeout(
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
      yield* response;
    } finally {
      client.close(force: true);
    }
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
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(resolveUri(path)).timeout(
            const Duration(seconds: 5),
          );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
            const Duration(seconds: 8),
          );
      final body = await utf8.decoder.bind(response).join().timeout(
            const Duration(seconds: 8),
          );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw RemoteLibraryDataSourceException(
          '远程资源请求失败：${response.statusCode}',
        );
      }
      final decoded = jsonDecode(body);
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
    } finally {
      client.close(force: true);
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