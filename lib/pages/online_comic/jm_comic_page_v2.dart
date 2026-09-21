import 'package:flutter/material.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'local_favorite_actions.dart';
import 'platform_favorite_panel.dart';
import 'package:share_plus/share_plus.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/base_online_comic_page.dart';
import 'package:picakeep/pages/online_comic/jm_comments_page_v2.dart';
import 'package:picakeep/pages/online_comic/online_comic_page_components.dart';
import 'package:picakeep/pages/online_search/online_search_result_page.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

/// JM 详情页（基于 BaseOnlineComicPage）
class JmComicPageV2 extends BaseOnlineComicPage<JmComicInfo> {
  const JmComicPageV2(this.comicId, {super.key});

  final String comicId;

  @override
  String get tag => 'jm_v2_$comicId';

  @override
  String get id => comicId;

  @override
  String get sourceKey => 'jm';

  @override
  String get source => 'JM禁漫天堂';

  @override
  Future<Res<JmComicInfo>> loadData() async {
    return JmNetwork().getComicInfo(comicId);
  }

  // === 数据提取 ===

  @override
  String? extractTitle(JmComicInfo data) => data.title;

  @override
  String? extractCover(JmComicInfo data) => data.coverUrl;

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
  Map<String, List<String>>? extractTags(JmComicInfo data) {
    return {
      'ID': ['JM${data.id}'],
      if (data.authors.isNotEmpty) '作者': data.authors,
      if (data.works.isNotEmpty) '作品': data.works,
      if (data.actors.isNotEmpty) '演员': data.actors.take(30).toList(),
      if (data.tags.isNotEmpty) '标签': data.tags.take(30).toList(),
    };
  }

  @override
  List<String>? extractEpisodes(JmComicInfo data) {
    if (data.series.isEmpty) return null;
    return List.generate(
      data.series.length,
      (i) => i < data.epNames.length ? data.epNames[i] : '第${i + 1}章',
    );
  }

  @override
  List<OnlineComicRecommendation>? extractRecommendation(JmComicInfo data) {
    if (data.relatedComics.isEmpty) return null;
    return data.relatedComics
        .map((comic) => OnlineComicRecommendation(
              title: comic.title,
              cover: comic.coverUrl,
            ))
        .toList();
  }

  // === 图片请求头 ===

  @override
  Map<String, String> get imageHeaders => getJmImgHeaders();

  // === 交互行为 ===

