import 'package:flutter/material.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';

/// 从详情页调用的评论页入口。
void showEhComments(
  BuildContext context,
  String link,
  String uploader,
  Map<String, String> auth,
) {
  Navigator.of(context).push(
    AppPageRoute(
      builder: (_) => EhCommentsPage(
        link: link,
        uploader: uploader,
        auth: auth,
      ),
    ),
  );
}

/// E-Hentai 评论页。
///
/// 功能：评论列表（分页加载）+ 发送评论 + 对评论投票（点赞/点踩）。
/// 鉴权通过 `auth` Map（含 gid/token/apiuid/apikey）。
class EhCommentsPage extends StatefulWidget {
  const EhCommentsPage({
    super.key,
    required this.link,
    required this.uploader,
    required this.auth,
  });

  final String link;
  final String uploader;
  final Map<String, String> auth;

  @override
  State<EhCommentsPage> createState() => _EhCommentsPageState();
}

class _EhCommentsPageState extends State<EhCommentsPage> {
  final _textController = TextEditingController();
  List<Comment> _comments = [];
  bool _loading = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadComments();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadComments() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await EhNetwork().getComments(widget.link);
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

  Future<void> _sendComment() async {
    final content = _textController.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('评论内容不能为空')));
      return;
    }
    setState(() => _sending = true);
    final res = await EhNetwork().comment(content, widget.link);
    if (!mounted) return;
    setState(() => _sending = false);
    if (res.error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发送失败: ${res.errorMessageWithoutNull}')),
      );
    } else {
      _textController.clear();
      FocusScope.of(context).unfocus();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('评论成功')));
      // 延迟后重载（等服务器处理）
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      _loadComments();
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
      body: Column(
        children: [
          // 评论列表
          Expanded(child: _buildCommentList()),
          // 发送评论输入框
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildCommentList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _loadComments, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_comments.isEmpty) {
      return const Center(child: Text('暂无评论，来抢沙发吧~'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _comments.length,
      separatorBuilder: (_, __) => const Divider(height: 20),
      itemBuilder: (_, index) => _EhCommentCard(
        comment: _comments[index],
        auth: widget.auth,
      ),
    );
  }

  Widget _buildInputBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                enabled: !_sending,
                maxLines: null,
                minLines: 1,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: '发表评论...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _sending ? null : _sendComment,
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
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  单条评论卡片（含投票）
// ═══════════════════════════════════════════════════════════════════════════

class _EhCommentCard extends StatefulWidget {
  const _EhCommentCard({required this.comment, required this.auth});

  final Comment comment;
  final Map<String, String> auth;

  @override
  State<_EhCommentCard> createState() => _EhCommentCardState();
}

class _EhCommentCardState extends State<_EhCommentCard> {
  bool _voting = false;

  Future<void> _vote(bool isUp) async {
    if (_voting) return;
    setState(() => _voting = true);
    final comment = widget.comment;
    // 乐观更新
    final prevVote = comment.voteUP;
    final prevScore = comment.score;
    setState(() {
      if (comment.voteUP == isUp) {
        // 同向再点 → 撤销
        comment.voteUP = null;
        comment.score += isUp ? -1 : 1;
      } else {
        // 换向或首次投票
        if (comment.voteUP != null) {
          comment.score += isUp ? 2 : -2;
        } else {
          comment.score += isUp ? 1 : -1;
        }
        comment.voteUP = isUp;
      }
    });

    final res = await EhNetwork().voteComment(widget.auth, comment.id, isUp);
    if (!mounted) return;
    setState(() {
      _voting = false;
      if (res.error) {
        // 失败回滚
        comment.voteUP = prevVote;
        comment.score = prevScore;
      } else {
        comment.score = res.data;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final comment = widget.comment;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 用户名 + 时间
        Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: colorScheme.secondaryContainer,
              child: Text(
                comment.name.isNotEmpty ? comment.name[0].toUpperCase() : '?',
                style: TextStyle(
                  color: colorScheme.onSecondaryContainer,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    comment.name,
                    style: textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    comment.time,
                    style: textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            // 分数
            Text(
              comment.score >= 0 ? '+${comment.score}' : '${comment.score}',
              style: textTheme.bodySmall?.copyWith(
                color: comment.score > 0
                    ? Colors.green
                    : comment.score < 0
                        ? Colors.red
                        : colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 评论正文
        SelectableText(comment.content, style: textTheme.bodyMedium),
        const SizedBox(height: 6),
        // 投票按钮
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _VoteButton(
              icon: Icons.thumb_up_outlined,
              activeIcon: Icons.thumb_up,
              active: comment.voteUP == true,
              onTap: _voting ? null : () => _vote(true),
            ),
            const SizedBox(width: 4),
            _VoteButton(
              icon: Icons.thumb_down_outlined,
              activeIcon: Icons.thumb_down,
              active: comment.voteUP == false,
              onTap: _voting ? null : () => _vote(false),
            ),
          ],
        ),
      ],
    );
  }
}

class _VoteButton extends StatelessWidget {
  const _VoteButton({
    required this.icon,
    required this.activeIcon,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(active ? activeIcon : icon, size: 18, color: color),
      ),
    );
  }
}
