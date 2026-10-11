import 'dart:convert';
import 'dart:io';
import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/reader_large_image_policy_setting.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart' as reader;
import 'package:picakeep/pages/settings/settings_page.dart' as settings;
import 'package:shared_preferences/shared_preferences.dart';

const _policyTitle = ReaderLargeImagePolicySetting.title;
const _scope = ReaderLargeImagePolicySetting.scope;

class _SettingsData extends reader.ReadingData {
  _SettingsData(this.sourceKey);
  @override
  final String sourceKey;
  @override
  String get id => '057-policy-settings-fixture';
  @override
  String get downloadId => id;
  @override
  String get title => 'Settings only fixture';
  @override
  ComicType get comicType => ComicType.jm;
  @override
  FavoriteType get favoriteType => FavoriteType.jm;
  @override
  bool get hasEp => false;
  @override
  Map<String, String>? get eps => null;
  @override
  bool get downloaded => false;
  @override
  Future<List<String>> loadEpNetwork(int ep) async => [];
  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) =>
      throw StateError('Settings fixture must never request an image');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late List<String> savedSettings;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('reader-policy-ui-057-');
    App.dataPath = root.path;
    App.cachePath = '${root.path}/cache';
    await Directory(App.cachePath).create();
  });

  setUp(() {
    savedSettings = List.of(appdata.settings);
    appdata.settings = List.of(Appdata().settings);
    appdata.settings[50] = 'zh';
    appdata.settings[28] = '0';
    appdata.settings[readerImagePipelineSettingIndex] =
        const ReaderImagePipelineSettings(
      legacyComic: 'comic-marker',
      legacyIllust: 'illust-marker',
    ).encode();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => appdata.settings = savedSettings);

  tearDownAll(() async {
    expect(root.path.split(Platform.pathSeparator).last,
        startsWith('reader-policy-ui-057-'));
    await root.delete(recursive: true);
  });

  ReaderImagePipelineSettings current() => ReaderImagePipelineSettings.tryParse(
      appdata.settings[readerImagePipelineSettingIndex])!;

  Future<void> flush(WidgetTester tester) async {
    final prefs = await SharedPreferences.getInstance();
    final expected = appdata.settings[readerImagePipelineSettingIndex];
    // File IO is real-time, while production callbacks resume in the fake zone.
    for (var i = 0; i < 100; i++) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      if (prefs.getStringList('settings')?[readerImagePipelineSettingIndex] ==
          expected) {
        break;
      }
    }
    expect(prefs.getStringList('settings')?[readerImagePipelineSettingIndex],
        expected);
    await tester.runAsync(() async {
      final file =
          jsonDecode(await File('${root.path}/settings').readAsString());
      expect(file[readerImagePipelineSettingIndex], expected);
      final fresh = Appdata();
      await fresh.readSettings(prefs);
      expect(fresh.settings[readerImagePipelineSettingIndex], expected);
    });
  }

  Future<void> choosePolicy(
      WidgetTester tester, ReaderLargeImagePolicy policy) async {
    final row = find.byType(ReaderLargeImagePolicySetting);
    expect(row, findsOneWidget);
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.text(_scope)),
        findsOneWidget);
    final option = find.widgetWithText(RadioListTile<ReaderLargeImagePolicy>,
        ReaderLargeImagePolicySetting.label(policy));
    await tester.ensureVisible(option);
    await tester.tap(option);
    await tester.pumpAndSettle();
    await flush(tester);
    expect(current().largeImagePolicy, policy);
    expect(tester.widget<ReaderLargeImagePolicySetting>(row).value, policy);
  }

  Future<void> chooseMode(
      WidgetTester tester, String title, String mode) async {
    final row =
        find.ancestor(of: find.text(title), matching: find.byType(ListTile));
    final selector = find.descendant(
        of: row, matching: find.byType(PopupMenuButton<String>));
    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, mode));
    await tester.pumpAndSettle();
    await flush(tester);
  }

  Future<void> pumpGlobal(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body:
            SingleChildScrollView(child: settings.ReadingSettings(width: 400)),
      ),
    ));
    await tester.pumpAndSettle();
  }

  for (final fixture in [
    for (final sourceKey in ['jm', 'local_album'])
      for (final size in [const Size(400, 800), const Size(800, 400)])
        (sourceKey: sourceKey, size: size),
  ]) {
    final sourceKey = fixture.sourceKey;
    testWidgets(
        'global and $sourceKey reader ${fixture.size} share policy across reopen/restart',
        (tester) async {
      tester.view.physicalSize = fixture.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpGlobal(tester);
      await choosePolicy(tester, ReaderLargeImagePolicy.strictOriginal);
      await chooseMode(tester, '漫画图片显示', '预览优先');
      await chooseMode(tester, '插画 / 图集图片显示', '预览优先');
      expect(current().largeImagePolicy, ReaderLargeImagePolicy.strictOriginal);

      reader.ComicReadingPage(_SettingsData(sourceKey), 1, 1);
      final logic = StateController.find<reader.ComicReadingPageLogic>();
      var rebuilds = 0;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        logic.clearPhotoViewControllers();
        logic.pageController.dispose();
        logic.scrollController.dispose();
        logic.focusNode.dispose();
        logic.viewportChanges.dispose();
        logic.dispose();
      });
      await tester.pumpWidget(MaterialApp(
        navigatorKey: App.navigatorKey,
        home: Scaffold(body: Builder(builder: (context) {
          return StateBuilder<reader.ComicReadingPageLogic>(builder: (_) {
            rebuilds++;
            return TextButton(
              onPressed: () => reader.showSettings(context),
              child: const Text('open-reader-settings'),
            );
          });
        })),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open-reader-settings'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<ReaderLargeImagePolicySetting>(
                  find.byType(ReaderLargeImagePolicySetting))
              .value,
          ReaderLargeImagePolicy.strictOriginal);
      final before = rebuilds;
      final page = logic.index;
      final chapter = logic.order;
      await choosePolicy(tester, ReaderLargeImagePolicy.safeWhole);
      expect(rebuilds, greaterThan(before),
          reason: 'reader logic.update must run');
      expect(current().comic, ReaderDisplayMode.previewFirst);
      expect(current().illust, ReaderDisplayMode.previewFirst);
      await chooseMode(tester, '图片显示', '清晰优先');
      expect(current().largeImagePolicy, ReaderLargeImagePolicy.safeWhole);
      await choosePolicy(tester, ReaderLargeImagePolicy.strictOriginal);
      expect(current().legacyComic, 'comic-marker');
      expect(current().legacyIllust, 'illust-marker');
      expect(logic.index, page);
      expect(logic.order, chapter);
      App.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('open-reader-settings'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<ReaderLargeImagePolicySetting>(
                  find.byType(ReaderLargeImagePolicySetting))
              .value,
          ReaderLargeImagePolicy.strictOriginal);
      App.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await pumpGlobal(tester);
      expect(
          tester
              .widget<ReaderLargeImagePolicySetting>(
                  find.byType(ReaderLargeImagePolicySetting))
              .value,
          ReaderLargeImagePolicy.strictOriginal);
      await choosePolicy(tester, ReaderLargeImagePolicy.safeWhole);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(320, 640), const Size(800, 400)]) {
    for (final scale in [1.0, 2.0, 3.0]) {
      for (final brightness in Brightness.values) {
        testWidgets('policy dialog wraps $size scale $scale $brightness',
            (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final semantics = tester.ensureSemantics();
          try {
            ReaderLargeImagePolicy? selected;
            await tester.pumpWidget(MaterialApp(
              theme: ThemeData(brightness: brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  padding: const EdgeInsets.only(top: 24, bottom: 24),
                ),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: ReaderLargeImagePolicySetting(
                    value: ReaderLargeImagePolicy.safeWhole,
                    onChanged: (value) => selected = value,
                  ),
                ),
              ),
            ));
            await tester.tap(find.text(_policyTitle));
            await tester.pumpAndSettle();
            final safe = find.widgetWithText(
                RadioListTile<ReaderLargeImagePolicy>, '安全整图显示');
            final strict = find.widgetWithText(
                RadioListTile<ReaderLargeImagePolicy>, '严格原尺寸');
            for (final option in [safe, strict]) {
              expect(tester.getSize(option).height, greaterThanOrEqualTo(48));
            }
            await tester.ensureVisible(safe);
            final safeSemantics = tester.getSemantics(safe).getSemanticsData();
            expect(
                safeSemantics.flagsCollection.isChecked, CheckedState.isTrue);
            expect(safeSemantics.label, contains('安全整图显示'));
            await tester.ensureVisible(strict);
            await tester.tap(strict);
            await tester.pumpAndSettle();
            expect(selected, ReaderLargeImagePolicy.strictOriginal);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        });
      }
    }
  }
}
