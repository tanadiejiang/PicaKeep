import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/tools/translations.dart';
import 'favorites/local_favorites.dart';
import 'local_comic_detail_page.dart';

class _SearchResult {
  final String title;
  final String author;
  final String sourceLabel;
  final List<String> tags;
  final FavoriteType? favType;
  final DownloadedItem? downloadItem;
  final FavoriteItemWithFolderInfo? favoriteItem;

  _SearchResult({
    required this.title,
    required this.author,
    required this.sourceLabel,
    this.tags = const [],
    this.favType,
    this.downloadItem,
    this.favoriteItem,
  });
}

class LocalSearchPage extends StatefulWidget {
  const LocalSearchPage({super.key});

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
    if (keyword.trim().isEmpty) {
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
    await favManager.init();
    final favResults = favManager.search(keyword);
    for (final fav in favResults) {
      final c = fav.comic;
      final idKey = 'fav_${c.type.key}_${c.target}';
      if (seenIds.contains(idKey)) continue;
      seenIds.add(idKey);
      results.add(_SearchResult(
        title: c.name,
        author: c.author,
        sourceLabel: '${c.type.name} · ${fav.folder}',
        tags: c.tags,
        favType: c.type,
        favoriteItem: fav,
      ));
    }
    try {
      final dlManager = DownloadManager();
      await dlManager.init();
      for (final item in dlManager.getAll()) {
        final idKey = 'dl_${item.id}';
        if (seenIds.contains(idKey)) continue;
        if (_matches(item, keyword)) {
          seenIds.add(idKey);
          results.add(_SearchResult(
            title: item.name,
            author: item.subTitle,
            sourceLabel: _downloadLabel(item.type),
            tags: item.tags,
            downloadItem: item,
          ));
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _results = results;
      _hasSearched = true;
      _isSearching = false;
    });
  }

  bool _matches(DownloadedItem item, String keyword) {
    final k = keyword.trim().toLowerCase();
    for (final kw in k.split(' ')) {
      if (kw.isEmpty) continue;
      if (!item.name.toLowerCase().contains(kw) &&
          !item.subTitle.toLowerCase().contains(kw) &&
          !item.tags.any((t) => t.toLowerCase().contains(kw))) {
        return false;
      }
    }
    return true;
  }

  String _downloadLabel(DownloadType type) {
    switch (type) {
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

  Widget _buildGridTile(_SearchResult r) {
    if (r.downloadItem != null) {
      final item = r.downloadItem!;
      final type = item.type.name;
      return Padding(
        padding: const EdgeInsets.all(2),
        child: DownloadedComicTile(
          name: item.name,
          author: item.subTitle,
          imagePath: DownloadManager().getCover(item.id),
          type: type,
          tag: item.tags,
          onTap: () {
            App.pushInner(() => LocalComicDetailPage(comic: item));
          },
          size: item.comicSize != null
              ? '${item.comicSize!.toStringAsFixed(2)}MB'
              : '未知大小'.tl,
          onLongTap: () {},
          onSecondaryTap: (_) {},
        ),
      );
    }
    if (r.favoriteItem != null) {
      final c = r.favoriteItem!.comic;
      final p = c.coverPath.trim();
      final coverOk = p.isNotEmpty && File(p).existsSync();
      if (coverOk) {
        return Padding(
          padding: const EdgeInsets.all(2),
          child: DownloadedComicTile(
            name: c.name,
            author: c.author,
            imagePath: File(p),
            type: r.sourceLabel,
            tag: c.tags,
            onTap: () {
              App.pushInner(
                () => LocalFavoritesFolder(folderName: r.favoriteItem!.folder),
              );
            },
            size: '—',
            onLongTap: () {},
            onSecondaryTap: (_) {},
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(2),
        child: Material(
          borderRadius: BorderRadius.circular(16),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: InkWell(
            onTap: () {
              App.pushInner(
                () => LocalFavoritesFolder(folderName: r.favoriteItem!.folder),
              );
            },
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Center(
                      child: Icon(
                        Icons.collections_bookmark,
                        size: 40,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  Text(
                    c.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (c.author.isNotEmpty)
                    Text(
                      c.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ),
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
          autofocus: true,
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
                        '输入关键词搜索本地收藏和下载',
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
