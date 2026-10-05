import 'dart:async';
import 'package:picakeep/pages/pixiv_folders_page.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/state_controller.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/base_online_comic_page.dart';
import 'package:picakeep/pages/online_comic/online_comic_page_components.dart';
import 'package:picakeep/pages/online_comic/online_comic_page_logic.dart';
import 'package:picakeep/pages/online_comic/pixiv_author_link.dart';
import 'package:picakeep/pages/online_search/online_search_result_page.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';
import 'pixiv_online_detail_view.dart';

/// Pixiv 作品详情页 V2。
///
/// 与 nhentai 同构：**单本无章节**（一本作品就是一组连续页图，没有目录结构），
/// 因此照铁律 `extractEpisodes => null`，章节区自动隐藏，直接用基类的「阅读」
/// 大胶囊进 [ComicReadingPage]，[PixivReadingData] 内部按 `ep` 忽略章节参数。
///
/// 唯一的增量是「作品页面预览」区块：EH/NH 那种逐页缩略图预览。Pixiv 的
/// `/ajax/illust/{id}/pages` 会一次性下发全部页的多档 URL，天然适合铺网格。
///
/// 该区块通过基类的 [buildSectionAfterDescription] 钩子插入（**插槽在简介之后**），
/// 缩略图墙的排版对齐原项目 `comic_page.dart` 的 `buildThumbnails`。源站私有 UI
/// 走基类的可选钩子扩展，不反过来侵入公共骨架的顺序与分支。
class PixivComicPageV2 extends BaseOnlineComicPage<PixivComicInfo> {
  const PixivComicPageV2(this.comicId, {super.key});

  final String comicId;

  @override
  Widget build(BuildContext context) {
    // Keep the base-page contract for test/support subclasses that override the
    // legacy section hooks. Production routes instantiate this exact class and
    // use the new Pixiv drawer shell below.
    if (runtimeType != PixivComicPageV2) return super.build(context);
    return PixivOnlineDetailView(
      comicId: comicId,
      loadDetail: loadData,
      loadPages: loadImagePages,
      writeBookmark: (id, {required isAdding, required isPrivate}) => isPrivate
          ? writePrivateBookmark(id, isAdding: isAdding)
          : writeBookmark(id, isAdding: isAdding),
      onRead: (context, data, page) => onRead(context, data, initialPage: page),
      onDownload: onDownload,
      onDownloadLongPress: onDownloadLongPress,
      onTagTap: onTagTap,
    );
  }

  Future<Res<List<PixivPage>>> loadImagePages(String id) =>
      PixivNetwork().getComicPages(id);

  @protected
  Future<Res<bool>> writePrivateBookmark(String id, {required bool isAdding}) =>
      PixivNetwork().setBookmark(id,
          isAdding: isAdding, visibility: PixivBookmarkVisibility.private);

  // ── 标识字段 ────────────────────────────────────────────────────────────

  /// 带上 `pixiv_` 前缀 + 作品 id：同时打开多个 Pixiv 详情页时状态层必须互不串台。
  @override
  String get tag => 'pixiv_$comicId';

  @override
  String get id => comicId;

  @override
  String get sourceKey => 'pixiv';

  @override
  String get source => 'Pixiv';

  // ── 数据加载 ────────────────────────────────────────────────────────────

  @override
  Future<Res<PixivComicInfo>> loadData() =>
      PixivNetwork().getComicInfo(comicId);

  // ── 数据提取 ────────────────────────────────────────────────────────────

  @override
  String? extractTitle(PixivComicInfo data) => data.title;

  @override
  String? extractCover(PixivComicInfo data) => data.coverUrl;

  @override
  String? extractSubTitle(PixivComicInfo data) =>
      data.author.isEmpty ? null : data.author;

  @override
  String? extractDescription(PixivComicInfo data) =>
      data.description.isEmpty ? null : data.description;

  @override
  int? extractPages(PixivComicInfo data) => data.pageCount;

  @override
  int? extractViews(PixivComicInfo data) => data.viewCount;

  @override
  int? extractLikes(PixivComicInfo data) => data.likeCount;

