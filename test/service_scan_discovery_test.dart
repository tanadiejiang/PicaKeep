import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
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
      expect(maxActiveHosts, lessThanOrEqualTo(12));
      expect(maxActiveProbes, lessThanOrEqualTo(12 * ports.length));
      expect(result.scannedHostCount, hosts.length);
      expect(result.scannedPortCount, ports.length);
      expect(result.scannedEndpointCount, hosts.length * ports.length);
      expect(result.plannedEndpointCount, hosts.length * ports.length);
    });

    test('never exceeds the fixed twelve host worker limit', () async {
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

      expect(maxActiveHosts, lessThanOrEqualTo(12));
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
      expect(startedHosts.length, lessThanOrEqualTo(12));
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

    test('mDNS success probes only the SRV endpoints, not scan ports',
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
        fallbackToSubnetScan: true,
        candidateHosts: const ['192.168.1.20'],
        effectiveScanPorts: const [9527, 8080, 4000],
      );

      expect(probeRequests.map((request) => request.port), [3210]);
      expect(result.effectiveMode, serviceDiscoveryModeMdns);
      expect(result.scannedHostCount, 1);
      expect(result.scannedPortCount, 1);
      expect(result.scannedEndpointCount, 1);
    });

    test('mDNS fallback uses the effective scan port snapshot', () async {
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
      expect(result.effectiveMode, serviceDiscoveryModeSubnetScan);
      expect(result.scannedHostCount, 1);
      expect(result.scannedPortCount, 3);
      expect(result.scannedEndpointCount, 3);
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
