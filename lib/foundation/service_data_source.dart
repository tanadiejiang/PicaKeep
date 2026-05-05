import 'dart:convert';
import 'dart:io';

import 'package:picakeep/base.dart';
import 'package:picakeep/server/local_server_runtime.dart';

import 'app_runtime_mode.dart';

enum ServiceConnectionState {
  notConfigured,
  invalidAddress,
  online,
  offline,
  idle,
}

class ServiceInfoSnapshot {
  const ServiceInfoSnapshot({
    required this.mode,
    required this.connectionState,
    required this.discoveryMode,
    required this.addressInput,
    required this.normalizedAddress,
    required this.statusText,
    required this.detailText,
    this.statusUrl,
    this.adminUrl,
    this.latencyMs,
    this.httpStatusCode,
    this.comicCount,
    this.connectionCount,
    this.libraryRootCount,
    this.resourceBytes,
    this.totalRequests,
    this.startedAt,
  });

  final String mode;
  final ServiceConnectionState connectionState;
  final String discoveryMode;
  final String addressInput;
  final String normalizedAddress;
  final String statusText;
  final String detailText;
  final String? statusUrl;
  final String? adminUrl;
  final int? latencyMs;
  final int? httpStatusCode;
  final int? comicCount;
  final int? connectionCount;
  final int? libraryRootCount;
  final int? resourceBytes;
  final int? totalRequests;
  final String? startedAt;

  bool get isClientMode => mode == appRuntimeModeClient;
  bool get isServerMode => mode == appRuntimeModeServer;
  bool get hasConfiguredAddress => normalizedAddress.isNotEmpty;
}

abstract class RuntimeServiceDataSource {
  Future<ServiceInfoSnapshot> fetchSnapshot();
}

class RuntimeServiceDataSourceResolver {
  static RuntimeServiceDataSource current() {
    final mode =
        normalizeAppRuntimeMode(appdata.settings[appRuntimeModeSettingIndex]);
    if (mode == appRuntimeModeServer) {
      return canUseServerModeOnCurrentPlatform()
          ? LocalRuntimeServiceDataSource()
          : UnsupportedServerRuntimeServiceDataSource();
    }
    return RemoteRuntimeServiceDataSource();
  }
}

class RemoteRuntimeServiceDataSource implements RuntimeServiceDataSource {
  @override
  Future<ServiceInfoSnapshot> fetchSnapshot() async {
    final rawAddress = appdata.settings[remoteServerAddressSettingIndex];
    final normalizedAddress = normalizeRemoteServerAddressValue(rawAddress);
    final discoveryMode = normalizeServiceDiscoveryMode(
      appdata.settings[serviceDiscoveryModeSettingIndex],
    );

    if (rawAddress.trim().isEmpty) {
      return ServiceInfoSnapshot(
        mode: appRuntimeModeClient,
        connectionState: ServiceConnectionState.notConfigured,
        discoveryMode: discoveryMode,
        addressInput: rawAddress,
        normalizedAddress: '',
        statusText: '未配置服务端地址',
        detailText: '请先填写远程服务地址，后续客户端模式会通过这个地址访问服务端接口。',
      );
    }

    if (normalizedAddress.isEmpty) {
      return ServiceInfoSnapshot(
        mode: appRuntimeModeClient,
        connectionState: ServiceConnectionState.invalidAddress,
        discoveryMode: discoveryMode,
        addressInput: rawAddress,
        normalizedAddress: '',
        statusText: '地址格式无效',
        detailText: '当前地址无法解析为可访问的 HTTP 服务地址。',
      );
    }

    final statusUrl = buildRemoteServiceStatusUrl(normalizedAddress);
    final statusUri = tryParseRemoteServerUri(statusUrl);
    if (statusUri == null) {
      return ServiceInfoSnapshot(
        mode: appRuntimeModeClient,
        connectionState: ServiceConnectionState.invalidAddress,
        discoveryMode: discoveryMode,
        addressInput: rawAddress,
        normalizedAddress: normalizedAddress,
        statusText: '状态地址无效',
        detailText: '已保存服务地址，但无法推导出有效的 /status 接口地址。',
      );
    }

    final stopwatch = Stopwatch()..start();
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      try {
        final request = await client.getUrl(statusUri).timeout(
              const Duration(seconds: 3),
            );
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response = await request.close().timeout(
              const Duration(seconds: 3),
            );
        final body = await utf8.decoder.bind(response).join().timeout(
              const Duration(seconds: 2),
              onTimeout: () => '',
            );
        stopwatch.stop();
        final payload = _tryParseJsonMap(body);
        final comicCount = _tryReadInt(payload?['comicCount']);
        final connectionCount = _tryReadInt(payload?['connectionCount']);
        final libraryRootCount = _tryReadInt(payload?['libraryRootCount']);
        final resourceBytes = _tryReadInt(payload?['resourceBytes']);
        final totalRequests = _tryReadInt(payload?['totalRequests']);
        final startedAt = payload?['startedAt']?.toString();
        final adminUrl = payload?['adminUrl']?.toString();
        final message = payload?['message']?.toString().trim();
        final isOnline =
            response.statusCode >= 200 && response.statusCode < 300;
        return ServiceInfoSnapshot(
          mode: appRuntimeModeClient,
          connectionState: isOnline
              ? ServiceConnectionState.online
              : ServiceConnectionState.offline,
          discoveryMode: discoveryMode,
          addressInput: rawAddress,
          normalizedAddress: normalizedAddress,
          statusUrl: statusUrl,
          adminUrl: adminUrl,
          statusText: isOnline ? '在线' : '服务有响应，但状态异常',
          detailText: (message != null && message.isNotEmpty)
              ? message
              : '已访问 $statusUrl，返回状态码 ${response.statusCode}。',
          latencyMs: stopwatch.elapsedMilliseconds,
          httpStatusCode: response.statusCode,
          comicCount: comicCount,
          connectionCount: connectionCount,
          libraryRootCount: libraryRootCount,
          resourceBytes: resourceBytes,
          totalRequests: totalRequests,
          startedAt: startedAt,
        );
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      stopwatch.stop();
      return ServiceInfoSnapshot(
        mode: appRuntimeModeClient,
        connectionState: ServiceConnectionState.offline,
        discoveryMode: discoveryMode,
        addressInput: rawAddress,
        normalizedAddress: normalizedAddress,
        statusUrl: statusUrl,
        statusText: '无法连接',
        detailText: '已尝试访问 $statusUrl，但当前没有可用服务响应。',
      );
    }
  }
}