  /// 作品 ID、作者与标签分桶；任一类为空就不放该键（对应行自动消失）。
  ///
  /// `ID` 放最前（与 JM 的 `'ID': ['JM${id}']` 同范式）：详情页需要能一眼看到并用
  /// 于跨设备定位作品。这里**只放裸数字 ID**，不拼 `pixiv` 前缀——信息区上方已
  /// 有源标识行显示「Pixiv」，再加前缀是冗余。
  @override
  Map<String, List<String>>? extractTags(PixivComicInfo data) {
    final result = <String, List<String>>{};
    if (data.id.isNotEmpty) {
      result['ID'] = <String>[data.id];
    }
    if (data.author.isNotEmpty) {
      result['作者'] = <String>[data.author];
    }
    if (data.tags.isNotEmpty) {
      result['标签'] = data.tags;
    }
    return result.isEmpty ? null : result;
  }

  /// 本轮不接推荐接口（Pixiv 的"相关作品"要另开接口），返回 null 隐藏推荐区。
  @override
  List<OnlineComicRecommendation>? extractRecommendation(
    PixivComicInfo data,
  ) =>
      null;

  /// 无章节：单作品多图。基类据此隐藏章节区，也不会渲染章节长按。
  @override
  List<String>? extractEpisodes(PixivComicInfo data) => null;

  // ── 图片鉴权 ────────────────────────────────────────────────────────────

  /// `i.pximg.net` 有严格防盗链：缺 Referer 会 403，UA 也必须与抓 session 时
  /// 一致（Pixiv 会把 UA/Referer 组合不一致判成风控）。
  @override
  Map<String, String>? get imageHeaders => const {
        'Referer': 'https://www.pixiv.net/',
        'User-Agent': PixivNetwork.pixivWebUA,
      };

  // ── 标签点击：ID 复制 / 其余跳该源搜索 ──────────────────────────────────

