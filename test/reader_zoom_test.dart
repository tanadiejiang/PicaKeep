import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

class _MemoryReadingData extends ReadingData {
  _MemoryReadingData(this.bytes);

  final Uint8List bytes;
  ImageProvider? provider;
  bool hasChapters = false;

  @override
  String get id => 'zoom-test';
  @override
  String get downloadId => id;
  @override
  String get sourceKey => 'pixiv';
  @override
  String get title => '缩放回归';
  @override
  ComicType get comicType => ComicType.pixiv;
  @override
  FavoriteType get favoriteType => FavoriteType.pixiv;
  @override
  bool get hasEp => hasChapters;
  @override
  Map<String, String>? get eps =>
      hasChapters ? {'1': 'First', '2': 'Second'} : null;
  @override
  bool get downloaded => false;
  @override
  Future<List<String>> loadEpNetwork(int ep) async => ['0', '1'];
  @override
  String buildImageKey(int ep, int page, String url) => '$id-$page';
  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) =>
      Stream.value(bytes);
  @override
  ImageProvider createImageProvider(int ep, int page, String url,
          {StreamImageAbortSignal? abortSignal}) =>
      provider ?? MemoryImage(bytes);
}

class _DeferredImage extends ImageProvider<_DeferredImage> {
  _DeferredImage(this.image);
  final Future<ui.Image> image;

  @override
  Future<_DeferredImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
          _DeferredImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(
          image.then((value) => ImageInfo(image: value)));
}

