import 'package:flutter/material.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';

/// picacg 回复页。展示某条评论的所有回复，并支持发送回复。
class PicacgReplyPage extends StatefulWidget {
  const PicacgReplyPage({
    super.key,
    required this.replyTo,
  });

  /// 被回复的原评论。
  final PicacgComment replyTo;

  @override
  State<PicacgReplyPage> createState() => _PicacgReplyPageState();
}

class _PicacgReplyPageState extends State<PicacgReplyPage> {
  final List<PicacgComment> _replies = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  int _page = 1;
  int _totalPages = 1;
  bool _loading = true;
  bool _loadingMore = false;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadReplies();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_loadingMore &&
        _page < _totalPages) {
      _loadMore();
    }
  }

  Future<void> _loadReplies() async {
    final res =
        await PicacgNetwork().getReply(widget.replyTo.commentId, _page);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res.error) {
        _error = res.errorMessageWithoutNull;
      } else {
        _replies.addAll(res.data);
        if (res.subData != null && res.subData is int) {
          _totalPages = res.subData as int;
        }
      }
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _page >= _totalPages) return;
    setState(() => _loadingMore = true);
    _page++;
    final res =
        await PicacgNetwork().getReply(widget.replyTo.commentId, _page);
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      if (!res.error) _replies.addAll(res.data);
    });
  }

  Future<void> _sendReply() async {
    final content = _controller.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('回复内容不能为空')),
      );
      return;
    }
    setState(() => _sending = true);
    final res =
        await PicacgNetwork().sendReply(widget.replyTo.commentId, content);
    if (!mounted) return;
    setState(() => _sending = false);

    if (res.error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发送失败: ${res.errorMessageWithoutNull}')),
      );
    } else {
      _controller.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('回复成功')),
      );
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      setState(() {
        _replies.clear();
        _page = 1;
        _loading = true;
      });
      _loadReplies();
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('回复 (${widget.replyTo.replyCount})'),
      ),
      body: Column(
        children: [
          // ── 被回复的原评论 ──────────────────────────────
          Container(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: _CommentRow(
              comment: widget.replyTo,
              textTheme: textTheme,
              colorScheme: colorScheme,
              showLike: false,
            ),
          ),
          const Divider(height: 1),

          // ── 回复列表 ────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.error_outline, size: 48),
                              const SizedBox(height: 12),
                              Text('加载失败: $_error',
                                  textAlign: TextAlign.center),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed: () {
                                  setState(() {
                                    _error = null;
                                    _loading = true;
                                    _page = 1;
                                    _replies.clear();
                                  });
                                  _loadReplies();
                                },
                                icon: const Icon(Icons.refresh),
                                label: const Text('重试'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _replies.isEmpty
                        ? const Center(child: Text('暂无回复'))
                        : ListView.separated(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(16),
                            itemCount:
                                _replies.length + (_page < _totalPages ? 1 : 0),
                            separatorBuilder: (_, __) =>
                                const Divider(height: 24),
                            itemBuilder: (context, index) {
                              if (index == _replies.length) {
                                return const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(16),
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }
                              return _CommentRow(
                                comment: _replies[index],
                                textTheme: textTheme,
                                colorScheme: colorScheme,
                                showLike: true,
                              );
                            },
                          ),
          ),

          // ── 发送框 ──────────────────────────────────────
          Container(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: 12 + MediaQuery.of(context).padding.bottom,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    enabled: !_sending,
                    decoration: InputDecoration(
                      hintText: '回复 ${widget.replyTo.name}...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    maxLines: null,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendReply(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sending ? null : _sendReply,
                  icon: _sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 评论/回复展示行（无状态，点赞由调用方决定是否显示）。
class _CommentRow extends StatelessWidget {
  const _CommentRow({
    required this.comment,
    required this.textTheme,
    required this.colorScheme,
    this.showLike = true,
  });

  final PicacgComment comment;
  final TextTheme textTheme;
  final ColorScheme colorScheme;
  final bool showLike;

  @override
  Widget build(BuildContext context) {
    final initial =
        comment.name.isNotEmpty ? comment.name[0].toUpperCase() : '?';
    final date = comment.createdAt.length >= 10
        ? comment.createdAt.substring(0, 10)
        : comment.createdAt;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: colorScheme.primaryContainer,
          backgroundImage: comment.avatarUrl.isNotEmpty
              ? NetworkImage(comment.avatarUrl)
              : null,
          child: comment.avatarUrl.isNotEmpty
              ? null
              : Text(
                  initial,
                  style: textTheme.labelMedium
                      ?.copyWith(color: colorScheme.onPrimaryContainer),
                ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      comment.name,
                      style: textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Lv.${comment.level}',
                    style: textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
              if (date.isNotEmpty)
                Text(
                  date,
                  style: textTheme.bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              const SizedBox(height: 4),
              Text(comment.content, style: textTheme.bodyMedium),
              if (showLike) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Spacer(),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          comment.isLiked
                              ? Icons.favorite
                              : Icons.favorite_border,
                          size: 14,
                          color: comment.isLiked
                              ? colorScheme.error
                              : colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${comment.likes}',
                          style: textTheme.bodySmall?.copyWith(
                            color: comment.isLiked
                                ? colorScheme.error
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
