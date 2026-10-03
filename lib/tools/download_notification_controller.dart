import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum DownloadNoticeState {
  empty,
  queued,
  running,
  waiting,
  paused,
  failed,
  finished
}

/// A projection of the execution queue, independent of widgets and source models.
class DownloadNoticeTask {
  const DownloadNoticeTask({
    required this.id,
    required this.title,
    this.progress = 0,
    this.bytesPerSecond = 0,
    this.completed = false,
    this.cancelled = false,
    this.paused = false,
    this.error,
  });

  final String id;
  final String title;
  final double progress;
  final int bytesPerSecond;
  final bool completed;
  final bool cancelled;
  final bool paused;
  final String? error;
  bool get runnable => !completed && !cancelled && !paused && error == null;
}

class DownloadNoticeSnapshot {
  const DownloadNoticeSnapshot({
    required this.state,
    required this.total,
    required this.completed,
    this.currentId,
    this.currentTitle = '',
    this.percent = 0,
    this.bytesPerSecond = 0,
  });

  factory DownloadNoticeSnapshot.fromTasks(
    Iterable<DownloadNoticeTask> source, {
    String? activeId,
    bool networkAvailable = true,
  }) {
    final tasks = source.toList(growable: false);
    final completed = tasks.where((t) => t.completed).length;
    DownloadNoticeTask? active;
    for (final task in tasks) {
      if (task.id == activeId && task.runnable) active = task;
    }
    final runnable = tasks.any((t) => t.runnable);
    final state = tasks.isEmpty
        ? DownloadNoticeState.empty
        : completed == tasks.length
            ? DownloadNoticeState.finished
            : runnable && !networkAvailable
                ? DownloadNoticeState.waiting
                : active != null
                    ? DownloadNoticeState.running
                    : runnable
                        ? DownloadNoticeState.queued
                        : tasks.any((t) => t.error != null)
                            ? DownloadNoticeState.failed
                            : DownloadNoticeState.paused;
    return DownloadNoticeSnapshot(
      state: state,
      total: tasks.length,
      completed: completed,
      currentId: active?.id,
      currentTitle: active?.title ?? '',
      percent: active == null || !active.progress.isFinite
          ? 0
          : (active.progress.clamp(0, 1) * 100).floor(),
      bytesPerSecond: active?.bytesPerSecond ?? 0,
    );
  }

  final DownloadNoticeState state;
  final int total;
  final int completed;
  final String? currentId;
  final String currentTitle;
  final int percent;
  final int bytesPerSecond;
  bool get needsService =>
      state == DownloadNoticeState.running ||
      state == DownloadNoticeState.waiting;

  /// Count/state/task switches bypass the progress throttle.
  String get transitionKey => '${state.name}|$total|$completed|$currentId';
  Map<String, Object?> toMap() => {
        'state': state.name,
        'total': total,
        'completed': completed,
        'currentId': currentId,
        'title': currentTitle,
        'percent': percent,
        'speed': bytesPerSecond,
      };
}

typedef DownloadNoticeTransport = Future<Object?> Function(
    String method, Map<String, Object?>? arguments);

/// Serializes IPC, coalesces progress, and never lets a stale timer revive a
/// finished/dismissed notification. Source queues remain owned by the manager.
class DownloadNotificationController {
  DownloadNotificationController({
    DownloadNoticeTransport? transport,
    bool? enabled,
    this.progressInterval = const Duration(seconds: 1),
  })  : _enabled = enabled ?? Platform.isAndroid,
        _transport = transport ?? _invoke;

  static final instance = DownloadNotificationController();
  static const channel =
      MethodChannel('lingxue.picakeep/download_notification');
  static Future<Object?> _invoke(
          String method, Map<String, Object?>? arguments) =>
      channel.invokeMethod<Object?>(method, arguments);

  final DownloadNoticeTransport _transport;
  final bool _enabled;
  final Duration progressInterval;
  final ValueNotifier<String?> warning = ValueNotifier(null);
  void Function(bool online)? onNetworkChanged;
  VoidCallback? onBackgroundProtectionLost;
  final ValueNotifier<int> routeVersion = ValueNotifier(0);
  String? _pendingRoute;
  bool get hasPendingRoute => _pendingRoute != null;
  bool _initialized = false;
  Timer? _timer;
  Timer? _heartbeat;
  DownloadNoticeSnapshot? _pending;
  DownloadNoticeSnapshot? _lastRequested;
  Future<void> _tail = Future<void>.value();
  bool _dismissed = false;
  bool _hasPublished = false;