  /// Pixiv 没有 NH 那种 `namespace:tag` 语法，"作者"分类按作者名直接搜标签即可。
  /// 分类前缀不拼进关键词，避免构造出 Pixiv 不认识的查询串。
  ///
  /// **`ID` 分类例外：点击 = 复制，不跳搜索**。理由：Pixiv 作品 ID 是纯数字，
  /// 当关键词去搜只会得到无关结果；用户点它的真实意图是"复制 ID 去别处用"。
  /// 这与 JM 旧详情页 `jm_comic_detail_page.dart` 对 ID 行隐藏「搜索」项同一口径。
  @override
  void onTagTap(BuildContext context, String tag, String category) {
    final keyword = tag.trim();
    if (keyword.isEmpty) return;

    if (category == 'ID') {
      // 复制是先于反馈的：await 完成后再提示，避免"提示了却没复制上"。
      unawaited(
        Clipboard.setData(ClipboardData(text: keyword)).then((_) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已复制 ID'),
              duration: Duration(seconds: 1),
            ),
          );
        }),
      );
      return;
    }

    final src = ComicSource.find(sourceKey);
    if (src == null) return;
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

  // ── 阅读入口 ────────────────────────────────────────────────────────────

  /// 单本无章节：`ep` 由基类传 1，[PixivReadingData] 内部忽略它并一次拉全部页。
  @override
  Future<void> onRead(BuildContext context, PixivComicInfo data,
      {int ep = 1, int initialPage = 1}) async {
    await History.ensureForLocalRead(
      target: data.id,
      type: HistoryType.pixiv,
      title: data.title,
      subtitle: data.author,
      cover: data.coverUrl,
      ep: ep,
    );
    if (!context.mounted) return;
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => ComicReadingPage(
          PixivReadingData(comic: data),
          initialPage,
          ep,
        ),
      ),
    );
  }

  // ── 下载入口 ────────────────────────────────────────────────────────────

  /// 加入在线下载队列（单本多图、无章节）。
  ///
  /// 下载取下 `regular` 档（见 `_runPixivTask`），不从 `original` 拉：
  /// 原图单页可达数十 MB，整套下载体积会成倍放大。
  /// 详情页打开失败前的空作品在这里先拦一道，避免入队后才失败。
  @override
  bool get supportsDownloadFolders => true;
  @override
  Future<void> onDownloadLongPress(BuildContext context, PixivComicInfo data) =>
      downloadPixivToFolder(context, data, choose: true);
  @override
  Future<void> onDownload(BuildContext context, PixivComicInfo data) =>
      downloadPixivToFolder(context, data, choose: false);

  // ── 收藏（平台书签 toggle）──────────────────────────────────────────────

  /// Pixiv 书签是"翻转"语义接口，但 [PixivNetwork.setBookmark] 用 `isAdding`
  /// 显式表达目标态；这里以 [currentFavorite]（而非 data 的静态快照）为基准，
  /// 保证连点两次后图标与实际平台状态一致。
  ///
  /// 忙锁挂在本页状态实例上，点击与长按取消共用，重建 widget 不会解锁。
  static final _bookmarkBusy = Expando<bool>('Pixiv bookmark action');

  OnlineComicPageLogic<PixivComicInfo>? get _favoriteLogic =>
      StateController.findOrNull<OnlineComicPageLogic<PixivComicInfo>>(
          tag: tag);

  bool _hasCurrentData(
    OnlineComicPageLogic<PixivComicInfo> logic,
    PixivComicInfo data,
  ) =>
      identical(_favoriteLogic, logic) && identical(logic.data, data);

  Future<R> _withBookmarkLock<R>(
    R busyResult,
    Future<R> Function(OnlineComicPageLogic<PixivComicInfo>) action,
  ) async {
    final logic = _favoriteLogic;
    if (logic == null || _bookmarkBusy[logic] == true) return busyResult;
    _bookmarkBusy[logic] = true;
    logic.setFavoriteBusy(true);
    try {
      return await action(logic);
    } finally {
      _bookmarkBusy[logic] = false;
      logic.setFavoriteBusy(false);
    }
  }

  /// 测试可覆盖这一请求边界，状态流程仍执行本页真实实现。
  @protected
  Future<Res<bool>> writeBookmark(String id, {required bool isAdding}) =>
      PixivNetwork().setBookmark(id, isAdding: isAdding);

  void _showBookmarkMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Future<void> onFavorite(BuildContext context, PixivComicInfo data) async {
    await _withBookmarkLock(false, (logic) async {
      final target = !logic.favorite;
      final res = await writeBookmark(data.id, isAdding: target);
      if (!context.mounted || !_hasCurrentData(logic, data)) return false;
      if (res.error) {
        _showBookmarkMessage(context, '操作失败：${res.errorMessageWithoutNull}');
        return false;
      }
      logic.setFavorite(target);
      _showBookmarkMessage(context, target ? '已收藏' : '已取消收藏');
      return true;
    });
  }

  /// 取消网络收藏（基类长按「收藏」按钮走这里）。
  ///
  /// 返回 `true` 表示平台侧已确定无收藏；失败保留确认前状态。
  @override
  Future<bool?> performCancelPlatformFavorite(PixivComicInfo data) =>
      _withBookmarkLock(false, (logic) async {
        final res = await writeBookmark(data.id, isAdding: false);
        return _hasCurrentData(logic, data) && res.success;
      });

  @override
  void Function(BuildContext, PixivComicInfo, bool)?
      get onCancelPlatformFavorite => _confirmAndCancelBookmark;

  Future<void> _confirmAndCancelBookmark(
    BuildContext context,
    PixivComicInfo data,
    bool wasFavorite,
  ) async {
    await _withBookmarkLock(false, (logic) async {
      if (!logic.favorite) {
        _showBookmarkMessage(context, '当前未收藏，无需取消');
        return false;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('取消网络收藏'),
          content: const Text('确定取消这本作品的 Pixiv 收藏吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      if (confirmed != true ||
          !context.mounted ||
          !_hasCurrentData(logic, data)) {
        return false;
      }
      final res = await writeBookmark(data.id, isAdding: false);
      if (!context.mounted || !_hasCurrentData(logic, data)) return false;
      if (res.success) logic.setFavorite(false);
      _showBookmarkMessage(
        context,
        res.success ? '已取消网络收藏' : '取消网络收藏失败：${res.errorMessageWithoutNull}',
      );
      return res.success;
    });
  }

  /// 详情响应自带当前账号的收藏状态，无需额外查询书签列表。
  @override
  Future<bool> loadFavoriteState(PixivComicInfo data) async =>
      data.isBookmarked;

  // ── 点赞 / 评论：不实现，按钮自动隐藏 ───────────────────────────────────

  @override
  void Function(BuildContext context, PixivComicInfo data)? get onLike => null;

  @override
  void Function(BuildContext context, PixivComicInfo data)? get onComment =>
      null;

  // ── 自定义区块：作品页面预览 ────────────────────────────────────────────

  @override
  Widget buildCustomSection(BuildContext context, PixivComicInfo data) {
    return PixivAuthorLink(
      destination: PixivAuthorDestination(
        authorId: data.authorId,
        comicId: data.id,
      ),
      authorName: data.author,
    );
  }

  /// 通过基类钩子插入「作品页面预览」，位置在**简介之后**。
  ///
  /// 用 [buildSectionAfterDescription] 而非 [buildCustomSection]：后者的插槽在
  /// 简介**之前**。预览墙体量大、属附属内容，放在简介之后更符合阅读顺序
  /// （先看信息与简介，再逐页预览）。
  ///
  /// 用 StatefulWidget 承载异步分页数据与档位状态，失败时只在区块内显示错误
  /// 文案，详情页本身（封面/信息/简介）不受影响。
  @override
  Widget? buildSectionAfterDescription(
      BuildContext context, PixivComicInfo data) {
    return _PixivPagePreviewSection(
      comicId: comicId,
      illustType: data.illustType,
    );
  }

  // ── 已下载检测（与下载队列 / 本地库 ID 规则一致）────────────────────────

  @override
  List<String>? downloadCandidateIds(PixivComicInfo data) =>
      ['pixiv${data.id}'];
}

