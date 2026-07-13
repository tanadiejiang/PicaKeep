import 'package:flutter/material.dart';
import '../../foundation/ai/ai_download_queue.dart';
import '../../foundation/ai/ai_result_item.dart';
import '../../foundation/online_download_manager.dart';

class AiDownloadListPage extends StatefulWidget {
  const AiDownloadListPage({super.key});

  @override
  State<AiDownloadListPage> createState() => _AiDownloadListPageState();
}

class _AiDownloadListPageState extends State<AiDownloadListPage> {
  // ────────────────────────────────────────────────────────
  //  多选状态（参照 ai_item_list_page.dart 的 _selecting/_selected 模式）。
  //  两个列表（待下载/下载进度）的选中键各自用 Set<String> 存储（而不是
  //  List<bool> 按下标索引），因为两个列表长度独立、下载进度列表顺序可能变化。
  //  同一时刻只允许一个列表处于多选态，以降低复杂度。
  // ────────────────────────────────────────────────────────
  bool _selectingQueue = false; // "待下载"列表多选态
  final Set<String> _selectedQueueKeys = {}; // key = 'source:id'

  bool _selectingTasks = false; // "下载进度"列表多选态
  final Set<String> _selectedTaskIds = {}; // key = taskId

  static String _itemKey(AiResultItem item) => AiDownloadQueue.itemKey(item);

  // ────────────────────────────────────────────────────────
  //  多选：待下载列表
  // ────────────────────────────────────────────────────────

  void _onQueueTap(AiResultItem item) {
    if (!_selectingQueue) return;
    final key = _itemKey(item);
    setState(() {
      if (_selectedQueueKeys.contains(key)) {
        _selectedQueueKeys.remove(key);
      } else {
        _selectedQueueKeys.add(key);
      }
      if (_selectedQueueKeys.isEmpty) _selectingQueue = false;
    });
  }

  void _onQueueLongPress(AiResultItem item) {
    if (_selectingTasks) return; // 同一时刻只允许一个列表多选
    setState(() {
      _selectingQueue = true;
      _selectedQueueKeys.add(_itemKey(item));
    });
  }

  void _exitQueueSelection() {
    setState(() {
      _selectingQueue = false;
      _selectedQueueKeys.clear();
    });
  }

  Future<void> _deleteSelectedQueueItems() async {
    final items = AiDownloadQueue.instance.items
        .where((e) => _selectedQueueKeys.contains(_itemKey(e)))
        .toList();
    await AiDownloadQueue.instance.removeAll(items);
    _exitQueueSelection();
  }

  // ────────────────────────────────────────────────────────
  //  多选：下载进度列表
  // ────────────────────────────────────────────────────────

  void _onTaskTap(OnlineDownloadTask task) {
    if (!_selectingTasks) return;
    setState(() {
      if (_selectedTaskIds.contains(task.taskId)) {
        _selectedTaskIds.remove(task.taskId);
      } else {
        _selectedTaskIds.add(task.taskId);
      }
      if (_selectedTaskIds.isEmpty) _selectingTasks = false;
    });
  }

  void _onTaskLongPress(OnlineDownloadTask task) {
    if (_selectingQueue) return; // 同一时刻只允许一个列表多选
    setState(() {
      _selectingTasks = true;
      _selectedTaskIds.add(task.taskId);
    });
  }

  void _exitTaskSelection() {
    setState(() {
      _selectingTasks = false;
      _selectedTaskIds.clear();
    });
  }

  void _cancelSelectedTasks() {
    OnlineDownloadManager.instance.cancelAll(_selectedTaskIds.toList());
    _exitTaskSelection();
  }

  void _removeSelectedTasks() {
    OnlineDownloadManager.instance.removeAll(_selectedTaskIds.toList());
    _exitTaskSelection();
  }

  // ────────────────────────────────────────────────────────
  //  下载逻辑（循环体已搬迁至 AiDownloadQueue，本页面只负责触发调用与展示）
  // ────────────────────────────────────────────────────────

  Future<void> _startDownload(AiResultItem item) =>
      AiDownloadQueue.instance.startDownload(item);

  Future<void> _startAll() => AiDownloadQueue.instance.startAll();