  @override
  void onTagTap(BuildContext context, String tag, String category) {
    final source = ComicSource.find(sourceKey);
    if (source == null) return;

    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => OnlineSearchResultPage(
          source: source,
          keyword: tag,
          option: '',
        ),
      ),
    );
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
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => ComicReadingPage(
          JmReadingData(info: data),
          1,
          ep,
        ),
      ),
    );
  }

  @override
  Future<void> onDownload(BuildContext context, JmComicInfo data) async {
    final res = await OnlineDownloadManager.instance.enqueueJm(data);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(res.error ? res.errorMessageWithoutNull : '已加入下载队列'),
      ),
    );
  }

  @override
  Future<bool?> performCancelPlatformFavorite(JmComicInfo data) async {
    final res = await JmNetwork().setFavorite(data.id, add: false);
    // 成功即"平台已取消"。`data.isFavourite` 是 final 快照改不了，
    // 由基类按"平台已取消"置图标（不重读快照）。
    return res.error ? false : true;
  }

  @override
  Future<void> onFavorite(BuildContext context, JmComicInfo data) async {
    final localItem = FavoriteItem(
      target: data.id, name: data.title, coverPath: data.coverUrl,
      author: data.author, type: FavoriteType.jm, tags: data.tags,
    );
    final wasFavorite = currentFavorite;

    final result = await showPlatformFavoritePanel(
      context,
      sourceTitle: '禁漫',
      localItem: localItem,
      isFavorite: wasFavorite,
      canFavorite: true,
      foldersLoader: () async {
        final res = await JmNetwork().getFolders();
        if (res.error) {
          return const <FavoriteFolderOption>[];
        }
        return [
          // 「默认收藏夹」是页面层拼的（服务端 folder_list 里没有它），
          // 空 id 即默认夹 —— 与原 `_JmFolderSelectDialog` 的取值一致。
          const FavoriteFolderOption(id: '', name: '默认收藏夹'),
          for (final f in res.data)
            FavoriteFolderOption(id: f.id, name: f.name),
        ];
      },
      onSubmitPlatform: ({String? folderId, required bool favorite}) async {
        // 取消平台收藏：整体取消，不涉及夹。
        if (!favorite) {
          final res = await JmNetwork().setFavorite(data.id, add: false);
          if (res.error) {
            return PlatformFavoriteSubmitResult.failed(
                '操作失败: ${res.errorMessageWithoutNull}');
          }
          return const PlatformFavoriteSubmitResult.ok();
        }

        // 收藏：`setFavorite` 是 toggle 端点，网络层内部已做自纠正。
        final res = await JmNetwork().setFavorite(data.id, add: true);
        if (res.error) {
          return PlatformFavoriteSubmitResult.failed(
              '操作失败: ${res.errorMessageWithoutNull}');
        }
        // 非默认夹才需要移动；移动失败不谎报成功（原实现丢弃了返回值）。
        if (folderId != null && folderId.isNotEmpty) {
          final moveRes =
              await JmNetwork().moveFavoriteToFolder(data.id, folderId);
          if (moveRes.error) {
            return const PlatformFavoriteSubmitResult.failed(
                '收藏成功，但移入所选收藏夹失败');
          }
        }
        return const PlatformFavoriteSubmitResult.ok();
      },
    );

    if (!context.mounted || result == null) return;
    switch (result.action) {
      case PlatformFavoriteAction.platformSubmitted:
        final nowFavorite = result.favoriteTarget ?? !wasFavorite;
        refreshFavorite(nowFavorite);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(nowFavorite ? '收藏成功' : '已取消收藏')),
        );
      case PlatformFavoriteAction.localSubmitted:
        final localResult = result.localResult;
        if (localResult != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(localFavoriteSingleMessage(localResult))),
          );
        }
        // 本地收藏不影响平台图标，但图标语义是「平台 OR 本地」，重算一次。
        refreshFavorite(wasFavorite || isLocallyFavorited(localItem));
    }
  }

  @override
  Future<bool> loadFavoriteState(JmComicInfo data) async {
    return data.isFavourite;
  }

  @override
  Future<bool> loadLikeState(JmComicInfo data) async {
    return data.isLiked;
  }

  // === 可选功能 ===

  @override
  void Function(BuildContext context, JmComicInfo data)? get onLike =>
      (context, data) async {
        if (currentLiked) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已经点过赞了')),
          );
          return;
        }

        final res = await JmNetwork().likeComic(data.id);
        if (!context.mounted) return;

        if (res.error) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('点赞失败: ${res.errorMessageWithoutNull}')),
          );
        } else {
          refreshLiked(true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('点赞成功')),
          );
        }
      };

  @override
  void Function(BuildContext context, JmComicInfo data)? get onComment =>
      (context, data) {
        Navigator.of(context).push(
          AppPageRoute(
            builder: (_) => JmCommentsPageV2(
              comicId: data.id,
              totalComments: data.comments,
            ),
          ),
        );
      };

  @override
  void Function(BuildContext context, JmComicInfo data)? get onShare =>
      (context, data) {
        Share.share('${data.title}\nhttps://18comic.vip/album/${data.id}');
      };

  @override
  void onRecommendationTap(BuildContext context, JmComicInfo data, int index) {
    if (data.relatedComics.isEmpty || index >= data.relatedComics.length) {
      return;
    }

    final item = data.relatedComics[index];
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => JmComicPageV2(item.id),
      ),
    );
  }

  // ── 相似搜索（jm 无 subTitle，始终用 title）────────────────────────────

  @override
  void Function(BuildContext context, JmComicInfo data)? get onSearchSimilar =>
      (context, data) {
        final source = ComicSource.find(sourceKey);
        if (source == null) return;
        final keyword =
            '"${data.title.replaceAll(RegExp(r'\[.*?\]'), '').replaceAll(RegExp(r'\(.*?\)'), '').trim()}"';
        Navigator.of(context).push(
          AppPageRoute(
            builder: (_) => OnlineSearchResultPage(
              source: source,
              keyword: keyword,
              option: '',
            ),
          ),
        );
      };

  // ── 已下载检测（与下载队列 taskId / 本地库 ID 一致）─────────────────────

  @override
  List<String>? downloadCandidateIds(JmComicInfo data) => ['jm${data.id}'];
}