// ═══════════════════════════════════════════════════════════════════════════
//  作品页面预览区块
// ═══════════════════════════════════════════════════════════════════════════

/// 图片档位：regular（常规） / original（原图）。
enum _PixivPreviewQuality { regular, original }

/// 「作品页面预览」区块：异步拉 `getComicPages`，网格展示缩略图，点击进全屏翻页。
class _PixivPagePreviewSection extends StatefulWidget {
  const _PixivPagePreviewSection({
    required this.comicId,
    required this.illustType,
  });

  final String comicId;

  /// 作品类型，[pixivIllustTypeUgoira] 时展示动图标记。
  final int illustType;

  @override
  State<_PixivPagePreviewSection> createState() =>
      _PixivPagePreviewSectionState();
}

class _PixivPagePreviewSectionState extends State<_PixivPagePreviewSection> {
  List<PixivPage>? _pages;
  String? _error;
  bool _loading = true;

  bool get _isUgoira => widget.illustType == pixivIllustTypeUgoira;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final res = await PixivNetwork().getComicPages(widget.comicId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res.error) {
        _error = res.errorMessageWithoutNull;
        _pages = null;
      } else {
        _pages = res.data;
        _error = null;
      }
    });
  }

  /// 网格缩略图固定取最小档：这里是概览，放大/切档由全屏预览页负责。
  ///
  /// 带向后回退是因为 Pixiv 对部分作品不下发小图，直接取会产生空白格。
  /// 缩略图取哪一档 URL。
  ///
  /// **顺序是 `small` → `regular` → `thumbMini`，把最小档放最后。**
  /// 理由：真机反馈"详情页预览区整片空白"，而详情页封面（用 `regular`/`original`）
  /// 是正常的——同域、同请求头，唯一变量就是**档位路径**。
  /// `thumb_mini` 是最小档（约 48px），部分作品的该档存在性/路径与其它档不一致，
  /// 优先用它会让"有图的作品也显示空"。
  /// 预览缩略图的目标尺寸本来就不该用 48px 档，`small`（约 540px）更合适。
  String _thumbUrlFor(PixivPage page) =>
      _firstNonEmpty([page.small, page.regular, page.thumbMini]);

  String _firstNonEmpty(List<String> candidates) {
    for (final url in candidates) {
      if (url.isNotEmpty) return url;
    }
    return '';
  }

  void _openPreview(int index) {
    final pages = _pages;
    if (pages == null || pages.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _PixivPagePreviewPage(
          pages: pages,
          initialIndex: index.clamp(0, pages.length - 1),
          headers: const {
            'Referer': 'https://www.pixiv.net/',
            'User-Agent': PixivNetwork.pixivWebUA,
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('作品页面预览', style: theme.textTheme.titleSmall),
            const SizedBox(width: 8),
            if (_isUgoira)
              // Ugoira 本轮只做静态帧展示（不做 zip 下载与动画合成），
              // 用标记明确告知用户"这是动图作品，此处为降级预览"。
              const Chip(
                avatar: Icon(Icons.gif_box_outlined, size: 16),
                label: Text('UGOIRA 动图'),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          _buildError()
        else if (_pages == null || _pages!.isEmpty)
          Text(
            '没有可预览的页面',
            style: theme.textTheme.bodySmall,
          )
        else
          _buildGrid(),
      ],
    );
  }

  Widget _buildError() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '页面预览加载失败：$_error',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('重试'),
        ),
      ],
    );
  }

  /// 缩略图墙：排版对齐原项目 `comic_page.dart` 的 `buildThumbnails`。
  ///
  /// 参照的三个关键取值：
  /// - `maxCrossAxisExtent: 200`（原项目同值）：比首版的 120 大得多，
  ///   手机上从 3 列变 2 列，单张缩略图约 160dp 宽，能看清画面内容；
  /// - `childAspectRatio: 0.65`（原项目同值）：竖版卡片，贴合插画/漫画的
  ///   常见长宽比，避免方形格把长图裁得很窄；
  /// - **页码放在图下方**（原项目是在 `Column` 里图片 `Expanded` + 下方 `Text`），
  ///   而不是叠在右下角的角标——原项目如此，且不遮挡画面。
  ///
  /// 卡片视觉也照原项目：圆角 16 + `outline` 描边 + 图片 `BoxFit.contain`
  /// （contain 而非 cover：预览的目的是看全整页版式，裁切会丢信息）。
  Widget _buildGrid() {
    final pages = _pages!;
    const headers = {
      'Referer': 'https://www.pixiv.net/',
      'User-Agent': PixivNetwork.pixivWebUA,
    };
    return GridView.builder(
      // 嵌套在详情页的滚动视图里：必须禁用自身滚动并给出固有高度，
      // 否则会在无界高度约束下报错。
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: pages.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        childAspectRatio: 0.65,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemBuilder: (context, index) {
        final url = _thumbUrlFor(pages[index]);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: InkWell(
                onTap: () => _openPreview(index),
                borderRadius: BorderRadius.circular(16),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox.expand(
                      child: url.isEmpty
                          ? const ColoredBox(
                              color: Colors.black12,
                              child: Icon(Icons.broken_image_outlined),
                            )
                          : Image.network(
                              url,
                              headers: headers,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.low,
                              loadingBuilder: (context, child, progress) {
                                if (progress == null) return child;
                                return const ColoredBox(
                                  color: Colors.black12,
                                  child: Center(
                                    child: SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ),
                                );
                              },
                              errorBuilder: (context, error, stackTrace) {
                                // 记录失败的 URL 与原因：图片加载失败目前是静默的
                                // （只画一个占位图标），不记日志就完全查不到
                                // "哪一档、哪个 URL 失败"，只能靠猜。
                                LogManager.addLog(
                                  LogLevel.warning,
                                  'PixivPreview',
                                  '预览缩略图加载失败：$url\n$error',
                                );
                                return const ColoredBox(
                                  color: Colors.black12,
                                  child: Icon(Icons.broken_image_outlined),
                                );
                              },
                            ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text('${index + 1}', style: Theme.of(context).textTheme.bodySmall),
          ],
        );
      },
    );
  }
}

