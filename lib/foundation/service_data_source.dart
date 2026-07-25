import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/remote_service_network_policy.dart';
import 'package:picakeep/server/local_server_runtime.dart';

import 'app_runtime_mode.dart';
import 'picakeep_mdns.dart';

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
    this.deviceSystem,
    this.deviceName,
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
  final String? deviceSystem;
  final String? deviceName;

  String get deviceSummary => _buildDeviceSummary(
        deviceSystem: deviceSystem,
        deviceName: deviceName,
        hostName: normalizedAddress,
        address: normalizedAddress,
      );

  bool get isClientMode => mode == appRuntimeModeClient;
  bool get isServerMode => mode == appRuntimeModeServer;

  /// A malformed but non-empty saved address must remain clearable. The
  /// normalized value is only for connection attempts, not for destructive
  /// configuration cleanup.
  bool get hasConfiguredAddress => addressInput.trim().isNotEmpty;
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

HttpClient _createRemoteServiceClient({
  Duration? connectionTimeout,
  Duration? idleTimeout,
  int? maxConnectionsPerHost,
  bool forceDirect = false,
}) {
  return RemoteServiceNetworkPolicy.createClient(
    manualProxy: appdata.settings[8],
    connectionTimeout: connectionTimeout,
    idleTimeout: idleTimeout,
    maxConnectionsPerHost: maxConnectionsPerHost,
    forceDirect: forceDirect,
    onDecision: (decision, uri) {
      final local = decision.hostKind == RemoteServiceHostKind.loopback ||
          decision.hostKind == RemoteServiceHostKind.lan ||
          decision.hostKind == RemoteServiceHostKind.linkLocal;
      Log.info(
        'RemoteNet',
        '${local ? 'local-direct' : decision.source.name} '
            '${uri.scheme}://${uri.host}',
      );
    },
  );
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
      final client = _createRemoteServiceClient(
        connectionTimeout: const Duration(seconds: 3),
      );
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
        final deviceSystem = payload?['deviceSystem']?.toString().trim();
        final deviceName = payload?['deviceName']?.toString().trim();
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
          deviceSystem: deviceSystem,
          deviceName: deviceName,
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
      deviceSystem: _localDeviceSystem(),
      deviceName: _localDeviceName(),
      comicCount: runtimeSnapshot.comicCount ?? 0,
      connectionCount: runtimeSnapshot.connectionCount ?? 0,
      libraryRootCount: runtimeSnapshot.libraryRootCount,
      resourceBytes: runtimeSnapshot.resourceBytes,
      totalRequests: runtimeSnapshot.totalRequests,
      startedAt: runtimeSnapshot.startedAt,
    );
  }
}

enum DiscoveryProgressStage {
  mdns,
  subnetScan,
  completed,
  cancelled,
  timedOut,
  failed,
}

class DiscoveryProgress {
  const DiscoveryProgress({
    required this.stage,
    required this.plannedEndpoints,
    required this.completedEndpoints,
    required this.candidateCount,
    required this.portCount,
    this.currentHost,
    this.error,
    this.candidates = const <ServiceDiscoveryCandidate>[],
  });

  final DiscoveryProgressStage stage;
  final int plannedEndpoints;
  final int completedEndpoints;
  final int candidateCount;
  final int portCount;
  final String? currentHost;
  final Object? error;

  /// 截至此刻已累计发现的候选快照（按延迟排序）；未命中时为空列表。
  final List<ServiceDiscoveryCandidate> candidates;

  bool get isCancelled => stage == DiscoveryProgressStage.cancelled;
  bool get isTimedOut => stage == DiscoveryProgressStage.timedOut;
}

class LocalNetworkServiceDiscoveryResult {
  const LocalNetworkServiceDiscoveryResult({
    required this.candidates,
    required this.scannedHostCount,
    required this.scannedSubnetCount,
    this.scannedPortCount = 0,
    this.scannedEndpointCount = 0,
    this.plannedEndpointCount = 0,
    this.requestedMode = serviceDiscoveryModeMdns,
    this.effectiveMode = serviceDiscoveryModeMdns,
    this.fellBackToSubnetScan = false,
    this.cancelled = false,
    this.timedOut = false,
  });

  final List<ServiceDiscoveryCandidate> candidates;
  final int scannedHostCount;
  final int scannedPortCount;
  final int scannedEndpointCount;
  final int plannedEndpointCount;
  final int scannedSubnetCount;
  final String requestedMode;
  final String effectiveMode;
  final bool fellBackToSubnetScan;
  final bool cancelled;
  final bool timedOut;
}

class ServiceDiscoveryCandidate {
  const ServiceDiscoveryCandidate({
    required this.address,
    required this.adminUrl,
    required this.detailText,
    required this.sourceMode,
    required this.port,
    this.comicCount,
    this.latencyMs,
    this.instanceName,
    this.hostName,
    this.serviceName,
    this.appName,
    this.deviceSystem,
    this.deviceName,
  });

  final String address;
  final String adminUrl;
  final String detailText;
  final String sourceMode;
  final int port;
  final int? comicCount;
  final int? latencyMs;
  final String? instanceName;
  final String? hostName;
  final String? serviceName;
  final String? appName;
  final String? deviceSystem;
  final String? deviceName;

