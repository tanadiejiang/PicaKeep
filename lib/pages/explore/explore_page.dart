/// Exploration keeps each visited source and entry alive until this page closes.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart'
    show illustWaterfallColumnsSettingIndex, normalizeIllustWaterfallColumns;
import 'package:picakeep/foundation/explore/explore_bindings.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_registry.dart';
import 'package:picakeep/foundation/explore/explore_selection_state.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/pages/explore/explore_category_panel.dart';
import 'package:picakeep/pages/explore/explore_common.dart';
import 'package:picakeep/pages/explore/explore_list_controller.dart';
import 'package:picakeep/pages/explore/explore_keep_alive_switcher.dart';
import 'package:picakeep/pages/explore/explore_result_page.dart';
import 'package:picakeep/pages/explore/explore_route_scope.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';

enum ExploreTabKind { recommend, ranking, category }

String? _sessionSourceKey;
ExploreTabKind _sessionKind = ExploreTabKind.recommend;

class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key});
  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage>
    with WidgetsBindingObserver, ExploreRouteRestoreMixin<ExplorePage> {
  final _visited = <String>{};
  final _sourceKinds = <String, ExploreTabKind>{};
  final _sourceContexts = <String, (String, bool)>{};
  final _sourcePanes = <String, _SourceExplorePane>{};
  int _displayRevision = 0;
  String? _sourceKey;
  ExploreTabKind _kind = _sessionKind;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _verifyContext();
  }

  @override
  void onExploreRouteRestored() => _verifyContext();

  void _verifyContext() {
    if (!mounted) return;
    final changed = ExploreBindings.instance?.refreshContext() ?? <String>[];
    _visited.removeWhere((key) => key != _sourceKey && changed.contains(key));
    _displayRevision++;
    _sourcePanes.clear();
    setState(() {});
  }

  void _selectKind(ExploreTabKind kind) {
    if (_kind == kind) return;
    setState(() {
      _kind = kind;
      _sessionKind = kind;
      if (_sourceKey != null) _sourceKinds[_sourceKey!] = kind;
    });
  }

  ExploreTabKind _storedKind(ExploreSourceDescriptor descriptor) {
    if (descriptor.sourceKey != 'pixiv') return _kind;
    final stored = selectionForDescriptor(
      sourceKey: descriptor.sourceKey,
      descriptor: descriptor,
      raw: appdata.settings.length > exploreSelectionSettingIndex
          ? appdata.settings[exploreSelectionSettingIndex]
          : null,
    );
    return stored.kind == exploreSelectionKindRanking
        ? ExploreTabKind.ranking
        : ExploreTabKind.recommend;
  }

  Widget _paneFor(ExploreRegistry registry, ExploreSourceState source) {
    final key = source.descriptor.sourceKey;
    if (!_visited.contains(key)) return const SizedBox.shrink();
    final active = key == _sourceKey;
    final kind = _sourceKinds[key] ?? _storedKind(source.descriptor);
    final cached = _sourcePanes[key];
    if (cached != null &&
        identical(cached.registry, registry) &&
        identical(cached.descriptor, source.descriptor) &&
        cached.active == active &&
        cached.kind == kind &&
        cached.loggedIn == source.loggedIn) {
      return cached;
    }
    return _sourcePanes[key] = _SourceExplorePane(
      key: ValueKey((registry, key, _sourceContexts[key])),
      registry: registry,
      descriptor: source.descriptor,
      loggedIn: source.loggedIn,
      active: active,
      kind: kind,
      displayRevision: _displayRevision,
      onKindChanged: _selectKind,
      onAccountsChanged: _verifyContext,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(child: _buildPage(context));
  }

  Widget _buildPage(BuildContext context) {
    final registry = ExploreBindings.instance?.registry;
    if (registry == null) {
      return exploreErrorView(
          error: '探索能力尚未初始化', onRetry: () async => _verifyContext());
    }
    final sources = registry.listSourceStates();
    for (final source in sources) {
      final key = source.descriptor.sourceKey;
      final identity =
          (registry.providerOf(key)!.contextFingerprint, source.loggedIn);
      if (_sourceContexts[key] != identity) {
        _visited.remove(key);
        _sourcePanes.remove(key);
        _sourceContexts[key] = identity;
      }
    }
    if (sources.isEmpty) return const Center(child: Text('没有可用的探索源'));
    if (!sources.any((s) => s.descriptor.sourceKey == _sourceKey)) {
      _sourceKey = (sources
                  .where((s) => s.descriptor.sourceKey == _sessionSourceKey)
                  .firstOrNull ??
              sources.where((s) => s.loggedIn).firstOrNull ??
              sources.first)
          .descriptor
          .sourceKey;
    }
    _visited.add(_sourceKey!);
    final activeSource = sources
        .where((source) => source.descriptor.sourceKey == _sourceKey)
        .first;
    _sourceKinds.putIfAbsent(
        _sourceKey!, () => _storedKind(activeSource.descriptor));
    _kind = _sourceKinds[_sourceKey!]!;
    final index =
        sources.indexWhere((s) => s.descriptor.sourceKey == _sourceKey);
    // 源页签要跟主导航顶栏留出一点距离：`NaviPane` 的内容区是
    // `MediaQuery.removePadding(removeTop: …)` 之后的区域（状态栏那一段由导航壳的
    // 顶栏负责），所以本页自己必须补这一档 —— 否则页签会直接贴顶栏下沿，
    // 而且向下滚时内容首行会钻进顶栏底下。与本站其它页留白一致。
    final topGap = MediaQuery.of(context).padding.top <= 0
        ? 8.0
        : (MediaQuery.of(context).padding.top / 3)
            .clamp(8.0, 16.0)
            .roundToDouble();
    return DefaultTabController(
      length: sources.length,
      initialIndex: index,
      child: Column(children: [
        Padding(
          padding: EdgeInsets.only(top: topGap),
          child: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            onTap: (i) {
              if (_sourceKey == sources[i].descriptor.sourceKey) return;
              setState(() {
                _sourceKey = sources[i].descriptor.sourceKey;
                _sessionSourceKey = _sourceKey;
                final source = sources[i];
                _sourceKinds[_sourceKey!] ??= _storedKind(source.descriptor);
                _kind = _sourceKinds[_sourceKey!]!;
              });
            },
            tabs: [
              for (final source in sources)
                Tab(
                    height: 42,
                    // 「（未登录）」只在**该源确实需要登录才有内容**时才加。
                    // `requiresLogin == false` 的源（Pixiv / Komiic）游客也能浏览
                    // 推荐与榜单，打上"未登录"会让人以为页签点进去是空的。
                    text: (source.loggedIn || !source.descriptor.requiresLogin)
                        ? source.descriptor.name
                        : '${source.descriptor.name}（未登录）')
            ],
          ),
        ),
        Expanded(
            child: ExploreKeepAliveSwitcher(index: index, children: [
          for (final source in sources) _paneFor(registry, source),
        ])),
      ]),
    );
  }
}

