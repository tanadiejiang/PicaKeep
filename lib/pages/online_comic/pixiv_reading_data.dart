part of pica_reader;

/// Pixiv 接入 PicaKeep 源无关通用阅读器 [ComicReadingPage] 的阅读数据（在线阅读）。
///
/// 与 nhentai 同构：Pixiv 单本书（作品）没有章节概念，一本作品就是一组连续页图。
/// [PixivNetwork.getComicPages] 一次性返回全部页的多档 URL，故 [loadEpNetwork]
/// 直接返回按画质档位挑选后的 URL 列表，[loadImageNetwork] 带 Referer 头直连下载。
class PixivReadingData extends ReadingData {
  PixivReadingData({required this.comic, this.originalQuality = false});

  final PixivComicInfo comic;

  /// 是否为原图画质：true 取 `urls.original`，false 取 `urls.regular`。
  final bool originalQuality;

  @override
  String get title => comic.title;

  @override
  String get id => comic.id;

  /// 与下载/历史侧的 id 规则一致（pixiv 前缀），
  /// 否则 [ReadingData.downloaded] 无法命中已下载条目。
  @override
  String get downloadId => 'pixiv${comic.id}';

  @override
  String get sourceKey => 'pixiv';

  @override
  ComicType get comicType => ComicType.pixiv;

  @override
  FavoriteType get favoriteType => FavoriteType.pixiv;

  /// 无章节：单作品多图。
  @override
  bool get hasEp => false;

  @override
  Map<String, String>? get eps => null;

  /// 取本作品全部页图。
  ///
  /// 优先按 [originalQuality] 选档；若目标档位为空串（Pixiv 对部分老作品不下发
  /// original），按 regular → small → thumbMini 顺序回退到第一个非空者，
  /// 保证阅读器永远拿不到空 URL。
  @override
  Future<List<String>> loadEpNetwork(int ep) async {
    final res = await PixivNetwork().getComicPages(comic.id);
    if (res.error) {
      throw Exception(res.errorMessageWithoutNull);
    }
    return [
      for (final page in res.data)
        originalQuality
            ? _firstNonEmpty(
                [page.original, page.regular, page.small, page.thumbMini])
            : _firstNonEmpty([page.regular, page.small, page.thumbMini]),
    ];
  }

  /// 档位回退：返回列表中第一个非空串；全为空时返回空串（由调用方决定如何提示）。
  String _firstNonEmpty(List<String> candidates) {
    for (final url in candidates) {
      if (url.isNotEmpty) {
        return url;
      }
    }
    return '';
  }

  /// 缓存键与 ep 无关，仅 id + page（Pixiv 无章节概念）。
  @override
  String buildImageKey(int ep, int page, String url) => '${comic.id}$page';

  /// url 是 [loadEpNetwork] 返回的 CDN 直链，带 Referer 与统一 UA 规避防盗链。
  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) async* {
    final result = await OnlineImageManager.instance.getImage(
      url,
      headers: const {
        'Referer': 'https://www.pixiv.net/',
        'User-Agent': PixivNetwork.pixivWebUA,
      },
    );
    yield* result.stream;
  }
}
