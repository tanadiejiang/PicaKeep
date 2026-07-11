import 'package:flutter/material.dart';
import '../../foundation/ai/ai_download_queue.dart';
import '../../foundation/ai/ai_result_item.dart';
import '../../foundation/ai/ai_sources.dart';
import '../../foundation/online_download_manager.dart';
import '../../network/eh_network/eh_main_network.dart';
import '../../network/jm_network/jm_network.dart';
import '../../network/nhentai_network/nhentai_main_network.dart';
import '../../network/picacg_network/picacg_network.dart';

class AiDownloadListPage extends StatefulWidget {
  const AiDownloadListPage({super.key});

  @override
  State<AiDownloadListPage> createState() => _AiDownloadListPageState();
}

class _AiDownloadListPageState extends State<AiDownloadListPage> {
  /// 正在发起下载的条目 key 集合（key = 'source:id'）。
  final Set<String> _downloading = {};

  static String _itemKey(AiResultItem item) => '${item.source}:${item.id}';

  // ────────────────────────────────────────────────────────
  //  下载逻辑
  // ────────────────────────────────────────────────────────

  Future<void> _startDownload(AiResultItem item) async {
    final key = _itemKey(item);
    if (_downloading.contains(key)) return;
    if (!mounted) return;
    setState(() => _downloading.add(key));

    try {
      switch (item.source) {
        case aiSourcePicacg:
          final res = await PicacgNetwork().getComicInfo(item.id);
          if (!mounted) return;
          if (res.error) {
            _showError(res.errorMessageWithoutNull);
            return;
          }
          final enq = await OnlineDownloadManager.instance.enqueuePicacg(res.data);
          if (!mounted) return;
          if (enq.error) {
            _showError(enq.errorMessageWithoutNull);
            return;
          }

        case aiSourceJm:
          final normalizedId =
              item.id.replaceFirst(RegExp(r'^jm', caseSensitive: false), '');
          final res = await JmNetwork().getComicInfo(normalizedId);
          if (!mounted) return;
          if (res.error) {
            _showError(res.errorMessageWithoutNull);
            return;
          }
          final enq = await OnlineDownloadManager.instance.enqueueJm(res.data);
          if (!mounted) return;
          if (enq.error) {
            _showError(enq.errorMessageWithoutNull);
            return;
          }

        case aiSourceEhentai:
          final res = await EhNetwork().getGalleryInfo(item.id);
          if (!mounted) return;
          if (res.error) {
            _showError(res.errorMessageWithoutNull);
            return;
          }
          final enq = await OnlineDownloadManager.instance.enqueueEhentai(res.data);
          if (!mounted) return;
          if (enq.error) {
            _showError(enq.errorMessageWithoutNull);
            return;
          }

        case aiSourceNhentai:
          final normalizedId = item.id
              .replaceFirst(RegExp(r'^nhentai', caseSensitive: false), '')
              .replaceFirst(RegExp(r'^nh', caseSensitive: false), '');
          final res = await NhentaiNetwork().getComicInfo(normalizedId);
          if (!mounted) return;
          if (res.error) {
            _showError(res.errorMessageWithoutNull);
            return;
          }
          final enq = await OnlineDownloadManager.instance.enqueueNhentai(res.data);
          if (!mounted) return;
          if (enq.error) {
            _showError(enq.errorMessageWithoutNull);
            return;
          }

        default:
          _showError('不支持的来源: ${item.source}');
          return;
      }

      // 入队成功，从 AI 待下载队列中移除
      await AiDownloadQueue.instance.remove(item);
    } finally {
      if (mounted) {
        setState(() => _downloading.remove(key));
      }
    }
  }

  /// 串行遍历队列，依次入队。
  Future<void> _startAll() async {
    final snapshot = List<AiResultItem>.from(AiDownloadQueue.instance.items);
    for (final item in snapshot) {
      await _startDownload(item);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // ────────────────────────────────────────────────────────
  //  Build
  // ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ── AppBar ──
          SliverAppBar(
            pinned: true,
            title: const Text('AI 下载清单'),
            actions: [
              ListenableBuilder(
                listenable: AiDownloadQueue.instance,
                builder: (context, _) {
                  final isEmpty = AiDownloadQueue.instance.items.isEmpty;
                  return IconButton(
                    onPressed: isEmpty ? null : _startAll,
                    icon: const Icon(Icons.download_for_offline_outlined),
                    tooltip: '全部开始下载',
                  );
                },
              ),
              ValueListenableBuilder<int>(
                valueListenable: OnlineDownloadManager.instance.version,
                builder: (context, _, __) {
                  final tasks = OnlineDownloadManager.instance.tasks;
                  final hasActive = tasks.any((t) =>
                      !t.completed && !t.cancelled && t.error == null);
                  final hasRunning = tasks.any((t) =>
                      !t.completed &&
                      !t.cancelled &&
                      !t.paused &&
                      t.error == null);
                  final hasFinished =
                      tasks.any((t) => t.completed || t.cancelled);

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
                              ? OnlineDownloadManager.instance.pauseAll
                              : OnlineDownloadManager.instance.resumeAll,
                        ),
                      if (hasFinished)
                        IconButton(
                          icon: const Icon(Icons.playlist_remove_outlined),
                          tooltip: '清除已完成',
                          onPressed:
                              OnlineDownloadManager.instance.clearFinished,
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
                    final isLoading = _downloading.contains(key);
                    return ListTile(
                      leading: _coverImage(item.coverUrl),
                      title: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: _sourceBadge(context, item.source),
                      trailing: isLoading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator.adaptive(
                                strokeWidth: 2,
                              ),
                            )
                          : ElevatedButton(
                              onPressed: () => _startDownload(item),
                              child: const Text('下载'),
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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: SizedBox(
        height: 114,
        child: Row(
          children: [
            // 封面
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
            // 右侧操作区
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
    );
  }
}