class _SourceExplorePane extends StatefulWidget {
  const _SourceExplorePane(
      {super.key,
      required this.registry,
      required this.descriptor,
      required this.loggedIn,
      required this.active,
      required this.kind,
      required this.displayRevision,
      required this.onKindChanged,
      required this.onAccountsChanged});
  final ExploreRegistry registry;
  final ExploreSourceDescriptor descriptor;
  final bool loggedIn;
  final bool active;
  final ExploreTabKind kind;
  final int displayRevision;
  final ValueChanged<ExploreTabKind> onKindChanged;
  final VoidCallback onAccountsChanged;
  @override
  State<_SourceExplorePane> createState() => _SourceExplorePaneState();
}

class _SourceExplorePaneState extends State<_SourceExplorePane> {
  String? _recommendId;
  String? _rankOption;
  final _visitedEntries = <String>{};
  final _entryWidgets = <String, Widget>{};

  bool get _isPixiv => widget.descriptor.sourceKey == 'pixiv';

  @override
  void initState() {
    super.initState();
    _restorePixivSelection();
  }

  void _restorePixivSelection() {
    if (!_isPixiv) return;
    final state = selectionForDescriptor(
      sourceKey: widget.descriptor.sourceKey,
      descriptor: widget.descriptor,
      raw: appdata.settings.length > exploreSelectionSettingIndex
          ? appdata.settings[exploreSelectionSettingIndex]
          : null,
    );
    _recommendId = state.entryId;
    _rankOption = state.rankingOption;
  }

  void _persistPixivSelection({ExploreTabKind? kind}) {
    if (!_isPixiv || appdata.settings.length <= exploreSelectionSettingIndex) {
      return;
    }
    final selectedKind = kind ?? widget.kind;
    final state = ExploreSelectionState(
      kind: selectedKind == ExploreTabKind.ranking
          ? exploreSelectionKindRanking
          : exploreSelectionKindRecommend,
      entryId: _recommendId ?? '',
      rankingOption: _rankOption ?? '',
    );
    appdata.settings[exploreSelectionSettingIndex] = updateExploreSelectionJson(
      raw: appdata.settings[exploreSelectionSettingIndex],
      sourceKey: widget.descriptor.sourceKey,
      state: state,
    );
    unawaited(appdata.updateSettings());
  }

