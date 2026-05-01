import 'dart:io';
import 'package:flutter/material.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/download.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late List<History> _items;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  void _loadHistory() {
    try {
      _items = HistoryManager().getAll();
    } catch (_) {
      _items = [];
    }
  }

  void _clearAll() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("清除记录"),
        content:
            const Text("要清除历史记录吗?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () {
              try {
                HistoryManager().clearHistory();
              } catch (_) {}
              setState(() {
                _items.clear();
              });
              Navigator.of(dialogContext).pop();
            },
            child: const Text("清除"),
          ),
        ],
      ),
    );
  }

  void _removeItem(int index) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("删除"),
        content: const Text(
            "要删除这条历史记录吗"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () {
              try {
                HistoryManager().remove(_items[index].target);
              } catch (_) {}
              setState(() {
                _items.removeAt(index);
              });
              Navigator.of(dialogContext).pop();
            },
            child: const Text("删除"),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return "刚刚";
    if (diff.inMinutes < 60) return "${diff.inMinutes}分钟前";
    if (diff.inHours < 24) return "${diff.inHours}小时前";
    if (diff.inDays < 7) return "${diff.inDays}天前";
    return "${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}";
  }

  Widget _buildCover(History item) {
    final cover = item.cover;
    if (cover.isEmpty) {
      return Center(
        child: Icon(
          Icons.auto_stories,
          size: 24,
          color: Theme.of(context).colorScheme.onSecondaryContainer,
        ),
      );
    }
    if (cover.startsWith('/') || cover.contains(':\\')) {
      return Image.file(
        File(cover),
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stackTrace) {
          return Center(
            child: Icon(
              Icons.auto_stories,
              size: 24,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
          );
        },
      );
    }
    return Center(
      child: Icon(
        Icons.auto_stories,
        size: 24,
        color: Theme.of(context).colorScheme.onSecondaryContainer,
      ),
    );
  }

  void _openComic(History item) async {
    var comic = await DownloadManager().getComicOrNull(item.target);
    if (comic != null) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => comic.createReadingPage()),
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("未找到该漫画"),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("历史记录(${_items.length})"),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_forever),
              tooltip: "清除",
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _items.isEmpty
          ? const Center(
              child: Text("暂无历史记录"),
            )
          : ListView.builder(
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index];
                return ListTile(
                  leading: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: Theme.of(context).colorScheme.secondaryContainer,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _buildCover(item),
                  ),
                  title: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (item.subtitle.isNotEmpty)
                        Text(
                          item.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      Text(
                        "${item.type.name} · ${_formatTime(item.time)}",
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openComic(item),
                  onLongPress: () => _removeItem(index),
                );
              },
            ),
    );
  }
}
