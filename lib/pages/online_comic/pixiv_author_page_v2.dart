/// Pixiv 作者页（App 内，第十八轮 34 号新增）。
///
/// ## 为什么有这一页
///
/// 「在线搜索」页的 ID 直跳区里，用户输入的纯数字在他看来**可能就是作者 uid**
/// （Pixiv 的作品 id 与作者 uid 都是纯数字，无法区分）。所以那里除「打开漫画」
/// 之外并排给出「打开作者页」，点击进入本页 —— 全程在 App 内，不走外部浏览器。
///
/// ## 数据来源（三步链路，见 `PixivNetwork` 的同名注释）
///
/// 1. `GET /ajax/user/{uid}?full=1` → 名字 / 头像 / 简介 / 关注数；
/// 2. `GET /ajax/user/{uid}/profile/all` → 全部作品 id；
/// 3. `GET /ajax/user/{uid}/profile/illusts?...&ids[]=…` → 每页 30 件的作品详情。
///
/// ## 两个刻意的设计
///
/// - **分区独立成败**：作者资料与作品列表**各自**加载、各自显示错误与重试。
///   资料挂了不该让作品列表也变成错误页（反之亦然），而且这样"哪一步失败"
///   在界面上就是可见的 —— 第 3 步（`profile/illusts`）尚未真机验证，
///   失败时的可诊断性比"一次做对"更现实。
/// - **作品列表用瀑布流**（36 号用户要求："把作者页的展示改为瀑布流的样式"）：
///   与图集页「插画」视图同一套视觉。为此 [PixivComicBrief] 补上了
///   `width` / `height`（响应里本来就有，之前没解析），并把封面 URL 用
///   [pixivProportionalThumbUrl] 换成**保持比例**的缩略图 ——
///   响应给的 `/c/250x250_80_a2/…_square1200.jpg` 是方图裁切版，
///   直接放进瀑布流只能全部按 1:1 排（那就不是瀑布流了）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart'
    show illustWaterfallColumnsSettingIndex, normalizeIllustWaterfallColumns;
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart'
    show pixivProportionalThumbUrl;
import 'package:picakeep/pages/online_common/online_comic_list_item.dart'
    show onlineCoverProvider, openOnlineComic;
import 'package:picakeep/pages/online_common/online_waterfall_card.dart';

/// Pixiv 图片（头像/封面）必须带的防盗链头。
///
/// 与 `comic_source/built_in/pixiv.dart` 的 `imageHeadersBuilder` **同口径**：
/// UA 必须是 [PixivNetwork.pixivWebUA]，不能图省事用通用 `webUA` ——
/// Pixiv 会校验 UA 与 Referer 的组合一致性，UA 不一致时图片被拒，
/// 表现为"头像/封面全空白"。
const Map<String, String> pixivImageHeaders = <String, String>{
  'Referer': 'https://www.pixiv.net/',
  'User-Agent': PixivNetwork.pixivWebUA,
};

/// Pixiv 作者页。入参 [uid] 是纯数字的作者 uid（由 ID 直跳区清洗后传来）。
class PixivAuthorPageV2 extends StatefulWidget {
  const PixivAuthorPageV2(this.uid, {super.key});

  /// 作者 uid（Pixiv 的 `userId`）。
  final String uid;

  @override
  State<PixivAuthorPageV2> createState() => _PixivAuthorPageV2State();
}

class _PixivAuthorPageV2State extends State<PixivAuthorPageV2> {
  final PixivNetwork _network = PixivNetwork();
  final ScrollController _scrollController = ScrollController();

  // ── 作者资料区（第 1 步，独立成败）──
  PixivAuthor? _author;
  String? _authorError;
  bool _authorLoading = false;

  // ── 作品列表区（第 2+3 步，独立成败）──
  final List<BaseComic> _items = <BaseComic>[];
  int _loadedPages = 0;