  @override
  void didUpdateWidget(covariant _SourceExplorePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.descriptor != widget.descriptor ||
        oldWidget.displayRevision != widget.displayRevision) {
      _entryWidgets.clear();
      if (oldWidget.descriptor != widget.descriptor) {
        _recommendId = null;
        _rankOption = null;
        _restorePixivSelection();
      }
    }
  }

  Widget _entryFor(
      ExploreEntry entry, String? activeId, ExploreEntry? ranking) {
    if (!_visitedEntries.contains(entry.id)) return const SizedBox.shrink();
    final cached = _entryWidgets[entry.id];
    if (entry.directoryAsTab) {
      return _entryWidgets[entry.id] = cached ??
          ExploreCategoryPanel(
            key: ValueKey(entry.id),
            sourceKey: widget.descriptor.sourceKey,
            entryId: entry.id,
          );
    }
    final active = widget.active && activeId == entry.id;
    final options = entry == ranking && _rankOption != null
        ? ExploreOptions.single(_rankOption!)
        : ExploreOptions.none;
    if (cached is _ExploreFeed &&
        cached.active == active &&
        cached.options == options) {
      return cached;
    }
    return _entryWidgets[entry.id] = _ExploreFeed(
      key: ValueKey(entry.id),
      registry: widget.registry,
      descriptor: widget.descriptor,
      entry: entry,
      active: active,
      onContextChanged: widget.onAccountsChanged,
      options: options,
    );
  }

  void _selectCategoryEntry(ExploreEntry entry) {
    setState(() {
      if (entry.kind == ExploreSectionKind.recommend) _recommendId = entry.id;
    });
    _persistPixivSelection(
      kind: entry.kind == ExploreSectionKind.ranking
          ? ExploreTabKind.ranking
          : ExploreTabKind.recommend,
    );
    widget.onKindChanged(entry.kind == ExploreSectionKind.ranking
        ? ExploreTabKind.ranking
        : ExploreTabKind.recommend);
  }

  void _selectKind(ExploreTabKind kind) {
    _persistPixivSelection(kind: kind);
    widget.onKindChanged(kind);
  }

  void _selectChoice(ExploreTabKind kind, String id) {
    setState(() {
      if (kind == ExploreTabKind.recommend) {
        _recommendId = id;
      } else {
        _rankOption = id;
      }
    });
    _persistPixivSelection(kind: kind);
  }

  Widget _categories() {
    if (!_visitedEntries.contains('_categories')) {
      return const SizedBox.shrink();
    }
    return _entryWidgets.putIfAbsent(
        '_categories',
        () => ExploreCategoryPanel(
              sourceKey: widget.descriptor.sourceKey,
              onSelectEntry: _selectCategoryEntry,
            ));
  }

  @override
  Widget build(BuildContext context) {
    final recommend = widget.descriptor
        .entriesOf(ExploreSectionKind.recommend)
        .where((e) => e.availableAsTab)
        .toList();
    final selected = recommend.where((e) => e.id == _recommendId).firstOrNull ??
        recommend.firstOrNull;
    _recommendId = selected?.id;
    final ranking =
        widget.descriptor.entriesOf(ExploreSectionKind.ranking).firstOrNull;
    if (ranking != null && !ranking.options.any((o) => o.id == _rankOption)) {
      _rankOption = ranking.defaultOptionIdOrFirst;
    }
    final kinds = <(ExploreTabKind, String)>[
      if (recommend.isNotEmpty) (ExploreTabKind.recommend, '推荐'),
      if (ranking != null) (ExploreTabKind.ranking, '榜单'),
      if (widget.descriptor.entriesOf(ExploreSectionKind.category).isNotEmpty)
        (ExploreTabKind.category, '分类'),
    ];
    final kind = kinds.any((k) => k.$1 == widget.kind)
        ? widget.kind
        : kinds.firstOrNull?.$1;
    final activeId = switch (kind) {
      ExploreTabKind.recommend => selected?.id,
      ExploreTabKind.ranking => ranking?.id,
      ExploreTabKind.category => '_categories',
      null => null,
    };
    final loggedIn = !widget.descriptor.requiresLogin || widget.loggedIn;
    if (loggedIn && activeId != null) _visitedEntries.add(activeId);
    final entries = [...recommend, if (ranking != null) ranking];
    final ids = [...entries.map((e) => e.id), '_categories'];
    final choices = kind == ExploreTabKind.recommend
        ? [for (final e in recommend) ExploreOption(id: e.id, label: e.label)]
        : kind == ExploreTabKind.ranking
            ? ranking?.options ?? <ExploreOption>[]
            : <ExploreOption>[];
    final choiceId =
        kind == ExploreTabKind.recommend ? selected?.id : _rankOption;
    final toolbar = LayoutBuilder(builder: (context, constraints) {
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
      // 页签与右侧入口**同一套胶囊**（同一 `_FloatingCapsule`）：圆角 20、
      // 未选中完全透明、选中 `secondaryContainer`。**不用 `ChoiceChip`** ——
      // 它的背景由 M3 chip 自己那层 `Material` 绘制，既带细描边、圆角与内边距
      // 也跟入口对不齐；自绘后背景是普通 `Container`，浮层淡出时不会留残影。
      // 多于三个 tab 时 `Wrap` 会换行（与「窄屏 + 大字号」的既有分支一致）。
      final navigation = Wrap(children: [
        for (final k in kinds)
          Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _FloatingCapsule(
                key: ValueKey('explore-tab-${k.$2}'),
                selected: kind == k.$1,
                semanticLabel: k.$2,
                onTap: () => _selectKind(k.$1),
                child: Text(k.$2),
              ))
      ]);
      final selector = choices.length > 1
          ? _EntryMenu(
              title:
                  '${widget.descriptor.name} · ${kind == ExploreTabKind.recommend ? '推荐入口' : '榜单范围'}',
              options: choices,
              selectedId: choiceId,
              floatingStyle: true,
              onSelected: (id) => _selectChoice(kind!, id),
            )
          : const SizedBox.shrink();
      // 水平内边距留在这一层；`explore-toolbar` 这个 key 由浮层那边统一挂
      // （见 `_FloatingExploreLayout`），避免同一把 key 出现在两处。
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: largeText || constraints.maxWidth < 340
            ? Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [navigation, selector])
            : Row(children: [
                navigation,
                const SizedBox(width: 4),
                Expanded(
                    child: Align(
                        alignment: Alignment.centerRight, child: selector))
              ]),
      );
    });
    final content = !loggedIn
        ? exploreLoginRequiredView(
            sourceName: widget.descriptor.name,
            onManageAccounts: () async {
              await showExploreAccountsPage(context);
              if (mounted) widget.onAccountsChanged();
            })
        : activeId == null
            ? const Center(child: Text('没有可用的探索入口'))
            : ExploreKeepAliveSwitcher(
                index: ids.indexOf(activeId),
                animate: widget.active,
                motionKey:
                    kind == ExploreTabKind.ranking ? _rankOption : activeId,
                children: [
                    for (final entry in entries)
                      _entryFor(entry, activeId, ranking),
                    _categories(),
                  ]);
    return _FloatingExploreLayout(
      // 页签 / 榜期 / 入口变了就是"换了内容"：停泊区要按新内容重新判断。
      motionKey: (kind, choiceId, activeId),
      toolbar: toolbar,
      child: content,
    );
  }
}

class _FloatingExploreLayout extends StatefulWidget {
  const _FloatingExploreLayout({
    required this.motionKey,
    required this.toolbar,
    required this.child,
  });

  /// 内容身份（页签 / 榜期 / 入口）。它一变，停泊区就按新内容重新从顶部算 ——
  /// 否则会沿用上一个页签的滚动位置。
  final Object? motionKey;
  final Widget toolbar;
  final Widget child;

  @override
  State<_FloatingExploreLayout> createState() => _FloatingExploreLayoutState();
}

