/// 探索分类目录页。
///
/// 独立的可滚动页面（**不放在无限榜单列表底部**）：顶部是分组筛选（大量标签时
/// 先选分组），下面是该组的分类入口网格。目录缓存仅本会话，失败可重试。
library;

import 'package:flutter/material.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/explore/explore_bindings.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/pages/explore/explore_common.dart';
import 'package:picakeep/pages/explore/explore_result_page.dart';

class ExploreCategoryPage extends StatefulWidget {
  const ExploreCategoryPage({
    super.key,
    required this.sourceKey,
    required this.entryId,
    this.title,
  });

  final String sourceKey;
  final String entryId;
  final String? title;

  @override
  State<ExploreCategoryPage> createState() => _ExploreCategoryPageState();
}

class _ExploreCategoryPageState extends State<ExploreCategoryPage> {
  String _sessionId = '';
  ExploreDirectory? _directory;
  ExploreError? _error;
  bool _loading = false;
  String? _activeGroupId;
  String _filter = '';

  ComicSource? get _source => ComicSource.find(widget.sourceKey);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    ExploreBindings.instance?.registry.releaseSession(_sessionId);
    super.dispose();
  }

  Future<void> _load() async {
    final registry = ExploreBindings.instance?.registry;
    if (registry == null || !mounted) {
      setState(() => _error =
          const ExploreError(ExploreErrorCode.unsupported, '探索能力尚未初始化'));
      return;
    }
    final descriptor = registry.describe(widget.sourceKey);
    final entry = descriptor?.entryById(widget.entryId);
    if (descriptor == null || entry == null) {
      setState(() => _error = ExploreError(
          ExploreErrorCode.invalidArgument, '该源没有入口：${widget.entryId}'));
      return;
    }
    if (descriptor.requiresLogin && !(_source?.isLoggedIn ?? false)) {
      setState(() {
        _loading = false;
        _error = null;
        _directory = null;
      });
      return;
    }
    if (_sessionId.isEmpty) {
      _sessionId = registry.createSession();
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    final result = await registry.loadDirectory(ExploreRequest(
      sessionId: _sessionId,
      sourceKey: widget.sourceKey,
      entryId: entry.id,
    ));
    if (!mounted) return;

    final error = result.errorOrNull;
    if (error != null) {
      setState(() {
        _loading = false;
        _error = error;
      });
      return;
    }
    final directory = result.dataOrNull!;
    setState(() {
      _loading = false;
      _directory = directory;
      _activeGroupId =
          directory.groups.isEmpty ? null : directory.groups.first.id;
      _filter = '';
    });
  }

  void _openItem(ExploreCategoryItem item) {
    final route = item.route;
    if (route == null) return;
    Navigator.of(context).push(AppPageRoute(
      builder: (_) => ExploreResultPage(
        sourceKey: widget.sourceKey,
        entryId: widget.entryId,
        category: route,
        categoryId: item.id,
        title: item.label,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final registry = ExploreBindings.instance?.registry;
    final descriptor = registry?.describe(widget.sourceKey);
    final entry = descriptor?.entryById(widget.entryId);
    final needsLogin =
        (descriptor?.requiresLogin ?? true) && !(_source?.isLoggedIn ?? false);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? entry?.label ?? '分类'),
        actions: [
          IconButton(
            tooltip: '刷新目录',
            onPressed: needsLogin ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(descriptor, entry, needsLogin),
    );
  }

  Widget _buildBody(
    ExploreSourceDescriptor? descriptor,
    ExploreEntry? entry,
    bool needsLogin,
  ) {
    if (_error != null) {
      return exploreErrorView(error: _error!.message, onRetry: _load);
    }
    if (descriptor == null || entry == null) {
      return const Center(child: Text('该入口不可用'));
    }
    if (needsLogin) {
      return exploreLoginRequiredView(
        sourceName: descriptor.name,
        onManageAccounts: () async {
          await showExploreAccountsPage(context);
          if (!mounted) return;
          ExploreBindings.instance?.refreshContext();
          await _load();
        },
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final directory = _directory;
    if (directory == null) {
      return const Center(child: Text('目录为空'));
    }
    if (directory.groups.isEmpty) {
      // 翻译表未就绪只影响标签目录：明确提示可重试，不伪装成"没有分类"。
      return exploreErrorView(
        error: entry.kind == ExploreSectionKind.category &&
                entry.id.contains('tag')
            ? '标签目录尚未就绪（翻译数据未加载），可稍后重试'
            : '站点未返回任何分类',
        onRetry: _load,
      );
    }

    final isSearch = directory.groups.any((group) => group.isSearch);
    final activeGroup = _activeGroupId == null
        ? directory.groups.first
        : directory.groups.firstWhere(
            (group) => group.id == _activeGroupId,
            orElse: () => directory.groups.first,
          );
    final items = _filter.isEmpty
        ? activeGroup.items
        : activeGroup.items
            .where((item) =>
                item.label.toLowerCase().contains(_filter.toLowerCase()))
            .toList();

    return Column(
      children: [
        // 分组筛选放在列表之前，大量标签可先选组再筛。
        if (directory.groups.length > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                for (final group in directory.groups)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(group.title),
                      selected: group.id == activeGroup.id,
                      onSelected: (_) =>
                          setState(() => _activeGroupId = group.id),
                    ),
                  ),
              ],
            ),
          ),
        if (activeGroup.items.length > 12)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.filter_alt_outlined),
                hintText: '筛选',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _filter = value),
            ),
          ),
        if (isSearch) exploreHintBar(context, '这里发送标签原始词作为搜索，不是原生分类'),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('没有匹配的分类'))
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 180,
                    mainAxisExtent: 48,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return OutlinedButton(
                      onPressed:
                          item.route == null ? null : () => _openItem(item),
                      child: Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
