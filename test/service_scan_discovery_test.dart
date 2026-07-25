import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/picakeep_mdns.dart';
import 'package:picakeep/foundation/service_data_source.dart';

void main() {
  group('service scan port contract', () {
    test('uses the two built-in ports before custom ports', () {
      expect(
        effectiveServiceScanPorts('[]'),
        serviceScanBuiltInPorts,
      );
      expect(
        effectiveServiceScanPorts('[3000, 8081]'),
        [9527, 8080, 3000, 8081],
      );
    });

    test('normalizes damaged JSON without changing custom order', () {
      expect(
        decodeServiceScanCustomPorts(
          '[3000, 9527, 3000, 0, -1, 65536, "8081", "bad", 8080, 3001]',
        ),
        [3000, 8081, 3001],
      );
      expect(decodeServiceScanCustomPorts('{"port":3000}'), isEmpty);
      expect(decodeServiceScanCustomPorts('not-json'), isEmpty);
      expect(encodeServiceScanCustomPorts([9527, 3000, 3000, 8080]), '[3000]');
    });

    test('keeps at most eight custom ports', () {
      final ports = List<Object?>.generate(10, (index) => 3000 + index);
      expect(
        normalizeServiceScanCustomPorts(ports),
        ports.take(8).toList(),
      );
      expect(
        validateServiceScanPortInput(
          '3999',
          existing: List<int>.generate(8, (index) => 3000 + index),
        ).code,
        ServiceScanPortValidationCode.quotaExceeded,
      );
    });

    test('reports concrete input errors', () {
      expect(
        validateServiceScanPortInput('').code,
        ServiceScanPortValidationCode.empty,
      );
      expect(
        validateServiceScanPortInput('abc').code,
        ServiceScanPortValidationCode.notAnInteger,
      );
      expect(
        validateServiceScanPortInput('0').code,
        ServiceScanPortValidationCode.outOfRange,
      );
      expect(
        validateServiceScanPortInput('65536').code,
        ServiceScanPortValidationCode.outOfRange,
      );
      expect(
        validateServiceScanPortInput('9527').code,
        ServiceScanPortValidationCode.builtIn,
      );
      expect(
        validateServiceScanPortInput('3000', existing: [3000]).code,
        ServiceScanPortValidationCode.duplicate,
      );
    });
  });

  group('local network service discovery scheduling', () {
    test('probes all ports of a host together and caps host concurrency',
        () async {
      var activeProbes = 0;
      var maxActiveProbes = 0;
      var activeHosts = <String, int>{};
      var maxActiveHosts = 0;
      final startedPortsByHost = <String, Set<int>>{};
      final firstProbeStarted = Completer<void>();

      final discovery = LocalNetworkServiceDiscovery(
        totalTimeout: const Duration(seconds: 2),
        probe: (request) async {
          startedPortsByHost
              .putIfAbsent(request.host, () => <int>{})
              .add(request.port);
          if (request.host == 'host-0' && !firstProbeStarted.isCompleted) {
            firstProbeStarted.complete();
          }
          activeProbes++;
          maxActiveProbes = max(maxActiveProbes, activeProbes);
          activeHosts[request.host] = (activeHosts[request.host] ?? 0) + 1;
          maxActiveHosts = max(maxActiveHosts, activeHosts.length);
          await Future<void>.delayed(const Duration(milliseconds: 4));
          activeProbes--;
          activeHosts[request.host] = activeHosts[request.host]! - 1;
          if (activeHosts[request.host] == 0) {
            activeHosts.remove(request.host);
          }
          return _candidate(request);
        },
      );
      final hosts = List<String>.generate(20, (index) => 'host-$index');
      final ports = List<int>.generate(10, (index) => 3000 + index);

      final resultFuture = discovery.scan(
        candidateHosts: hosts,
        effectiveScanPorts: ports,
      );
      await firstProbeStarted.future;
      await Future<void>.delayed(Duration.zero);

      expect(startedPortsByHost['host-0'], ports.toSet());
      final result = await resultFuture;
      expect(maxActiveHosts, lessThanOrEqualTo(20));
      expect(maxActiveProbes, lessThanOrEqualTo(20 * ports.length));
      expect(result.scannedHostCount, hosts.length);
      expect(result.scannedPortCount, ports.length);
      expect(result.scannedEndpointCount, hosts.length * ports.length);
      expect(result.plannedEndpointCount, hosts.length * ports.length);
    });

    test('never exceeds the fixed twenty host worker limit', () async {
      var activeHosts = 0;
      var maxActiveHosts = 0;
      final discovery = LocalNetworkServiceDiscovery(
        hostConcurrency: 64,
        probe: (request) async {
          activeHosts++;
          maxActiveHosts = max(maxActiveHosts, activeHosts);
          await Future<void>.delayed(const Duration(milliseconds: 2));
          activeHosts--;
          return _candidate(request);
        },
      );

      await discovery.scan(
        candidateHosts: List<String>.generate(32, (index) => 'cap-$index'),
        effectiveScanPorts: const [3000],
      );

      expect(maxActiveHosts, lessThanOrEqualTo(20));
    });

    test('retains two valid services on the same IP at different ports',
        () async {
      final discovery = LocalNetworkServiceDiscovery(
        probe: (request) async => _candidate(request),
      );
      final result = await discovery.scan(
        candidateHosts: const ['192.168.1.20'],
        effectiveScanPorts: const [3000, 3001],
      );

      expect(result.candidates.map((candidate) => candidate.address), [
        'http://192.168.1.20:3000',
        'http://192.168.1.20:3001',
      ]);
    });

    test('cancels without scheduling another host', () async {
      final token = DiscoveryCancellationToken();
      var startedHosts = <String>{};
      final firstProbeStarted = Completer<void>();
      final discovery = LocalNetworkServiceDiscovery(
        probe: (request) async {
          startedHosts.add(request.host);
          if (!firstProbeStarted.isCompleted) {
            firstProbeStarted.complete();
          }
          await Future.any<void>([
            Future<void>.delayed(const Duration(seconds: 5)),
            token.whenCancelled,
          ]);
          return _candidate(request);
        },
      );
      final resultFuture = discovery.scan(
        candidateHosts: List<String>.generate(40, (index) => 'host-$index'),
        effectiveScanPorts: const [3000, 3001],
        cancellationToken: token,
      );
      await firstProbeStarted.future;
      token.cancel();
      final result = await resultFuture;

      expect(result.cancelled, isTrue);
      expect(startedHosts.length, lessThanOrEqualTo(20));
      expect(result.scannedPortCount, 2);
      expect(result.plannedEndpointCount, 80);
    });

    test('reports a total timeout and closes the scheduling round', () async {
      final token = DiscoveryCancellationToken();
      final discovery = LocalNetworkServiceDiscovery(
        totalTimeout: const Duration(milliseconds: 20),
        probe: (request) async {
          await Future.any<void>([
            Future<void>.delayed(const Duration(seconds: 5)),
            token.whenCancelled,
          ]);
          return _candidate(request);
        },
      );

      final result = await discovery.scan(
        candidateHosts: const ['host-0', 'host-1'],
        effectiveScanPorts: const [3000],
        cancellationToken: token,
      );

      expect(result.timedOut, isTrue);
      expect(result.cancelled, isFalse);
      expect(result.plannedEndpointCount, 2);
    });

    test('mDNS with complement scan off probes only the SRV endpoints',
        () async {
      final probeRequests = <ServiceDiscoveryProbeRequest>[];
      final endpoint = PicaKeepMdnsEndpoint(
        instanceName: 'node._picakeep._tcp.local',
        hostName: 'node.local',
        address: InternetAddress('192.168.1.20'),
        port: 3210,
      );
      final discovery = LocalNetworkServiceDiscovery(
        mdnsFactory: () => _FakeMdnsDiscovery([endpoint]),
        probe: (request) async {
          probeRequests.add(request);
          return _candidate(request);
        },
      );

      final result = await discovery.discover(
        mode: serviceDiscoveryModeMdns,
        fallbackToSubnetScan: false,
        candidateHosts: const ['192.168.1.20'],
        effectiveScanPorts: const [9527, 8080, 4000],
      );

      expect(probeRequests.map((request) => request.port), [3210]);
      expect(result.fellBackToSubnetScan, isFalse);
      expect(result.effectiveMode, serviceDiscoveryModeMdns);
      expect(result.scannedHostCount, 1);
      expect(result.scannedPortCount, 1);
      expect(result.scannedEndpointCount, 1);
    });

    test('mDNS empty still complement-scans with the effective port snapshot',
        () async {
      final probeRequests = <ServiceDiscoveryProbeRequest>[];
      final discovery = LocalNetworkServiceDiscovery(
        mdnsFactory: () => _FakeMdnsDiscovery(const []),
        probe: (request) async {
          probeRequests.add(request);
          return _candidate(request);
        },
      );

      final result = await discovery.discover(
        mode: serviceDiscoveryModeMdns,
        fallbackToSubnetScan: true,
        candidateHosts: const ['host-0'],
        effectiveScanPorts: const [9527, 8080, 4000],
      );

      expect(probeRequests.map((request) => request.port), [9527, 8080, 4000]);
      expect(result.fellBackToSubnetScan, isTrue);
      // 用户选择仍是 mDNS；补扫是该模式的内建附加行为。
      expect(result.effectiveMode, serviceDiscoveryModeMdns);
      expect(result.requestedMode, serviceDiscoveryModeMdns);
      expect(result.scannedHostCount, 1);
      expect(result.scannedPortCount, 3);
      expect(result.scannedEndpointCount, 3);
    });

    test('mDNS with hits still complement-scans and merges distinct addresses',
        () async {
      final probeRequests = <ServiceDiscoveryProbeRequest>[];
      final endpoint = PicaKeepMdnsEndpoint(
        instanceName: 'direct._picakeep._tcp.local',
        hostName: 'direct.local',
        address: InternetAddress('192.168.1.20'),
        port: 9527,
      );
      final discovery = LocalNetworkServiceDiscovery(
        mdnsFactory: () => _FakeMdnsDiscovery([endpoint]),
        probe: (request) async {
          probeRequests.add(request);
          // mDNS SRV + 直连机扫描端口 + Docker 机 8080 均视为可用。
          return _candidate(request);
        },
      );

      final result = await discovery.discover(
        mode: serviceDiscoveryModeMdns,
        fallbackToSubnetScan: true,
        candidateHosts: const ['192.168.1.20', '192.168.1.30'],
        effectiveScanPorts: const [9527, 8080],
      );

      final probedKeys = probeRequests
          .map((request) => '${request.host}:${request.port}')
          .toList();
      expect(probedKeys, contains('192.168.1.20:9527'));
      expect(probedKeys, contains('192.168.1.20:8080'));
      expect(probedKeys, contains('192.168.1.30:9527'));
      expect(probedKeys, contains('192.168.1.30:8080'));
      // mDNS 验证 SRV 端口也会探测一次。
      expect(
        probeRequests
            .where(
              (request) =>
                  request.host == '192.168.1.20' &&
                  request.port == 9527 &&
                  request.sourceMode == serviceDiscoveryModeMdns,
            )
            .length,
        1,
      );

      expect(result.fellBackToSubnetScan, isTrue);
      expect(result.effectiveMode, serviceDiscoveryModeMdns);
      // 去重后至少含 mDNS 的 20:9527 与扫描到的 30 上两端口、以及 20:8080。
      final addresses = result.candidates.map((c) => c.address).toSet();
      expect(addresses, contains('http://192.168.1.20:9527'));
      expect(addresses, contains('http://192.168.1.20:8080'));
      expect(addresses, contains('http://192.168.1.30:9527'));
      expect(addresses, contains('http://192.168.1.30:8080'));
      expect(result.candidates.length, 4);
    });

    test('merged candidates prefer mDNS metadata for the same address',
        () async {
      final endpoint = PicaKeepMdnsEndpoint(
        instanceName: 'rich-node._picakeep._tcp.local',
        hostName: 'rich-node.local',
        address: InternetAddress('192.168.1.40'),
        port: 9527,
        txt: const {
          'service': 'PicaKeep',
          'app': 'PicaKeep',
          'deviceName': 'NAS-Direct',
        },
      );
      final discovery = LocalNetworkServiceDiscovery(
        mdnsFactory: () => _FakeMdnsDiscovery([endpoint]),
        probe: (request) async {
          // 两种来源都返回成功；合并时应保留 mDNS 侧元数据。
          return ServiceDiscoveryCandidate(
            address: Uri(
              scheme: 'http',
              host: request.host,
              port: request.port,
            ).toString(),
            adminUrl: 'http://${request.host}:${request.port}/admin-view',
            detailText: request.sourceMode == serviceDiscoveryModeMdns
                ? 'from-mdns'
                : 'from-scan',
            sourceMode: request.sourceMode,
            port: request.port,
            latencyMs: request.sourceMode == serviceDiscoveryModeMdns ? 5 : 1,
            instanceName: request.instanceName,
            hostName: request.hostName,
            serviceName: request.serviceName,
            appName: request.appName,
            deviceName: request.deviceNameHint,
          );
        },
      );

      final result = await discovery.discover(
        mode: serviceDiscoveryModeMdns,
        fallbackToSubnetScan: true,
        candidateHosts: const ['192.168.1.40'],
        effectiveScanPorts: const [9527],
      );

      expect(result.candidates.length, 1);
      final candidate = result.candidates.single;
      expect(candidate.address, 'http://192.168.1.40:9527');
      expect(candidate.sourceMode, serviceDiscoveryModeMdns);
      expect(candidate.detailText, 'from-mdns');
      expect(candidate.instanceName, 'rich-node._picakeep._tcp.local');
      expect(candidate.hostName, 'rich-node.local');
      expect(candidate.deviceName, 'NAS-Direct');
      // 即使扫描延迟更低，同地址仍优先 mDNS 元数据。
      expect(candidate.latencyMs, 5);
    });

    test('complement scan switch off never runs subnet scan', () async {
      final probeRequests = <ServiceDiscoveryProbeRequest>[];
      final discovery = LocalNetworkServiceDiscovery(
        mdnsFactory: () => _FakeMdnsDiscovery(const []),
        probe: (request) async {
          probeRequests.add(request);
          return _candidate(request);
        },
      );

      final result = await discovery.discover(
        mode: serviceDiscoveryModeMdns,
        fallbackToSubnetScan: false,
        candidateHosts: const ['host-0'],
        effectiveScanPorts: const [9527, 8080, 4000],
      );

      expect(probeRequests, isEmpty);
      expect(result.candidates, isEmpty);
      expect(result.fellBackToSubnetScan, isFalse);
      expect(result.effectiveMode, serviceDiscoveryModeMdns);
    });

    test('prefers local 192.168 prefix over 10.x when building scan targets',
        () async {
      final probeHosts = <String>[];
      final discovery = LocalNetworkServiceDiscovery(
        prefixResolver: (_) async => const ['10.8.0', '192.168.5'],
        localHostResolver: () async => {'192.168.5.154', '10.8.0.2'},
        totalTimeout: const Duration(seconds: 2),
        probe: (request) async {
          probeHosts.add(request.host);
          // 只让 192.168.5 段里的 NAS 命中，验证它会被优先扫到。
          if (request.host == '192.168.5.50' && request.port == 8080) {
            return _candidate(request);
          }
          return null;
        },
      );

      final result = await discovery.scan(
        preferredAddress: 'http://192.168.5.154:8080',
        effectiveScanPorts: const [8080],
      );

      // preferred 本机段 192.168.5 应整体排在 10.8.0 之前（除 explicit）。
      final firstTen = probeHosts.indexWhere((h) => h.startsWith('10.8.0.'));
      final first192 = probeHosts.indexWhere((h) => h.startsWith('192.168.5.'));
      expect(first192, greaterThanOrEqualTo(0));
      expect(firstTen, greaterThanOrEqualTo(0));
      expect(first192, lessThan(firstTen));
      expect(result.candidates.map((c) => c.address),
          contains('http://192.168.5.50:8080'));
    });

    test('orders hosts by numeric IPv4 within a prefix', () async {
      final probeHosts = <String>[];
      final discovery = LocalNetworkServiceDiscovery(
        prefixResolver: (_) async => const ['192.168.5'],
        localHostResolver: () async => const <String>{},
        totalTimeout: const Duration(seconds: 3),
        probe: (request) async {
          probeHosts.add(request.host);
          return null;
        },
      );

      await discovery.scan(
        effectiveScanPorts: const [9527],
      );

      // 取段内前几个主机：.1 < .2 < ... < .10（数字序而非字符串 "10" 在 "2" 前）。
      final sample = probeHosts.take(12).toList();
      expect(sample, containsAllInOrder([
        '192.168.5.1',
        '192.168.5.2',
        '192.168.5.3',
      ]));
      final index2 = sample.indexOf('192.168.5.2');
      final index10 = probeHosts.indexOf('192.168.5.10');
      expect(index2, greaterThanOrEqualTo(0));
      expect(index10, greaterThan(index2));
    });

    test('hits same-subnet service before budget is spent on lower-priority 10.x',
        () async {
      final probeHosts = <String>[];
      final discovery = LocalNetworkServiceDiscovery(
        // 模拟错误枚举顺序：10.x 先返回，但本机在 192.168.5。
        prefixResolver: (_) async => const ['10.8.0', '192.168.5'],
        localHostResolver: () async => {'192.168.5.154'},
        hostConcurrency: 20,
        totalTimeout: const Duration(seconds: 8),
        probe: (request) async {
          probeHosts.add(request.host);
          await Future<void>.delayed(const Duration(milliseconds: 1));
          if (request.host == '192.168.5.80' && request.port == 8080) {
            return _candidate(request);
          }
          return null;
        },
      );

      final result = await discovery.scan(
        preferredAddress: 'http://192.168.5.154',
        effectiveScanPorts: const [8080],
      );

      expect(
        result.candidates.map((c) => c.address),
        contains('http://192.168.5.80:8080'),
      );
      // 命中时不应把整段 10.x 先扫完。
      final hitIndex = probeHosts.indexOf('192.168.5.80');
      final tenCountBeforeHit =
          probeHosts.take(hitIndex + 1).where((h) => h.startsWith('10.')).length;
      expect(hitIndex, greaterThanOrEqualTo(0));
      expect(tenCountBeforeHit, 0);
    });

    test('puts preferred and last-success hosts at the front of the scan queue',
        () async {
      final probeHosts = <String>[];
      // 写入 last-success 地址到 settings（index 98）。
      final settings = appdata.settings;
      final previous = settings[remoteServerAddressSettingIndex];
      settings[remoteServerAddressSettingIndex] = 'http://192.168.5.200:8080';
      addTearDown(() {
        settings[remoteServerAddressSettingIndex] = previous;
      });

      final discovery = LocalNetworkServiceDiscovery(
        prefixResolver: (_) async => const ['192.168.5'],
        localHostResolver: () async => const <String>{},
        probe: (request) async {
          probeHosts.add(request.host);
          return null;
        },
      );

      await discovery.scan(
        preferredAddress: 'http://192.168.5.10:8080',
        effectiveScanPorts: const [8080],
      );

      expect(probeHosts.first, '192.168.5.10');
      expect(probeHosts[1], '192.168.5.200');
    });
    test('mDNS stop interrupts the socket wait and is idempotent', () async {
      final token = DiscoveryCancellationToken();
      final mdns = PicaKeepMdnsDiscovery();
      final resultFuture = mdns.discover(
        timeout: const Duration(seconds: 30),
        cancellationToken: token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel();

      expect(
        await resultFuture.timeout(const Duration(seconds: 2)),
        isEmpty,
      );
      await mdns.stop();
      await mdns.stop();
      expect(mdns.isRunning, isFalse);
    });

    test('progress events include candidate snapshots when a host is found',
        () async {
      final discovery = LocalNetworkServiceDiscovery(
        probe: (request) async {
          if (request.host == 'host-hit') {
            return _candidate(request);
          }
          return null;
        },
      );
      final session = discovery.createSession(
        mode: serviceDiscoveryModeSubnetScan,
        generation: 7,
        candidateHosts: const ['host-miss', 'host-hit'],
        effectiveScanPorts: const [3000],
      );
      final progress = <DiscoveryProgress>[];
      final subscription = session.progress.listen(progress.add);
      final result = await session.result;
      await subscription.cancel();

      expect(result.candidates, hasLength(1));
      final withCandidates =
          progress.where((event) => event.candidates.isNotEmpty).toList();
      expect(withCandidates, isNotEmpty);
      expect(
        withCandidates.last.candidates.single.address,
        'http://host-hit:3000',
      );
      expect(withCandidates.last.candidateCount, 1);
    });

    test('session keeps generation and emits progress for one snapshot',
        () async {
      final discovery = LocalNetworkServiceDiscovery(
        probe: (request) async => _candidate(request),
      );
      final session = discovery.createSession(
        mode: serviceDiscoveryModeSubnetScan,
        generation: 42,
        candidateHosts: const ['host-0'],
        effectiveScanPorts: const [3000, 3001],
      );
      final progress = <DiscoveryProgress>[];
      final subscription = session.progress.listen(progress.add);
      final result = await session.result;
      await subscription.cancel();

      expect(session.generation, 42);
      expect(result.scannedEndpointCount, 2);
      expect(
        progress.map((event) => event.stage),
        containsAllInOrder([
          DiscoveryProgressStage.subnetScan,
          DiscoveryProgressStage.completed,
        ]),
      );
    });
  });
}

ServiceDiscoveryCandidate _candidate(ServiceDiscoveryProbeRequest request) {
  return ServiceDiscoveryCandidate(
    address: Uri(
      scheme: 'http',
      host: request.host,
      port: request.port,
    ).toString(),
    adminUrl: 'http://${request.host}:${request.port}/admin-view',
    detailText: 'test',
    sourceMode: request.sourceMode,
    port: request.port,
    latencyMs: 1,
  );
}

class _FakeMdnsDiscovery extends PicaKeepMdnsDiscovery {
  _FakeMdnsDiscovery(this._endpoints);

  final List<PicaKeepMdnsEndpoint> _endpoints;

  @override
  Future<List<PicaKeepMdnsEndpoint>> discover({
    Duration timeout = const Duration(seconds: 3),
    DiscoveryCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancelled == true) {
      return const <PicaKeepMdnsEndpoint>[];
    }
    return _endpoints;
  }
}