class _FloatingExploreLayoutState extends State<_FloatingExploreLayout>
    with SingleTickerProviderStateMixin {
  /// 工具栏的**实测**高度（`toolbarHeight`）。只有它是"按钮真正占的高度"，
  /// 才能既让内容首行从浮层下方开始、又在收起时精确归零 —— 写死 56 就是 027
  /// 被推翻的那种"固定占位"。
  static const double _fallbackDockExtent = 36;

  late final AnimationController _settle;
  final GlobalKey _dockKey = GlobalKey();
  double _progress = 0;
  int _direction = 0;

  /// 停泊区当前高度 = 工具栏实测高度。
  double _dockExtent = _fallbackDockExtent;
  double? _lastTextScale;

  /// 内容当前的纵向滚动位置（停泊区跟着它收缩）。用 notifier 是为了让这一层
  /// 独立重建，滚动时不必每帧重建整页。
  final ValueNotifier<double> _pixels = ValueNotifier<double>(0);

  /// 停泊区当前高度。
  ///
  /// 两个上限取小值，缺一不可：
  ///
  /// * **`_dockExtent - pixels`**（跟真实滚动位置）：滚过一个工具栏高度就归零，
  ///   内容可以顶到浮层下方（"悬浮"就是这么来的）。**不能只跟 `_settle.value`** ——
  ///   进度是按滚动增量**累加**的，滚半屏也只到 0.7 左右，避让会一直留着一截，
  ///   内容顶不上去，看起来就像"工具栏又有了背景"（实测踩过）。
  /// * **`_dockExtent * (1 - _settle.value)`**（跟浮层显隐进度）：保证"浮层已经
  ///   整个露出来"时避让一定完整，不会出现"按钮全在、下面却只让出一点点"。
  ///
  /// 完全收起时两者都是 0 ⇒ 不会留下 027 那种"隐藏的固定占位"。
  double get _dockPadding {
    final byScroll = _dockExtent - _pixels.value;
    final byProgress = _dockExtent * (1 - _settle.value);
    final smallest = byScroll < byProgress ? byScroll : byProgress;
    return smallest > 0 ? smallest : 0;
  }

  /// 浮层不透明度：`1 - _progress`。
  ///
  /// 停泊区不走 `_progress` 字段，而是直接跟这条动画曲线 —— 滚动手势里
  /// `_settle.stop()` 之后 `_settle.value` 就是手输的进度（两者恒等，实测
  /// `_settle.value == _progress`），所以合并成一个可监听源不会改变手感，
  /// 却能让"内容 padding"这一层独立重建（`AnimatedBuilder`），
  /// **不必每帧重建内容子树**。
  double get _opacity => 1 - _settle.value;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: 0,
    )..addListener(() {
        if (mounted) setState(() => _progress = _settle.value);
      });
    // 首帧之后按实测高度校正一次（默认值只是为了让第一帧就有避让、不闪）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureDock());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统字号变了 → 工具栏高度变了 → 停泊区必须跟着重新量。
    final scale = MediaQuery.textScalerOf(context);
    if (_lastTextScale != scale.scale(14)) {
      _lastTextScale = scale.scale(14);
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureDock());
    }
  }

  @override
  void didUpdateWidget(covariant _FloatingExploreLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.motionKey != widget.motionKey) {
      // 换页签 / 换榜期：上一个内容的位置不再适用，避让按新内容的顶部算。
      _pixels.value = 0;
    }
  }

  @override
  void dispose() {
    _settle.dispose();
    _pixels.dispose();
    super.dispose();
  }

  void _measureDock() {
    if (!mounted) return;
    final box = _dockKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final height = box.size.height;
    if (height <= 0 || (height - _dockExtent).abs() < 0.5) return;
    setState(() => _dockExtent = height);
  }

  /// 把实时滚动位置写进停泊区的判据（见 `_dockPadding`）。
  bool _onScrollMetrics(ScrollMetricsNotification notification) {
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    _pixels.value = metrics.pixels;
    return false;
  }

  void _setProgress(double value) {
    final next = value.clamp(0.0, 1.0).toDouble();
    if ((next - _progress).abs() < 0.001) return;
    _settle.stop();
    _settle.value = next;
    setState(() => _progress = next);
  }

  void _settleTo(double target) {
    // 已经在目标上（或正朝它动）就不要重启动画：重启会让跟手滚动一顿一顿的。
    if ((_settle.value - target).abs() < 0.001) return;
    _settle.stop();
    _settle.value = _progress;
    _settle.animateTo(target, curve: Curves.easeOutCubic);
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification &&
        notification.metrics.axis == Axis.vertical) {
      // 停泊区跟着**实际**滚动位置收缩（程序化滚动同样计数）：顶端留出整个
      // 工具栏高度，滚过一个工具栏高度就归零。跟"实际位置"而不是跟手势进度，
      // 是为了让内容位移只由滚动决定 —— 否则程序化滚动后避让突然归零，内容
      // 会凭空跳一下，出现"点不到的浮层/找不到的条目"。
      final pixels = notification.metrics.pixels;
      _pixels.value = pixels;
      // 靠近顶部**无条件显示**（手感来源 `FlSQLite_Viewer` 的
      // `_handleTableSelectorScroll`：`offset < 0` 时直接收回进度）：
      // 只要内容回到停泊区那一带，浮层就露出来——拖到一半停住、再往上挪一点，
      // 也能立刻看到它在回来，而不是"必须滚到顶"或"必须累够 192"。
      // 这里用**动画**而不是直接赋值，避免"滚到一半突然整块跳出来"。
      if (pixels < _dockExtent) {
        _settleTo(0);
        return false;
      }
      final delta = notification.scrollDelta ?? 0;
      if (delta.abs() < 0.5) return false;
      if (delta > 0) {
        _direction = 1;
        _setProgress(_progress + delta / 96);
      } else {
        _direction = -1;
        final distance = -delta;
        final revealDistance = pixels <= 0 ? 160 : 128;
        // **不再要求累计够 192**：一向上回滚，浮层就跟着手指按距离淡回来
        // （"往上挪一点就见它回来一点"）。原来的门槛会让回滚的前 192dp
        // 完全没反应，看起来就像"动画被打断了"。
        _setProgress(_progress - distance / revealDistance);
      }
    } else if (notification is ScrollEndNotification) {
      if (_direction > 0 && _progress >= 0.25) {
        _settleTo(1);
      } else if (_direction < 0 && _progress <= 0.8) {
        _settleTo(0);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // 收起后 `Opacity` 已经降到 0（完全看不见），所以不再额外套 `IgnorePointer`：
    // 那会在顶部留下一条"看不见、点不到、却仍然占着布局"的死区。
    final toolbar = Material(
      // `MaterialType.transparency` 只把水波纹收进这一层、并负责圆角裁切：它不画
      // 底色，所以浮层没有"整条工具区背景"（需求 §3.4）；水波纹落在透明 Material
      // 上，也不会再出现"文字淡出、背景残留"。
      type: MaterialType.transparency,
      child: Opacity(
        opacity: _opacity,
        child: Transform.scale(
          alignment: Alignment.topCenter,
          scale: 1 - 0.2 * _progress,
          child: KeyedSubtree(
            key: const ValueKey('explore-toolbar'),
            // `_dockKey` 挂在工具栏最外侧（不含额外内边距）→ 量到的就是这个
            // 工具栏真实占的高度，正是停泊区要留出的距离。
            child: KeyedSubtree(key: _dockKey, child: widget.toolbar),
          ),
        ),
      ),
    );
    return Stack(children: [
      NotificationListener<ScrollMetricsNotification>(
        onNotification: _onScrollMetrics,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: AnimatedBuilder(
            animation: Listenable.merge([_settle, _pixels]),
            // 只重建这一层 Padding：内容子树是 `child` 实例，不跟着重建。
            child: widget.child,
            builder: (context, child) => Padding(
              padding: EdgeInsets.only(top: _dockPadding),
              child: child,
            ),
          ),
        ),
      ),
      Positioned(left: 0, right: 0, top: 0, child: toolbar),
    ]);
  }
}

