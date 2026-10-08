import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum PixivBookmarkPhase { accepted, begin, settle }

/// An event from this target's own operation, separate from shared authority.
@immutable
class PixivBookmarkEvent {
  const PixivBookmarkEvent({
    required this.sequence,
    required this.operationId,
    required this.phase,
    this.target,
    this.success = true,
    this.begin,
  }) : assert(phase != PixivBookmarkPhase.begin || target != null);

  final int sequence;
  final int operationId;
  final PixivBookmarkPhase phase;
  final bool? target;
  final bool success;

  /// Preserve an unconsumed begin when an immediate Future coalesces both
  /// notifications into one widget frame. It must belong to this operation.
  final PixivBookmarkEvent? begin;
}

/// A fixed-size Pixiv bookmark target. The caller owns all network state and
/// emits [event] only for this target's own operation. Passive state updates and
/// the event present on first binding never animate. No haptics are emitted.
class PixivBookmarkButton extends StatefulWidget {
  const PixivBookmarkButton({
    super.key,
    required this.isBookmarked,
    this.stateKnown = true,
    this.busy = false,
    this.enabled = true,
    this.active = true,
    this.identity,
    this.visualEpoch,
    this.event,
    this.onPressed,
    this.onLongPress,
    this.size = 48,
    this.iconSize = 22,
    this.activeColor,
    this.inactiveColor,
    this.shadows,
    this.circularBackground = false,
  })  : assert(size > 0),
        assert(iconSize > 0);

  final bool isBookmarked;
  final bool stateKnown;
  final bool busy;
  final bool enabled;
  final bool active;

  /// Include account and artwork identity so a reused target clears old work.
  final Object? identity;

  /// The feedback Host's visual generation, independent of business state.
  final Object? visualEpoch;
  final PixivBookmarkEvent? event;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final double size;
  final double iconSize;
  final Color? activeColor;
  final Color? inactiveColor;
  final List<Shadow>? shadows;
  final bool circularBackground;

  @override
  State<PixivBookmarkButton> createState() => _PixivBookmarkButtonState();
}

