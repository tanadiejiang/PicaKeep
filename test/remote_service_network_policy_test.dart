import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/network/remote_service_network_policy.dart';

void main() {
  group('classifyRemoteServiceHost', () {
    test('classifies IPv4 boundaries', () {
      expect(
        classifyRemoteServiceHost('127.0.0.1'),
        RemoteServiceHostKind.loopback,
      );
      expect(
        classifyRemoteServiceHost('127.255.255.255'),
        RemoteServiceHostKind.loopback,
      );
      expect(
        classifyRemoteServiceHost('10.0.0.0'),
        RemoteServiceHostKind.lan,
      );
      expect(
        classifyRemoteServiceHost('172.16.0.0'),
        RemoteServiceHostKind.lan,
      );
      expect(
        classifyRemoteServiceHost('172.31.255.255'),
        RemoteServiceHostKind.lan,
      );
      expect(
        classifyRemoteServiceHost('192.168.255.255'),
        RemoteServiceHostKind.lan,
      );
      expect(
        classifyRemoteServiceHost('169.254.0.0'),
        RemoteServiceHostKind.linkLocal,
      );
      expect(
        classifyRemoteServiceHost('169.254.255.255'),
        RemoteServiceHostKind.linkLocal,
      );

      expect(
        classifyRemoteServiceHost('126.255.255.255'),
        RemoteServiceHostKind.publicIp,
      );
      expect(
        classifyRemoteServiceHost('172.15.255.255'),
        RemoteServiceHostKind.publicIp,
      );
      expect(
        classifyRemoteServiceHost('172.32.0.0'),
        RemoteServiceHostKind.publicIp,
      );
      expect(
        classifyRemoteServiceHost('192.167.255.255'),
        RemoteServiceHostKind.publicIp,
      );
    });

    test('classifies IPv6, mapped IPv4, and names', () {
      expect(
        classifyRemoteServiceHost('::1'),
        RemoteServiceHostKind.loopback,
      );
      expect(
        classifyRemoteServiceHost('fe80::1'),
        RemoteServiceHostKind.linkLocal,
      );
      expect(
        classifyRemoteServiceHost('fc00::1'),
        RemoteServiceHostKind.lan,
      );
      expect(
        classifyRemoteServiceHost('2001:db8::1'),
        RemoteServiceHostKind.ipv6,
      );
      expect(
        classifyRemoteServiceHost('::ffff:192.168.1.10'),
        RemoteServiceHostKind.lan,
      );
      expect(
        classifyRemoteServiceHost('localhost'),
        RemoteServiceHostKind.loopback,
      );
      expect(
        classifyRemoteServiceHost('nas.local'),
        RemoteServiceHostKind.loopback,
      );
      expect(
        classifyRemoteServiceHost('nas'),
        RemoteServiceHostKind.loopback,
      );
      expect(
        classifyRemoteServiceHost('api.example.com.'),
        RemoteServiceHostKind.hostname,
      );
      expect(
        classifyRemoteServiceHost('not a host'),
        RemoteServiceHostKind.invalid,
      );
      expect(
        classifyRemoteServiceHost('999.1.1.1'),
        RemoteServiceHostKind.invalid,
      );
    });
  });

  group('RemoteServiceNetworkPolicy', () {
    test('manual proxy has priority over environment proxy', () {
      final policy = RemoteServiceNetworkPolicy(
        manualProxy: 'manual.example:8080',
        environment: const {
          'HTTP_PROXY': 'http://environment.example:3128',
        },
      );

      final decision = policy.resolveProxy(
        Uri.parse('http://public.example/resource'),
      );
      expect(decision.source, RemoteServiceProxySource.manualProxy);
      expect(decision.findProxyRule, 'PROXY manual.example:8080');
    });

    test('environment proxy is selected when manual proxy is absent', () {
      final policy = RemoteServiceNetworkPolicy(
        environment: const {
          'HTTPS_PROXY': 'https://secure-proxy.example:8443',
          'HTTP_PROXY': 'http://http-proxy.example:3128',
        },
      );

      final https = policy.resolveProxy(Uri.parse('https://public.example'));
      final http = policy.resolveProxy(Uri.parse('http://public.example'));
      expect(https.source, RemoteServiceProxySource.environment);
      expect(https.findProxyRule, 'PROXY secure-proxy.example:8443');
      expect(http.findProxyRule, 'PROXY http-proxy.example:3128');
    });

    test('invalid or absent proxies fall back to direct', () {
      final policy = RemoteServiceNetworkPolicy(
        manualProxy: 'not-a-proxy',
        environment: const {'HTTP_PROXY': 'http://bad proxy:8080'},
      );

      final decision = policy.resolveProxy(Uri.parse('http://public.example'));
      expect(decision.source, RemoteServiceProxySource.directFallback);
      expect(decision.findProxyRule, 'DIRECT');
    });

    test('local targets bypass configured proxies', () {
      final policy = RemoteServiceNetworkPolicy(
        manualProxy: 'manual.example:8080',
        environment: const {'HTTP_PROXY': 'http://environment.example:3128'},
      );

      for (final uri in [
        Uri.parse('http://127.0.0.1:9000/status'),
        Uri.parse('http://192.168.1.20:9000/status'),
        Uri.parse('http://[fe80::1]:9000/status'),
      ]) {
        final decision = policy.resolveProxy(uri);
        expect(decision.source, RemoteServiceProxySource.directFallback);
        expect(decision.findProxyRule, 'DIRECT');
      }
    });

    test('NO_PROXY bypasses environment proxy for matching names and CIDR', () {
      final policy = RemoteServiceNetworkPolicy(
        environment: const {
          'HTTP_PROXY': 'proxy.example:3128',
          'NO_PROXY': '.internal.example,10.20.0.0/16,localhost:80',
        },
      );

      expect(
        policy.findProxy(Uri.parse('http://api.internal.example/items')),
        'DIRECT',
      );
      expect(
        policy.findProxy(Uri.parse('http://10.20.10.4/items')),
        'DIRECT',
      );
      expect(
        policy.findProxy(Uri.parse('http://localhost:80/items')),
        'DIRECT',
      );
      expect(
        policy.findProxy(Uri.parse('http://public.example/items')),
        'PROXY proxy.example:3128',
      );
    });

    test('configures an HttpClient findProxy callback', () async {
      final proxyServer =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxyRequests = <String>[];
      final subscription = proxyServer.listen((request) async {
        proxyRequests.add('${request.method} ${request.uri}');
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });
      addTearDown(() async {
        await subscription.cancel();
        await proxyServer.close(force: true);
      });

      final proxyAddress = '${proxyServer.address.host}:${proxyServer.port}';
      final policy = RemoteServiceNetworkPolicy(
        manualProxy: proxyAddress,
        environment: const <String, String>{},
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      expect(policy.configureHttpClient(client), same(client));
      final callbackObserved = <RemoteServiceProxyDecision>[];
      final callbackClient = RemoteServiceNetworkPolicy.createClient(
        manualProxy: proxyAddress,
        environment: const <String, String>{},
        onDecision: (decision, uri) {
          callbackObserved.add(decision);
          expect(uri.host, 'public.example');
        },
      );
      addTearDown(() => callbackClient.close(force: true));

      final requestUri = Uri.parse('http://public.example');
      final configuredResponse =
          await client.getUrl(requestUri).then((request) => request.close());
      expect(configuredResponse.statusCode, HttpStatus.noContent);
      final response = await callbackClient
          .getUrl(requestUri)
          .then((request) => request.close());
      expect(response.statusCode, HttpStatus.noContent);
      expect(proxyRequests, hasLength(2));
      expect(
          callbackObserved.single.route, RemoteServiceProxySource.manualProxy);
    });

    test('forceDirect disables both manual and environment proxies', () {
      final policy = RemoteServiceNetworkPolicy(
        manualProxy: 'manual.example:8080',
        environment: const {'HTTP_PROXY': 'environment.example:3128'},
        forceDirect: true,
      );

      final decision = policy.resolveProxy(Uri.parse('http://public.example'));
      expect(decision.route, RemoteServiceProxySource.directFallback);
      expect(decision.findProxyRule, 'DIRECT');
    });

    test('policy logs only non-sensitive route metadata', () {
      final messages = <String>[];
      final policy = RemoteServiceNetworkPolicy(
        manualProxy: 'user:secret@proxy.example:8080',
        environment: const {
          'HTTP_PROXY': 'http://environment.example:3128',
        },
        logger: messages.add,
      );

      final decision = policy.resolveProxy(
        Uri.parse('http://account:password@secret.example/path?token=secret'),
      );
      expect(decision.source, RemoteServiceProxySource.environment);
      expect(
          messages.single, 'hostKind=hostname source=environment route=proxy');
      expect(messages.single, isNot(contains('secret')));
      expect(messages.single, isNot(contains('password')));
      expect(decision.toString(), isNot(contains('environment.example')));
    });
  });
}