Future<Uint8List> _imageBytes() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 400, 600), Paint()..color = Colors.blue);
  final picture = recorder.endRecording();
  final image = await picture.toImage(400, 600);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List bytes;
  late List<String> originalSettings;
  late ComicReadingPage page;
  late ComicReadingPageLogic logic;

  setUpAll(() async {
    bytes = await _imageBytes();
  });
  setUp(() {
    originalSettings = List.of(appdata.settings);
    appdata.settings[9] = '1';
    appdata.settings[43] = '0';
    appdata.settings[49] = '1';
    appdata.settings[55] = '0';
    TapController.reset();
    TapController.lastScrollTime = DateTime(2023);
    page = ComicReadingPage(_MemoryReadingData(bytes), 1, 1);
    logic = StateController.find<ComicReadingPageLogic>();
    logic.urls = ['0', '1'];
    logic.isLoading = false;
  });
  tearDown(() {
    logic.clearPhotoViewControllers();
    logic.pageController.dispose();
    logic.scrollController.dispose();
    logic.focusNode.dispose();
    logic.dispose();
    appdata.settings = originalSettings;
    TapController.reset();
  });

  Future<void> pumpReader(WidgetTester tester, {bool preload = true}) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      home: Scaffold(body: Builder(builder: (context) {
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) => TapController.onTapDown(e, context),
          onPointerMove: TapController.onPointerMove,
          onPointerUp: (e) => TapController.onTapUp(e, context),
          onPointerCancel: TapController.onTapCancel,
          child: Stack(children: [page.buildComicView(logic, context, 'zoom')]),
        );
      })),
    ));
    if (preload) {
      await tester.runAsync(
          () => precacheImage(MemoryImage(bytes), App.globalContext!));
      await tester.pumpAndSettle();
    } else {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('reader pinch zooms and returns to fitted size', (tester) async {
    await pumpReader(tester);
    final controller = logic.photoViewControllers[1]!;
    final initial = controller.scale!;
    final a = await tester.startGesture(const Offset(150, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(250, 400), pointer: 2);
    await a.moveTo(const Offset(120, 400));
    await b.moveTo(const Offset(280, 400));
    await tester.pump();
    await a.moveTo(const Offset(80, 400));
    await b.moveTo(const Offset(320, 400));
    await tester.pump();
    expect(controller.scale, greaterThan(initial));
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(logic.index, 1);
    expect(logic.tools, isFalse);
    final c = await tester.startGesture(const Offset(80, 400), pointer: 3);
    final d = await tester.startGesture(const Offset(320, 400), pointer: 4);
    await c.moveTo(const Offset(140, 400));
    await d.moveTo(const Offset(260, 400));
    await tester.pump();
    await c.moveTo(const Offset(185, 400));
    await d.moveTo(const Offset(215, 400));
    await tester.pump();
    await c.up();
    await d.up();
    await tester.pumpAndSettle();
    expect(controller.scale, closeTo(initial, .001));
  });

  testWidgets('reader double tap zooms in then resets', (tester) async {
    await pumpReader(tester);
    final controller = logic.photoViewControllers[1]!;
    final initial = controller.scale!;
    await tester.tapAt(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    expect(controller.scale, greaterThan(initial));
    await tester.tapAt(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    expect(controller.scale, closeTo(initial, .001));
  });

  testWidgets('a two finger interaction never triggers a single tap',
      (tester) async {
    await pumpReader(tester);
    final a = await tester.startGesture(const Offset(150, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(250, 400), pointer: 2);
    await tester.pump(const Duration(milliseconds: 50));
    await a.up();
    await b.up();
    await tester.pump(const Duration(milliseconds: 220));
    expect(logic.tools, isFalse);
    expect(logic.index, 1);
  });

  testWidgets('a slow two finger pinch does not activate long press zoom',
      (tester) async {
    appdata.settings[55] = '1';
    await pumpReader(tester);
    final controller = logic.photoViewControllers[1]!;
    final initial = controller.scale!;
    final a = await tester.startGesture(const Offset(150, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(250, 400), pointer: 2);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(controller.scale, closeTo(initial, .001));
    await a.moveTo(const Offset(120, 400));
    await b.moveTo(const Offset(280, 400));
    await tester.pump();
    await a.moveTo(const Offset(80, 400));
    await b.moveTo(const Offset(320, 400));
    await tester.pump();
    expect(controller.scale, greaterThan(initial));
    await a.up();
    await b.up();
    await tester.pump(const Duration(milliseconds: 220));
    expect(logic.tools, isFalse);
  });

  testWidgets('widely separated taps are not a double tap', (tester) async {
    await pumpReader(tester);
    final controller = logic.photoViewControllers[1]!;
    final initial = controller.scale!;
    await tester.tapAt(const Offset(150, 350));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(const Offset(250, 450));
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    expect(controller.scale, closeTo(initial, .001));
  });

  testWidgets('cancelling one pinch finger does not tap with the remaining one',
      (tester) async {
    appdata.settings[55] = '1';
    await pumpReader(tester);
    final a = await tester.startGesture(const Offset(150, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(250, 400), pointer: 2);
    await b.cancel();
    await tester.pump(const Duration(milliseconds: 350));
    await a.up();
    await tester.pump(const Duration(milliseconds: 220));
    expect(TapController.fingers, 0);
    expect(logic.tools, isFalse);
    expect(logic.index, 1);
    await tester.tapAt(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 220));
    expect(logic.tools, isTrue);
  });

  testWidgets('a single finger long press still zooms then restores',
      (tester) async {
    appdata.settings[55] = '1';
    await pumpReader(tester);
    final controller = logic.photoViewControllers[1]!;
    final initial = controller.scale!;
    final gesture = await tester.startGesture(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(controller.scale, greaterThan(initial));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.scale, closeTo(initial, .001));
    expect(logic.tools, isFalse);
  });

  testWidgets('a reader session reset cancels its pending single tap',
      (tester) async {
    await pumpReader(tester);
    await tester.tapAt(const Offset(200, 400));
    TapController.reset();
    await tester.pump(const Duration(milliseconds: 220));
    expect(logic.tools, isFalse);
    expect(TapController.fingers, 0);
  });

  for (final fit in ['0', '1', '2']) {
    testWidgets('pinch remains available with reader fit setting $fit',
        (tester) async {
      appdata.settings[41] = fit;
      await pumpReader(tester);
      final controller = logic.photoViewControllers[1]!;
      final initial = controller.scale!;
      final a = await tester.startGesture(const Offset(150, 400), pointer: 1);
      final b = await tester.startGesture(const Offset(250, 400), pointer: 2);
      await a.moveTo(const Offset(110, 400));
      await b.moveTo(const Offset(290, 400));
      await tester.pump();
      await a.moveTo(const Offset(60, 400));
      await b.moveTo(const Offset(340, 400));
      await tester.pump();
      expect(controller.scale, greaterThan(initial));
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(logic.index, 1);
      expect(logic.tools, isFalse);
    });
  }

  testWidgets('touches while the reader image loads do not break later pinch',
      (tester) async {
    appdata.settings[55] = '1';
    final image = Completer<ui.Image>();
    (page.readingData as _MemoryReadingData).provider =
        _DeferredImage(image.future);
    await pumpReader(tester, preload: false);
    final a = await tester.startGesture(const Offset(150, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(250, 400), pointer: 2);
    await tester.pump(const Duration(milliseconds: 350));
    await a.up();
    await b.up();
    await tester.pump(const Duration(milliseconds: 220));
    expect(logic.tools, isFalse);
    final codec = await tester.runAsync(() => ui.instantiateImageCodec(bytes));
    final frame = await tester.runAsync(() => codec!.getNextFrame());
    image.complete(frame!.image);
    codec!.dispose();
    await tester.pumpAndSettle();
    final controller = logic.photoViewControllers[1]!;
    final initial = controller.scale!;
    final c = await tester.startGesture(const Offset(150, 400), pointer: 3);
    final d = await tester.startGesture(const Offset(250, 400), pointer: 4);
    await c.moveTo(const Offset(110, 400));
    await d.moveTo(const Offset(290, 400));
    await tester.pump();
    await c.moveTo(const Offset(60, 400));
    await d.moveTo(const Offset(340, 400));
    await tester.pump();
    expect(controller.scale, greaterThan(initial));
    await c.up();
    await d.up();
    await tester.pumpAndSettle();
  });

  testWidgets('flipping to another reader page preserves its pinch gesture',
      (tester) async {
    await pumpReader(tester);
    await tester.dragFrom(const Offset(340, 400), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(logic.index, 2);
    final controller = logic.photoViewControllers[2]!;
    final initial = controller.scale!;
    final a = await tester.startGesture(const Offset(150, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(250, 400), pointer: 2);
    await a.moveTo(const Offset(110, 400));
    await b.moveTo(const Offset(290, 400));
    await tester.pump();
    await a.moveTo(const Offset(60, 400));
    await b.moveTo(const Offset(340, 400));
    await tester.pump();
    expect(controller.scale, greaterThan(initial));
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(logic.index, 2);
  });

  for (final cancel in [false, true]) {
    testWidgets(
        'continuous pinch ${cancel ? 'cancel' : 'release'} clears scroll lock without chapter jump',
        (tester) async {
      appdata.settings[9] = '4';
      (page.readingData as _MemoryReadingData).hasChapters = true;
      logic.scrollManager = ScrollManager(logic);
      await pumpReader(tester);
      final a = await tester.startGesture(const Offset(150, 400), pointer: 1);
      final b = await tester.startGesture(const Offset(250, 400), pointer: 2);
      expect(logic.noScroll, isTrue);
      logic.fABValue = 60;
      if (cancel) {
        await b.cancel();
      } else {
        await b.up();
      }
      await a.up();
      await tester.pump(const Duration(milliseconds: 220));
      expect(logic.noScroll, isFalse);
      expect(logic.order, 1);
      expect(logic.urls, hasLength(2));
      expect(logic.fABValue, 0);
    });
  }

  for (final mode in ['5', '6']) {
    testWidgets('two page mode $mode still accepts pinch without tap',
        (tester) async {
      appdata.settings[9] = mode;
      await pumpReader(tester);
      final controller = logic.photoViewControllers[1]!;
      final initial = controller.scale!;
      final a = await tester.startGesture(const Offset(150, 400), pointer: 1);
      final b = await tester.startGesture(const Offset(250, 400), pointer: 2);
      await a.moveTo(const Offset(110, 400));
      await b.moveTo(const Offset(290, 400));
      await tester.pump();
      await a.moveTo(const Offset(60, 400));
      await b.moveTo(const Offset(340, 400));
      await tester.pump();
      expect(controller.scale, greaterThan(initial));
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(logic.tools, isFalse);
    });
  }
}
