part of pica_reader;

class PicacgReadingData extends ReadingData {
  PicacgReadingData({
    required this.comic,
    this.imageManager,
  }) : eps = {
          for (var i = 0; i < comic.eps.length; i++)
            (i + 1).toString(): comic.eps[i],
        };

  final PicacgComicItem comic;
  final OnlineImageManager? imageManager;
  OnlineImageManager get _images => imageManager ?? OnlineImageManager.instance;

  @override
  String get title => comic.title;

  @override
  String get id => comic.id;

  @override
  String get downloadId => comic.id;

  @override
  String get sourceKey => 'picacg';

  @override
  ComicType get comicType => ComicType.picacg;

  @override
  bool get hasEp => true;

  @override
  final Map<String, String> eps;

  @override
  FavoriteType get favoriteType => FavoriteType.picacg;

  @override
  Future<List<String>> loadEpNetwork(int ep) async {
    final res = await PicacgNetwork().getComicContent(comic.id, ep);
    if (res.error) {
      throw Exception(res.errorMessageWithoutNull);
    }
    return res.data;
  }

  @override
  Future<StreamImageLoadResult> loadOriginalNetworkWithProgress(
          int ep, int page, String url,
          {StreamImageAbortSignal? abortSignal}) =>
      _images.getImage(url,
          cacheIdentity: originalNetworkCacheIdentity(ep, page, url),
          abortSignal: abortSignal);

  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) async* {
    final result = await loadOriginalNetworkWithProgress(ep, page, url);
    yield* result.stream;
  }

  @override
  Future<void> invalidateImage(int ep, int page, String url) async {
    if (downloaded && checkEpDownloaded(ep)) return;
    await _images.invalidateImage(url,
        cacheIdentity: originalNetworkCacheIdentity(ep, page, url));
  }

  @override
  String buildImageKey(int ep, int page, String url) =>
      originalNetworkCacheIdentity(ep, page, url);

  @override
  Future<ReaderPageSource> resolvePageSource(
      int ep, int page, String url) async {
    if (downloaded && checkEpDownloaded(ep)) {
      return super.resolvePageSource(ep, page, url);
    }
    return networkPageSource(ep, page, url,
        imageManager: _images,
        cacheIdentity: originalNetworkCacheIdentity(ep, page, url));
  }
}
