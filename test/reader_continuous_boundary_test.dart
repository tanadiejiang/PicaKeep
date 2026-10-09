import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/scrollable_list/src/scrollable_positioned_list.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';

class _BoundaryReadingData extends ReadingData {
  _BoundaryReadingData(this.file);

  final File file;
  int chapters = 3;
  int pages = 2;
  double imageHeight = 2400;

  List<String> get urls => List.generate(pages, (i) => '$i');
  @override
  String get id => 'reader-boundary-test';
  @override
  String get downloadId => id;
  @override
  String get sourceKey => 'jm';
  @override
  String get title => 'Reader boundary fixture';
  @override
  ComicType get comicType => ComicType.jm;
  @override
  FavoriteType get favoriteType => FavoriteType.jm;
  @override
  bool get hasEp => chapters > 0;
  @override
  Map<String, String>? get eps =>
      hasEp ? {for (var i = 1; i <= chapters; i++) '$i': 'Chapter $i'} : null;
  @override
  bool get downloaded => false;
  @override
  Future<List<String>> loadEpNetwork(int ep) async => urls;
  @override
  String buildImageKey(int ep, int page, String url) => '$id-$ep-$page';
  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) =>
      Stream.value(const <int>[]);
  @override
  Future<ReaderPageSource> resolvePageSource(
          int ep, int page, String url) async =>
      _BoundaryPageSource(
          file,
          ReaderPageIdentity(
              sourceKey: sourceKey,
              workId: id,
              downloadId: downloadId,
              episode: ep,
              page: page,
              sourceVersion: 'fixture'),
          Size(400, imageHeight));
}

class _BoundaryPageSource extends FileReaderPageSource
    implements RasterReaderPageSource {
  _BoundaryPageSource(File file, ReaderPageIdentity identity, this.size)
      : rasterLocator = file,
        super(identity: identity, file: file);

  final Size size;
  @override
  final File rasterLocator;
  @override
  ReaderRasterBackend get rasterBackend => _BoundaryBackend(size);
  @override
  Future<ReaderRasterMetadata> openRasterMetadata() async =>
      _BoundaryBackend(size).metadata;
}

