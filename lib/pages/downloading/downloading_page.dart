import 'package:flutter/material.dart';

import 'package:picakeep/foundation/online_download_manager.dart';

import 'downloading_logic.dart';

class DownloadingPage extends StatefulWidget {
  const DownloadingPage({super.key});

  @override
  State<DownloadingPage> createState() => _DownloadingPageState();
}

class _DownloadingPageState extends State<DownloadingPage> {
  final _logic = DownloadingLogic();
  final _selected = <String>{};
  bool _selectMode = false;

  OnlineDownloadManager get _manager => _logic.manager;

  @override
  void initState() {
    super.initState();
    _manager.version.addListener(_handleChanged);
  }

  @override
  void dispose() {
    _manager.version.removeListener(_handleChanged);
    super.dispose();
  }

  void _handleChanged() {
    if (mounted) setState(() {});
  }

  bool get _hasActiveDownloading => _logic.tasks.any(
        (t) => !t.completed && !t.cancelled && !t.paused && t.error == null,
      );

  bool get _hasTasks => _logic.tasks.isNotEmpty;

  void _toggleGlobalPause() {
    if (_hasActiveDownloading) {
      _manager.pauseAll();
    } else {
      _manager.resumeAll();
    }
  }

  void _enterSelectMode(String id) {
    setState(() {
      _selectMode = true;
      _selected.add(id);
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
        if (_selected.isEmpty) _selectMode = false;
      } else {
        _selected.add(id);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selected.addAll(_logic.tasks.map((t) => t.id));
    });
  }

  List<OnlineDownloadTask> get _selectedTasks =>
      _logic.tasks.where((t) => _selected.contains(t.id)).toList();

  void _multiCancel() {
    final ids = _selectedTasks
        .where((t) => !t.completed && !t.cancelled)
        .map((t) => t.id)
        .toList();
    _manager.cancelAll(ids);
    _exitSelectMode();
  }

  void _multiRemove() {
    _manager.removeAll(_selected.toList());
    _exitSelectMode();
  }

  void _multiPause() {
    for (final t in _selectedTasks) {
      if (!t.paused && !t.completed && !t.cancelled && t.error == null) {
        _manager.pauseOne(t.id);
      }
    }
    _exitSelectMode();
  }

  void _multiResume() {
    for (final t in _selectedTasks) {
      if (t.paused) _manager.resumeOne(t.id);
    }
    _exitSelectMode();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _logic.tasks.toList(growable: false);
    final downloading = _hasActiveDownloading;

    return PopScope(
      canPop: !_selectMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitSelectMode();
      },
      child: Scaffold(
        appBar: _selectMode
            ? _buildSelectAppBar(tasks)
            : _buildNormalAppBar(downloading),
        body: tasks.isEmpty
            ? const Center(child: Text('暂无下载任务'))
            : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: tasks.length,
                itemBuilder: (context, index) {
                  final task = tasks[index];
                  final isSelected = _selected.contains(task.id);
                  return GestureDetector(
                    onLongPress: () => _selectMode
                        ? null
                        : _enterSelectMode(task.id),
                    onTap: _selectMode ? () => _toggleSelect(task.id) : null,
                    child: _DownloadingTile(
                      task: task,
                      selectMode: _selectMode,
                      isSelected: isSelected,
                      onPauseResume: () => task.paused
                          ? _manager.resumeOne(task.id)
                          : _manager.pauseOne(task.id),
                      onMoveToFront: () => _manager.moveToFront(task.id),
                      onRetry: () => _manager.retry(task.id),
                    ),
                  );
                },
              ),
      ),
    );
  }

  AppBar _buildNormalAppBar(bool downloading) {
    return AppBar(
      title: const Text('下载管理器'),
      actions: [
        if (_hasTasks)
          IconButton(
            tooltip: downloading ? '暂停全部' : '继续全部',
            icon: Icon(
              downloading
                  ? Icons.pause_circle_outline
                  : Icons.play_circle_outline,
            ),
            onPressed: _toggleGlobalPause,
          ),
        if (_hasTasks &&
            _logic.tasks.any((t) => t.completed || t.cancelled))
          IconButton(
            tooltip: '清除已完成/已取消',
            icon: const Icon(Icons.cleaning_services_outlined),
            onPressed: _manager.clearFinished,
          ),
      ],
    );
  }

  AppBar _buildSelectAppBar(List<OnlineDownloadTask> tasks) {
    final count = _selected.length;
    final hasActive = _selectedTasks
        .any((t) => !t.completed && !t.cancelled && !t.paused && t.error == null);
    final hasPaused = _selectedTasks.any((t) => t.paused);
    final hasStoppable = _selectedTasks
        .any((t) => !t.completed && !t.cancelled);

    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _exitSelectMode,
      ),
      title: Text('已选 $count'),
      actions: [
        IconButton(
          tooltip: '全选',
          icon: const Icon(Icons.select_all),
          onPressed: _selectAll,
        ),
        PopupMenuButton<String>(
          onSelected: (v) {
            switch (v) {
              case 'pause':
                _multiPause();
              case 'resume':
                _multiResume();
              case 'cancel':
                _multiCancel();
              case 'remove':
                _multiRemove();
            }
          },
          itemBuilder: (_) => [
            if (hasActive)
              const PopupMenuItem(value: 'pause', child: Text('暂停所选')),
            if (hasPaused)
              const PopupMenuItem(value: 'resume', child: Text('继续所选')),
            if (hasStoppable)
              const PopupMenuItem(value: 'cancel', child: Text('取消所选')),
            const PopupMenuItem(value: 'remove', child: Text('从列表移除')),
          ],
        ),
      ],
    );
  }
}

