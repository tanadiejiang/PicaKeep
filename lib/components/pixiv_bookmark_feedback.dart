import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:picakeep/base.dart' show appdata;
import 'package:picakeep/foundation/app.dart' show App;
import 'package:picakeep/foundation/pixiv_bookmark_feedback_settings.dart';
import 'package:picakeep/components/components.dart' show NaviObserver;
import 'package:picakeep/components/pixiv_bookmark_queue.dart';
import 'package:picakeep/pages/explore/explore_route_scope.dart';

/// A result belongs to the page that started the operation, never a global queue.
@immutable
class PixivBookmarkFeedbackMessage {
  const PixivBookmarkFeedbackMessage.added()
      : text = '已添加公开收藏',
        icon = Icons.favorite,
        target = true,
        duration = const Duration(seconds: 2),
        isError = false;
  const PixivBookmarkFeedbackMessage.removed()
      : text = '已取消收藏',
        icon = Icons.favorite_border,
        target = false,
        duration = const Duration(seconds: 2),
        isError = false;
  const PixivBookmarkFeedbackMessage.privateAdded()
      : text = '已添加私密收藏',
        icon = Icons.lock_outline,
        target = true,
        duration = const Duration(seconds: 3),
        isError = false;
  factory PixivBookmarkFeedbackMessage.failed(String reason) =>
      PixivBookmarkFeedbackMessage._error('收藏失败：$reason');
  const PixivBookmarkFeedbackMessage._error(this.text)
      : icon = Icons.error_outline,
        target = null,
        duration = const Duration(milliseconds: 3500),
        isError = true;

  const PixivBookmarkFeedbackMessage.waiting({this.target})
      : text = target == null
            ? '正在读取收藏状态…'
            : target
                ? '正在提交收藏…'
                : '正在取消收藏…',
        icon = Icons.more_horiz,
        duration = Duration.zero,
        isError = false;

  bool get isWaiting => duration == Duration.zero;
  final String text;
  final IconData icon;
  final Duration duration;
  final bool isError;
  final bool? target;
}

class PixivBookmarkFeedbackTicket {
  PixivBookmarkFeedbackTicket._(
      this._owner, this._epoch, this._operationId, this.account, this.workId);
  final PixivBookmarkFeedbackController _owner;
  final int _epoch;
  final int _operationId;
  final String account;
  final String workId;
  bool? _target;
  bool _waiting = false;
  bool _finished = false;
  bool _cancelled = false;

  bool get isCurrent => _owner.isCurrent && _epoch == _owner._epoch;

  /// Only an accepted operation is queued. Capture alone (login/rejection) is inert.
  void startWaiting({bool? target}) {
    if (!isCurrent || _waiting || _finished || _cancelled) return;
    _target = target;
    _waiting = true;
    _owner._waiting(_operationId, workId, target);
  }

  void updateWaitingTarget(bool target) {
    _target = target;
    if (_waiting && isCurrent && !_finished && !_cancelled) {
      _owner._waiting(_operationId, workId, target);
    }
  }

  /// A caller's finally cannot erase its settled result or any other operation.
  void cancelWaiting() {
    if (_finished || _cancelled) return;
    _cancelled = true;
    _waiting = false;
    if (isCurrent) _owner._cancel(_operationId);
  }

  bool finish(PixivBookmarkFeedbackMessage message) {
    if (!isCurrent || _finished || _cancelled) return false;
    _finished = true;
    _waiting = false;
    return _owner._complete(_operationId, workId, message, _target);
  }

  bool show(PixivBookmarkFeedbackMessage message) {
    if (!isCurrent || _finished || _cancelled) return false;
    if (message.isWaiting) {
      startWaiting(target: message.target);
      return true;
    }
    return finish(message);
  }
}

class _QueuedBookmark {
  _QueuedBookmark(this.operationId, this.workId, this.message, this.target);
  final int operationId;
  final String workId;
  PixivBookmarkFeedbackMessage message;
  bool? target;
  int? settlementSequence;
  Timer? retentionTimer;
  bool ready = false;
  bool exiting = false;

  PixivBookmarkQueueEntry get view => PixivBookmarkQueueEntry(
        operationId: operationId,
        workId: workId,
        status: message.isWaiting
            ? PixivBookmarkQueueStatus.waiting
            : message.isError
                ? PixivBookmarkQueueStatus.failed
                : PixivBookmarkQueueStatus.completed,
        text: message.text,
        target: target,
        isPrivate: message.icon == Icons.lock_outline,
        exiting: exiting,
        settlementSequence: settlementSequence,
      );
}

