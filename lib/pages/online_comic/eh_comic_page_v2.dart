// ignore_for_file: use_build_context_synchronously
// loadData() 内使用 App.globalContext 弹 Content Warning 对话框，
// 这是全局引用（不依赖 widget 生命周期），suppression 是合理的。
import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/eh_network/get_gallery_id.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/base_online_comic_page.dart';
import 'package:picakeep/pages/online_comic/eh_comments_page.dart';
import 'package:picakeep/pages/online_comic/online_comic_page_components.dart';
import 'package:picakeep/pages/online_search/online_search_result_page.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

/// E-Hentai / ExHentai 画廊详情页 V2。
///
/// 继承 [BaseOnlineComicPage]<[Gallery]>，对接 PicaKeep 通用详情页基类的所有槽位：
/// 封面（带鉴权三件套 header）/ 标签分组（按 namespace）/ 页数 / 星级评分区 /
/// 平台+本地双层收藏 / 评论入口 / 阅读入口 / 下载入口（07 占位）/ Content Warning 拦截。
class EhentaiComicPageV2 extends BaseOnlineComicPage<Gallery> {
  const EhentaiComicPageV2(this.link, {super.key});

  final String link;

  // ── 基类必须实现的标识字段 ─────────────────────────────────────────────────

  @override
  String get tag => 'ehentai_$link'; // 公共契约：详情页唯一标识

  @override
  String get id => link; // 画廊完整 URL 即唯一标识

  @override
  String get sourceKey => 'ehentai';

  @override
  String get source => 'E-Hentai';

  // ── 数据加载（含 Content Warning 二次确认）───────────────────────────────────

  @override
  Future<Res<Gallery>> loadData() async {
    var res = await EhNetwork().getGalleryInfo(link);
    // Content Warning 命中时弹二次确认，确认后带绕过参数重试
    if (res.error && (res.errorMessage ?? '').contains('Content Warning')) {
      final ctx = App.globalContext;
      if (ctx != null) {
        final confirmed = await showDialog<bool>(
          context: ctx,
          builder: (_) => AlertDialog(
            title: const Text('内容警告'),
            content: const Text(
              '该画廊标记了成人内容警告。确认继续查看吗？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('继续'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          return EhNetwork().getGalleryInfo(link, false);
        }
      }
    }
    return res;
  }

  // ── 数据提取方法 ──────────────────────────────────────────────────────────

  @override
  String? extractTitle(Gallery data) {
    // settings[78]=='1' 时优先显示日文原标题（subTitle）
    if (appdata.settings[78] == '1') {
      return data.subTitle?.isNotEmpty == true ? data.subTitle : data.title;
    }
    return data.title;
  }

  @override
  String? extractCover(Gallery data) {
    // 封面域名替换：s.exhentai.org → ehgt.org（公共契约）
    return data.coverPath.replaceFirst('s.exhentai.org', 'ehgt.org');
  }

  @override
  Map<String, List<String>>? extractTags(Gallery data) {
    return data.tags.isEmpty ? null : data.tags;
  }

  @override
  String? extractSubTitle(Gallery data) => data.subTitle;

  @override
  int? extractPages(Gallery data) => int.tryParse(data.maxPage);

  @override
  int? extractComments(Gallery data) => data.comments.length;

  // ehentai 无浏览量、无点赞数（星级走自定义区块）、无章节、无推荐、简介通常为空
  @override
  int? extractViews(Gallery data) => null;
  @override
  int? extractLikes(Gallery data) => null;
  @override
  List<String>? extractEpisodes(Gallery data) => null; // 无章节，铁律
  @override
  List<OnlineComicRecommendation>? extractRecommendation(Gallery data) => null;
  @override
  String? extractDescription(Gallery data) => null;

  // ── 图片鉴权三件套（封面/缩略图必须带，否则裂图）────────────────────────────

  @override
  Map<String, String>? get imageHeaders => {
        'Cookie': EhNetwork().cookiesStr,
        'User-Agent': EhNetwork.ehUA,
        'Referer': EhNetwork().ehBaseUrl,
      };

  // ── 收藏状态初始化（平台 OR 本地）────────────────────────────────────────

  @override
  Future<bool> loadFavoriteState(Gallery data) async {
    if (data.favorite) return true;
    // 检查本地收藏
    return LocalFavoritesManager().isExist(data.link);
  }

  // ── 标签点击：还原 namespace 并跳搜索 ─────────────────────────────────────
  // category 参数由 OnlineComicTagsSection 传来，已是 namespace 键

  @override
  bool get enableTagTranslation => true;

  @override
  void onTagTap(BuildContext context, String tag, String category) {
    final source = ComicSource.find('ehentai');
    if (source == null) return;

    // 含空格的 tag value 加英文双引号；uploader namespace 特判
    final needsQuote = tag.contains(' ');
    final quotedTag = needsQuote ? '"$tag"' : tag;
    final keyword = category.isEmpty
        ? quotedTag
        : '$category:$quotedTag';

    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => OnlineSearchResultPage(
          source: source,
          keyword: keyword,
          option: source.searchPageData?.defaultOption ?? '',
        ),
      ),
    );
  }