  String get sourceLabel => serviceDiscoveryModeLabel(sourceMode);

  String get deviceSummary => _buildDeviceSummary(
        deviceSystem: deviceSystem,
        deviceName: deviceName,
        hostName: hostName,
        address: address,
      );

  String get displayName {
    final values = [
      instanceName,
      hostName,
      appName,
      serviceName,
    ];
    for (final value in values) {
      final normalized = _cleanDiscoveryDisplayName(value);
      if (normalized.isNotEmpty) {
        return normalized;
      }
    }
    return address;
  }
}

class ServiceDiscoveryProbeRequest {
  const ServiceDiscoveryProbeRequest({
    required this.host,
    required this.port,
    required this.sourceMode,
    this.instanceName,
    this.hostName,
    this.serviceName,
    this.appName,
    this.deviceSystemHint,
    this.deviceNameHint,
  });

  final String host;
  final int port;
  final String sourceMode;
  final String? instanceName;
  final String? hostName;
  final String? serviceName;
  final String? appName;
  final String? deviceSystemHint;
  final String? deviceNameHint;
}

typedef ServiceDiscoveryProbe = Future<ServiceDiscoveryCandidate?> Function(
    ServiceDiscoveryProbeRequest);
typedef ServiceDiscoveryMdnsFactory = PicaKeepMdnsDiscovery Function();
typedef ServiceDiscoveryPrefixResolver = Future<List<String>> Function(
    String? preferredAddress);
typedef ServiceDiscoveryLocalHostResolver = Future<Set<String>> Function();

class DiscoverySession {
  DiscoverySession({
    required Future<LocalNetworkServiceDiscoveryResult> Function(
      DiscoverySession session,
    ) operation,
    this.generation = 0,
  }) {
    _result = _run(operation);
  }

  final int generation;
  final DiscoveryCancellationToken cancellationToken =
      DiscoveryCancellationToken();
  final StreamController<DiscoveryProgress> _progressController =
      StreamController<DiscoveryProgress>.broadcast();
  late final Future<LocalNetworkServiceDiscoveryResult> _result;
  HttpClient? _client;
  PicaKeepMdnsDiscovery? _mdns;
  bool _cancelRequested = false;

  Future<LocalNetworkServiceDiscoveryResult> get result => _result;
  Stream<DiscoveryProgress> get progress => _progressController.stream;
  bool get isCancelled => _cancelRequested;

  Future<LocalNetworkServiceDiscoveryResult> _run(
    Future<LocalNetworkServiceDiscoveryResult> Function(
      DiscoverySession session,
    ) operation,
  ) async {
    try {
      return await operation(this);
    } finally {
      await _progressController.close();
    }
  }

  void attachClient(HttpClient client) {
    if (_cancelRequested) {
      client.close(force: true);
      return;
    }
    _client = client;
  }

  void attachMdns(PicaKeepMdnsDiscovery mdns) {
    if (_cancelRequested) {
      unawaited(mdns.stop());
      return;
    }
    _mdns = mdns;
  }

  void emit(DiscoveryProgress event) {
    if (_cancelRequested || _progressController.isClosed) {
      return;
    }
    _progressController.add(event);
  }

  Future<void> cancel() async {
    if (!_cancelRequested) {
      _cancelRequested = true;
      cancellationToken.cancel();
      _client?.close(force: true);
      await _mdns?.stop();
    }
    try {
      await _result;
    } catch (_) {}
  }
}

class _DiscoveryAccumulator {
  final candidatesByAddress = <String, ServiceDiscoveryCandidate>{};
  final hosts = <String>{};
  final ports = <int>{};
  int completedEndpoints = 0;

  List<ServiceDiscoveryCandidate> get sortedCandidates =>
      candidatesByAddress.values.toList()
        ..sort(
          (a, b) => (a.latencyMs ?? 1 << 30).compareTo(b.latencyMs ?? 1 << 30),
        );
}

class LocalNetworkServiceDiscovery {
  LocalNetworkServiceDiscovery({
    this.probe,
    this.mdnsFactory = PicaKeepMdnsDiscovery.new,
    this.prefixResolver,
    this.localHostResolver,
    this.hostConcurrency = 20,
    this.totalTimeout = const Duration(seconds: 20),
  }) : assert(hostConcurrency > 0);

  /// 主机级并发上限。单网段 253 主机 × 2 端口时，20 并发 + 20s 预算可扫完本机段。
  static const hostConcurrencyLimit = 20;

  final ServiceDiscoveryProbe? probe;
  final ServiceDiscoveryMdnsFactory mdnsFactory;
  final ServiceDiscoveryPrefixResolver? prefixResolver;
  final ServiceDiscoveryLocalHostResolver? localHostResolver;
  final int hostConcurrency;
  final Duration totalTimeout;

