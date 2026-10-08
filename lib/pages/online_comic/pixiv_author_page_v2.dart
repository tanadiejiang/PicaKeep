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
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart'
    show illustWaterfallColumnsSettingIndex, normalizeIllustWaterfallColumns;
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/pages/accounts/account_page_route.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart'
    show
        onlineCoverProvider,
        onlinePixivDetailEntry,
        pixivDetailAccountIdentity;
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';
import 'package:picakeep/pages/settings/settings_page.dart'
    show showWaterfallTagSettings;

/// Pixiv 图片（头像/封面）必须带的防盗链头。
///
/// 与 `comic_source/built_in/pixiv.dart` 的 `imageHeadersBuilder` **同口径**：
/// 保持与 [PixivNetwork.pixivWebUA] 一致。Referer 是现有图片链路所需；
/// 是否还严格校验 UA 并未单独验证，不从图片加载失败推断额外站点契约。
const Map<String, String> pixivImageHeaders = <String, String>{
  'Referer': 'https://www.pixiv.net/',
  'User-Agent': PixivNetwork.pixivWebUA,
};

/// Pixiv 作者页。入参 [uid] 是纯数字的作者 uid（由 ID 直跳区清洗后传来）。
class PixivAuthorPageV2 extends StatefulWidget {
  const PixivAuthorPageV2(this.uid,
      {super.key,
      this.loadAuthor,
      this.loadWorks,
      this.setFollow,
      this.isLoggedIn,
      this.currentUserId,
      this.manageAccounts,
      this.openTagSettings,
      this.bookmarks,
      this.accountIdentity,
      this.writeBookmark,
      this.loadBookmarkState});

  /// 作者 uid（Pixiv 的 `userId`）。
  final String uid;

  /// Injectable boundaries keep refresh/paging tests independent of HTTP.
  final Future<Res<PixivAuthor>> Function(String uid)? loadAuthor;
  final Future<Res<List<PixivComicBrief>>> Function(String uid, int page)?
      loadWorks;

  final Future<Res<bool>> Function(String uid, {required bool isFollowing})?
      setFollow;
  final bool Function()? isLoggedIn;
  final String Function()? currentUserId;
  final Future<void> Function(BuildContext context)? manageAccounts;
  final Future<void> Function(BuildContext context)? openTagSettings;
  final RecommendationBookmarkController? bookmarks;
  final String Function()? accountIdentity;
  final Future<Res<bool>> Function(String id, {required bool isAdding})?
      writeBookmark;
  final Future<Res<PixivBookmarkState>> Function(String id)? loadBookmarkState;

  @override
  State<PixivAuthorPageV2> createState() => _PixivAuthorPageV2State();
}

