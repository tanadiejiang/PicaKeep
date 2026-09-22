/// 探索统一结果页。
///
/// 榜单 / 最新 / 分类结果 / 分区更多 / 集合详情 / 随机 / 标签搜索都用这一个页面，
/// 只换 [ExploreEntry] 与初始选项/分类目标。因此"榜单选项在前、分类入口可达、
/// 追加失败保留内容、切期重置滚动"这些行为只有一份实现。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/explore/explore_bindings.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/pages/explore/explore_common.dart';
import 'package:picakeep/pages/explore/explore_list_controller.dart';
import 'package:picakeep/pages/explore/explore_route_scope.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart';

class ExploreResultPage extends StatefulWidget {
  const ExploreResultPage({
    super.key,
    required this.sourceKey,
    required this.entryId,
    this.options = ExploreOptions.none,
    this.category,
    this.categoryId,
    this.title,
  });

  final String sourceKey;
  final String entryId;
  final ExploreOptions options;
  final ExploreCategoryTarget? category;
  final String? categoryId;

  /// 页面标题；为空时用入口 label。
  final String? title;

  @override
  State<ExploreResultPage> createState() => _ExploreResultPageState();
}

class _ExploreResultPageState extends State<ExploreResultPage>
    with WidgetsBindingObserver, ExploreRouteRestoreMixin<ExploreResultPage> {
  final _scrollController = ScrollController();
  ExploreListController? _controller;

  late ExploreOptions _options = widget.options;
  String? _error;

  ComicSource? get _source => ComicSource.find(widget.sourceKey);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _controller?.releaseSession();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_verifyContext());
    }
  }

  /// 从详情页 / 侧栏设置返回、重新成为当前路由时核对上下文。
  @override
  void onExploreRouteRestored() {
    unawaited(_verifyContext());
  }

  /// 账号 / 站点变化时失效并重载；卡片与屏蔽设置变化只重算现有条目。
  Future<void> _verifyContext() async {
    final bindings = ExploreBindings.instance;
    if (bindings == null || !mounted) return;
    final previousSession = _controller;
    final changed = bindings.refreshContext();
    if (changed.contains(widget.sourceKey)) {
      previousSession?.releaseSession();
      previousSession?.dispose();
      _controller = null;
      await _start();
      return;
    }
    // 屏蔽/卡片设置：保留已加载内容，只重算展示。
    _controller?.applyBlockingResolver(buildExploreBlockingResolver());
  }

  Future<void> _start() async {
    if (!mounted) return;
    final registry = ExploreBindings.instance?.registry;
    if (registry == null) {
      setState(() => _error = '探索能力尚未初始化');
      return;
    }
    final descriptor = registry.describe(widget.sourceKey);
    if (descriptor == null) {
      setState(() => _error = '未知的探索源：${widget.sourceKey}');
      return;
    }
    final entry = descriptor.entryById(widget.entryId);
    if (entry == null) {
      setState(() => _error = '该源没有入口：${widget.entryId}');
      return;
    }
    final source = _source;
    if (source == null) {
      setState(() => _error = '源未注册：${widget.sourceKey}');
      return;
    }
    // 未登录源不发无效请求。
    if (descriptor.requiresLogin && !source.isLoggedIn) {
      setState(() => _error = null);
      return;
    }

    final options = entry.options.isEmpty
        ? ExploreOptions.none
        : (_options.isEmpty
            ? ExploreOptions.single(entry.defaultOptionIdOrFirst!)
            : _options);

    final controller = ExploreListController(
      registry: registry,
      sourceKey: widget.sourceKey,
      entryId: entry.id,
      sessionId: registry.createSession(),
      blockingResolver: buildExploreBlockingResolver(),
    );
    _controller?.releaseSession();
    _controller?.dispose();
    _controller = controller;
    controller.addListener(_onControllerChanged);
    _options = options;
    setState(() => _error = null);
    await controller.load(
      options: options,
      category: widget.category,
      categoryId: widget.categoryId,
      clearCategory: widget.category == null,
    );
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _handleScroll() {
    final controller = _controller;
    if (controller == null) return;
    final state = controller.state;
    if (state.loading || state.loadingMore || !state.hasMore) return;
    if (state.moreError != null) return; // 不连续重试同一失败页
    final pos = _scrollController.position;
    // 下拉刷新时不同时触发续页；短列表由页尾按钮继续加载。
    if (pos.pixels <= 0) return;
    if (pos.pixels >= pos.maxScrollExtent - 420) {
      unawaited(controller.loadMore());
    }
  }

  Future<void> _changeOption(String optionId) async {
    final controller = _controller;
    if (controller == null || optionId == _options.first) return;
    _options = ExploreOptions.single(optionId);
    _resetScrollToTop();
    await controller.load(
      options: _options,
      category: widget.category,
      categoryId: widget.categoryId,
      clearCategory: widget.category == null,
    );
  }

  void _resetScrollToTop() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels == 0) return;
    _scrollController.jumpTo(0);
  }

  Future<void> _refresh() async {
    _resetScrollToTop();
    ExploreBindings.instance?.refreshContext();
    // 刷新创建自己的新会话，兼容 TTL 过期，并保留当前榜期和分类/期号目标。
    await _start();
  }

  @override
  Widget build(BuildContext context) {
    final registry = ExploreBindings.instance?.registry;
    final descriptor = registry?.describe(widget.sourceKey);
    final entry = descriptor?.entryById(widget.entryId);
    final source = _source;
    final needsLogin =
        (descriptor?.requiresLogin ?? true) && !(source?.isLoggedIn ?? false);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? entry?.label ?? '探索'),
        actions: [
          if (entry?.supportsRefresh ?? false)
            IconButton(
              tooltip: entry?.singlePage == true ? '换一批' : '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: needsLogin ? null : _refresh,
            ),
        ],
      ),
      body: _buildBody(context, descriptor, entry, needsLogin),
    );
  }

  Widget _buildBody(
    BuildContext context,
    ExploreSourceDescriptor? descriptor,
    ExploreEntry? entry,
    bool needsLogin,
  ) {
    if (_error != null) {
      return exploreErrorView(
        error: _error!,
        onRetry: _start,
      );
    }
    if (descriptor == null || entry == null) {
      return const Center(child: Text('该入口不可用'));
    }
    if (needsLogin) {
      return exploreLoginRequiredView(
        sourceName: descriptor.name,
        onManageAccounts: _openAccounts,
      );
    }
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final state = controller.state;
    final source = _source!;

    return Column(
      children: [
        // 榜单选项、分类入口都放在列表**之前**（不能被无限列表压到底部）。
        if (entry.options.isNotEmpty)
          exploreOptionBar(
            options: entry.options,
            selectedId: state.optionId ?? entry.defaultOptionIdOrFirst,
            onSelected: (id) => unawaited(_changeOption(id)),
          ),
        if (entry.description.isNotEmpty)
          exploreHintBar(context, entry.description),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: _buildList(context, source, state),
          ),
        ),
      ],
    );
  }

  Widget _buildList(
    BuildContext context,
    ComicSource source,
    ExploreListState state,
  ) {
    final controller = _controller!;
    if (state.loading) {
      return _buildStatusList(
        const Center(child: CircularProgressIndicator()),
      );
    }
    final error = state.error;
    if (error != null) {
      return _buildStatusList(
        exploreErrorView(error: error.message, onRetry: _refresh),
      );
    }
    if (!state.hasVisibleItems && !state.hasMore) {
      return _buildStatusList(const Center(child: Text('没有内容')));
    }

    final items = state.items;
    return ListView.builder(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      // 过滤后全空但仍有下一页时，页尾保留"继续加载"入口。
      itemCount: items.length + 1,
      itemBuilder: (context, index) {
        if (index >= items.length) {
          return _buildFooter(context, controller, state);
        }
        final item = items[index];
        if (item.isBlocked && readHideBlockedComics()) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: OnlineComicListItem(
            source: source,
            comic: item.comic,
            highlighted: item.isBlocked,
            trailing: item.isBlocked ? Text('已屏蔽：${item.blockedBy}') : null,
          ),
        );
      },
    );
  }

  /// 空、错误和加载态也提供一个占满剩余高度的可下拉滚动区域。
  Widget _buildStatusList(Widget child) {
    return CustomScrollView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverFillRemaining(hasScrollBody: false, child: child),
      ],
    );
  }

  Widget _buildFooter(
    BuildContext context,
    ExploreListController controller,
    ExploreListState state,
  ) {
    final moreError = state.moreError;
    if (moreError != null) {
      final restart = moreError.code == ExploreErrorCode.expiredContinuation ||
          controller.nextToken == null;
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              moreError.message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
            // 网络错误重试原 token；过期或已停止的分页必须从头刷新。
            OutlinedButton.icon(
              onPressed: () => unawaited(
                restart ? _refresh() : controller.loadMore(),
              ),
              icon: const Icon(Icons.refresh),
              label: Text(restart ? '从头刷新' : '重试'),
            ),
          ],
        ),
      );
    }
    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (state.hasMore) {
      // 短列表没填满屏幕也能点；不只依赖滚动事件。
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: OutlinedButton(
            onPressed: () => unawaited(controller.loadMore()),
            child: const Text('加载更多'),
          ),
        ),
      );
    }
    return const SizedBox(height: 24);
  }

  Future<void> _openAccounts() async {
    if (!mounted) return;
    // 复用账号容器；它返回的 Future 在整个容器关闭时完成。
    await showExploreAccountsPage(context);
    if (!mounted) return;
    ExploreBindings.instance?.refreshContext();
    await _start();
  }
}
