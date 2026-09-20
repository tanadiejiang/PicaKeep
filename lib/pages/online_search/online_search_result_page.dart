import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/foundation/untranslated_tags/untranslated_tag_coordinator.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';
import 'package:picakeep/network/res.dart';
import 'package:uuid/uuid.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/nhentai_network/models.dart';
import 'package:picakeep/tools/tags_translation.dart';

import 'online_search_logic.dart';

/// Converts only the tags already present in a search brief into observations.
/// Search must not issue detail requests just to fill the untranslated-tag
/// store, and pagination must reuse the caller's operation id.
@visibleForTesting
List<UntranslatedTagObservation> buildOnlineSearchTagObservations({
  required String sourceKey,
  required Iterable<BaseComic> items,
  required String operationId,
}) {
  final source = sourceKey.trim().toLowerCase();
  if (source != 'ehentai' && source != 'nhentai') {
    return const <UntranslatedTagObservation>[];
  }
  final observations = <UntranslatedTagObservation>[];
  for (final item in items) {
    final tags = item.tags;
    if (tags.isEmpty) continue;
    if (source == 'ehentai' && item is! EhGalleryBrief) continue;
    if (source == 'nhentai' && item is! NhentaiComicBrief) continue;
    observations.add(
      UntranslatedTagObservation(
        source: source,
        comicId: item.id,
        flat: tags,
        operationId: operationId,
        context: 'online-search',
      ),
    );
  }
  return observations;
}

/// 首次请求前把调用方传入的 option 规范化到该源声明的合法取值。
///
/// - 源没有搜索声明、或声明了空选项列表:原样保留传入值,不臆造选项;
/// - 传入值精确命中某个 [SearchOption.value]:原样保留(空串是 EH/NH 的合法值,
///   不能用 `isEmpty` 当成"未选择");
/// - 未命中:回落到该源 [SearchPageData.defaultOption]。
///
/// 结果页的请求与弹窗高亮共用这一个值,因此不存在"界面正确但请求仍在用旧值"的
/// 分叉;详情页标签直跳等传入空串的调用点也在这里被统一纠正。
@visibleForTesting
String resolveSearchOptionForSource(ComicSource source, String option) {
  final data = source.searchPageData;
  if (data == null || data.searchOptions.isEmpty) {
    return option;
  }
  for (final item in data.searchOptions) {
    if (item.value == option) {
      return option;
    }
  }
  return data.defaultOption;
}

class OnlineSearchResultPage extends StatefulWidget {
  const OnlineSearchResultPage({
    super.key,
    required this.source,
    required this.keyword,
    required this.option,
  });

  final ComicSource source;
  final String keyword;
  final String option;

  @override
  State<OnlineSearchResultPage> createState() => _OnlineSearchResultPageState();
}

class _OnlineSearchResultPageState extends State<OnlineSearchResultPage> {
  /// 宽屏阈值:>=400dp 显示两个图标,<400dp 折叠为"更多"菜单。
  /// 依据原项目 search_result_page.dart 的同一阈值。
  static const double _wideLayoutThreshold = 400;

  final _logic = OnlineSearchLogic();
  final _scrollController = ScrollController();
  late final _keywordController = TextEditingController(text: widget.keyword);
  final _items = <BaseComic>[];

  /// 已提交查询(与输入框草稿 [_keywordController] 有意分离)。
  late String _keyword = widget.keyword;
  late ComicSource _source;
  late String _option;

  int _page = 1;
  int? _maxPage;
  bool _loading = false;
  String? _error;
  int _searchGeneration = 0;
  String _searchOperationId = '';

