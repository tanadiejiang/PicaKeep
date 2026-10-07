import 'dart:async';
import 'package:picakeep/foundation/illust_cover_diagnostics.dart';

/// Page-owned decoration work. It never controls the user's download queue.
/// Covers and optional metadata share one concurrency limit; visible covers
/// always take priority over queued metadata.
class IllustWorkQueue<T> {
  IllustWorkQueue({
    required this.resolve,
    required this.publish,
    this.resolveDetails,
    this.onCoverWorkChanged,
    this.concurrency = 2,
    this.isComplete,
    this.retryDelay = const Duration(seconds: 5),
    this.maxAutomaticRetries = 2,
    this.scrollStartSpacing = const Duration(milliseconds: 120),
  })  : assert(concurrency > 0),
        assert(!scrollStartSpacing.isNegative);

  final bool Function(T value)? isComplete;
  final Future<T?> Function(String key, bool Function() canContinue) resolve;
  final Future<T?> Function(String key, T value, bool Function() canContinue)?
      resolveDetails;
  final void Function(Map<String, T> values) publish;
  final void Function(bool busy)? onCoverWorkChanged;
  final int concurrency;
  final Duration retryDelay;
  final int maxAutomaticRetries;

  /// While scrolling (including the idle settling interval), start at most one
  /// cover at a time and space starts apart. Already running work can finish.
  final Duration scrollStartSpacing;
  final _pending = <String>{};
  final _pendingDetails = <String>{};
  final _detailValues = <String, T>{};
  final _detailsDone = <String>{};
  final _running = <String, ({int generation, int revision, bool details})>{};
  final _revisions = <String, int>{};
  final _ready = <String, T>{};
  final _readyDetails = <String, T>{};
  final _done = <String>{};
  final _failures = <String, int>{};
  final _retryTimers = <String, Timer>{};
  Set<String> _visible = {};
  Timer? _idle;
  Timer? _coverStartCooldown;
  bool _active = true, _scrolling = false, _disposed = false;
  int _generation = 0;
  int started = 0, peakActive = 0;
  bool _reportedCoverWork = false;
  int get queued => _pending.length + _pendingDetails.length;
  int get active => _running.length;
  bool get _canRun => !_disposed && _active;
  bool get _canRunDetails => _canRun && !_scrolling && _idle == null;

  void _reportCoverWork() {
    final busy = _canRun &&
        (_scrolling ||
            _idle != null ||
            _pending.isNotEmpty ||
            _running.values.any((work) => !work.details));
    if (busy == _reportedCoverWork) return;
    _reportedCoverWork = busy;
    onCoverWorkChanged?.call(busy);
  }

  void _mark(String event) {
    IllustCoverDiagnostics.event('queue.$event', arguments: {
      'generation': _generation,
      'queued': queued,
      'active': active,
      'started': started,
      'peakActive': peakActive,
    });
  }

  void reset() {
    _generation++;
    _pending.clear();
    _pendingDetails.clear();
    _detailValues.clear();
    _detailsDone.clear();
    _revisions.clear();
    _ready.clear();
    _readyDetails.clear();
    _coverStartCooldown?.cancel();
    _coverStartCooldown = null;
    _done.clear();
    _failures.clear();
    _cancelRetries();
    _visible = {};
    _reportCoverWork();
    _mark('reset');
  }

  void setVisible(Iterable<String> keys) {
    if (_disposed) return;
    _visible = keys.toSet();
    _pending.removeWhere((key) => !_visible.contains(key));
    _pendingDetails.removeWhere((key) => !_visible.contains(key));
    for (final key in _retryTimers.keys.toList()) {
      if (!_visible.contains(key)) _retryTimers.remove(key)?.cancel();
    }
    for (final key in _visible) {
      if (_running.containsKey(key)) continue;
      if (!_done.contains(key) &&
          !_retryTimers.containsKey(key) &&
          (_failures[key] ?? 0) <= maxAutomaticRetries) {
        _pending.add(key);
      } else if (_detailValues.containsKey(key) &&
          !_detailsDone.contains(key)) {
        _pendingDetails.add(key);
      }
    }
    _drain();
  }

  void setActive(bool value) {
    if (value != _active) _mark(value ? 'foreground' : 'paused');
    _active = value;
    _reportCoverWork();
    if (value) setVisible(_visible);
  }

  void retry(String key) {
    if (_disposed) return;
    // An image error may arrive while its metadata is still running. Invalidate
    // that task so it cannot overwrite the replacement cover when it returns.
    _revisions[key] = (_revisions[key] ?? 0) + 1;
    _done.remove(key);
    _ready.remove(key);
    _readyDetails.remove(key);
    _detailsDone.remove(key);
    _detailValues.remove(key);
    _pendingDetails.remove(key);
    _failures.remove(key);
    _retryTimers.remove(key)?.cancel();
    if (_visible.contains(key)) _pending.add(key);
    _drain();
  }