class _PixivAuthorPageV2State extends State<PixivAuthorPageV2> {
  late final PixivNetwork _network = PixivNetwork();
  final ScrollController _scrollController = ScrollController();
  late RecommendationBookmarkController _bookmarks;
  int _generation = 0;
  int _authorRequest = 0;
  bool _commentExpanded = false;
  bool _followLoading = false;
  bool _accountsOpening = false;
  bool _followTarget = false;

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
    _bookmarks = widget.bookmarks ?? RecommendationBookmarkController.shared();
    _scrollController.addListener(_onScroll);
    App.displaySettingsVersion.addListener(_onDisplaySettingsChanged);
    _loadAuthor();
    _loadNextPage();
  }

  @override
  void dispose() {
    _generation++;
    App.displaySettingsVersion.removeListener(_onDisplaySettingsChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    if (widget.bookmarks == null) _bookmarks.dispose();
    super.dispose();
  }

  void _onDisplaySettingsChanged() {
    if (mounted) setState(() {});
  }

  /// 触底前 400px 预加载下一页：与搜索页的续页手感一致（不等用户真的滑到底）。
  void _onScroll() {
    if (!_scrollController.hasClients || _worksError != null) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 400) {
      _loadNextPage();
    }
  }

  Future<void> _loadAuthor() async {
    if (!mounted || _followLoading) return;
    final generation = _generation;
    final request = ++_authorRequest;
    setState(() {
      _authorLoading = true;
      _authorError = null;
    });
    Res<PixivAuthor> res;
    try {
      res = await (widget.loadAuthor?.call(widget.uid) ??
          _network.getAuthorInfo(widget.uid));
    } catch (_) {
      res = const Res.error('暂时无法连接 Pixiv，请检查网络后重试');
    }
    if (!mounted || generation != _generation || request != _authorRequest) {
      return;
    }
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
    final generation = _generation;
    final page = _loadedPages + 1;
    setState(() {
      _worksLoading = true;
      _worksError = null;
    });
    Res<List<PixivComicBrief>> res;
    try {
      res = await (widget.loadWorks?.call(widget.uid, page) ??
          _network.getAuthorWorks(widget.uid, page: page));
    } catch (_) {
      res = const Res.error('暂时无法连接 Pixiv，请检查网络后重试');
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _worksLoading = false;
      if (res.error) {
        _worksError = res.errorMessageWithoutNull;
        return;
      }
      final totalPages = _asInt(res.subData);
      if (totalPages != null) _totalPages = totalPages;
      _loadedPages = page;
      final existing = _items.map((item) => item.id).toSet();
      _items.addAll(res.data.where((item) => existing.add(item.id)));
      if (res.data.isEmpty) _totalPages = _loadedPages;
    });
  }

  static int? _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }

  Future<void> _refresh() async {
    if (!mounted || _followLoading || _accountsOpening) return;
    if (widget.bookmarks == null) _bookmarks.reset();
    setState(() {
      _generation++;
      _worksLoading = false;
      _items.clear();
      _loadedPages = 0;
      _totalPages = null;
      _worksError = null;
    });
    await Future.wait(<Future<void>>[_loadAuthor(), _loadNextPage()]);
  }

  @override
  void didUpdateWidget(covariant PixivAuthorPageV2 oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookmarks != widget.bookmarks) {
      if (oldWidget.bookmarks == null) _bookmarks.dispose();
      _bookmarks =
          widget.bookmarks ?? RecommendationBookmarkController.shared();
    }
    if (oldWidget.uid != widget.uid) {
      _author = null;
      _commentExpanded = false;
      _followLoading = false;
      _accountsOpening = false;
      _refresh();
    }
  }

  ComicSource? get _source => ComicSource.find('pixiv');

  PixivDetailSession _detailSession(ComicSource source) {
    final generation = _generation;
    final uid = widget.uid;
    final account = pixivDetailAccountIdentity(source);
    return PixivDetailSession(
      scope: PixivDetailScope.author,
      entries: _items.map((item) => onlinePixivDetailEntry(source, item)),
      hasMore: _totalPages == null || _loadedPages < _totalPages!,
      ownerIsCurrent: () =>
          mounted &&
          generation == _generation &&
          uid == widget.uid &&
          account == pixivDetailAccountIdentity(source),
      loadMore: () async {
        if (_worksLoading) throw StateError('入口正在加载');
        await _loadNextPage();
        if (_worksError != null) throw StateError(_worksError!);
        return PixivDetailBatch(
          _items.map((item) => onlinePixivDetailEntry(source, item)),
          hasMore: _totalPages == null || _loadedPages < _totalPages!,
        );
      },
    );
  }

  bool get _isLoggedIn =>
      widget.isLoggedIn?.call() ?? (_source?.isLoggedIn ?? false);

  String get _currentUserId => (widget.currentUserId?.call() ??
          _source?.data['userId']?.toString() ??
          '')
      .trim();

  bool get _isSelf => _isLoggedIn && _currentUserId == widget.uid;

  Future<void> _openAccounts() async {
    final generation = _generation;
    final uid = widget.uid;
    setState(() => _accountsOpening = true);
    try {
      await (widget.manageAccounts?.call(context) ?? showAccountsPage(context));
    } catch (_) {
      if (mounted && generation == _generation && uid == widget.uid) {
        _showMessage('暂时无法打开账号管理，请重试');
      }
    }
    if (!mounted || generation != _generation || uid != widget.uid) return;
    setState(() => _accountsOpening = false);
    // A changed account needs fresh server state. Opening login never submits
    // the original follow action automatically.
    await _refresh();
  }

  Future<void> _toggleFollow() async {
    final author = _author;
    if (author == null ||
        _authorLoading ||
        _followLoading ||
        _accountsOpening) {
      return;
    }
    if (!_isLoggedIn) {
      await _openAccounts();
      return;
    }
    if (_isSelf) return;
    final generation = _generation;
    final uid = widget.uid;
    final accountUid = _currentUserId;
    final target = !author.isFollowed;
    setState(() {
      _followLoading = true;
      _followTarget = target;
      // A profile request started before the write must not restore old state.
      _authorRequest++;
    });
    Res<bool> res;
    try {
      res = await (widget.setFollow?.call(uid, isFollowing: target) ??
          _network.setFollow(uid, isFollowing: target));
    } catch (_) {
      res = const Res.error('暂时无法连接 Pixiv，请检查网络后重试');
    }
    if (!mounted || generation != _generation || uid != widget.uid) return;
    setState(() => _followLoading = false);
    if (!_isLoggedIn || accountUid != _currentUserId) {
      await _loadAuthor();
      return;
    }
    if (res.error) {
      _showMessage('操作失败：${res.errorMessageWithoutNull}');
      return;
    }
    setState(() => _author = author.copyWith(isFollowed: res.data));
    _showMessage(res.data ? '已关注' : '已取消关注');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openTagSettings() async {
    await (widget.openTagSettings?.call(context) ??
        showWaterfallTagSettings(context));
    if (mounted) setState(() {});
  }

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
        actions: [
          IconButton(
            tooltip: '瀑布流标签设置',
            onPressed: _openTagSettings,
            icon: const Icon(Icons.label_outline),
          ),
          IconButton(
            tooltip: '刷新作者页',
            onPressed: _followLoading || _accountsOpening ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: PixivBookmarkFeedbackHost(
        identity: (
          widget.uid,
          widget.accountIdentity?.call() ??
              (_source == null ? '' : pixivDetailAccountIdentity(_source!)),
          _generation
        ),
        avoidViewInsets: true,
        child: RefreshIndicator(
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
    return OnlineRecommendationCard(
      key: ValueKey((source.key, comic.id)),
      source: source,
      comic: comic,
      bookmarks: _bookmarks,
      isAuthorPage: true,
      actionsEnabled: !_worksLoading && !_accountsOpening,
      isLoggedIn: widget.isLoggedIn,
      accountIdentity: widget.accountIdentity,
      writeBookmark: widget.writeBookmark,
      loadBookmarkState: widget.loadBookmarkState,
      manageAccounts: widget.manageAccounts,
      onAccountsChanged: _refresh,
      detailSessionBuilder: () => _detailSession(source),
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
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _AuthorAvatar(url: author?.avatar ?? '', size: 64),
                    const SizedBox(width: 14),
                    Expanded(child: _buildAuthorTexts(context)),
                  ],
                ),
                if (author != null) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: _buildFollowButton(),
                  ),
                ],
                if (comment.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    comment,
                    maxLines: _commentExpanded ? null : 3,
                    overflow: _commentExpanded ? null : TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () =>
                          setState(() => _commentExpanded = !_commentExpanded),
                      icon: Icon(_commentExpanded
                          ? Icons.expand_less
                          : Icons.expand_more),
                      label: Text(_commentExpanded ? '收起简介' : '展开简介'),
                    ),
                  ),
                ],
                if (_authorLoading && author != null) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                if (_authorError != null && author != null) ...[
                  const SizedBox(height: 8),
                  Text('资料更新失败，正在显示上次加载的资料',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colorScheme.error)),
                  TextButton(onPressed: _loadAuthor, child: const Text('重试资料')),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('作品', style: theme.textTheme.titleMedium),
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
              ),
              PopupMenuButton<int>(
                tooltip: '作品列数',
                initialValue: _columns,
                onSelected: (value) {
                  setState(() => appdata
                      .settings[illustWaterfallColumnsSettingIndex] = '$value');
                  appdata.writeData();
                },
                itemBuilder: (_) => [
                  for (final columns in [2, 3])
                    CheckedPopupMenuItem<int>(
                      value: columns,
                      checked: _columns == columns,
                      child: Text('$columns 列'),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.view_column_outlined, size: 20),
                      const SizedBox(width: 6),
                      Text('$_columns 列'),
                      const Icon(Icons.expand_more, size: 18),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildFollowButton() {
    final loggedIn = _isLoggedIn;
    final busy = _followLoading || _accountsOpening;
    final followed = _author!.isFollowed;
    final label = _accountsOpening
        ? '正在打开账号管理…'
        : _followLoading
            ? (_followTarget ? '正在关注…' : '正在取消关注…')
            : _isSelf
                ? '这是你自己'
                : !loggedIn
                    ? '登录后关注'
                    : followed
                        ? '已关注'
                        : '关注';
    return FilledButton.tonalIcon(
      key: const ValueKey('pixiv-author-follow'),
      onPressed: busy || _authorLoading || _isSelf ? null : _toggleFollow,
      icon: busy
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              followed ? Icons.person_remove_outlined : Icons.person_add_alt),
      label: Text(label),
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
            style:
                theme.textTheme.bodyMedium?.copyWith(color: colorScheme.error),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Center(
        child: TextButton.icon(
          onPressed: _loadNextPage,
          icon: const Icon(Icons.expand_more),
          label: const Text('加载更多作品'),
        ),
      ),
    );
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
