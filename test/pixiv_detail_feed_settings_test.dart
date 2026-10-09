import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/pixiv_bookmark_feedback_settings.dart';
import 'package:picakeep/foundation/pixiv_detail_feed_settings.dart';
import 'package:picakeep/pages/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _authorIndex = pixivAuthorPreviewCountSettingIndex;
const _relatedIndex = pixivRelatedBatchSizeSettingIndex;
const _modeIndex = pixivRelatedModeSettingIndex;
const _pixivModeKey = ValueKey('pixiv-related-mode-pixiv');
const _customModeKey = ValueKey('pixiv-related-mode-custom');
const _authorKey = ValueKey('pixiv-author-preview-count-setting');
const _relatedKey = ValueKey('pixiv-related-batch-size-setting');
const _inputKey = ValueKey('pixiv-detail-feed-count-input');

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final Directory root;

  Future<String> _dir(String name) async =>
      (await Directory(p.join(root.path, name)).create(recursive: true)).path;

  @override
  Future<String?> getApplicationCachePath() => _dir('cache');

  @override
  Future<String?> getApplicationSupportPath() => _dir('support');
}

Future<PackageInfo> _packageInfo() async => PackageInfo(
      appName: 'PicaKeep',
      packageName: 'lingxue.picakeep',
      version: 'test',
      buildNumber: '0',
    );

Widget _settingsPage() => const MaterialApp(
      home: Scaffold(
        body: SettingsPage(initialPage: 0, packageInfoLoader: _packageInfo),
      ),
    );

