import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_conversation_store.dart';
import 'package:picakeep/pages/ai/ai_page.dart';
import 'package:picakeep/tools/translations.dart';

class AiChatPage extends StatefulWidget {
  const AiChatPage({super.key});

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage> {
  AiConversationController? _controller;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late final TextEditingController _inputController;
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController();
    _scrollController = ScrollController();
    _loadController();
  }

  Future<void> _loadController() async {
    final lastId = await AiConversationStore.loadLastActiveId();
    final ctrl = await AiConversationController.create(loadId: lastId);
    if (mounted) {
      setState(() => _controller = ctrl);
      _controller!.addListener(_onControllerUpdate);
    }
  }

  Future<void> _switchConversation(AiConversationMeta meta) async {
    final newCtrl = await AiConversationController.create(loadId: meta.id);
    if (mounted) {
      _controller?.removeListener(_onControllerUpdate);
      _controller?.dispose();
      setState(() => _controller = newCtrl);
      _controller!.addListener(_onControllerUpdate);
      await AiConversationStore.saveLastActiveId(meta.id);
    }
  }

  Future<void> _newConversation() async {
    final newCtrl = await AiConversationController.create();
    if (mounted) {
      _controller?.removeListener(_onControllerUpdate);
      _controller?.dispose();
      setState(() => _controller = newCtrl);
      _controller!.addListener(_onControllerUpdate);
      if (newCtrl.conversationId != null) {
        await AiConversationStore.saveLastActiveId(newCtrl.conversationId!);
      }
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onControllerUpdate);
    _controller?.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onControllerUpdate() {
    setState(() {});
    // 自动滚动到底部
    if (_scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  Widget _buildEmptyGuide(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dimColor = colorScheme.onSurface.withValues(alpha: 0.4);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 48, color: dimColor),
            const SizedBox(height: 16),
            Text(
              'AI 助手',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '当前对话的上下文在本次会话中保留，\n关闭对话或清空后重置。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: dimColor),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _buildExampleChip(context, '我有没有下过 XXX'),
                _buildExampleChip(context, '帮我搜索 XXX'),
                _buildExampleChip(context, '我收藏过 XXX 吗'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExampleChip(BuildContext context, String text) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(
          color: colorScheme.outline.withValues(alpha: 0.4),
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        '「$text」',
        style: TextStyle(
          fontSize: 12,
          color: colorScheme.onSurface.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    _controller!.send(text);
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      key: _scaffoldKey,
      drawer: _ConversationDrawer(
        currentId: _controller!.conversationId,
        onSelect: _switchConversation,
        onNewConversation: _newConversation,
      ),
      appBar: AppBar(
        title: Text('AI 对话'.tl),
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空对话'.tl,
            onPressed: _controller!.isLoading
                ? null
                : () {
                    _controller!.clear();
                  },
          ),
          IconButton(
            icon: const Icon(Icons.build_outlined),
            tooltip: '工具调试'.tl,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (ctx) => const AiToolDebugPage(),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 消息列表
          Expanded(
            child: _controller!.displayMessages.isEmpty &&
                    _controller!.pendingDownload == null
                ? _buildEmptyGuide(context)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(8),
                    itemCount: _controller!.displayMessages.length +
                        (_controller!.pendingDownload != null ? 1 : 0),
                    itemBuilder: (context, index) {
                      // 如果是最后一项且有 pendingDownload，显示确认卡片
                      if (index == _controller!.displayMessages.length &&
                          _controller!.pendingDownload != null) {
                        return _DownloadConfirmCard(
                          pending: _controller!.pendingDownload!,
                          onConfirm: (confirmed) =>
                              _controller!.confirmDownload(confirmed),
                        );
                      }

                      final message = _controller!.displayMessages[index];
                      return _MessageBubble(message: message);
                    },
                  ),
          ),

          // 加载指示器
          if (_controller!.isLoading)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('思考中...', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),

          // 错误提示
          if (_controller!.error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: Theme.of(context).colorScheme.errorContainer,
              child: Text(
                _controller!.error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                  fontSize: 12,
                ),
              ),
            ),

          // 输入框
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    decoration: InputDecoration(
                      hintText: _controller!.pendingDownload != null
                          ? '请先处理下载确认'.tl
                          : '输入消息...'.tl,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      isDense: true,
                    ),
                    maxLines: 3,
                    minLines: 1,
                    enabled: !_controller!.isLoading &&
                        _controller!.pendingDownload == null,
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _controller!.isLoading ||
                          _controller!.pendingDownload != null
                      ? null
                      : _send,
                  child: Text('发送'.tl),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 消息气泡
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final AiChatMessage message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    switch (message.type) {
      case AiChatMessageType.user:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(12),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7,
            ),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              message.text,
              style: TextStyle(color: colorScheme.onPrimaryContainer),
            ),
          ),
        );

      case AiChatMessageType.assistant:
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(12),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7,
            ),
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              message.text,
              style: TextStyle(color: colorScheme.onSecondaryContainer),
            ),
          ),
        );

      case AiChatMessageType.toolCall:
        return _ToolCard(
          toolName: message.toolName!,
          toolArgs: message.toolArgs,
          isResult: false,
        );

      case AiChatMessageType.toolResult:
        return _ToolCard(
          toolName: message.toolName!,
          resultText: message.text,
          resultData: message.toolData,
          isResult: true,
        );

      case AiChatMessageType.error:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: colorScheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message.text,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
              ),
            ],
          ),
        );

      default:
        return const SizedBox.shrink();
    }
  }
}

