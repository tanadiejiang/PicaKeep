/// 可嵌入探索页的分类目录，沿用原项目的分组标题与可换行圆角按钮。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/explore/explore_bindings.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_registry.dart';
import 'package:picakeep/foundation/explore/providers/jm_explore_provider.dart'
    show JmExploreEntries;
import 'package:picakeep/foundation/explore/providers/picacg_explore_provider.dart'
    show PicacgExploreEntries;
import 'package:picakeep/pages/explore/explore_common.dart';
import 'package:picakeep/pages/explore/explore_category_button.dart';
import 'package:picakeep/pages/explore/explore_category_label_metrics.dart';
import 'package:picakeep/pages/explore/explore_result_page.dart';
import 'package:picakeep/tools/tags_translation.dart';

class ExploreCategoryPanel extends StatefulWidget {
  const ExploreCategoryPanel({
    super.key,
    required this.sourceKey,
    this.entryId,
    this.onSelectEntry,
  });

  final String sourceKey;

  /// 独立目录页可只显示一个入口；探索首页不传，直接显示当前源全部目录。
  final String? entryId;

  /// 首页把「排行榜 / 推荐」快捷按钮接回当前源相应页签。
  final ValueChanged<ExploreEntry>? onSelectEntry;

  @override
  State<ExploreCategoryPanel> createState() => _ExploreCategoryPanelState();
}

class _ExploreCategoryPanelState extends State<ExploreCategoryPanel> {
  final _rowCache = _CategoryRowCache();
  final _directories = <String, ExploreDirectory>{};
  final _errors = <String, ExploreError>{};
  final _loading = <String>{};
  final _groups = <String, _CategoryGroupData>{};
  ExploreRegistry? _sessionRegistry;
  String? _sessionId;
  String? _fingerprint;
  int _generation = 0;
  bool _contextReloadScheduled = false;