  void setScrolling(bool value) {
    if (_disposed || value == _scrolling) return;
    _mark(value ? 'scroll' : 'idle');
    _scrolling = value;
    _idle?.cancel();
    _idle = null;
    if (!value) {
      _idle = Timer(const Duration(milliseconds: 140), () {
        _idle = null;
        setVisible(_visible);
      });
    }
    _drain();
  }

  void _drain() {
    _reportCoverWork();
    if (!_canRun) return;
    final values = <String, T>{};
    for (final key in _visible) {
      if (_ready.containsKey(key)) values[key] = _ready.remove(key) as T;
      // Metadata can change the waterfall geometry. Keep its publication idle,
      // even when its IO began before scrolling and has already completed.
      if (_canRunDetails && _readyDetails.containsKey(key)) {
        values[key] = _readyDetails.remove(key) as T;
      }
    }
    if (values.isNotEmpty) publish(values);
    while (_canRun && _running.length < concurrency) {
      final covers = _pending.where((key) => !_running.containsKey(key));
      final details =
          _pendingDetails.where((key) => !_running.containsKey(key));
      final isDetails = covers.isEmpty;
      if (isDetails && details.isEmpty) break;
      if (isDetails && !_canRunDetails) break;
      if (!isDetails &&
          !_canRunDetails &&
          (_coverStartCooldown != null ||
              _running.values.any((work) => !work.details))) {
        break;
      }
      // Keep one lane available for newly visible covers if an archive count
      // stalls. Details still count toward the overall concurrency limit.
      if (isDetails && _running.values.any((work) => work.details)) break;
      final key = isDetails ? details.first : covers.first;
      (isDetails ? _pendingDetails : _pending).remove(key);
      final token = (
        generation: _generation,
        revision: _revisions[key] ?? 0,
        details: isDetails,
      );
      _running[key] = token;
      if (!isDetails) {
        _coverStartCooldown?.cancel();
        _coverStartCooldown = Timer(scrollStartSpacing, () {
          _coverStartCooldown = null;
          _drain();
        });
      }
      started++;
      if (_running.length > peakActive) peakActive = _running.length;
      unawaited(_run(key, token, isDetails));
    }
    _reportCoverWork();
  }

  void _scheduleRetry(String key) {
    final failures = (_failures[key] ?? 0) + 1;
    _failures[key] = failures;
    if (failures > maxAutomaticRetries || !_visible.contains(key)) return;
    _retryTimers.remove(key)?.cancel();
    _retryTimers[key] = Timer(retryDelay, () {
      _retryTimers.remove(key);
      if (_disposed || !_visible.contains(key)) return;
      _pending.add(key);
      _drain();
    });
  }

  Future<void> _run(
      String key,
      ({int generation, int revision, bool details}) token,
      bool isDetails) async {
    bool current() =>
        !_disposed &&
        token.generation == _generation &&
        token.revision == (_revisions[key] ?? 0);
    bool canContinue() => current() && _canRun && _visible.contains(key);
    var interrupted = false;
    try {
      final value = isDetails
          ? await resolveDetails!(key, _detailValues[key] as T, canContinue)
          : await resolve(key, canContinue);
      if (!current()) return;
      if (value != null) {
        (isDetails ? _readyDetails : _ready)[key] = value;
        if (isDetails) {
          _detailsDone.add(key);
          _detailValues.remove(key);
        } else if (isComplete?.call(value) ?? true) {
          _done.add(key);
          _failures.remove(key);
          if (resolveDetails != null) {
            _detailValues[key] = value;
            if (_visible.contains(key)) _pendingDetails.add(key);
          }
        } else {
          _scheduleRetry(key);
        }
      } else if (!canContinue()) {
        interrupted = true;
      } else if (isDetails) {
        _detailsDone.add(key);
        _detailValues.remove(key);
      } else {
        _scheduleRetry(key);
      }
    } catch (_) {
      if (current()) {
        if (!canContinue()) {
          interrupted = true;
        } else if (isDetails) {
          // Metadata must not hide or invalidate a successfully prepared cover.
          _detailsDone.add(key);
          _detailValues.remove(key);
        } else {
          _scheduleRetry(key);
        }
      }
    } finally {
      _running.remove(key);
      if (current() && interrupted && _visible.contains(key)) {
        (isDetails ? _pendingDetails : _pending).add(key);
      } else if (!current() && !_disposed && _visible.contains(key)) {
        _pending.add(key);
      }
      _drain();
    }
  }

  void _cancelRetries() {
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
  }

  void dispose() {
    _mark('dispose');
    _disposed = true;
    _generation++;
    _idle?.cancel();
    _coverStartCooldown?.cancel();
    _cancelRetries();
    _pending.clear();
    _pendingDetails.clear();
    _detailValues.clear();
    _ready.clear();
    _readyDetails.clear();
    _visible.clear();
    _reportCoverWork();
  }
}
