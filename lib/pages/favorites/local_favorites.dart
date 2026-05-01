import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import '../download_page.dart';
import 'package:picakeep/tools/read_history_helper.dart';

class LocalFavoritesPage extends StatefulWidget {
  final String folderName;
  const LocalFavoritesPage({super.key, required this.folderName});

  @override
  State<LocalFavoritesPage> createState() => _LocalFavoritesPageState();
}

class _LocalFavoritesPageState extends State<LocalFavoritesPage> {
  final _favManager = LocalFavoritesManager();
  final _scrollController = ScrollController();
  List<FavoriteItem> _comics = [];
  bool _loading = true;
  bool _orderDirty = false;

  @override
  void initState() {
    super.initState();
    _loadComics();
  }

  @override
  void dispose() {
    if (_orderDirty) {
      _favManager.reorder(_comics, widget.folderName);
    }
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadComics() async {
    await _favManager.init();
    setState(() {
      _comics = _favManager.getAllComics(widget.folderName);
      _loading = false;
    });
  }

  Future<void> _openComic(FavoriteItem comic) async {
    final dm = DownloadManager();
    await dm.init();
    final id = comic.toDownloadId();
    if (!dm.isExists(id)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('未找到本地下载: $id')),
      );
      return;
    }
    final dl = await dm.getComicOrNull(id);
    if (dl == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开该漫画')),
      );
      return;
    }
    await ensureHistoryBeforeRead(dl);
    if (!mounted) return;
    await dl.read();
  }

  void _removeComic(FavoriteItem comic) {
    _favManager.deleteComic(widget.folderName, comic);
    _loadComics();
  }

  File _coverFile(FavoriteItem comic) {
    final p = comic.coverPath.trim();
    if (p.isEmpty) return File('');
    final f = File(p);
    return f.existsSync() ? f : File('');
  }

  Widget _buildTile(FavoriteItem comic) {
    final cover = _coverFile(comic);
    final hasCover = cover.path.isNotEmpty;
    if (!hasCover) {
      return Material(
        borderRadius: BorderRadius.circular(16),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: InkWell(
          onTap: () => _openComic(comic),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Center(
                    child: Icon(
                      Icons.menu_book,
                      size: 40,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                Text(
                  comic.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                if (comic.author.isNotEmpty)
                  Text(
                    comic.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return DownloadedComicTile(
      name: comic.name,
      author: comic.author,
      imagePath: cover,
      type: comic.type.name,
      tag: comic.tags,
      onTap: () => _openComic(comic),
      size: '—',
      onLongTap: () {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('操作'),
            content: Text(comic.name),
            actions: [
              TextButton(
                onPressed: () {
                  _removeComic(comic);
                  Navigator.pop(ctx);
                },
                child: const Text('删除'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
            ],
          ),
        );
      },
      onSecondaryTap: (_) {},
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.folderName),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              showSearch(
                context: context,
                delegate: _FavSearchDelegate(_comics, (c) => _openComic(c)),
              );
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _comics.isEmpty
              ? const Center(child: Text('暂无漫画'))
              : ReorderableBuilder(
                  scrollController: _scrollController,
                  longPressDelay: App.isDesktop
                      ? const Duration(milliseconds: 100)
                      : const Duration(milliseconds: 500),
                  onReorder: (reorderFunc) {
                    setState(() {
                      _orderDirty = true;
                      _comics = reorderFunc(_comics) as List<FavoriteItem>;
                    });
                  },
                  dragChildBoxDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  ),
                  builder: (children) {
                    return GridView(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(4),
                      gridDelegate: SliverGridDelegateWithComics(),
                      children: children,
                    );
                  },
                  children: List.generate(
                    _comics.length,
                    (index) => Padding(
                      key: Key(
                          '${_comics[index].type.key}_${_comics[index].target}'),
                      padding: const EdgeInsets.all(2),
                      child: _buildTile(_comics[index]),
                    ),
                  ),
                ),
    );
  }
}

class _FavSearchDelegate extends SearchDelegate<void> {
  final List<FavoriteItem> comics;
  final Future<void> Function(FavoriteItem) onOpen;

  _FavSearchDelegate(this.comics, this.onOpen);

  @override
  List<Widget>? buildActions(BuildContext context) => [
        IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
      ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildResults(BuildContext context) => _list(context);

  @override
  Widget buildSuggestions(BuildContext context) => _list(context);

  Widget _list(BuildContext context) {
    final q = query.toLowerCase().trim();
    final results = q.isEmpty
        ? comics
        : comics
            .where((c) =>
                c.name.toLowerCase().contains(q) ||
                c.author.toLowerCase().contains(q))
            .toList();
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (_, i) => ListTile(
        title: Text(results[i].name),
        subtitle: Text(results[i].author),
        onTap: () async {
          await onOpen(results[i]);
          if (context.mounted) close(context, null);
        },
      ),
    );
  }
}