class _EntryMenu extends StatefulWidget {
  const _EntryMenu(
      {required this.title,
      required this.options,
      required this.selectedId,
      this.floatingStyle = false,
      required this.onSelected});
  final String title;
  final List<ExploreOption> options;
  final String? selectedId;
  final bool floatingStyle;
  final ValueChanged<String> onSelected;
  @override
  State<_EntryMenu> createState() => _EntryMenuState();
}

class _EntryMenuState extends State<_EntryMenu> {
  /// 反查 state 用的 key，只弹出菜单而已。
  ///
  /// ⚠️ 两条约束缺一不可：
  ///
  /// 1. **必须是 State 的 `final` 字段**（不能写成 getter）：`GlobalKey` 一旦每次
  ///    build 都新建，跨帧就不再是同一把，`currentState` 恒为 `null`、菜单永远弹不
  ///    出来（实测踩过）。
  /// 2. **每个实例各自一把**（不能 `static const` 共用）：探索页用 keep-alive
  ///    同时挂着多个源的 pane，各源的 `_EntryMenu` 会同时存在于树上，共用一把
  ///    `GlobalKey` 时第二个及以后的 `PopupMenuButton` 注册失败被整棵丢弃
  ///    ⇒ **入口按钮在新切过去的源上直接消失**（实测报错：`the second time a
  ///    key is seen, the previous … build scope unexpectedly does not contain
  ///    that widget`）。
  final GlobalKey<PopupMenuButtonState<String>> _buttonKey =
      GlobalKey<PopupMenuButtonState<String>>();
  bool _open = false;
  bool _pressed = false;

  @override
  void didUpdateWidget(covariant _EntryMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换入口 / 榜期后菜单内容变了，把它收起来，避免停在半开状态。
    if (oldWidget.selectedId != widget.selectedId) _open = false;
  }

  void _setOpen(bool value) {
    if (mounted && _open != value) setState(() => _open = value);
  }

  void _setPressed(bool value) {
    if (mounted && _pressed != value) setState(() => _pressed = value);
  }

  /// 胶囊自己的 `InkWell` 负责点击与水波纹，弹出菜单仍由 `PopupMenuButton`
  /// 提供（菜单锚点、定位与 `MediaQuery` 适配都不变）。
  void _openMenu() => _buttonKey.currentState?.showButtonMenu();

  IconData _optionIcon(String id) => switch (id.split('.').last) {
        'home' => Icons.auto_awesome_outlined,
        'latest' || 'recent' => Icons.update_rounded,
        'week' || 'mv_w' || 'popular-week' || 'D7' => Icons.date_range_outlined,
        'random' => Icons.shuffle_rounded,
        'collections' => Icons.collections_bookmark_outlined,
        'popular' => Icons.local_fire_department_outlined,
        'mv_t' ||
        'popular-today' ||
        'H24' ||
        'yesterday' =>
          Icons.today_outlined,
        'mv_m' ||
        'popular-month' ||
        'D30' ||
        'month' ||
        'year' =>
          Icons.calendar_month_outlined,
        _ => Icons.leaderboard_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final selected =
        widget.options.where((o) => o.id == widget.selectedId).firstOrNull ??
            widget.options.first;
    final colors = Theme.of(context).colorScheme;
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
    final menuWidth = (largeText ? 288.0 : 240.0)
        .clamp(0.0, MediaQuery.sizeOf(context).width - 32);
    // 这里挂的是**反查 state 用的实例级 `GlobalKey`**（见 `_buttonKey`）：
    // 胶囊自己的 `InkWell` 负责点击，`_openMenu` 靠它拿到 state 弹菜单。
    // 测试定位请用 `find.byType(PopupMenuButton<String>)`。
    return PopupMenuButton<String>(
      key: _buttonKey,
      tooltip: '切换${selected.label}',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 4),
      requestFocus: true,
      borderRadius: BorderRadius.circular(14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.6)),
      ),
      color: colors.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shadowColor: colors.shadow.withValues(alpha: 0.18),
      elevation: 8,
      clipBehavior: Clip.antiAlias,
      constraints: BoxConstraints.tightFor(width: menuWidth),
      menuPadding: const EdgeInsets.all(8),
      popUpAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              duration: Duration(milliseconds: 220),
              curve: Curves.easeOutQuad,
              reverseCurve: Curves.easeInCubic,
            ),
      onOpened: () => _setOpen(true),
      onCanceled: () => _setOpen(false),
      onSelected: (id) {
        _setOpen(false);
        if (id != selected.id) widget.onSelected(id);
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          height: 36,
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Text(widget.title,
              style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w500)),
        ),
        for (final option in widget.options)
          PopupMenuItem<String>(
            key: ValueKey('explore-entry-option-${option.id}'),
            value: option.id,
            padding: EdgeInsets.zero,
            child: Semantics(
              selected: option.id == selected.id,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 52),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: option.id == selected.id
                        ? colors.secondaryContainer
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: option.id == selected.id
                            ? colors.surface.withValues(alpha: 0.65)
                            : colors.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(_optionIcon(option.id),
                          size: 19,
                          color: option.id == selected.id
                              ? colors.onSecondaryContainer
                              : colors.onSurfaceVariant),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(option.label,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: option.id == selected.id
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: option.id == selected.id
                                  ? colors.onSecondaryContainer
                                  : colors.onSurface)),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 20,
                      child: option.id == selected.id
                          ? Icon(Icons.check_circle_rounded,
                              size: 20, color: colors.primary)
                          : null,
                    ),
                  ]),
                ),
              ),
            ),
          ),
      ],
      child: _FloatingCapsule(
        floating: widget.floatingStyle,
        selected: widget.floatingStyle && _open,
        // 展开期间保持轻反馈（非浮层外观下这就是原来的 `secondaryContainer`）。
        pressed: _pressed || _open,
        semanticLabel: selected.label,
        onTap: _openMenu,
        onTapState: _setPressed,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Text(selected.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.primary)),
          ),
          const SizedBox(width: 4),
          AnimatedRotation(
            turns: _open ? 0.5 : 0,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 220),
            child: Icon(Icons.expand_more, size: 18, color: colors.primary),
          ),
        ]),
      ),
    );
  }
}

