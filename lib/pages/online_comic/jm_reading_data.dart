part of pica_reader;

class JmReadingData extends ReadingData {
  JmReadingData({required this.info, this.forceOnline = false, this.pageLoader})
      : eps = {
          for (final entry in info.series.entries)
            entry.key.toString(): entry.key <= info.epNames.length
                ? info.epNames[entry.key - 1]
                : '第${entry.key}章',
        };

  final JmComicInfo info;

  /// Tests can replace transport while keeping the production page-source path.
  final JmPageLoader? pageLoader;

  /// 强制在线阅读：true 时忽略本地下载，始终走网络（长按章节触发）。
  final bool forceOnline;

  @override
  bool get downloaded => forceOnline ? false : super.downloaded;

  @override
  String get title => info.title;

  @override
  String get id => info.id;

  @override
  String get downloadId => 'jm${info.id}';

  @override
  String get sourceKey => 'jm';

  @override
  ComicType get comicType => ComicType.jm;

  @override
  bool get hasEp => info.series.length > 1;

  @override
  final Map<String, String> eps;

  @override
  FavoriteType get favoriteType => FavoriteType.jm;

  /// 获取第 [ep] 章（1-based）的图片 URL 列表
  @override
  Future<List<String>> loadEpNetwork(int ep) async {
    final chapterId = info.series[ep];
    if (chapterId == null) return const [];
    final res = await JmNetwork().getChapter(chapterId);
    if (res.error) throw Exception(res.errorMessageWithoutNull);
    return res.data;
  }

  @override
  String buildImageKey(int ep, int page, String url) =>
      '${JmPageLoader.algorithmVersion}:${originalNetworkCacheIdentity(ep, page, url)}';

  Future<JmLoadedPage> _loadPage(int ep, int page, String url,
      {StreamImageAbortSignal? abortSignal}) {
    final fileName = Uri.parse(url).pathSegments.last;
    return (pageLoader ?? JmPageLoader.instance).load(
      url: url,
      cacheIdentity: originalNetworkCacheIdentity(ep, page, url),
      headers: getJmImgHeaders(),
      episodeId: info.series[ep] ?? info.id,
      scrambleId: kJmScrambleId,
      pictureName: fileName.replaceFirst(RegExp(r'\.[^.]+$'), ''),
      abortSignal: abortSignal,
    );
  }

  @override
  Future<void> invalidateImage(int ep, int page, String url) async {
    if (downloaded && checkEpDownloaded(ep)) return;
    if (url.isEmpty) return;
    final fileName = Uri.parse(url).pathSegments.last;
    await (pageLoader ?? JmPageLoader.instance).invalidatePage(
      url: url,
      cacheIdentity: originalNetworkCacheIdentity(ep, page, url),
      headers: getJmImgHeaders(),
      episodeId: info.series[ep] ?? info.id,
      scrambleId: kJmScrambleId,
      pictureName: fileName.replaceFirst(RegExp(r'\.[^.]+$'), ''),
    );
  }

  @override
  Future<ReaderPageSource> resolvePageSource(
      int ep, int page, String url) async {
    if (downloaded && checkEpDownloaded(ep)) {
      return super.resolvePageSource(ep, page, url);
    }
    return JmReaderPageSource(
      identity: _pageIdentity(ep, page, url,
          sourceVersion: buildImageKey(ep, page, url)),
      load: (abort) => _loadPage(ep, page, url, abortSignal: abort),
    );
  }

  // Inherit the provider's request-scope and input guards. The virtual loader
  // below still returns the same complete, losslessly reconstructed JM page.
  @override
  Future<StreamImageLoadResult> loadOriginalNetworkWithProgress(
      int ep, int page, String url,
      {StreamImageAbortSignal? abortSignal}) async {
    final loaded = await _loadPage(ep, page, url, abortSignal: abortSignal);
    Stream<List<int>> read() async* {
      try {
        await for (final chunk in loaded.file.openRead()) {
          if (abortSignal?.isAborted == true) {
            throw StateError('JM page load aborted');
          }
          yield chunk;
        }
      } catch (error, stack) {
        if (abortSignal?.isAborted != true) {
          // The final leased JM cache file read is a cache boundary.
          observeReaderImageFailure(ReaderImageStage.cache, error, stack);
        }
        rethrow;
      } finally {
        loaded.release();
      }
    }

    return StreamImageLoadResult(
        stream: read(),
        expectedTotalBytes: loaded.byteLength,
        cancel: () async => loaded.release());
  }

  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) async* {
    final response = await loadOriginalNetworkWithProgress(ep, page, url);
    yield* response.stream;
  }
}
