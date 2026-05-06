import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
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

class RemoteLibraryRootSummary {
  const RemoteLibraryRootSummary({
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

  factory RemoteLibraryRootSummary.fromJson(Map<String, dynamic> json) {
    return RemoteLibraryRootSummary(
      id: _readText(json['id']),
      title: _readText(json['title'], fallback: '远程目录'),
      path: _readText(json['path']),
      exists: json['exists'] != false,
      itemCount: _readInt(json['itemCount']) ?? 0,
      totalBytes: _readInt(json['totalBytes']) ?? 0,
    );
  }
}

class RemoteLibraryRootItem extends DownloadedItem {
  RemoteLibraryRootItem({
    required this.root,
    this.coverUrl,
  }) {
    comicSize = root.totalBytes > 0 ? root.totalBytes / (1024 * 1024) : null;
  }

  final RemoteLibraryRootSummary root;
  final String? coverUrl;

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
    return NetworkImage(trimmed);
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
      };

  @override
  Widget createReadingPage({int? ep, int? page}) {
    throw const RemoteLibraryDataSourceException('远程目录不支持直接阅读');
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
    this.subtitle = '',
    this.metadataTags = const <String>[],
    this.metadataSourceDisplayName = '',
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
  final String subtitle;
  final List<String> metadataTags;
  final String metadataSourceDisplayName;

  @override
  double? comicSize;

  bool get hasMultipleEpisodes => episodesData.length > 1;

  bool get hasCompletePages => episodesData.every((episode) => episode.hasPages);

  bool get isManagedDownloadRoot =>
      rootId == 'current_download' || rootId == 'original_download';

  bool get isCustomLibraryRoot => rootId.startsWith('custom_');

  ImageProvider<Object>? get coverImageProvider {
    if (coverUrl.trim().isEmpty) {
      return null;
    }
    return NetworkImage(coverUrl.trim());
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
      subtitle: subtitle,
      metadataTags: metadataTags,
      metadataSourceDisplayName: metadataSourceDisplayName,
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
      subtitle: _readText(
        json['subtitle'],
        fallback: _readText(json['author']),
      ),
      metadataTags: _readStringList(json['tags']),
      metadataSourceDisplayName: _readText(json['sourceDisplayName']),
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
    return hasMultipleEpisodes ? '${episodesData.length} 个章节' : '$imageCount 张图片';
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
  String buildImageKey(int ep, int page, String url) =>
      'remote::$ep::$page::${item.client.resolveUrlString(url)}';
}

class _RemoteLibrarySnapshot {
  const _RemoteLibrarySnapshot({
    required this.roots,
    required this.items,
  });

  final List<RemoteLibraryRootSummary> roots;
  final List<RemoteLibraryComicItem> items;
}

class RemoteLibraryDataSource {
  const RemoteLibraryDataSource();

  Future<List<RemoteLibraryComicItem>> fetchItems() async {
    return RemoteLibraryClient.fromCurrentSettings().fetchItems();
  }

  Future<List<RemoteLibraryComicItem>> fetchItemsForRoot(String rootId) async {
    return RemoteLibraryClient.fromCurrentSettings().fetchItemsForRoot(rootId);
  }

  Future<List<RemoteLibraryRootItem>> fetchRootItems({
    bool managedDownloadOnly = false,
    bool customLibraryOnly = false,
  }) async {
    return RemoteLibraryClient.fromCurrentSettings().fetchRootItems(
      managedDownloadOnly: managedDownloadOnly,
      customLibraryOnly: customLibraryOnly,
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

  Future<List<RemoteLibraryComicItem>> fetchItems({bool forceRefresh = false}) async {
    return (await _fetchSnapshot(forceRefresh: forceRefresh)).items;
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
    return _RemoteLibrarySnapshot(
      roots: roots,
      items: items,
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
      for (final item in snapshot.items) {
        if (item.rootId != root.id) {
          continue;
        }
        final value = item.coverUrl.trim();
        if (value.isNotEmpty) {
          coverUrl = value;
          break;
        }
      }
      return RemoteLibraryRootItem(root: root, coverUrl: coverUrl);
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
      grouped.putIfAbsent(item.rootId, () => <RemoteLibraryComicItem>[]).add(item);
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
    if (cached != null && cached.hasCompletePages) {
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

  Future<RemoteLibraryComicItem> _fetchItemDetailFromNetwork(String itemId) async {
    final payload = await _getJsonMap(
      '/api/library/items/${Uri.encodeComponent(itemId)}',
    );
    final detail = RemoteLibraryComicItem.fromJson(payload, this);
    _detailCache[itemId] = detail;
    return detail;
  }

  Stream<List<int>> loadImage(String url) async* {
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
      yield* response;
    } on SocketException {
      throw const RemoteLibraryDataSourceException('无法连接远程图片资源');
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
    try {
      final request = await _httpClient.getUrl(resolveUri(path)).timeout(
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