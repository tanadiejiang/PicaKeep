part of pica_reader;

/// nhentai 画廊接入 PicaKeep 源无关通用阅读器 [ComicReadingPage] 的阅读数据（在线阅读）。
///
/// 与 ehentai 同构：无章节概念，一本画廊就是一组连续页图。差异在于 nhentai 图片是
/// CDN 直链——[NhentaiNetwork.getImages] 一次性返回全部页的真实 URL（无需逐页解密），
/// 故 [loadEpNetwork] 直接返回 URL 列表，[loadImageNetwork] 带 Referer 头直接下载。
class NhentaiReadingData extends ReadingData {
  NhentaiReadingData({required this.comic});

  final NhentaiComic comic;

  @override
  String get title => comic.title;

  @override
  String get id => comic.id;

  /// 与 [NhentaiDownloadedComic.id] 规则一致（nhentai 前缀），
  /// 否则 [ReadingData.downloaded] 无法命中已下载条目。
  @override
  String get downloadId => 'nhentai${comic.id}';

  @override
  String get sourceKey => 'nhentai';

  @override
  ComicType get comicType => ComicType.nhentai;

  @override
  FavoriteType get favoriteType => FavoriteType.nhentai;

  /// 无章节：单画廊多图。
  @override
  bool get hasEp => false;

  @override
  Map<String, String>? get eps => null;

  /// nhentai 直接返回完整 URL 列表（区别于 eh 的空占位 + 逐页 showKey 解密）。
  @override
  Future<List<String>> loadEpNetwork(int ep) async {
    final res = await NhentaiNetwork().getImages(comic.id);
    if (res.error) {
      throw Exception(res.errorMessageWithoutNull);
    }
    return res.data;
  }

  /// 缓存键与 ep 无关，仅 id + page（公共契约）。
  @override
  String buildImageKey(int ep, int page, String url) => '${comic.id}$page';

  /// url 是 [loadEpNetwork] 返回的 CDN 直链，带 Referer 头规避防盗链，无需解密。
  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) async* {
    final result = await OnlineImageManager.instance.getImage(
      url,
      headers: const {'Referer': 'https://nhentai.net/'},
    );
    yield* result.stream;
  }
}
