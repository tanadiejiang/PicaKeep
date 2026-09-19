import 'package:flutter/material.dart';
import 'local_favorite_actions.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/components/info_value_action.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/base_online_comic_page.dart';
import 'package:picakeep/pages/online_comic/nhentai_comments_page.dart';
import 'package:picakeep/pages/online_comic/online_comic_page_components.dart';
import 'package:picakeep/pages/online_search/online_search_result_page.dart';
import 'package:picakeep/tools/tags_translation.dart';
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
  Future<Res<NhentaiComic>> loadData() =>
      NhentaiNetwork().getComicInfo(comicId);

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
  Map<String, String>? get imageHeaders =>
      const {'Referer': 'https://nhentai.net/'};

  // ── 收藏态初始化（平台 OR 本地）────────────────────────────────────────

  @override
  Future<bool> loadFavoriteState(NhentaiComic data) async {
    if (data.favorite) return true;
    return isLocalFavoriteTarget(data.id, FavoriteType.nhentai);
  }

  // ── 标签点击：跳搜索 ─────────────────────────────────────────────────────

  @override
  bool get enableTagTranslation => true;

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

  // ── 自定义标签区（ID 置顶 + 页数/时间合并行）─────────────────────────────

  @override
  Widget? buildTagsSectionOverride(
      BuildContext context, NhentaiComic data, Map<String, List<String>> tags) {
    final cs = Theme.of(context).colorScheme;
    final palette = <Color>[
      cs.primaryContainer,
      cs.tertiaryContainer,
      cs.secondaryContainer,
      cs.errorContainer,
      cs.primaryContainer,
    ];
    final onPalette = <Color>[
      cs.onPrimaryContainer,
      cs.onTertiaryContainer,
      cs.onSecondaryContainer,
      cs.onErrorContainer,
      cs.onPrimaryContainer,
    ];

    Widget catChip(String label, int i) => OnlineComicInfoChip(
          label: label,
          color: palette[i % palette.length],
          textColor: onPalette[i % onPalette.length],
        );
    Widget valChip(String v) => OnlineComicInfoChip(
          label: v,
          color: cs.primary.withValues(alpha: 0.10),
          textColor: cs.primary,
        );
    Widget valueAction({
      required String raw,
      required String display,
      String category = '',
    }) {
      final normalized = raw.trim();
      return InfoValueAction(
        data: InfoValueData(
          displayText: display,
          rawSearchValue: normalized,
          rawNamespace: category,
        ),
        onSearch: normalized.isEmpty
            ? null
            : () => onTagTap(context, normalized, category),
        child: valChip(display),
      );
    }

    Widget tagRow(Widget wrap) =>
        Padding(padding: const EdgeInsets.only(bottom: 4), child: wrap);

    // 找时间 key（getComicInfo 里写的是 "时间".tl，中文环境 = "时间"）
    String? timeKey;
    for (final k in tags.keys) {
      if (k == '时间' || k == 'Time') {
        timeKey = k;
        break;
      }
    }

    final rows = <Widget>[];
    int idx = 0;

    // ID 行（置顶）
    rows.add(tagRow(Wrap(spacing: 6, runSpacing: 4, children: [
      catChip('ID', idx),
      valueAction(raw: data.id, display: data.id),
    ])));
    idx++;

    // 普通标签（排除 Pages、时间，其余按顺序正常渲染）
    for (final e in tags.entries) {
      if (e.key == 'Pages' || e.key == timeKey) continue;
      if (e.value.isEmpty) continue;
      rows.add(tagRow(Wrap(spacing: 6, runSpacing: 4, children: [
        catChip(tagTranslateCategory(e.key), idx),
        for (final v in e.value)
          valueAction(
            raw: v,
            display: tagTranslateWithNs(v, e.key),
            category: e.key,
          ),
      ])));
      idx++;
    }

    // 页数 + 时间 合并行（两对 category+value 同一 Wrap）
    final pagesVal = tags['Pages']?.firstOrNull ?? '';
    final timeVal = timeKey != null ? (tags[timeKey]?.firstOrNull ?? '') : '';
    if (pagesVal.isNotEmpty || timeVal.isNotEmpty) {
      rows.add(tagRow(Wrap(spacing: 6, runSpacing: 4, children: [
        if (pagesVal.isNotEmpty) ...[
          catChip('页数', idx),
          valueAction(raw: pagesVal, display: pagesVal),
        ],
        if (timeVal.isNotEmpty) ...[
          catChip(timeKey ?? '时间', idx + 1),
          valueAction(raw: timeVal, display: timeVal),
        ],
      ])));
    }

    if (rows.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
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
    final authors = resolveNhentaiAuthors(data.tags).join(', ');
    await History.ensureForLocalRead(
      target: data.id,
      type: HistoryType.nhentai,
      title: data.title,
      subtitle: authors,
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
    final localItem = FavoriteItem(
      target: data.id, name: data.title, coverPath: data.cover,
      author: resolveNhentaiAuthors(data.tags).join(', '),
      type: FavoriteType.nhentai,
      tags: data.tags.values.expand((tags) => tags).toList(),
    );
    final localFav = isLocallyFavorited(localItem);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => _NhentaiFavoritePanel(
        platformFavorite: data.favorite,
        localFavorite: localFav,
        loggedIn: ComicSource.find('nhentai')?.isLoggedIn ?? false,
        onPlatformToggle: () async {
          Navigator.of(ctx).pop();
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
        onManageLocal: () async {
          Navigator.of(ctx).pop();
          await showLocalFavoriteFoldersWithFeedback(context, localItem);
          if (!context.mounted) return;
          refreshFavorite(data.favorite || isLocallyFavorited(localItem));
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

  // ── 相似搜索（用标题做精确关键词搜索）──────────────────────────────────

  @override
  void Function(BuildContext context, NhentaiComic data)? get onSearchSimilar =>
      (context, data) {
        final source = ComicSource.find(sourceKey);
        if (source == null) return;
        final raw = data.subTitle.isEmpty ? data.title : data.subTitle;
        final keyword =
            '"${raw.replaceAll(RegExp(r'\[.*?\]'), '').replaceAll(RegExp(r'\(.*?\)'), '').trim()}"';
        Navigator.of(context).push(
          AppPageRoute(
            builder: (_) => OnlineSearchResultPage(
              source: source,
              keyword: keyword,
              option: source.searchPageData?.defaultOption ?? '',
            ),
          ),
        );
      };

  // ── 已下载检测（与下载队列 taskId / 本地库 ID 一致）─────────────────────

  @override
  List<String>? downloadCandidateIds(NhentaiComic data) =>
      ['nhentai${data.id}'];
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
    required this.onManageLocal,
  });

  final bool platformFavorite;
  final bool localFavorite;
  final bool loggedIn;
  final VoidCallback onPlatformToggle;
  final VoidCallback onManageLocal;

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
              color:
                  localFavorite ? Theme.of(context).colorScheme.primary : null,
            ),
            title: Text(localFavorite ? '管理本地收藏夹（已收藏）' : '添加到本地收藏'),
            onTap: onManageLocal,
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
