import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/tools/translations.dart';
import 'favorites/local_favorites.dart';
import 'local_comic_detail_page.dart';

enum LocalSearchType { favoritesOnly, downloadsOnly, all }

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
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
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
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onSearchTextChanged(String v) {
    _debounce?.cancel();
    if (v.trim().isEmpty) {
      setState(() {
        _results = [];
        _hasSearched = false;
        _isSearching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 320), () {
      if (!mounted) return;
      _search(v);
    });
  }

  Future<void> _search(String keyword) async {
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
      final favResults = favManager.search(normalizedKeyword);
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
        if (_matches(item, normalizedKeyword)) {
          seenIds.add(idKey);
          results.add(
            _SearchResult(
              title: item.name,
              author: item.subTitle,
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

  Iterable<String> _tagTerms(String tag) sync* {
    final raw = tag.trim();
    if (raw.isEmpty) return;
    yield raw.toLowerCase();
    if (raw.contains(':')) {
      final value = raw.split(':').last.trim();
      if (value.isNotEmpty) {
        yield value.toLowerCase();
      }
    }
  }

  Iterable<String> _searchTerms(DownloadedItem item) sync* {
    yield item.name.toLowerCase();
    yield item.subTitle.toLowerCase();
    yield item.sourceDisplayName.toLowerCase();

    for (final tag in item.tags) {
      yield* _tagTerms(tag);
    }

    try {
      final json = item.toJson();
      for (final key in const [
        'comicId',
        'id',
        'itemId',
        'link',
        'favoriteTarget',
        'directory',
      ]) {
        final value = json[key]?.toString().trim();
        if (value != null && value.isNotEmpty) {
          yield value.toLowerCase();
        }
      }
    } catch (_) {}

    if (item is LocalLibraryComicItem) {
      yield item.itemId.toLowerCase();
      yield item.originalId.toLowerCase();
      final favoriteTarget = item.favoriteTarget?.trim();
      if (favoriteTarget != null && favoriteTarget.isNotEmpty) {
        yield favoriteTarget.toLowerCase();
      }
      final fileSystemPath = item.fileSystemPath?.trim();
      if (fileSystemPath != null && fileSystemPath.isNotEmpty) {
        yield fileSystemPath.toLowerCase();
      }
      for (final alias in item.aliases) {
        final normalized = alias.trim();
        if (normalized.isNotEmpty) {
          yield normalized.toLowerCase();
        }
      }
      if (item.isAlbum) {
        yield '图集';
      }
    }
  }

  bool _matches(DownloadedItem item, String keyword) {
    final words = keyword
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .toList();
    if (words.isEmpty) {
      return true;
    }
    final terms = _searchTerms(item).where((e) => e.isNotEmpty).toList();
    return words.every((word) => terms.any((term) => term.contains(word)));
  }

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
          author: item.subTitle,
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
                });
              },
            ),
        ],
      ),
      body: _isSearching
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
                        widget.searchType == LocalSearchType.favoritesOnly
                            ? '输入关键词搜索收藏夹漫画'
                            : widget.searchType == LocalSearchType.downloadsOnly
                                ? '输入关键词搜索本地已下载漫画'
                                : '输入关键词搜索本地收藏和下载',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                )
              : _results.isEmpty
                  ? const Center(child: Text('未找到匹配的漫画'))
                  : GridView.builder(
                      padding: const EdgeInsets.all(4),
                      gridDelegate: SliverGridDelegateWithComics(),
                      itemCount: _results.length,
                      itemBuilder: (ctx, i) => _buildGridTile(_results[i]),
                    ),
    );
  }
}
