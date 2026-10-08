import 'dart:math' as math;

import 'package:flutter/material.dart';

enum PixivBookmarkQueueStatus { waiting, completed, failed }

/// An operation snapshot. The host owns ordering, retention and removal.
@immutable
class PixivBookmarkQueueEntry {
  const PixivBookmarkQueueEntry({
    required this.operationId,
    required this.workId,
    required this.status,
    required this.text,
    this.target,
    this.isPrivate = false,
    this.exiting = false,
    this.settlementSequence,
  });

  final int operationId;
  final String workId;
  final PixivBookmarkQueueStatus status;
  final String text;
  final bool? target;
  final bool isPrivate;
  final bool exiting;
  final int? settlementSequence;
}

/// A FIFO view: earlier operations stay on the left, new operations enter right.
///
/// This widget never removes or completes entries. Only an exiting head can
/// collapse, and stable operation keys preserve other entries' animation state.
class PixivBookmarkQueueCapsule extends StatelessWidget {
  const PixivBookmarkQueueCapsule({
    required this.entries,
    required this.reducedMotion,
    this.showCounts = false,
    super.key,
  });

  final List<PixivBookmarkQueueEntry> entries;
  final bool reducedMotion;
  final bool showCounts;

  String get _counts {
    final waiting = entries
        .where((entry) => entry.status == PixivBookmarkQueueStatus.waiting)
        .length;
    final completed = entries
        .where((entry) => entry.status == PixivBookmarkQueueStatus.completed)
        .length;
    final failed = entries
        .where((entry) => entry.status == PixivBookmarkQueueStatus.failed)
        .length;
    return '$waiting 项等待 · $completed 项完成'
        '${failed == 0 ? '' : ' · $failed 项失败'}';
  }

  PixivBookmarkQueueEntry? _latestSettled({PixivBookmarkQueueStatus? status}) {
    PixivBookmarkQueueEntry? latest;
    for (final entry in entries) {
      if (entry.status == PixivBookmarkQueueStatus.waiting ||
          (status != null && entry.status != status)) {
        continue;
      }
      if (latest == null ||
          (entry.settlementSequence ?? entry.operationId) >=
              (latest.settlementSequence ?? latest.operationId)) {
        latest = entry;
      }
    }
    return latest;
  }

  PixivBookmarkQueueEntry get _latestResult => _latestSettled() ?? entries.last;

  PixivBookmarkQueueEntry? get _latestError =>
      _latestSettled(status: PixivBookmarkQueueStatus.failed);

  PixivBookmarkQueueEntry get _captionDetail => _latestError ?? _latestResult;

  String get _semanticLabel {
    if (entries.length == 1) return entries.first.text;
    final latest = _latestResult;
    final lastError = _latestError;
    return '$_counts。${latest.text}'
        '${lastError == null || lastError.operationId == latest.operationId ? '' : '。最近错误：${lastError.text}'}';
  }