  ExploreRegistry? get _registry => ExploreBindings.instance?.registry;
  ExploreSourceDescriptor? get _descriptor =>
      _registry?.describe(widget.sourceKey);
  bool get _needsLogin =>
      (_descriptor?.requiresLogin ?? true) &&
      !(_registry?.providerOf(widget.sourceKey)?.isLoggedIn ?? false);
  List<ExploreEntry> get _entries =>
      (widget.entryId == null
              ? _descriptor?.entriesOf(ExploreSectionKind.category)
              : _descriptor?.entries)
          ?.where(
              (entry) => widget.entryId == null || entry.id == widget.entryId)
          .toList(growable: false) ??
      const <ExploreEntry>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadAll());
    });
  }

  @override
  void didUpdateWidget(covariant ExploreCategoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceKey != widget.sourceKey ||
        oldWidget.entryId != widget.entryId) {
      _reset();
      unawaited(_loadAll());
    }
  }

  @override
  void dispose() {
    _generation++;
    _sessionRegistry?.releaseSession(_sessionId ?? '');
    _disposeGroups();
    super.dispose();
  }

  void _disposeGroups() {
    for (final group in _groups.values) {
      group.dispose();
    }
    _groups.clear();
  }

  void _reset() {
    _generation++;
    _sessionRegistry?.releaseSession(_sessionId ?? '');
    _sessionId = null;
    _sessionRegistry = null;
    _directories.clear();
    _errors.clear();
    _loading.clear();
    _disposeGroups();
  }

  Future<void> _loadAll() async {
    if (!mounted) return;
    final registry = _registry;
    final fingerprint =
        registry?.providerOf(widget.sourceKey)?.contextFingerprint;
    if (!identical(registry, _sessionRegistry) || fingerprint != _fingerprint) {
      _reset();
      _fingerprint = fingerprint;
    }
    if (registry == null || _descriptor == null || _needsLogin) {
      setState(() {});
      return;
    }
    _sessionRegistry = registry;
    if (_sessionId == null || !registry.isSessionAlive(_sessionId!)) {
      _sessionId = registry.createSession();
    }
    // 目录互相独立：例如标签翻译表不可用时，原生分类仍可直接浏览。
    await Future.wait(_entries.map(_loadEntry));
  }

  Future<void> _loadEntry(ExploreEntry entry) async {
    final registry = _sessionRegistry;
    final sessionId = _sessionId;
    if (registry == null || sessionId == null || !mounted || _needsLogin) {
      return;
    }
    final generation = _generation;
    final fingerprint = _fingerprint;
    setState(() {
      _loading.add(entry.id);
      _errors.remove(entry.id);
    });
    ExploreResult<ExploreDirectory> result;
    try {
      result = await registry.loadDirectory(ExploreRequest(
        sessionId: sessionId,
        sourceKey: widget.sourceKey,
        entryId: entry.id,
      ));
    } catch (_) {
      result = const ExploreFailure(
        ExploreError(ExploreErrorCode.network, '目录加载失败，请重试'),
      );
    }
    if (!mounted || generation != _generation) return;
    if (registry.providerOf(widget.sourceKey)?.contextFingerprint !=
            fingerprint ||
        _needsLogin) {
      await _loadAll();
      return;
    }
    setState(() {
      _loading.remove(entry.id);
      final error = result.errorOrNull;
      if (error != null) {
        _errors[entry.id] = error;
      } else {
        _directories[entry.id] = result.dataOrNull!;
      }
    });
  }

  void _openItem(ExploreEntry entry, ExploreCategoryItem item) {
    final route = item.route;
    if (route == null) return;
    Navigator.of(context).push(AppPageRoute(
      builder: (_) => ExploreResultPage(
        sourceKey: widget.sourceKey,
        entryId: entry.id,
        category: route,
        categoryId: item.id,
        title: item.label,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final descriptor = _descriptor;
    if (_registry == null || descriptor == null) {
      return exploreErrorView(error: '分类目录尚未初始化', onRetry: _loadAll);
    }
    if (_needsLogin) {
      return exploreLoginRequiredView(
        sourceName: descriptor.name,
        onManageAccounts: () async {
          await showExploreAccountsPage(context);
          if (!mounted) return;
          ExploreBindings.instance?.refreshContext();
          await _loadAll();
        },
      );
    }
    final fingerprint =
        _registry?.providerOf(widget.sourceKey)?.contextFingerprint;
    if (_fingerprint != null &&
        (!identical(_registry, _sessionRegistry) ||
            fingerprint != _fingerprint)) {
      // 保活目录在账号/站点变化后的首帧即隐藏旧内容，不把旧账号目录带过去。
      if (!_contextReloadScheduled) {
        _contextReloadScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _contextReloadScheduled = false;
          if (mounted) unawaited(_loadAll());
        });
      }
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _loadAll,
      // Box constraints remain unchanged while scrolling. A SliverLayoutBuilder
      // per group instead invokes a build callback on every scroll frame.
      child: LayoutBuilder(
        builder: (context, constraints) =>
            _buildList(context, descriptor, constraints.maxWidth),
      ),
    );
  }

  Widget _buildList(
      BuildContext context, ExploreSourceDescriptor descriptor, double width) {
    final entries = _entries;
    final rows = <_CategoryListRow>[];
    void add(String id, WidgetBuilder builder) =>
        rows.add(_CategoryListRow(id, builder));
    add('top', (_) => const SizedBox(height: 4));
    final onSelectEntry = widget.onSelectEntry;
    if (widget.entryId == null) {
      add('source', (context) => _groupTitle(context, descriptor.name));
      if (onSelectEntry != null) {
        final ranking =
            descriptor.entriesOf(ExploreSectionKind.ranking).firstOrNull;
        final recommendations = descriptor
            .entriesOf(ExploreSectionKind.recommend)
            .where((entry) => entry.availableAsTab);
        final shortcutEntryId = switch (widget.sourceKey) {
          'jm' => JmExploreEntries.week,
          'picacg' => PicacgExploreEntries.collections,
          _ => null,
        };
        final recommend = shortcutEntryId == null
            ? recommendations.firstOrNull
            : recommendations
                .where((entry) => entry.id == shortcutEntryId)
                .firstOrNull;
        add(
            'shortcuts',
            (context) => Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Wrap(spacing: 12, runSpacing: 8, children: [
                    if (ranking != null)
                      _categoryButton(context,
                          label: '排行榜',
                          onPressed: () => onSelectEntry(ranking)),
                    if (recommend != null)
                      _categoryButton(context,
                          label: widget.sourceKey == 'jm' ? '每周推荐' : '推荐',
                          onPressed: () => onSelectEntry(recommend)),
                  ]),
                ));
      }
    }
    if (entries.isEmpty) {
      add(
          'empty',
          (_) => const Padding(
                padding: EdgeInsets.all(24),
                child: Text('该源没有分类目录'),
              ));
    }
    final currentGroups = <String>{};
    for (final entry in entries) {
      final directory = _directories[entry.id];
      final error = _errors[entry.id];
      if (_loading.contains(entry.id) && directory == null) {
        add(
            '${entry.id}/loading',
            (_) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Row(children: [
                    const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 12),
                    Expanded(child: Text('正在加载${entry.label}…')),
                  ]),
                ));
      }
      if (error != null || (directory != null && directory.isEmpty)) {
        add(
            '${entry.id}/error',
            (_) => Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(children: [
                    Expanded(
                        child: Text(
                            error?.message ?? '${entry.label}目录暂不可用，请稍后重试')),
                    TextButton(
                        onPressed: () => _loadEntry(entry),
                        child: const Text('重试')),
                  ]),
                ));
      }
      for (final group in directory?.groups ?? const <ExploreCategoryGroup>[]) {
        final key = '${widget.sourceKey}/${entry.id}/${group.id}/$_fingerprint';
        currentGroups.add(key);
        final data = _groups.putIfAbsent(key, () => _CategoryGroupData(group));
        data.update(group, context, (width - 32).clamp(0.0, double.infinity));
        add('$key/header', (context) => _buildGroupHeader(context, data));
        if (data.rows.isEmpty) {
          add(
              '$key/empty',
              (_) => const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text('没有匹配的分类'),
                  ));
        }
        for (var index = 0; index < data.rows.length; index++) {
          final row = data.rows[index];
          final isLast = index == data.rows.length - 1;
          final style = data.style;
          add(
              '$key/row/$index',
              (context) => Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, isLast ? 16 : 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < row.length; i++) ...[
                          if (i != 0) const SizedBox(width: 12),
                          SizedBox(
                            width: row[i].width,
                            child: _categoryButton(context,
                                textStyle: style,
                                label: row[i].label,
                                onPressed: row[i].item.route == null
                                    ? null
                                    : () => _openItem(entry, row[i].item)),
                          ),
                        ],
                      ],
                    ),
                  ));
        }
      }
    }
    for (final key in _groups.keys.toList(growable: false)) {
      if (!currentGroups.contains(key)) _groups.remove(key)!.dispose();
    }
    add('bottom', (_) => const SizedBox(height: 24));
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].key: i};
    return CustomScrollView(
      key: PageStorageKey(
          'category/${widget.sourceKey}/${widget.entryId ?? 'all'}'),
      physics: const AlwaysScrollableScrollPhysics(),
      // Roughly three button rows of prefetch per edge keep new rows ready
      // without updating a large offscreen semantics tree on every scroll tick.
      cacheExtent: 160,
      slivers: [
        // A single delegate also recycles offscreen group headers and avoids
        // retaining one materialized button row for every offscreen group.
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => rows[index].build(context, _rowCache),
            childCount: rows.length,
            findChildIndexCallback: (key) => indices[key],
          ),
        ),
      ],
    );
  }

  Widget _buildGroupHeader(BuildContext context, _CategoryGroupData data) {
    final group = data.group;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: _groupTitle(context, group.title)),
          if (data.matches.length > _CategoryGroupData.pageSize)
            IconButton(
              tooltip: '换一批${group.title}',
              onPressed: () => setState(data.nextPage),
              icon: const Icon(Icons.refresh),
            ),
          const SizedBox(width: 8),
        ]),
        if (group.items.length > _CategoryGroupData.pageSize)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: data.filterController,
              focusNode: data.focusNode,
              decoration: InputDecoration(
                hintText: '筛选${group.title}',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: const OutlineInputBorder(),
                helperText: '共 ${data.matches.length} 项，每次显示最多 '
                    '${_CategoryGroupData.pageSize} 项',
              ),
              onChanged: (_) => setState(data.filterChanged),
            ),
          ),
        if (group.isSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text('点击标签搜索', style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }
}

