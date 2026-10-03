import 'dart:async';
import 'dart:developer';
import 'package:flutter/foundation.dart';

/// Page-owned decoration work. It never controls the user's download queue.
class IllustWorkQueue<T> {
  IllustWorkQueue(
      {required this.resolve,
      required this.publish,
      this.concurrency = 2,
      this.isComplete});
  final bool Function(T value)? isComplete;
  final _retryAfter = <String, DateTime>{};
  final Future<T?> Function(String key, bool Function() canContinue) resolve;
  final void Function(Map<String, T> values) publish;
  final int concurrency;
  final _pending = <String>{};
  final _running = <String, int>{};
  final _ready = <String, T>{};
  final _done = <String>{};
  Set<String> _visible = {};
  Timer? _idle;
  bool _active = true, _scrolling = false, _disposed = false;
  int _generation = 0;
  int started = 0, peakActive = 0;
  int get queued => _pending.length;
  int get active => _running.length;
  bool get _canRun => !_disposed && _active && !_scrolling && _idle == null;
  void _mark(String event) {
    if (kProfileMode) {
      Timeline.instantSync('IllustWork.$event', arguments: {
        'generation': _generation,
        'queued': queued,
        'active': active,
        'started': started,
        'peakActive': peakActive,
      });
    }
  }

  void reset() {
    _generation++;
    _pending.clear();
    _ready.clear();
    _done.clear();
    _retryAfter.clear();
    _visible = {};
    _mark('reset');
  }

  void setVisible(Iterable<String> keys) {
    _visible = keys.toSet();
    _pending.removeWhere((key) => !_visible.contains(key));
    _pending.addAll(_visible.where((key) =>
        !_done.contains(key) &&
        !_running.containsKey(key) &&
        (_retryAfter[key] == null ||
            DateTime.now().isAfter(_retryAfter[key]!))));
    _drain();
  }

  void setActive(bool value) {
    if (value != _active) _mark(value ? 'foreground' : 'paused');
    _active = value;
    if (value) setVisible(_visible);
  }

  void retry(String key) {
    if (_disposed) return;
    _done.remove(key);
    _retryAfter.remove(key);
    if (_visible.contains(key)) _pending.add(key);
    _drain();
  }

  void setScrolling(bool value) {
    if (value != _scrolling) _mark(value ? 'scroll' : 'idle');
    _scrolling = value;
    _idle?.cancel();
    _idle = null;
    if (!value) {
      _idle = Timer(const Duration(milliseconds: 140), () {
        _idle = null;
        _drain();
      });
    }
  }

  void _drain() {
    if (!_canRun) return;
    if (_ready.isNotEmpty) {
      final values = Map<String, T>.of(_ready);
      _ready.clear();
      publish(values);
    }
    while (_canRun && _running.length < concurrency && _pending.isNotEmpty) {
      final key = _pending.first;
      _pending.remove(key);
      final generation = _generation;
      _running[key] = generation;
      started++;
      if (_running.length > peakActive) peakActive = _running.length;
      unawaited(_run(key, generation));
    }
  }

  Future<void> _run(String key, int generation) async {
    bool current() => !_disposed && generation == _generation;
    bool canContinue() => current() && _canRun && _visible.contains(key);
    try {
      final value = await resolve(key, canContinue);
      if (current() && value != null) {
        if (isComplete?.call(value) ?? true) {
          _done.add(key);
        } else {
          _retryAfter[key] = DateTime.now().add(const Duration(seconds: 30));
        }
        _ready[key] = value;
      }
    } catch (_) {
      // Retry on a later visibility/refresh event, never spin on permission errors.
    } finally {
      _running.remove(key);
      if (current() &&
          !_done.contains(key) &&
          _visible.contains(key) &&
          !_canRun) {
        _pending.add(key);
      } else if (!current() && !_disposed && _visible.contains(key)) {
        _pending.add(key);
      }
      _drain();
    }
  }

  void dispose() {
    _mark('dispose');
    _disposed = true;
    _generation++;
    _idle?.cancel();
    _pending.clear();
    _ready.clear();
    _visible.clear();
  }
}
