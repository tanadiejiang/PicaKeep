/// 可嵌入探索页的分类目录，沿用原项目的分组标题与可换行圆角按钮。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/explore/explore_bindings.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_registry.dart';
import 'package:picakeep/pages/explore/explore_common.dart';
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
  final _directories = <String, ExploreDirectory>{};
  final _errors = <String, ExploreError>{};
  final _loading = <String>{};
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
    super.dispose();
  }

  void _reset() {
    _generation++;
    _sessionRegistry?.releaseSession(_sessionId ?? '');
    _sessionId = null;
    _sessionRegistry = null;
    _directories.clear();
    _errors.clear();
    _loading.clear();
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
    final entries = _entries;
    final children = <Widget>[];
    void addBox(Widget child) => children.add(SliverToBoxAdapter(child: child));
    final onSelectEntry = widget.onSelectEntry;
    if (widget.entryId == null) {
      addBox(_groupTitle(context, descriptor.name));
      if (onSelectEntry != null) {
        final ranking =
            descriptor.entriesOf(ExploreSectionKind.ranking).firstOrNull;
        final recommend = descriptor
            .entriesOf(ExploreSectionKind.recommend)
            .where((entry) => entry.availableAsTab)
            .firstOrNull;
        addBox(Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (ranking != null)
                _categoryButton(context,
                    label: '排行榜', onPressed: () => onSelectEntry(ranking)),
              if (recommend != null)
                _categoryButton(context,
                    label: '推荐', onPressed: () => onSelectEntry(recommend)),
            ],
          ),
        ));
      }
    }
    if (entries.isEmpty) {
      addBox(const Padding(
        padding: EdgeInsets.all(24),
        child: Text('该源没有分类目录'),
      ));
    }
    for (final entry in entries) {
      final directory = _directories[entry.id];
      final error = _errors[entry.id];
      if (_loading.contains(entry.id) && directory == null) {
        addBox(Padding(
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
        addBox(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            Expanded(
                child: Text(error?.message ?? '${entry.label}目录暂不可用，请稍后重试')),
            TextButton(
                onPressed: () => _loadEntry(entry), child: const Text('重试')),
          ]),
        ));
      }
      for (final group in directory?.groups ?? const <ExploreCategoryGroup>[]) {
        children.add(_CategoryGroup(
          key: ValueKey(
              '${widget.sourceKey}/${entry.id}/${group.id}/$_fingerprint'),
          group: group,
          onOpen: (item) => _openItem(entry, item),
        ));
      }
    }
    return RefreshIndicator(
      onRefresh: _loadAll,
      child: CustomScrollView(
        key: PageStorageKey(
            'category/${widget.sourceKey}/${widget.entryId ?? 'all'}'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 4)),
          ...children,
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
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
    ElevatedButton(
      style: ElevatedButton.styleFrom(
        elevation: 1,
        // Keep the original soft, raised category buttons, with enough seed
        // color to remain visibly themed under Material 3's neutral surfaces.
        backgroundColor: Color.alphaBlend(
          Theme.of(context).colorScheme.primaryContainer.withValues(alpha: .55),
          Theme.of(context).colorScheme.surfaceContainerLow,
        ),
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        textStyle: textStyle,
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed: onPressed,
      child: Text(label),
    );

class _CategoryGroup extends StatefulWidget {
  const _CategoryGroup({super.key, required this.group, required this.onOpen});

  final ExploreCategoryGroup group;
  final ValueChanged<ExploreCategoryItem> onOpen;

  @override
  State<_CategoryGroup> createState() => _CategoryGroupState();
}

class _CategoryGroupState extends State<_CategoryGroup> {
  static const _pageSize = 50;
  String _filter = '';
  int _offset = 0;
  Object? _labelContext;
  final _labels = <ExploreCategoryItem, String>{};
  List<ExploreCategoryItem>? _matches;
  Object? _rowContext;
  ThemeData? _rowTheme;
  List<List<({ExploreCategoryItem item, String label, double width})>> _rows =
      [];
  Widget? _buttonRowsSliver;

  @override
  void didUpdateWidget(covariant _CategoryGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group != widget.group) _invalidateLabels();
  }

  void _invalidateLabels() {
    _labels.clear();
    _matches = null;
    _rowContext = null;
    _buttonRowsSliver = null;
  }

  String _label(ExploreCategoryItem item) {
    return _labels.putIfAbsent(item, () {
      if (!widget.group.isSearch ||
          Localizations.localeOf(context).languageCode != 'zh') {
        return item.label;
      }
      return lookupTagTranslation(
              item.label, item.groupId.isEmpty ? 'tags' : item.groupId)
          .displayText;
    });
  }

  void _updateRows(
      double width,
      ThemeData theme,
      TextStyle style,
      TextScaler scaler,
      TextDirection direction,
      Locale locale,
      List<ExploreCategoryItem> matches,
      int offset) {
    // ThemeData equality compares the whole theme. Scrolling calls this for
    // each group, so use identity; unchanged text styles can reuse measurements.
    if (!identical(_rowTheme, theme)) {
      _rowTheme = theme;
      _buttonRowsSliver = null;
    }
    final signature =
        (width, style, scaler, direction, locale, matches, offset);
    if (_rowContext == signature) return;
    _rowContext = signature;
    _buttonRowsSliver = null;
    _rows = [];
    var row = <({ExploreCategoryItem item, String label, double width})>[];
    var usedWidth = 0.0;
    final painter = TextPainter(
        textDirection: direction, textScaler: scaler, locale: locale);
    for (final item in matches.skip(offset).take(_pageSize)) {
      final label = _label(item);
      painter.text = TextSpan(text: label, style: style);
      painter.layout();
      // Reserve the same 16dp padding on each side as the real button. Ceil
      // fractional text widths so a label never wraps due to rounding alone.
      final itemWidth = (painter.width.ceilToDouble() + 32).clamp(0.0, width);
      if (row.isNotEmpty && usedWidth + 12 + itemWidth > width) {
        _rows.add(row);
        row = [];
        usedWidth = 0;
      }
      usedWidth += (row.isEmpty ? 0 : 12) + itemWidth;
      row.add((item: item, label: label, width: itemWidth));
    }
    painter.dispose();
    if (row.isNotEmpty) _rows.add(row);
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final locale = Localizations.localeOf(context);
    final labelContext = (locale, tagTranslations, tagTranslationsReady);
    if (_labelContext != labelContext) {
      _labelContext = labelContext;
      _invalidateLabels();
    }
    final query = _filter.trim().toLowerCase();
    final matches = _matches ??= query.isEmpty
        ? group.items
        : group.items
            .where(
              (item) =>
                  item.label.toLowerCase().contains(query) ||
                  _label(item).toLowerCase().contains(query),
            )
            .toList(growable: false);
    final offset = _offset < matches.length ? _offset : 0;
    final theme = Theme.of(context);
    var style = (theme.elevatedButtonTheme.style?.textStyle
            ?.resolve(const <WidgetState>{}) ??
        theme.textTheme.labelLarge)!;
    if (MediaQuery.boldTextOf(context)) {
      style = style.copyWith(fontWeight: FontWeight.bold);
    }
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    // Only this small header stays mounted to retain text editing/focus state.
    // Buttons below are materialized by visual row, never as a 50-button Wrap.
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: _groupTitle(context, group.title)),
          if (matches.length > _pageSize)
            IconButton(
              tooltip: '换一批${group.title}',
              onPressed: () => setState(
                  () => _offset = (offset + _pageSize) % matches.length),
              icon: const Icon(Icons.refresh),
            ),
          const SizedBox(width: 8),
        ]),
        if (group.items.length > _pageSize)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              decoration: InputDecoration(
                hintText: '筛选${group.title}',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: const OutlineInputBorder(),
                helperText: '共 ${matches.length} 项，每次显示最多 $_pageSize 项',
              ),
              onChanged: (value) => setState(() {
                _filter = value;
                _offset = 0;
                _matches = null;
              }),
            ),
          ),
        if (group.isSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text('点击标签搜索', style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
    return SliverMainAxisGroup(slivers: [
      SliverToBoxAdapter(child: header),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        sliver: SliverLayoutBuilder(builder: (context, constraints) {
          _updateRows(constraints.crossAxisExtent, theme, style, scaler,
              direction, locale, matches, offset);
          if (matches.isEmpty) {
            return const SliverToBoxAdapter(child: Text('没有匹配的分类'));
          }
          // SliverLayoutBuilder runs as scroll constraints change. Reuse the
          // delegate so scrolling does not rebuild every already-visible row.
          return _buttonRowsSliver ??= SliverList.builder(
            itemCount: _rows.length,
            itemBuilder: (context, index) => Padding(
              padding:
                  EdgeInsets.only(bottom: index == _rows.length - 1 ? 0 : 8),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (var i = 0; i < _rows[index].length; i++) ...[
                  if (i != 0) const SizedBox(width: 12),
                  SizedBox(
                    width: _rows[index][i].width,
                    child: _categoryButton(
                      context,
                      textStyle: style,
                      label: _rows[index][i].label,
                      onPressed: _rows[index][i].item.route == null
                          ? null
                          : () => widget.onOpen(_rows[index][i].item),
                    ),
                  ),
                ],
              ]),
            ),
          );
        }),
      ),
    ]);
  }
}
