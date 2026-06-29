import 'package:flutter/material.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';

class JmCommentsPageV2 extends StatefulWidget {
  const JmCommentsPageV2({
    super.key,
    required this.comicId,
    required this.totalComments,
  });

  final String comicId;
  final int totalComments;

  @override
  State<JmCommentsPageV2> createState() => _JmCommentsPageV2State();
}

class _JmCommentsPageV2State extends State<JmCommentsPageV2> {
  final List<JmComment> _comments = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  int _page = 1;
  int _totalPages = 1;
  bool _loading = true;
  bool _loadingMore = false;
  bool _sendingComment = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadComments();
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

  Future<void> _loadComments() async {
    final res = await JmNetwork().getComments(widget.comicId, _page);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res.error) {
        _error = res.errorMessageWithoutNull;
      } else {
        _comments.addAll(res.data);
        // subData 是总页数
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
    final res = await JmNetwork().getComments(widget.comicId, _page);
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      if (!res.error) {
        _comments.addAll(res.data);
      }
    });
  }

  Future<void> _sendComment() async {
    final content = _controller.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('评论内容不能为空')),
      );
      return;
    }

    setState(() => _sendingComment = true);
    final res = await JmNetwork().comment(widget.comicId, content);
    if (!mounted) return;
    setState(() => _sendingComment = false);

    if (res.error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发送失败: ${res.errorMessageWithoutNull}')),
      );
    } else {
      _controller.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('评论成功')),
      );
      // 延迟 5 秒后刷新评论列表（等待服务器处理）
      await Future.delayed(const Duration(seconds: 5));
      if (!mounted) return;
      setState(() {
        _comments.clear();
        _page = 1;
        _loading = true;
      });
      _loadComments();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('评论 (${widget.totalComments})'),
      ),
      body: Column(
        children: [
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
                              Text(
                                '加载失败: $_error',
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed: () {
                                  setState(() {
                                    _error = null;
                                    _loading = true;
                                    _page = 1;
                                    _comments.clear();
                                  });
                                  _loadComments();
                                },
                                icon: const Icon(Icons.refresh),
                                label: const Text('重试'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _comments.isEmpty
                        ? const Center(child: Text('暂无评论'))
                        : ListView.separated(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(16),
                            itemCount: _comments.length +
                                (_page < _totalPages ? 1 : 0),
                            separatorBuilder: (_, __) =>
                                const Divider(height: 24),
                            itemBuilder: (context, index) {
                              if (index == _comments.length) {
                                return const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(16),
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }
                              return _CommentCard(comment: _comments[index]);
                            },
                          ),
          ),
          // 发送框
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
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
                    enabled: !_sendingComment,
                    decoration: InputDecoration(
                      hintText: '发表评论...',
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
                    onSubmitted: (_) => _sendComment(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sendingComment ? null : _sendComment,
                  icon: _sendingComment
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

class _CommentCard extends StatelessWidget {
  const _CommentCard({required this.comment, this.isReply = false});

  final JmComment comment;
  final bool isReply;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final initial =
        comment.username.isNotEmpty ? comment.username[0].toUpperCase() : '?';

    return Padding(
      padding: EdgeInsets.only(left: isReply ? 32 : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头像：优先显示真实头像，fallback 为字母占位
              comment.avatar.isNotEmpty
                  ? CircleAvatar(
                      radius: isReply ? 13 : 16,
                      backgroundImage: NetworkImage(
                        comment.avatar,
                        headers: getJmImgHeaders(),
                      ),
                      onBackgroundImageError: (_, __) {},
                      child: Container(), // 加载失败时显示空容器
                    )
                  : CircleAvatar(
                      radius: isReply ? 13 : 16,
                      backgroundColor: colorScheme.primaryContainer,
                      child: Text(
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
                    Text(
                      comment.username,
                      style: textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (comment.timeAgo.isNotEmpty)
                      Text(
                        comment.timeAgo,
                        style: textTheme.bodySmall
                            ?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(comment.content, style: textTheme.bodyMedium),
          // 回复
          if (comment.replies.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final reply in comment.replies)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _CommentCard(comment: reply, isReply: true),
              ),
          ],
        ],
      ),
    );
  }
}
