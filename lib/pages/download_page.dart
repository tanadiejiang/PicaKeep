// ignore_for_file: unused_element

import 'package:flutter/material.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'local_comic_detail_page.dart';

void _toComicInfoPage(BuildContext context, DownloadedItem comic) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => LocalComicDetailPage(comic: comic),
  ));
}

extension ReadComic on DownloadedItem {
  void read({int? ep, int? page}) {
    // Open reader with local files
    // For now, show snackbar
    ScaffoldMessenger.of(App.globalContext!).showSnackBar(
      SnackBar(content: Text('打开阅读器: $name')),
    );
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
              ? const Center(child: Text('暂无已下载的漫画'))
              : ListView.builder(
                  itemCount: _filtered.length,
                  itemBuilder: (context, index) => _buildItem(index),
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
                itemBuilder: (ctx, i) => ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: downloaded.contains(i)
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                  onPressed: downloaded.contains(i)
                      ? () {
                          Navigator.pop(ctx);
                          comic.read(ep: i);
                        }
                      : null,
                  child: Text(eps[i],
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
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
