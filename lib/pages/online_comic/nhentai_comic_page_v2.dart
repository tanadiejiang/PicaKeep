import 'package:flutter/material.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/base_online_comic_page.dart';
import 'package:picakeep/pages/online_comic/nhentai_comments_page.dart';
import 'package:picakeep/pages/online_comic/online_comic_page_components.dart';
import 'package:picakeep/pages/online_search/online_search_result_page.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

/// Nhentai 画廊详情页 V2。
///
/// 继承 [BaseOnlineComicPage]<[NhentaiComic]>。与 ehentai 同构（单本无章节，照铁律
/// `extractEpisodes => null`，不铺缩略图网格，直接用基类「阅读」大胶囊）。差异：
/// nhentai 无星级评分（不重写 buildCustomSection）、无 Content Warning。
class NhentaiComicPageV2 extends BaseOnlineComicPage<NhentaiComic> {
  const NhentaiComicPageV2(this.comicId, {super.key});

  final String comicId;

  // ── 标识字段 ────────────────────────────────────────────────────────────

  @override
  String get tag => 'nhentai_$comicId';

  @override
  String get id => comicId;

  @override
  String get sourceKey => 'nhentai';

  @override
  String get source => 'Nhentai';

  // ── 数据加载 ────────────────────────────────────────────────────────────

  @override
  Future<Res<NhentaiComic>> loadData() => NhentaiNetwork().getComicInfo(comicId);

  // ── 数据提取 ────────────────────────────────────────────────────────────

  @override
  String? extractTitle(NhentaiComic data) => data.title;

  @override
  String? extractCover(NhentaiComic data) => data.cover;

  @override
  String? extractSubTitle(NhentaiComic data) =>
      data.subTitle.isEmpty ? null : data.subTitle;

  @override
  Map<String, List<String>>? extractTags(NhentaiComic data) =>
      data.tags.isEmpty ? null : data.tags;

  @override
  int? extractPages(NhentaiComic data) =>
      data.thumbnails.isEmpty ? null : data.thumbnails.length;

  // nhentai 无浏览量/点赞/评论数/章节，简介为空。
  @override
  int? extractViews(NhentaiComic data) => null;
  @override
  int? extractLikes(NhentaiComic data) => null;
  @override
  List<String>? extractEpisodes(NhentaiComic data) => null; // 无章节，铁律
  @override
  String? extractDescription(NhentaiComic data) => null;

  @override
  List<OnlineComicRecommendation>? extractRecommendation(NhentaiComic data) {
    if (data.recommendations.isEmpty) return null;
    return data.recommendations
        .map((c) => OnlineComicRecommendation(
              title: c.title,
              cover: c.cover,
              subTitle: c.lang,
            ))
        .toList();
  }

  // ── 图片鉴权（封面/缩略图带 Referer 规避防盗链）──────────────────────────

  @override
  Map<String, String>? get imageHeaders => const {'Referer': 'https://nhentai.net/'};

  // ── 收藏态初始化（平台 OR 本地）────────────────────────────────────────

  @override
  Future<bool> loadFavoriteState(NhentaiComic data) async {
    if (data.favorite) return true;
    return LocalFavoritesManager().isExist(data.id);
  }

  // ── 标签点击：跳搜索 ─────────────────────────────────────────────────────

