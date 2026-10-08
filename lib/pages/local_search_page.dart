import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/foundation/local_search_cover.dart';
import 'package:picakeep/foundation/local_search_data_source.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/foundation/pixiv_local_detail.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/pages/online_comic/pixiv_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/pixiv_detail_pager.dart';
import 'package:picakeep/foundation/app.dart';

import 'package:picakeep/tools/tags_translation.dart';
import 'package:picakeep/tools/translations.dart';
import 'favorites/local_favorites.dart';
import 'local_comic_detail_page.dart';

export 'package:picakeep/foundation/local_search_data_source.dart'
    show LocalSearchType;

class LocalSearchPage extends StatefulWidget {
  const LocalSearchPage({
    this.searchType = LocalSearchType.all,
    this.initialKeyword = '',
    this.dataSource = const LocalSearchDataSource(),
    this.coverResolver,
    super.key,
  });

  final LocalSearchType searchType;
  final String initialKeyword;
  final LocalSearchDataSource dataSource;
  final LocalSearchCoverResolver? coverResolver;

  @override
  State<LocalSearchPage> createState() => _LocalSearchPageState();
}

class _LocalSearchPageState extends State<LocalSearchPage> {
  final _controller = TextEditingController();
  List<LocalSearchResult> _results = [];
  late LocalSearchType _scope;
  int _searchRevision = 0;
  int _chipsRevision = 0;
  String? _searchError;
  String _lastSubmitted = '';
  List<String> _lastAliases = const [];
  bool _editing = true;
  bool _hasSearched = false;
  bool _isSearching = false;
  List<String> _chips = [];
  bool _chipsReady = false;
  List<String> _suggestions = [];
  bool _tagTranslationsReady = false; // 中文标签翻译表是否加载完毕
  late final LocalSearchCoverResolver _covers;