  DiscoverySession createSession({
    required String mode,
    String? preferredAddress,
    bool fallbackToSubnetScan = false,
    List<int>? effectiveScanPorts,
    int generation = 0,
    Iterable<String>? candidateHosts,
  }) {
    return DiscoverySession(
      generation: generation,
      operation: (session) => discover(
        mode: mode,
        preferredAddress: preferredAddress,
        fallbackToSubnetScan: fallbackToSubnetScan,
        effectiveScanPorts: effectiveScanPorts,
        cancellationToken: session.cancellationToken,
        session: session,
        candidateHosts: candidateHosts,
      ),
    );
  }

  Future<LocalNetworkServiceDiscoveryResult> discover({
    required String mode,
    String? preferredAddress,
    String? fallbackPort,
    bool fallbackToSubnetScan = false,
    List<int>? effectiveScanPorts,
    DiscoveryCancellationToken? cancellationToken,
    DiscoverySession? session,
    Iterable<String>? candidateHosts,
  }) {
    final token = cancellationToken ?? DiscoveryCancellationToken();
    final future = _discover(
      mode: mode,
      preferredAddress: preferredAddress,
      fallbackToSubnetScan: fallbackToSubnetScan,
      effectiveScanPorts: effectiveScanPorts,
      cancellationToken: token,
      session: session,
      candidateHosts: candidateHosts,
    );
    return future.timeout(
      totalTimeout,
      onTimeout: () {
        token.cancel();
        return LocalNetworkServiceDiscoveryResult(
          candidates: const <ServiceDiscoveryCandidate>[],
          scannedHostCount: 0,
          scannedPortCount: 0,
          scannedEndpointCount: 0,
          plannedEndpointCount: 0,
          scannedSubnetCount: 0,
          requestedMode: normalizeServiceDiscoveryMode(mode),
          effectiveMode: normalizeServiceDiscoveryMode(mode),
          cancelled: false,
          timedOut: true,
        );
      },
    );
  }

  Future<LocalNetworkServiceDiscoveryResult> _discover({
    required String mode,
    required String? preferredAddress,
    required bool fallbackToSubnetScan,
    required List<int>? effectiveScanPorts,
    required DiscoveryCancellationToken cancellationToken,
    required DiscoverySession? session,
    required Iterable<String>? candidateHosts,
  }) async {
    final normalizedMode = normalizeServiceDiscoveryMode(mode);
    if (normalizedMode == serviceDiscoveryModeSubnetScan) {
      return scan(
        preferredAddress: preferredAddress,
        effectiveScanPorts: effectiveScanPorts,
        cancellationToken: cancellationToken,
        session: session,
        candidateHosts: candidateHosts,
      );
    }

    final mdnsResult = await discoverMdns(
      cancellationToken: cancellationToken,
      session: session,
    );
    // 取消或关闭补扫：只返回 mDNS 结果（纯 mDNS 语义不变）。
    if (cancellationToken.isCancelled || !fallbackToSubnetScan) {
      return mdnsResult;
    }

    // 补扫开关开启时始终执行网段扫描，再与 mDNS 结果合并去重，
    // 避免「mDNS 先发现直连机 → 非空短路 → Docker/NAS 被漏」的盲区。
    final scanResult = await scan(
      preferredAddress: preferredAddress,
      effectiveScanPorts: effectiveScanPorts,
      cancellationToken: cancellationToken,
      session: session,
      candidateHosts: candidateHosts,
    );
    return _mergeDiscoveryResults(mdnsResult, scanResult);
  }

  /// 合并 mDNS 与网段补扫结果：同 [ServiceDiscoveryCandidate.address] 去重，
  /// 优先保留 mDNS 候选（元数据更丰富），再按延迟升序排序。
  LocalNetworkServiceDiscoveryResult _mergeDiscoveryResults(
    LocalNetworkServiceDiscoveryResult mdnsResult,
    LocalNetworkServiceDiscoveryResult scanResult,
  ) {
    final candidatesByAddress = <String, ServiceDiscoveryCandidate>{};
    for (final candidate in mdnsResult.candidates) {
      candidatesByAddress.putIfAbsent(candidate.address, () => candidate);
    }
    for (final candidate in scanResult.candidates) {
      candidatesByAddress.putIfAbsent(candidate.address, () => candidate);
    }
    final candidates = candidatesByAddress.values.toList()
      ..sort(
        (a, b) => (a.latencyMs ?? 1 << 30).compareTo(b.latencyMs ?? 1 << 30),
      );

    return LocalNetworkServiceDiscoveryResult(
      candidates: candidates,
      scannedHostCount:
          mdnsResult.scannedHostCount + scanResult.scannedHostCount,
      scannedPortCount:
          mdnsResult.scannedPortCount + scanResult.scannedPortCount,
      scannedEndpointCount:
          mdnsResult.scannedEndpointCount + scanResult.scannedEndpointCount,
      plannedEndpointCount:
          mdnsResult.plannedEndpointCount + scanResult.plannedEndpointCount,
      scannedSubnetCount:
          mdnsResult.scannedSubnetCount + scanResult.scannedSubnetCount,
      requestedMode: serviceDiscoveryModeMdns,
      // 用户选择仍是 mDNS 模式；网段补扫是该模式的内建附加行为。
      effectiveMode: serviceDiscoveryModeMdns,
      fellBackToSubnetScan: true,
      cancelled: mdnsResult.cancelled || scanResult.cancelled,
      timedOut: mdnsResult.timedOut || scanResult.timedOut,
    );
  }