/// 工具调用/结果卡片
class _ToolCard extends StatefulWidget {
  const _ToolCard({
    required this.toolName,
    this.toolArgs,
    this.resultText,
    this.resultData,
    required this.isResult,
  });

  final String toolName;
  final Map<String, dynamic>? toolArgs;
  final String? resultText;
  final Object? resultData;
  final bool isResult;

  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            dense: true,
            leading: Icon(
              widget.isResult ? Icons.check_circle_outline : Icons.build,
              size: 20,
              color: colorScheme.onSurfaceVariant,
            ),
            title: Text(
              widget.toolName,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: widget.isResult
                ? Text(widget.resultText ?? '', style: const TextStyle(fontSize: 11))
                : null,
            trailing: IconButton(
              icon: Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: 20,
              ),
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _formatJson(widget.isResult
                      ? widget.resultData
                      : widget.toolArgs),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatJson(Object? obj) {
    try {
      return const JsonEncoder.withIndent('  ').convert(obj ?? {});
    } catch (_) {
      return obj?.toString() ?? '';
    }
  }
}

/// 下载确认卡片
class _DownloadConfirmCard extends StatelessWidget {
  const _DownloadConfirmCard({
    required this.pending,
    required this.onConfirm,
  });

  final PendingDownload pending;
  final void Function(bool) onConfirm;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final title = pending.title?.toString() ?? '未知漫画';
    final source = pending.source;
    final comicId = pending.comicId;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.download_outlined,
                  color: colorScheme.onTertiaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '确认下载'.tl,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onTertiaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '漫画：$title',
              style: TextStyle(color: colorScheme.onTertiaryContainer),
            ),
            Text(
              '来源：$source，ID：$comicId',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onTertiaryContainer.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => onConfirm(false),
                  child: Text('取消'.tl),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => onConfirm(true),
                  child: Text('确认下载'.tl),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 会话侧栏抽屉
class _ConversationDrawer extends StatefulWidget {
  final String? currentId;
  final Future<void> Function(AiConversationMeta) onSelect;
  final VoidCallback onNewConversation;

  const _ConversationDrawer({
    required this.currentId,
    required this.onSelect,
    required this.onNewConversation,
  });

  @override
  State<_ConversationDrawer> createState() => _ConversationDrawerState();
}

class _ConversationDrawerState extends State<_ConversationDrawer> {
  Future<List<AiConversationMeta>>? _indexFuture;

  @override
  void initState() {
    super.initState();
    _indexFuture = AiConversationStore.loadIndex();
  }

  void _refresh() {
    setState(() => _indexFuture = AiConversationStore.loadIndex());
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          Container(
            color: Theme.of(context).colorScheme.primaryContainer,
            padding: const EdgeInsets.fromLTRB(16, 48, 16, 12),
            width: double.infinity,
            child: Text(
              '历史会话',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('新建会话'),
            onTap: () {
              Navigator.pop(context);
              widget.onNewConversation();
            },
          ),
          const Divider(),
          Expanded(
            child: FutureBuilder<List<AiConversationMeta>>(
              future: _indexFuture,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final list = snapshot.data!;
                if (list.isEmpty) {
                  return const Center(child: Text('暂无历史会话'));
                }
                return ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, index) {
                    final meta = list[index];
                    final isCurrent = meta.id == widget.currentId;
                    return ListTile(
                      selected: isCurrent,
                      title: Text(
                        meta.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(_formatTime(meta.updatedAt)),
                      onTap: () {
                        if (!isCurrent) {
                          Navigator.pop(context);
                          widget.onSelect(meta);
                        }
                      },
                      onLongPress: () => _confirmDelete(context, meta),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, AiConversationMeta meta) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定删除「${meta.title}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await AiConversationStore.delete(meta.id);
      _refresh();
    }
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 30) return '${diff.inDays}天前';
    if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}个月前';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }
}
