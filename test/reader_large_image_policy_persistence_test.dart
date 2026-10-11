import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _index = readerImagePipelineSettingIndex;
const _device = ReaderImagePipelineSettings(
  comic: ReaderDisplayMode.previewFirst,
  largeImagePolicy: ReaderLargeImagePolicy.strictOriginal,
  legacyComic: 'device-comic',
  legacyIllust: 'device-illust',
);
const _incoming = ReaderImagePipelineSettings(
  illust: ReaderDisplayMode.previewFirst,
  legacyComic: 'backup-comic',
  legacyIllust: 'backup-illust',
);

String withoutPolicy(ReaderImagePipelineSettings config) {
  final data = jsonDecode(config.encode()) as Map<String, dynamic>;
  data.remove('largeImagePolicy');
  return jsonEncode(data);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('reader-policy-057-');
    App.dataPath = root.path;
    App.cachePath = '${root.path}/cache';
    await Directory(App.cachePath).create();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final file = File('${root.path}/settings');
    if (await file.exists()) {
      expect(file.parent.path, root.path);
      await file.delete();
    }
  });

  tearDownAll(() async {
    expect(root.path.split(Platform.pathSeparator).last,
        startsWith('reader-policy-057-'));
    await root.delete(recursive: true);
  });

  ReaderImagePipelineSettings config(Appdata data) =>
      ReaderImagePipelineSettings.tryParse(data.settings[_index])!;

  Future<void> expectPersisted(Appdata data) async {
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('settings')![_index], data.settings[_index]);
    final disk = jsonDecode(await File('${root.path}/settings').readAsString());
    expect(disk[_index], data.settings[_index]);
    final restarted = Appdata();
    await restarted.readSettings(prefs);
    expect(restarted.settings[_index], data.settings[_index]);
  }

  Future<void> importBackup(Appdata data, List<String> values) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('settings');
    expect(
        data.readDataFromJson(jsonDecode(jsonEncode({
          'settings': values,
          'firstUse': List.of(data.firstUse),
          'blockingKeywords': <String>[],
          'favoriteTags': <String>[],
        })) as Map<String, dynamic>),
        isTrue);
    // readDataFromJson owns an asynchronous writeData call; wait for its actual
    // preferences publication before reading the file or deleting the fixture.
    final expected = data.settings[_index];
    for (var i = 0; i < 100; i++) {
      if (prefs.getStringList('settings')?[_index] == expected) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await expectPersisted(data);
  }

  for (final disk in [false, true]) {
    for (final policy in ['missing', 'invalid', 'strictOriginal']) {
      test(
          'startup ${disk ? 'file' : 'prefs'} $policy preserves modes and facts',
          () async {
        final data = Appdata();
        final raw = jsonDecode(_device.encode()) as Map<String, dynamic>;
        if (policy == 'missing') {
          raw.remove('largeImagePolicy');
        } else {
          raw['largeImagePolicy'] = policy;
        }
        final values = List.of(data.settings)..[_index] = jsonEncode(raw);
        if (disk) {
          await File('${root.path}/settings').writeAsString(jsonEncode(values));
        } else {
          SharedPreferences.setMockInitialValues({'settings': values});
        }
        await data.readSettings(await SharedPreferences.getInstance());
        expect(config(data).comic, _device.comic);
        expect(config(data).illust, _device.illust);
        expect(config(data).legacyComic, _device.legacyComic);
        expect(config(data).legacyIllust, _device.legacyIllust);
        expect(
            config(data).largeImagePolicy,
            policy == 'strictOriginal'
                ? ReaderLargeImagePolicy.strictOriginal
                : ReaderLargeImagePolicy.safeWhole);
        // A migrated startup must publish by itself, not rely on a later save.
        if (policy != 'strictOriginal') await expectPersisted(data);
        await data.updateSettings(false);
        await expectPersisted(data);
      });
    }
  }

  test('save normalizes only a missing or invalid new field', () async {
    final data = Appdata();
    for (final raw in [
      withoutPolicy(_device),
      jsonEncode({...jsonDecode(_device.encode()), 'largeImagePolicy': []}),
    ]) {
      data.settings[_index] = raw;
      await data.updateSettings(false);
      expect(
          config(data).encode(),
          _device
              .withLargeImagePolicy(ReaderLargeImagePolicy.safeWhole)
              .encode());
      await expectPersisted(data);
    }
  });

  for (final length in [0, 10, 159, 160, 165]) {
    test('short startup and save array $length get safe default', () async {
      final values = Appdata().settings.take(length).toList();
      SharedPreferences.setMockInitialValues({'settings': values});
      final started = Appdata();
      await started.readSettings(await SharedPreferences.getInstance());
      expect(
          config(started).largeImagePolicy, ReaderLargeImagePolicy.safeWhole);
      final saving = Appdata()..settings = List.of(values);
      await saving.updateSettings(false);
      expect(config(saving).largeImagePolicy, ReaderLargeImagePolicy.safeWhole);
      await expectPersisted(saving);
    });
  }

  test('old schema2 backup inherits device policy but restores backup modes',
      () async {
    final data = Appdata()..settings[_index] = _device.encode();
    final values = List.of(data.settings)..[_index] = withoutPolicy(_incoming);
    await importBackup(data, values);
    expect(config(data).encode(),
        _incoming.withLargeImagePolicy(_device.largeImagePolicy).encode());
  });

  for (final policy in ['safeWhole', 'strictOriginal', 'invalid']) {
    test('backup with explicit $policy replaces only its own policy', () async {
      final data = Appdata()..settings[_index] = _device.encode();
      final values = List.of(data.settings)
        ..[_index] = jsonEncode({
          ...jsonDecode(_incoming.encode()),
          'largeImagePolicy': policy,
        });
      await importBackup(data, values);
      expect(
          config(data).encode(),
          _incoming
              .withLargeImagePolicy(ReaderLargeImagePolicy.fromValue(policy))
              .encode());
    });
  }

  test('old backup without entire 165 keeps complete current reader config',
      () async {
    final data = Appdata()..settings[_index] = _device.encode();
    await importBackup(data, data.settings.take(160).toList());
    expect(config(data).encode(), _device.encode());
  });

  test('old backup without valid current policy falls back to safe', () async {
    final data = Appdata()..settings[_index] = 'invalid';
    final values = List.of(data.settings)..[_index] = withoutPolicy(_incoming);
    await importBackup(data, values);
    expect(config(data).encode(), _incoming.encode());
  });

  test('shared setter merges latest modes and persisted backup roundtrip',
      () async {
    final data = Appdata()..settings[_index] = _incoming.encode();
    await data.setReaderLargeImagePolicy(ReaderLargeImagePolicy.strictOriginal);
    expect(
        config(data).encode(),
        _incoming
            .withLargeImagePolicy(ReaderLargeImagePolicy.strictOriginal)
            .encode());
    await expectPersisted(data);
    final backup =
        jsonDecode(jsonEncode(data.toJson())) as Map<String, dynamic>;
    final restored = Appdata();
    await importBackup(restored, List<String>.from(backup['settings']));
    expect(config(restored).encode(), config(data).encode());
  });
}
