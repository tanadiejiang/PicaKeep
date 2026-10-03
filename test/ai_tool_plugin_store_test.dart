import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_tool_plugin_store.dart';

Map<String, dynamic> _manifest({
  String id = 'catalog',
  String version = '1',
  String endpoint = 'https://example.com/search',
}) =>
    {
      'schemaVersion': 1,
      'id': id,
      'name': '目录查询',
      'version': version,
      'kind': 'http_json',
      'endpoint': endpoint,
      'description': '按关键词查询公开目录',
      'parameters': {'keyword': '关键词'},
      'query': {'q': '{keyword}'},
      'resultPath': 'results.items',
    };

Map<String, dynamic> _fullManifest(Map<String, dynamic> manifest) {
  final result = {...manifest, 'notes': ''};
  result['notes'] = 'x' * (65536 - utf8.encode(jsonEncode(result)).length);
  expect(utf8.encode(jsonEncode(result)), hasLength(65536));
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('manifest contract', () {
    test('built-in adapter and public JSON query round-trip', () {
      final builtin = builtinImageSearchPlugin();
      expect(builtin.id, builtinImagePluginId);
      expect(builtin.toolName, 'search_by_image');
      expect(
          AiToolPlugin.fromJson(builtin.toJson()).toJson(), builtin.toJson());
      final query = AiToolPlugin.fromJson(_manifest());
      expect(query.toolName, 'plugin_catalog');
      expect(
          readPluginJsonPath({
            'results': {
              'items': [1, 2]
            }
          }, query.json['resultPath']),
          [1, 2]);
      expect(
          readPluginJsonPath({
            'items': [1, 2]
          }, 'items.0'),
          isNull);
      expect(readPluginJsonPath({'a': null}, 'a.b'), isNull);
    });

    test('rejects unsupported format, executable type, invalid IDs and paths',
        () {
      for (final patch in <Map<String, dynamic>>[
        {'schemaVersion': 2},
        {'kind': 'javascript'},
        {'id': '../escape'},
        {'id': 'Uppercase'},
        {'id': builtinImagePluginId},
        {'resultPath': 'results[0]'},
        {'resultPath': 'results..items'},
        {'resultPath': '../file'},
        {
          'query': {'q': '{undefinedParameter}'}
        },
        {
          'parameters': {'bad/name': 'invalid'}
        },
      ]) {
        expect(() => AiToolPlugin.fromJson({..._manifest(), ...patch}),
            throwsFormatException,
            reason: patch.toString());
      }
    });

    test(
        'rejects local targets, credentials, query, fragments and spoofed host',
        () {
      for (final endpoint in [
        'http://example.com/api',
        'https://localhost/api',
        'https://192.168.1.1/api',
        'https://[::1]/api',
        'https://device.local/api',
        'https://server.internal/api',
        'https://device.local./api',
        'https://user:password@example.com/api',
        'https://example.com/api?token=secret',
        'https://example.com/api#token',
        'https://foo..example.com/api',
      ]) {
        expect(() => AiToolPlugin.fromJson(_manifest(endpoint: endpoint)),
            throwsFormatException,
            reason: endpoint);
      }
      final builtin = builtinImageSearchPlugin().toJson();
      for (final endpoint in [
        'https://soutubot.moe.example.com/api/search',
        'https://example.com/api/search',
        'https://soutubot.moe:8443/api/search',
      ]) {
        expect(() => AiToolPlugin.fromJson({...builtin, 'endpoint': endpoint}),
            throwsFormatException);
      }
    });

    test('64KB is measured in UTF-8 bytes, including direct model construction',
        () {
      final oversized = {..._manifest(), 'notes': '文' * 23000};
      expect(jsonEncode(oversized).length, lessThan(65536));
      expect(utf8.encode(jsonEncode(oversized)).length, greaterThan(65536));
      expect(() => AiToolPlugin.fromJson(oversized), throwsFormatException);
      expect(() => AiToolPlugin.fromJson(_fullManifest(_manifest())),
          returnsNormally);
    });

    test(
        'validated nested data cannot be mutated through input, json or adapter',
        () {
      final original = builtinImageSearchPlugin().toJson();
      final plugin = AiToolPlugin.fromJson(original);
      final response = plugin.json['response'] as Map;
      (original['response'] as Map)['resultsPath'] = 'changed';
      expect(response['resultsPath'], 'results');
      expect(() => response['resultsPath'] = '../file', throwsUnsupportedError);
      expect(
          () => ((response['fieldPaths'] as Map)['title'] as List).add('bad'),
          throwsUnsupportedError);
      final adapter = plugin.adapter;
      expect(() => (adapter['fields'] as Map)['factor'] = 'bad',
          throwsUnsupportedError);
      final exported = plugin.toJson();
      (exported['fields'] as Map)['factor'] = 'changed';
      expect((plugin.json['fields'] as Map)['factor'], '1.2');
    });
  });

  group('persistent store', () {
    late Directory directory;
    late File file;
    late AiToolPluginStore store;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('picakeep-plugin57-');
      file = File('${directory.path}/plugins.json');
      store = AiToolPluginStore.atFile(file);
    });
    tearDown(() async {
      store.dispose();
      await directory.delete(recursive: true);
    });

    test(
        'imports atomically, rejects invalid replacement, and exports reimport',
        () async {
      await store.importManifest(jsonEncode(_manifest()));
      final before = await file.readAsString();
      await expectLater(
          store.importManifest('{invalid'), throwsFormatException);
      await expectLater(
          store
              .importManifest(jsonEncode(_manifest(endpoint: 'file:///tmp/x'))),
          throwsFormatException);
      expect(await file.readAsString(), before);
      expect(store.record('catalog')!.plugin.version, '1');
      await store.importManifest(store.exportManifest('catalog'));
      expect(store.record('catalog')!.previous, isNull);
      expect(await File('${file.path}.tmp').exists(), isFalse);
    });

    test('export of maximum-size manifest remains importable', () async {
      await store.importManifest(jsonEncode(_fullManifest(_manifest())));
      final exported = store.exportManifest('catalog');
      expect(utf8.encode(exported).length, lessThanOrEqualTo(65536));
      await store.importManifest(exported);
      expect(store.record('catalog')!.previous, isNull);
    });

    test('failed disk write preserves both current file and in-memory record',
        () async {
      await store.importManifest(jsonEncode(_manifest()));
      final before = await file.readAsBytes();
      final blockedTemporary = await Directory('${file.path}.tmp').create();
      await expectLater(
          store.importManifest(jsonEncode(_manifest(version: '2'))),
          throwsA(isA<FileSystemException>()));
      expect(await file.readAsBytes(), before);
      expect(store.record('catalog')!.plugin.version, '1');
      await blockedTemporary.delete();
      await store.importManifest(jsonEncode(_manifest(version: '2')));
      expect(store.record('catalog')!.plugin.version, '2');
    });

    test('disabled status, maintenance and rollback survive reopening',
        () async {
      await store.importManifest(jsonEncode(_manifest()));
      await store.setEnabled('catalog', false);
      await store.setMaintenanceEnabled(true);
      await store.importManifest(jsonEncode(_manifest(version: '2')),
          fromAi: true);
      final reopened = AiToolPluginStore.atFile(file);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.maintenanceEnabled, isTrue);
      expect(reopened.enabled('catalog'), isFalse);
      expect(reopened.record('catalog')!.plugin.version, '2');
      expect(reopened.record('catalog')!.previous!.version, '1');
      await reopened.rollback('catalog', fromAi: true);
      expect(reopened.record('catalog')!.plugin.version, '1');
      expect(reopened.enabled('catalog'), isFalse);
      await reopened.rollback('catalog');
      expect(reopened.record('catalog')!.plugin.version, '2');
    });

    test(
        'builtin restore re-enables adapter and preserves the custom predecessor',
        () async {
      await store.importManifest(jsonEncode({
        ...builtinImageSearchPlugin().toJson(),
        'version': 'custom',
        'endpoint': 'https://soutubot.moe/new/search',
      }));
      await store.setEnabled(builtinImagePluginId, false);
      await store.restoreBuiltin();
      expect(store.enabled(builtinImagePluginId), isTrue);
      expect(store.record(builtinImagePluginId)!.plugin.endpoint.path,
          '/api/search');
      expect(store.record(builtinImagePluginId)!.previous!.version, 'custom');
      await expectLater(
          store.remove(builtinImagePluginId), throwsFormatException);
    });

    test('AI may only update installed same-origin adapter with maintenance on',
        () async {
      await store.importManifest(jsonEncode(_manifest()));
      await expectLater(
          store.importManifest(jsonEncode(_manifest(version: '2')),
              fromAi: true),
          throwsFormatException);
      await store.setMaintenanceEnabled(true);
      await expectLater(
          store.importManifest(jsonEncode(_manifest(id: 'new_plugin')),
              fromAi: true),
          throwsFormatException);
      await expectLater(
          store.importManifest(
              jsonEncode(
                  _manifest(endpoint: 'https://other.example.com/search')),
              fromAi: true),
          throwsFormatException);
      await store.importManifest(
          jsonEncode(
              _manifest(version: '2', endpoint: 'https://example.com/v2')),
          fromAi: true);
      expect(store.record('catalog')!.plugin.version, '2');
      await store.setMaintenanceEnabled(false);
      await expectLater(
          store.rollback('catalog', fromAi: true), throwsFormatException);
      expect(store.record('catalog')!.plugin.version, '2');
    });

    test('AI rollback cannot change origin after a manual endpoint replacement',
        () async {
      await store.importManifest(jsonEncode(_manifest()));
      await store.importManifest(jsonEncode(_manifest(
          version: '2', endpoint: 'https://other.example.com/search')));
      await store.setMaintenanceEnabled(true);
      await expectLater(
          store.rollback('catalog', fromAi: true), throwsFormatException);
      expect(store.record('catalog')!.plugin.version, '2');
      await store.rollback('catalog');
      expect(store.record('catalog')!.plugin.version, '1');
    });

    test('corrupt file is preserved on load, backed up before explicit repair',
        () async {
      const original = '{invalid local plugin store';
      await file.writeAsString(original);
      await store.load();
      expect(store.loadWarning, isNotNull);
      expect(await file.readAsString(), original);
      expect(store.records.map((r) => r.plugin.id), [builtinImagePluginId]);
      await store.setEnabled(builtinImagePluginId, false);
      final backups = await directory
          .list()
          .where((entry) => entry.path.contains('.unreadable-'))
          .toList();
      expect(backups, hasLength(1));
      expect(await File(backups.single.path).readAsString(), original);
      expect(store.loadWarning, isNull);
      expect(store.enabled(builtinImagePluginId), isFalse);
    });

    test('invalid stored identities do not partially import a store', () async {
      await file.writeAsString(jsonEncode({
        'version': 1,
        'plugins': [
          {'plugin': _manifest(), 'enabled': true},
          {
            'plugin': _manifest(id: 'second'),
            'previous': _manifest(id: 'wrong_id'),
            'enabled': true,
          },
        ],
      }));
      await store.load();
      expect(store.loadWarning, isNotNull);
      expect(store.record('catalog'), isNull);
      expect(store.record('second'), isNull);
    });

    test('32-record cap includes restored builtin when a file omits it',
        () async {
      await file.writeAsString(jsonEncode({
        'version': 1,
        'plugins': [
          for (var i = 0; i < 32; i++)
            {'plugin': _manifest(id: 'plugin_$i'), 'enabled': true},
        ],
      }));
      await store.load();
      expect(store.loadWarning, isNotNull);
      expect(store.records.map((record) => record.plugin.id),
          [builtinImagePluginId]);
    });

    test('parallel mutations are serialized without losing updates', () async {
      await Future.wait([
        store.importManifest(jsonEncode(_manifest(id: 'first'))),
        store.importManifest(jsonEncode(_manifest(id: 'second'))),
        store.importManifest(jsonEncode(_manifest(id: 'first', version: '2'))),
        store.setEnabled('second', false),
        store.setMaintenanceEnabled(true),
      ]);
      final reopened = AiToolPluginStore.atFile(file);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.records, hasLength(3));
      expect(reopened.record('first')!.plugin.version, '2');
      expect(reopened.record('first')!.previous!.version, '1');
      expect(reopened.enabled('second'), isFalse);
      expect(reopened.maintenanceEnabled, isTrue);
    });

    test('refuses to persist a store exceeding its 4MB read limit', () async {
      final records = <Map<String, Object?>>[];
      for (var i = 0; i < 32; i++) {
        final manifest = _fullManifest(i == 0
            ? builtinImageSearchPlugin().toJson()
            : _manifest(id: 'plugin_$i'));
        records.add({
          'plugin': manifest,
          'enabled': true,
          if (i != 31) 'previous': manifest,
        });
      }
      await file.writeAsString(jsonEncode({'version': 1, 'plugins': records}));
      expect(await file.length(), lessThan(4 * 1024 * 1024));
      await store.load();
      expect(store.loadWarning, isNull);
      final before = await file.readAsBytes();
      await expectLater(
          store.importManifest(jsonEncode(
              _fullManifest(_manifest(id: 'plugin_31', version: '2')))),
          throwsFormatException);
      expect(await file.readAsBytes(), before);
      expect(store.record('plugin_31')!.plugin.version, '1');
      final reopened = AiToolPluginStore.atFile(file);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.loadWarning, isNull);
      expect(reopened.records, hasLength(32));
    });
  });
}