/// 浮层里的**胶囊**：左侧「推荐 / 榜单 / 分类」与右侧入口按钮共用一套外观。
///
/// **背景画在普通 `Container` 上**（不是 `Ink.decoration`）—— ink 装饰由祖先
/// `Material` 的 ink layer 绘制，浮层淡出时容易留下"文字没了、色块还在"的残影；
/// 普通容器处在浮层的绘制子树内，`Opacity` 一定管得住。
/// 水波纹交给内层透明 `Material` + `InkWell`，圆角裁切与热区一并解决。
class _FloatingCapsule extends StatelessWidget {
  const _FloatingCapsule({
    super.key,
    required this.child,
    required this.selected,
    required this.onTap,
    this.floating = true,
    this.pressed = false,
    this.semanticLabel,
    this.onTapState,
  });

  final Widget child;
  final bool selected;

  /// 浮层外观（圆角 20 / 最小高度 32 / 未选中透明）。`false` 时回到内嵌外观
  /// （圆角 12 / 最小高度 40 / 有底色），供页面里非浮层的入口复用。
  final bool floating;
  final bool pressed;
  final String? semanticLabel;
  final VoidCallback onTap;
  final ValueChanged<bool>? onTapState;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 浮层态：未选中**完全透明**、选中 `secondaryContainer`，按下/展开时只给
    // 一层很轻的 `primary` 叠色 —— 不再有"恒亮的浅紫块"。
    final background = floating
        ? (selected
            ? colors.secondaryContainer
            : pressed
                ? colors.primary.withValues(alpha: 0.10)
                : Colors.transparent)
        : (selected || pressed ? colors.secondaryContainer : colors.surfaceContainer);
    final foreground = floating
        ? (selected ? colors.onSecondaryContainer : colors.onSurfaceVariant)
        : (selected ? colors.onSecondaryContainer : colors.onSurface);
    final radius = BorderRadius.circular(floating ? 20 : 12);
    return Semantics(
      selected: selected,
      button: true,
      label: semanticLabel,
      child: Material(
        // 透明 Material 只负责"接住水波纹 + 按圆角裁切"，不画任何底色。
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onTapDown: onTapState == null ? null : (_) => onTapState!(true),
          onTapUp: onTapState == null ? null : (_) => onTapState!(false),
          onTapCancel: onTapState == null ? null : () => onTapState!(false),
          borderRadius: radius,
          child: DecoratedBox(
            decoration: BoxDecoration(color: background, borderRadius: radius),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: floating ? 32 : 40,
                maxWidth: floating ? 220 : double.infinity,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: floating ? 6 : 8,
                ),
                child: DefaultTextStyle(
                  style: TextStyle(
                    fontSize: floating ? 13 : 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: foreground,
                  ),
                  child: Center(widthFactor: 1, heightFactor: 1, child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExploreFeed extends StatefulWidget {
  const _ExploreFeed(
      {super.key,
      required this.registry,
      required this.descriptor,
      required this.entry,
      required this.active,
      required this.onContextChanged,
      required this.options});
  final ExploreRegistry registry;
  final ExploreSourceDescriptor descriptor;
  final ExploreEntry entry;
  final bool active;
  final VoidCallback onContextChanged;
  final ExploreOptions options;
  @override
  State<_ExploreFeed> createState() => _ExploreFeedState();
}

class _ExploreFeedState extends State<_ExploreFeed> {
  final _scroll = ScrollController();
  final _bookmarks = RecommendationBookmarkController();
  ExploreOverview? _overview;
  // Virtualize individual comics, not entire recommendation sections. A single
  // section can contain dozens of cards whose metadata is expensive to build.
  List<({ExploreSection section, BaseComic? comic, bool header})>
      _overviewRows = [];
  ExploreListController? _controller;
  ExploreListState? _retainedRecommendationState;
  String? _session;
  ExploreError? _error;
  bool _loading = true;
  int _generation = 0;
  late final String? _fingerprint = widget.registry
      .providerOf(widget.descriptor.sourceKey)
      ?.contextFingerprint;
  bool _contextCheckScheduled = false;

  bool get _usesPixivWaterfall =>
      widget.descriptor.sourceKey.toLowerCase() == 'pixiv' &&
      (widget.entry.kind == ExploreSectionKind.recommend ||
          widget.entry.kind == ExploreSectionKind.ranking);

  bool get _contextMatches =>
      _fingerprint ==
          widget.registry
              .providerOf(widget.descriptor.sourceKey)
              ?.contextFingerprint &&
      (!widget.descriptor.requiresLogin ||
          (widget.registry
                  .providerOf(widget.descriptor.sourceKey)
                  ?.isLoggedIn ??
              false));

  void _contextChanged() {
    if (_contextCheckScheduled) return;
    _contextCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _contextCheckScheduled = false;
      if (mounted) widget.onContextChanged();
    });
  }

  void _onScroll() {
    final controller = _controller;
    if (_loading ||
        !widget.active ||
        controller == null ||
        !_scroll.hasClients) {
      return;
    }
    if (!_contextMatches) {
      _contextChanged();
      return;
    }
    final state = controller.state;
    if (!state.loading &&
        !state.loadingMore &&
        state.moreError == null &&
        state.hasMore &&
        _scroll.position.extentAfter < 320) {
      unawaited(controller.loadMore());
    }
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    App.displaySettingsVersion.addListener(_onDisplaySettingsChanged);
    // Capture identity before the first request, rather than after its completion.
    final identity = _fingerprint;
    assert(identity != null);
    unawaited(_load());
  }

  void _onDisplaySettingsChanged() {
    if (mounted &&
        (_usesPixivWaterfall ||
            widget.entry.kind == ExploreSectionKind.recommend)) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant _ExploreFeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.options != oldWidget.options) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
      unawaited(_load());
    }
  }

  void _release() {
    _controller?.releaseSession();
    _controller?.dispose();
    _controller = null;
    widget.registry.releaseSession(_session ?? '');
    _session = null;
  }

  @override
  void dispose() {
    _generation++;
    App.displaySettingsVersion.removeListener(_onDisplaySettingsChanged);
    _bookmarks.dispose();
    _release();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool preserveContent = false}) async {
    if (!_contextMatches) {
      _contextChanged();
      return;
    }
    final generation = ++_generation;
    final retainContent = preserveContent &&
        _usesPixivWaterfall &&
        (_overview != null ||
            (_controller?.state.items.isNotEmpty ?? false) ||
            _retainedRecommendationState != null);
    final retainedState = retainContent
        ? _retainedRecommendationState ?? _controller?.state
        : null;
    _bookmarks.reset(preserveConfirmed: retainContent);
    _release();
    setState(() {
      _loading = true;
      _error = null;
      _retainedRecommendationState = retainedState;
      if (!retainContent) {
        _overview = null;
        _overviewRows = [];
      }
    });
    _session = widget.registry.createSession();
    final sourceKey = widget.descriptor.sourceKey;
    if (widget.entry.kind == ExploreSectionKind.recommend &&
        !widget.entry.singlePage) {
      final result = await widget.registry.loadOverview(ExploreRequest(
          sessionId: _session!,
          sourceKey: sourceKey,
          entryId: widget.entry.id));
      if (!mounted || generation != _generation) return;
      if (!_contextMatches) {
        _contextChanged();
        return;
      }
      if (result.errorOrNull?.code != ExploreErrorCode.unsupported) {
        if (retainContent && result.errorOrNull != null) {
          setState(() => _loading = false);
          _showRefreshError(result.errorOrNull!);
          return;
        }
        _bookmarks.reset();
        setState(() {
          _overview = result.dataOrNull;
          _overviewRows = [
            for (final section
                in _overview?.sections ?? <ExploreSection>[]) ...[
              (section: section, comic: null, header: true),
              if (section.error != null || section.items.isEmpty)
                (section: section, comic: null, header: false)
              else
                for (final comic in section.items)
                  (section: section, comic: comic, header: false),
            ],
          ];
          _error = result.errorOrNull;
          _retainedRecommendationState = null;
          _loading = false;
        });
        return;
      }
    }
    final controller = ExploreListController(
        registry: widget.registry,
        sourceKey: sourceKey,
        entryId: widget.entry.id,
        sessionId: _session!,
        blockingResolver: buildExploreBlockingResolver());
    _controller = controller;
    controller.addListener(() {
      if (mounted && generation == _generation) setState(() {});
    });
    await controller.load(options: widget.options, clearCategory: true);
    if (!mounted || generation != _generation) return;
    if (!_contextMatches) {
      _contextChanged();
      return;
    }
    // Restore the previously loaded range in the new session before replacing
    // the visible grid. Old continuation handles belong to the released session.
    final targetCount = retainedState?.items.length ?? 0;
    while (controller.state.error == null &&
        controller.state.moreError == null &&
        controller.state.hasMore &&
        controller.state.items.length < targetCount) {
      final previousCount = controller.state.items.length;
      await controller.loadMore();
      if (!mounted || generation != _generation) return;
      if (!_contextMatches) {
        _contextChanged();
        return;
      }
      if (controller.state.items.length <= previousCount) break;
    }
    final refreshError = controller.state.error ?? controller.state.moreError;
    if (retainContent && refreshError != null) {
      setState(() => _loading = false);
      _showRefreshError(refreshError);
      return;
    }
    _bookmarks.reset();
    setState(() {
      _overview = null;
      _overviewRows = [];
      _retainedRecommendationState = null;
      _loading = false;
    });
  }