  Future<LocalNetworkServiceDiscoveryResult> discoverMdns({
    DiscoveryCancellationToken? cancellationToken,
    DiscoverySession? session,
  }) async {
    final token = cancellationToken ?? DiscoveryCancellationToken();
    _emitProgress(
      session,
      const DiscoveryProgress(
        stage: DiscoveryProgressStage.mdns,
        plannedEndpoints: 0,
        completedEndpoints: 0,
        candidateCount: 0,
        portCount: 0,
      ),
    );
    final mdns = mdnsFactory();
    session?.attachMdns(mdns);
    final endpoints = await mdns.discover(cancellationToken: token);
    if (token.isCancelled) {
      _emitProgress(
        session,
        const DiscoveryProgress(
          stage: DiscoveryProgressStage.cancelled,
          plannedEndpoints: 0,
          completedEndpoints: 0,
          candidateCount: 0,
          portCount: 0,
        ),
      );
      return const LocalNetworkServiceDiscoveryResult(
        candidates: <ServiceDiscoveryCandidate>[],
        scannedHostCount: 0,
        scannedPortCount: 0,
        scannedEndpointCount: 0,
        plannedEndpointCount: 0,
        scannedSubnetCount: 0,
        cancelled: true,
      );
    }
    final uniqueEndpoints = <String, PicaKeepMdnsEndpoint>{};
    for (final endpoint in endpoints) {
      uniqueEndpoints.putIfAbsent(
        _endpointKey(endpoint.address.address, endpoint.port),
        () => endpoint,
      );
    }
    if (uniqueEndpoints.isEmpty) {
      return const LocalNetworkServiceDiscoveryResult(
        candidates: <ServiceDiscoveryCandidate>[],
        scannedHostCount: 0,
        scannedPortCount: 0,
        scannedEndpointCount: 0,
        plannedEndpointCount: 0,
        scannedSubnetCount: 0,
      );
    }

    final client = probe == null
        ? _createRemoteServiceClient(
            connectionTimeout: const Duration(milliseconds: 900),
            maxConnectionsPerHost: 10,
            forceDirect: true,
          )
        : null;
    if (client != null) {
      session?.attachClient(client);
      unawaited(token.whenCancelled.then((_) => client.close(force: true)));
    }
    final accumulator = _DiscoveryAccumulator();
    try {
      for (final endpoint in uniqueEndpoints.values) {
        if (token.isCancelled) {
          break;
        }
        accumulator.hosts.add(endpoint.address.address);
        accumulator.ports.add(endpoint.port);
        final candidate = await _probeRequest(
          client,
          ServiceDiscoveryProbeRequest(
            host: endpoint.address.address,
            port: endpoint.port,
            sourceMode: serviceDiscoveryModeMdns,
            instanceName: endpoint.instanceName,
            hostName: endpoint.hostName,
            serviceName: endpoint.txt['service'],
            appName: endpoint.txt['app'],
            deviceSystemHint: endpoint.txt['deviceSystem'],
            deviceNameHint: endpoint.txt['deviceName'],
          ),
        );
        accumulator.completedEndpoints += 1;
        var candidateSnapshot = const <ServiceDiscoveryCandidate>[];
        if (candidate != null) {
          final before = accumulator.candidatesByAddress.length;
          accumulator.candidatesByAddress.putIfAbsent(
            candidate.address,
            () => candidate,
          );
          if (accumulator.candidatesByAddress.length > before) {
            candidateSnapshot = accumulator.sortedCandidates;
          }
        }
        _emitProgress(
          session,
          DiscoveryProgress(
            stage: DiscoveryProgressStage.mdns,
            plannedEndpoints: uniqueEndpoints.length,
            completedEndpoints: accumulator.completedEndpoints,
            currentHost: endpoint.address.address,
            candidateCount: accumulator.candidatesByAddress.length,
            portCount: accumulator.ports.length,
            candidates: candidateSnapshot,
          ),
        );
      }
    } finally {
      client?.close(force: true);
    }
    final result = LocalNetworkServiceDiscoveryResult(
      candidates: accumulator.sortedCandidates,
      scannedHostCount: accumulator.hosts.length,
      scannedPortCount: accumulator.ports.length,
      scannedEndpointCount: accumulator.completedEndpoints,
      plannedEndpointCount: uniqueEndpoints.length,
      scannedSubnetCount: 0,
      requestedMode: serviceDiscoveryModeMdns,
      effectiveMode: serviceDiscoveryModeMdns,
    );
    _emitProgress(
      session,
      DiscoveryProgress(
        stage: DiscoveryProgressStage.completed,
        plannedEndpoints: result.plannedEndpointCount,
        completedEndpoints: result.scannedEndpointCount,
        candidateCount: result.candidates.length,
        portCount: result.scannedPortCount,
        candidates: result.candidates,
      ),
    );
    return result;
  }

