// These tests exercise disk persistence/isolation, not normal UI or native dialogs.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import '../tools/image_pipeline_022_task_storage.dart';
import '../tools/image_pipeline_022_normal_ui_main.dart' as normal_ui;

class _ForbiddenPreferences extends SharedPreferencesStorePlatform {
  Never _reject() => throw StateError('OS/user preferences must not be called');
  @override
  Future<bool> clear() async => _reject();
  @override
  Future<Map<String, Object>> getAll() async => _reject();
  @override
  Future<bool> remove(String key) async => _reject();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      _reject();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final oldPreferences = SharedPreferencesStorePlatform.instance;
  final oldPaths = PathProviderPlatform.instance;
  late Directory parent;
  late ImagePipelineTaskStorage storage;
  setUp(() async {
    parent = await Directory.systemTemp.createTemp('picakeep-task-adapter-');
    storage = await ImagePipelineTaskStorage.prepare(
        p.join(parent.path, 'normal-ui-022-unit'));
  });
  tearDown(() async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = oldPreferences;
    PathProviderPlatform.instance = oldPaths;
    await parent.delete(recursive: true);
  });

  test(
      'explicit marked task roots reject existing user directories and escaped paths',
      () async {
    final existing = Directory(p.join(parent.path, 'normal-ui-022-unmarked'));
    await existing.create();
    await File(p.join(existing.path, 'user-settings'))
        .writeAsString('preserve');
    await expectLater(
        ImagePipelineTaskStorage.prepare(existing.path), throwsStateError);
    expect(await File(p.join(existing.path, 'user-settings')).readAsString(),
        'preserve');
    await expectLater(
        ImagePipelineTaskStorage.prepare('normal-ui-022-relative'),
        throwsArgumentError);
    await expectLater(
        storage.checkPath(p.join(parent.path, 'outside')), throwsStateError);
    expect((await ImagePipelineTaskStorage.prepare(storage.root)).root,
        storage.root);
  });

  test('a wrong marker cannot authorize reuse of another task directory',
      () async {
    final marker =
        File(p.join(storage.root, ImagePipelineTaskStorage.markerName));
    await marker.writeAsString(jsonEncode(
        {'scope': 'other-task', 'version': 1, 'root': storage.root}));
    await expectLater(
        ImagePipelineTaskStorage.prepare(storage.root), throwsStateError);
    expect((jsonDecode(await marker.readAsString()) as Map)['scope'],
        'other-task');
  });

  test(
      'real SharedPreferences API persists task prefix without any OS delegation',
      () async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = _ForbiddenPreferences();
    final store = await TaskSharedPreferencesStore.open(storage);
    SharedPreferencesStorePlatform.instance = store;
    SharedPreferences.setPrefix('picakeep022.');
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('language', 'zh');
    await preferences.setStringList('settings', ['local', 'sharpFirst']);
    await preferences.setBool('enabled', true);
    await preferences.setInt('count', 2);
    await preferences.setDouble('scale', 1.25);
    await store.setValue('String', 'unrelated.keep', 'preserve');
    final disk =
        jsonDecode(await File(storage.preferences).readAsString()) as Map;
    expect((disk['values'] as Map)['picakeep022.language'], 'zh');
    expect((disk['values'] as Map).containsKey('flutter.language'), false);
    final reopened = await TaskSharedPreferencesStore.open(storage);
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = reopened;
    SharedPreferences.setPrefix('picakeep022.');
    final reloaded = await SharedPreferences.getInstance();
    expect(reloaded.getStringList('settings'), ['local', 'sharpFirst']);
    expect(reloaded.getDouble('scale'), 1.25);
    await reloaded.clear();
    expect(await reopened.getAllWithPrefix('picakeep022.'), isEmpty);
    expect(await reopened.getAllWithPrefix('unrelated.'),
        {'unrelated.keep': 'preserve'});
    expect(await File('${storage.preferences}.part').exists(), false);
    expect(await File('${storage.preferences}.previous').exists(), false);
  });

  test(
      'prefix allow-list filtering and serialized writes survive adapter restart',
      () async {
    final store = await TaskSharedPreferencesStore.open(storage);
    await Future.wait(List.generate(
        20, (index) => store.setValue('Int', 'task.$index', index)));
    await store.setValue('StringList', 'task.list', ['original']);
    final snapshot = await store.getAllWithParameters(GetAllParameters(
        filter: PreferencesFilter(
            prefix: 'task.', allowList: {'task.1', 'task.list'})));
    (snapshot['task.list'] as List<String>).add('mutated');
    expect((await store.getAllWithPrefix('task.'))['task.list'], ['original']);
    await store.clearWithParameters(ClearParameters(
        filter: PreferencesFilter(prefix: 'task.', allowList: {'task.1'})));
    final reopened = await TaskSharedPreferencesStore.open(storage);
    expect((await reopened.getAllWithPrefix('task.')).length, 20);
    expect((await reopened.getAllWithPrefix('task.')).containsKey('task.1'),
        false);
    await expectLater(
        store.setValue('Int', 'bad', 'wrong-type'), throwsArgumentError);
    await store.setValue('Int', 'after-error', 1);
    expect(await store.getAllWithPrefix('after-'), {'after-error': 1});
  });

  test('every path-provider location is persistent and inside the task',
      () async {
    final paths = TaskPathProvider(storage);
    PathProviderPlatform.instance = paths;
    final directories = [
      await getTemporaryDirectory(),
      await getApplicationSupportDirectory(),
      await getApplicationCacheDirectory(),
      await getLibraryDirectory(),
      await getApplicationDocumentsDirectory(),
      (await getDownloadsDirectory())!,
      Directory((await paths.getExternalStoragePath())!),
      ...((await paths.getExternalCachePaths())!).map(Directory.new),
      ...((await paths.getExternalStoragePaths())!).map(Directory.new),
    ];
    for (final directory in directories) {
      expect(p.isWithin(storage.root, directory.path), true);
      expect(await directory.exists(), true);
    }
    expect((await getApplicationSupportDirectory()).path, storage.support);
  });

  test(
      'corrupt persisted preferences are rejected without reading or overwriting defaults',
      () async {
    await File(storage.preferences).writeAsString('{broken');
    await expectLater(
        TaskSharedPreferencesStore.open(storage), throwsFormatException);
    expect(await File(storage.preferences).readAsString(), '{broken');
  });

  test(
      'incomplete preference publication fails closed and preserves recovery bytes',
      () async {
    final backup = File('${storage.preferences}.previous');
    await backup.writeAsString('retained-for-recovery');
    await expectLater(
        TaskSharedPreferencesStore.open(storage), throwsStateError);
    expect(await backup.readAsString(), 'retained-for-recovery');
    expect(await File(storage.preferences).exists(), false);
  });

  test(
      'Dart system temporary files can be scoped without replacing native file plugins',
      () async {
    await IOOverrides.runZoned(() async {
      final temporary = await Directory.systemTemp.createTemp('actual-copy-');
      expect(p.isWithin(storage.temporary, temporary.path), true);
      await File(p.join(temporary.path, 'image.png')).writeAsBytes([1, 2, 3]);
      expect(await File(p.join(temporary.path, 'image.png')).readAsBytes(),
          [1, 2, 3]);
      await temporary.delete(recursive: true);
    }, getSystemTempDirectory: () => Directory(storage.temporary));
  });

  test(
      'normal UI target refuses missing explicit roots before App initialization',
      () async {
    await expectLater(normal_ui.main([]), throwsArgumentError);
  });

  final sourceRoot = Platform.environment['PICAKEEP_022_REAL_SOURCE_ROOT'];
  test(
      'prepare-only uses real anonymous source hashes and persistent task settings',
      () async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = _ForbiddenPreferences();
    final arguments = [
      '--work=${storage.root}',
      '--sources=$sourceRoot',
      '--prepare-only=true'
    ];
    final sourcePaths = [
      p.join(sourceRoot!, 'page-001.jpg'),
      p.join(sourceRoot, 'archive-001.zip')
    ];
    final before = [for (final path in sourcePaths) await File(path).stat()];
    await normal_ui.main(arguments);
    final preferences = await SharedPreferences.getInstance();
    final settings = preferences.getStringList('settings')!;
    expect(settings[22], p.join(storage.support, 'download'));
    expect(settings[75], '0');
    expect(settings[90], '');
    expect(settings[91], jsonEncode([storage.library]));
    expect(settings[97], 'client');
    expect((jsonDecode(settings[118]) as Map).values, [true]);
    expect(preferences.getKeys(), {'settings', 'firstUse'});
    final config = jsonDecode(
        await File(p.join(storage.support, 'picakeep_server.data'))
            .readAsString()) as Map;
    expect(config['host'], '127.0.0.1');
    expect(config['originalDownloadRoot'], '');
    expect(config['customLibraryRoots'], [storage.library]);
    expect(
        (jsonDecode(config['customLibraryCollectionShellModes'] as String)
                as Map)
            .values,
        [true]);
    expect(settings[98], 'http://127.0.0.1:${config['port']}');
    expect(
        await File(p.join(storage.library, 'real-jpeg', '1.jpg')).readAsBytes(),
        await File(sourcePaths[0]).readAsBytes());
    expect(await File(p.join(storage.library, 'archive-001.zip')).readAsBytes(),
        await File(sourcePaths[1]).readAsBytes());
    final workflow = jsonDecode(
        await File(p.join(storage.root, 'workflow-fixtures.json'))
            .readAsString()) as Map;
    final pngs = (workflow['pngSha256'] as List).cast<String>();
    expect(pngs.toSet().length, 2);
    expect((workflow['chapters'] as Map)['chapter-1'],
        [workflow['jpegSha256'], ...pngs]);
    expect((workflow['chapters'] as Map)['chapter-2'],
        [workflow['jpegSha256'], ...pngs.reversed]);
    final first = File(p.join(storage.library, 'same-name-1', '1.png'));
    final second = File(p.join(storage.library, 'same-name-2', '1.png'));
    expect(await first.readAsBytes(), isNot(await second.readAsBytes()));
    expect(
        await File(
                p.join(storage.library, 'real-workflow', 'chapter-1', '2.png'))
            .readAsBytes(),
        await first.readAsBytes());
    expect(
        await File(
                p.join(storage.library, 'real-workflow', 'chapter-2', '2.png'))
            .readAsBytes(),
        await second.readAsBytes());
    settings[50] = 'en';
    await preferences.setStringList('settings', settings);
    SharedPreferences.resetStatic();
    await normal_ui.main(arguments);
    expect(
        (await SharedPreferences.getInstance()).getStringList('settings')![50],
        'en');
    // A later launch must refuse to overwrite a modified task source.
    await first.writeAsBytes([1, 2, 3]);
    SharedPreferences.resetStatic();
    await expectLater(normal_ui.main(arguments), throwsStateError);
    expect(await first.readAsBytes(), [1, 2, 3]);
    for (var i = 0; i < sourcePaths.length; i++) {
      final after = await File(sourcePaths[i]).stat();
      expect(after.size, before[i].size);
      expect(after.modified, before[i].modified);
    }
    expect(await File(p.join(storage.support, 'cookies.db')).exists(), false);
    expect(
        await File(p.join(storage.support, 'download', 'download.db')).exists(),
        false);
  },
      skip: sourceRoot == null
          ? 'Requires explicit anonymous PICAKEEP_022_REAL_SOURCE_ROOT'
          : false);
}
