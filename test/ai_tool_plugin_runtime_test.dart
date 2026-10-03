import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_tool_plugin_runtime.dart';
import 'package:picakeep/foundation/ai/ai_tool_plugin_store.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handle);
  final Future<ResponseBody> Function(RequestOptions) handle;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      handle(options);
  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _manifest(
        {String version = '1', String path = '/search'}) =>
    {
      'schemaVersion': 1,
      'id': 'catalog',
      'name': '公开目录',
      'version': version,
      'kind': 'http_json',
      'endpoint': 'https://example.com$path',
      'description': '查询公开目录',
      'parameters': {'keyword': '关键词'},
      'query': {'q': 'title:{keyword}', 'limit': '10'},
      'resultPath': 'items',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AiPluginHttpClient client(
      Future<ResponseBody> Function(RequestOptions) handle,
      {List<String> addresses = const ['93.184.216.34']}) {
    final dio = Dio()..httpClientAdapter = _Adapter(handle);
    addTearDown(() => dio.close(force: true));
    return AiPluginHttpClient(
        dio: dio,
        resolveHost: (_) async => addresses.map(InternetAddress.new).toList());
  }

  group('isolated public HTTP client', () {
    test('GET has no inherited credentials and disables redirects', () async {
      final http = client((request) async {
        expect(request.method, 'GET');
        expect(request.followRedirects, isFalse);
        expect(request.headers.keys.map((e) => e.toLowerCase()),
            isNot(contains('authorization')));
        expect(request.headers.keys.map((e) => e.toLowerCase()),
            isNot(contains('cookie')));
        expect(request.data, isNull);
        return ResponseBody.fromString('{"ok":true}', 200);
      });
      expect(await http.get(Uri.parse('https://example.com/search')),
          '{"ok":true}');
    });

    test('rejects private DNS answers before dispatching any HTTP request',
        () async {
      var calls = 0;
      for (final addresses in <List<String>>[
        [],
        ['127.0.0.1'],
        ['10.1.2.3'],
        ['172.16.0.1'],
        ['192.168.1.1'],
        ['169.254.169.254'],
        ['100.64.0.1'],
        ['::1'],
        ['fd12::1'],
        ['::ffff:192.168.1.1'],
        ['93.184.216.34', '127.0.0.1'],
      ]) {
        final http = client((_) async {
          calls++;
          return ResponseBody.fromString('{}', 200);
        }, addresses: addresses);
        await expectLater(http.get(Uri.parse('https://example.com/search')),
            throwsFormatException,
            reason: addresses.toString());
      }
      expect(calls, 0);
    });

    test('redirect is rejected without making a second request', () async {
      var calls = 0;
      final http = client((request) async {
        calls++;
        expect(request.followRedirects, isFalse);
        return ResponseBody.fromString('', 302, headers: {
          'location': ['https://other.example.com/moved']
        });
      });
      await expectLater(http.get(Uri.parse('https://example.com/search')),
          throwsA(isA<DioException>()));
      expect(calls, 1);
    });

    test('enforces response size for both declared and streamed lengths',
        () async {
      final declared =
          client((_) async => ResponseBody.fromString('{}', 200, headers: {
                'content-length': ['${2 * 1024 * 1024 + 1}']
              }));
      await expectLater(declared.get(Uri.parse('https://example.com/search')),
          throwsFormatException);
      final chunked = client((_) async =>
          ResponseBody(Stream.value(Uint8List(2 * 1024 * 1024 + 1)), 200));
      await expectLater(chunked.get(Uri.parse('https://example.com/search')),
          throwsFormatException);
    });
  });

  group('tool execution and maintenance', () {
    late Directory directory;
    late AiToolPluginStore store;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('picakeep-runtime57-');
      store = AiToolPluginStore.atFile(File('${directory.path}/plugins.json'));
      await store.importManifest(jsonEncode(_manifest()));
    });
    tearDown(() async {
      store.dispose();
      await directory.delete(recursive: true);
    });

    test('query is encoded as data, response follows configured JSON path',
        () async {
      final tool = AiHttpJsonPluginTool(store.record('catalog')!.plugin,
          store: store, client: client((request) async {
        expect(request.uri.host, 'example.com');
        expect(request.uri.queryParameters,
            {'q': 'title:猫 & red/blue?', 'limit': '10'});
        return ResponseBody.fromString(
            jsonEncode({
              'items': [
                {'title': 'Result'}
              ],
              'private': 'ignored'
            }),
            200);
      }));
      final result = await tool.execute({'keyword': '猫 & red/blue?'});
      expect(result.ok, isTrue);
      expect(result.data, {
        'plugin_id': 'catalog',
        'result': [
          {'title': 'Result'}
        ],
      });
      expect((await tool.execute({'keyword': 1})).ok, isFalse);
      expect((await tool.execute({})).ok, isFalse);
    });

    test(
        'existing tool instance reads new adapter and disabled state next call',
        () async {
      final paths = <String>[];
      final tool = AiHttpJsonPluginTool(store.record('catalog')!.plugin,
          store: store, client: client((request) async {
        paths.add(request.uri.path);
        return ResponseBody.fromString('{"items":[]}', 200);
      }));
      expect((await tool.execute({'keyword': 'one'})).ok, isTrue);
      await store
          .importManifest(jsonEncode(_manifest(version: '2', path: '/v2')));
      expect((await tool.execute({'keyword': 'two'})).ok, isTrue);
      await store.setEnabled('catalog', false);
      expect((await tool.execute({'keyword': 'three'})).ok, isFalse);
      expect(paths, ['/search', '/v2']);
    });

    test('missing response path fails visibly rather than pretending empty',
        () async {
      final tool = AiHttpJsonPluginTool(store.record('catalog')!.plugin,
          store: store,
          client: client((_) async => ResponseBody.fromString('{}', 200)));
      final result = await tool.execute({'keyword': 'one'});
      expect(result.ok, isFalse);
      expect(result.message, contains('缺少'));
    });

    test('resolver and timeout errors become tool failures', () async {
      for (final error in [
        const SocketException('DNS failure'),
        TimeoutException('DNS timed out'),
      ]) {
        final tool = AiHttpJsonPluginTool(store.record('catalog')!.plugin,
            store: store,
            client: AiPluginHttpClient(resolveHost: (_) async => throw error));
        final result = await tool.execute({'keyword': 'one'});
        expect(result.ok, isFalse);
      }
    });

    test('maintenance rejects updates while disabled and validates manifest ID',
        () async {
      final tool = AiManageToolPluginTool(store: store);
      final args = {
        'action': 'update',
        'plugin_id': 'catalog',
        'manifest': jsonEncode(_manifest(version: '2')),
      };
      expect((await tool.execute(args)).ok, isFalse);
      expect(store.record('catalog')!.plugin.version, '1');
      await store.setMaintenanceEnabled(true);
      expect((await tool.execute({...args, 'plugin_id': 'other'})).ok, isFalse);
      expect((await tool.execute(args)).ok, isTrue);
      expect(store.record('catalog')!.plugin.version, '2');
      expect(
          (await tool.execute({'action': 'rollback', 'plugin_id': 'catalog'}))
              .ok,
          isTrue);
      expect(store.record('catalog')!.plugin.version, '1');
    });

    test('diagnosis enforces same-origin public path and redacts evidence',
        () async {
      final visited = <Uri>[];
      final http = client((request) async {
        visited.add(request.uri);
        return ResponseBody.fromString(
            '<script>{"token":"secret-token","password":"secret-pass"}</script>',
            200);
      });
      for (final path in [
        '//evil.example/api',
        'https://evil.example/api',
        '/api?token=secret',
        '/api#secret',
      ]) {
        await expectLater(
            diagnoseAiToolPlugin('catalog',
                store: store, client: http, path: path),
            throwsFormatException);
      }
      expect(visited, isEmpty);
      final evidence = await diagnoseAiToolPlugin('catalog',
          store: store, client: http, path: '/public');
      expect(evidence['http_ok'], isTrue);
      expect(visited.single.path, '/public');
      expect(evidence['evidence'], isNot(contains('secret-token')));
      expect(evidence['evidence'], isNot(contains('secret-pass')));
      expect(evidence['evidence'], contains('"token":'));
      expect(evidence['evidence'], contains('"password":'));
      expect(evidence['note'], contains('不可信'));
    });

    test('diagnosis shows HTTP failure and truncates oversized public evidence',
        () async {
      final failed = await diagnoseAiToolPlugin('catalog',
          store: store,
          client: client((_) async => ResponseBody.fromString('blocked', 403)));
      expect(failed['http_ok'], isFalse);
      expect(failed['status'], 403);
      final long = await diagnoseAiToolPlugin('catalog',
          store: store,
          client:
              client((_) async => ResponseBody.fromString('x' * 25000, 200)));
      expect((long['evidence'] as String).length, 24000);
      expect(long['truncated'], isTrue);
    });
  });
}