Widget _groupTitle(BuildContext context, String title) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Text(title, style: Theme.of(context).textTheme.titleLarge),
    );

Widget _categoryButton(
  BuildContext context, {
  required String label,
  required VoidCallback? onPressed,
  TextStyle? textStyle,
}) =>
    ExploreCategoryButton(
      label: label,
      onPressed: onPressed,
      textStyle: textStyle,
    );

/// Editing and measurement state outlives recycled group headers and rows.
class _CategoryGroupData {
  _CategoryGroupData(this.group);

  static const pageSize = 50;
  ExploreCategoryGroup group;
  final filterController = TextEditingController();
  final focusNode = FocusNode();
  int _offset = 0;
  Object? _labelContext;
  final _labels = <ExploreCategoryItem, String>{};
  List<ExploreCategoryItem>? _matches;
  Object? _rowContext;
  late TextStyle style;
  List<List<({ExploreCategoryItem item, String label, double width})>> rows =
      [];

  List<ExploreCategoryItem> get matches => _matches!;

  void dispose() {
    filterController.dispose();
    focusNode.dispose();
  }

  void filterChanged() {
    _offset = 0;
    _matches = null;
  }

  void nextPage() {
    _offset = (_offset + pageSize) % matches.length;
  }

  void _invalidateLabels() {
    _labels.clear();
    _matches = null;
    _rowContext = null;
  }

