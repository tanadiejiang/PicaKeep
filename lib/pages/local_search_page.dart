import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_search_core.dart';
import 'package:picakeep/tools/tags_translation.dart';
import 'package:picakeep/tools/translations.dart';
import 'favorites/local_favorites.dart';
import 'local_comic_detail_page.dart';

enum LocalSearchType { favoritesOnly, downloadsOnly, all }

String _localSearchAuthor(DownloadedItem item) {
  if (item is LocalLibraryComicItem) {
    return resolveDownloadedAuthors(item).join(', ');
  }
  return item.subTitle.trim();
}

/// 异步收集所有本地漫画的唯一标签和作者，返回 chip 标签列表。
///
/// 作者条目格式为 `'作者: <name>'`；标签条目使用原始字符串。
/// 结果按出现频次降序排列，作者类在前；显示上限由调用侧 take(50) 控制。
Future<List<String>> _collectLocalChips() async {
  final tagFreq = <String, int>{};
  final authorFreq = <String, int>{};

  // --- 已下载漫画 ---
  final localManager = LocalLibraryManager();
  await localManager.ensureLoaded();
  for (final item in await localManager.getAll()) {
    for (final tag in item.tags) {
      final t = tag.trim();
      if (t.isNotEmpty) tagFreq[t] = (tagFreq[t] ?? 0) + 1;
    }
    final author = _localSearchAuthor(item).trim();
    if (author.isNotEmpty) {
      authorFreq[author] = (authorFreq[author] ?? 0) + 1;
    }
  }

  // --- 收藏漫画 ---
  final favManager = LocalFavoritesManager();
  await favManager.init();
  for (final fav in favManager.allComics()) {
    final comic = fav.comic;
    for (final tag in comic.tags) {
      final t = tag.trim();
      if (t.isNotEmpty) tagFreq[t] = (tagFreq[t] ?? 0) + 1;
    }
    final author = comic.author.trim();
    if (author.isNotEmpty) {
      authorFreq[author] = (authorFreq[author] ?? 0) + 1;
    }
  }

  // 按频次降序排列
  final sortedAuthors = authorFreq.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final sortedTags = tagFreq.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  final chips = <String>[];
  for (final e in sortedAuthors) {
    chips.add('作者: ${e.key}');
  }
  for (final e in sortedTags) {
    chips.add(e.key);
  }
  return chips;
}

class _SearchResult {
  final String title;
  final String author;
  final String sourceLabel;
  final List<String> tags;
  final DownloadedItem? downloadItem;
  final DownloadedItem? localItem;
  final FavoriteItemWithFolderInfo? favoriteItem;

  const _SearchResult({
    required this.title,
    required this.author,
    required this.sourceLabel,
    this.tags = const [],
    this.downloadItem,
    this.localItem,
    this.favoriteItem,
  });
}

class LocalSearchPage extends StatefulWidget {
  const LocalSearchPage({
    this.searchType = LocalSearchType.all,
    this.initialKeyword = '',
    super.key,
  });

  final LocalSearchType searchType;
  final String initialKeyword;

  @override
  State<LocalSearchPage> createState() => _LocalSearchPageState();
}

