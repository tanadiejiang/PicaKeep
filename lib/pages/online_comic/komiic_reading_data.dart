part of pica_reader;

/// Komiic 接入 PicaKeep 源无关通用阅读器 [ComicReadingPage] 的阅读数据（在线阅读）。
///
/// 与 jm/picacg 同构：Komiic 有章节概念，[eps] 的 key 是章节的 1-based 序号，
/// value 是 [KomiicChapter.displayName]。基类的 `epDisplayName(index)` 用
/// `eps.values.elementAt(index)`，`checkEpDownloaded(ep)` 用 `downloadedEps.contains(ep - 1)`，
/// 二者都建立在"eps 的插入顺序 == 章节顺序"这一前提上，因此这里直接用章节列表
/// 顺序构 map，并让 [loadEpNetwork] 用 `ep - 1` 反查章节 id，保证两端索引同源。
class KomiicReadingData extends ReadingData {
  KomiicReadingData({required this.comic}) : _chapters = comic.chapters;

  final KomiicComicInfo comic;

  /// 章节顺序快照：[loadEpNetwork] 与 [loadImageNetwork] 都用 `ep - 1` 索引它，
  /// 与 [eps] 的生成顺序严格一致。
  final List<KomiicChapter> _chapters;

  @override
  String get title => comic.title;

  @override
  String get id => comic.id;

  /// 与下载/历史侧的 id 规则一致（komiic 前缀），
  /// 否则 [ReadingData.downloaded] 无法命中已下载条目。
  @override
  String get downloadId => 'komiic${comic.id}';

  /// 必须大写：项目既有代码（download_model.dart 的 `sourceKey == 'Komiic'`
  /// 分支与 history.dart 的源列表）统一用 `'Komiic'` 作为该源标识，小写会串不上。
  @override
  String get sourceKey => 'Komiic';

  @override
  ComicType get comicType => ComicType.komiic;

  @override
  FavoriteType get favoriteType => FavoriteType.komiic;

  /// 有章节。
  @override
  bool get hasEp => true;

  /// key 用章节在列表中的 1-based 序号字符串，value 用章节展示名。
  @override
  Map<String, String> get eps => {
        for (var i = 0; i < _chapters.length; i++)
          (i + 1).toString(): _chapters[i].displayName,
      };

  /// 取第 [ep] 章（1-based）的图片 URL 列表。
  @override
  Future<List<String>> loadEpNetwork(int ep) async {
    final index = ep - 1;
    if (index < 0 || index >= _chapters.length) {
      throw Exception('Komiic 章节越界：ep=$ep，共 ${_chapters.length} 章');
    }
    final res = await KomiicNetwork().getImages(_chapters[index].id);
    if (res.error) {
      throw Exception(res.errorMessageWithoutNull);
    }
    return res.data;
  }

  /// 缓存键必须含章节维度，否则跨章同页码会串图。
  @override
  String buildImageKey(int ep, int page, String url) =>
      originalNetworkCacheIdentity(ep, page, url);

  @override
  Future<ReaderPageSource> resolvePageSource(
      int ep, int page, String url) async {
    if (downloaded && checkEpDownloaded(ep)) {
      return super.resolvePageSource(ep, page, url);
    }
    final index = ep - 1;
    if (index < 0 || index >= _chapters.length) {
      throw StateError('Komiic chapter is unavailable');
    }
    final token = KomiicNetwork().token;
    return networkPageSource(ep, page, url, headers: {
      'Referer':
          'https://komiic.com/comic/${comic.id}/chapter/${_chapters[index].id}/images/all',
      'User-Agent': KomiicNetwork.komiicUA,
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    });
  }

  /// url 是 [loadEpNetwork] 返回的 CDN 直链，带章节图片页 Referer（防盗链）。
  ///
  /// Komiic 站点对已登录用户会校验 Bearer token，因此 token 非空时一并附上；
  /// 未登录（token 为空）时按匿名请求下发，能拿到公开章节即可。
  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) async* {
    final index = ep - 1;
    if (index < 0 || index >= _chapters.length) {
      throw Exception('Komiic 章节越界：ep=$ep，共 ${_chapters.length} 章');
    }
    final chapterId = _chapters[index].id;
    final network = KomiicNetwork();
    final token = network.token;
    final headers = <String, String>{
      'Referer':
          'https://komiic.com/comic/${comic.id}/chapter/$chapterId/images/all',
      'User-Agent': KomiicNetwork.komiicUA,
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
    final result = await OnlineImageManager.instance.getImage(
      url,
      cacheIdentity: originalNetworkCacheIdentity(ep, page, url),
      headers: headers,
    );
    yield* result.stream;
  }
}
