import 'package:flutter/material.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'local_favorite_actions.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/base_online_comic_page.dart';
import 'package:picakeep/pages/online_comic/picacg_comments_page_v2.dart';
import 'package:picakeep/pages/online_comic/online_comic_page_components.dart';
import 'package:picakeep/pages/online_search/online_search_result_page.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

/// picacg 详情页（基于 BaseOnlineComicPage）
class PicacgComicPageV2 extends BaseOnlineComicPage<PicacgComicItem> {
  const PicacgComicPageV2(this.comicId, {super.key});

  final String comicId;

  @override
  String get tag => 'picacg_$comicId';

  @override
  String get id => comicId;

  @override
  String get sourceKey => 'picacg';

  @override
  String get source => 'picacg';

  @override
  Future<Res<PicacgComicItem>> loadData() async {
    return PicacgNetwork().getComicInfo(comicId);
  }

  // === 数据提取 ===

  @override
  String? extractTitle(PicacgComicItem data) => data.title;

  @override
  String? extractCover(PicacgComicItem data) => data.cover;

  @override
  String? extractSubTitle(PicacgComicItem data) => data.author;

  @override
  String? extractDescription(PicacgComicItem data) => data.description;

  @override
  int? extractPages(PicacgComicItem data) => data.pagesCount;

  @override
  int? extractLikes(PicacgComicItem data) => data.likes;

  @override
  int? extractComments(PicacgComicItem data) => data.comments;

  @override
  Map<String, List<String>>? extractTags(PicacgComicItem data) {
    return {
      'ID': [data.id],
      '作者': [data.author],
      if (data.chineseTeam.isNotEmpty) '汉化组': [data.chineseTeam],
      if (data.categories.isNotEmpty) '分类': data.categories,
      if (data.tags.isNotEmpty) '标签': data.tags.take(30).toList(),
    };
  }

  @override
  List<String>? extractEpisodes(PicacgComicItem data) =>
      data.eps.isEmpty ? null : data.eps;

  @override
  List<OnlineComicRecommendation>? extractRecommendation(PicacgComicItem data) {
    if (data.recommendation.isEmpty) return null;
    return data.recommendation
        .map((item) => OnlineComicRecommendation(
              title: item.title,
              cover: item.cover,
            ))
        .toList();
  }

  // === 图片请求头 ===

  @override
  Map<String, String>? get imageHeaders => null;

  // === 收藏 / 点赞态加载 ===

  @override
  Future<bool> loadFavoriteState(PicacgComicItem data) async =>
      data.isFavourite;

  @override
  Future<bool> loadLikeState(PicacgComicItem data) async => data.isLiked;

  // === 自定义区块：创建者卡片 ===

  @override
  Widget? buildCustomSection(BuildContext context, PicacgComicItem data) {
    final creator = data.creator;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: colorScheme.surfaceContainerHighest,
          backgroundImage: creator.avatarUrl.isEmpty
              ? null
              : NetworkImage(creator.avatarUrl),
          child: creator.avatarUrl.isEmpty
              ? const Icon(Icons.person_outline, size: 20)
              : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                creator.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium,
              ),
              const SizedBox(height: 2),
              Text(
                'Lv.${creator.level}',
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }

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
  Future<void> onRead(BuildContext context, PicacgComicItem data,
      {int ep = 1}) async {
    await History.ensureForLocalRead(
      target: data.id,
      type: HistoryType.picacg,
      title: data.title,
      subtitle: data.subTitle,
      cover: data.cover,
      ep: ep,
    );
    if (!context.mounted) return;
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => ComicReadingPage(
          PicacgReadingData(comic: data),
          1,
          ep,
        ),
      ),
    );
  }

  @override
  Future<void> onDownload(BuildContext context, PicacgComicItem data) async {
    final res = await OnlineDownloadManager.instance.enqueuePicacg(data);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(res.error ? res.errorMessageWithoutNull : '已加入下载队列'),
      ),
    );
  }

  @override
  Future<void> onFavorite(BuildContext context, PicacgComicItem data) async {
    if (!await choosePlatformFavorite(context, FavoriteItem(
      target: data.id, name: data.title, coverPath: data.cover,
      author: data.author, type: FavoriteType.picacg, tags: data.tags,
    ))) {
      return;
    }
    // 基于当前真实收藏态 toggle（picacg 收藏接口本身就是 toggle）。
    final adding = !currentFavorite;
    final res = await PicacgNetwork().favouriteOrUnfavouriteComic(data.id);
    if (!context.mounted) return;
    if (res.error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('操作失败: ${res.errorMessageWithoutNull}')),
      );
    } else {
      refreshFavorite(adding);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(adding ? '收藏成功' : '已取消收藏')),
      );
    }
  }

  // === 可选功能 ===

  @override
  void Function(BuildContext context, PicacgComicItem data)? get onLike =>
      (context, data) async {
        // picacg 点赞接口为 toggle，取消点赞调用同一接口。
        final liking = !currentLiked;
        final res = await PicacgNetwork().likeOrUnlikeComic(data.id);
        if (!context.mounted) return;
        if (res.error) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('操作失败: ${res.errorMessageWithoutNull}')),
          );
        } else {
          refreshLiked(liking);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(liking ? '已点赞' : '已取消点赞')),
          );
        }
      };

  @override
  void Function(BuildContext context, PicacgComicItem data)? get onComment =>
      (context, data) {
        Navigator.of(context).push(
          AppPageRoute(
            builder: (_) => PicacgCommentsPageV2(
              comicId: data.id,
              totalComments: data.comments,
            ),
          ),
        );
      };

  @override
  void onRecommendationTap(
      BuildContext context, PicacgComicItem data, int index) {
    if (data.recommendation.isEmpty || index >= data.recommendation.length) {
      return;
    }
    final item = data.recommendation[index];
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => PicacgComicPageV2(item.id),
      ),
    );
  }
}
