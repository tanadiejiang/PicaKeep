import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/service_data_source.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as web_socket_status;

class RemoteLibraryEventChannel {
  RemoteLibraryEventChannel._();

  static final RemoteLibraryEventChannel instance =
      RemoteLibraryEventChannel._();

  static const Duration _heartbeatInterval = Duration(seconds: 25);
  static const Duration _staleConnectionTimeout = Duration(seconds: 30);
  static const Duration _statusProbeMinInterval = Duration(seconds: 8);
  static const List<Duration> _reconnectBackoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];

  bool _started = false;
  bool _foreground = true;
  bool _connecting = false;
  String? _lastKnownSignature;
  String? _pendingSignature;
  DateTime? _lastMessageAt;
  DateTime? _lastStatusProbeAt;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  StreamSubscription<dynamic>? _socketSubscription;
  IOWebSocketChannel? _channel;
  int _reconnectAttempt = 0;
  int _suppressedRuntimeVersionReactions = 0;
  bool _statusProbeInFlight = false;

  void start() {
    if (_started) {
      return;
    }
    _started = true;
    App.serviceConfigVersion.addListener(_handleServiceConfigChanged);
    App.serviceRuntimeVersion.addListener(_handleServiceRuntimeChanged);
    App.isReadingActive.addListener(_handleReadingStateChanged);
    _ensureConnectedOrProbe(resetBackoff: true, forceStatusProbe: true);
  }

  void onForeground() {
    _foreground = true;
    _ensureConnectedOrProbe(forceStatusProbe: true);
  }

  void onBackground() {
    _foreground = false;
    _disconnect();
  }

  void onRemotePageActivated() {
    _ensureConnectedOrProbe(forceStatusProbe: true);
  }

  void flushPendingSignature() {
    final signature = _pendingSignature?.trim() ?? '';
    _pendingSignature = null;
    if (signature.isEmpty) {
      return;
    }
    _applySignature(signature);
  }

  void _handleServiceConfigChanged() {
    _lastKnownSignature = null;
    _pendingSignature = null;
    _disconnect();
    _ensureConnectedOrProbe(resetBackoff: true, forceStatusProbe: true);
  }

  void _handleServiceRuntimeChanged() {
    if (_suppressedRuntimeVersionReactions > 0) {
      _suppressedRuntimeVersionReactions--;
      return;
    }
    _ensureConnectedOrProbe(resetBackoff: true);
  }

  void _handleReadingStateChanged() {
    if (App.isReadingActive.value) {
      _disconnect();
      return;
    }
    flushPendingSignature();
    _ensureConnectedOrProbe(resetBackoff: true, forceStatusProbe: true);
  }

  bool get _shouldConnect {
    if (!_started || !_foreground || App.isReadingActive.value) {
      return false;
    }
    if (normalizeAppRuntimeMode(appdata.settings[appRuntimeModeSettingIndex]) !=
        appRuntimeModeClient) {
      return false;
    }
    return normalizeRemoteServerAddressValue(
      appdata.settings[remoteServerAddressSettingIndex],
    ).isNotEmpty;
  }

  void _ensureConnectedOrProbe({
    bool resetBackoff = false,
    bool forceStatusProbe = false,
  }) {
    if (!_shouldConnect) {
      _disconnect();
      return;
    }
    if (resetBackoff) {
      _resetReconnectBackoff();
    }
    if (_channel == null && !_connecting) {
      unawaited(_connect());
    }
    if (forceStatusProbe && (_channel == null || _connecting)) {
      unawaited(_probeStatusSignatureIfNeeded(force: true));
    }
  }

  Future<void> _connect() async {
    if (_connecting || !_shouldConnect) {
      return;
    }
    final uri = _buildEventsUri();
    if (uri == null) {
      return;
    }
    _connecting = true;
    try {
      final socket = await WebSocket.connect(uri.toString()).timeout(
        const Duration(seconds: 5),
      );
      if (!_shouldConnect) {
        await socket.close(web_socket_status.goingAway);
        return;
      }
      final channel = IOWebSocketChannel(socket);
      _channel = channel;
      _lastMessageAt = DateTime.now();
      _reconnectAttempt = 0;
      _socketSubscription = channel.stream.listen(
        _handleSocketMessage,
        onDone: _handleSocketClosed,
        onError: (_) => _handleSocketClosed(),
        cancelOnError: true,
      );
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
        _sendHeartbeatOrReconnect();
      });
    } catch (_) {
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _handleSocketMessage(dynamic payload) {
    _lastMessageAt = DateTime.now();
    final text = switch (payload) {
      String value => value,
      List<int> value => utf8.decode(value, allowMalformed: true),
      _ => '',
    };
    if (text.trim().isEmpty) {
      return;
    }
    Map<String, dynamic>? jsonMap;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        jsonMap = decoded;
      } else if (decoded is Map) {
        jsonMap = decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      return;
    }
    if (jsonMap == null) {
      return;
    }
    final type = jsonMap['type']?.toString().trim() ?? '';
    if (type == 'ping' || type == 'pong') {
      return;
    }
    if (type != 'library-changed') {
      return;
    }
    final signature = jsonMap['signature']?.toString().trim() ?? '';
    if (signature.isEmpty) {
      return;
    }
    if (App.isReadingActive.value) {
      _pendingSignature = signature;
      return;
    }
    _applySignature(signature);
  }

  void _applySignature(String signature) {
    final normalized = signature.trim();
    if (normalized.isEmpty) {
      return;
    }
    final currentClientSignature =
        RemoteLibraryClient.tryFromCurrentSettings()?.currentSignature?.trim() ??
            '';
    if (_lastKnownSignature == normalized || currentClientSignature == normalized) {
      _lastKnownSignature = normalized;
      return;
    }
    _lastKnownSignature = normalized;
    _suppressedRuntimeVersionReactions++;
    App.notifyServiceRuntimeChanged();
  }

  void _handleSocketClosed() {
    _disconnect();
    _scheduleReconnect();
  }

  void _sendHeartbeatOrReconnect() {
    final now = DateTime.now();
    final lastMessageAt = _lastMessageAt;
    if (lastMessageAt == null ||
        now.difference(lastMessageAt) > _staleConnectionTimeout) {
      _disconnect();
      _scheduleReconnect();
      return;
    }
    try {
      _channel?.sink.add(
        jsonEncode({
          'type': 'ping',
          'generatedAt': now.toIso8601String(),
        }),
      );
    } catch (_) {
      _disconnect();
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!_shouldConnect || _reconnectTimer != null) {
      return;
    }
    final delay = _reconnectBackoff[
        _reconnectAttempt.clamp(0, _reconnectBackoff.length - 1)];
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      _ensureConnectedOrProbe(forceStatusProbe: true);
    });
  }

  void _resetReconnectBackoff() {
    _reconnectAttempt = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _disconnect() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    unawaited(_socketSubscription?.cancel());
    _socketSubscription = null;
    try {
      _channel?.sink.close(web_socket_status.goingAway);
    } catch (_) {}
    _channel = null;
    _connecting = false;
    _lastMessageAt = null;
  }

  Future<void> _probeStatusSignatureIfNeeded({bool force = false}) async {
    if (!_shouldConnect || _statusProbeInFlight) {
      return;
    }
    final now = DateTime.now();
    if (!force &&
        _lastStatusProbeAt != null &&
        now.difference(_lastStatusProbeAt!) < _statusProbeMinInterval) {
      return;
    }
    _statusProbeInFlight = true;
    _lastStatusProbeAt = now;
    try {
      final snapshot = await RemoteRuntimeServiceDataSource().fetchSnapshot();
      if (snapshot.connectionState != ServiceConnectionState.online) {
        return;
      }
      final signature = snapshot.librarySignature?.trim() ?? '';
      if (signature.isEmpty) {
        return;
      }
      if (App.isReadingActive.value) {
        _pendingSignature = signature;
        return;
      }
      _applySignature(signature);
    } catch (_) {
      // Ignore fallback probe failures and keep retrying via the normal backoff.
    } finally {
      _statusProbeInFlight = false;
    }
  }

  Uri? _buildEventsUri() {
    final baseUri = tryParseRemoteServerUri(
      appdata.settings[remoteServerAddressSettingIndex],
    );
    if (baseUri == null) {
      return null;
    }
    final resolved = baseUri.resolve('/api/events');
    final scheme = resolved.scheme == 'https' ? 'wss' : 'ws';
    return resolved.replace(scheme: scheme);
  }
}