class PixivBookmarkFeedbackController extends ChangeNotifier {
  PixivBookmarkFeedbackController._(this._current);
  final bool Function() _current;
  int _epoch = 0;
  int _operationSequence = 0;
  int _settlementSequence = 0;
  bool _disposed = false;
  bool _reducedMotion = false;
  Timer? _drainTimer;
  bool _canAdvance = true;
  final List<_QueuedBookmark> _queue = [];
  Duration Function(Duration)? _readableDuration;

  bool get isCurrent => !_disposed && _current();
  int get visualEpoch => _epoch;
  List<PixivBookmarkQueueEntry> get entries =>
      List.unmodifiable(_queue.map((item) => item.view));

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  PixivBookmarkFeedbackTicket capture(
          {required String account, required String workId}) =>
      PixivBookmarkFeedbackTicket._(
          this, _epoch, ++_operationSequence, account, workId);

  /// UI validity never participates in the network/store's account predicate.
  void invalidate({bool notify = true}) {
    _epoch++;
    _drainTimer?.cancel();
    _drainTimer = null;
    _canAdvance = true;
    for (final item in _queue) {
      item.retentionTimer?.cancel();
    }
    _queue.clear();
    if (!_disposed && notify) notifyListeners();
  }

  _QueuedBookmark? _find(int operationId) {
    for (final item in _queue) {
      if (item.operationId == operationId) return item;
    }
    return null;
  }

  void _insert(_QueuedBookmark item) {
    _queue.add(item);
  }

  void _waiting(int operationId, String workId, bool? target) {
    if (!isCurrent) return;
    final message = PixivBookmarkFeedbackMessage.waiting(target: target);
    final previous = _find(operationId);
    if (previous == null) {
      _insert(_QueuedBookmark(operationId, workId, message, target));
    } else if (previous.message.isWaiting) {
      previous.message = message;
      previous.target = target;
    } else {
      return;
    }
    _notify();
  }

  bool _complete(int operationId, String workId,
      PixivBookmarkFeedbackMessage message, bool? target) {
    if (!isCurrent) return false;
    final value = _find(operationId);
    final record =
        value ?? _QueuedBookmark(operationId, workId, message, target);
    if (value != null && !value.message.isWaiting) return false;
    if (value == null) _insert(record);
    record.message = message;
    record.settlementSequence = ++_settlementSequence;
    record.target = message.isError ? target : message.target;
    record.retentionTimer = Timer(
        _readableDuration?.call(message.duration) ?? message.duration, () {
      if (_disposed || !_queue.contains(record)) return;
      record.ready = true;
      _scheduleDrain();
    });
    _notify();
    _scheduleDrain();
    return true;
  }

  void _cancel(int operationId) {
    final item = _find(operationId);
    if (item == null || !item.message.isWaiting) return;
    _queue.remove(item);
    _notify();
    _scheduleDrain();
  }

  void _scheduleDrain({bool notify = true}) {
    // Waiting entries have no expiry. Settlement retention and FIFO exit are
    // independent timers, so a slow head cannot erase completed later entries.
    if (_disposed ||
        !_canAdvance ||
        _queue.isEmpty ||
        _queue.first.exiting ||
        !_queue.first.ready) {
      return;
    }
    _beginExit(notify: notify);
  }

  void _beginExit({bool notify = true}) {
    if (_disposed || _queue.isEmpty || _queue.first.message.isWaiting) return;
    final head = _queue.first;
    if (_reducedMotion) {
      _removeHead(head, notify: notify);
      return;
    }
    head.exiting = true;
    if (notify) _notify();
    _drainTimer =
        Timer(const Duration(milliseconds: 240), () => _removeHead(head));
  }

  void _removeHead(_QueuedBookmark head, {bool notify = true}) {
    if (_disposed || _queue.isEmpty || !identical(_queue.first, head)) return;
    _queue.removeAt(0);
    head.retentionTimer?.cancel();
    _canAdvance = false;
    if (notify) _notify();
    _drainTimer = Timer(const Duration(milliseconds: 180), () {
      if (_disposed) return;
      _canAdvance = true;
      _scheduleDrain();
    });
  }