  // ────────────────────────────────────────────────────────
  //  Build
  // ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ── AppBar ──
          _selectingQueue
              ? SliverAppBar(
                  pinned: true,
                  backgroundColor:
                      Theme.of(context).colorScheme.primaryContainer,
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _exitQueueSelection,
                  ),
                  title: Text('已选 ${_selectedQueueKeys.length} 项'),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '批量删除',
                      onPressed: _selectedQueueKeys.isEmpty
                          ? null
                          : _deleteSelectedQueueItems,
                    ),
                  ],
                )
              : _selectingTasks
                  ? SliverAppBar(
                      pinned: true,
                      backgroundColor:
                          Theme.of(context).colorScheme.primaryContainer,
                      leading: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: _exitTaskSelection,
                      ),
                      title: Text('已选 ${_selectedTaskIds.length} 项'),
                      actions: [
                        IconButton(
                          icon: const Icon(Icons.cancel_outlined),
                          tooltip: '批量取消',
                          onPressed: _selectedTaskIds.isEmpty
                              ? null
                              : _cancelSelectedTasks,
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: '批量删除',
                          onPressed: _selectedTaskIds.isEmpty
                              ? null
                              : _removeSelectedTasks,
                        ),
                      ],
                    )
                  : SliverAppBar(
                      pinned: true,
                      title: const Text('AI 下载清单'),
                      actions: [
                        ListenableBuilder(
                          listenable: AiDownloadQueue.instance,
                          builder: (context, _) {
                            final isEmpty =
                                AiDownloadQueue.instance.items.isEmpty;
                            return IconButton(
                              onPressed: isEmpty ? null : _startAll,
                              icon: const Icon(
                                  Icons.download_for_offline_outlined),
                              tooltip: '全部开始下载',
                            );
                          },
                        ),
                        ValueListenableBuilder<int>(
                          valueListenable:
                              OnlineDownloadManager.instance.version,
                          builder: (context, _, __) {
                            final tasks = OnlineDownloadManager.instance.tasks;
                            final hasActive = tasks.any((t) =>
                                !t.completed &&
                                !t.cancelled &&
                                t.error == null);
                            final hasRunning = tasks.any((t) =>
                                !t.completed &&
                                !t.cancelled &&
                                !t.paused &&
                                t.error == null);
                            final hasFinished = tasks
                                .any((t) => t.completed || t.cancelled);

                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (hasActive)
                                  IconButton(
                                    icon: Icon(hasRunning
                                        ? Icons.pause_outlined
                                        : Icons.play_arrow_outlined),
                                    tooltip: hasRunning ? '全部暂停' : '全部继续',
                                    onPressed: hasRunning
                                        ? OnlineDownloadManager.instance
                                            .pauseAll
                                        : OnlineDownloadManager.instance
                                            .resumeAll,
                                  ),
                                if (hasFinished)
                                  IconButton(
                                    icon: const Icon(
                                        Icons.playlist_remove_outlined),
                                    tooltip: '清除已完成',
                                    onPressed: OnlineDownloadManager
                                        .instance.clearFinished,
                                  ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),

          // ── 待下载 section 标题 ──
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '待下载',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ),

          // ── 待下载列表 ──
          ListenableBuilder(
            listenable: AiDownloadQueue.instance,
            builder: (context, _) {
              final items = AiDownloadQueue.instance.items;
              if (items.isEmpty) {
                return const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      '队列为空',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                );
              }
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = items[index];
                    final key = _itemKey(item);
                    final isLoading =
                        AiDownloadQueue.instance.downloading.contains(key);
                    final isSelected = _selectedQueueKeys.contains(key);
                    return GestureDetector(
                      onLongPress: () => _onQueueLongPress(item),
                      onTap:
                          _selectingQueue ? () => _onQueueTap(item) : null,
                      child: Container(
                        color: isSelected
                            ? Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.12)
                            : null,
                        child: ListTile(
                          leading: _selectingQueue
                              ? Icon(
                                  isSelected
                                      ? Icons.check_circle
                                      : Icons.radio_button_unchecked,
                                  color: isSelected
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                )
                              : _coverImage(item.coverUrl),
                          title: Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: _sourceBadge(context, item.source),
                          trailing: _selectingQueue
                              ? null
                              : (isLoading
                                  ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator
                                          .adaptive(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : ElevatedButton(
                                      onPressed: () => _startDownload(item),
                                      child: const Text('下载'),
                                    )),
                        ),
                      ),
                    );
                  },
                  childCount: items.length,
                ),
              );
            },
          ),

          // ── 下载进度 section 标题 ──
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                '下载进度',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ),

          // ── 下载进度列表 ──
          ValueListenableBuilder<int>(
            valueListenable: OnlineDownloadManager.instance.version,
            builder: (context, _, __) {
              final tasks = OnlineDownloadManager.instance.tasks;
              if (tasks.isEmpty) {
                return const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      '暂无下载任务',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                );
              }
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final task = tasks[index];
                    return _buildTaskTile(context, task);
                  },
                  childCount: tasks.length,
                ),
              );
            },
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  // ────────────────────────────────────────────────────────
  //  辅助 Widgets
  // ────────────────────────────────────────────────────────

  Widget _coverImage(String url) {
    if (url.isEmpty) {
      return const SizedBox(
        width: 40,
        height: 56,
        child: Icon(Icons.image_not_supported_outlined),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.network(
        url,
        width: 40,
        height: 56,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox(
          width: 40,
          height: 56,
          child: Icon(Icons.image_not_supported_outlined),
        ),
      ),
    );
  }

  Widget _sourceBadge(BuildContext context, String source) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          source,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }

  // ────────────────────────────────────────────────────────
  //  状态辅助
  // ────────────────────────────────────────────────────────

  String _formatSpeed(int bytesPerSec) {
    if (bytesPerSec >= 1024 * 1024) {
      return '${(bytesPerSec / 1024 / 1024).toStringAsFixed(1)} MB/s';
    } else if (bytesPerSec >= 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
    } else if (bytesPerSec > 0) {
      return '$bytesPerSec B/s';
    }
    return '';
  }

  String _taskProgressText(OnlineDownloadTask task) {
    if (task.error != null) return '出错：${task.error}';
    if (task.completed || task.cancelled) return '';
    if (task.paused) return '已暂停';
    final speed = _formatSpeed(task.currentSpeed);
    final pages = '已下载 ${task.currentPage}/${task.totalPages} 页';
    return speed.isEmpty ? pages : '$pages  $speed';
  }

  Widget _buildTaskTile(BuildContext context, OnlineDownloadTask task) {
    final colorScheme = Theme.of(context).colorScheme;
    final finished = task.completed || task.cancelled;
    final progressText = _taskProgressText(task);
    final isSelected = _selectedTaskIds.contains(task.taskId);

    return GestureDetector(
      onLongPress: () => _onTaskLongPress(task),
      onTap: _selectingTasks ? () => _onTaskTap(task) : null,
      child: Container(
        color: isSelected
            ? colorScheme.primary.withValues(alpha: 0.12)
            : null,
        child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: SizedBox(
        height: 114,
        child: Row(
          children: [
            // 封面（多选态显示选中态勾选图标覆盖）
            Stack(
              children: [
                Container(
                  width: 84,
                  height: 114,
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: task.taskCover.isEmpty
                      ? const Center(child: Icon(Icons.image_not_supported_outlined))
                      : Image.network(
                          task.taskCover,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const Center(child: Icon(Icons.broken_image_outlined)),
                        ),
                ),
                if (_selectingTasks)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Icon(
                      isSelected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: isSelected
                          ? colorScheme.primary
                          : Colors.white,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            // 中间信息
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
            // 右侧操作区（多选态隐藏，避免误触）
            if (!_selectingTasks)
              SizedBox(
                width: 44,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (task.error != null)
                      IconButton(
                        icon: const Icon(Icons.refresh, color: Colors.red),
                        tooltip: '重试',
                        iconSize: 20,
                        padding: EdgeInsets.zero,
                        onPressed: () =>
                            OnlineDownloadManager.instance.retry(task.taskId),
                      )
                    else if (task.completed)
                      Icon(Icons.check_circle_outline,
                          size: 20, color: colorScheme.primary)
                    else if (task.cancelled)
                      Icon(Icons.cancel_outlined,
                          size: 20, color: colorScheme.onSurfaceVariant)
                    else if (task.paused)
                      IconButton(
                        icon: const Icon(Icons.play_circle_outline),
                        tooltip: '继续',
                        iconSize: 20,
                        padding: EdgeInsets.zero,
                        onPressed: () =>
                            OnlineDownloadManager.instance.resumeOne(task.taskId),
                      )
                    else ...[
                      IconButton(
                        icon: const Icon(Icons.pause_circle_outline),
                        tooltip: '暂停',
                        iconSize: 20,
                        padding: EdgeInsets.zero,
                        onPressed: () =>
                            OnlineDownloadManager.instance.pauseOne(task.taskId),
                      ),
                      IconButton(
                        icon: const Icon(Icons.vertical_align_top),
                        tooltip: '置顶',
                        iconSize: 18,
                        padding: EdgeInsets.zero,
                        onPressed: () =>
                            OnlineDownloadManager.instance.moveToFront(task.taskId),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
        ),
      ),
    );
  }
}