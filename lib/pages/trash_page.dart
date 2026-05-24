import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/trash.dart';
import 'package:picakeep/tools/translations.dart';

enum _TrashPageView {
  local,
  remote,
}

enum _TrashItemKindView {
  comic,
  album,
}

class TrashPage extends StatefulWidget {
  const TrashPage({super.key});

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> with WidgetsBindingObserver {
  _TrashPageView _view = _TrashPageView.local;
  _TrashItemKindView _kindView = _TrashItemKindView.comic;
  late Future<void> _loadTask = _reload();
  List<TrashItemRecord> _localItems = const <TrashItemRecord>[];
  List<RemoteLibraryTrashItem> _remoteItems = const <RemoteLibraryTrashItem>[];
  final Set<String> _selectedKeys = <String>{};
  bool _selecting = false;
  String? _errorText;
  bool _isOperationRunning = false;
  int _operationProgressCurrent = 0;
  int _operationProgressTotal = 0;
  String _operationActionLabel = '';

  List<TrashItemRecord> get _filteredLocalItems => _localItems
      .where((item) => item.isAlbum == (_kindView == _TrashItemKindView.album))
      .toList(growable: false);

  List<RemoteLibraryTrashItem> get _filteredRemoteItems => _remoteItems
      .where((item) => item.isAlbum == (_kindView == _TrashItemKindView.album))
      .toList(growable: false);

  String _selectionKeyForLocal(TrashItemRecord item) => 'local:${item.id}';

  String _selectionKeyForRemote(RemoteLibraryTrashItem item) =>
      'remote:${item.id}';

  int get _selectedCount => _selectedKeys.length;

  String get _currentItemLabel =>
      _kindView == _TrashItemKindView.album ? '图集' : '漫画';

  List<TrashItemRecord> get _selectedLocalItems => _filteredLocalItems
      .where((item) => _selectedKeys.contains(_selectionKeyForLocal(item)))
      .toList(growable: false);

  List<RemoteLibraryTrashItem> get _selectedRemoteItems => _filteredRemoteItems
      .where((item) => _selectedKeys.contains(_selectionKeyForRemote(item)))
      .toList(growable: false);

  String get _operationProgressHint => '请不要退出，强制退出可能导致操作异常';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && !_isOperationRunning) {
      setState(() {
        _loadTask = _reload();
      });
    }
  }

  Future<void> _reload() async {
    try {
      final localItems = await TrashManager.instance.listItems(
        scope: TrashItemScope.local,
      );
      List<RemoteLibraryTrashItem> remoteItems =
          const <RemoteLibraryTrashItem>[];
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
        _clearSelectionState();
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

  void _clearSelectionState() {
    _selectedKeys.clear();
    _selecting = false;
  }

  void _exitSelectionMode() {
    setState(_clearSelectionState);
  }

  bool _isLocalSelected(TrashItemRecord item) {
    return _selectedKeys.contains(_selectionKeyForLocal(item));
  }

  bool _isRemoteSelected(RemoteLibraryTrashItem item) {
    return _selectedKeys.contains(_selectionKeyForRemote(item));
  }

  void _toggleLocalSelection(TrashItemRecord item) {
    final key = _selectionKeyForLocal(item);
    setState(() {
      _selecting = true;
      if (!_selectedKeys.add(key)) {
        _selectedKeys.remove(key);
      }
      if (_selectedKeys.isEmpty) {
        _selecting = false;
      }
    });
  }

  void _toggleRemoteSelection(RemoteLibraryTrashItem item) {
    final key = _selectionKeyForRemote(item);
    setState(() {
      _selecting = true;
      if (!_selectedKeys.add(key)) {
        _selectedKeys.remove(key);
      }
      if (_selectedKeys.isEmpty) {
        _selecting = false;
      }
    });
  }

  Iterable<String> get _currentVisibleSelectionKeys sync* {
    if (_view == _TrashPageView.local) {
      for (final item in _filteredLocalItems) {
        yield _selectionKeyForLocal(item);
      }
      return;
    }
    for (final item in _filteredRemoteItems) {
      yield _selectionKeyForRemote(item);
    }
  }

  bool get _allVisibleItemsSelected {
    final keys = _currentVisibleSelectionKeys.toList(growable: false);
    return keys.isNotEmpty && keys.every(_selectedKeys.contains);
  }

  void _toggleSelectAllVisible() {
    final keys = _currentVisibleSelectionKeys.toList(growable: false);
    if (keys.isEmpty) {
      return;
    }
    setState(() {
      if (_allVisibleItemsSelected) {
        _clearSelectionState();
        return;
      }
      _selectedKeys
        ..clear()
        ..addAll(keys);
      _selecting = true;
    });
  }

  String _operationErrorText(Object error) {
    final message = error is StateError
        ? error.message.toString()
        : error.toString().replaceFirst('Exception: ', '');
    if (message.contains(deleteFailurePermissionDenied) ||
        message.toLowerCase().contains('permission denied')) {
      return deleteFailureMessage(deleteFailurePermissionDenied).tl;
    }
    if (message.contains(deleteFailureLocalPathNotFound)) {
      return deleteFailureMessage(deleteFailureLocalPathNotFound).tl;
    }
    return message.replaceFirst('Bad state: ', '');
  }

  Future<void> _runItemsOperation<T>({
    required String actionLabel,
    required List<T> items,
    required Future<void> Function(T item) onItem,
  }) async {
    if (_isOperationRunning || items.isEmpty) {
      return;
    }
    setState(() {
      _isOperationRunning = true;
      _operationProgressCurrent = 0;
      _operationProgressTotal = items.length;
      _operationActionLabel = actionLabel;
    });
    App.beginNavigationLock();
    App.temporaryDisablePopGesture = true;
    String? errorText;
    try {
      for (int i = 0; i < items.length; i++) {
        if (mounted) {
          setState(() {
            _operationProgressCurrent = i + 1;
          });
        } else {
          _operationProgressCurrent = i + 1;
        }
        await onItem(items[i]);
      }
    } catch (e) {
      errorText = _operationErrorText(e);
    } finally {
      try {
        await _reload();
        if (mounted) {
          setState(() {
            _loadTask = Future<void>.value();
          });
        }
      } catch (e) {
        errorText ??= _operationErrorText(e);
      }
      App.temporaryDisablePopGesture = false;
      App.endNavigationLock();
      if (mounted) {
        setState(() {
          _isOperationRunning = false;
          _operationProgressCurrent = 0;
          _operationProgressTotal = 0;
          _operationActionLabel = '';
        });
      } else {
        _isOperationRunning = false;
        _operationProgressCurrent = 0;
        _operationProgressTotal = 0;
        _operationActionLabel = '';
      }
      if (errorText != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorText)),
        );
      }
    }
  }

  Future<void> _runBatchOperation<T>({
    required String actionLabel,
    required List<T> items,
    required Future<void> Function(List<T> items) action,
  }) async {
    if (_isOperationRunning || items.isEmpty) {
      return;
    }
    setState(() {
      _isOperationRunning = true;
      _operationProgressCurrent = 0;
      _operationProgressTotal = items.length;
      _operationActionLabel = actionLabel;
    });
    App.beginNavigationLock();
    App.temporaryDisablePopGesture = true;
    String? errorText;
    try {
      if (mounted) {
        setState(() {
          _operationProgressCurrent = items.length;
        });
      } else {
        _operationProgressCurrent = items.length;
      }
      await action(items);
    } catch (e) {
      errorText = _operationErrorText(e);
    } finally {
      try {
        await _reload();
        if (mounted) {
          setState(() {
            _loadTask = Future<void>.value();
          });
        }
      } catch (e) {
        errorText ??= _operationErrorText(e);
      }
      App.temporaryDisablePopGesture = false;
      App.endNavigationLock();
      if (mounted) {
        setState(() {
          _isOperationRunning = false;
          _operationProgressCurrent = 0;
          _operationProgressTotal = 0;
          _operationActionLabel = '';
        });
      } else {
        _isOperationRunning = false;
        _operationProgressCurrent = 0;
        _operationProgressTotal = 0;
        _operationActionLabel = '';
      }
      if (errorText != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorText)),
        );
      }
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
      await action();
    }
  }

  Future<void> _restoreSelected() async {
    if (_selectedCount == 0) {
      return;
    }
    if (_view == _TrashPageView.local) {
      await _runItemsOperation<TrashItemRecord>(
        actionLabel: '正在恢复',
        items: _selectedLocalItems,
        onItem: (item) => TrashManager.instance.restoreLocalItem(item.id),
      );
      return;
    }
    await _runBatchOperation<RemoteLibraryTrashItem>(
      actionLabel: '正在恢复',
      items: _selectedRemoteItems,
      action: (items) => TrashManager.instance.restoreRemoteItems(
        items.map((item) => item.id),
      ),
    );
  }

  Future<void> _deleteSelectedPermanently() async {
    if (_selectedCount == 0) {
      return;
    }
    await _confirmAndRun(
      title: '彻底删除'.tl,
      content: '确定要彻底删除已选择的$_selectedCount个$_currentItemLabel吗？'.tl,
      action: () async {
        if (_view == _TrashPageView.local) {
          await _runItemsOperation<TrashItemRecord>(
            actionLabel: '正在删除',
            items: _selectedLocalItems,
            onItem: (item) =>
                TrashManager.instance.permanentlyDeleteTrashItem(item.id),
          );
          return;
        }
        await _runBatchOperation<RemoteLibraryTrashItem>(
          actionLabel: '正在彻底删除',
          items: _selectedRemoteItems,
          action: (items) => TrashManager.instance.permanentlyDeleteRemoteItems(
            items.map((item) => item.id),
          ),
        );
      },
    );
  }

  Widget _buildOperationOverlay() {
    final theme = Theme.of(context);
    final progressText = '$_operationProgressCurrent/$_operationProgressTotal';
    final isDesktop = App.isDesktop;
    final barrierColor = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: 0.06),
      Colors.white.withValues(alpha: 0.76),
    );
    final panelColor = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: 0.04),
      theme.colorScheme.surface.withValues(alpha: 0.97),
    );
    return Stack(
      children: [
        ModalBarrier(
          dismissible: false,
          color: barrierColor,
        ),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isDesktop ? 440 : 300,
              minWidth: isDesktop ? 340 : 260,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: panelColor,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.shadow.withValues(alpha: 0.08),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
                border: Border.all(
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 22,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        strokeWidth: 3.2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (isDesktop)
                      Text(
                        '$_operationActionLabel $progressText',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      )
                    else ...[
                      Text(
                        _operationActionLabel,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        progressText,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.primary,
                          height: 1.25,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      _operationProgressHint.tl,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget page = Scaffold(
      appBar: AppBar(
        title: _selecting
            ? Text('已选择 @num 个项目'.tlParams({'num': _selectedCount.toString()}))
            : Text('回收站'.tl),
        leading: _selecting
            ? IconButton(
                onPressed: _exitSelectionMode,
                icon: const Icon(Icons.close),
              )
            : null,
        actions: _selecting
            ? [
                IconButton(
                  tooltip: (_allVisibleItemsSelected ? '取消全选' : '全选').tl,
                  onPressed: _currentVisibleSelectionKeys.isEmpty
                      ? null
                      : _toggleSelectAllVisible,
                  icon: Icon(
                    _allVisibleItemsSelected
                        ? Icons.clear_all
                        : Icons.select_all,
                  ),
                ),
                IconButton(
                  tooltip: '恢复'.tl,
                  onPressed: _selectedCount == 0 ? null : _restoreSelected,
                  icon: const Icon(Icons.restore),
                ),
                IconButton(
                  tooltip: '彻底删除'.tl,
                  onPressed:
                      _selectedCount == 0 ? null : _deleteSelectedPermanently,
                  icon: const Icon(Icons.delete_forever_outlined),
                ),
              ]
            : [
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegmentedButton<_TrashPageView>(
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
                          final nextView = selection.first;
                          setState(() {
                            _view = nextView;
                            _clearSelectionState();
                            _loadTask = _reload();
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      SegmentedButton<_TrashItemKindView>(
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment<_TrashItemKindView>(
                            value: _TrashItemKindView.comic,
                            label: Text('漫画'.tl),
                          ),
                          ButtonSegment<_TrashItemKindView>(
                            value: _TrashItemKindView.album,
                            label: Text('图集'.tl),
                          ),
                        ],
                        selected: {_kindView},
                        onSelectionChanged: (selection) {
                          if (selection.isEmpty) {
                            return;
                          }
                          setState(() {
                            _kindView = selection.first;
                            _clearSelectionState();
                            _loadTask = _reload();
                          });
                        },
                      ),
                    ],
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
    if (_isOperationRunning) {
      page = Stack(
        fit: StackFit.expand,
        children: [
          page,
          Positioned.fill(
            child: _buildOperationOverlay(),
          ),
        ],
      );
    }
    return PopScope(
      canPop: !_isOperationRunning,
      child: page,
    );
  }

  Widget _buildLocalList() {
    final items = _filteredLocalItems;
    if (items.isEmpty) {
      return Center(child: Text('本地$_currentItemLabel回收站为空'.tl));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _buildTrashCard(
          title: item.title,
          subtitle: item.subtitle,
          path: item.originalPath,
          cover: _buildLocalCover(
            resolveLocalTrashCoverPath(
              trashedPath: item.trashedPath,
              coverRelativePath: item.coverRelativePath,
              cover: item.cover,
            ),
          ),
          selected: _isLocalSelected(item),
          onTap: _selecting ? () => _toggleLocalSelection(item) : null,
          onLongPress: () => _toggleLocalSelection(item),
        );
      },
    );
  }

  Widget _buildRemoteList() {
    final items = _filteredRemoteItems;
    if (items.isEmpty) {
      return Center(child: Text('远程$_currentItemLabel回收站为空'.tl));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _buildTrashCard(
          title: item.title,
          subtitle: item.subtitle,
          path: item.originalPath,
          cover: _buildRemoteCover(item.coverUrl),
          selected: _isRemoteSelected(item),
          onTap: _selecting ? () => _toggleRemoteSelection(item) : null,
          onLongPress: () => _toggleRemoteSelection(item),
        );
      },
    );
  }

  Widget _buildTrashCard({
    required String title,
    required String subtitle,
    required String path,
    required Widget cover,
    required bool selected,
    required VoidCallback? onTap,
    required VoidCallback onLongPress,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(alpha: 0.22),
                          border: Border.all(
                            color: colorScheme.primary,
                            width: 1.6,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                colorScheme.primary.withValues(alpha: 0.14),
                                colorScheme.primary.withValues(alpha: 0.28),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
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

  Widget _coverPlaceholder(
      {IconData icon = Icons.image_not_supported_outlined}) {
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