Future<void> _openRelatedDialog(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_relatedKey));
  await tester.pumpAndSettle();
  await tester.runAsync(() => tester.tap(find.byKey(_relatedKey)));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  late PathProviderPlatform savedPaths;
  late List<String> savedSettings;
  late File settingsFile;

  setUpAll(() async {
    savedPaths = PathProviderPlatform.instance;
    savedSettings = List.of(appdata.settings);
    final tempParent =
        Directory(p.join('.dart_tool', '042-settings-temp')).absolute;
    await tempParent.create(recursive: true);
    workspace = await tempParent.createTemp('feed-settings-');
    PathProviderPlatform.instance = _Paths(workspace);
    await App.init(dataPathOverride: p.join(workspace.path, 'data'));
    settingsFile = File(p.join(App.dataPath, 'settings'));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    appdata.settings = List.of(Appdata().settings);
    if (await settingsFile.exists()) {
      expect(p.dirname(settingsFile.absolute.path),
          p.join(workspace.path, 'data'));
      await settingsFile.delete();
    }
  });

  tearDown(() => appdata.settings = List.of(savedSettings));

  tearDownAll(() async {
    appdata.settings = List.of(savedSettings);
    PathProviderPlatform.instance = savedPaths;
    expect(
        p.isWithin(
            Directory(p.join('.dart_tool', '042-settings-temp')).absolute.path,
            workspace.absolute.path),
        isTrue);
    await workspace.delete(recursive: true);
  });

  Future<void> expectPersisted(int author, int related,
      {String mode = pixivRelatedModePixiv}) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList('settings')!;
    expect(stored[_authorIndex], '$author');
    expect(stored[_relatedIndex], '$related');
    expect(stored[_modeIndex], mode);
    final disk =
        List<String>.from(jsonDecode(await settingsFile.readAsString()));
    expect(disk[_authorIndex], '$author');
    expect(disk[_relatedIndex], '$related');
    expect(disk[_modeIndex], mode);
    final fresh = Appdata();
    await fresh.readSettings(prefs);
    expect(readPixivAuthorPreviewCount(fresh.settings), author);
    expect(readPixivRelatedBatchSize(fresh.settings), related);
    expect(readPixivRelatedMode(fresh.settings), mode);
    expect(readPixivRelatedRequestedCount(fresh.settings),
        mode == pixivRelatedModePixiv ? null : related);
  }

  Future<void> waitForSave(int author, int related,
      {String mode = pixivRelatedModePixiv}) async {
    final prefs = await SharedPreferences.getInstance();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (prefs.getStringList('settings')?.elementAtOrNull(_authorIndex) !=
            '$author' ||
        prefs.getStringList('settings')?.elementAtOrNull(_relatedIndex) !=
            '$related' ||
        prefs.getStringList('settings')?.elementAtOrNull(_modeIndex) != mode) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Production save did not persist counts and related mode.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await expectPersisted(author, related, mode: mode);
  }

  Map<String, dynamic> importFixture(List<Object?> settings, Appdata data) =>
      jsonDecode(jsonEncode({
        'settings': settings,
        'firstUse': List.of(data.firstUse),
        'blockingKeywords': <String>[],
        'favoriteTags': <String>[],
      })) as Map<String, dynamic>;

  test('related mode appends at 170 with Pixiv default and dormant five', () {
    expect(_authorIndex, 168);
    expect(_relatedIndex, 169);
    expect(_modeIndex, 170);
    final defaults = Appdata().settings;
    expect(defaults.length, 171);
    expect(defaults[167], isEmpty);
    expect(defaults[_authorIndex], '5');
    expect(defaults[_relatedIndex], '5');
    expect(defaults[_modeIndex], pixivRelatedModePixiv);
    expect(defaults[pixivBookmarkQueueCountsSettingIndex], '0');
    expect(readPixivAuthorPreviewCount(), 5);
    expect(readPixivRelatedBatchSize(), 5);
    expect(readPixivRelatedMode(), pixivRelatedModePixiv);
    expect(readPixivRelatedRequestedCount(), isNull);
  });

  test(
      'mode accepts only exact tokens and defaults every invalid value to Pixiv',
      () {
    expect(normalizePixivRelatedMode('pixiv'), pixivRelatedModePixiv);
    expect(normalizePixivRelatedMode('custom'), pixivRelatedModeCustom);
    for (final raw in <Object?>[
      null,
      '',
      'bad',
      'PIXIV',
      'CUSTOM',
      ' custom ',
      'pixiv ',
      0,
      5,
      true,
      false,
      <Object?>[],
      <String, Object?>{},
    ]) {
      expect(normalizePixivRelatedMode(raw), pixivRelatedModePixiv,
          reason: 'mode raw=$raw');
    }
  });

  test(
      'normalizers accept integer or decimal integer text within independent bounds',
      () {
    for (final raw in <Object?>[
      null,
      '',
      ' ',
      'bad',
      0,
      -1,
      31,
      '0',
      '-1',
      '31',
      '1.5',
      1.0,
      '1e1',
      '+1',
      true,
      false,
      [],
      {},
    ]) {
      expect(normalizePixivAuthorPreviewCount(raw), 5,
          reason: 'author raw=$raw');
    }
    for (final raw in <Object?>[
      null,
      '',
      ' ',
      'bad',
      0,
      -1,
      19,
      30,
      '0',
      '-1',
      '19',
      '30',
      '1.5',
      1.0,
      '1e1',
      '+1',
      true,
      false,
      [],
      {},
    ]) {
      expect(normalizePixivRelatedBatchSize(raw), 5,
          reason: 'related raw=$raw');
    }
    for (var count = 1; count <= 30; count++) {
      expect(normalizePixivAuthorPreviewCount(count), count);
      expect(normalizePixivAuthorPreviewCount(' $count '), count);
      if (count <= 18) {
        expect(normalizePixivRelatedBatchSize(count), count);
        expect(normalizePixivRelatedBatchSize('$count'), count);
      }
    }
  });

  test('readers tolerate legacy arrays and do not couple the two preferences',
      () {
    for (final length in [0, 20, 166, 167, 168]) {
      final legacy = List.filled(length, '30');
      expect(readPixivAuthorPreviewCount(legacy), 5);
      expect(readPixivRelatedBatchSize(legacy), 5);
      expect(readPixivRelatedMode(legacy), pixivRelatedModePixiv);
      expect(readPixivRelatedRequestedCount(legacy), isNull);
    }
    final legacy170 = Appdata().settings.take(170).toList()
      ..[_relatedIndex] = '12';
    expect(readPixivRelatedBatchSize(legacy170), 12);
    expect(readPixivRelatedRequestedCount(legacy170), isNull);
    appdata.settings[_authorIndex] = '30';
    expect(readPixivAuthorPreviewCount(), 30);
    expect(readPixivRelatedBatchSize(), 5);
    appdata.settings[_relatedIndex] = '18';
    expect(readPixivAuthorPreviewCount(), 30);
    expect(readPixivRelatedBatchSize(), 18);
    expect(readPixivRelatedRequestedCount(), isNull);
    appdata.settings[_modeIndex] = pixivRelatedModeCustom;
    expect(readPixivRelatedRequestedCount(), 18);
    appdata.settings[_relatedIndex] = 'bad';
    expect(readPixivRelatedRequestedCount(), 5);
    expect(readPixivAuthorPreviewCount(), 30);
  });

  test(
      'readSettings uses missing original persisted slots, not stale in-memory counts',
      () async {
    final legacy = Appdata().settings.take(167).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('settings', legacy);
    final data = Appdata()
      ..settings[_authorIndex] = '30'
      ..settings[_relatedIndex] = '18';
    await data.readSettings(prefs);
    expect(readPixivAuthorPreviewCount(data.settings), 5);
    expect(readPixivRelatedBatchSize(data.settings), 5);
    expect(data.settings[pixivBookmarkQueueCountsSettingIndex], '0');
    await expectPersisted(5, 5);
  });

  test(
      'partially extended persisted array preserves author and defaults missing related',
      () async {
    final partial = Appdata().settings.take(169).toList()..[_authorIndex] = '7';
    await settingsFile.writeAsString(jsonEncode(partial));
    final data = Appdata()..settings[_relatedIndex] = '18';
    await data.readSettings(await SharedPreferences.getInstance());
    expect(readPixivAuthorPreviewCount(data.settings), 7);
    expect(readPixivRelatedBatchSize(data.settings), 5);
    await expectPersisted(7, 5);
  });

  for (final source in ['prefs', 'disk']) {
    test('$source legacy length 170 resets stale custom but preserves counts',
        () async {
      final legacy = Appdata().settings.take(170).toList()
        ..[_authorIndex] = '13'
        ..[_relatedIndex] = '12';
      final prefs = await SharedPreferences.getInstance();
      if (source == 'disk') {
        await settingsFile.writeAsString(jsonEncode(legacy));
      } else {
        await prefs.setStringList('settings', legacy);
      }
      final data = Appdata()..settings[_modeIndex] = pixivRelatedModeCustom;
      await data.readSettings(prefs);
      expect(readPixivRelatedMode(data.settings), pixivRelatedModePixiv);
      expect(readPixivRelatedRequestedCount(data.settings), isNull);
      expect(data.settings[167], isEmpty);
      await expectPersisted(13, 12);
    });
  }

  test('incoming current modes normalize independently from the manual count',
      () async {
    final prefs = await SharedPreferences.getInstance();
    for (final raw in ['pixiv', 'custom', '', 'bad', ' custom ', 'CUSTOM']) {
      final incoming = Appdata().settings
        ..[_authorIndex] = '13'
        ..[_relatedIndex] = '12'
        ..[_modeIndex] = raw;
      await settingsFile.writeAsString(jsonEncode(incoming));
      final data = Appdata()..settings[_modeIndex] = pixivRelatedModeCustom;
      await data.readSettings(prefs);
      final mode = normalizePixivRelatedMode(raw);
      expect(readPixivRelatedMode(data.settings), mode);
      if (raw == mode) {
        // Valid current arrays need no migration write; use the normal save to
        // check disk/prefs/reload after asserting the incoming read result.
        await data.updateSettings(false);
      }
      await expectPersisted(13, 12, mode: mode);
    }
  });

  test('invalid current disk count slots normalize and persist as five',
      () async {
    for (final pair in [('0', '19'), ('31', 'bad'), ('', ''), ('1.5', '-1')]) {
      final settings = Appdata().settings
        ..[_authorIndex] = pair.$1
        ..[_relatedIndex] = pair.$2;
      await settingsFile.writeAsString(jsonEncode(settings));
      final data = Appdata()
        ..settings[_authorIndex] = '30'
        ..settings[_relatedIndex] = '18';
      await data.readSettings(await SharedPreferences.getInstance());
      expect(readPixivAuthorPreviewCount(data.settings), 5);
      expect(readPixivRelatedBatchSize(data.settings), 5);
      await expectPersisted(5, 5);
    }
  });

  test(
      'current valid counts persist and reload, keeping queue-count preference',
      () async {
    final data = Appdata()
      ..settings[_authorIndex] = '30'
      ..settings[_relatedIndex] = '18'
      ..settings[pixivBookmarkQueueCountsSettingIndex] = '1';
    await data.updateSettings(false);
    await expectPersisted(30, 18);
    final fresh = Appdata();
    await fresh.readSettings(await SharedPreferences.getInstance());
    expect(showPixivBookmarkQueueCounts(fresh.settings), isTrue);
  });

  test(
      'legacy short updateSettings appends defaults and preserves prior settings',
      () async {
    final data = Appdata()..settings = Appdata().settings.take(167).toList();
    data.settings[23] = '1';
    await data.updateSettings(false);
    expect(data.settings.length, Appdata().settings.length);
    expect(data.settings[23], '1');
    expect(data.settings[pixivBookmarkQueueCountsSettingIndex], '0');
    await expectPersisted(5, 5);
  });

  test('updateSettings canonicalizes count values before disk and prefs writes',
      () async {
    final data = Appdata()
      ..settings[_authorIndex] = ' 007 '
      ..settings[_relatedIndex] = '18';
    await data.updateSettings(false);
    await expectPersisted(7, 18);
    data.settings[_authorIndex] = '999';
    data.settings[_relatedIndex] = '';
    await data.updateSettings(false);
    await expectPersisted(5, 5);
  });

  test('updateSettings length 170 appends Pixiv and preserves manual numbers',
      () async {
    final data = Appdata()
      ..settings = (Appdata().settings.take(170).toList()
        ..[_authorIndex] = '13'
        ..[_relatedIndex] = '12');
    await data.updateSettings(false);
    expect(data.settings.length, 171);
    await expectPersisted(13, 12);
    data.settings[_modeIndex] = pixivRelatedModeCustom;
    data.settings[_relatedIndex] = ' 007 ';
    await data.updateSettings(false);
    await expectPersisted(13, 7, mode: pixivRelatedModeCustom);
    data.settings[_modeIndex] = 'invalid';
    await data.updateSettings(false);
    await expectPersisted(13, 7);
  });

  test(
      'old imports reset missing counts instead of inheriting stale live memory',
      () async {
    final data = appdata;
    data.settings[_authorIndex] = '30';
    data.settings[_relatedIndex] = '18';
    expect(
        data.readDataFromJson(
            importFixture(Appdata().settings.take(167).toList(), data)),
        isTrue);
    expect(readPixivAuthorPreviewCount(), 5);
    expect(readPixivRelatedBatchSize(), 5);
    await waitForSave(5, 5);
  });

  test(
      'current imports normalize int/string counts and invalid values independently',
      () async {
    final data = appdata;
    final imported = List<Object?>.from(Appdata().settings)
      ..[_authorIndex] = 11
      ..[_relatedIndex] = '3';
    expect(data.readDataFromJson(importFixture(imported, data)), isTrue);
    await waitForSave(11, 3);
    imported[_authorIndex] = 0;
    imported[_relatedIndex] = '18';
    expect(data.readDataFromJson(importFixture(imported, data)), isTrue);
    await waitForSave(5, 18);
  });

  test(
      'raw JSON legacy import resets stale custom while retaining manual count',
      () async {
    appdata.settings[_modeIndex] = pixivRelatedModeCustom;
    appdata.settings[_relatedIndex] = '18';
    final imported = Appdata().settings.take(170).toList()
      ..[_authorIndex] = '13'
      ..[_relatedIndex] = '12';
    expect(appdata.readDataFromJson(importFixture(imported, appdata)), isTrue);
    expect(readPixivRelatedMode(), pixivRelatedModePixiv);
    expect(readPixivRelatedRequestedCount(), isNull);
    await waitForSave(13, 12);
  });

  test(
      'raw JSON mode imports normalize tokens and invalid values independently',
      () async {
    for (final raw in <Object?>[
      'custom',
      'pixiv',
      null,
      5,
      true,
      '',
      'bad',
      ' custom ',
    ]) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('settings');
      appdata.settings[_modeIndex] = pixivRelatedModeCustom;
      final imported = List<Object?>.from(Appdata().settings)
        ..[_authorIndex] = 13
        ..[_relatedIndex] = ' 012 '
        ..[_modeIndex] = raw;
      expect(
          appdata.readDataFromJson(importFixture(imported, appdata)), isTrue);
      final mode = normalizePixivRelatedMode(raw);
      expect(readPixivRelatedMode(), mode);
      expect(readPixivRelatedRequestedCount(),
          mode == pixivRelatedModeCustom ? 12 : null);
      await waitForSave(13, 12, mode: mode);
    }
  });

  testWidgets(
      'real browse settings default to Pixiv and save author and custom independently',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_settingsPage());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(_authorKey));
    await tester.pumpAndSettle();
    expect(
        find.descendant(of: find.byKey(_authorKey), matching: find.text('5 个')),
        findsOneWidget);
    await tester.ensureVisible(find.byKey(_relatedKey));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byKey(_relatedKey), matching: find.text('由Pixiv返回')),
        findsOneWidget);
    expect(find.text('作者作品预览数量'), findsOneWidget);
    expect(find.text('详情作者横排，默认5个'), findsOneWidget);
    expect(find.text('相关推荐每轮数量'), findsOneWidget);
    expect(find.text('每轮数量由Pixiv返回，读完后上拉继续推荐'), findsOneWidget);

    var displayVersion = App.displaySettingsVersion.value;
    await tester.ensureVisible(find.byKey(_authorKey));
    await tester.runAsync(() => tester.tap(find.byKey(_authorKey)));
    await tester.pumpAndSettle();
    expect(find.text('1–30 个，默认5个'), findsOneWidget);
    await tester.enterText(find.byKey(_inputKey), '7');
    await tester
        .runAsync(() => tester.tap(find.widgetWithText(FilledButton, '保存')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => waitForSave(7, 5));
    await tester.pumpAndSettle();
    expect(App.displaySettingsVersion.value, displayVersion + 1);
    expect(readPixivAuthorPreviewCount(), 7);
    expect(readPixivRelatedBatchSize(), 5);
    expect(
        find.descendant(of: find.byKey(_authorKey), matching: find.text('7 个')),
        findsOneWidget);

    displayVersion = App.displaySettingsVersion.value;
    await _openRelatedDialog(tester);
    expect(
        tester
            .widget<RadioGroup<String>>(
                find.byKey(const ValueKey('pixiv-related-mode-group')))
            .groupValue,
        pixivRelatedModePixiv);
    expect(find.byKey(_inputKey), findsNothing);
    await tester.runAsync(() => tester.tap(find.byKey(_customModeKey)));
    await tester.pumpAndSettle();
    expect(find.text('1–18 个，默认5个'), findsOneWidget);
    await tester.enterText(find.byKey(_inputKey), ' 003 ');
    await tester
        .runAsync(() => tester.tap(find.widgetWithText(FilledButton, '保存')));
    await tester.pumpAndSettle();
    await tester
        .runAsync(() => waitForSave(7, 3, mode: pixivRelatedModeCustom));
    await tester.pumpAndSettle();
    expect(App.displaySettingsVersion.value, displayVersion + 1);
    expect(readPixivAuthorPreviewCount(), 7);
    expect(readPixivRelatedBatchSize(), 3);
    expect(readPixivRelatedRequestedCount(), 3);
    expect(find.text('每轮最多3个，读完后上拉继续推荐'), findsOneWidget);
    expect(appdata.settings[pixivBookmarkQueueCountsSettingIndex], '0');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
      'Pixiv saves ignore an invalid draft, retain last manual count, and notify mode changes',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    appdata.settings[_authorIndex] = '13';
    appdata.settings[_relatedIndex] = '12';
    appdata.settings[_modeIndex] = pixivRelatedModeCustom;
    await tester.pumpWidget(_settingsPage());
    await tester.pumpAndSettle();
    final version = App.displaySettingsVersion.value;
    final before = List.of(appdata.settings);

    await _openRelatedDialog(tester);
    expect(
        tester
            .widget<RadioGroup<String>>(
                find.byKey(const ValueKey('pixiv-related-mode-group')))
            .groupValue,
        pixivRelatedModeCustom);
    expect(
        tester.widget<TextFormField>(find.byKey(_inputKey)).initialValue, '12');
    await tester.runAsync(() => tester.tap(find.byKey(_pixivModeKey)));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(appdata.settings, before);
    expect(App.displaySettingsVersion.value, version);
    expect((await SharedPreferences.getInstance()).getStringList('settings'),
        isNull);
    expect(await tester.runAsync(() => settingsFile.exists()), isFalse);

    await _openRelatedDialog(tester);
    await tester.enterText(find.byKey(_inputKey), 'bad');
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull);
    await tester.runAsync(() => tester.tap(find.byKey(_pixivModeKey)));
    await tester.pumpAndSettle();
    expect(find.byKey(_inputKey), findsNothing);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNotNull);
    await tester
        .runAsync(() => tester.tap(find.widgetWithText(FilledButton, '保存')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => waitForSave(13, 12));
    await tester.pumpAndSettle();
    expect(readPixivRelatedRequestedCount(), isNull);
    expect(App.displaySettingsVersion.value, version + 1);
    expect(find.text('每轮数量由Pixiv返回，读完后上拉继续推荐'), findsOneWidget);

    await _openRelatedDialog(tester);
    await tester.runAsync(() => tester.tap(find.byKey(_customModeKey)));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextFormField>(find.byKey(_inputKey)).initialValue, '12');
    await tester
        .runAsync(() => tester.tap(find.widgetWithText(FilledButton, '保存')));
    await tester.pumpAndSettle();
    await tester
        .runAsync(() => waitForSave(13, 12, mode: pixivRelatedModeCustom));
    await tester.pumpAndSettle();
    expect(readPixivRelatedRequestedCount(), 12);
    expect(readPixivAuthorPreviewCount(), 13);
    expect(App.displaySettingsVersion.value, version + 2);
    expect(find.text('每轮最多12个，读完后上拉继续推荐'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('range errors remain beside the field and cancel changes nothing',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_settingsPage());
    await tester.pumpAndSettle();
    final version = App.displaySettingsVersion.value;
    for (final entry in [(_authorKey, 30), (_relatedKey, 18)]) {
      await tester.ensureVisible(find.byKey(entry.$1));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(entry.$1));
      await tester.pumpAndSettle();
      if (entry.$1 == _relatedKey) {
        await tester.runAsync(() => tester.tap(find.byKey(_customModeKey)));
        await tester.pumpAndSettle();
      }
      for (final invalid in ['0', '${entry.$2 + 1}', 'bad', '', '1.5']) {
        await tester.enterText(find.byKey(_inputKey), invalid);
        await tester.pumpAndSettle();
        if (entry.$1 == _relatedKey) {
          expect(
              tester
                  .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
                  .onPressed,
              isNull);
        } else {
          await tester.tap(find.widgetWithText(FilledButton, '保存'));
          await tester.pumpAndSettle();
        }
        expect(find.text('请输入1到${entry.$2}的整数'), findsOneWidget);
        expect(find.byType(AlertDialog), findsOneWidget);
      }
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
    }
    expect(readPixivAuthorPreviewCount(), 5);
    expect(readPixivRelatedBatchSize(), 5);
    expect(readPixivRelatedMode(), pixivRelatedModePixiv);
    expect(readPixivRelatedRequestedCount(), isNull);
    expect(App.displaySettingsVersion.value, version);
    expect((await SharedPreferences.getInstance()).getStringList('settings'),
        isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
