import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart' as reader;
import 'package:picakeep/pages/reader/reader_page_image.dart';
import 'package:picakeep/pages/settings/settings_page.dart' as settings;
import 'package:shared_preferences/shared_preferences.dart';

const _comicTitle = '漫画图片显示';
const _illustTitle = '插画 / 图集图片显示';
const _imageTitle = '图片显示';
const _previewTitle = '预览优先';
const _sharpTitle = '清晰优先';

class _FailingReadingData extends reader.ReadingData {
  _FailingReadingData(this.sourceKey);

  int sourceLoads = 0;
  final urls = const ['first', 'second', 'third'];

  @override
  final String sourceKey;
  @override
  String get id => 'reader-settings-fixture';
  @override
  String get downloadId => id;
  @override
  String get title => 'Reader settings fixture';
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
  Future<List<String>> loadEpNetwork(int ep) async => urls;
  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) =>
      Stream.value(const <int>[]);
  @override
  Future<ReaderPageSource> resolvePageSource(
      int ep, int page, String url) async {
    sourceLoads++;
    throw const FileSystemException('fixture source failure');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory taskRoot;
  late List<String> savedSettings;
  late List<String> savedImplicit;
  late bool savedLogging;

  setUpAll(() async {
    taskRoot = await Directory.systemTemp.createTemp('reader-settings-046-');
    App.dataPath = taskRoot.path;
    App.cachePath = '${taskRoot.path}/cache';
    await Directory(App.cachePath).create();
  });

  tearDownAll(() async {
    await taskRoot.delete(recursive: true);
  });

  setUp(() {
    savedSettings = List.of(appdata.settings);
    savedImplicit = List.of(appdata.implicitData);
    savedLogging = LogManager.recordingEnabled;
    LogManager.recordingEnabled = false;
    SharedPreferences.setMockInitialValues({});
    appdata.settings[0] = '1';
    appdata.settings[9] = '1';
    appdata.settings[28] = '0';
    appdata.settings[43] = '0';
    appdata.settings[49] = '0';
    appdata.settings[50] = 'zh';
    appdata.settings[55] = '0';
    appdata.settings[readerImagePipelineSettingIndex] =
        const ReaderImagePipelineSettings(
      legacyComic: 'comic-marker',
      legacyIllust: 'illust-marker',
    ).encode();
    reader.TapController.reset();
    reader.TapController.lastScrollTime = DateTime(2023);
  });

  tearDown(() {
    appdata.settings = savedSettings;
    appdata.implicitData = savedImplicit;
    LogManager.recordingEnabled = savedLogging;
    reader.TapController.reset();
  });

  ReaderImagePipelineSettings currentConfig() =>
      ReaderImagePipelineSettings.tryParse(
          appdata.settings[readerImagePipelineSettingIndex])!;

  Finder settingRow(String title) =>
      find.ancestor(of: find.text(title), matching: find.byType(ListTile));

  Finder selector(String title) => find.descendant(
      of: settingRow(title), matching: find.byType(PopupMenuButton<String>));

  void expectDisplayed(String title, String modeTitle) {
    expect(find.descendant(of: selector(title), matching: find.text(modeTitle)),
        findsOneWidget);
  }

  Future<void> flushPersistence(WidgetTester tester) async {
    final prefs = await SharedPreferences.getInstance();
    for (var i = 0; i < 20; i++) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      if (prefs.getStringList('settings')?[readerImagePipelineSettingIndex] ==
          appdata.settings[readerImagePipelineSettingIndex]) {
        break;
      }
    }
    expect(prefs.getStringList('settings')?[readerImagePipelineSettingIndex],
        appdata.settings[readerImagePipelineSettingIndex]);
    await tester.runAsync(() async {
      final onDisk =
          jsonDecode(await File('${taskRoot.path}/settings').readAsString())
              as List;
      expect(onDisk[readerImagePipelineSettingIndex],
          appdata.settings[readerImagePipelineSettingIndex]);
    });
  }

  Future<void> select(
      WidgetTester tester, String title, String modeTitle) async {
    final control = selector(title);
    expect(control, findsOneWidget);
    await tester.ensureVisible(control);
    await tester.tap(control);
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<String>), findsNWidgets(2));
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, modeTitle));
    await tester.pumpAndSettle();
    await flushPersistence(tester);
    expectDisplayed(title, modeTitle);
  }

  Future<void> pumpGlobal(WidgetTester tester, {Key? key}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        key: key,
        body: const SingleChildScrollView(
          child: settings.ReadingSettings(width: 400),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  for (final comicFirst in [true, false]) {
    testWidgets(
        'global selectors merge latest policy in ${comicFirst ? 'comic then illustration' : 'illustration then comic'} order',
        (tester) async {
      await pumpGlobal(tester);
      expectDisplayed(_comicTitle, _sharpTitle);
      expectDisplayed(_illustTitle, _sharpTitle);
      final first = comicFirst ? _comicTitle : _illustTitle;
      final second = comicFirst ? _illustTitle : _comicTitle;
      await select(tester, first, _previewTitle);
      expect(comicFirst ? currentConfig().illust : currentConfig().comic,
          ReaderDisplayMode.sharpFirst);
      // Both child States stay mounted while their menus are used in turn.
      await select(tester, second, _previewTitle);
      expect(currentConfig().comic, ReaderDisplayMode.previewFirst);
      expect(currentConfig().illust, ReaderDisplayMode.previewFirst);
      await select(tester, first, _sharpTitle);
      expect(comicFirst ? currentConfig().illust : currentConfig().comic,
          ReaderDisplayMode.previewFirst);
      expect(currentConfig().legacyComic, 'comic-marker');
      expect(currentConfig().legacyIllust, 'illust-marker');

      final persisted = (await SharedPreferences.getInstance())
          .getStringList('settings')![readerImagePipelineSettingIndex];
      appdata.settings[readerImagePipelineSettingIndex] = persisted;
      await pumpGlobal(tester, key: const ValueKey('reopened'));
      expectDisplayed(first, _sharpTitle);
      expectDisplayed(second, _previewTitle);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('global selectors recover invalid policy using existing defaults',
      (tester) async {
    appdata.settings[readerImagePipelineSettingIndex] = '{broken-json';
    await pumpGlobal(tester);
    expectDisplayed(_comicTitle, _sharpTitle);
    expectDisplayed(_illustTitle, _sharpTitle);
    await select(tester, _illustTitle, _previewTitle);
    expect(currentConfig().comic, ReaderDisplayMode.sharpFirst);
    expect(currentConfig().illust, ReaderDisplayMode.previewFirst);
    await select(tester, _comicTitle, _previewTitle);
    expect(currentConfig().comic, ReaderDisplayMode.previewFirst);
    expect(currentConfig().illust, ReaderDisplayMode.previewFirst);
    expect(tester.takeException(), isNull);
  });

  Future<(_FailingReadingData, reader.ComicReadingPageLogic)> pumpReader(
      WidgetTester tester, String sourceKey) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final data = _FailingReadingData(sourceKey);
    final page = reader.ComicReadingPage(data, 1, 1);
    final logic = StateController.find<reader.ComicReadingPageLogic>();
    logic.urls = data.urls;
    logic.isLoading = false;
    logic.scrollManager = reader.ScrollManager(logic);
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
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) =>
              reader.TapController.onTapDown(event, context),
          onPointerMove: reader.TapController.onPointerMove,
          onPointerUp: (event) => reader.TapController.onTapUp(event, context),
          onPointerCancel: reader.TapController.onTapCancel,
          child: StateBuilder<reader.ComicReadingPageLogic>(builder: (logic) {
            return Stack(children: [
              page.buildComicView(logic, context, 'settings-workflow'),
              Positioned(
                top: 0,
                left: 0,
                child: TextButton(
                  onPressed: () => reader.showSettings(context),
                  child: const Text('open-settings'),
                ),
              ),
            ]);
          }),
        );
      })),
    ));
    await tester.pumpAndSettle();
    expect(data.sourceLoads, greaterThan(0));
    await tester.tap(find.text('open-settings'));
    await tester.pumpAndSettle();
    expect(find.byType(reader.ReadingSettings), findsOneWidget);
    return (data, logic);
  }

  for (final sourceKey in ['jm', 'local_album']) {
    testWidgets(
        'reader menu persists $sourceKey mode and keeps failure until explicit retry',
        (tester) async {
      final (data, logic) = await pumpReader(tester, sourceKey);
      final beforeLoads = data.sourceLoads;
      final beforePage = logic.index;
      final beforeChapter = logic.order;
      expectDisplayed(_imageTitle, _sharpTitle);
      await select(tester, _imageTitle, _previewTitle);
      final isComic = readerReadingIsComic(sourceKey);
      expect(isComic ? currentConfig().comic : currentConfig().illust,
          ReaderDisplayMode.previewFirst);
      expect(isComic ? currentConfig().illust : currentConfig().comic,
          ReaderDisplayMode.sharpFirst);
      expect(currentConfig().legacyComic, 'comic-marker');
      expect(currentConfig().legacyIllust, 'illust-marker');
      final currentPages = tester.widgetList<ReaderPageImage>(
          find.byType(ReaderPageImage, skipOffstage: false));
      expect(currentPages, isNotEmpty);
      expect(currentPages.map((page) => page.mode),
          everyElement(ReaderDisplayMode.previewFirst));
      expect(data.sourceLoads, beforeLoads);
      expect(logic.index, beforePage);
      expect(logic.order, beforeChapter);

      App.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      final retries = find.descendant(
          of: find.byType(ReaderPageImage), matching: find.byType(TextButton));
      expect(retries, findsOneWidget);
      await tester.tap(retries);
      await tester.pumpAndSettle();
      expect(data.sourceLoads, beforeLoads + 1);
      await tester.tap(find.text('open-settings'));
      await tester.pumpAndSettle();
      expectDisplayed(_imageTitle, _previewTitle);
      expect(logic.index, beforePage);
      expect(logic.order, beforeChapter);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('reader menu recovers invalid policy using existing defaults',
      (tester) async {
    appdata.settings[readerImagePipelineSettingIndex] = 'invalid';
    final (data, _) = await pumpReader(tester, 'jm');
    final beforeLoads = data.sourceLoads;
    expectDisplayed(_imageTitle, _sharpTitle);
    await select(tester, _imageTitle, _previewTitle);
    expect(currentConfig().comic, ReaderDisplayMode.previewFirst);
    expect(currentConfig().illust, ReaderDisplayMode.sharpFirst);
    expect(data.sourceLoads, beforeLoads);
    expect(tester.takeException(), isNull);
  });
}