  @override
  void onTagTap(BuildContext context, String tag, String category) {
    final src = ComicSource.find('nhentai');
    if (src == null) return;
    // nhentai 搜索语法：含空格的 tag 加双引号；分类前缀用 namespace。
    final needsQuote = tag.contains(' ');
    final quotedTag = needsQuote ? '"$tag"' : tag;
    final keyword = category.isEmpty ? quotedTag : '$category:$quotedTag';
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => OnlineSearchResultPage(
          source: src,
          keyword: keyword,
          option: src.searchPageData?.defaultOption ?? '',
        ),
      ),
    );
  }

  // ── 推荐项点击：跳该画廊详情 ─────────────────────────────────────────────

  @override
  void onRecommendationTap(BuildContext context, NhentaiComic data, int index) {
    if (index < 0 || index >= data.recommendations.length) return;
    final target = data.recommendations[index].id;
    Navigator.of(context).push(
      AppPageRoute(builder: (_) => NhentaiComicPageV2(target)),
    );
  }

  // ── 阅读入口 ────────────────────────────────────────────────────────────

  @override
  Future<void> onRead(BuildContext context, NhentaiComic data,
      {int ep = 1}) async {
    await History.ensureForLocalRead(
      target: data.id,
      type: HistoryType.nhentai,
      title: data.title,
      subtitle: data.subTitle,
      cover: data.cover,
    );
    if (!context.mounted) return;
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => ComicReadingPage(
          NhentaiReadingData(comic: data),
          1,
          ep, // ep=1，NhentaiReadingData.loadEpNetwork 忽略此参数（无章节）
        ),
      ),
    );
  }

  // ── 收藏（平台 toggle + 本地双层）────────────────────────────────────────

  @override
  Future<void> onFavorite(BuildContext context, NhentaiComic data) async {
    final localFav = LocalFavoritesManager().isExist(data.id);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => _NhentaiFavoritePanel(
        platformFavorite: data.favorite,
        localFavorite: localFav,
        loggedIn: ComicSource.find('nhentai')?.isLoggedIn ?? false,
        onPlatformToggle: () async {
          Navigator.of(ctx).pop();
          if (data.token.isEmpty) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('缺少 CSRF token，请下拉刷新后重试')));
            return;
          }
          final wantFav = !data.favorite;
          final res = wantFav
              ? await NhentaiNetwork().favoriteComic(data.id, data.token)
              : await NhentaiNetwork().unfavoriteComic(data.id, data.token);
          if (!context.mounted) return;
          if (res.success) {
            data.favorite = wantFav;
            refreshFavorite(wantFav || localFav);
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(wantFav ? '已收藏' : '已取消收藏')));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('操作失败：${res.errorMessageWithoutNull}')));
          }
        },
        onLocalAdd: () {
          Navigator.of(ctx).pop();
          LocalFavoritesManager().addComic(
            'local',
            FavoriteItem(
              target: data.id,
              name: data.title,
              coverPath: data.cover,
              author: data.subTitle,
              type: FavoriteType.nhentai,
              tags: data.tags.values.expand((l) => l).toList(),
            ),
          );
          refreshFavorite(true);
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('已添加到本地收藏')));
        },
        onLocalRemove: () {
          Navigator.of(ctx).pop();
          LocalFavoritesManager()
              .deleteComicWithTarget('local', data.id, FavoriteType.nhentai);
          refreshFavorite(data.favorite);
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('已取消本地收藏')));
        },
      ),
    );
  }

  // ── 评论按钮（非 null → 基类显示评论图标）───────────────────────────────

  @override
  void Function(BuildContext context, NhentaiComic data)? get onComment =>
      (context, data) => showNhentaiComments(context, data.id);

  @override
  void Function(BuildContext context, NhentaiComic data)? get onLike => null;

  // ── 下载入口 ────────────────────────────────────────────────────────────

  @override
  Future<void> onDownload(BuildContext context, NhentaiComic data) async {
    await OnlineDownloadManager.instance.enqueueNhentai(data);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已加入下载队列')));
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  收藏面板（平台单一 toggle + 本地收藏）
// ═══════════════════════════════════════════════════════════════════════════

class _NhentaiFavoritePanel extends StatelessWidget {
  const _NhentaiFavoritePanel({
    required this.platformFavorite,
    required this.localFavorite,
    required this.loggedIn,
    required this.onPlatformToggle,
    required this.onLocalAdd,
    required this.onLocalRemove,
  });

  final bool platformFavorite;
  final bool localFavorite;
  final bool loggedIn;
  final VoidCallback onPlatformToggle;
  final VoidCallback onLocalAdd;
  final VoidCallback onLocalRemove;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Text('收藏', style: Theme.of(context).textTheme.titleMedium),
          const Divider(),
          // 本地收藏
          ListTile(
            leading: Icon(
              localFavorite ? Icons.bookmark : Icons.bookmark_border,
              color: localFavorite
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            title: Text(localFavorite ? '已本地收藏（点击取消）' : '添加到本地收藏'),
            onTap: localFavorite ? onLocalRemove : onLocalAdd,
          ),
          // 平台收藏（需登录）
          if (loggedIn)
            ListTile(
              leading: Icon(
                platformFavorite ? Icons.favorite : Icons.favorite_border,
                color: platformFavorite
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: Text(platformFavorite ? '取消平台收藏' : '添加到平台收藏'),
              onTap: onPlatformToggle,
            )
          else
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('登录 Nhentai 后可使用平台收藏'),
              enabled: false,
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