/// 全屏预览页：左右翻页看全部图，支持 regular / original 档位切换。
class _PixivPagePreviewPage extends StatefulWidget {
  const _PixivPagePreviewPage({
    required this.pages,
    required this.initialIndex,
    required this.headers,
  });

  final List<PixivPage> pages;
  final int initialIndex;
  final Map<String, String> headers;

  @override
  State<_PixivPagePreviewPage> createState() => _PixivPagePreviewPageState();
}

class _PixivPagePreviewPageState extends State<_PixivPagePreviewPage> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  _PixivPreviewQuality _quality = _PixivPreviewQuality.regular;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _urlFor(PixivPage page) {
    final candidates = switch (_quality) {
      _PixivPreviewQuality.regular => [
          page.regular,
          page.small,
          page.thumbMini
        ],
      _PixivPreviewQuality.original => [
          page.original,
          page.regular,
          page.small
        ],
    };
    for (final url in candidates) {
      if (url.isNotEmpty) return url;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.pages.length;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / $total'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: SegmentedButton<_PixivPreviewQuality>(
                segments: const [
                  ButtonSegment(
                    value: _PixivPreviewQuality.regular,
                    label: Text('常规'),
                  ),
                  ButtonSegment(
                    value: _PixivPreviewQuality.original,
                    label: Text('原图'),
                  ),
                ],
                selected: {_quality},
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
                onSelectionChanged: (selection) {
                  setState(() => _quality = selection.first);
                },
              ),
            ),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: total,
        onPageChanged: (value) => setState(() => _index = value),
        itemBuilder: (context, index) {
          final url = _urlFor(widget.pages[index]);
          if (url.isEmpty) {
            return const Center(
              child: Icon(Icons.broken_image_outlined,
                  color: Colors.white54, size: 48),
            );
          }
          return InteractiveViewer(
            maxScale: 5,
            child: Center(
              child: Image.network(
                url,
                headers: widget.headers,
                fit: BoxFit.contain,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  );
                },
                errorBuilder: (context, error, stackTrace) => const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.broken_image_outlined,
                          color: Colors.white54, size: 48),
                      SizedBox(height: 8),
                      Text(
                        '图片加载失败',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