  Future<LocalNetworkServiceDiscoveryResult> scan({
    String? preferredAddress,
    String? fallbackPort,
    List<int>? effectiveScanPorts,
    DiscoveryCancellationToken? cancellationToken,
    DiscoverySession? session,
    Iterable<String>? candidateHosts,
  }) async {
    final token = cancellationToken ?? DiscoveryCancellationToken();
    final ports = _normalizeEffectivePorts(
      effectiveScanPorts ??
          effectiveServiceScanPorts(
            appdata.settings[serviceScanCustomPortsSettingIndex],
          ),
    );
    final injectedHosts = candidateHosts?.map((host) => host.trim()).where(
          (host) => host.isNotEmpty,
        );
    final rawPrefixes = injectedHosts == null
        ? await (prefixResolver ?? _resolveCandidatePrefixes)(preferredAddress)
        : const <String>[];
    // 无论来自真实网卡枚举还是注入的 prefixResolver，统一按优先级排序再截断。
    final prefixes = injectedHosts == null
        ? await _prioritizeCandidatePrefixes(
            rawPrefixes,
            preferredAddress: preferredAddress,
          )
        : const <String>[];
    final preferredHost =
        tryParseRemoteServerUri(preferredAddress ?? '')?.host ?? '';
    // 复用已保存的远程地址作为 last-success：每轮显式优先探测，覆盖跨段漏网。
    final lastSuccessHost = tryParseRemoteServerUri(
          appdata.settings[remoteServerAddressSettingIndex],
        )?.host ??
        '';
    // 有序：preferred 最先，再 last-success；后续段扫描在 _buildScanTargets 中展开。
    final explicitHosts = <String>[];
    void addExplicit(String host, {bool requirePrivate = false}) {
      if (host.isEmpty ||
          _isLoopbackHost(host) ||
          (requirePrivate && !_isPrivateIpv4(host)) ||
          explicitHosts.contains(host)) {
        return;
      }
      explicitHosts.add(host);
    }

    addExplicit(preferredHost);
    addExplicit(lastSuccessHost, requirePrivate: true);
    final targets = injectedHosts != null
        ? _normalizeHosts(injectedHosts)
        : await _buildScanTargets(prefixes, explicitHosts);
    if (targets.isEmpty || ports.isEmpty) {
      return LocalNetworkServiceDiscoveryResult(
        candidates: const <ServiceDiscoveryCandidate>[],
        scannedHostCount: 0,
        scannedPortCount: ports.length,
        scannedEndpointCount: 0,
        plannedEndpointCount: 0,
        scannedSubnetCount: prefixes.length,
        requestedMode: serviceDiscoveryModeSubnetScan,
        effectiveMode: serviceDiscoveryModeSubnetScan,
        cancelled: token.isCancelled,
      );
    }
    return _scanTargets(
      targets: targets,
      ports: ports,
      scannedSubnetCount: prefixes.length,
      cancellationToken: token,
      session: session,
    );
  }