  /// 弹窗进行中标记:只用于避免桌面连击叠开,不参与请求串行。
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    _source = widget.source;
    _option = resolveSearchOptionForSource(_source, widget.option);
    _scrollController.addListener(_handleScroll);
    _search();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _keywordController.dispose();
    super.dispose();
  }

  bool get _canChangeOption =>
      _source.searchPageData?.searchOptions.isNotEmpty ?? false;

  void _handleScroll() {
    if (_loading || _items.isEmpty) return;
    if (_maxPage != null && _page >= _maxPage!) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 420) {
      _search(loadMore: true);
    }
  }

  /// 新一次查询回到列表顶部。
  ///
  /// 调用点已经处于 loading 状态、且 items 已清空,滚动监听不会因此触发加载
  /// 下一页;不依赖 post-frame 回调,避免旧回调重置较新查询的滚动位置。
  void _resetScrollToTop() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels == 0) return;
    _scrollController.jumpTo(0);
  }

  Future<void> _search({bool loadMore = false}) async {
    if (loadMore && _loading) return;

    // 快照本次请求的全部归属,await 之后不再读取可变的页面配置。
    final source = _source;
    final keyword = _keyword;
    final option = _option;

    final int generation;
    final String operationId;
    final int nextPage;
    if (loadMore) {
      generation = _searchGeneration;
      operationId = _searchOperationId;
      nextPage = _page + 1;
    } else {
      _searchGeneration++;
      _searchOperationId = 'online-search-${const Uuid().v4()}';
      generation = _searchGeneration;
      operationId = _searchOperationId;
      nextPage = 1;
    }

    setState(() {
      _loading = true;
      _error = null;
      if (!loadMore) {
        _items.clear();
        _maxPage = null;
        _page = 1;
      }
    });
    if (!loadMore) {
      _resetScrollToTop();
    }

    final Res<List<BaseComic>> res;
    try {
      res = await _logic.search(
        source: source,
        keyword: keyword,
        page: nextPage,
        option: option,
      );
    } catch (error) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
      return;
    }

    if (!mounted || generation != _searchGeneration) return;

    if (res.error) {
      // 错误必须在外层终止:失败 Res 的 data getter 会抛异常。
      setState(() {
        _loading = false;
        _error = res.errorMessageWithoutNull;
      });
      return;
    }

    final items = res.dataOrNull ?? const <BaseComic>[];
    setState(() {
      _loading = false;
      _page = nextPage;
      final sub = res.subData;
      _maxPage = sub is int ? sub : int.tryParse('$sub');
      _items.addAll(items);
    });
    unawaited(
      _observeSearchResults(
        items,
        sourceKey: source.key,
        operationId: operationId,
      ),
    );
  }

  void _submitSearch(String keyword) {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    _logic.addSearchHistory(kw);
    setState(() {
      _keyword = kw;
      _page = 1;
      _maxPage = null;
      _items.clear();
      _error = null;
    });
    unawaited(_search());
  }

  Future<void> _observeSearchResults(
    Iterable<BaseComic> items, {
    required String sourceKey,
    required String operationId,
  }) async {
    final observations = buildOnlineSearchTagObservations(
      sourceKey: sourceKey,
      items: items,
      operationId: operationId,
    );
    try {
      if (!tagTranslationsReady) {
        try {
          await loadTagTranslations();
        } catch (_) {
          // The coordinator retains observations while the table is unavailable.
        }
      }
      if (tagTranslationsReady) {
        await UntranslatedTagCoordinator.instance.flushPending();
      }
      if (observations.isEmpty) return;
      await UntranslatedTagCoordinator.instance.observeBatch(observations);
    } catch (_) {
      // Tag collection is side data and must not affect search rendering.
    }
  }

  /// 切换源:弹窗只改临时选择,确认后原地应用新源并按同一已提交关键词重搜。
  Future<void> _changeSource() async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    try {
      FocusScope.of(context).unfocus();
      final keys = _logic.searchableSources.map((e) => e.key).toList();
      final picked = await showDialog<String>(
        context: context,
        builder: (_) => _SourcePickerDialog(
          sourceKeys: keys,
          currentKey: _source.key,
        ),
      );
      if (!mounted || picked == null) return;

      // 弹窗关闭后重新校验:期间源可能被移除或登录态失效。
      final target = ComicSource.find(picked);
      if (target == null || target.searchPageData == null) {
        _showMessage('该源当前不可搜索');
        return;
      }
      if (!target.isLoggedIn) {
        _showMessage('该源未登录');
        return;
      }
      if (target.key == _source.key) return;

      setState(() {
        _source = target;
        _option = resolveSearchOptionForSource(
          target,
          target.searchPageData!.defaultOption,
        );
      });
      unawaited(_search());
    } finally {
      _dialogOpen = false;
    }
  }

  /// 搜索选项:弹窗内只改临时选择,确认且值变化才重搜。
  Future<void> _changeOption() async {
    if (_dialogOpen) return;
    final data = _source.searchPageData;
    if (data == null || data.searchOptions.isEmpty) return;
    _dialogOpen = true;
    try {
      FocusScope.of(context).unfocus();
      final picked = await showDialog<String>(
        context: context,
        builder: (_) => _SearchOptionPickerDialog(
          options: data.searchOptions,
          current: _option,
        ),
      );
      if (!mounted || picked == null) return;

      // 关闭后确认来源未变、返回值仍属于当前源的选项列表。
      final currentData = _source.searchPageData;
      if (currentData == null ||
          !currentData.searchOptions.any((e) => e.value == picked)) {
        return;
      }
      if (picked == _option) return;

      setState(() => _option = picked);
      unawaited(_search());
    } finally {
      _dialogOpen = false;
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _openComic(BaseComic comic) {
    final builder = _source.comicPageBuilder;
    if (builder == null) return;
    Navigator.of(context).push(
      AppPageRoute(builder: (_) => builder(comic)),
    );
  }

  /// 构造封面 imageProvider。
  /// - 源未提供 [imageHeadersBuilder](picacg / jm)→ 走裸 `NetworkImage`,与改造前完全一致。
  /// - 钩子返回 `null` 或空 header → 同样回退 `NetworkImage`。
  /// - 钩子返回非空 header → 走带 header 的 `StreamImageProvider`,header 透传到图片请求。
  ImageProvider _coverProvider(BaseComic comic) {
    final builder = _source.imageHeadersBuilder;
    if (builder == null) {
      return NetworkImage(comic.cover);
    }
    final headers = builder(comic);
    if (headers == null || headers.isEmpty) {
      return NetworkImage(comic.cover);
    }
    return StreamImageProvider.withProgress(
      () => OnlineImageManager.instance.getImage(comic.cover, headers: headers),
      comic.cover,
    );
  }

  List<Widget> _buildActions(bool wideLayout) {
    final canChangeOption = _canChangeOption;
    if (wideLayout) {
      return [
        IconButton(
          icon: const Icon(Icons.dataset_outlined),
          tooltip: '切换源',
          onPressed: _changeSource,
        ),
        IconButton(
          icon: const Icon(Icons.tune),
          tooltip: '搜索选项',
          onPressed: canChangeOption ? _changeOption : null,
        ),
      ];
    }
    return [
      PopupMenuButton<int>(
        icon: const Icon(Icons.more_horiz),
        tooltip: '更多',
        onSelected: (value) {
          if (value == 0) {
            unawaited(_changeSource());
          } else {
            unawaited(_changeOption());
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem<int>(
            value: 0,
            child: Row(
              children: [
                Icon(Icons.dataset_outlined, size: 20),
                SizedBox(width: 12),
                Text('切换源'),
              ],
            ),
          ),
          PopupMenuItem<int>(
            value: 1,
            enabled: canChangeOption,
            child: const Row(
              children: [
                Icon(Icons.tune, size: 20),
                SizedBox(width: 12),
                Text('搜索选项'),
              ],
            ),
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wideLayout = constraints.maxWidth >= _wideLayoutThreshold;
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: Container(
              height: 40,
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
              ),
              child: TextField(
                controller: _keywordController,
                textInputAction: TextInputAction.search,
                onSubmitted: _submitSearch,
                decoration: InputDecoration(
                  hintText: '关键词',
                  border: InputBorder.none,
                  // 框内不再放装饰性搜索图标:顶栏已有提交按钮与切源/选项入口,
                  // 重复的放大镜只会挤占输入区。
                  contentPadding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.search, size: 20),
                    onPressed: () => _submitSearch(_keywordController.text),
                  ),
                ),
              ),
            ),
            actions: _buildActions(wideLayout),
          ),
          body: Column(
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(color: colorScheme.error),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _search(),
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: _items.isEmpty && !_loading && _error == null
                    ? const Center(child: Text('无结果'))
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _items.length + (_loading ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index >= _items.length) {
                            return const Padding(
                              padding: EdgeInsets.all(16),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }
                          final comic = _items[index];
                          // 搜索页按源取配置：切源后当前 build 立即用新值，
                          // 无需额外监听（_source 变化一定伴随 setState）。
                          final cardConfig =
                              readSearchComicTileDisplayConfig(_source.key);
                          return SizedBox(
                            height: 164,
                            child: DownloadedComicTile(
                              cardDisplayConfig: cardConfig,
                              name: comic.title,
                              author: resolveSourceAuthors(
                                source: _source.key,
                                flatTags: comic.tags,
                                fallbackAuthor: comic.subTitle,
                              ).join(', '),
                              imagePath: File(''),
                              imageProvider: _coverProvider(comic),
                              type: null,
                              tag: comic.tags,
                              size: displaySourceInfoLine(
                                source: _source.key,
                                comicId: comic.id,
                                description: comic.description,
                                showId: cardConfig.showId,
                              ),
                              onTap: () => _openComic(comic),
                              onLongTap: () {},
                              onSecondaryTap: (_) {},
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 切换源弹窗:列出 registry 全部可搜索源,未登录项置灰不可选。
///
/// 弹窗只持有候选 key 与临时选择;登录态与可搜索性在每次 build 和确认时通过
/// [ComicSource.find] 重新解析,因此弹窗打开期间发生的登录失效不会被快照掩盖。
class _SourcePickerDialog extends StatefulWidget {
  const _SourcePickerDialog({
    required this.sourceKeys,
    required this.currentKey,
  });

  final List<String> sourceKeys;
  final String currentKey;

  @override
  State<_SourcePickerDialog> createState() => _SourcePickerDialogState();
}

class _SourcePickerDialogState extends State<_SourcePickerDialog> {
  late String? _selected = widget.currentKey;
  String? _error;

  ComicSource? _resolve(String key) {
    final source = ComicSource.find(key);
    if (source == null || source.searchPageData == null) return null;
    return source;
  }

  bool _selectable(String key) => _resolve(key)?.isLoggedIn ?? false;

  void _confirm() {
    final key = _selected;
    if (key == null) return;
    final source = _resolve(key);
    if (source == null) {
      setState(() => _error = '该源当前不可搜索');
      return;
    }
    if (!source.isLoggedIn) {
      setState(() => _error = '该源未登录');
      return;
    }
    Navigator.of(context).pop(key);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final anySelectable = widget.sourceKeys.any(_selectable);
    return AlertDialog(
      title: const Text('切换源'),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RadioGroup<String>(
                groupValue: _selected,
                onChanged: (value) {
                  setState(() {
                    _selected = value;
                    _error = null;
                  });
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final key in widget.sourceKeys) _buildSourceTile(key),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Text(
                    _error!,
                    style: TextStyle(color: colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: anySelectable ? _confirm : null,
          child: const Text('确认'),
        ),
      ],
    );
  }

  Widget _buildSourceTile(String key) {
    final source = _resolve(key);
    final loggedIn = source?.isLoggedIn ?? false;
    return RadioListTile<String>(
      value: key,
      enabled: source != null && loggedIn,
      title: Text(source?.name ?? key),
      subtitle: loggedIn ? null : Text(source == null ? '该源当前不可搜索' : '未登录'),
      selected: _selected == key,
    );
  }
}

/// 搜索选项弹窗:当前源的单值选项(四源均为"排序"语义)。
///
/// 空串是 EH/NH 的合法选项,返回 `null` 才表示取消。
class _SearchOptionPickerDialog extends StatefulWidget {
  const _SearchOptionPickerDialog({
    required this.options,
    required this.current,
  });

  final List<SearchOption> options;
  final String current;

  @override
  State<_SearchOptionPickerDialog> createState() =>
      _SearchOptionPickerDialogState();
}

class _SearchOptionPickerDialogState extends State<_SearchOptionPickerDialog> {
  late String _selected = widget.current;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('搜索选项'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('排序', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in widget.options)
                    ChoiceChip(
                      label: Text(option.label),
                      selected: _selected == option.value,
                      onSelected: (_) =>
                          setState(() => _selected = option.value),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('确认'),
        ),
      ],
    );
  }
}
