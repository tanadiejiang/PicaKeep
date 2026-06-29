import 'package:flutter/material.dart';

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_search/online_search_result_page.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

import 'base_online_comic_page.dart';

/// 示例：用 [BaseOnlineComicPage] 接入一个源站需要写的全部代码。
///
/// 这里用项目里真实存在的 JM 模型/网络层演示，因此本文件可直接编译。
/// 它仅作为接入参考，**未接入应用路由**，不替代现有的 `JmComicDetailPage`。
///
/// 对照 `docs/新增在线源站接入指南.md` 阅读。
class ExampleSourcePage extends BaseOnlineComicPage<JmComicInfo> {
  const ExampleSourcePage(this.comicId, {super.key});

  final String comicId;

  // ===== 强制：数据加载 =====

  @override
  String get tag => 'example_$comicId';

  @override
  Future<Res<JmComicInfo>> loadData() => JmNetwork().getComicInfo(comicId);

  // ===== 强制：基础信息 =====

  @override
  String get id => comicId;

  @override
  String get sourceKey => 'jm';

  @override
  String get source => '示例源站';

  @override
  String? extractTitle(JmComicInfo data) => data.title;

  @override
  String? extractCover(JmComicInfo data) => data.coverUrl;

  @override
  Map<String, List<String>>? extractTags(JmComicInfo data) => {
        if (data.authors.isNotEmpty) '作者': data.authors,
        if (data.works.isNotEmpty) '作品': data.works,
        if (data.actors.isNotEmpty) '演员': data.actors,
        if (data.tags.isNotEmpty) '标签': data.tags,
      };

  // ===== 强制：交互 =====

  @override
  void onTagTap(BuildContext context, String tag, String category) {
    final source = ComicSource.find(sourceKey);
    if (source == null) return;
    Navigator.of(context).push(AppPageRoute(
      builder: (_) => OnlineSearchResultPage(
        source: source,
        keyword: tag,
        option: '',
      ),
    ));
  }

  @override
  Future<void> onRead(BuildContext context, JmComicInfo data,
      {int ep = 1}) async {
    await History.ensureForLocalRead(
      target: data.id,
      type: HistoryType.jmComic,
      title: data.title,
      subtitle: data.author,
      cover: data.coverUrl,
      ep: ep,
    );
    if (!context.mounted) return;
    Navigator.of(context).push(AppPageRoute(
      builder: (_) => ComicReadingPage(JmReadingData(info: data), 1, ep),
    ));
  }

  @override
  Future<void> onDownload(BuildContext context, JmComicInfo data) async {
    final res = await OnlineDownloadManager.instance.enqueueJm(data);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res.error ? res.errorMessageWithoutNull : '已加入下载队列'),
    ));
  }

  @override
  Future<void> onFavorite(BuildContext context, JmComicInfo data) async {
    final res = await JmNetwork().setFavorite(data.id, add: !data.isFavourite);
    if (!context.mounted) return;
    if (!res.error) refreshFavorite(!data.isFavourite);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res.error ? res.errorMessageWithoutNull : '操作完成'),
    ));
  }

  @override
  Future<bool> loadFavoriteState(JmComicInfo data) async => data.isFavourite;

  // ===== 可选：附加信息 =====

  @override
  String? extractSubTitle(JmComicInfo data) => data.author;

  @override
  String? extractDescription(JmComicInfo data) => data.description;

  @override
  int? extractViews(JmComicInfo data) => data.views;

  @override
  int? extractLikes(JmComicInfo data) => data.likes;

  @override
  int? extractComments(JmComicInfo data) => data.comments;

  @override
  List<String>? extractEpisodes(JmComicInfo data) => data.epNames;

  // ===== 可选：附加交互 =====

  @override
  Map<String, String>? get imageHeaders => getJmImgHeaders();
}