  /// 总页数（`Res.subData`）。null 表示还不知道（尚未成功加载过一页）。
  /// 为 0 表示该作者没有任何公开作品。
  int? _totalPages;
  bool _worksLoading = false;
  String? _worksError;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadAuthor();
    _loadNextPage();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// 触底前 400px 预加载下一页：与搜索页的续页手感一致（不等用户真的滑到底）。
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 400) {
      _loadNextPage();
    }
  }

  Future<void> _loadAuthor() async {
    if (!mounted) return;
    setState(() {
      _authorLoading = true;
      _authorError = null;
    });
    final res = await _network.getAuthorInfo(widget.uid);
    if (!mounted) return;
    setState(() {
      _authorLoading = false;
      if (res.error) {
        // 错误文案由网络层拼好（含步骤名 + HTTP 状态码 + Content-Type + 正文片段），
        // 这里**原样透出**，不再包一层"加载失败"——包了就丢掉了可诊断性。
        _authorError = res.errorMessageWithoutNull;
        return;
      }
      _author = res.data;
    });
  }

  Future<void> _loadNextPage() async {
    if (_worksLoading) return;
    final total = _totalPages;
    if (total != null && _loadedPages >= total) return; // 已到底，不再请求
    if (!mounted) return;
    setState(() {
      _worksLoading = true;
      _worksError = null;
    });
    final res = await _network.getAuthorWorks(widget.uid, page: _loadedPages + 1);
    if (!mounted) return;
    setState(() {
      _worksLoading = false;
      if (res.error) {
        _worksError = res.errorMessageWithoutNull;
        return;
      }
      final totalPages = _asInt(res.subData);
      if (totalPages != null) _totalPages = totalPages;
      _loadedPages += 1;
      _items.addAll(res.data);
    });
  }

  static int? _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }

  Future<void> _refresh() async {
    setState(() {
      _items.clear();
      _loadedPages = 0;
      _totalPages = null;
      _worksError = null;
    });
    await Future.wait(<Future<void>>[_loadAuthor(), _loadNextPage()]);
  }

  ComicSource? get _source => ComicSource.find('pixiv');

  /// 瀑布流列数：与图集页「插画」视图**共用同一个设置**（`settings[156]`）。
  ///
  /// 两处都是"多列图片墙"，各配一个列数只会让用户在两个地方各调一次。
  int get _columns => normalizeIllustWaterfallColumns(
        appdata.settings[illustWaterfallColumnsSettingIndex],
      );

  @override
  Widget build(BuildContext context) {
    final author = _author;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          (author?.name.isNotEmpty ?? false) ? author!.name : '作者页',
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          controller: _scrollController,
          // 内容不足一屏时也要能下拉刷新。
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            // 头部（作者资料 + 区块标题）与尾部（加载中/错误/到底）都是 sliver，
            // 中间的作品墙才是瀑布流本身。
            SliverToBoxAdapter(child: _buildHeader(context)),
            SliverPadding(
              // 与图集页插画瀑布流同样的左右各 2dp：卡片自带 3dp 外边距，
              // 两者相加才是视觉上的块间距。
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 24),
              sliver: SliverMasonryGrid.count(
                crossAxisCount: _columns,
                mainAxisSpacing: 0,
                crossAxisSpacing: 0,
                childCount: _items.length,
                itemBuilder: (context, index) =>
                    _buildWorkCard(context, _items[index]),
              ),
            ),
            SliverToBoxAdapter(child: _buildFooter(context)),
          ],
        ),
      ),
    );
  }

  /// 一张作品卡片；点开进入该源的详情页（与搜索页/探索页同一个跳转函数）。
  Widget _buildWorkCard(BuildContext context, BaseComic comic) {
    final source = _source;
    if (source == null) {
      // 理论上不可达（pixiv 是内置源）；留一行兜底，避免整页崩在
      // 一个"源没注册"的环境问题上。
      return ListTile(title: Text(comic.title));
    }
    // 宽高 / 页数只有 [PixivComicBrief] 有。`_items` 声明成 `BaseComic` 只是
    // 为了装 `Res<List<BaseComic>>` 的容器，实际元素恒为 `PixivComicBrief`
    // （作者页只从 `getAuthorWorks` 取数）；这里做一次显式收窄，
    // 拿不到就退回 `BaseComic` 能给的字段，不硬转。
    final brief = comic is PixivComicBrief ? comic : null;
    return OnlineWaterfallCard(
      title: comic.title,
      // **必须换掉方图缩略图**：响应给的 `_square1200` 是裁切版，
      // 直接排进瀑布流会让每一格都变成 1:1。
      cover: pixivProportionalThumbUrl(comic.cover),
      imageHeaders:
          source.imageHeadersBuilder?.call(comic) ?? pixivImageHeaders,
      onTap: () => openOnlineComic(context, source, comic),
      author: brief?.author ?? comic.subTitle,
      pageCount: brief?.pageCount ?? 0,
      width: brief?.width,
      height: brief?.height,
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  //  作者资料区
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final author = _author;
    final comment = author?.comment ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AuthorAvatar(url: author?.avatar ?? '', size: 64),
              const SizedBox(width: 12),
              Expanded(child: _buildAuthorTexts(context)),
            ],
          ),
          if (comment.isNotEmpty) ...[
            const SizedBox(height: 12),
            // 简介可能很长（有的作者写了十几行）：限行 + 省略，避免把作品列表
            // 挤出首屏。本轮不做"展开全文"（属交互增量，见计划的未覆盖项）。
            Text(
              comment,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Text('作品', style: theme.textTheme.titleSmall),
              const Spacer(),
              if (_items.isNotEmpty)
                Text(
                  _totalPages != null && _loadedPages >= _totalPages!
                      ? '共 ${_items.length} 件'
                      : '已加载 ${_items.length} 件',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildAuthorTexts(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final author = _author;

    if (_authorLoading && author == null) {
      return Text(
        '加载作者资料…',
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: colorScheme.onSurfaceVariant),
      );
    }

    final error = _authorError;
    if (error != null && author == null) {
      // 失败时把网络层给的诊断原文显示出来（可长按复制），并给重试入口。
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '作者资料加载失败',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: colorScheme.error),
          ),
          const SizedBox(height: 2),
          SelectableText(
            error,
            maxLines: 4,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          TextButton.icon(
            onPressed: _loadAuthor,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试'),
          ),
        ],
      );
    }

    final following = author?.following ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          author?.name ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          following > 0
              ? 'uid ${author?.id ?? widget.uid} · $following 关注'
              : 'uid ${author?.id ?? widget.uid}',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  //  作品列表尾部：加载中 / 错误+重试 / 空 / 到底
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildFooter(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (_worksLoading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final error = _worksError;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '作品列表加载失败',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: colorScheme.error),
                  ),
                ),
                TextButton.icon(
                  onPressed: _loadNextPage,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重试'),
                ),
              ],
            ),
            SelectableText(
              error,
              maxLines: 5,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    if (_items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            '该作者暂无公开作品',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final total = _totalPages;
    if (total != null && _loadedPages >= total) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Text(
            '已经到底了',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return const SizedBox(height: 16);
  }
}

/// 圆形头像。Pixiv 头像域同样有防盗链，必须带 [pixivImageHeaders]，
/// 因此走 [onlineCoverProvider]（带磁盘缓存与在途去重）而不是裸 `NetworkImage`。
class _AuthorAvatar extends StatelessWidget {
  const _AuthorAvatar({required this.url, required this.size});

  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.person_outline,
        size: size * 0.5,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
    return ClipOval(
      child: SizedBox.square(
        dimension: size,
        child: url.isEmpty
            ? placeholder
            : Image(
                image: onlineCoverProvider(
                  url: url,
                  headers: pixivImageHeaders,
                ),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => placeholder,
              ),
      ),
    );
  }
}