class _DownloadingTile extends StatelessWidget {
  const _DownloadingTile({
    required this.task,
    required this.selectMode,
    required this.isSelected,
    required this.onPauseResume,
    required this.onMoveToFront,
    required this.onRetry,
  });

  final OnlineDownloadTask task;
  final bool selectMode;
  final bool isSelected;
  final VoidCallback onPauseResume;
  final VoidCallback onMoveToFront;
  final VoidCallback onRetry;

  String _progressText() {
    if (task.error != null) return '出错：${task.error}';
    if (task.completed || task.cancelled) return '';
    if (task.paused) return '已暂停';
    final pages = '已下载 ${task.currentPage}/${task.totalPages}';
    return '$pages · ${bytesPerSecToText(task.currentSpeed)}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final finished = task.completed || task.cancelled;
    final progressText = _progressText();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: SizedBox(
        height: 114,
        child: Row(
          children: [
            // ── 封面 / 多选 checkbox ──
            if (selectMode)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Checkbox(
                  value: isSelected,
                  onChanged: (_) {},
                ),
              ),
            Container(
              width: 84,
              height: 114,
              decoration: BoxDecoration(
                color: colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
                border: isSelected
                    ? Border.all(color: colorScheme.primary, width: 2)
                    : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.network(
                task.taskCover,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const Center(child: Icon(Icons.broken_image_outlined)),
              ),
            ),
            const SizedBox(width: 12),
            // ── 中间信息区 ──
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.taskTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  if (task.totalEps > 1 && !finished)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '第 ${task.currentEp}/${task.totalEps} 章：${task.currentEpName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: colorScheme.primary),
                      ),
                    ),
                  const Spacer(),
                  if (progressText.isNotEmpty)
                    Text(
                      progressText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: task.error != null
                            ? colorScheme.error
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: task.completed ? 1 : task.progress.clamp(0.0, 1.0),
                  ),
                ],
              ),
            ),
            // ── 右侧操作区（非多选模式）──
            if (!selectMode)
              SizedBox(
                width: 50,
                child: finished
                    ? Center(
                        child: Icon(
                          task.completed
                              ? Icons.check_circle_outline
                              : Icons.cancel_outlined,
                          color: task.completed
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                      )
                    : task.error != null
                        ? Center(
                            child: IconButton(
                              tooltip: '重试',
                              icon: const Icon(Icons.refresh),
                              onPressed: onRetry,
                            ),
                          )
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // 左上：暂停/继续
                              IconButton(
                                tooltip: task.paused ? '继续' : '暂停',
                                padding: EdgeInsets.zero,
                                icon: Icon(
                                  task.paused
                                      ? Icons.play_circle_outline
                                      : Icons.pause_circle_outline,
                                  size: 22,
                                ),
                                onPressed: onPauseResume,
                              ),
                              // 右下：置顶
                              IconButton(
                                tooltip: '置顶',
                                padding: EdgeInsets.zero,
                                icon: const Icon(
                                    Icons.vertical_align_top,
                                    size: 22),
                                onPressed: onMoveToFront,
                              ),
                            ],
                          ),
              ),
          ],
        ),
      ),
    );
  }
}