  @override
  void initState() {
    super.initState();
    _covers = widget.coverResolver ?? LocalSearchCoverResolver();
    App.localDataVersion.addListener(_onCoverSourcesChanged);
    App.serviceConfigVersion.addListener(_onCoverSourcesChanged);
    App.serviceRuntimeVersion.addListener(_onCoverSourcesChanged);
    _scope = widget.searchType;
    _loadChips();
    // 懒加载中文标签翻译表（对齐在线搜索页 _tagsReady 模式）；
    // 加载失败时静默保持 false，不影响英文直配与热门回退
    loadTagTranslations().then((_) {
      if (!mounted) return;
      _tagTranslationsReady = true;
      if (_editing) _updateSuggestions(_controller.text);
    }).catchError((_) {});
    final initialKeyword = widget.initialKeyword.trim();
    if (initialKeyword.isNotEmpty) {
      _controller.text = initialKeyword;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _search(initialKeyword);
        }
      });
    }
  }

  @override
  void dispose() {
    App.localDataVersion.removeListener(_onCoverSourcesChanged);
    App.serviceConfigVersion.removeListener(_onCoverSourcesChanged);
    App.serviceRuntimeVersion.removeListener(_onCoverSourcesChanged);
    _covers.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onCoverSourcesChanged() {
    if (!mounted || _editing || _lastSubmitted.isEmpty) return;
    _search(_lastSubmitted, aliases: _lastAliases);
  }

  Future<void> _loadChips() async {
    final revision = ++_chipsRevision;
    try {
      final chips = await widget.dataSource.collectChips(_scope);
      if (!mounted || revision != _chipsRevision) return;
      setState(() {
        _chips = chips;
        _chipsReady = true;
      });
      if (_editing) _updateSuggestions(_controller.text);
    } catch (_) {
      // Suggestions are optional; a failed suggestion read must not block search.
      if (!mounted || revision != _chipsRevision) return;
      setState(() {
        _chips = [];
        _chipsReady = true;
      });
    }
  }

  void _changeScope(LocalSearchType scope) {
    if (_scope == scope) return;
    final query = _controller.text.trim();
    final aliases = query == _lastSubmitted ? _lastAliases : const <String>[];
    ++_searchRevision;
    _covers.cancelPending();
    setState(() {
      _scope = scope;
      _results = [];
      _suggestions = [];
      _chips = [];
      _chipsReady = false;
      _searchError = null;
      _hasSearched = false;
      _isSearching = false;
      _editing = query.isEmpty;
    });
    _loadChips();
    if (query.isNotEmpty) _search(query, aliases: aliases);
  }

  void _onSearchTextChanged(String value) {
    // Editing or clearing a query also invalidates any in-flight search.
    ++_searchRevision;
    _covers.cancelPending();
    setState(() {
      _editing = true;
      _results = [];
      _hasSearched = false;
      _isSearching = false;
      _searchError = null;
      _suggestions = [];
    });
    _updateSuggestions(value);
  }

  Future<void> _search(String keyword,
      {List<String> aliases = const []}) async {
    final normalizedKeyword = keyword.trim();
    final revision = ++_searchRevision;
    _covers.cancelPending();
    if (normalizedKeyword.isEmpty) {
      _onSearchTextChanged('');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _editing = false;
      _lastSubmitted = normalizedKeyword;
      _lastAliases = List.of(aliases);
      _suggestions = [];
      _searchError = null;
      _isSearching = true;
    });
    try {
      final results = await widget.dataSource.search(
        normalizedKeyword,
        _scope,
        aliases: aliases,
      );
      if (!mounted || revision != _searchRevision) return;
      setState(() {
        _results = results;
        _hasSearched = true;
        _isSearching = false;
      });
    } catch (_) {
      if (!mounted || revision != _searchRevision) return;
      setState(() {
        _results = [];
        _searchError = '读取本地内容失败，请重试';
        _isSearching = false;
      });
    }
  }

  String _formatSize(double? size) {
    if (size == null) return '未知大小'.tl;
    if (size > 1024) return '${(size / 1024).toStringAsFixed(1)}GB';
    return '${size.toStringAsFixed(1)}MB';
  }

  Widget _buildGridTile(LocalSearchResult result) {
    if (result.downloadItem != null) {
      final item = result.downloadItem!;
      return Padding(
        key: ValueKey(('download', item.id, item.fileSystemPath)),
        padding: const EdgeInsets.all(2),
        child: DownloadedComicTile(
          name: item.name,
          author: localSearchAuthor(item),
          imagePath: File(''),
          imageProvider: _covers.providerFor(result),
          optimizeCoverDecode: true,
          type: result.sourceLabel,
          tag: item.tags,
          onTap: () {
            _openResult(result);
          },
          size: _formatSize(item.comicSize),
          onLongTap: () {},
          onSecondaryTap: (_) {},
        ),
      );
    }

    if (result.favoriteItem != null) {
      final favorite = result.favoriteItem!;
      final comic = favorite.comic;
      final localItem = result.localItem;
      return Padding(
        key: ValueKey((
          'favorite',
          comic.type.key,
          comic.target,
          localItem?.id,
          localItem?.fileSystemPath
        )),
        padding: const EdgeInsets.all(2),
        child: DownloadedComicTile(
          name: comic.name,
          author: comic.author,
          imagePath: File(''),
          imageProvider: _covers.providerFor(result),
          optimizeCoverDecode: true,
          type: result.sourceLabel,
          tag: comic.tags,
          onTap: () {
            if (localItem != null) {
              _openResult(result);
              return;
            }
            if (comic.type == FavoriteType.pixiv) {
              _openResult(result);
              return;
            }
            App.pushInner(
                () => LocalFavoritesFolder(folderName: favorite.folder));
          },
          size: localItem != null ? _formatSize(localItem.comicSize) : '未下载'.tl,
          onLongTap: () {},
          onSecondaryTap: (_) {},
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Future<void> _openResult(LocalSearchResult result) async {
    final item = result.downloadItem ?? result.localItem;
    final target = result.favoriteItem?.comic;
    if (item != null && PixivLocalIdentity.fromItem(item) == null) {
      App.pushInner(() => LocalComicDetailPage(comic: item));
      return;
    }
    String keyFor(LocalSearchResult value) {
      final local = value.downloadItem ?? value.localItem;
      return local != null
          ? pixivLocalDetailKey(local)
          : 'favorite:${value.favoriteItem!.folder}:${value.favoriteItem!.comic.target}';
    }

    if (item == null &&
        (target == null ||
            target.type != FavoriteType.pixiv ||
            resolveOnlineTargetSpec(target.target, target.type) == null)) {
      return;
    }
    PixivDetailEntry? entryFor(LocalSearchResult value) {
      final local = value.downloadItem ?? value.localItem;
      if (local != null) {
        final identity = PixivLocalIdentity.fromItem(local);
        if (identity == null) return null;
        return PixivDetailEntry(
          key: keyFor(value),
          comicId: identity.workId ?? local.id,
          localFavoriteFolder: value.favoriteItem?.folder,
          builder: (_) => LocalComicDetailPage(comic: local),
        );
      }
      final favorite = value.favoriteItem;
      if (favorite == null || favorite.comic.type != FavoriteType.pixiv) {
        return null;
      }
      final spec =
          resolveOnlineTargetSpec(favorite.comic.target, FavoriteType.pixiv);
      if (spec == null) return null;
      return PixivDetailEntry(
        key: keyFor(value),
        comicId: spec.id,
        localFavoriteFolder: favorite.folder,
        builder: (_) => PixivComicPageV2(spec.id),
      );
    }

    final session = PixivDetailSession(
      scope: PixivDetailScope.localSearch,
      entries: _results.map(entryFor).whereType<PixivDetailEntry>(),
    );
    try {
      await App.pushInner(
          () => PixivDetailPager(session: session, initialKey: keyFor(result)));
    } finally {
      session.dispose();
    }
  }

  /// 根据输入框内容从已收集的 chips（本地标签 + 作者）中过滤出匹配的建议。
  ///
  /// 输入为空时清空建议；否则按包含匹配（不区分大小写）过滤，
  /// 保留 '作者: ' 前缀的完整条目，结果取前 50 条作为上限，防止建议列表过长。
  /// 本地标签/作者多为日文英文，中文输入通过翻译层（[tags_translation]）逆查
  /// 命中对应英文标签；没有匹配时保留关键词输入，不展示无关建议。
  void _updateSuggestions(String input) {
    // chips（建议数据源）尚未加载完成前不提供建议
    if (!_chipsReady) return;
    final normalizedInput = input.trim();
    if (normalizedInput.isEmpty) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = []);
      return;
    }
    final candidates = _candidatesForInput(normalizedInput);
    setState(() {
      _suggestions = candidates.take(50).toList();
    });
  }

  /// 为输入生成建议候选集（保持 chips 频次顺序）。
  ///
  /// 两类命中：
  /// 1. 直配：chips 条目（'作者: ' 前缀先剥离）包含输入关键词（不区分大小写），
  ///    覆盖英文/日文标签与作者名（含中文作者名/拼音）；
  /// 2. 翻译层（仅当输入含中文且翻译表就绪）：先一次遍历翻译表逆查
  ///    「中文译名包含输入」或「中文分类名展开」命中的英文 key 集合，
  ///    再用该集合一次遍历 chips 匹配（先 O(1) 精确匹配，再包含匹配兜底），
  ///    避免 O(翻译表×chips) 的嵌套全遍历。
  List<String> _candidatesForInput(String input) {
    final keyword = input.toLowerCase();
    final candidates = <String>[];

    // 中文输入才做翻译逆查；英文/日文输入由直配覆盖
    final translatedKeys = <String>{};
    if (_tagTranslationsReady && _isChineseText(input)) {
      // 中文分类名展开：'女性/画师/标签' 等 → 对应 namespace 下全部英文 key
      for (final namespace in tagNamespacesForChineseCategory(input)) {
        tagTranslations[namespace]
            ?.forEach((englishKey, _) => translatedKeys.add(englishKey));
      }
      // 中文译名包含匹配：一次遍历翻译表收集命中英文 key
      for (final table in tagTranslations.entries) {
        for (final entry in table.value.entries) {
          if (entry.value.toLowerCase().contains(keyword)) {
            translatedKeys.add(entry.key);
          }
        }
      }
    }

    for (final chip in _chips) {
      // '作者: ' 前缀只影响展示与点击解前缀，不影响匹配；
      // 作者条目没有翻译层，但始终参与直配（中文作者名/拼音可命中）
      final body =
          chip.startsWith('作者: ') ? chip.substring('作者: '.length).trim() : chip;
      final bodyLower = body.toLowerCase();
      if (bodyLower.contains(keyword)) {
        candidates.add(chip);
        continue;
      }
      // 翻译命中：本地标签包含任一命中英文 key（key 已统一小写）
      if (translatedKeys.isNotEmpty &&
          (translatedKeys.contains(bodyLower) ||
              translatedKeys.any((k) => bodyLower.contains(k)))) {
        candidates.add(chip);
      }
    }
    return candidates;
  }

  /// 输入是否包含中文字符（决定是否启用翻译表逆查）。
  bool _isChineseText(String input) => RegExp(r'[一-鿿]').hasMatch(input);

  /// 构建占满内容区的建议列表（在线搜索样式）。
  ///
  /// 顶栏为「建议」标题 + 关闭按钮，下方 Divider 分隔后是建议 ListView；
  /// 作者条目显示完整条目（含 '作者: ' 前缀），subtitle 标注「作者 / 标签」；
  /// 点击条目：作者条目去掉 '作者: ' 前缀后填入搜索框并立即搜索。
  Widget _buildSuggestionList() {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        SizedBox(
          height: 48,
          child: Row(
            children: [
              const SizedBox(width: 20),
              Text(
                '建议',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: '关闭建议',
                onPressed: () => setState(() => _suggestions = []),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: _suggestions.length,
            itemBuilder: (context, index) {
              final label = _suggestions[index];
              final isAuthor = label.startsWith('作者: ');
              return ListTile(
                dense: true,
                title: Text(label),
                subtitle: Text(
                  isAuthor ? '作者' : '标签',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                onTap: () {
                  // 作者条目去掉 "作者: " 前缀，填入原始作者名以匹配 _matches() 逻辑
                  final query =
                      isAuthor ? label.substring('作者: '.length).trim() : label;
                  _controller.text = query;
                  _controller.selection = TextSelection.fromPosition(
                    TextPosition(offset: query.length),
                  );
                  setState(() => _suggestions = []);
                  // tag 建议附带翻译表别名（跨语言命中：如 milf ↔ 熟女）；
                  // 作者名无翻译层，显式传空别名抑制
                  _search(
                    query,
                    aliases: isAuthor
                        ? const []
                        : (_tagTranslationsReady
                            ? tagAliasesForTag(query)
                            : const []),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildScopeSelector() {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Material(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final scope in LocalSearchType.values)
                    ChoiceChip(
                      key: ValueKey('local-search-scope-${scope.name}'),
                      avatar: Icon(
                          switch (scope) {
                            LocalSearchType.favoritesOnly =>
                              Icons.bookmarks_outlined,
                            LocalSearchType.downloadsOnly =>
                              Icons.download_done_rounded,
                            LocalSearchType.all => Icons.layers_outlined,
                          },
                          size: 18),
                      label: Text(switch (scope) {
                        LocalSearchType.favoritesOnly => '收藏',
                        LocalSearchType.downloadsOnly => '已下载',
                        LocalSearchType.all => '全部',
                      }),
                      selected: _scope == scope,
                      onSelected: (_) => _changeScope(scope),
                      showCheckmark: false,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                switch (_scope) {
                  LocalSearchType.favoritesOnly => '搜索所有本地收藏夹中的作品',
                  LocalSearchType.downloadsOnly => '搜索本地已下载与导入的作品',
                  LocalSearchType.all => '合并搜索本地收藏与已下载，重复作品只显示一次',
                },
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchError() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_searchError!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => _search(_lastSubmitted, aliases: _lastAliases),
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: widget.initialKeyword.trim().isEmpty,
          decoration: InputDecoration(
            hintText: switch (_scope) {
              LocalSearchType.favoritesOnly => '搜索收藏',
              LocalSearchType.downloadsOnly => '搜索已下载',
              LocalSearchType.all => '搜索本地内容',
            },
            border: InputBorder.none,
            prefixIcon: const Icon(Icons.search),
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          onChanged: _onSearchTextChanged,
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              tooltip: '清空搜索',
              icon: const Icon(Icons.clear),
              onPressed: () {
                _controller.clear();
                _onSearchTextChanged('');
              },
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildScopeSelector(),
          Expanded(
            // 输入框有内容且有匹配建议时，建议列表占满内容区（在线搜索模式）；
            // 输入清空或建议清空时，回到正常的搜索结果区
            child: _controller.text.isNotEmpty && _suggestions.isNotEmpty
                ? _buildSuggestionList()
                : _isSearching
                    ? const Center(child: CircularProgressIndicator())
                    : _searchError != null
                        ? _buildSearchError()
                        : !_hasSearched
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.search,
                                      size: 64,
                                      color:
                                          Theme.of(context).colorScheme.outline,
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      _scope == LocalSearchType.favoritesOnly
                                          ? '输入关键词搜索收藏夹漫画'
                                          : _scope ==
                                                  LocalSearchType.downloadsOnly
                                              ? '输入关键词搜索本地已下载漫画'
                                              : '输入关键词搜索本地收藏和下载',
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .outline,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : _results.isEmpty
                                ? const Center(child: Text('未找到匹配的漫画'))
                                : GridView.builder(
                                    key: ValueKey(
                                        'local-search-results-${_scope.name}'),
                                    padding: const EdgeInsets.all(4),
                                    gridDelegate:
                                        SliverGridDelegateWithComics(),
                                    itemCount: _results.length,
                                    itemBuilder: (ctx, i) =>
                                        _buildGridTile(_results[i]),
                                  ),
          ),
        ],
      ),
    );
  }
}