  Future<void> initialize() async {
    if (!_enabled || _initialized) return;
    _initialized = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'networkChanged') {
        onNetworkChanged?.call(call.arguments == true);
      } else if (call.method == 'serviceStopped') {
        warning.value = call.arguments?.toString() ?? '后台下载保护已停止';
        onBackgroundProtectionLost?.call();
      } else if (call.method == 'dismissed') {
        markDismissed();
      } else if (call.method == 'intentAvailable') {
        // The hint is optional; the payload is retained natively until pulled.
        await pullRoute();
      }
    });
    try {
      final status = await _transport('status', null);
      if (status is Map) {
        _hasPublished = _hasPublished || status['serviceRunning'] == true;
        if (status['networkAvailable'] is bool) {
          onNetworkChanged?.call(status['networkAvailable'] as bool);
        }
        warning.value = status['failure'] as String?;
      }
    } catch (_) {
      warning.value = '后台下载保护暂不可用，请保持应用打开';
    }
  }

  void update(DownloadNoticeSnapshot snapshot) {
    if (!_enabled) return;
    // Loading a paused disk queue at cold start must not resurrect a dismissed
    // completion notice or start a foreground service from the background.
    if (!_hasPublished && !snapshot.needsService) return;
    if (snapshot.needsService) {
      _dismissed = false;
      _hasPublished = true;
      _heartbeat ??= Timer.periodic(const Duration(seconds: 30), (_) {
        if (_lastRequested?.needsService == true) {
          _pending = _lastRequested;
          _flush();
        }
      });
    } else if (snapshot.state != DownloadNoticeState.queued) {
      _heartbeat?.cancel();
      _heartbeat = null;
    }
    if (_dismissed && !snapshot.needsService) return;
    if (snapshot.state == DownloadNoticeState.queued) return;
    final transition = _lastRequested?.transitionKey != snapshot.transitionKey;
    _lastRequested = snapshot;
    _pending = snapshot;
    if (transition || !snapshot.needsService) {
      _timer?.cancel();
      _timer = null;
      _flush();
    } else {
      _timer ??= Timer(progressInterval, () {
        _timer = null;
        _flush();
      });
    }
  }

  void _flush() {
    final snapshot = _pending;
    _pending = null;
    if (snapshot == null) return;
    final method = snapshot.state == DownloadNoticeState.empty
        ? 'cancel'
        : snapshot.needsService
            ? 'update'
            : 'finish';
    _tail = _tail.then((_) async {
      try {
        final result = await _transport(method, snapshot.toMap());
        if (result is Map && result['failure'] is String) {
          warning.value = result['failure'] as String;
          onBackgroundProtectionLost?.call();
        }
      } catch (_) {
        warning.value = '后台下载保护暂不可用，请保持应用打开';
        onBackgroundProtectionLost?.call();
      }
    });
  }

  void markDismissed() {
    _dismissed = true;
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }

  Future<void> pullRoute() async {
    if (!_enabled) return;
    try {
      final route = await _transport('getInitialIntent', null);
      if (route == 'queue' || route == 'downloaded') {
        _pendingRoute = route as String;
        routeVersion.value++;
      }
    } catch (_) {}
  }

  String? takeRoute({required bool ready}) {
    if (!ready) return null;
    final route = _pendingRoute;
    _pendingRoute = null;
    return route;
  }

  Future<void> foregrounded() async {
    if (!_enabled) return;
    await initialize();
    try {
      await _transport('foregrounded', null);
      warning.value = null;
    } catch (_) {}
    await pullRoute();
    if (_lastRequested?.needsService == true) {
      _pending = _lastRequested;
      _flush();
    }
  }

  @visibleForTesting
  Future<void> get idle => _tail;

  void dispose() {
    _timer?.cancel();
    _heartbeat?.cancel();
    warning.dispose();
    routeVersion.dispose();
  }
}
