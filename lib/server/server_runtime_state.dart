import 'dart:collection';

const serverRuntimeLifecycleStopped = 'stopped';
const serverRuntimeLifecycleStarting = 'starting';
const serverRuntimeLifecycleRunning = 'running';
const serverRuntimeLifecycleStopping = 'stopping';
const serverRuntimeLifecycleError = 'error';

class ServerRuntimeState {
  ServerRuntimeState({this.onChanged, this.onStatsChanged});

  DateTime? startedAt;
  int totalRequests = 0;
  int activeConnections = 0;
  String lifecycle = serverRuntimeLifecycleStopped;
  String? lastMessage;
  String? lastError;
  void Function()? onChanged;
  void Function()? onStatsChanged;
  final ListQueue<Map<String, dynamic>> _recentLogs = ListQueue();

  bool get isRunning => lifecycle == serverRuntimeLifecycleRunning;

  void markStarting([String message = '正在启动服务']) {
    lifecycle = serverRuntimeLifecycleStarting;
    startedAt = null;
    totalRequests = 0;
    activeConnections = 0;
    lastError = null;
    lastMessage = message;
    addLog('server', message, notify: false);
    _notifyChanged();
  }

  void markRunning(String message) {
    lifecycle = serverRuntimeLifecycleRunning;
    startedAt = DateTime.now();
    totalRequests = 0;
    activeConnections = 0;
    lastError = null;
    lastMessage = message;
    addLog('server', message, notify: false);
    _notifyChanged();
  }

  void markStopping([String message = '正在停止服务']) {
    lifecycle = serverRuntimeLifecycleStopping;
    lastMessage = message;
    addLog('server', message, notify: false);
    _notifyChanged();
  }

  void markStopped([String message = '服务已停止']) {
    lifecycle = serverRuntimeLifecycleStopped;
    startedAt = null;
    totalRequests = 0;
    activeConnections = 0;
    lastError = null;
    lastMessage = message;
    addLog('server', message, notify: false);
    _notifyChanged();
  }

  void markError(Object error, [StackTrace? stackTrace]) {
    lifecycle = serverRuntimeLifecycleError;
    startedAt = null;
    activeConnections = 0;
    lastError = error.toString();
    lastMessage = '服务运行失败';
    addLog('error', lastError!, notify: false);
    if (stackTrace != null) {
      addLog('error', stackTrace.toString(), notify: false);
    }
    _notifyChanged();
  }

  void beginRequest(String method, String path) {
    totalRequests++;
    activeConnections++;
    addLog('request', '$method $path', notify: false);
    _notifyStatsChanged();
  }

  void endRequest() {
    if (activeConnections > 0) {
      activeConnections--;
    }
    _notifyStatsChanged();
  }

  void addLog(String type, String message, {bool notify = true}) {
    _recentLogs.addLast({
      'time': DateTime.now().toIso8601String(),
      'type': type,
      'message': message,
    });
    while (_recentLogs.length > 100) {
      _recentLogs.removeFirst();
    }
    if (notify) {
      _notifyStatsChanged();
    }
  }

  List<Map<String, dynamic>> recentLogs() =>
      _recentLogs.toList(growable: false);

  void _notifyChanged() {
    onChanged?.call();
  }

  void _notifyStatsChanged() {
    onStatsChanged?.call();
  }
}
