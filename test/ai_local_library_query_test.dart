import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/ai/ai_capabilities.dart';
import 'package:picakeep/foundation/ai/local_library_ai_query.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:sqlite3/open.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final Directory root;

  @override
  Future<String?> getApplicationCachePath() async {
    final dir = Directory('${root.path}${Platform.pathSeparator}cache');
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String?> getApplicationSupportPath() async {
    final dir = Directory('${root.path}${Platform.pathSeparator}support');
    await dir.create(recursive: true);
    return dir.path;
  }
}

void main() {
  open.overrideFor(
    OperatingSystem.windows,
    () => DynamicLibrary.open(
      '${Directory.current.path}${Platform.pathSeparator}windows'
      '${Platform.pathSeparator}sqlite3.dll',
    ),
  );

  test('AI local capability schemas include rich local query tools', () {
    final names = AiCapabilities.registry
        .toolSchemas()
        .map((schema) => schema['name'])
        .toSet();

    expect(names, contains('search_local'));
    expect(names, contains('query_local_library'));
    expect(names, contains('resolve_local_items'));
    expect(names, contains('search_online'));
    expect(names, contains('download_comic'));
    expect(names, contains('get_download_status'));
  });

  test('AI local input parser handles mixed loose lists', () {
    final inputs = const AiLocalLibraryQueryCore().parseInputs(
      text: '1. jm12345\n- nh12345；https://e-hentai.org/g/987/abc123/，普通标题',
    );

    expect(inputs.map((e) => e.rawText), contains('jm12345'));
    expect(inputs.map((e) => e.rawText), contains('nh12345'));
    expect(inputs.map((e) => e.rawText), contains('普通标题'));
    expect(
        inputs.any((e) => e.source == 'jm' && e.originId == 'jm12345'), true);
    expect(
      inputs.any((e) => e.source == 'nhentai' && e.originId == 'nhentai12345'),
      true,
    );
    expect(
      inputs.any((e) => e.source == 'ehentai' && e.originId == '987-abc123'),
      true,
    );
  });

  test('AI local tools reject empty input and survive empty local data',
      () async {
    final root =
        await Directory.systemTemp.createTemp('picakeep_ai_local_test_');
    PathProviderPlatform.instance = _FakePathProvider(root);
    await App.init(
        dataPathOverride: '${root.path}${Platform.pathSeparator}data');

    final previousPath = appdata.settings[22];
    appdata.settings[22] =
        '${root.path}${Platform.pathSeparator}empty-download';
    try {
      final registry = AiCapabilities.registry;

      final missingQuery = await registry.dispatch('query_local_library', {});
      expect(missingQuery.ok, false);

      final noMatch = await registry.dispatch(
        'query_local_library',
        {'query': '__unlikely_ai_local_test_keyword__'},
      );
      expect(noMatch.ok, true);
      final noMatchData = noMatch.data as Map;
      expect(noMatchData['items'], isEmpty);

      final missingResolve = await registry.dispatch('resolve_local_items', {});
      expect(missingResolve.ok, false);

      final resolved = await registry.dispatch(
        'resolve_local_items',
        {'text': 'jm12345\nnh12345\n普通标题'},
      );
      expect(resolved.ok, true);
      final resolvedData = resolved.data as Map;
      expect(resolvedData['inputs'], hasLength(3));
      expect((resolvedData['summary'] as Map)['total'], 3);
    } finally {
      appdata.settings[22] = previousPath;
      HistoryManager().dispose();
      LocalFavoritesManager().dispose();
      await root.delete(recursive: true);
    }
  });
}
