import 'package:flutter/material.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';

class JmCommentsPage extends StatefulWidget {
  const JmCommentsPage({
    super.key,
    required this.comicId,
    required this.totalComments,
  });

  final String comicId;
  final int totalComments;

  @override
  State<JmCommentsPage> createState() => _JmCommentsPageState();
}

class _JmCommentsPageState extends State<JmCommentsPage> {
  late Future<List<JmComment>> _future = _loadComments();
  final int _page = 1;

  Future<List<JmComment>> _loadComments() async {
    final res = await JmNetwork().getComments(widget.comicId, _page);
    if (res.error) throw res.errorMessageWithoutNull;
    return res.data;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('评论 (${widget.totalComments})'),
      ),
      body: FutureBuilder<List<JmComment>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 12),
                    Text(
                      '加载失败: ${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () =>
                          setState(() => _future = _loadComments()),
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            );
          }
          final comments = snapshot.data!;
          if (comments.isEmpty) {
            return const Center(child: Text('暂无评论'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: comments.length,
            separatorBuilder: (_, __) => const Divider(height: 24),
            itemBuilder: (context, index) =>
                _CommentCard(comment: comments[index]),
          );
        },
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
              CircleAvatar(
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
