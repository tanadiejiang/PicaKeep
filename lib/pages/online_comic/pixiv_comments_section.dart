import 'package:flutter/material.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';

typedef PixivCommentRootsLoader = Future<Res<PixivCommentPage>> Function(
    String illustId, int offset, int limit);
typedef PixivCommentRepliesLoader = Future<Res<PixivCommentPage>> Function(
    String commentId, int page);

class PixivCommentsSection extends StatefulWidget {
  const PixivCommentsSection({
    super.key,
    required this.illustId,
    this.autoLoad = true,
    this.loadRoots,
    this.loadReplies,
  });

  final String illustId;
  final bool autoLoad;
  final PixivCommentRootsLoader? loadRoots;
  final PixivCommentRepliesLoader? loadReplies;

  @override
  State<PixivCommentsSection> createState() => _PixivCommentsSectionState();
}

class _ReplyState {
  final comments = <PixivComment>[];
  bool loading = false;
  bool loaded = false;
  bool hasNext = false;
  bool expanded = false;
  int page = 1;
  String? error;
}

class _PixivCommentsSectionState extends State<PixivCommentsSection> {
  final _comments = <PixivComment>[];
  final _replies = <String, _ReplyState>{};
  bool _loading = false;
  bool _loaded = false;
  bool _hasNext = false;
  bool _autoLoadQueued = false;
  int _offset = 0;
  int _generation = 0;
  String? _error;

  String _message(Object error) => error
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceFirst('StateError: ', '');

  PixivCommentRootsLoader get _rootsLoader =>
      widget.loadRoots ??
      (id, offset, limit) =>
          PixivNetwork().getComments(id, offset: offset, limit: limit);

  PixivCommentRepliesLoader get _repliesLoader =>
      widget.loadReplies ??
      (id, page) => PixivNetwork().getCommentReplies(id, page: page);