class _BoundaryBackend extends ReaderRasterBackend {
  const _BoundaryBackend(this.size);
  final Size size;
  ReaderRasterMetadata get metadata => ReaderRasterMetadata(
      size: size, animated: false, format: 'fixture', workingBytes: 1);
  @override
  bool get requiresFileBacking => false;
  @override
  Future<ReaderRasterMetadata> probe(File file) async => metadata;
  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    if (isCancelled()) throw const ImageWorkCancelled();
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
        Rect.fromLTWH(0, 0, demand.outputWidth.toDouble(),
            demand.outputHeight.toDouble()),
        Paint()..color = Colors.green);
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(demand.outputWidth, demand.outputHeight);
    } finally {
      picture.dispose();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory taskRoot;
  late File original;
  late List<String> savedSettings;
  late _BoundaryReadingData data;
  late ComicReadingPage page;
  late ComicReadingPageLogic logic;
  late bool savedLogging;
  late List<String> savedImplicit;

  setUpAll(() async {
    taskRoot = await Directory.systemTemp.createTemp('reader-boundary-045-');
    App.dataPath = taskRoot.path;
    App.cachePath = '${taskRoot.path}/cache';
    await Directory(App.cachePath).create(recursive: true);
    original = await File('${taskRoot.path}/original.png').writeAsBytes(
        base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='));
  });
  tearDownAll(() async {
    if (await taskRoot.exists()) await taskRoot.delete(recursive: true);
  });
  setUp(() {
    savedSettings = List.of(appdata.settings);
    savedImplicit = List.of(appdata.implicitData);
    savedLogging = LogManager.recordingEnabled;
    LogManager.recordingEnabled = false;
    appdata.settings[9] = '4';
    appdata.settings[43] = '0';
    appdata.settings[49] = '0';
    appdata.settings[55] = '0';
    TapController.reset();
    TapController.lastScrollTime = DateTime(2023);
    data = _BoundaryReadingData(original);
    page = ComicReadingPage(data, 1, 1);
    logic = StateController.find<ComicReadingPageLogic>();
    logic.urls = data.urls;
    logic.isLoading = false;
    logic.scrollManager = ScrollManager(logic);
  });
  tearDown(() {
    logic.clearPhotoViewControllers();
    logic.pageController.dispose();
    logic.scrollController.dispose();
    logic.focusNode.dispose();
    logic.dispose();
    appdata.settings = savedSettings;
    appdata.implicitData = savedImplicit;
    TapController.reset();
    LogManager.recordingEnabled = savedLogging;
  });

  Future<void> finishRasterWork(WidgetTester tester) async {
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
    }
  }

  Future<void> pumpReader(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await finishRasterWork(tester);
    });
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      home: Scaffold(body: Builder(builder: (context) {
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) => TapController.onTapDown(event, context),
          onPointerMove: TapController.onPointerMove,
          onPointerUp: (event) => TapController.onTapUp(event, context),
          onPointerCancel: TapController.onTapCancel,
          child: StateBuilder<ComicReadingPageLogic>(builder: (logic) {
            return Stack(children: [
              if (!logic.isLoading)
                page.buildComicView(logic, context, 'boundary'),
            ]);
          }),
        );
      })),
    ));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
      if (ReaderSurfaceDiagnostics.residentBytes > 0 &&
          !ImageWorkScheduler.shared.hasWork) {
        break;
      }
    }
    await tester.pumpAndSettle();
    expect(
        logic.readingMethod == ReadingMethod.topToBottomContinuously
            ? logic.scrollController.hasClients
            : logic.pageController.hasClients,
        isTrue);
  }

  Future<void> goToBottom(WidgetTester tester) async {
    logic.scrollController
        .jumpTo(logic.scrollController.position.maxScrollExtent);
    await tester.pumpAndSettle();
  }

  OverscrollNotification overscroll(WidgetTester tester, double distance,
      {bool drag = true,
      Axis axis = Axis.vertical,
      BuildContext? dispatchFrom}) {
    final position = logic.scrollController.position;
    final metrics = FixedScrollMetrics(
      minScrollExtent: position.minScrollExtent,
      maxScrollExtent: position.maxScrollExtent,
      pixels:
          distance > 0 ? position.maxScrollExtent : position.minScrollExtent,
      viewportDimension: position.viewportDimension,
      axisDirection:
          axis == Axis.vertical ? AxisDirection.down : AxisDirection.right,
      devicePixelRatio: 1,
    );
    final context = tester.element(find.byType(ScrollablePositionedList));
    final notification = OverscrollNotification(
      metrics: metrics,
      context: context,
      overscroll: distance,
      dragDetails: drag
          ? DragUpdateDetails(
              delta: Offset(0, -distance),
              globalPosition: const Offset(200, 500))
          : null,
    );
    notification.dispatch(dispatchFrom ?? context);
    return notification;
  }

  testWidgets('last chapter overscroll preserves the long tail image position',
      (tester) async {
    logic.order = data.chapters;
    await pumpReader(tester);
    await goToBottom(tester);
    final before = logic.itemScrollListener.itemPositions.value
        .singleWhere((position) => position.index == data.pages - 1);
    expect(before.itemLeadingEdge, lessThan(-1));
    expect(before.itemTrailingEdge, closeTo(1, .02));
    final offset = logic.scrollController.offset;
    final index = logic.index;
    await tester.dragFrom(const Offset(200, 650), const Offset(0, -350));
    await finishRasterWork(tester);
    final after = logic.itemScrollListener.itemPositions.value
        .singleWhere((position) => position.index == data.pages - 1);
    expect(after.itemLeadingEdge, closeTo(before.itemLeadingEdge, .02));
    expect(logic.scrollController.offset, closeTo(offset, .02));
    expect(logic.index, index);
    expect(logic.order, data.chapters);
    for (var i = 0; i < 3; i++) {
      await tester.dragFrom(const Offset(200, 650), const Offset(0, -60));
      await finishRasterWork(tester);
    }
    expect(logic.scrollController.offset, closeTo(offset, .02));
    await tester.dragFrom(const Offset(200, 300), const Offset(0, 350));
    await finishRasterWork(tester);
    expect(logic.scrollController.offset, lessThan(offset - 100));
  });

  for (final height in [400.0, 800.0, 2400.0]) {
    for (final chapters in [0, 1, 3]) {
      testWidgets('first boundary preserves position for $height/$chapters',
          (tester) async {
        data.imageHeight = height;
        data.chapters = chapters;
        data.pages = 1;
        logic.urls = data.urls;
        var historyUpdates = 0;
        logic.addIndexChangeCallback((_) => historyUpdates++);
        await pumpReader(tester);
        final before = logic.scrollController.offset;
        final updates = historyUpdates;
        logic.jumpToLastChapter();
        await tester.dragFrom(const Offset(200, 200), const Offset(0, 350));
        await finishRasterWork(tester);
        expect(logic.order, 1);
        expect(logic.scrollController.offset, closeTo(before, .02));
        expect(historyUpdates, updates);
      });
    }
  }

  testWidgets('small pulls do not add across separate physical gestures',
      (tester) async {
    await pumpReader(tester);
    await goToBottom(tester);
    for (var i = 0; i < 3; i++) {
      await tester.dragFrom(const Offset(200, 650), const Offset(0, -60));
      await finishRasterWork(tester);
      expect(logic.order, 1);
    }
    await tester.dragFrom(const Offset(200, 650), const Offset(0, -250));
    await tester.pump();
    expect(logic.order, 2);
  });

  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets('$kind drag accepts only one chapter before pointer up',
        (tester) async {
      await pumpReader(tester);
      await goToBottom(tester);
      final gesture =
          await tester.startGesture(const Offset(200, 650), kind: kind);
      await gesture.moveBy(const Offset(0, -140));
      await tester.pump();
      expect(logic.order, 2);
      expect(logic.scrollController.hasClients, isFalse);
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      expect(tester.takeException(), isNull);
      logic.urls = data.urls;
      logic.isLoading = false;
      logic.update();
      await finishRasterWork(tester);
      await goToBottom(tester);
      await gesture.moveBy(const Offset(0, -100));
      overscroll(tester, 150);
      // A late release-progress value still belongs to the consumed gesture.
      logic.fABValue = 60;
      await gesture.up();
      await tester.pump();
      expect(logic.order, 2);
      expect(logic.fABValue, 0);
      final next =
          await tester.startGesture(const Offset(200, 650), kind: kind);
      overscroll(tester, 100);
      await next.up();
      await tester.pump();
      expect(logic.order, 3);
    });
  }

  testWidgets('rebuild preserves partial pull but reverse motion clears it',
      (tester) async {
    await pumpReader(tester);
    await goToBottom(tester);
    final gesture = await tester.startGesture(const Offset(200, 650));
    overscroll(tester, 44);
    logic.tools = true;
    logic.update();
    await tester.pump();
    overscroll(tester, 45);
    expect(logic.order, 2);
    await gesture.up();
    logic.urls = data.urls;
    logic.isLoading = false;
    logic.update();
    await finishRasterWork(tester);
    await goToBottom(tester);
    final reverse = await tester.startGesture(const Offset(200, 650));
    overscroll(tester, 60);
    await reverse.moveBy(const Offset(0, 30));
    await tester.pump();
    overscroll(tester, 40);
    expect(logic.order, 2);
    await reverse.cancel();
  });

  testWidgets('ordinary scrolling away from a boundary clears its partial pull',
      (tester) async {
    await pumpReader(tester);
    await goToBottom(tester);
    final maximum = logic.scrollController.position.maxScrollExtent;
    final gesture = await tester.startGesture(const Offset(200, 550));
    overscroll(tester, 60);
    await gesture.moveBy(const Offset(0, 180));
    await tester.pump();
    final away = logic.scrollController.offset;
    expect(away, lessThan(maximum - 100));
    expect(logic.order, 1);
    await gesture.moveBy(Offset(0, -(maximum - away)));
    await tester.pump();
    expect(logic.scrollController.offset, closeTo(maximum, .02));
    overscroll(tester, 40);
    expect(logic.order, 1,
        reason: 'The first 60 pixels must not survive leaving the boundary');
    overscroll(tester, 49);
    expect(logic.order, 2);
    await gesture.up();
  });

  for (final foreign in ['axis', 'depth']) {
    testWidgets('$foreign notifications do not contribute to a reader pull',
        (tester) async {
      await pumpReader(tester);
      await goToBottom(tester);
      final offset = logic.scrollController.offset;
      final gesture = await tester.startGesture(const Offset(200, 650));
      overscroll(tester, 60);
      final notification = overscroll(tester, 150,
          axis: foreign == 'axis' ? Axis.horizontal : Axis.vertical,
          dispatchFrom: foreign == 'depth'
              ? tester.element(find.byType(ReaderImageSurface).first)
              : null);
      if (foreign == 'depth') expect(notification.depth, greaterThan(0));
      expect(logic.order, 1);
      expect(logic.scrollController.offset, closeTo(offset, .02));
      overscroll(tester, 20);
      expect(logic.order, 1);
      overscroll(tester, 10);
      expect(logic.order, 2,
          reason: 'Only the three valid vertical reader pulls contribute');
      await gesture.up();
    });
  }

  testWidgets('a new single pointer at non-unit scale cannot change chapters',
      (tester) async {
    await pumpReader(tester);
    await goToBottom(tester);
    final controller = logic.photoViewControllers[0]!;
    final a = await tester.startGesture(const Offset(150, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(250, 400), pointer: 2);
    await a.moveTo(const Offset(110, 400));
    await b.moveTo(const Offset(290, 400));
    await tester.pump();
    await a.moveTo(const Offset(60, 400));
    await b.moveTo(const Offset(340, 400));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(controller.scale, greaterThan(1.05));
    expect(logic.noScroll, isFalse);
    final offset = logic.scrollController.offset;
    final position = controller.position;
    final single =
        await tester.startGesture(const Offset(200, 600), pointer: 3);
    await single.moveBy(const Offset(0, -140));
    await tester.pump();
    overscroll(tester, 150);
    expect(logic.order, 1);
    expect(logic.scrollController.offset, closeTo(offset, .02));
    expect((controller.position - position).distance, greaterThan(20));
    await single.cancel();
    final c = await tester.startGesture(const Offset(60, 400), pointer: 4);
    final d = await tester.startGesture(const Offset(340, 400), pointer: 5);
    await c.moveTo(const Offset(110, 400));
    await d.moveTo(const Offset(290, 400));
    await tester.pump();
    await c.moveTo(const Offset(185, 400));
    await d.moveTo(const Offset(215, 400));
    await tester.pump();
    await c.up();
    await d.up();
    await finishRasterWork(tester);
    await tester.pumpAndSettle();
    expect(controller.scale, closeTo(1, .001));
    final next = await tester.startGesture(const Offset(200, 650), pointer: 6);
    overscroll(tester, 100);
    await next.up();
    expect(logic.order, 2);
  });

  testWidgets('mouse wheel scrolls the list and moves PhotoView at both ends',
      (tester) async {
    logic.order = 2;
    await pumpReader(tester);
    final controller = logic.photoViewControllers[0]!;
    final positions = <Offset>[];
    final subscription = controller.outputStateStream
        .listen((value) => positions.add(value.position));
    addTearDown(subscription.cancel);
    Future<void> wheel(double delta) async {
      await tester.sendEventToBinding(PointerScrollEvent(
          viewId: tester.view.viewId,
          kind: PointerDeviceKind.mouse,
          position: const Offset(200, 400),
          scrollDelta: Offset(0, delta)));
      await finishRasterWork(tester);
      await tester.pumpAndSettle();
    }

    final initialPosition = controller.position;
    await wheel(120);
    expect(logic.mouseScroll, isTrue);
    expect(logic.scrollController.offset, greaterThan(50));
    expect(controller.position, initialPosition);
    expect(logic.order, 2);
    await wheel(4000);
    final maximum = logic.scrollController.position.maxScrollExtent;
    expect(logic.scrollController.offset, closeTo(maximum, .02));
    final bottomPosition = controller.position;
    positions.clear();
    await wheel(180);
    expect(logic.scrollController.offset, closeTo(maximum, .02));
    expect(positions, contains(bottomPosition - const Offset(0, 180)));
    expect(controller.position, Offset.zero,
        reason: 'PhotoView clamps the requested displacement at fitted scale');
    expect(logic.order, 2);
    await wheel(-180);
    expect(logic.scrollController.offset, lessThan(maximum - 50));
    await wheel(-4000);
    expect(logic.scrollController.offset, closeTo(0, .02));
    final topPosition = controller.position;
    positions.clear();
    await wheel(-180);
    expect(logic.scrollController.offset, closeTo(0, .02));
    expect(positions, contains(topPosition + const Offset(0, 180)));
    expect(controller.position, Offset.zero);
    expect(logic.order, 2);
    expect(logic.urls, hasLength(data.pages));
  });

  testWidgets('wheel at a zoomed boundary moves the actual PhotoView position',
      (tester) async {
    logic.order = 2;
    await pumpReader(tester);
    await goToBottom(tester);
    final controller = logic.photoViewControllers[0]!;
    final a = await tester.startGesture(const Offset(150, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(250, 400), pointer: 2);
    await a.moveTo(const Offset(110, 400));
    await b.moveTo(const Offset(290, 400));
    await tester.pump();
    await a.moveTo(const Offset(60, 400));
    await b.moveTo(const Offset(340, 400));
    await tester.pump();
    await a.up();
    await b.up();
    await finishRasterWork(tester);
    await tester.pumpAndSettle();
    expect(controller.scale, greaterThan(1.05));
    final offset = logic.scrollController.offset;
    final position = controller.position;
    await tester.sendEventToBinding(PointerScrollEvent(
        viewId: tester.view.viewId,
        kind: PointerDeviceKind.mouse,
        position: const Offset(200, 400),
        scrollDelta: const Offset(0, 180)));
    await finishRasterWork(tester);
    await tester.pumpAndSettle();
    expect(controller.position.dy, closeTo(position.dy - 180, .02));
    expect(logic.scrollController.offset, closeTo(offset, .02));
    expect(logic.order, 2);
    expect(logic.urls, hasLength(data.pages));
  });

  testWidgets(
      'trackpad pan zoom scrolls normally and clamps at both boundaries',
      (tester) async {
    logic.order = 2;
    await pumpReader(tester);
    final gesture = await tester.startGesture(const Offset(200, 400),
        kind: PointerDeviceKind.trackpad, pointer: 9);
    await gesture.moveBy(const Offset(0, -120));
    await finishRasterWork(tester);
    await tester.pumpAndSettle();
    expect(logic.scrollController.offset, greaterThan(50));
    expect(logic.order, 2);
    await gesture.moveBy(const Offset(0, -4000));
    await finishRasterWork(tester);
    await tester.pumpAndSettle();
    final maximum = logic.scrollController.position.maxScrollExtent;
    expect(logic.scrollController.offset, closeTo(maximum, .02));
    await gesture.moveBy(const Offset(0, -200));
    await finishRasterWork(tester);
    await tester.pumpAndSettle();
    expect(logic.scrollController.offset, closeTo(maximum, .02));
    expect(logic.order, 2);
    await gesture.moveBy(const Offset(0, 120));
    await finishRasterWork(tester);
    await tester.pumpAndSettle();
    expect(logic.scrollController.offset, lessThan(maximum - 50));
    await gesture.moveBy(const Offset(0, 4000));
    await finishRasterWork(tester);
    await tester.pumpAndSettle();
    expect(logic.scrollController.offset, closeTo(0, .02));
    await gesture.moveBy(const Offset(0, 200));
    await finishRasterWork(tester);
    await tester.pumpAndSettle();
    expect(logic.scrollController.offset, closeTo(0, .02));
    expect(logic.order, 2);
    await gesture.up();
    expect(logic.urls, hasLength(data.pages));
    expect(TapController.fingers, 0);
  });

  testWidgets('trackpad scaling changes PhotoView without scrolling the list',
      (tester) async {
    logic.order = 2;
    await pumpReader(tester);
    final controller = logic.photoViewControllers[0]!;
    final offset = logic.scrollController.offset;
    final position = controller.position;
    final gesture = await tester.startGesture(const Offset(200, 400),
        kind: PointerDeviceKind.trackpad, pointer: 9);
    await gesture.panZoomUpdate(const Offset(200, 400), scale: 1.3);
    await tester.pump();
    await gesture.panZoomUpdate(const Offset(200, 400),
        scale: 1.8, pan: const Offset(0, -100));
    await tester.pump();
    expect(controller.scale, greaterThan(1.05));
    expect((controller.position - position).distance, greaterThan(20));
    expect(logic.scrollController.offset, closeTo(offset, .02));
    expect(logic.order, 2);
    await gesture.up();
    await finishRasterWork(tester);
    await tester.pumpAndSettle();
    expect(logic.order, 2);
    expect(logic.urls, hasLength(data.pages));
    expect(TapController.fingers, 0);
  });

  testWidgets('multi pointer invalidation lasts until all pointers leave',
      (tester) async {
    await pumpReader(tester);
    await goToBottom(tester);
    final a = await tester.startGesture(const Offset(150, 500), pointer: 1);
    overscroll(tester, 60);
    final b = await tester.startGesture(const Offset(250, 500), pointer: 2);
    await a.moveBy(const Offset(-20, 0));
    await b.moveBy(const Offset(20, 0));
    await tester.pump();
    await b.up();
    await tester.pump();
    await a.moveBy(const Offset(0, -150));
    overscroll(tester, 100);
    logic.fABValue = 60;
    await a.up();
    await tester.pump();
    expect(logic.order, 1);
    expect(logic.noScroll, isFalse);
    final c = await tester.startGesture(const Offset(200, 650), pointer: 3);
    overscroll(tester, 100);
    await c.up();
    expect(logic.order, 2);
  });

  testWidgets(
      'cancel and release discard later inertia and stale chapter events',
      (tester) async {
    await pumpReader(tester);
    await goToBottom(tester);
    final gesture = await tester.startGesture(const Offset(200, 650));
    overscroll(tester, 60);
    await gesture.cancel();
    overscroll(tester, 150, drag: false);
    overscroll(tester, 150);
    expect(logic.order, 1);
    final next = await tester.startGesture(const Offset(200, 650));
    overscroll(tester, 150, axis: Axis.horizontal);
    expect(logic.order, 1);
    final oldNotification = OverscrollNotification(
      context: tester.element(find.byType(ScrollablePositionedList)),
      metrics: logic.scrollController.position,
      overscroll: 150,
      dragDetails: DragUpdateDetails(
          delta: const Offset(0, -150), globalPosition: const Offset(200, 500)),
    );
    logic.order = 2;
    logic.handleContinuousChapterScroll(oldNotification, 1);
    expect(logic.order, 2);
    await next.up();
    overscroll(tester, 150, drag: false);
    expect(logic.order, 2);
  });

  testWidgets('loading and mode changes invalidate the entire current gesture',
      (tester) async {
    await pumpReader(tester);
    await goToBottom(tester);
    final gesture = await tester.startGesture(const Offset(200, 650));
    overscroll(tester, 60);
    logic.isLoading = true;
    overscroll(tester, 150);
    logic.isLoading = false;
    overscroll(tester, 150);
    expect(logic.order, 1);
    await gesture.up();
    final next = await tester.startGesture(const Offset(200, 650));
    overscroll(tester, 60);
    appdata.settings[9] = '1';
    logic.syncContinuousChapterGesture();
    appdata.settings[9] = '4';
    overscroll(tester, 150);
    expect(logic.order, 1);
    await next.up();
  });

  testWidgets(
      'non-first chapter top pull moves to exactly the previous chapter',
      (tester) async {
    logic.order = 2;
    await pumpReader(tester);
    await tester.dragFrom(const Offset(200, 200), const Offset(0, 250));
    await tester.pump();
    expect(logic.order, 1);
  });

  testWidgets(
      'release progress still accepts a chapter before clearing the gesture',
      (tester) async {
    await pumpReader(tester);
    await goToBottom(tester);
    final gesture = await tester.startGesture(const Offset(200, 650));
    logic.fABValue = 60;
    await gesture.up();
    await tester.pump();
    expect(logic.order, 2);
    expect(logic.fABValue, 0);
  });

  testWidgets('explicit continuous page jumps still position the selected page',
      (tester) async {
    await pumpReader(tester);
    await goToBottom(tester);
    await finishRasterWork(tester);
    logic.jumpToPage(1);
    await finishRasterWork(tester);
    logic.jumpToPage(2, true);
    expect(logic.index, 2);
    await finishRasterWork(tester);
    expect(
        logic.itemScrollListener.itemPositions.value
            .singleWhere((item) => item.index == 1)
            .itemLeadingEdge,
        inInclusiveRange(0, 1));
  });

  for (final mode in ['1', '2', '3', '5', '6']) {
    for (final pages in [3, 4]) {
      for (final firstSingle
          in mode == '5' || mode == '6' ? [false, true] : [false]) {
        testWidgets(
            'pagination $mode/$pages/$firstSingle keeps end sentinels valid',
            (tester) async {
          appdata.settings[9] = mode;
          appdata.implicitData[1] = firstSingle ? '1' : '0';
          data.pages = pages;
          data.imageHeight = 600;
          logic.urls = data.urls;
          logic.order = data.chapters;
          await pumpReader(tester);
          final two = logic.readingMethod.isTwoPage;
          var validEnd = two ? (pages + 1) ~/ 2 : pages;
          if (two && pages.isEven && firstSingle) validEnd++;
          logic.pageController.jumpToPage(validEnd + 1);
          await finishRasterWork(tester);
          expect(logic.pageController.page, closeTo(validEnd.toDouble(), .02));
          expect(logic.order, data.chapters);
          logic.order = 1;
          logic.pageController.jumpToPage(0);
          await finishRasterWork(tester);
          expect(logic.pageController.page, closeTo(1, .02));
          expect(logic.order, 1);
        });
      }
    }
  }
}