  Future<LocalNetworkServiceDiscoveryResult> _scanTargets({
    required List<String> targets,
    required List<int> ports,
    required int scannedSubnetCount,
    required DiscoveryCancellationToken cancellationToken,
    required DiscoverySession? session,
  }) async {
    final client = probe == null
        ? _createRemoteServiceClient(
            connectionTimeout: const Duration(milliseconds: 600),
            maxConnectionsPerHost: ports.length,
            forceDirect: true,
          )
        : null;
    if (client != null) {
      session?.attachClient(client);
      unawaited(
        cancellationToken.whenCancelled.then((_) => client.close(force: true)),
      );
    }
    final accumulator = _DiscoveryAccumulator();
    final plannedEndpoints = targets.length * ports.length;
    _emitProgress(
      session,
      DiscoveryProgress(
        stage: DiscoveryProgressStage.subnetScan,
        plannedEndpoints: plannedEndpoints,
        completedEndpoints: 0,
        candidateCount: 0,
        portCount: ports.length,
      ),
    );
    var timedOut = false;

    Future<void> probeEndpoint(String host, int port) async {
      if (cancellationToken.isCancelled) {
        return;
      }
      accumulator.hosts.add(host);
      accumulator.ports.add(port);
      var candidateSnapshot = const <ServiceDiscoveryCandidate>[];
      try {
        final candidate = await _probeRequest(
          client,
          ServiceDiscoveryProbeRequest(
            host: host,
            port: port,
            sourceMode: serviceDiscoveryModeSubnetScan,
          ),
        );
        if (candidate != null) {
          final before = accumulator.candidatesByAddress.length;
          accumulator.candidatesByAddress.putIfAbsent(
            candidate.address,
            () => candidate,
          );
          if (accumulator.candidatesByAddress.length > before) {
            candidateSnapshot = accumulator.sortedCandidates;
          }
        }
      } catch (_) {
        // A failed endpoint must not stop the remaining hosts.
      } finally {
        accumulator.completedEndpoints += 1;
        _emitProgress(
          session,
          DiscoveryProgress(
            stage: DiscoveryProgressStage.subnetScan,
            plannedEndpoints: plannedEndpoints,
            completedEndpoints: accumulator.completedEndpoints,
            currentHost: host,
            candidateCount: accumulator.candidatesByAddress.length,
            portCount: ports.length,
            candidates: candidateSnapshot,
          ),
        );
      }
    }

    Future<void> scanHost(String host) async {
      if (cancellationToken.isCancelled) {
        return;
      }
      final probes = <Future<void>>[
        for (final port in ports) probeEndpoint(host, port),
      ];
      await Future.wait(probes);
    }

    Future<void> runHostWorkers() async {
      var nextHostIndex = 0;
      Future<void> worker() async {
        while (!cancellationToken.isCancelled) {
          if (nextHostIndex >= targets.length) {
            return;
          }
          final host = targets[nextHostIndex++];
          await scanHost(host);
        }
      }

      final workerCount = min(
        hostConcurrencyLimit,
        min(hostConcurrency, targets.length),
      );
      await Future.wait([
        for (var i = 0; i < workerCount; i++) worker(),
      ]);
    }

    final scanFuture = runHostWorkers();
    try {
      await scanFuture.timeout(totalTimeout);
    } on TimeoutException {
      timedOut = true;
      cancellationToken.cancel();
      client?.close(force: true);
      await scanFuture.timeout(
        const Duration(milliseconds: 100),
        onTimeout: () {},
      );
    } finally {
      client?.close(force: true);
    }
    final cancelled = cancellationToken.isCancelled && !timedOut;
    final result = LocalNetworkServiceDiscoveryResult(
      candidates: accumulator.sortedCandidates,
      scannedHostCount: targets.length,
      scannedPortCount: ports.length,
      scannedEndpointCount: accumulator.completedEndpoints,
      plannedEndpointCount: plannedEndpoints,
      scannedSubnetCount: scannedSubnetCount,
      requestedMode: serviceDiscoveryModeSubnetScan,
      effectiveMode: serviceDiscoveryModeSubnetScan,
      cancelled: cancelled,
      timedOut: timedOut,
    );
    _emitProgress(
      session,
      DiscoveryProgress(
        stage: timedOut
            ? DiscoveryProgressStage.timedOut
            : cancelled
                ? DiscoveryProgressStage.cancelled
                : DiscoveryProgressStage.completed,
        plannedEndpoints: result.plannedEndpointCount,
        completedEndpoints: result.scannedEndpointCount,
        candidateCount: result.candidates.length,
        portCount: result.scannedPortCount,
        candidates: result.candidates,
      ),
    );
    return result;
  }

  Future<ServiceDiscoveryCandidate?> _probeRequest(
    HttpClient? client,
    ServiceDiscoveryProbeRequest request,
  ) {
    final customProbe = probe;
    if (customProbe != null) {
      return customProbe(request);
    }
    return _probeHost(client!, request);
  }