class _LocalSearchPageState extends State<LocalSearchPage> {
  final _controller = TextEditingController();
  List<_SearchResult> _results = [];
  bool _hasSearched = false;
  bool _isSearching = false;
  List<String> _chips = [];
  bool _chipsReady = false;
  List<String> _suggestions = [];
  bool _tagTranslationsReady = false; // 中文标签翻译表是否加载完毕

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    // 异步加载 chips（不阻塞页面打开）
    Future.microtask(() async {
      final chips = await _collectLocalChips();
      if (mounted) {
        setState(() {
          _chips = chips;
          _chipsReady = true;
        });
        // chips 加载完成后，若输入框已有内容则立即刷新一次建议，避免先输入后加载的间隙
        if (_controller.text.isNotEmpty) _updateSuggestions(_controller.text);
      }
    });
    // 懒加载中文标签翻译表（对齐在线搜索页 _tagsReady 模式）；
    // 加载失败时静默保持 false，不影响英文直配与热门回退
    loadTagTranslations().then((_) {
      if (mounted) setState(() => _tagTranslationsReady = true);
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
    _controller.dispose();
    super.dispose();
  }

  void _onSearchTextChanged(String v) {
    // 对齐在线搜索：输入只更新建议（建议列表停留占满内容区，不自动消失），
    // 搜索由点击建议或键盘搜索键（onSubmitted）触发，不做自动搜索
    _updateSuggestions(v);
    if (v.trim().isEmpty) {
      setState(() {
        _results = [];
        _hasSearched = false;
        _isSearching = false;
        // 输入为空时同时清空建议与结果，回到正常区域
        _suggestions = [];
      });
      return;
    }
  }

  Future<void> _search(String keyword,
      {List<String> aliases = const []}) async {
    // 搜索开始时收起建议列表，避免结果被遮蔽
    if (_suggestions.isNotEmpty) setState(() => _suggestions = []);
    final normalizedKeyword = keyword.trim();
    if (normalizedKeyword.isEmpty) {
      setState(() {
        _results = [];
        _hasSearched = false;
      });
      return;
    }
    setState(() => _isSearching = true);

    final results = <_SearchResult>[];
    final seenIds = <String>{};
    final favManager = LocalFavoritesManager();
    final localManager = LocalLibraryManager();

    await favManager.init();
    await localManager.ensureLoaded();
    final showAllDatabaseRecords = localManager.showAllDatabaseRecords;

    if (widget.searchType != LocalSearchType.downloadsOnly) {
      final favResults = favManager.search(normalizedKeyword, aliases: aliases);
      for (final fav in favResults) {
        final comic = fav.comic;
        final localItem =
            localManager.findCachedByCandidates(comic.candidateDownloadIds());
        final idKey = localItem != null
            ? 'local_${localItem.id}'
            : 'fav_${comic.type.key}_${comic.target}';
        if (seenIds.contains(idKey)) continue;
        seenIds.add(idKey);
        results.add(
          _SearchResult(
            title: comic.name,
            author: comic.author,
            sourceLabel: '${comic.type.name} · ${fav.folder}',
            tags: comic.tags,
            localItem: localItem,
            favoriteItem: fav,
          ),
        );
      }
    }

    if (widget.searchType != LocalSearchType.favoritesOnly) {
      for (final item in await localManager.getAll()) {
        if (_shouldHideDownloadedItem(item, showAllDatabaseRecords)) {
          continue;
        }
        final idKey = 'local_${item.id}';
        if (seenIds.contains(idKey)) continue;
        if (_matches(item, normalizedKeyword, aliases: aliases)) {
          seenIds.add(idKey);
          results.add(
            _SearchResult(
              title: item.name,
              author: _localSearchAuthor(item),
              sourceLabel: _downloadLabel(item),
              tags: item.tags,
              downloadItem: item,
            ),
          );
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _results = results;
      _hasSearched = true;
      _isSearching = false;
    });
  }

  bool _matches(DownloadedItem item, String keyword,
          {List<String> aliases = const []}) =>
      matchesLocalDownloadedItem(item, keyword, aliases: aliases);

  bool _shouldHideDownloadedItem(
    DownloadedItem item,
    bool showAllDatabaseRecords,
  ) {
    return !showAllDatabaseRecords &&
        item is LocalLibraryComicItem &&
        item.isManagedDownloadItem &&
        !item.localStorageExists;
  }

  String _downloadLabel(DownloadedItem item) {
    if (item is LocalLibraryComicItem) {
      if (item.isAlbum) {
        return '图集 · 本地';
      }
      final source = item.sourceDisplayName.trim();
      return source.isEmpty ? '本地下载' : '$source · 本地';
    }
    switch (item.type) {
      case DownloadType.picacg:
        return 'Picacg · 下载';
      case DownloadType.ehentai:
        return 'E-Hentai · 下载';
      case DownloadType.jm:
        return '禁漫 · 下载';
      case DownloadType.hitomi:
        return 'Hitomi · 下载';
      case DownloadType.htmanga:
        return '绅士漫画 · 下载';
      case DownloadType.nhentai:
        return 'NHentai · 下载';
      case DownloadType.copyManga:
        return '拷贝漫画 · 下载';
      case DownloadType.komiic:
        return 'Komiic · 下载';
      default:
        return '下载';
    }
  }

  String _formatSize(double? size) {
    if (size == null) return '未知大小'.tl;
    if (size > 1024) return '${(size / 1024).toStringAsFixed(1)}GB';
    return '${size.toStringAsFixed(1)}MB';
  }

  File _coverForDownloadedItem(DownloadedItem item) {
    if (item is LocalLibraryComicItem) {
      final coverPath = item.localCoverPath?.trim();
      if (coverPath != null && coverPath.isNotEmpty) {
        final file = File(coverPath);
        if (file.existsSync()) {
          return file;
        }
      }
      return File('');
    }
    return DownloadManager().getCover(item.id);
  }

  Widget _buildGridTile(_SearchResult result) {
    if (result.downloadItem != null) {
      final item = result.downloadItem!;
      return Padding(
        padding: const EdgeInsets.all(2),
        child: DownloadedComicTile(
          name: item.name,
          author: _localSearchAuthor(item),
          imagePath: _coverForDownloadedItem(item),
          type: result.sourceLabel,
          tag: item.tags,
          onTap: () {
            App.pushInner(() => LocalComicDetailPage(comic: item));
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
      final coverPath = comic.coverPath.trim();
      final favoriteCover = coverPath.isNotEmpty ? File(coverPath) : File('');
      final localCover =
          localItem != null ? _coverForDownloadedItem(localItem) : null;
      final imageFile = favoriteCover.existsSync()
          ? favoriteCover
          : (localCover?.existsSync() ?? false)
              ? localCover!
              : File('');

      return Padding(
        padding: const EdgeInsets.all(2),
        child: DownloadedComicTile(
          name: comic.name,
          author: comic.author,
          imagePath: imageFile,
          type: result.sourceLabel,
          tag: comic.tags,
          onTap: () {
            if (localItem != null) {
              App.pushInner(() => LocalComicDetailPage(comic: localItem));
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

  /// 根据输入框内容从已收集的 chips（本地标签 + 作者）中过滤出匹配的建议。
  ///
  /// 输入为空时清空建议；否则按包含匹配（不区分大小写）过滤，
  /// 保留 '作者: ' 前缀的完整条目，结果取前 50 条作为上限，防止建议列表过长。
  /// 本地标签/作者多为日文英文，中文输入通过翻译层（[tags_translation]）逆查
  /// 命中对应英文标签；仍匹配不到时回退展示热门建议（频次最高的前 50 条），
  /// 保证"输入非空即有提示"。
  void _updateSuggestions(String input) {
    // chips（建议数据源）尚未加载完成前不提供建议
    if (!_chipsReady) return;
    if (input.isEmpty) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = []);
      return;
    }
    final candidates = _candidatesForInput(input);
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
      final body = chip.startsWith('作者: ')
          ? chip.substring('作者: '.length).trim()
          : chip;
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
  bool _isChineseText(String input) =>
      RegExp(r'[一-鿿]').hasMatch(input);

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
          height: 36,
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
                  final query = isAuthor
                      ? label.substring('作者: '.length).trim()
                      : label;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: widget.initialKeyword.trim().isEmpty,
          decoration: const InputDecoration(
            hintText: '搜索本地漫画...',
            border: InputBorder.none,
            prefixIcon: Icon(Icons.search),
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          onChanged: _onSearchTextChanged,
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _controller.clear();
                setState(() {
                  _results = [];
                  _hasSearched = false;
                  _suggestions = [];
                });
              },
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            // 输入框有内容且有匹配建议时，建议列表占满内容区（在线搜索模式）；
            // 输入清空或建议清空时，回到正常的搜索结果区
            child: _controller.text.isNotEmpty && _suggestions.isNotEmpty
                ? _buildSuggestionList()
                : _isSearching
                    ? const Center(child: CircularProgressIndicator())
                    : !_hasSearched
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.search,
                                  size: 64,
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  widget.searchType ==
                                          LocalSearchType.favoritesOnly
                                      ? '输入关键词搜索收藏夹漫画'
                                      : widget.searchType ==
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
