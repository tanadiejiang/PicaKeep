import 'package:flutter/material.dart';
import 'package:picakeep/foundation/history.dart';

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
        title: const Text("\u6E05\u9664\u8BB0\u5F55"),
        content:
            const Text("\u8981\u6E05\u9664\u5386\u53F2\u8BB0\u5F55\u5417?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text("\u53D6\u6D88"),
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
            child: const Text("\u6E05\u9664"),
          ),
        ],
      ),
    );
  }

  void _removeItem(int index) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("\u5220\u9664"),
        content: const Text(
            "\u8981\u5220\u9664\u8FD9\u6761\u5386\u53F2\u8BB0\u5F55\u5417"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text("\u53D6\u6D88"),
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
            child: const Text("\u5220\u9664"),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return "\u521A\u521A";
    if (diff.inMinutes < 60) return "${diff.inMinutes}\u5206\u949F\u524D";
    if (diff.inHours < 24) return "${diff.inHours}\u5C0F\u65F6\u524D";
    if (diff.inDays < 7) return "${diff.inDays}\u5929\u524D";
    return "${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("\u5386\u53F2\u8BB0\u5F55(${_items.length})"),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_forever),
              tooltip: "\u6E05\u9664",
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _items.isEmpty
          ? const Center(
              child: Text("\u6682\u65E0\u5386\u53F2\u8BB0\u5F55"),
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
                    child: Center(
                      child: Icon(
                        Icons.auto_stories,
                        size: 24,
                        color:
                            Theme.of(context).colorScheme.onSecondaryContainer,
                      ),
                    ),
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
                        "${item.type.name} \u00B7 ${_formatTime(item.time)}",
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text("\u6253\u5F00\u9605\u8BFB\u5668"),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  onLongPress: () => _removeItem(index),
                );
              },
            ),
    );
  }
}