  String _label(ExploreCategoryItem item, Locale locale) {
    return _labels.putIfAbsent(item, () {
      if (!group.isSearch || locale.languageCode != 'zh') return item.label;
      return lookupTagTranslation(
              item.label, item.groupId.isEmpty ? 'tags' : item.groupId)
          .displayText;
    });
  }

  void update(
      ExploreCategoryGroup nextGroup, BuildContext context, double width) {
    if (!identical(group, nextGroup)) {
      group = nextGroup;
      _invalidateLabels();
    }
    final locale = Localizations.localeOf(context);
    final labelContext = (locale, tagTranslations, tagTranslationsReady);
    if (_labelContext != labelContext) {
      _labelContext = labelContext;
      _invalidateLabels();
    }
    final query = filterController.text.trim().toLowerCase();
    _matches ??= query.isEmpty
        ? group.items
        : group.items
            .where((item) =>
                item.label.toLowerCase().contains(query) ||
                _label(item, locale).toLowerCase().contains(query))
            .toList(growable: false);
    if (_offset >= matches.length) _offset = 0;
    style = ExploreCategoryButton.labelStyleOf(context);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final signature =
        (width, style, scaler, direction, locale, matches, _offset);
    if (_rowContext == signature) return;
    _rowContext = signature;
    rows = [];
    var row = <({ExploreCategoryItem item, String label, double width})>[];
    var usedWidth = 0.0;
    final visible =
        matches.skip(_offset).take(pageSize).toList(growable: false);
    final labels =
        visible.map((item) => _label(item, locale)).toList(growable: false);
    final labelWidths = measureCategoryLabelWidths(labels,
        style: style,
        textScaler: scaler,
        textDirection: direction,
        locale: locale);
    for (var index = 0; index < visible.length; index++) {
      final item = visible[index];
      final label = labels[index];
      // Match button padding and round up to avoid accidental line breaks.
      final itemWidth =
          (labelWidths[index].ceilToDouble() + 32).clamp(0.0, width);
      if (row.isNotEmpty && usedWidth + 12 + itemWidth > width) {
        rows.add(row);
        row = [];
        usedWidth = 0;
      }
      usedWidth += (row.isEmpty ? 0 : 12) + itemWidth;
      row.add((item: item, label: label, width: itemWidth));
    }
    if (row.isNotEmpty) rows.add(row);
  }
}

/// A lightweight descriptor; unvisited rows do not create button widgets.
class _CategoryListRow {
  _CategoryListRow(String id, this.builder) : key = ValueKey<String>(id);

  final ValueKey<String> key;
  final WidgetBuilder builder;
  Widget? _widget;

  Widget build(BuildContext context, _CategoryRowCache cache) =>
      _widget ??= KeyedSubtree(
        key: key,
        child: _CachedCategoryRow(cache: cache, child: builder(context)),
      );
}

/// Recently created rows survive short reverse scrolls in the sliver's cache.
/// Unlike cacheExtent, kept-alive rows do not enter layout, paint or semantics.
class _CategoryRowCache {
  static const capacity = 40;
  final _rows = <_CachedCategoryRowState>{};
  final _pendingRelease = <_CachedCategoryRowState>{};
  bool _releaseScheduled = false;

  void retain(_CachedCategoryRowState row) {
    _rows.add(row);
    while (_rows.length > capacity) {
      final oldest = _rows.first;
      _rows.remove(oldest);
      _pendingRelease.add(oldest);
    }
    if (_pendingRelease.isNotEmpty && !_releaseScheduled) {
      _releaseScheduled = true;
      // A cold layout at a restored offset can create more than capacity rows.
      // Let their initial AutomaticKeepAlive post-frame callbacks run before
      // withdrawing handles, or they may apply invalid parent data out of turn.
      scheduleMicrotask(() {
        _releaseScheduled = false;
        final pending = _pendingRelease.toList(growable: false);
        _pendingRelease.clear();
        for (final row in pending) {
          if (row.mounted) row.release();
        }
      });
    }
  }

  void forget(_CachedCategoryRowState row) {
    _rows.remove(row);
    _pendingRelease.remove(row);
  }
}

class _CachedCategoryRow extends StatefulWidget {
  const _CachedCategoryRow({required this.cache, required this.child});

  final _CategoryRowCache cache;
  final Widget child;

  @override
  State<_CachedCategoryRow> createState() => _CachedCategoryRowState();
}

class _CachedCategoryRowState extends State<_CachedCategoryRow>
    with AutomaticKeepAliveClientMixin {
  bool _retained = true;

  @override
  bool get wantKeepAlive => _retained;

  @override
  void initState() {
    super.initState();
    widget.cache.retain(this);
  }

  void release() {
    _retained = false;
    updateKeepAlive();
  }

  @override
  void dispose() {
    widget.cache.forget(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