  int _capacity(double width, TextStyle style, TextScaler scaler) {
    for (var count = math.min(5, entries.length); count >= 1; count--) {
      final hidden = entries.length - count;
      var markerWidth = 0.0;
      if (hidden > 0) {
        final painter = TextPainter(
          text: TextSpan(text: '＋$hidden', style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout();
        markerWidth = painter.width + 8;
        painter.dispose();
      }
      if (count * 38 + markerWidth <= width) return count;
    }
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final textStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: scheme.onSurface,
      height: 1.4,
    );
    final single = entries.length == 1;
    final scaler = MediaQuery.textScalerOf(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: LayoutBuilder(builder: (context, constraints) {
        final capacity = single
            ? 1
            : _capacity(
                math.max(0, constraints.maxWidth - 26), textStyle, scaler);
        final hidden = entries.length - capacity;
        return Align(
          widthFactor: 1,
          heightFactor: 1,
          child: Semantics(
            key: const ValueKey('pixiv-bookmark-feedback'),
            container: true,
            liveRegion: true,
            label: _semanticLabel,
            child: ExcludeSemantics(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420, minHeight: 48),
                padding: const EdgeInsets.fromLTRB(10, 9, 16, 9),
                decoration: BoxDecoration(
                  color: dark
                      ? scheme.surfaceContainerHigh
                      : scheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(
                    !single ||
                            scaler.scale(14) > 18 ||
                            entries.first.text.length > 22
                        ? 20
                        : 24,
                  ),
                  border: Border.all(color: scheme.outlineVariant),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: dark ? .18 : .10),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      key: const ValueKey('pixiv-bookmark-queue-strip'),
                      mainAxisSize: MainAxisSize.min,
                      textDirection: TextDirection.ltr,
                      children: [
                        for (var i = 0; i < capacity; i++)
                          Flexible(
                            key: ValueKey(
                                'pixiv-bookmark-queue-slot-${entries[i].operationId}'),
                            flex: single ? 1 : 0,
                            child: _QueueItem(
                              key: ValueKey(
                                  'pixiv-bookmark-queue-item-${entries[i].operationId}'),
                              entry: entries[i],
                              reducedMotion: reducedMotion,
                              isHead: i == 0,
                              single: single,
                              textStyle: textStyle,
                            ),
                          ),
                        if (hidden > 0)
                          Flexible(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  '＋$hidden',
                                  key: const ValueKey(
                                      'pixiv-bookmark-queue-folded'),
                                  style: textStyle,
                                  maxLines: 1,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (!single) ...[
                      const SizedBox(height: 6),
                      Text(
                        showCounts
                            ? '$_counts · ${_captionDetail.text}'
                            : _captionDetail.text,
                        key: const ValueKey('pixiv-bookmark-queue-caption'),
                        style: textStyle,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _QueueItem extends StatefulWidget {
  const _QueueItem({
    required this.entry,
    required this.reducedMotion,
    required this.isHead,
    required this.single,
    required this.textStyle,
    super.key,
  });

  final PixivBookmarkQueueEntry entry;
  final bool reducedMotion;
  final bool isHead;
  final bool single;
  final TextStyle textStyle;

  @override
  State<_QueueItem> createState() => _QueueItemState();
}

class _QueueItemState extends State<_QueueItem> with TickerProviderStateMixin {
  late final _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  late final _completion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );
  late final _exit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  late final _entranceCurve = CurvedAnimation(
    parent: _entrance,
    curve: Curves.easeOutCubic,
  );
  late final _exitCurve = CurvedAnimation(
    parent: _exit,
    curve: Curves.easeInCubic,
  );
  late final _exitSize = ReverseAnimation(_exitCurve);

  bool get _shouldExit => widget.isHead && widget.entry.exiting;

  @override
  void initState() {
    super.initState();
    _completion.value = 1;
    if (widget.reducedMotion) {
      _entrance.value = 1;
    } else {
      _entrance.forward();
    }
    _syncExit();
  }

  void _syncExit() {
    if (widget.reducedMotion) {
      _exit.value = _shouldExit ? 1 : 0;
    } else if (_shouldExit) {
      if (_exit.status != AnimationStatus.completed &&
          _exit.status != AnimationStatus.forward) {
        _exit.forward();
      }
    } else if (_exit.value != 0) {
      _exit.value = 0;
    }
  }

  @override
  void didUpdateWidget(covariant _QueueItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reducedMotion) {
      _entrance.value = 1;
      _completion.value = 1;
    } else if (oldWidget.entry.status != widget.entry.status &&
        widget.entry.status == PixivBookmarkQueueStatus.completed) {
      _completion.forward(from: 0);
    }
    _syncExit();
  }

  @override
  void dispose() {
    _entranceCurve.dispose();
    _exitCurve.dispose();
    _entrance.dispose();
    _completion.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final rose = dark ? const Color(0xFFFFA2BA) : const Color(0xFFB92E58);
    final waiting = entry.status == PixivBookmarkQueueStatus.waiting;
    final failed = entry.status == PixivBookmarkQueueStatus.failed;
    final completed = entry.status == PixivBookmarkQueueStatus.completed;
    final accent = failed
        ? scheme.error
        : waiting
            ? scheme.onSurfaceVariant
            : rose;
    final id = entry.operationId;
    return AnimatedBuilder(
      animation: Listenable.merge([_entrance, _completion, _exit]),
      builder: (context, _) {
        final fill =
            completed && entry.target == true ? _completion.value : 0.0;
        final scale = completed && !widget.reducedMotion
            ? 1 + .1 * (1 - (2 * _completion.value - 1).abs())
            : 1.0;
        return SizeTransition(
          key: ValueKey('pixiv-bookmark-queue-exit-size-$id'),
          axis: Axis.horizontal,
          axisAlignment: -1,
          sizeFactor: _exitSize,
          child: FadeTransition(
            key: ValueKey('pixiv-bookmark-queue-exit-opacity-$id'),
            opacity: _exitSize,
            child: Transform.translate(
              key: ValueKey('pixiv-bookmark-queue-exit-translation-$id'),
              offset: Offset(-24 * _exitCurve.value, 0),
              child: FadeTransition(
                key: ValueKey('pixiv-bookmark-queue-entrance-opacity-$id'),
                opacity: _entranceCurve,
                child: Transform.translate(
                  key:
                      ValueKey('pixiv-bookmark-queue-entrance-translation-$id'),
                  offset: Offset(12 * (1 - _entranceCurve.value), 0),
                  child: Padding(
                    padding: EdgeInsets.only(right: widget.single ? 0 : 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Transform.scale(
                          key: ValueKey(
                              'pixiv-bookmark-queue-completion-scale-$id'),
                          scale: scale,
                          child: Container(
                            key: ValueKey(
                                'pixiv-bookmark-queue-status-$id-${entry.status.name}'),
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: accent.withValues(alpha: .12),
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Opacity(
                                  opacity: 1 - fill,
                                  child: Icon(Icons.favorite_border,
                                      size: 18, color: accent),
                                ),
                                if (completed && entry.target == true)
                                  Opacity(
                                    key: ValueKey(
                                        'pixiv-bookmark-queue-heart-fill-$id'),
                                    opacity: fill,
                                    child: Icon(Icons.favorite,
                                        size: 18, color: rose),
                                  ),
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: dark
                                          ? scheme.surfaceContainerHigh
                                          : scheme.surfaceContainerLowest,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      waiting
                                          ? Icons.more_horiz
                                          : failed
                                              ? Icons.error_outline
                                              : Icons.check_circle,
                                      key: ValueKey(
                                          'pixiv-bookmark-queue-badge-$id-${entry.status.name}'),
                                      size: 12,
                                      color: accent,
                                    ),
                                  ),
                                ),
                                if (entry.isPrivate)
                                  Positioned(
                                    right: 0,
                                    top: 0,
                                    child: Icon(
                                      Icons.lock,
                                      key: ValueKey(
                                          'pixiv-bookmark-queue-private-$id'),
                                      size: 10,
                                      color: scheme.onSurface,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (widget.single) ...[
                          const SizedBox(width: 10),
                          Flexible(
                              child: Text(entry.text, style: widget.textStyle)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
