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
    this.librarySignature,
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
  final String? librarySignature;
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
        final librarySignature = payload?['librarySignature']?.toString();
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
          librarySignature: librarySignature,
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
    final detailText = capability.isEnhancedServerTarget &&
            !runtimeSnapshot.isRunning &&
            !runtimeSnapshot.hasError
        ? '${runtimeSnapshot.detailText} 如需持续保持服务端在线，请允许通知并尽量关闭系统电池优化限制。'
        : runtimeSnapshot.detailText;

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
      detailText: detailText,
      comicCount: runtimeSnapshot.comicCount ?? 0,
      connectionCount: runtimeSnapshot.connectionCount ?? 0,
      libraryRootCount: runtimeSnapshot.libraryRootCount,
      resourceBytes: runtimeSnapshot.resourceBytes,
      totalRequests: runtimeSnapshot.totalRequests,
      startedAt: runtimeSnapshot.startedAt,
    );
  }
}

class LocalNetworkServiceDiscoveryResult {
  const LocalNetworkServiceDiscoveryResult({
    required this.candidates,
    required this.scannedHostCount,
    required this.scannedSubnetCount,
  });

  final List<ServiceDiscoveryCandidate> candidates;
  final int scannedHostCount;
  final int scannedSubnetCount;
}

class ServiceDiscoveryCandidate {
  const ServiceDiscoveryCandidate({
    required this.address,
    required this.adminUrl,
    required this.detailText,
    this.comicCount,
    this.latencyMs,
  });

  final String address;
  final String adminUrl;
  final String detailText;
  final int? comicCount;
  final int? latencyMs;
}

class LocalNetworkServiceDiscovery {
  Future<LocalNetworkServiceDiscoveryResult> scan({
    String? preferredAddress,
    String? fallbackPort,
  }) async {
    final ports = _resolveCandidatePorts(preferredAddress, fallbackPort);
    final prefixes = await _resolveCandidatePrefixes(preferredAddress);
    final preferredHost =
        tryParseRemoteServerUri(preferredAddress ?? '')?.host ?? '';
    final explicitHosts = <String>{
      if (preferredHost.isNotEmpty && !_isLoopbackHost(preferredHost))
        preferredHost,
    };
    if (prefixes.isEmpty && explicitHosts.isEmpty) {
      return const LocalNetworkServiceDiscoveryResult(
        candidates: <ServiceDiscoveryCandidate>[],
        scannedHostCount: 0,
        scannedSubnetCount: 0,
      );
    }

    final localHosts = await _resolveLocalIpv4Hosts();
    final hosts = <String>{
      ...explicitHosts,
      for (final prefix in prefixes)
        for (var i = 1; i <= 254; i++) '$prefix.$i',
    };
    final removableLocalHosts = Set<String>.from(localHosts)
      ..removeAll(explicitHosts);
    hosts.removeAll(removableLocalHosts);

    final remainingHosts = Set<String>.from(hosts)..removeAll(explicitHosts);
    final targets = <String>[
      ...explicitHosts.where(hosts.contains),
      ...(remainingHosts.toList()..sort()),
    ];
    if (targets.isEmpty) {
      return const LocalNetworkServiceDiscoveryResult(
        candidates: <ServiceDiscoveryCandidate>[],
        scannedHostCount: 0,
        scannedSubnetCount: 0,
      );
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 450)
      ..maxConnectionsPerHost = 64;
    final candidatesByAddress = <String, ServiceDiscoveryCandidate>{};
    var scannedHostCount = 0;
    try {
      const chunkSize = 64;
      for (var i = 0; i < targets.length; i += chunkSize) {
        final chunk = targets.sublist(
          i,
          i + chunkSize > targets.length ? targets.length : i + chunkSize,
        );
        scannedHostCount += chunk.length * ports.length;
        final results = await Future.wait(
          [
            for (final host in chunk)
              for (final port in ports) _probeHost(client, host, port),
          ],
        );
        for (final candidate
            in results.whereType<ServiceDiscoveryCandidate>()) {
          candidatesByAddress.putIfAbsent(candidate.address, () => candidate);
        }
        if (candidatesByAddress.isNotEmpty) {
          break;
        }
      }
    } finally {
      client.close(force: true);
    }

    final candidates = candidatesByAddress.values.toList()
      ..sort(
        (a, b) => (a.latencyMs ?? 1 << 30).compareTo(b.latencyMs ?? 1 << 30),
      );
    return LocalNetworkServiceDiscoveryResult(
      candidates: candidates,
      scannedHostCount: scannedHostCount,
      scannedSubnetCount: prefixes.length,
    );
  }

