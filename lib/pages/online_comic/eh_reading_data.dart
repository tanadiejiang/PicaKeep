part of pica_reader;

typedef _EhReaderImageRequest = ({
  String url,
  String cacheIdentity,
  Map<String, String> headers,
});

/// ehentai 画廊接入 PicaKeep 源无关通用阅读器 [ComicReadingPage] 的阅读数据。
///
/// 与 picacg/jm 的根本差异：ehentai 没有章节概念，一本画廊就是一组连续页图，
/// 且页图真实 URL 不能直接拼出，必须经 [EhNetwork.getEhImageUrl] 的
/// showKey/mpvKey 状态机向服务器换取本次会话的直链（解密+重试全在网络层）。
class EhReadingData extends ReadingData {
  EhReadingData(this.gallery, {this.imageManager, this.imageUrlLoader});

  final Gallery gallery;
  final OnlineImageManager? imageManager;

  /// Optional URL resolver, receiving the existing 1-based gallery page number.
  final Future<String> Function(int page)? imageUrlLoader;
  OnlineImageManager get _images => imageManager ?? OnlineImageManager.instance;
  final _lastImageRequests = <(int, int), _EhReaderImageRequest>{};

  @override
  String get imageAccessScope {
    final headers = EhNetwork().galleryHeaders(gallery.link);
    // EH authentication lives in its independent CookieJar, not source.data.
    // getCookies legitimately toggles nw/sp during URL resolution; those are
    // preferences, not account changes. Keep the actual configured sp version.
    final cookies = (headers['Cookie'] ?? '').split(';')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && !value.startsWith('nw=') &&
            !value.startsWith('sp=')).toList()..sort();
    return sha256.convert(utf8.encode(jsonEncode([
      super.imageAccessScope, headers['Referer'], headers['User-Agent'],
      appdata.settings[75], cookies,
    ]))).toString();
  }

  Future<_EhReaderImageRequest> _imageRequest(int ep, int page) async {
    final scope = imageAccessScope;
    final loader = imageUrlLoader;
    final target = loader != null
        ? await loader(page + 1)
        : (await EhNetwork().getEhImageUrl(gallery, page + 1)).$1;
    if (imageAccessScope != scope) {
      throw StateError('EH image account changed during URL resolution');
    }
    final request = (
      url: target,
      cacheIdentity: originalNetworkCacheIdentity(ep, page, target),
      headers: Map<String, String>.unmodifiable(
          EhNetwork().galleryHeaders(gallery.link)),
    );
    _lastImageRequests[(ep, page)] = request;
    return request;
  }

  @override
  String get title => gallery.title;

  /// 唯一标识：画廊完整 URL（公共契约）。
  @override
  String get id => gallery.link;

  /// 与 [DownloadedGallery.id] 规则一致（getGalleryId(link)，不带前缀），
  /// 否则 [ReadingData.downloaded] 无法命中已下载条目。
  @override
  String get downloadId => getGalleryId(gallery.link);

  @override
  String get sourceKey => 'ehentai';

  @override
  String get untranslatedTagComicId => getGalleryId(gallery.link);

  @override
  Iterable<String> get untranslatedTagFlatTags => [
        for (final entry in gallery.tags.entries)
          for (final tag in entry.value) '${entry.key}:$tag',
      ];

  @override
  Map<String, List<String>> get untranslatedTagCategorizedTags => gallery.tags;

  @override
  ComicType get comicType => ComicType.ehentai;

  @override
  FavoriteType get favoriteType => FavoriteType.ehentai;

  /// 无章节：单画廊多图。
  @override
  bool get hasEp => false;

  @override
  Map<String, String>? get eps => null;

  /// 忽略 ep，返回 maxPage 个空占位（共 maxPage 页，真实 URL 延迟到
  /// [loadImageNetwork] 时逐页解密）。
  @override
  Future<List<String>> loadEpNetwork(int ep) async {
    final maxPage = int.tryParse(gallery.maxPage) ?? 1;
    return List.filled(maxPage > 0 ? maxPage : 1, '');
  }

  /// 缓存键与 ep 无关，仅 link + page（公共契约）。
  @override
  String buildImageKey(int ep, int page, String url) =>
      originalNetworkCacheIdentity(ep, page, url);

  @override
  Future<ReaderPageSource> resolvePageSource(
      int ep, int page, String url) async {
    if (downloaded && checkEpDownloaded(ep)) {
      return super.resolvePageSource(ep, page, url);
    }
    final request = await _imageRequest(ep, page);
    return networkPageSource(ep, page, request.url,
        headers: request.headers,
        imageManager: _images,
        cacheIdentity: request.cacheIdentity);
  }

  /// 逐页解密并加载：
  /// 1. [EhNetwork.getEhImageUrl] 解密拿已验证可用直链（page 0-based → 1-based）。
  /// 2. [OnlineImageManager] 带图片鉴权三件套下载字节流。
  /// 状态机内部已重试 4 次；此处兜底捕获最终失败，避免阅读器崩溃。
  @override
  Future<StreamImageLoadResult> loadOriginalNetworkWithProgress(
      int ep, int page, String url,
      {StreamImageAbortSignal? abortSignal}) async {
    if (abortSignal?.isAborted == true) throw StateError('Image load aborted');
    // The existing showKey/MPV resolver has no abort API. Image transfer still
    // receives cancellation, including an abort that arrived during resolution.
    final request = await _imageRequest(ep, page);
    return _images.getImage(request.url,
        cacheIdentity: request.cacheIdentity,
        headers: request.headers,
        abortSignal: abortSignal);
  }

  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) async* {
    final result = await loadOriginalNetworkWithProgress(ep, page, url);
    yield* result.stream;
  }

  @override
  Future<void> invalidateImage(int ep, int page, String url) async {
    if (downloaded && checkEpDownloaded(ep)) return;
    final request = _lastImageRequests[(ep, page)];
    if (request == null) return;
    // Do not resolve a fresh signed URL here or clear a previous account's key.
    if (request.cacheIdentity !=
            originalNetworkCacheIdentity(ep, page, request.url) ||
        jsonEncode(request.headers) !=
            jsonEncode(EhNetwork().galleryHeaders(gallery.link))) {
      return;
    }
    await _images.invalidateImage(request.url,
        cacheIdentity: request.cacheIdentity, headers: request.headers);
  }
}