  Future<ServiceDiscoveryCandidate?> _probeHost(
    HttpClient client,
    ServiceDiscoveryProbeRequest request,
  ) async {
    final uri = Uri(
      scheme: 'http',
      host: request.host,
      port: request.port,
      path: '/status',
    );
    final stopwatch = Stopwatch()..start();
    try {
      final httpRequest = await client.getUrl(uri).timeout(
            const Duration(milliseconds: 600),
          );
      httpRequest.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await httpRequest.close().timeout(
            const Duration(milliseconds: 900),
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
      final deviceSystem = _cleanDeviceText(
        payload?['deviceSystem']?.toString(),
        fallback: request.deviceSystemHint,
      );
      final deviceName = _cleanDeviceText(
        payload?['deviceName']?.toString(),
        fallback: request.deviceNameHint ?? request.hostName,
      );
      final address = Uri(
        scheme: 'http',
        host: request.host,
        port: request.port,
      ).toString();
      return ServiceDiscoveryCandidate(
        address: address,
        adminUrl: payload?['adminUrl']?.toString().trim().isNotEmpty == true
            ? payload!['adminUrl'].toString().trim()
            : buildServiceAdminUrl(request.host, port: '${request.port}'),
        detailText: (detailText != null && detailText.isNotEmpty)
            ? detailText
            : '发现可用服务',
        sourceMode: request.sourceMode,
        port: request.port,
        comicCount: _tryReadInt(payload?['comicCount']),
        latencyMs: stopwatch.elapsedMilliseconds,
        instanceName: request.instanceName,
        hostName: request.hostName,
        serviceName: request.serviceName,
        appName: request.appName,
        deviceSystem: deviceSystem,
        deviceName: deviceName,
      );
    } catch (_) {
      stopwatch.stop();
      return null;
    }
  }

  void _emitProgress(
    DiscoverySession? session,
    DiscoveryProgress progress,
  ) {
    session?.emit(progress);
  }

  List<int> _normalizeEffectivePorts(Iterable<int> ports) {
    final normalized = <int>[];
    for (final port in ports) {
      if (port >= serviceScanPortMin &&
          port <= serviceScanPortMax &&
          !normalized.contains(port)) {
        normalized.add(port);
        if (normalized.length ==
            serviceScanBuiltInPorts.length + maxServiceScanCustomPorts) {
          break;
        }
      }
    }
    return normalized;
  }

  List<String> _normalizeHosts(Iterable<String> hosts) {
    final normalized = <String>[];
    for (final host in hosts) {
      if (host.isEmpty || normalized.contains(host)) {
        continue;
      }
      normalized.add(host);
    }
    return normalized;
  }

  Future<List<String>> _prioritizeCandidatePrefixes(
    List<String> rawPrefixes, {
    String? preferredAddress,
  }) async {
    final preferredHost =
        tryParseRemoteServerUri(preferredAddress ?? '')?.host ?? '';
    final preferredPrefix = _isPrivateIpv4(preferredHost)
        ? _extractIpv4Prefix(preferredHost)
        : null;

    final localHosts = await (localHostResolver ?? _resolveLocalIpv4Hosts)();
    final localPrefixes = <String>{};
    for (final host in localHosts) {
      final prefix = _extractIpv4Prefix(host);
      if (prefix != null) {
        localPrefixes.add(prefix);
      }
    }

    // 无网卡名时无法判虚拟网卡；仅依赖地址族优先级 + preferred/local。
    final virtualPrefixes = <String>{};
    final unique = <String>{
      for (final prefix in rawPrefixes)
        if (prefix.trim().isNotEmpty) prefix.trim(),
    };
    if (unique.isEmpty) {
      return const <String>[];
    }

    final sorted = unique.toList()
      ..sort(
        (a, b) {
          final rankA = _subnetPrefixPriorityRank(
            a,
            preferredPrefix: preferredPrefix,
            localPrefixes: localPrefixes,
            virtualPrefixes: virtualPrefixes,
          );
          final rankB = _subnetPrefixPriorityRank(
            b,
            preferredPrefix: preferredPrefix,
            localPrefixes: localPrefixes,
            virtualPrefixes: virtualPrefixes,
          );
          final byRank = rankA.compareTo(rankB);
          if (byRank != 0) {
            return byRank;
          }
          return _compareIpv4Prefix(a, b);
        },
      );

    if (sorted.length > 2) {
      return sorted.sublist(0, 2);
    }
    return sorted;
  }

  Future<List<String>> _buildScanTargets(
    List<String> prefixes,
    List<String> explicitHosts,
  ) async {
    if (prefixes.isEmpty && explicitHosts.isEmpty) {
      return const <String>[];
    }
    final localHosts = await (localHostResolver ?? _resolveLocalIpv4Hosts)();
    final removableLocalHosts = Set<String>.from(localHosts)
      ..removeAll(explicitHosts);

    // 按前缀顺序展开（前缀已优先级排序），段内 1..254 数字升序；
    // explicitHosts（preferred / last-success）始终最前。
    final ordered = <String>[];
    final seen = <String>{};
    for (final host in explicitHosts) {
      if (host.isEmpty || !seen.add(host)) {
        continue;
      }
      ordered.add(host);
    }
    for (final prefix in prefixes) {
      for (var i = 1; i <= 254; i++) {
        final host = '$prefix.$i';
        if (removableLocalHosts.contains(host) || !seen.add(host)) {
          continue;
        }
        ordered.add(host);
      }
    }
    return ordered;
  }

  Future<List<String>> _resolveCandidatePrefixes(
      String? preferredAddress) async {
    final preferredHost =
        tryParseRemoteServerUri(preferredAddress ?? '')?.host ?? '';
    final preferredPrefix = _isPrivateIpv4(preferredHost)
        ? _extractIpv4Prefix(preferredHost)
        : null;

    final localHosts = await (localHostResolver ?? _resolveLocalIpv4Hosts)();
    final localPrefixes = <String>{};
    for (final host in localHosts) {
      final prefix = _extractIpv4Prefix(host);
      if (prefix != null) {
        localPrefixes.add(prefix);
      }
    }

    final interfaceEntries = <({String prefix, String interfaceName})>[];
    final seenInterfacePrefix = <String>{};
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final networkInterface in interfaces) {
      for (final address in networkInterface.addresses) {
        final host = address.address;
        if (!_isPrivateIpv4(host)) {
          continue;
        }
        final prefix = _extractIpv4Prefix(host);
        if (prefix == null || !seenInterfacePrefix.add(prefix)) {
          continue;
        }
        interfaceEntries.add((
          prefix: prefix,
          interfaceName: networkInterface.name,
        ));
      }
    }

    final allPrefixes = <String>{
      if (preferredPrefix != null) preferredPrefix,
      ...localPrefixes,
      for (final entry in interfaceEntries) entry.prefix,
    };
    if (allPrefixes.isEmpty) {
      return const <String>[];
    }

    final virtualNames = {
      for (final entry in interfaceEntries)
        if (_looksLikeVirtualNetworkInterface(entry.interfaceName))
          entry.prefix,
    };

    final sorted = allPrefixes.toList()
      ..sort(
        (a, b) {
          final rankA = _subnetPrefixPriorityRank(
            a,
            preferredPrefix: preferredPrefix,
            localPrefixes: localPrefixes,
            virtualPrefixes: virtualNames,
          );
          final rankB = _subnetPrefixPriorityRank(
            b,
            preferredPrefix: preferredPrefix,
            localPrefixes: localPrefixes,
            virtualPrefixes: virtualNames,
          );
          final byRank = rankA.compareTo(rankB);
          if (byRank != 0) {
            return byRank;
          }
          return _compareIpv4Prefix(a, b);
        },
      );

    // 截断前已排序：保留最可能命中的前 2 段（本机/192 优先于 10.x）。
    if (sorted.length > 2) {
      return sorted.sublist(0, 2);
    }
    return sorted;
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

String _localDeviceSystem() {
  return switch (Platform.operatingSystem.toLowerCase()) {
    'android' => 'Android',
    'ios' => 'iOS',
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    _ => Platform.operatingSystem.trim().isEmpty
        ? '未知系统'
        : Platform.operatingSystem,
  };
}

String _localDeviceName() {
  final hostName = Platform.localHostname.trim();
  return hostName.isEmpty ? '当前设备' : hostName;
}

String? _cleanDeviceText(String? value, {String? fallback}) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isNotEmpty) {
    return trimmed;
  }
  final fallbackText = fallback?.trim() ?? '';
  return fallbackText.isEmpty ? null : fallbackText;
}

