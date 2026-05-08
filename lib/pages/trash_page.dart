import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/foundation/trash.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/tools/translations.dart';

enum _TrashPageView {
  local,
  remote,
}

class TrashPage extends StatefulWidget {
  const TrashPage({super.key});

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  _TrashPageView _view = _TrashPageView.local;
  late Future<void> _loadTask = _reload();
  List<TrashItemRecord> _localItems = const <TrashItemRecord>[];
  List<RemoteLibraryTrashItem> _remoteItems = const <RemoteLibraryTrashItem>[];
  String? _errorText;

  Future<void> _reload() async {
    try {
      final localItems = await TrashManager.instance.listItems(
        scope: TrashItemScope.local,
      );
      List<RemoteLibraryTrashItem> remoteItems = const <RemoteLibraryTrashItem>[];
      try {
        remoteItems = await TrashManager.instance.listRemoteItems();
      } catch (_) {
        remoteItems = const <RemoteLibraryTrashItem>[];
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _localItems = localItems;
        _remoteItems = remoteItems;
        _errorText = null;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = e.toString();
      });
    }
  }

  Future<void> _runAction(Future<void> Function() action) async {
    try {
      await action();
      if (!mounted) {
        return;
      }
      await _reload();
      setState(() {
        _loadTask = Future<void>.value();
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _confirmAndRun({
    required String title,
    required String content,
    required Future<void> Function() action,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('确认'.tl),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _runAction(action);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('回收站'.tl),
        actions: [
          IconButton(
            onPressed: () {
              setState(() {
                _loadTask = _reload();
              });
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _loadTask,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done &&
              _localItems.isEmpty &&
              _remoteItems.isEmpty &&
              _errorText == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<_TrashPageView>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment<_TrashPageView>(
                        value: _TrashPageView.local,
                        label: Text('本地'.tl),
                      ),
                      ButtonSegment<_TrashPageView>(
                        value: _TrashPageView.remote,
                        label: Text('远程'.tl),
                      ),
                    ],
                    selected: {_view},
                    onSelectionChanged: (selection) {
                      if (selection.isEmpty) {
                        return;
                      }
                      setState(() {
                        _view = selection.first;
                      });
                    },
                  ),
                ),
              ),
              Expanded(
                child: _errorText != null
                    ? Center(child: Text(_errorText!))
                    : _view == _TrashPageView.local
                        ? _buildLocalList()
                        : _buildRemoteList(),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLocalList() {
    if (_localItems.isEmpty) {
      return Center(child: Text('本地回收站为空'.tl));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      itemCount: _localItems.length,
      itemBuilder: (context, index) {
        final item = _localItems[index];
        return _buildTrashCard(
          title: item.title,
          subtitle: item.subtitle,
          path: item.originalPath,
          cover: _buildLocalCover(item.cover),
          onRestore: () => _runAction(
            () => TrashManager.instance.restoreLocalItem(item.id),
          ),
          onDelete: () => _confirmAndRun(
            title: '彻底删除'.tl,
            content: '确定要彻底删除“${item.title}”吗？'.tl,
            action: () => TrashManager.instance.permanentlyDeleteTrashItem(item.id),
          ),
        );
      },
    );
  }

  Widget _buildRemoteList() {
    if (_remoteItems.isEmpty) {
      return Center(child: Text('远程回收站为空'.tl));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      itemCount: _remoteItems.length,
      itemBuilder: (context, index) {
        final item = _remoteItems[index];
        return _buildTrashCard(
          title: item.title,
          subtitle: item.subtitle,
          path: item.originalPath,
          cover: _buildRemoteCover(item.coverUrl),
          onRestore: () => _runAction(
            () => TrashManager.instance.restoreRemoteItem(item.id),
          ),
          onDelete: () => _confirmAndRun(
            title: '彻底删除'.tl,
            content: '确定要彻底删除“${item.title}”吗？'.tl,
            action: () => TrashManager.instance.permanentlyDeleteRemoteItem(item.id),
          ),
        );
      },
    );
  }

  Widget _buildTrashCard({
    required String title,
    required String subtitle,
    required String path,
    required Widget cover,
    required VoidCallback onRestore,
    required VoidCallback onDelete,
  }) {
    return Card.outlined(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 44,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '恢复'.tl,
                    visualDensity: VisualDensity.compact,
                    onPressed: onRestore,
                    icon: const Icon(Icons.restore),
                  ),
                  const SizedBox(height: 4),
                  IconButton(
                    tooltip: '彻底删除'.tl,
                    visualDensity: VisualDensity.compact,
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_forever_outlined),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            cover,
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (path.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocalCover(String path) {
    final file = path.trim().isEmpty ? null : File(path.trim());
    if (file != null && file.existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          file,
          width: 72,
          height: 104,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _coverPlaceholder(),
        ),
      );
    }
    return _coverPlaceholder();
  }

  Widget _buildRemoteCover(String url) {
    if (url.trim().isEmpty) {
      return _coverPlaceholder(icon: Icons.cloud_off_outlined);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        url,
        width: 72,
        height: 104,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            _coverPlaceholder(icon: Icons.broken_image_outlined),
      ),
    );
  }

  Widget _coverPlaceholder({IconData icon = Icons.image_not_supported_outlined}) {
    return Container(
      width: 72,
      height: 104,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Icon(icon),
    );
  }
}