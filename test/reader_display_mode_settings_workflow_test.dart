import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:picakeep/foundation/image_loader/reader_preview_provider.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_cache.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep/pages/reader/reader_whole_image.dart';
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
const _loadFailure = '图片暂时无法打开，请重试';

class _FailingReadingData extends reader.ReadingData {
  _FailingReadingData(this.sourceKey);

  int sourceLoads = 0;
  int providerLoads = 0;
  int invalidations = 0;
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
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) {
    providerLoads++;
    return Stream.value(const <int>[]);
  }

  @override
  Future<void> invalidateImage(int ep, int page, String url) async {
    invalidations++;
  }

  @override
  Future<ReaderPageSource> resolvePageSource(
      int ep, int page, String url) async {
    sourceLoads++;
    throw const FileSystemException('fixture source failure');
  }
}

// Intentionally isolates a sharp source failure from a valid provider result.
// It does not diagnose the cause of any real user's failure.
class _ValidProviderReadingData extends _FailingReadingData {
  _ValidProviderReadingData(this.bytes) : super('jm');
  final List<int> bytes;

  @override
  String get id => 'reader-settings-live-mode-fixture';

  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) {
    providerLoads++;
    return Stream.value(bytes);
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
    expect(taskRoot.path.split(Platform.pathSeparator).last,
        startsWith('reader-settings-046-'));
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
      largeImagePolicy: ReaderLargeImagePolicy.strictOriginal,
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

  // Native IO/completer cancellation is not driven by FakeAsync alone. These
  // real settings widgets can keep a spinner ticking while that work finishes.
  Future<void> pumpIoFrame(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)));
    tester.binding.scheduleFrame();
    await tester.pump(const Duration(milliseconds: 16));
  }

  Future<void> settleUiAndIo(WidgetTester tester) async {
    var quietFrames = 0;
    for (var i = 0; i < 240; i++) {
      await pumpIoFrame(tester);
      if (tester.binding.hasScheduledFrame) {
        quietFrames = 0;
      } else if (++quietFrames == 3) {
        return;
      }
    }
    fail('Reader/settings widgets did not settle after native IO and frames');
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
    await settleUiAndIo(tester);
    expect(find.byType(PopupMenuItem<String>), findsNWidgets(2));
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, modeTitle));
    await settleUiAndIo(tester);
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
    await settleUiAndIo(tester);
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
      expect(currentConfig().largeImagePolicy,
          ReaderLargeImagePolicy.strictOriginal);

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
      WidgetTester tester, String sourceKey,
      {_FailingReadingData? readingData,
      bool openMenu = true,
      int initialPage = 1}) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final data = readingData ?? _FailingReadingData(sourceKey);
    final page = reader.ComicReadingPage(data, initialPage, 1);
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
      // Finish native cancellation and ImageCache's deferred post-frame handle
      // disposal while this widget's FakeAsync is still alive. In particular,
      // a failed assertion must not abandon an in-flight settings file write.
      await settleUiAndIo(tester);
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getStringList('settings') != null) {
        await flushPersistence(tester);
      }
      for (var i = 0; i < 6; i++) {
        await pumpIoFrame(tester);
      }
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
    await settleUiAndIo(tester);
    expect(data.sourceLoads, greaterThan(0));
    if (openMenu) {
      await tester.tap(find.text('open-settings'));
      await settleUiAndIo(tester);
      expect(find.byType(reader.ReadingSettings), findsOneWidget);
    }
    return (data, logic);
  }

  for (final sourceKey in ['jm', 'local_album']) {
    testWidgets(
        'reader menu persists $sourceKey mode and starts the independent provider pipeline',
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
      expect(currentConfig().largeImagePolicy,
          ReaderLargeImagePolicy.strictOriginal);
      expect(find.byType(ReaderPageImage, skipOffstage: false), findsNothing);
      final currentPages = tester.widgetList<reader.ReaderPreviewPageImage>(
          find.byType(reader.ReaderPreviewPageImage, skipOffstage: false));
      expect(currentPages, isNotEmpty);
      expect(data.providerLoads, greaterThan(0));
      expect(data.sourceLoads, beforeLoads);
      expect(logic.index, beforePage);
      expect(logic.order, beforeChapter);

      App.navigatorKey.currentState!.pop();
      await settleUiAndIo(tester);
      final retries = find.descendant(
          of: find.byType(reader.ReaderPreviewPageImage),
          matching: find.byType(TextButton));
      expect(retries, findsOneWidget);
      final beforeProviderLoads = data.providerLoads;
      await tester.tap(retries);
      await settleUiAndIo(tester);
      expect(data.sourceLoads, beforeLoads);
      expect(data.providerLoads, beforeProviderLoads + 1);
      expect(data.invalidations, 1);
      await tester.tap(find.text('open-settings'));
      await settleUiAndIo(tester);
      expectDisplayed(_imageTitle, _previewTitle);
      expect(logic.index, beforePage);
      expect(logic.order, beforeChapter);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'continuous sharp failure and retry switch immediately to valid preview in the same reader',
      (tester) async {
    appdata.settings[9] = '4';
    // The harness opener sits inside its canvas Listener; disable click-to-turn
    // so that button is not also an unrelated page-navigation gesture.
    appdata.settings[0] = '0';
    // Match the error placeholder's 1.4 aspect to isolate mode-switch anchoring
    // from the separate late-size-hint/geometry contract.
    final bytes = img.encodePng(
        img.Image(width: 400, height: 560)..clear(img.ColorRgb8(20, 100, 180)));
    final fixture = _ValidProviderReadingData(bytes);
    bool drained() =>
        ReaderWholeImageResidency.shared.bytes == 0 &&
        ReaderPreviewImagePool.globalReservedWorkingBytes == 0 &&
        ReaderPreviewImagePool.globalReservedDecodedBytes == 0 &&
        ReaderPageFileLease.activeLeaseCount == 0 &&
        ReaderRasterCache.pendingBytes == 0 &&
        !ImageWorkScheduler.shared.hasWork &&
        ImageWorkScheduler.shared.reservedBytes == 0 &&
        ImageTemporaryPool.shared.reservedBytes == 0;
    // Register first: the shared harness's later teardown unmounts/disposes
    // the one reader before this checks its eventual decoder-owner release.
    addTearDown(() async {
      for (var i = 0; i < 300 && !drained(); i++) {
        await pumpIoFrame(tester);
      }
      expect(drained(), isTrue,
          reason:
              'live mode switch must not retain old errors or image owners');
      expect(ReaderSurfaceDiagnostics.activeSurfaces, 0);
      expect(ReaderSurfaceDiagnostics.residentBytes, 0);
      expect(tester.takeException(), isNull);
    });
    final (data, logic) = await pumpReader(tester, 'jm',
        readingData: fixture, openMenu: false, initialPage: 2);
    expect(data.providerLoads, 0);
    expect(find.text(_loadFailure), findsWidgets);
    expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .where((widget) => widget.image != null),
        isEmpty);
    final beforeRetry = data.sourceLoads;
    final retry = find.widgetWithText(TextButton, '重试').hitTestable().first;
    await tester.tap(retry);
    await settleUiAndIo(tester);
    expect(data.invalidations, 1);
    expect(data.sourceLoads, beforeRetry + 1);
    expect(data.providerLoads, 0);
    expect(find.text(_loadFailure), findsWidgets,
        reason:
            'manual retry deliberately cannot repair the sharp fixture source');

    logic.itemScrollController.jumpTo(index: 1, alignment: -0.1);
    await settleUiAndIo(tester);
    (int, double) anchor() {
      final visible = logic.itemScrollListener.itemPositions.value
          .where(
              (item) => item.itemTrailingEdge > 0 && item.itemLeadingEdge < 1)
          .toList()
        ..sort((a, b) => a.index.compareTo(b.index));
      expect(visible, isNotEmpty);
      return (visible.first.index, visible.first.itemLeadingEdge);
    }

    final beforeAnchor = anchor();
    expect(beforeAnchor.$1, 1);
    final beforePage = logic.index;
    final beforeChapter = logic.order;
    final beforeOffset = logic.scrollController.offset;
    final beforeSources = data.sourceLoads;
    final controller = logic.scrollController;
    final viewport = logic.readerViewportKey.currentContext;
    expect(viewport, isNotNull);
    await tester.tap(find.text('open-settings'));
    await settleUiAndIo(tester);
    final control = selector(_imageTitle);
    await tester.ensureVisible(control);
    await tester.tap(control);
    await settleUiAndIo(tester);
    expect(find.byType(PopupMenuItem<String>), findsNWidgets(2));
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, _previewTitle));
    // Unlike the six error-only cases, real codec IO needs event-loop turns,
    // not pumpAndSettle spinning solely on the widget clock's loading spinner.
    await tester.pump(const Duration(milliseconds: 350));
    await flushPersistence(tester);
    for (var i = 0; i < 100 && data.providerLoads == 0; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expectDisplayed(_imageTitle, _previewTitle);
    expect(data.providerLoads, greaterThan(0),
        reason:
            'the new pipeline starts while the settings dialog remains open');
    // Pop only the settings dialog; the reader itself is never remounted.
    App.navigatorKey.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 350));
    final actualPixels = find.descendant(
        of: find.byType(reader.ReaderPreviewPageImage),
        matching: find.byWidgetPredicate(
            (widget) => widget is RawImage && widget.image != null));
    for (var i = 0;
        i < 300 && actualPixels.hitTestable().evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(actualPixels.hitTestable(), findsWidgets,
        reason:
            'the menu selection alone must reveal actual provider pixels, without reader re-entry');
    for (final raw in tester.widgetList<RawImage>(actualPixels)) {
      expect((raw.image!.width, raw.image!.height), (400, 560));
    }
    expect(StateController.find<reader.ComicReadingPageLogic>(), same(logic));
    expect(logic.scrollController, same(controller));
    expect(logic.readerViewportKey.currentContext, same(viewport));
    expect(logic.index, beforePage);
    expect(logic.order, beforeChapter);
    expect(logic.scrollController.offset, closeTo(beforeOffset, 0.02));
    final afterAnchor = anchor();
    expect(afterAnchor.$1, beforeAnchor.$1);
    expect(afterAnchor.$2, closeTo(beforeAnchor.$2, 0.001));
    expect(data.providerLoads, greaterThan(0));
    expect(data.sourceLoads, beforeSources);
    expect(currentConfig().comic, ReaderDisplayMode.previewFirst);
    expect(currentConfig().largeImagePolicy,
        ReaderLargeImagePolicy.strictOriginal);
    expect(find.byType(ReaderPageImage, skipOffstage: false), findsNothing);
    expect(find.byType(ReaderWholeImage, skipOffstage: false), findsNothing);
    expect(find.text(_loadFailure, skipOffstage: false), findsNothing);
    expect(find.byType(ReaderImageSurface, skipOffstage: false), findsNothing);
    expect(ReaderSurfaceDiagnostics.activeSurfaces, 0);
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(tester.takeException(), isNull);
  });

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