String _buildDeviceSummary({
  String? deviceSystem,
  String? deviceName,
  String? hostName,
  String? address,
}) {
  final system = _cleanDeviceText(deviceSystem);
  final name = _cleanDeviceText(deviceName);
  if (system != null && name != null) {
    return '$system · $name';
  }
  if (system != null) {
    final host = _cleanDeviceText(hostName);
    return host == null ? system : '$system · $host';
  }
  if (name != null) {
    return name;
  }
  final host = _cleanDeviceText(hostName);
  if (host != null) {
    return host;
  }
  final normalizedAddress = _cleanDeviceText(address);
  return normalizedAddress ?? '未获取到设备信息';
}

String _cleanDiscoveryDisplayName(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) {
    return '';
  }
  final withoutType = trimmed.replaceFirst(
    RegExp(r'\.?_picakeep\._tcp\.local\.?$', caseSensitive: false),
    '',
  );
  final withoutLocal = withoutType.replaceFirst(
    RegExp(r'\.local\.?$', caseSensitive: false),
    '',
  );
  return withoutLocal.replaceAll('\\032', ' ').trim();
}

String _endpointKey(String host, int port) {
  return Uri(scheme: 'http', host: host, port: port).toString();
}

/// 网段扫描前缀优先级：数值越小越优先。
/// preferred / 本机段 > 其他 192.168 > 172.16/12 > 10/8；疑似虚拟网卡再降一级。
int _subnetPrefixPriorityRank(
  String prefix, {
  String? preferredPrefix,
  required Set<String> localPrefixes,
  required Set<String> virtualPrefixes,
}) {
  // 数值越小越优先：
  // preferred → 本机 192.168 → 本机 172 → 本机 10 → 非本机 192.168 → 172 → 10。
  // 同为本机时仍让 192.168 先于 10.x，避免 VPN/虚拟 10 段抢预算。
  var rank = 100;
  final isLocal = localPrefixes.contains(prefix);
  if (preferredPrefix != null && prefix == preferredPrefix) {
    rank = 0;
  } else if (isLocal && prefix.startsWith('192.168.')) {
    rank = 10;
  } else if (isLocal && prefix.startsWith('172.')) {
    rank = 12;
  } else if (isLocal && prefix.startsWith('10.')) {
    rank = 15;
  } else if (prefix.startsWith('192.168.')) {
    rank = 20;
  } else if (prefix.startsWith('172.')) {
    rank = 30;
  } else if (prefix.startsWith('10.')) {
    rank = 40;
  }
  if (virtualPrefixes.contains(prefix) && rank > 0) {
    rank += 50;
  }
  return rank;
}

bool _looksLikeVirtualNetworkInterface(String name) {
  final lower = name.toLowerCase();
  const markers = <String>[
    'vethernet',
    'virtual',
    'vpn',
    'utun',
    'tun',
    'tap',
    'loopback',
    'hyper-v',
    'wsl',
    'docker',
    'veth',
    'br-',
    'vmnet',
    'vbox',
  ];
  for (final marker in markers) {
    if (lower.contains(marker)) {
      return true;
    }
  }
  return false;
}

int _compareIpv4Host(String a, String b) {
  final aParts = _parseIpv4Octets(a);
  final bParts = _parseIpv4Octets(b);
  if (aParts == null && bParts == null) {
    return a.compareTo(b);
  }
  if (aParts == null) {
    return 1;
  }
  if (bParts == null) {
    return -1;
  }
  for (var i = 0; i < 4; i++) {
    final cmp = aParts[i].compareTo(bParts[i]);
    if (cmp != 0) {
      return cmp;
    }
  }
  return 0;
}

int _compareIpv4Prefix(String a, String b) {
  return _compareIpv4Host('$a.0', '$b.0');
}

List<int>? _parseIpv4Octets(String value) {
  final parts = value.split('.');
  if (parts.length != 4) {
    return null;
  }
  final numbers = <int>[];
  for (final part in parts) {
    final number = int.tryParse(part);
    if (number == null || number < 0 || number > 255) {
      return null;
    }
    numbers.add(number);
  }
  return numbers;
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