class _PixivBookmarkButtonState extends State<PixivBookmarkButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(vsync: this)
    ..addStatusListener(_motionStatus);
  final FocusNode _focus = FocusNode();
  int? _lastSequence;
  int? _operationId;
  bool _began = false;
  bool _settled = false;
  bool? _pendingVisualTarget;
  bool? _playingTarget;
  bool? _failureFrom;
  bool _pressed = false;
  bool _reduceMotion = false;
  bool _tickerEnabled = true;
  bool _focusVisible = false;

  bool get _visualActive => widget.active && widget.enabled && _tickerEnabled;
  bool get _operable => _visualActive && !widget.busy;
  bool get _authority => widget.stateKnown && widget.isBookmarked;

  @override
  void initState() {
    super.initState();
    _lastSequence = widget.event?.sequence;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.disableAnimationsOf(context);
    final ticker = TickerMode.valuesOf(context).enabled;
    if (ticker != _tickerEnabled) {
      _tickerEnabled = ticker;
      _resetVisuals();
      _rememberCurrentEvent();
    }
    if (reduce != _reduceMotion) {
      _reduceMotion = reduce;
      // A preference change cancels motion, not the accepted local target.
      _stopMotion();
      _pressed = false;
    }
  }

  @override
  void didUpdateWidget(PixivBookmarkButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity ||
        oldWidget.visualEpoch != widget.visualEpoch ||
        oldWidget.active != widget.active ||
        oldWidget.enabled != widget.enabled) {
      _resetVisuals();
      if (oldWidget.identity != widget.identity) {
        _lastSequence = widget.event?.sequence;
      } else {
        _rememberCurrentEvent();
      }
      return;
    }
    if (widget.busy) _pressed = false;
    final event = widget.event;
    if (event == null ||
        (_lastSequence != null && event.sequence <= _lastSequence!)) {
      return;
    }
    final previousSequence = _lastSequence;
    _lastSequence = event.sequence;
    if (!_visualActive) return;
    final begin = event.begin;
    if (event.phase == PixivBookmarkPhase.settle &&
        begin != null &&
        begin.phase == PixivBookmarkPhase.begin &&
        begin.operationId == event.operationId &&
        begin.sequence < event.sequence &&
        (previousSequence == null || begin.sequence > previousSequence)) {
      _consume(begin);
    }
    _consume(event);
  }

  void _rememberCurrentEvent() {
    final sequence = widget.event?.sequence;
    if (sequence != null &&
        (_lastSequence == null || sequence > _lastSequence!)) {
      _lastSequence = sequence;
    }
  }

  void _consume(PixivBookmarkEvent event) {
    switch (event.phase) {
      case PixivBookmarkPhase.accepted:
        if (_operationId == event.operationId) return;
        _startOperation(event.operationId);
      case PixivBookmarkPhase.begin:
        // accepted and begin can be coalesced into the same Flutter frame.
        if (_operationId != event.operationId) {
          _startOperation(event.operationId);
        }
        if (_began || _settled || event.target == null) return;
        _began = true;
        _pendingVisualTarget = event.target;
        _pressed = false;
        if (!_reduceMotion) {
          _playingTarget = event.target;
          _motion.duration = Duration(milliseconds: event.target! ? 300 : 500);
          _motion.forward(from: 0);
        }
      case PixivBookmarkPhase.settle:
        // A late settlement cannot remove a newer operation's local target.
        if (_operationId != null && _operationId != event.operationId) return;
        if (_settled) return;
        _operationId = event.operationId;
        _settled = true;
        final previous = _displayedBookmark;
        _pendingVisualTarget = null;
        if (!event.success) {
          _stopMotion();
          if (!_reduceMotion && previous != _authority) {
            _failureFrom = previous;
            _motion.duration = const Duration(milliseconds: 140);
            _motion.forward(from: 0);
          }
        }
      // Success only releases the override. An existing first motion finishes
      // normally; a read failure/success without begin never invents motion.
    }
  }

  void _startOperation(int operationId) {
    _stopMotion();
    _operationId = operationId;
    _began = false;
    _settled = false;
    _pendingVisualTarget = null;
  }

  bool get _displayedBookmark {
    if (_playingTarget != null && _motion.value < 1) {
      return _playingTarget! && _elapsed >= 100;
    }
    return _pendingVisualTarget ?? _authority;
  }

  double get _elapsed {
    final raw = _motion.value * _motion.duration!.inMilliseconds;
    // Snap millisecond boundaries before choosing the 100ms icon swap.
    return (raw - raw.round()).abs() < .000001 ? raw.roundToDouble() : raw;
  }

  void _motionStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() {
        _playingTarget = null;
        _failureFrom = null;
      });
    }
  }

  void _stopMotion() {
    _motion.stop();
    _playingTarget = null;
    _failureFrom = null;
  }

  void _resetVisuals() {
    _stopMotion();
    _pressed = false;
    _operationId = null;
    _began = false;
    _settled = false;
    _pendingVisualTarget = null;
  }

  void _activate() {
    if (_operable) widget.onPressed?.call();
  }

  void _longPress() {
    _release();
    if (_operable) widget.onLongPress?.call();
  }

  void _release() {
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  void dispose() {
    _motion.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pendingVisualTarget;
    final label = pending != null
        ? pending
            ? '正在添加收藏，尚未确认'
            : '正在取消收藏，尚未确认'
        : widget.busy
            ? widget.stateKnown
                ? '正在更新收藏'
                : '正在读取收藏状态'
            : !widget.stateKnown
                ? '切换平台收藏'
                : widget.isBookmarked
                    ? '取消平台收藏'
                    : '加入平台收藏';
    return Semantics(
      container: true,
      button: true,
      enabled:
          _operable && (widget.onPressed != null || widget.onLongPress != null),
      toggled: widget.stateKnown ? widget.isBookmarked : null,
      label: label,
      onTap: _operable && widget.onPressed != null ? _activate : null,
      onLongPress: _operable && widget.onLongPress != null ? _longPress : null,
      child: ExcludeSemantics(
        child: FocusableActionDetector(
          focusNode: _focus,
          enabled: _operable &&
              (widget.onPressed != null || widget.onLongPress != null),
          mouseCursor: _operable && widget.onPressed != null
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                _activate();
                return null;
              },
            ),
          },
          onShowFocusHighlight: (visible) {
            if (_focusVisible != visible) {
              setState(() => _focusVisible = visible);
            }
          },
          child: Listener(
            onPointerDown: (event) {
              if (_operable && event.buttons == kPrimaryButton) {
                setState(() => _pressed = true);
              }
            },
            onPointerUp: (_) => _release(),
            onPointerCancel: (_) => _release(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Retain recognizers while disabled/busy to consume the containing
              // artwork's navigation gesture, within this fixed target only.
              onTap: _activate,
              onLongPress: _longPress,
              onTapCancel: _release,
              child: SizedBox.square(
                dimension: widget.size,
                child: RepaintBoundary(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.circularBackground ? Colors.white : null,
                      border: _focusVisible && _operable
                          ? Border.all(
                              color: Theme.of(context).colorScheme.primary,
                              width: 2,
                            )
                          : null,
                    ),
                    child: AnimatedBuilder(
                      animation: _motion,
                      builder: (context, _) => _buildArtwork(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Android AccelerateDecelerateInterpolator and OvershootInterpolator(2).
  static double _accelerateDecelerate(double input) =>
      (1 - math.cos(math.pi * input.clamp(0.0, 1.0))) / 2;

  static double _overshoot(double input) {
    final u = input.clamp(0.0, 1.0) - 1;
    return u * u * (3 * u + 2) + 1;
  }

  Widget _decoration(Widget child) =>
      IgnorePointer(child: ExcludeSemantics(child: child));

  Widget _buildArtwork(BuildContext context) {
    final activeColor = widget.activeColor ?? const Color(0xFFE84C79);
    final inactiveColor =
        widget.inactiveColor ?? Theme.of(context).colorScheme.onSurfaceVariant;
    var bookmarked = _pendingVisualTarget ?? _authority;
    var scale = 1.0;
    double? ringProgress;
    double? fallProgress;
    var fallOpacity = 0.0;
    if (_playingTarget != null && _motion.value < 1) {
      final elapsed = _elapsed;
      if (_playingTarget!) {
        if (elapsed < 100) {
          bookmarked = false; // previous = !target, resolved at writer entry.
          scale = 1 - .9 * _accelerateDecelerate(elapsed / 100);
        } else {
          bookmarked = true;
          final u = ((elapsed - 100) / 200).clamp(0.0, 1.0);
          scale = .1 + .9 * _overshoot(u); // Deliberately allow output > 1.
          ringProgress = 1 - (1 - u) * (1 - u);
        }
      } else {
        bookmarked = false;
        fallProgress = _accelerateDecelerate(elapsed / 500);
        scale = .1 + .9 * fallProgress;
        fallOpacity = 1 - _accelerateDecelerate(elapsed / 300);
      }
    }
    Widget heart(bool value, {Key? key}) => Icon(
          value ? Icons.favorite : Icons.favorite_border,
          key: key,
          size: widget.iconSize,
          color: value ? activeColor : inactiveColor,
          shadows: widget.shadows,
        );
    final restoring = _failureFrom != null && _motion.value < 1;
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        if (_pressed)
          Positioned.fill(
            child: _decoration(DecoratedBox(
              key: const ValueKey('pixiv-bookmark-press-layer'),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: .08),
              ),
            )),
          ),
        if (ringProgress != null)
          _decoration(Opacity(
            key: const ValueKey('pixiv-bookmark-ring-alpha'),
            opacity: 1 - ringProgress,
            child: Transform.scale(
              key: const ValueKey('pixiv-bookmark-ring-scale'),
              scale: 1 + .2 * ringProgress,
              child: SizedBox.square(
                dimension: 30,
                child: CustomPaint(
                  key: const ValueKey('pixiv-bookmark-ring'),
                  painter: _BookmarkRingPainter(color: activeColor),
                ),
              ),
            ),
          )),
        Transform.scale(
          key: const ValueKey('pixiv-bookmark-main-scale'),
          scale: scale,
          child: restoring
              ? Opacity(
                  key: const ValueKey('pixiv-bookmark-restore-alpha'),
                  opacity: _motion.value,
                  child: heart(_authority,
                      key: const ValueKey('pixiv-bookmark-main-icon')),
                )
              : heart(bookmarked,
                  key: const ValueKey('pixiv-bookmark-main-icon')),
        ),
        if (restoring)
          _decoration(Opacity(
            opacity: 1 - _motion.value,
            child: heart(_failureFrom!),
          )),
        if (fallProgress != null)
          _decoration(Opacity(
            key: const ValueKey('pixiv-bookmark-fall-alpha'),
            opacity: fallOpacity,
            child: Transform.translate(
              key: const ValueKey('pixiv-bookmark-fall-translation'),
              offset: Offset(0, widget.iconSize * fallProgress),
              child: Transform.rotate(
                key: const ValueKey('pixiv-bookmark-fall-rotation'),
                angle: 36 * math.pi / 180 * fallProgress,
                child: heart(true,
                    key: const ValueKey('pixiv-bookmark-fall-icon')),
              ),
            ),
          )),
      ],
    );
  }
}

class _BookmarkRingPainter extends CustomPainter {
  const _BookmarkRingPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawOval((Offset.zero & size).deflate(1), paint);
  }

  @override
  bool shouldRepaint(_BookmarkRingPainter oldDelegate) =>
      color != oldDelegate.color;
}
