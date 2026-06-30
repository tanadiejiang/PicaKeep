part of pica_reader;

/// ehentai 画廊接入 PicaKeep 源无关通用阅读器 [ComicReadingPage] 的阅读数据。
///
/// 与 picacg/jm 的根本差异：ehentai 没有章节概念，一本画廊就是一组连续页图，
/// 且页图真实 URL 不能直接拼出，必须经 [EhNetwork.getEhImageUrl] 的
/// showKey/mpvKey 状态机向服务器换取本次会话的直链（解密+重试全在网络层）。
class EhReadingData extends ReadingData {
  EhReadingData(this.gallery);

  final Gallery gallery;

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
  String buildImageKey(int ep, int page, String url) => '${gallery.link}$page';

  /// 逐页解密并加载：
  /// 1. [EhNetwork.getEhImageUrl] 解密拿已验证可用直链（page 0-based → 1-based）。
  /// 2. [OnlineImageManager] 带图片鉴权三件套下载字节流。
  /// 状态机内部已重试 4 次；此处兜底捕获最终失败，避免阅读器崩溃。
  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) async* {
    final (imageUrl, _) = await EhNetwork().getEhImageUrl(gallery, page + 1);
    final result = await OnlineImageManager.instance.getImage(
      imageUrl,
      headers: {
        'Cookie': EhNetwork().cookiesStr,
        'User-Agent': EhNetwork.ehUA,
        'Referer': EhNetwork().ehBaseUrl,
      },
    );
    yield* result.stream;
  }
}
