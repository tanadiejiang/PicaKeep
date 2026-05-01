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
import 'package:picakeep/tools/translations.dart';

class LocalFavoritesPage extends StatefulWidget {
  final String folderName;
  const LocalFavoritesPage({super.key, required this.folderName});

  @override
  State<LocalFavoritesPage> createState() => _LocalFavoritesPageState();
}

enum _SortMode { name, author, time }

class _LocalFavoritesPageState extends State<LocalFavoritesPage> {
  final _favManager = LocalFavoritesManager();
  final _scrollController = ScrollController();
  List<FavoriteItem> _comics = [];
  bool _loading = true;
  bool _orderDirty = false;
  bool _selecting = false;
  var _selected = <bool>[];
  _SortMode _sortMode = _SortMode.time;

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
    final comics = _favManager.getAllComics(widget.folderName);
    _applySort(comics);
    setState(() {
      _comics = comics;
      _loading = false;
    });
  }

  void _applySort(List<FavoriteItem> comics) {
    switch (_sortMode) {
      case _SortMode.name:
        comics.sort((a, b) => a.name.compareTo(b.name));
        break;
      case _SortMode.author:
        comics.sort((a, b) => a.author.compareTo(b.author));
        break;
      case _SortMode.time:
        // Keep original order from database (time-descending)
        break;
    }
  }

  Future<void> _openComic(FavoriteItem comic) async {
    if (_selecting) return;
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

  void _removeSelected() {
    final toRemove = <FavoriteItem>[];
    for (var i = 0; i < _comics.length; i++) {
      if (_selected[i]) {
        toRemove.add(_comics[i]);
      }
    }
    for (final comic in toRemove) {
      _favManager.deleteComic(widget.folderName, comic);
    }
    _loadComics();
    setState(() {
      _selecting = false;
      _selected = [];
    });
  }

  void _enterSelectMode(int index) {
    setState(() {
      _selecting = true;
      _selected = List.filled(_comics.length, false);
      _selected[index] = true;
    });
  }

  void _toggleSelectMode() {
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) {
        _selected = [];
      } else {
        _selected = List.filled(_comics.length, false);
      }
    });
  }

  File _coverFile(FavoriteItem comic) {
    final p = comic.coverPath.trim();
    if (p.isEmpty) return File('');
    final f = File(p);
    return f.existsSync() ? f : File('');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.folderName),
        actions: [
          if (_selecting)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除选中'.tl,
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('删除'),
                    content: Text('确定要删除选中的 ${_selected.where((e) => e).length} 部漫画吗？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                      TextButton(
                        onPressed: () {
                          _removeSelected();
                          Navigator.pop(ctx);
                        },
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
              },
            ),
          PopupMenuButton<_SortMode>(
            icon: const Icon(Icons.sort),
            tooltip: '排序'.tl,
            onSelected: (mode) {
              setState(() {
                _sortMode = mode;
              });
              _loadComics();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: _SortMode.time, child: Text('按时间')),
              const PopupMenuItem(value: _SortMode.name, child: Text('按标题')),
              const PopupMenuItem(value: _SortMode.author, child: Text('按作者')),
            ],
          ),
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
      floatingActionButton: _comics.isNotEmpty
          ? FloatingActionButton.small(
              heroTag: 'fav_select',
              onPressed: _toggleSelectMode,
              child: Icon(_selecting ? Icons.close : Icons.checklist),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _comics.isEmpty
              ? const Center(child: Text('暂无漫画'))
              : ReorderableBuilder(
                  scrollController: _scrollController,
                  longPressDelay: _selecting
                      ? const Duration(days: 365)
                      : App.isDesktop
                          ? const Duration(milliseconds: 100)
                          : const Duration(milliseconds: 500),
                  enableDraggable: !_selecting,
                  onReorder: (reorderFunc) {
                    if (_selecting) return;
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
                      padding: const EdgeInsets.only(
                          bottom: 80, left: 4, right: 4, top: 4),
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
                      child: Stack(
                        children: [
                          _buildTile(_comics[index]),
                          if (_selecting)
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Checkbox(
                                value: _selected[index],
                                onChanged: (v) {
                                  setState(() => _selected[index] = v ?? false);
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }

  Widget _buildTile(FavoriteItem comic) {
    final cover = _coverFile(comic);
    return DownloadedComicTile(
      name: comic.name,
      author: comic.author,
      imagePath: cover.path.isNotEmpty ? cover : File(''),
      type: comic.type.name,
      tag: comic.tags,
      onTap: () {
        if (_selecting) {
          // Toggle selection through the Checkbox handler instead
          return;
        }
        _openComic(comic);
      },
      size: () {
        try {
          final dm = DownloadManager();
          final id = comic.toDownloadId();
          if (dm.isExists(id)) {
            final dirPath = dm.getDirectory(id);
            final dir = Directory(dirPath);
            int totalSize = 0;
            for (final entity in dir.listSync(recursive: true)) {
              if (entity is File) {
                totalSize += entity.lengthSync();
              }
            }
            if (totalSize > 0) {
              return '${(totalSize / (1024 * 1024)).toStringAsFixed(1)} MB';
            }
          }
        } catch (_) {}
        return '—';
      }(),
      onLongTap: () {
        if (!_selecting) {
          _enterSelectMode(_comics.indexOf(comic));
        }
      },
      onSecondaryTap: (_) {},
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