  // ── 阅读入口（照公共契约范式）────────────────────────────────────────────

  @override
  Future<void> onRead(BuildContext context, Gallery data, {int ep = 1}) async {
    await History.ensureForLocalRead(
      target: data.link,
      type: HistoryType.ehentai,
      title: data.title,
      subtitle: data.uploader,
      cover: extractCover(data) ?? data.coverPath,
    );
    if (!context.mounted) return;
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => ComicReadingPage(
          EhReadingData(data),
          1,
          ep, // ep=1，EhReadingData.loadEpNetwork 忽略此参数（无章节）
        ),
      ),
    );
  }

  // ── 收藏（平台 + 本地双层）────────────────────────────────────────────────

  @override
  Future<void> onFavorite(BuildContext context, Gallery data) async {
    final auth = data.auth ?? {};
    final gid = auth['gid'] ?? '';
    final token = auth['token'] ?? '';

    final platformFav = data.favorite;
    final localFav = LocalFavoritesManager().isExist(data.link);

    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => _EhFavoritePanel(
        platformFavorite: platformFav,
        localFavorite: localFav,
        folderNames: EhNetwork().folderNames,
        onPlatformAdd: (folderIndex) async {
          Navigator.of(ctx).pop();
          final res = await EhNetwork()
              .favorite(gid, token, id: folderIndex.toString());
          if (!context.mounted) return;
          if (res) {
            refreshFavorite(true);
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已添加到平台收藏夹')));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('平台收藏失败')));
          }
        },
        onPlatformRemove: () async {
          Navigator.of(ctx).pop();
          final res = await EhNetwork().unfavorite(gid, token);
          if (!context.mounted) return;
          if (res) {
            refreshFavorite(localFav); // 本地收藏可能仍存在
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已取消平台收藏')));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('取消平台收藏失败')));
          }
        },
        onLocalAdd: () {
          Navigator.of(ctx).pop();
          LocalFavoritesManager().addComic(
            'local',
            FavoriteItem(
              target: data.link,
              name: data.title,
              coverPath: extractCover(data) ?? data.coverPath,
              author: data.uploader,
              type: FavoriteType.ehentai,
              tags: data.tags.values.expand((l) => l).toList(),
            ),
          );
          refreshFavorite(true);
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('已添加到本地收藏')));
        },
        onLocalRemove: () {
          Navigator.of(ctx).pop();
          LocalFavoritesManager().deleteComicWithTarget(
              'local', data.link, FavoriteType.ehentai);
          refreshFavorite(platformFav); // 平台收藏态保持
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('已取消本地收藏')));
        },
      ),
    );
  }

  // ── 评论按钮（非 null → 基类显示评论图标）───────────────────────────────

  @override
  void Function(BuildContext context, Gallery data)? get onComment =>
      (context, data) => showEhComments(context, link, data.uploader, data.auth ?? {});

  @override
  void Function(BuildContext context, Gallery data)? get onLike => null; // 星级评分在自定义区块，不占点赞槽

  // ── 下载入口 ────────────────────────────────────────────────────────────

  @override
  Future<void> onDownload(BuildContext context, Gallery data) async {
    final hasArchive =
        data.auth != null && (data.auth!['archiveDownload'] ?? '').isNotEmpty;

    var current = 0;
    var loading = hasArchive;
    ArchiveDownloadInfo? info;

    Future<void> startDownload(int type) async {
      final taskId = getGalleryId(data.link);
      if (OnlineDownloadManager.instance.isDownloading(taskId)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已在下载中')));
        return;
      }
      await OnlineDownloadManager.instance.enqueueEhentai(data, type);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已加入下载队列')));
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          // 归档信息懒加载
          if (hasArchive && loading && info == null) {
            EhNetwork()
                .getArchiveDownloadInfo(data.auth!['archiveDownload']!)
                .then((res) {
              if (!ctx.mounted) return;
              setS(() {
                loading = false;
                if (!res.error) info = res.data;
              });
            });
          }

          Future<void> cancelUnlockAndReload() async {
            if (info?.cancelUnlockUrl == null) return;
            setS(() => loading = true);
            final res = await EhNetwork().cancelAndReloadArchiveInfo(info!);
            if (!ctx.mounted) return;
            setS(() {
              loading = false;
              if (!res.error) info = res.data;
            });
          }

          return AlertDialog(
            title: const Text('下载选项'),
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            content: SizedBox(
              width: double.maxFinite,
              child: RadioGroup<int>(
                groupValue: current,
                onChanged: (v) => setS(() => current = v!),
                child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const RadioListTile<int>(
                    value: 0,
                    title: Text('普通下载'),
                    subtitle: Text('逐页下载，支持断点续传'),
                  ),
                  if (hasArchive)
                    ExpansionTile(
                      title: const Text('归档下载'),
                      children: [
                        if (loading)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: CircularProgressIndicator(),
                          )
                        else if (info == null)
                          const ListTile(
                            title: Text('归档信息加载失败'),
                            subtitle: Text('请重试'),
                          )
                        else ...[
                          RadioListTile<int>(
                            value: 1,
                            title: const Text('Original'),
                            subtitle: Text(
                                '${info!.originCost}  ${info!.originSize}'),
                          ),
                          RadioListTile<int>(
                            value: 2,
                            title: const Text('Resample'),
                            subtitle: Text(
                                '${info!.resampleCost}  ${info!.resampleSize}'),
                          ),
                          if (info!.cancelUnlockUrl != null)
                            ListTile(
                              title: const Text('取消解锁'),
                              subtitle: const Text('长按执行此操作'),
                              onLongPress: cancelUnlockAndReload,
                            ),
                        ],
                      ],
                    ),
                ],
              ),
            ),
          ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  startDownload(current);
                },
                child: const Text('确认'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── 自定义区块：星级评分 ─────────────────────────────────────────────────

  @override
  Widget? buildCustomSection(BuildContext context, Gallery data) {
    return _EhRatingSection(
      gallery: data,
      auth: data.auth ?? {},
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  星级评分区块
// ═══════════════════════════════════════════════════════════════════════════

class _EhRatingSection extends StatefulWidget {
  const _EhRatingSection({required this.gallery, required this.auth});

  final Gallery gallery;
  final Map<String, String> auth;

  @override
  State<_EhRatingSection> createState() => _EhRatingSectionState();
}

class _EhRatingSectionState extends State<_EhRatingSection> {
  late double _stars;
  bool _rating = false;

  @override
  void initState() {
    super.initState();
    _stars = widget.gallery.stars;
  }

  @override
  void didUpdateWidget(_EhRatingSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gallery.stars != widget.gallery.stars) {
      _stars = widget.gallery.stars;
    }
  }

  Future<void> _rate(int score) async {
    if (_rating) return;
    setState(() => _rating = true);
    final ok = await EhNetwork().rateGallery(widget.auth, score);
    if (!mounted) return;
    if (ok) {
      setState(() => _stars = score.toDouble());
    }
    setState(() => _rating = false);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // 5 星图标，点击评分（1-5 整星）
          for (var i = 1; i <= 5; i++)
            GestureDetector(
              onTap: _rating ? null : () => _rate(i),
              child: Icon(
                i <= _stars.round()
                    ? Icons.star_rounded
                    : (i - 0.5 <= _stars
                        ? Icons.star_half_rounded
                        : Icons.star_border_rounded),
                color: colorScheme.tertiary,
                size: 28,
              ),
            ),
          const SizedBox(width: 8),
          if (widget.gallery.rating != null)
            Text(
              widget.gallery.rating!,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          if (_rating) ...[
            const SizedBox(width: 8),
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  收藏面板（平台收藏夹 0-9 + 本地收藏）
// ═══════════════════════════════════════════════════════════════════════════

class _EhFavoritePanel extends StatelessWidget {
  const _EhFavoritePanel({
    required this.platformFavorite,
    required this.localFavorite,
    required this.folderNames,
    required this.onPlatformAdd,
    required this.onPlatformRemove,
    required this.onLocalAdd,
    required this.onLocalRemove,
  });

  final bool platformFavorite;
  final bool localFavorite;
  final List<String> folderNames;
  final void Function(int folderIndex) onPlatformAdd;
  final VoidCallback onPlatformRemove;
  final VoidCallback onLocalAdd;
  final VoidCallback onLocalRemove;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, controller) => Column(
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
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
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
                const Divider(),
                // 平台收藏夹
                if (platformFavorite)
                  ListTile(
                    leading: const Icon(Icons.star_border),
                    title: const Text('取消平台收藏'),
                    onTap: onPlatformRemove,
                  )
                else
                  for (var i = 0; i < folderNames.length; i++)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text('平台收藏夹 $i: ${folderNames[i]}'),
                      onTap: () => onPlatformAdd(i),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