class UnsupportedServerRuntimeServiceDataSource
    implements RuntimeServiceDataSource {
  @override
  Future<ServiceInfoSnapshot> fetchSnapshot() async {
    final capability = currentServerPlatformCapability();
    return ServiceInfoSnapshot(
      mode: appRuntimeModeServer,
      connectionState: ServiceConnectionState.idle,
      discoveryMode: normalizeServiceDiscoveryMode(
        appdata.settings[serviceDiscoveryModeSettingIndex],
      ),
      addressInput: '',
      normalizedAddress: '',
      statusText: '当前平台不支持服务端模式',
      detailText:
          '${capability.displayName} 暂未纳入当前服务端目标。${serverPlatformTierDescription(capability.tier)}',
    );
  }
}

class LocalRuntimeServiceDataSource implements RuntimeServiceDataSource {
  @override
  Future<ServiceInfoSnapshot> fetchSnapshot() async {
    final capability = currentServerPlatformCapability();
    final runtimeSnapshot = await LocalServerRuntime.instance.readSnapshot();
    final discoveryMode = normalizeServiceDiscoveryMode(
      appdata.settings[serviceDiscoveryModeSettingIndex],
    );

    if (capability.isEnhancedServerTarget && !runtimeSnapshot.isRunning) {
      return ServiceInfoSnapshot(
        mode: appRuntimeModeServer,
        connectionState: ServiceConnectionState.idle,
        discoveryMode: discoveryMode,
        addressInput: '',
        normalizedAddress: '',
        statusUrl: runtimeSnapshot.statusUrl,
        adminUrl: runtimeSnapshot.adminUrl,
        statusText: '待接入前台服务',
        detailText: '当前平台属于移动增强服务端目标，后续需要前台服务、保活策略与权限链路共同配合。',
        comicCount: runtimeSnapshot.comicCount ?? 0,
        connectionCount: runtimeSnapshot.connectionCount ?? 0,
        libraryRootCount: runtimeSnapshot.libraryRootCount,
        resourceBytes: runtimeSnapshot.resourceBytes,
        totalRequests: runtimeSnapshot.totalRequests,
        startedAt: runtimeSnapshot.startedAt,
      );
    }

    return ServiceInfoSnapshot(
      mode: appRuntimeModeServer,
      connectionState: runtimeSnapshot.isRunning
          ? ServiceConnectionState.online
          : runtimeSnapshot.hasError
              ? ServiceConnectionState.offline
              : ServiceConnectionState.idle,
      discoveryMode: discoveryMode,
      addressInput: '',
      normalizedAddress: '',
      statusUrl: runtimeSnapshot.statusUrl,
      adminUrl: runtimeSnapshot.adminUrl,
      statusText: runtimeSnapshot.statusText,
      detailText: runtimeSnapshot.detailText,
      comicCount: runtimeSnapshot.comicCount ?? 0,
      connectionCount: runtimeSnapshot.connectionCount ?? 0,
      libraryRootCount: runtimeSnapshot.libraryRootCount,
      resourceBytes: runtimeSnapshot.resourceBytes,
      totalRequests: runtimeSnapshot.totalRequests,
      startedAt: runtimeSnapshot.startedAt,
    );
  }
}

Map<String, dynamic>? _tryParseJsonMap(String value) {
  if (value.trim().isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(value);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
  } catch (_) {}
  return null;
}

int? _tryReadInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}
