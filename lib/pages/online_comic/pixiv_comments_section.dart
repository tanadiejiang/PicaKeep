import 'package:flutter/material.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
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
    this.previewLimit,
    this.loadRoots,
    this.loadReplies,
  }) : assert(previewLimit == null || (previewLimit > 0 && previewLimit <= 20));

  final String illustId;
  final bool autoLoad;

  /// A null limit preserves the full, manually paginated comments section.
  final int? previewLimit;
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
  final _headerKey = GlobalKey(debugLabel: 'pixiv-comments-header');
  bool _expanded = false;
  bool _entryActive = true;
  bool _autoLoadVisible = false;
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    _entryActive = PixivDetailEntryScope.isActiveOf(context) &&
        TickerMode.valuesOf(context).enabled;
  }

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
      _autoLoadVisible = false;
      _expanded = false;
    }
  }

  bool get _showAllRoots =>
      widget.previewLimit == null || (_expanded && _entryActive);

  int get _visibleRootCount => _showAllRoots
      ? _comments.length
      : _comments.length.clamp(0, widget.previewLimit!);

  bool get _canExpand =>
      widget.previewLimit != null &&
      (_comments.length > widget.previewLimit! || _hasNext);

  int get _placeholderCount =>
      widget.previewLimit != null && !_loaded && _error == null
          ? widget.previewLimit!
          : 0;

  void _queueVisibleAutoLoad() {
    if (!widget.autoLoad ||
        !_entryActive ||
        _loaded ||
        _loading ||
        _autoLoadQueued) {
      return;
    }
    final generation = _generation;
    _autoLoadQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      _autoLoadQueued = false;
      if (widget.autoLoad && _entryActive && _autoLoadVisible && !_loaded) {
        _loadRoots();
      }
    });
  }

  void _expandRoots() {
    if (_loading || !_entryActive) return;
    final needsPage = _hasNext && _comments.length <= widget.previewLimit!;
    setState(() => _expanded = true);
    // Revealing cached roots is enough. A user expansion requests at most one
    // page when the preview has no hidden roots to reveal.
    if (needsPage) _loadRoots();
  }

  void _collapseRoots() {
    setState(() {
      _expanded = false;
      for (final state in _replies.values) {
        state.expanded = false;
      }
    });
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation || !_entryActive || _expanded) {
        return;
      }
      final headerContext = _headerKey.currentContext;
      if (headerContext != null) {
        Scrollable.ensureVisible(headerContext,
            duration: const Duration(milliseconds: 180),
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
      }
    });
  }

  Future<void> _loadRoots() async {
    if (_loading || !_entryActive) return;
    final generation = _generation;
    final limit = widget.previewLimit != null && !_expanded && _offset == 0
        ? widget.previewLimit!
        : 20;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _rootsLoader(widget.illustId, _offset, limit);
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
    if (!_entryActive) return;
    final state = _replies.putIfAbsent(root.id, _ReplyState.new);
    if (state.loading) return;
    if (state.loaded) {
      setState(() => state.expanded = !state.expanded);
      return;
    }
    await _loadReplies(root, state);
  }

  Future<void> _loadReplies(PixivComment root, _ReplyState state) async {
    if (state.loading || !_entryActive) return;
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
        _autoLoadVisible = constraints.remainingPaintExtent > 0;
        if (_autoLoadVisible) _queueVisibleAutoLoad();
        return SliverMainAxisGroup(slivers: [
          // Keep the header mounted even when the lazy root list scrolls away.
          SliverToBoxAdapter(child: _header(context)),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildRow(context, index),
              childCount: _rowCount,
            ),
          ),
        ]);
      },
    );
  }

  bool get _showRootControls =>
      widget.previewLimit == null ? _hasNext : _showAllRoots || _canExpand;

  int get _rowCount {
    var count = _visibleRootCount + _placeholderCount;
    if (_error != null) count++;
    if (_comments.isEmpty && _loaded && _error == null) count++;
    if (_showRootControls) count++;
    return count;
  }

  Widget _header(BuildContext context) => Padding(
        key: _headerKey,
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Row(
            key: ValueKey('pixiv-comments-header-${widget.illustId}'),
            children: [
              Text('评论', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              if (_loading)
                const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
      );

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
    var cursor = 0;
    if (_error != null) {
      if (index == cursor) {
        return Material(
          color: Colors.transparent,
          child: ListTile(
            title: Text(_error!, style: TextStyle(color: colors.error)),
            trailing: IconButton(
                tooltip: '重试',
                onPressed: _loading || !_entryActive ? null : _loadRoots,
                icon: const Icon(Icons.refresh)),
          ),
        );
      }
      cursor++;
    }
    if (index < cursor + _visibleRootCount) {
      return _comment(context, _comments[index - cursor]);
    }
    cursor += _visibleRootCount;
    if (index < cursor + _placeholderCount) {
      return _previewPlaceholder(context, index - cursor);
    }
    cursor += _placeholderCount;
    if (_comments.isEmpty && _loaded && _error == null) {
      if (index == cursor) {
        return const Padding(
            padding: EdgeInsets.all(24), child: Center(child: Text('暂无评论')));
      }
      cursor++;
    }
    if (_showRootControls && index == cursor) return _rootControls(context);
    return const SizedBox.shrink();
  }

  Widget _rootControls(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Center(
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              if (widget.previewLimit != null && !_showAllRoots)
                TextButton.icon(
                  key: ValueKey('pixiv-comments-expand-${widget.illustId}'),
                  onPressed: _loading || !_entryActive ? null : _expandRoots,
                  icon: const Icon(Icons.expand_more),
                  label: const Text('展开更多评论'),
                )
              else ...[
                if (_hasNext)
                  TextButton.icon(
                    onPressed: _loading || !_entryActive ? null : _loadRoots,
                    icon: const Icon(Icons.expand_more),
                    label: const Text('加载更多评论'),
                  ),
                if (widget.previewLimit != null)
                  TextButton.icon(
                    key: ValueKey('pixiv-comments-collapse-${widget.illustId}'),
                    onPressed: _entryActive ? _collapseRoots : null,
                    icon: const Icon(Icons.expand_less),
                    label: const Text('收起评论'),
                  ),
              ],
            ],
          ),
        ),
      );

  Widget _previewPlaceholder(BuildContext context, int index) => Semantics(
        key: ValueKey('pixiv-comments-placeholder-${widget.illustId}-$index'),
        label: '正在加载第${index + 1}条评论',
        child: LayoutBuilder(builder: (context, constraints) {
          final width = (constraints.maxWidth - 78).clamp(1.0, double.infinity);
          final theme = Theme.of(context);
          final color = theme.colorScheme.surfaceContainerHighest;
          final textScaler = MediaQuery.textScalerOf(context);
          double textHeight(String text, TextStyle? style, int lines) {
            final painter = TextPainter(
                text: TextSpan(text: text, style: style),
                textDirection: Directionality.of(context),
                textScaler: textScaler,
                maxLines: lines)
              ..layout(maxWidth: width);
            return painter.height;
          }

          Widget line(double height, double fraction) => SizedBox(
                height: height,
                width: width * fraction,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    height: height * .55,
                    decoration: BoxDecoration(
                        color: color, borderRadius: BorderRadius.circular(4)),
                  ),
                ),
              );

          // At most one nickname line, two short caption lines, one date line,
          // and the same 64dp stamp slot as a real comment. Width and text scale
          // affect this finite budget, never a server count or unknown content.
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CircleAvatar(radius: 18, backgroundColor: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        line(textHeight('用户昵称', theme.textTheme.bodyMedium, 1),
                            .4),
                        const SizedBox(height: 4),
                        line(
                            textHeight('评论内容预览', theme.textTheme.bodyMedium, 2),
                            .85),
                        const SizedBox(height: 4),
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        const SizedBox(height: 4),
                        line(
                            textHeight(
                                '2026-10-08', theme.textTheme.bodySmall, 1),
                            .35),
                      ]),
                ),
              ]),
              const Divider(height: 16),
            ]),
          );
        }),
      );

  Widget _comment(BuildContext context, PixivComment comment) {
    final state = _replies[comment.id];
    final replies = state?.comments ?? const <PixivComment>[];
    final showReplies = state?.expanded == true &&
        (widget.previewLimit == null || _entryActive);
    return Padding(
      key: ValueKey('pixiv-comment-${widget.illustId}-${comment.id}'),
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
                if (showReplies && state?.error != null)
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
                if (showReplies)
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
    final expanded = state?.expanded == true &&
        (widget.previewLimit == null || _entryActive);
    return Wrap(children: [
      TextButton(
        onPressed: _entryActive ? () => _toggleReplies(comment) : null,
        child: Text(loaded && expanded ? '收起回复' : '查看回复'),
      ),
      if (loaded && state!.hasNext && (widget.previewLimit == null || expanded))
        TextButton(
            onPressed: _entryActive ? () => _loadReplies(comment, state) : null,
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