  void _showRefreshError(ExploreError error) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('刷新失败：${error.message}')));
  }

  Widget _message(Widget child) => CustomScrollView(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [SliverFillRemaining(hasScrollBody: false, child: child)]);

  @override
  Widget build(BuildContext context) {
    if (!_contextMatches) {
      _contextChanged();
      return const Center(child: CircularProgressIndicator());
    }
    final source = ComicSource.find(widget.descriptor.sourceKey);
    final error = _retainedRecommendationState == null
        ? _error ?? _controller?.state.error
        : null;
    Widget body;
    if (_loading && _overview == null && _retainedRecommendationState == null) {
      body = _message(const Center(child: CircularProgressIndicator()));
    } else if (error != null) {
      body = _message(exploreErrorView(error: error.message, onRetry: _load));
    } else if (source == null) {
      body = _message(const Center(child: Text('源未注册')));
    } else if (_overview != null) {
      final sections = _overview!.sections;
      body = sections.isEmpty
          ? _message(const Center(child: Text('没有推荐内容')))
          : _usesPixivWaterfall
              ? _recommendOverview(source, sections)
              : ListView.builder(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  itemCount: _overviewRows.length,
                  itemBuilder: (_, i) {
                    final row = _overviewRows[i];
                    if (row.header) return _sectionHeader(row.section);
                    final comic = row.comic;
                    return Padding(
                      padding: EdgeInsets.only(
                          bottom: comic == null ||
                                  identical(comic, row.section.items.last)
                              ? 8
                              : 0),
                      child: comic == null
                          ? _sectionMessage(row.section)
                          : _comic(source, comic),
                    );
                  });
    } else {
      final state = _retainedRecommendationState ??
          _controller?.state ??
          const ExploreListState();
      final items = state.items;
      body = items.isEmpty && !state.hasMore
          ? _message(const Center(child: Text('没有内容')))
          : _usesPixivWaterfall
              ? _recommendList(source, state)
              : ListView.builder(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  itemCount: items.length + 1,
                  itemBuilder: (_, i) => i == items.length
                      ? _footer(state)
                      : _comic(source, items[i].comic));
    }
    return Column(children: [
      if (widget.entry.kind == ExploreSectionKind.ranking &&
          widget.descriptor.sourceKey == 'ehentai')
        exploreHintBar(context, widget.entry.description),
      Expanded(child: RefreshIndicator(onRefresh: _load, child: body)),
    ]);
  }

  List<({BaseComic comic, String? blockedBy})> _recommendItems(
      Iterable<BaseComic> comics) {
    final resolver = buildExploreBlockingResolver();
    final hide = readHideBlockedComics();
    final result = <({BaseComic comic, String? blockedBy})>[];
    for (final comic in comics) {
      final blockedBy = resolver?.call(comic);
      if (!hide || blockedBy == null) {
        result.add((comic: comic, blockedBy: blockedBy));
      }
    }
    return result;
  }

  Widget _recommendGrid(
      ComicSource source, List<({BaseComic comic, String? blockedBy})> items) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      sliver: SliverMasonryGrid.count(
        crossAxisCount: normalizeIllustWaterfallColumns(
            appdata.settings[illustWaterfallColumnsSettingIndex]),
        childCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return OnlineRecommendationCard(
            key: ValueKey((source.key, item.comic.id)),
            source: source,
            comic: item.comic,
            blockedBy: item.blockedBy,
            bookmarks: _bookmarks,
            actionsEnabled: !_loading,
            onAccountsChanged: () {
              widget.onContextChanged();
              if (_contextMatches) {
                unawaited(_load(preserveContent: true));
              }
            },
            onDataRefresh: () => _load(preserveContent: true),
            detailSessionBuilder: () => _detailSession(
              source,
              items.map((item) => item.comic).toList(),
              paginated: _overview == null,
            ),
          );
        },
      ),
    );
  }

  PixivDetailSession _detailSession(ComicSource source, List<BaseComic> items,
      {required bool paginated}) {
    final generation = _generation;
    final controller = _controller;
    final account = pixivDetailAccountIdentity(source);
    return PixivDetailSession(
      scope: PixivDetailScope.recommendation,
      entries: items.map((item) => onlinePixivDetailEntry(source, item)),
      hasMore: paginated && (controller?.state.hasMore ?? false),
      ownerIsCurrent: () =>
          mounted &&
          generation == _generation &&
          _contextMatches &&
          account == pixivDetailAccountIdentity(source) &&
          (!paginated || identical(controller, _controller)),
      loadMore: paginated && controller != null
          ? () async {
              await controller.loadMore();
              final state = controller.state;
              if (state.moreError != null) {
                throw StateError(state.moreError!.message);
              }
              return PixivDetailBatch(
                _recommendItems(state.items.map((item) => item.comic))
                    .map((item) => onlinePixivDetailEntry(source, item.comic)),
                hasMore: state.hasMore,
              );
            }
          : null,
    );
  }

  Widget _recommendOverview(ComicSource source, List<ExploreSection> sections) {
    return CustomScrollView(
      key: const Key('explore-recommend-scroll'),
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 4)),
        for (final section in sections) ...[
          SliverToBoxAdapter(child: _sectionHeader(section)),
          if (section.error != null || section.items.isEmpty)
            SliverToBoxAdapter(child: _sectionMessage(section))
          else
            _recommendGrid(source, _recommendItems(section.items)),
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
    );
  }

  Widget _recommendList(ComicSource source, ExploreListState state) {
    return CustomScrollView(
      key: const Key('explore-recommend-scroll'),
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 4)),
        _recommendGrid(
            source, _recommendItems(state.items.map((item) => item.comic))),
        SliverToBoxAdapter(child: _footer(state)),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
    );
  }

  Widget _comic(ComicSource source, BaseComic comic) {
    final blockedBy = buildExploreBlockingResolver()?.call(comic);
    if (blockedBy != null && readHideBlockedComics()) {
      return const SizedBox.shrink();
    }
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: OnlineComicListItem(
            source: source,
            comic: comic,
            onTap: source.key != 'pixiv'
                ? null
                : () async {
                    final section = _overview?.sections
                        .where((section) =>
                            section.items.any((item) => item.id == comic.id))
                        .firstOrNull;
                    final comics = section?.items ??
                        _controller?.state.items
                            .map((item) => item.comic)
                            .toList() ??
                        [comic];
                    await openOnlineComic(context, source, comic,
                        detailSession: _detailSession(
                            source,
                            _recommendItems(comics)
                                .map((item) => item.comic)
                                .toList(),
                            paginated: section == null));
                    if (mounted && _contextMatches) {
                      await _load(preserveContent: true);
                    }
                  },
            highlighted: blockedBy != null,
            trailing: blockedBy == null ? null : Text('已屏蔽：$blockedBy')));
  }

  Widget _sectionHeader(ExploreSection section) {
    return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
        child: Row(children: [
          Expanded(
              child: Text(section.title,
                  style: Theme.of(context).textTheme.titleMedium)),
          if (section.moreEntryId != null)
            TextButton(
                onPressed: () {
                  Navigator.of(context).push(AppPageRoute(
                      builder: (_) => ExploreResultPage(
                          sourceKey: widget.descriptor.sourceKey,
                          entryId: section.moreEntryId!,
                          category: section.moreTarget ??
                              ExploreCategoryTarget(
                                  kind: 'section', value: section.id),
                          categoryId: section.id,
                          title: section.title)));
                },
                child: const Text('查看更多')),
        ]));
  }

  Widget _sectionMessage(ExploreSection section) {
    if (section.error != null) {
      return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(child: Text(section.error!.message)),
            TextButton(onPressed: _load, child: const Text('重试'))
          ]));
    }
    return const Padding(padding: EdgeInsets.all(16), child: Text('暂无内容'));
  }

  Widget _footer(ExploreListState state) {
    if (state.loadingMore) {
      return const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()));
    }
    final error = _retainedRecommendationState == null
        ? state.moreError
        : _controller?.state.error ?? _controller?.state.moreError;
    if (error != null || state.hasMore) {
      final restart = _retainedRecommendationState != null ||
          error?.code == ExploreErrorCode.expiredContinuation ||
          !state.hasMore;
      return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            if (error != null) Text(error.message),
            OutlinedButton(
                onPressed: _loading
                    ? null
                    : restart
                        ? () => _load(
                            preserveContent:
                                _retainedRecommendationState != null)
                        : _controller!.loadMore,
                child: Text(restart
                    ? '从头刷新'
                    : error != null
                        ? '重试'
                        : '加载更多')),
          ]));
    }
    return const SizedBox(height: 16);
  }
}