  @override
  void didUpdateWidget(covariant PixivCommentsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.illustId != widget.illustId) {
      _generation++;
      _comments.clear();
      _replies.clear();
      _loading = false;
      _loaded = false;
      _hasNext = false;
      _offset = 0;
      _error = null;
      _autoLoadQueued = false;
    }
  }

  void _queueVisibleAutoLoad() {
    if (!widget.autoLoad || _loaded || _loading || _autoLoadQueued) return;
    _autoLoadQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoLoadQueued = false;
      if (mounted && widget.autoLoad && !_loaded) _loadRoots();
    });
  }

  Future<void> _loadRoots() async {
    if (_loading) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _rootsLoader(widget.illustId, _offset, 20);
      if (!mounted || generation != _generation) return;
      if (page.error) throw StateError(page.errorMessageWithoutNull);
      final seen = _comments.map((item) => item.id).toSet();
      final incoming = <PixivComment>[];
      for (final item in page.data.comments) {
        if (seen.add(item.id)) incoming.add(item);
      }
      setState(() {
        _comments.addAll(incoming);
        _offset += page.data.originalCount;
        _hasNext = page.data.hasNext && page.data.originalCount > 0;
        _loaded = true;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _loaded = true;
        _error = _message(error);
      });
    }
  }

  Future<void> _toggleReplies(PixivComment root) async {
    final state = _replies.putIfAbsent(root.id, _ReplyState.new);
    if (state.loaded) {
      setState(() => state.expanded = !state.expanded);
      return;
    }
    await _loadReplies(root, state);
  }

  Future<void> _loadReplies(PixivComment root, _ReplyState state) async {
    if (state.loading) return;
    final generation = _generation;
    setState(() {
      state.loading = true;
      state.error = null;
      state.expanded = true;
    });
    try {
      final page = await _repliesLoader(root.id, state.page);
      if (!mounted || generation != _generation) return;
      if (page.error) throw StateError(page.errorMessageWithoutNull);
      final seen = state.comments.map((item) => item.id).toSet();
      for (final item in page.data.comments) {
        if (seen.add(item.id)) state.comments.add(item);
      }
      setState(() {
        state.page++;
        state.hasNext = page.data.hasNext && page.data.originalCount > 0;
        state.loaded = true;
        state.loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        state.loading = false;
        state.loaded = state.comments.isNotEmpty;
        state.error = _message(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded && !widget.autoLoad) return _explicitTrigger(context);
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        if (widget.autoLoad && constraints.remainingPaintExtent > 0) {
          _queueVisibleAutoLoad();
        }
        return SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildRow(context, index),
            childCount: _rowCount,
          ),
        );
      },
    );
  }

  int get _rowCount {
    var count = 1;
    if (_error != null) count++;
    count += _comments.length;
    if (_comments.isEmpty && _loaded && _error == null) count++;
    if (_hasNext) count++;
    return count;
  }

  Widget _explicitTrigger(BuildContext context) => SliverToBoxAdapter(
        child: Material(
          color: Colors.transparent,
          child: ListTile(
            leading: const Icon(Icons.comment_outlined),
            title: const Text('评论'),
            subtitle: Text(_error ?? '点击加载在线评论'),
            trailing: _error == null
                ? null
                : IconButton(
                    tooltip: '重试',
                    onPressed: _loading ? null : _loadRoots,
                    icon: const Icon(Icons.refresh),
                  ),
            onTap: _loading ? null : _loadRoots,
          ),
        ),
      );

  Widget _buildRow(BuildContext context, int index) {
    final colors = Theme.of(context).colorScheme;
    if (index == 0) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Row(children: [
          Text('评论', style: Theme.of(context).textTheme.titleLarge),
          const Spacer(),
          if (_loading)
            const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
      );
    }
    var cursor = 1;
    if (_error != null) {
      if (index == cursor) {
        return Material(
          color: Colors.transparent,
          child: ListTile(
            title: Text(_error!, style: TextStyle(color: colors.error)),
            trailing: IconButton(
                tooltip: '重试',
                onPressed: _loading ? null : _loadRoots,
                icon: const Icon(Icons.refresh)),
          ),
        );
      }
      cursor++;
    }
    if (index < cursor + _comments.length) {
      return _comment(context, _comments[index - cursor]);
    }
    cursor += _comments.length;
    if (_comments.isEmpty && _loaded && _error == null) {
      if (index == cursor) {
        return const Padding(
            padding: EdgeInsets.all(24), child: Center(child: Text('暂无评论')));
      }
      cursor++;
    }
    if (_hasNext && index == cursor) {
      return Center(
        child: TextButton.icon(
          onPressed: _loading ? null : _loadRoots,
          icon: const Icon(Icons.expand_more),
          label: const Text('加载更多评论'),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _comment(BuildContext context, PixivComment comment) {
    final state = _replies[comment.id];
    final replies = state?.comments ?? const <PixivComment>[];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _avatar(context, comment),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(comment.userName.isEmpty ? 'Pixiv用户' : comment.userName,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                _commentBody(context, comment),
                if (comment.commentDate.isNotEmpty)
                  Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(comment.commentDate,
                          style: Theme.of(context).textTheme.bodySmall)),
                if (comment.hasReplies == true || state != null)
                  _replyControls(context, comment, state),
                if (state?.error != null)
                  Row(children: [
                    Expanded(
                        child: Text(state!.error!,
                            style: TextStyle(color: colors(context).error))),
                    IconButton(
                        tooltip: '重试',
                        onPressed: state.loading
                            ? null
                            : () => _loadReplies(comment, state),
                        icon: const Icon(Icons.refresh)),
                  ]),
                if (state?.expanded == true)
                  for (final reply in replies) _reply(context, reply),
              ])),
        ]),
        const Divider(height: 16),
      ]),
    );
  }

  ColorScheme colors(BuildContext context) => Theme.of(context).colorScheme;

  Widget _replyControls(
      BuildContext context, PixivComment comment, _ReplyState? state) {
    if (state?.loading == true) {
      return const Padding(
          padding: EdgeInsets.only(top: 4),
          child: SizedBox.square(
              dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    final loaded = state?.loaded == true;
    return Row(children: [
      TextButton(
        onPressed: () => _toggleReplies(comment),
        child: Text(loaded && state!.expanded ? '收起回复' : '查看回复'),
      ),
      if (loaded && state!.hasNext)
        TextButton(
            onPressed: () => _loadReplies(comment, state),
            child: const Text('加载更多')),
    ]);
  }

  Widget _reply(BuildContext context, PixivComment reply) => Padding(
        padding: const EdgeInsets.only(top: 8, left: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _avatar(context, reply, radius: 14),
          const SizedBox(width: 8),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(reply.userName.isEmpty ? 'Pixiv用户' : reply.userName,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                _commentBody(context, reply),
                if (reply.commentDate.isNotEmpty)
                  Text(reply.commentDate,
                      style: Theme.of(context).textTheme.bodySmall),
              ])),
        ]),
      );

  Widget _avatar(BuildContext context, PixivComment comment,
      {double radius = 18}) {
    final fallback = comment.userName.trim().isEmpty
        ? '?'
        : comment.userName.trim().characters.first;
    return CircleAvatar(
      radius: radius,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: comment.avatarUrl.isEmpty
          ? Text(fallback)
          : ClipOval(
              child: Image.network(comment.avatarUrl,
                  width: radius * 2,
                  height: radius * 2,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Center(child: Text(fallback))),
            ),
    );
  }

  Widget _commentBody(BuildContext context, PixivComment comment) {
    final children = <Widget>[];
    if (comment.comment.trim().isNotEmpty) children.add(Text(comment.comment));
    if (comment.stampId != null && comment.stampUrl != null) {
      final stampUrl = comment.stampUrl!;
      final stampId = comment.stampId!;
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Image.network(
            stampUrl,
            width: 64,
            height: 64,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => Text('表情 $stampId'),
          ),
        ),
      );
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}
