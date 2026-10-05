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
    return DefaultTabController(
      length: sources.length,
      initialIndex: index,
      child: Column(children: [
        TabBar(
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
      final navigation = Wrap(children: [
        for (final k in kinds)
          Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ChoiceChip(
                label: Text(k.$2),
                selected: kind == k.$1,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                backgroundColor: Colors.transparent,
                selectedColor: Theme.of(context).colorScheme.secondaryContainer,
                side: BorderSide.none,
                onSelected: (_) => _selectKind(k.$1),
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
      return Padding(
        key: const ValueKey('explore-toolbar'),
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
    return _FloatingExploreLayout(toolbar: toolbar, child: content);
  }
}

class _FloatingExploreLayout extends StatefulWidget {
  const _FloatingExploreLayout({required this.toolbar, required this.child});

  final Widget toolbar;
  final Widget child;

  @override
  State<_FloatingExploreLayout> createState() => _FloatingExploreLayoutState();
}

class _FloatingExploreLayoutState extends State<_FloatingExploreLayout>
    with SingleTickerProviderStateMixin {
  late final AnimationController _settle;
  double _progress = 0;
  double _upDistance = 0;
  int _direction = 0;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(() {
        if (mounted) setState(() => _progress = _settle.value);
      });
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _setProgress(double value) {
    final next = value.clamp(0.0, 1.0).toDouble();
    if ((next - _progress).abs() < 0.001) return;
    _settle.stop();
    setState(() => _progress = next);
  }

  void _settleTo(double target) {
    _settle.stop();
    _settle.value = _progress;
    _settle.animateTo(target, curve: Curves.easeOutCubic);
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification &&
        notification.metrics.axis == Axis.vertical) {
      final delta = notification.scrollDelta ?? 0;
      if (delta.abs() < 0.5) return false;
      if (delta > 0) {
        _direction = 1;
        _upDistance = 0;
        _setProgress(_progress + delta / 96);
      } else {
        _direction = -1;
        final distance = -delta;
        _upDistance += distance;
        final revealDistance = notification.metrics.pixels <= 0 ? 160 : 128;
        if (notification.metrics.pixels <= 0 || _upDistance > 192) {
          _setProgress(_progress - distance / revealDistance);
        }
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
    final toolbar = IgnorePointer(
      ignoring: _progress >= 0.98,
      child: Opacity(
        opacity: 1 - _progress,
        child: Transform.scale(
          alignment: Alignment.topCenter,
          scale: 1 - 0.2 * _progress,
          child: widget.toolbar,
        ),
      ),
    );
    return Stack(children: [
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.child,
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
  bool _open = false;

  void _setOpen(bool value) {
    if (mounted && _open != value) setState(() => _open = value);
  }

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
    return PopupMenuButton<String>(
      key: const ValueKey('explore-entry-menu'),
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
      child: Semantics(
        expanded: _open,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: widget.floatingStyle ? 2 : 4),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: widget.floatingStyle ? 32 : 40,
              maxWidth: widget.floatingStyle ? 220 : double.infinity,
            ),
            child: Ink(
              padding: EdgeInsets.symmetric(
                horizontal: widget.floatingStyle ? 10 : 10,
                vertical: widget.floatingStyle ? 6 : 8,
              ),
              decoration: BoxDecoration(
                color: widget.floatingStyle
                    ? colors.secondaryContainer
                    : (_open
                        ? colors.secondaryContainer
                        : colors.surfaceContainer),
                borderRadius:
                    BorderRadius.circular(widget.floatingStyle ? 20 : 12),
              ),
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
                  child:
                      Icon(Icons.expand_more, size: 18, color: colors.primary),
                ),
              ]),
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