  void _setReducedMotion(bool reduced) {
    if (_reducedMotion == reduced) return;
    _reducedMotion = reduced;
    if (reduced && _queue.isNotEmpty && _queue.first.exiting) {
      _drainTimer?.cancel();
      _removeHead(_queue.first, notify: false);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _drainTimer?.cancel();
    for (final item in _queue) {
      item.retentionTimer?.cancel();
    }
    _queue.clear();
    super.dispose();
  }
}

class _FeedbackScope
    extends InheritedNotifier<PixivBookmarkFeedbackController> {
  const _FeedbackScope(
      {required PixivBookmarkFeedbackController controller,
      required this.epoch,
      required super.child})
      : super(notifier: controller);
  final int epoch;
  @override
  bool updateShouldNotify(covariant _FeedbackScope oldWidget) =>
      epoch != oldWidget.epoch || super.updateShouldNotify(oldWidget);
}

class PixivBookmarkFeedbackHost extends StatefulWidget {
  const PixivBookmarkFeedbackHost({
    super.key,
    required this.child,
    this.active = true,
    this.identity,
    this.bottomOffset = 16,
    this.avoidViewInsets = false,
  });
  final Widget child;
  final bool active;
  final Object? identity;
  final double bottomOffset;

  /// Embedded hosts already receive the navigation/scaffold's usable bounds.
  final bool avoidViewInsets;

  static PixivBookmarkFeedbackController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FeedbackScope>()?.notifier;

  @override
  State<PixivBookmarkFeedbackHost> createState() =>
      _PixivBookmarkFeedbackHostState();
}

class _PixivBookmarkFeedbackHostState extends State<PixivBookmarkFeedbackHost> {
  late final _controller = PixivBookmarkFeedbackController._(_isCurrentPage);
  NaviObserver? _observer;
  ModalRoute<dynamic>? _route;
  bool _wasCurrent = true;
  bool _notificationScheduled = false;

  bool _isCurrentPage() {
    if (!mounted || !widget.active) return false;
    final pages = _observer?.routes.whereType<PageRoute<dynamic>>();
    if (_route is PageRoute && pages != null && pages.isNotEmpty) {
      return identical(pages.last, _route);
    }
    return _route?.isCurrent ?? true;
  }

  @override
  void initState() {
    super.initState();
    App.displaySettingsVersion.addListener(_displaySettingsChanged);
  }

  void _displaySettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final observer = ExploreRouteScope.maybeOf(context) ??
        Navigator.maybeOf(context)
            ?.widget
            .observers
            .whereType<NaviObserver>()
            .firstOrNull;
    if (!identical(observer, _observer)) {
      _observer?.removeListener(_routeChanged);
      _observer = observer;
      _observer?.addListener(_routeChanged);
    }
    _updateCurrent(notify: false);
    final media = MediaQuery.of(context);
    _controller._setReducedMotion(media.disableAnimations);
    _controller._readableDuration = (duration) {
      final scale = media.textScaler.scale(14) / 14;
      final factor = media.accessibleNavigation
          ? math.max(3.0, scale)
          : math.max(1.0, scale);
      return Duration(milliseconds: (duration.inMilliseconds * factor).round());
    };
  }

  @override
  void didUpdateWidget(covariant PixivBookmarkFeedbackHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity ||
        oldWidget.active != widget.active) {
      _controller.invalidate(notify: false);
    }
    _wasCurrent = _isCurrentPage();
  }

  void _updateCurrent({required bool notify}) {
    final current = _isCurrentPage();
    if (_wasCurrent != current) _controller.invalidate(notify: notify);
    _wasCurrent = current;
  }

  void _routeChanged() {
    // Invalidate tickets immediately, but notify dependents after navigation's build.
    _updateCurrent(notify: false);
    if (_notificationScheduled) return;
    _notificationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notificationScheduled = false;
      if (mounted) _controller._notify();
    });
  }

  @override
  void dispose() {
    App.displaySettingsVersion.removeListener(_displaySettingsChanged);
    _observer?.removeListener(_routeChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final reduced = media.disableAnimations;
    return _FeedbackScope(
      controller: _controller,
      epoch: _controller._epoch,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final current = _controller.isCurrent;
                  final entries = current
                      ? _controller.entries
                      : const <PixivBookmarkQueueEntry>[];
                  final clearance = widget.avoidViewInsets
                      ? math.max(
                          media.viewPadding.bottom, media.viewInsets.bottom)
                      : 0.0;
                  return LayoutBuilder(builder: (context, constraints) {
                    final bottom = math.min(widget.bottomOffset + clearance,
                        math.max(0.0, constraints.maxHeight - 64));
                    return Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, bottom),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: KeyedSubtree(
                          key: ValueKey(_controller._epoch),
                          child: entries.isEmpty
                              ? const SizedBox.shrink()
                              : PixivBookmarkQueueCapsule(
                                  key: ValueKey(('queue', _controller._epoch)),
                                  entries: entries,
                                  reducedMotion: reduced,
                                  showCounts: showPixivBookmarkQueueCounts(
                                      appdata.settings),
                                ),
                        ),
                      ),
                    );
                  });
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
