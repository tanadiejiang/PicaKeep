// ignore_for_file: unused_element

import 'dart:io' show Platform, Process;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'reader/comic_reading_page.dart';
import 'local_comic_detail_page.dart';

void _toComicInfoPage(BuildContext context, DownloadedItem comic) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => LocalComicDetailPage(comic: comic),
  ));
}

extension ReadComic on DownloadedItem {
  void read({int? ep, int? page}) {
    final hasEp = eps.isNotEmpty;
    final readingData = LocalReadingData(
      title: name,
      id: id,
      downloadId: id,
      sourceKey: RegExp(r'^[a-zA-Z]+').stringMatch(id) ?? '',
      hasEp: hasEp,
      eps: hasEp ? {for (int i = 0; i < eps.length; i++) eps[i]: eps[i]} : null,
      favoriteType: const FavoriteType(0),
    );

    Navigator.of(App.globalContext!).push(MaterialPageRoute(
      builder: (_) => ComicReadingPage(
        readingData,
        page ?? 1,
        ep ?? (hasEp ? 1 : 0),
      ),
    ));
  }
}

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  List<DownloadedItem> _comics = [];
  List<DownloadedItem> _filtered = [];
  bool _loading = true;
  String _searchQuery = '';
  bool _selecting = false;
  Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    _loadComics();
  }

  Future<void> _loadComics() async {
    try {
      await DownloadManager().init();
      final comics = DownloadManager().getAll();
      setState(() {
        _comics = comics;
        _filtered = List.from(comics);
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  void _onSearch(String query) {
    setState(() {
      _searchQuery = query;
      if (query.isEmpty) {
        _filtered = List.from(_comics);
      } else {
        final q = query.toLowerCase();
        _filtered = _comics
            .where((c) =>
                c.name.toLowerCase().contains(q) ||
                c.subTitle.toLowerCase().contains(q) ||
                c.tags.any((t) => t.toLowerCase().contains(q)))
            .toList();
      }
    });
  }

  Future<void> _deleteSelected() async {
    final ids = _selected.map((i) => _filtered[i].id).toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除 ${ids.length} 个已下载的漫画吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed == true) {
      await DownloadManager().delete(ids);
      _selected.clear();
      _selecting = false;
      _loadComics();
    }
  }

  Future<void> _addToFavorites() async {
    final selectedComics = _selected.map((i) => _filtered[i]).toList();
    final favManager = LocalFavoritesManager();
    await favManager.init();

    final folders = favManager.folderNames;
    if (folders.isEmpty) {
      final controller = TextEditingController();
      final createResult = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('新建收藏文件夹'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '请输入文件夹名称'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      if (createResult == null || createResult.isEmpty) return;
      favManager.createFolder(createResult);
      folders.clear();
      folders.addAll(favManager.folderNames);
    }

    final targetFolder = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择收藏文件夹'),
        children: folders
            .map((f) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, f),
                  child: Text(f),
                ))
            .toList(),
      ),
    );

    if (targetFolder == null) return;

    int added = 0;
    for (final comic in selectedComics) {
      try {
        final favItem = FavoriteItem(
          target: comic.id,
          name: comic.name,
          coverPath: '',
          author: comic.subTitle,
          type: _downloadTypeToFavoriteType(comic.type),
          tags: comic.tags,
        );
        favManager.addComic(targetFolder, favItem);
        added++;
      } catch (_) {}
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已添加 $added 个漫画到"$targetFolder"')),
      );
      setState(() {
        _selecting = false;
        _selected.clear();
      });
    }
  }

  FavoriteType _downloadTypeToFavoriteType(DownloadType type) {
    switch (type) {
      case DownloadType.picacg:
        return FavoriteType.picacg;
      case DownloadType.ehentai:
        return FavoriteType.ehentai;
      case DownloadType.jm:
        return FavoriteType.jm;
      case DownloadType.hitomi:
        return FavoriteType.hitomi;
      case DownloadType.htmanga:
        return FavoriteType.htManga;
      case DownloadType.nhentai:
        return FavoriteType.nhentai;
      case DownloadType.copyManga:
        return FavoriteType.copyManga;
      case DownloadType.komiic:
        return FavoriteType.komiic;
      default:
        return const FavoriteType(0);
    }
  }

  String _formatSize(double? size) {
    if (size == null) return '未知';
    if (size > 1024) return '${(size / 1024).toStringAsFixed(1)} GB';
    return '${size.toStringAsFixed(1)} MB';
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title:
            _selecting ? Text('已选择 ${_selected.length} 项') : const Text('已下载'),
        actions: [
          if (_selecting) ...[
            IconButton(
                icon: const Icon(Icons.select_all),
                onPressed: () {
                  setState(() {
                    if (_selected.length == _filtered.length) {
                      _selected.clear();
                    } else {
                      _selected = {
                        for (var i = 0; i < _filtered.length; i++) i
                      };
                    }
                  });
                }),
            IconButton(
                icon: const Icon(Icons.favorite_border),
                onPressed: _selected.isNotEmpty ? _addToFavorites : null),
            IconButton(
                icon: const Icon(Icons.delete),
                onPressed: _selected.isNotEmpty ? _deleteSelected : null),
            IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    _selecting = false;
                    _selected.clear();
                  });
                }),
          ] else ...[
            IconButton(
                icon: const Icon(Icons.search),
                onPressed: () {
                  showSearch(
                      context: context,
                      delegate: _DownloadSearchDelegate(_comics, _loadComics));
                }),
            IconButton(icon: const Icon(Icons.sort), onPressed: _showSortMenu),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _filtered.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  itemCount: _filtered.length,
                  itemBuilder: (context, index) => _buildItem(index),
                ),
    );
  }

  Widget _buildEmptyState() {
    final path = DownloadManager().path ?? appdata.settings[22];
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.download_done, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('暂无已下载的漫画',
                style: TextStyle(fontSize: 18, color: Colors.grey)),
            const SizedBox(height: 8),
            if (path.isNotEmpty)
              Text('下载目录: $path',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () async {
                await DownloadManager().init();
                final count = DownloadManager().scanDirectoryForComics();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('扫描完成，共发现 $count 个漫画')),
                  );
                  _loadComics();
                }
              },
              icon: const Icon(Icons.refresh),
              label: const Text('重新扫描磁盘'),
            ),
            const SizedBox(height: 8),
            Text('请确保下载目录中存在 download.db 数据库文件',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline)),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(int index) {
    final comic = _filtered[index];
    final isSelected = _selected.contains(index);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
      color: isSelected ? Theme.of(context).colorScheme.primaryContainer : null,
      child: InkWell(
        onTap: () {
          if (_selecting) {
            setState(() {
              if (isSelected) {
                _selected.remove(index);
              } else {
                _selected.add(index);
              }
              if (_selected.isEmpty) _selecting = false;
            });
          } else {
            _showInfoPanel(comic);
          }
        },
        onLongPress: () {
          setState(() {
            _selecting = true;
            _selected.add(index);
          });
        },
        onSecondaryTap: _selecting ? null : () => _showItemMenu(comic),
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56,
              height: 72,
              child: _buildCover(comic),
            ),
          ),
          title: Text(comic.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (comic.subTitle.isNotEmpty)
                Text(comic.subTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 13)),
              Text(
                  '${_formatSize(comic.comicSize)}  ${_formatTime(comic.time)}  ${comic.eps.length} 章',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                      fontSize: 11)),
            ],
          ),
          trailing: _selecting
              ? Icon(
                  isSelected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color:
                      isSelected ? Theme.of(context).colorScheme.primary : null)
              : const Icon(Icons.chevron_right),
        ),
      ),
    );
  }

  Widget _buildCover(DownloadedItem comic) {
    try {
      final coverFile = DownloadManager().getCover(comic.id);
      if (coverFile.existsSync())
        return Image.file(coverFile,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                const Icon(Icons.image_not_supported));
    } catch (_) {}
    return Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Icon(Icons.image_not_supported_outlined));
  }

  void _showInfoPanel(DownloadedItem comic) {
    final eps = comic.eps;
    final downloaded = comic.downloadedEps;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        maxChildSize: 0.8,
        minChildSize: 0.3,
        expand: false,
        builder: (ctx, scrollController) => Column(
          children: [
            const SizedBox(height: 12),
            Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 12),
            Text(comic.name,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Expanded(
              child: GridView.builder(
                controller: scrollController,
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    childAspectRatio: 2.5,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8),
                itemCount: eps.length,
                itemBuilder: (ctx, i) => GestureDetector(
                  onLongPress: downloaded.contains(i)
                      ? () => _deleteSingleEpisode(ctx, comic, i)
                      : null,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: downloaded.contains(i)
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                    ),
                    onPressed: downloaded.contains(i)
                        ? () {
                            Navigator.pop(ctx);
                            comic.read(ep: i);
                          }
                        : null,
                    child: Text(eps[i],
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w500)),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _toComicInfoPage(context, comic);
                      },
                      child: const Text('查看详情'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        comic.read();
                      },
                      child: const Text('阅读'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteSingleEpisode(
      BuildContext sheetCtx, DownloadedItem comic, int ep) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除章节'),
        content: Text('确定要删除"${comic.eps[ep]}"吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed == true) {
      final error = await DownloadManager().deleteEpisode(comic, ep);
      if (error != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error)),
        );
      }
      Navigator.pop(sheetCtx);
      _loadComics();
    }
  }

  void _showSortMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
                title: const Text('按时间'),
                onTap: () {
                  Navigator.pop(ctx);
                  _sortBy((a, b) =>
                      (b.time ?? DateTime(0)).compareTo(a.time ?? DateTime(0)));
                }),
            ListTile(
                title: const Text('按标题'),
                onTap: () {
                  Navigator.pop(ctx);
                  _sortBy((a, b) => a.name.compareTo(b.name));
                }),
            ListTile(
                title: const Text('按作者'),
                onTap: () {
                  Navigator.pop(ctx);
                  _sortBy((a, b) => a.subTitle.compareTo(b.subTitle));
                }),
            ListTile(
                title: const Text('按大小'),
                onTap: () {
                  Navigator.pop(ctx);
                  _sortBy(
                      (a, b) => (b.comicSize ?? 0).compareTo(a.comicSize ?? 0));
                }),
          ],
        ),
      ),
    );
  }

  void _sortBy(int Function(DownloadedItem, DownloadedItem) compare) {
    setState(() {
      _comics.sort(compare);
      if (_searchQuery.isEmpty) {
        _filtered = List.from(_comics);
      }
    });
  }

  void _showItemMenu(DownloadedItem comic) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.menu_book),
              title: const Text('阅读'),
              onTap: () {
                Navigator.pop(ctx);
                comic.read();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete),
              title: const Text('删除'),
              onTap: () async {
                Navigator.pop(ctx);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('确认删除'),
                    content: Text('确定要删除"${comic.name}"吗？'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('删除')),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await DownloadManager().delete([comic.id]);
                  _loadComics();
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('导出'),
              onTap: () {
                Navigator.pop(ctx);
                _exportComic(comic);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('查看详情'),
              onTap: () {
                Navigator.pop(ctx);
                _toComicInfoPage(context, comic);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('复制路径'),
              onTap: () {
                Navigator.pop(ctx);
                final dir = comic.directory ?? '';
                final fullPath = "${DownloadManager().path}/$dir";
                Clipboard.setData(ClipboardData(text: fullPath));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('路径已复制到剪贴板')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _exportComic(DownloadedItem comic) {
    final dir = comic.directory ?? '';
    final fullPath = "${DownloadManager().path}/$dir";
    if (Platform.isWindows) {
      Process.run('explorer', [fullPath]);
    } else if (Platform.isMacOS) {
      Process.run('open', [fullPath]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [fullPath]);
    }
  }
}

class _DownloadSearchDelegate extends SearchDelegate<String> {
  final List<DownloadedItem> comics;
  final VoidCallback onDone;

  _DownloadSearchDelegate(this.comics, this.onDone);

  @override
  List<Widget>? buildActions(BuildContext context) => [
        IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
      ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, ''),
      );

  @override
  Widget buildResults(BuildContext context) => _buildSearchResults();

  @override
  Widget buildSuggestions(BuildContext context) => _buildSearchResults();

  Widget _buildSearchResults() {
    final q = query.toLowerCase();
    final results = comics
        .where((c) =>
            c.name.toLowerCase().contains(q) ||
            c.subTitle.toLowerCase().contains(q) ||
            c.tags.any((t) => t.toLowerCase().contains(q)))
        .toList();
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (ctx, i) => ListTile(
        title: Text(results[i].name),
        subtitle: Text(results[i].subTitle),
        onTap: () => close(ctx, results[i].id),
      ),
    );
  }
}
