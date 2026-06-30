import 'package:flutter/material.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';

/// 从详情页调用的评论页入口。
void showNhentaiComments(BuildContext context, String id) {
  Navigator.of(context).push(
    AppPageRoute(
      builder: (_) => NhentaiCommentsPage(id: id),
    ),
  );
}

/// Nhentai 评论页（只读）。
///
/// 一次性加载 [NhentaiNetwork.getComments]（无分页）。原版即无发送/点赞/回复能力，
/// 此处保持只读：仅渲染头像 / 用户名 / 时间 / 正文。
class NhentaiCommentsPage extends StatefulWidget {
  const NhentaiCommentsPage({super.key, required this.id});

  final String id;

  @override
  State<NhentaiCommentsPage> createState() => _NhentaiCommentsPageState();
}

class _NhentaiCommentsPageState extends State<NhentaiCommentsPage> {
  List<NhentaiComment> _comments = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadComments();
  }

  Future<void> _loadComments() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await NhentaiNetwork().getComments(widget.id);
    if (!mounted) return;
    if (res.error) {
      setState(() {
        _loading = false;
        _error = res.errorMessageWithoutNull;
      });
    } else {
      setState(() {
        _loading = false;
        _comments = res.data;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('评论'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _loadComments,
            tooltip: '刷新',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _loadComments, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_comments.isEmpty) {
      return const Center(child: Text('暂无评论'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _comments.length,
      separatorBuilder: (_, __) => const Divider(height: 20),
      itemBuilder: (_, index) => _NhentaiCommentCard(comment: _comments[index]),
    );
  }
}

class _NhentaiCommentCard extends StatelessWidget {
  const _NhentaiCommentCard({required this.comment});

  final NhentaiComment comment;

  String _formatDate(int seconds) {
    if (seconds <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: colorScheme.secondaryContainer,
              backgroundImage:
                  comment.avatar.isNotEmpty ? NetworkImage(comment.avatar) : null,
              onBackgroundImageError: comment.avatar.isNotEmpty ? (_, __) {} : null,
              child: comment.avatar.isEmpty
                  ? Text(
                      comment.userName.isNotEmpty
                          ? comment.userName[0].toUpperCase()
                          : '?',
                      style: TextStyle(
                        color: colorScheme.onSecondaryContainer,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    comment.userName,
                    style: textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _formatDate(comment.date),
                    style: textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SelectableText(comment.content, style: textTheme.bodyMedium),
      ],
    );
  }
}