  Future<ServiceDiscoveryCandidate?> _probeHost(
    HttpClient client,
    String host,
    int port,
  ) async {
    final uri = Uri(scheme: 'http', host: host, port: port, path: '/status');
    final stopwatch = Stopwatch()..start();
    try {
      final request = await client.getUrl(uri).timeout(
            const Duration(milliseconds: 450),
          );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
            const Duration(milliseconds: 700),
          );
      final body = await utf8.decoder.bind(response).join().timeout(
            const Duration(milliseconds: 500),
            onTimeout: () => '',
          );
      stopwatch.stop();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final payload = _tryParseJsonMap(body);
      final detailText = payload?['message']?.toString().trim();
      return ServiceDiscoveryCandidate(
        address: 'http://$host:$port',
        adminUrl: payload?['adminUrl']?.toString().trim().isNotEmpty == true
            ? payload!['adminUrl'].toString().trim()
            : buildServiceAdminUrl(host, port: '$port'),
        detailText: (detailText != null && detailText.isNotEmpty)
            ? detailText
            : '发现可用服务',
        comicCount: _tryReadInt(payload?['comicCount']),
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } catch (_) {
      stopwatch.stop();
      return null;
    }
  }

  List<int> _resolveCandidatePorts(
      String? preferredAddress, String? fallbackPort) {
    final ports = <int>[];

    void addPort(int? port) {
      if (port == null || port < 1 || port > 65535 || ports.contains(port)) {
        return;
      }
      ports.add(port);
    }

    final preferredUri = tryParseRemoteServerUri(preferredAddress ?? '');
    if (preferredUri != null && preferredUri.hasPort) {
      addPort(preferredUri.port);
    }
    addPort(
      int.tryParse(
        normalizeServiceAdminPortValue(fallbackPort ?? defaultServiceAdminPort),
      ),
    );
    addPort(int.tryParse(defaultServiceAdminPort));
    if (ports.isEmpty) {
      return const [9527];
    }
    return ports;
  }

  Future<List<String>> _resolveCandidatePrefixes(
      String? preferredAddress) async {
    final prefixes = <String>[];
    final seen = <String>{};

    void addPrefixFromHost(String host) {
      final prefix = _extractIpv4Prefix(host);
      if (prefix == null || !seen.add(prefix)) {
        return;
      }
      prefixes.add(prefix);
    }

    final preferredHost =
        tryParseRemoteServerUri(preferredAddress ?? '')?.host ?? '';
    if (_isPrivateIpv4(preferredHost)) {
      addPrefixFromHost(preferredHost);
    }

    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final networkInterface in interfaces) {
      for (final address in networkInterface.addresses) {
        final host = address.address;
        if (_isPrivateIpv4(host)) {
          addPrefixFromHost(host);
        }
      }
    }

    if (prefixes.length > 2) {
      return prefixes.sublist(0, 2);
    }
    return prefixes;
  }

  Future<Set<String>> _resolveLocalIpv4Hosts() async {
    final hosts = <String>{};
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final networkInterface in interfaces) {
      for (final address in networkInterface.addresses) {
        if (_isPrivateIpv4(address.address)) {
          hosts.add(address.address);
        }
      }
    }
    return hosts;
  }

  bool _isLoopbackHost(String value) {
    return value == '127.0.0.1' || value.toLowerCase() == 'localhost';
  }
}

String? _extractIpv4Prefix(String value) {
  final parts = value.split('.');
  if (parts.length != 4) {
    return null;
  }
  return '${parts[0]}.${parts[1]}.${parts[2]}';
}

bool _isPrivateIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) {
    return false;
  }
  final numbers = parts.map(int.tryParse).toList(growable: false);
  if (numbers.any((element) => element == null)) {
    return false;
  }
  final first = numbers[0]!;
  final second = numbers[1]!;
  return first == 10 ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168);
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
