import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final Directory root;
  @override
  Future<String?> getApplicationCachePath() async => root.path;
  @override
  Future<String?> getApplicationSupportPath() async => root.path;
}

class _Source extends FileReaderPageSource {
  _Source(String name)
      : super(
            identity: ReaderPageIdentity(
                sourceKey: 'test',
                workId: name,
                downloadId: name,
                episode: 1,
                page: 0,
                sourceVersion: '1'),
            file: File('unused-$name'));
  @override
  Future<File> openOriginalFile({ReaderPageCancellation? cancellation}) async {
    cancellation?.throwIfCancelled();
    return File('unused');
  }
}

class _CoordinateBackend extends ReaderRasterBackend {
  final requests = <ReaderTileDemand>[];
  final images = <ui.Image>[];
  Size metadataSize = const Size(2048, 2048);
  int maximumReserved = 0;
  @override
  bool get requiresFileBacking => false;
  @override
  Future<ReaderRasterMetadata> probe(File file) async => ReaderRasterMetadata(
      size: metadataSize,
      animated: false,
      format: 'coordinate-fixture',
      workingBytes: 16 << 20);

  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    if (isCancelled()) throw const ImageWorkCancelled();
    requests.add(demand);
    final reserved = ImageWorkScheduler.shared.reservedBytes;
    if (reserved > maximumReserved) maximumReserved = reserved;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(demand.density)
      ..translate(-demand.rasterRect.left, -demand.rasterRect.top);
    // The same global source cells are drawn into every requested original
    // region. Transparent and translucent strips cross both grid boundaries.
    for (var y = demand.rasterRect.top ~/ 128 * 128;
        y < demand.rasterRect.bottom;
        y += 128) {
      for (var x = demand.rasterRect.left ~/ 128 * 128;
          x < demand.rasterRect.right;
          x += 128) {
        canvas.drawRect(
            Rect.fromLTWH(x.toDouble(), y.toDouble(), 128, 128),
            Paint()
              ..color = Color.fromARGB(
                  255, (32 + x ~/ 8) & 255, y ~/ 8 & 255, (x ^ y) ~/ 8 & 255));
      }
    }
    canvas.drawRect(
        Rect.fromLTWH(0, 508, metadataSize.width, 8),
        Paint()
          ..blendMode = BlendMode.src
          ..color = const Color(0x80ff0000));
    for (final x in [508.0, 1020.0, 1532.0]) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 8, metadataSize.height),
          Paint()..blendMode = BlendMode.clear);
    }
    final picture = recorder.endRecording();
    try {
      final image =
          picture.toImageSync(demand.outputWidth, demand.outputHeight);
      images.add(image);
      return image;
    } finally {
      picture.dispose();
    }
  }
}

class _HeldWork {
  _HeldWork(this.demand, this.isCancelled);
  final ReaderTileDemand demand;
  final bool Function() isCancelled;
  final ready = Completer<void>();
}

class _GatedCoordinateBackend extends _CoordinateBackend {
  _GatedCoordinateBackend() {
    metadataSize = const Size(8192, 8192);
  }
  final held = <_HeldWork>[];
  final lateImages = <ui.Image>[];
  bool holdNative = false;

  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    var late = false;
    if (holdNative && demand.density == 1) {
      final gate = _HeldWork(demand, isCancelled);
      held.add(gate);
      await gate.ready.future;
      late = isCancelled();
    }
    final image = await super.decode(file, demand,
        backingPath: backingPath,
        memoryBudgetBytes: memoryBudgetBytes,
        isCancelled: () => false,
        cancelled: cancelled);
    if (late) lateImages.add(image);
    return image;
  }

  void releaseAll() {
    holdNative = false;
    for (final gate in held) {
      if (!gate.ready.isCompleted) gate.ready.complete();
    }
  }
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 16));
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 3)));
}

Future<Uint8List> _capture(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
  try {
    final bytes = (await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    return Uint8List.fromList(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
  } finally {
    image!.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ImageDiskQuota? savedQuota;
  late PathProviderPlatform savedPaths;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('reader-tile-grouping-');
    savedPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory);
    await App.init();
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = savedPaths;
    await directory.delete(recursive: true);
  });
  setUp(() {
    savedQuota = ImageDiskQuota.overrideForTesting;
    ImageDiskQuota.overrideForTesting = ImageDiskQuota(
        roots: () => [App.cachePath],
        idleLimitBytes: () => 512 << 20,
        space: (_) async =>
            const ImageDiskSpace(100 << 30, 'tile-grouping-test'));
  });
  tearDown(() {
    ImageDiskQuota.overrideForTesting = savedQuota;
  });

  testWidgets(
      '1024 tiles preserve exact native coverage and alpha with four times fewer requests',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2048, 2048);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    Uint8List? reference;
    final requestCounts = <int>[];
    for (final tilePixels in [512, 1024]) {
      final backend = _CoordinateBackend();
      final viewport = GlobalKey();
      final capture = GlobalKey();
      final changes = ValueNotifier(0);
      ReaderPresentedFrame? presented;
      try {
        await tester.pumpWidget(MaterialApp(
            home: RepaintBoundary(
                key: capture,
                child: ColoredBox(
                    color: Colors.black,
                    child: SizedBox(
                        key: viewport,
                        width: 2048,
                        height: 2048,
                        child: ReaderImageSurface(
                            source: _Source('grid-$tilePixels'),
                            sourceSize: const Size(2048, 2048),
                            viewportKey: viewport,
                            mode: ReaderDisplayMode.sharpFirst,
                            transformChanges: changes,
                            tilePixels: tilePixels,
                            backend: backend,
                            onPresented: (frame) => presented = frame))))));
        for (var i = 0; i < 120 && presented == null; i++) {
          await _pump(tester);
        }
        expect(presented, isNotNull);
        expect(presented!.sourceRect, const Rect.fromLTWH(0, 0, 2048, 2048));
        expect(presented!.complete, isTrue);
        expect(presented!.density, 1);
        expect(presented!.nativePixels, isTrue);
        expect(backend.requests.every((d) => d.density == 1), isTrue);
        expect(
            backend.requests.fold<double>(
                0, (sum, d) => sum + d.sourceRect.width * d.sourceRect.height),
            2048 * 2048);
        requestCounts.add(backend.requests.length);
        expect(ReaderSurfaceDiagnostics.residentBytes, 2048 * 2048 * 4);
        expect(ReaderSurfaceDiagnostics.residentBytes,
            lessThanOrEqualTo(64 << 20));
        expect(
            ReaderSurfaceDiagnostics.residentBytes +
                ReaderSurfaceDiagnostics.pendingBytes,
            lessThanOrEqualTo(192 << 20));
        expect(backend.maximumReserved,
            lessThanOrEqualTo(ImageWorkScheduler.shared.memoryBudgetBytes));
        final pixels = await _capture(tester, capture);
        expect(pixels.length, 2048 * 2048 * 4);
        List<int> at(int x, int y) =>
            pixels.sublist((y * 2048 + x) * 4, (y * 2048 + x) * 4 + 4);
        expect(at(511, 100), [0, 0, 0, 255]);
        expect(at(1024, 100), [0, 0, 0, 255]);
        expect(at(100, 511), [128, 0, 0, 255]);
        if (reference == null) {
          reference = pixels;
        } else {
          var differences = 0;
          for (var i = 0; i < pixels.length; i++) {
            if (pixels[i] != reference[i]) differences++;
          }
          expect(differences, 0,
              reason:
                  'grouping must keep original source pixels and transparent seams identical');
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        for (var i = 0; i < 6; i++) {
          await _pump(tester);
        }
        changes.dispose();
      }
      expect(ReaderSurfaceDiagnostics.residentBytes, 0);
      expect(ReaderSurfaceDiagnostics.pendingBytes, 0);
      expect(ImageWorkScheduler.shared.reservedBytes, 0);
      expect(ReaderPageFileLease.activeLeaseCount, 0);
    }
    expect(requestCounts, [16, 4]);
  });

  testWidgets(
      'fit grouping switches to native 512 tiles without holes or stale pan completion',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2048, 2048);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final source = _Source('adaptive-grid');
    final backend = _GatedCoordinateBackend();
    final viewport = GlobalKey();
    final capture = GlobalKey();
    final transform = ValueNotifier((zoom: 0.5, pan: Offset.zero));
    final presented = <ReaderPresentedFrame>[];
    Future<void> waitForFrame(Rect rect, double density) async {
      for (var i = 0; i < 160; i++) {
        if (presented.any(
            (frame) => frame.sourceRect == rect && frame.density == density)) {
          return;
        }
        await _pump(tester);
      }
      fail('No complete frame for $rect at $density; '
          '${ReaderSurfaceDiagnostics.snapshot()}');
    }

    try {
      await tester.pumpWidget(MaterialApp(
          home: RepaintBoundary(
              key: capture,
              child: ColoredBox(
                  color: Colors.black,
                  child: SizedBox(
                      key: viewport,
                      width: 2048,
                      height: 2048,
                      child: ClipRect(
                          child: OverflowBox(
                              minWidth: 8192,
                              maxWidth: 8192,
                              minHeight: 8192,
                              maxHeight: 8192,
                              alignment: Alignment.topLeft,
                              child: ValueListenableBuilder<({double zoom, Offset pan})>(
                                  valueListenable: transform,
                                  builder: (_, value, __) => SizedBox(
                                      width: 8192,
                                      height: 8192,
                                      child: Transform.translate(
                                          offset: value.pan,
                                          child: Transform.scale(
                                              scale: value.zoom,
                                              alignment: Alignment.topLeft,
                                              child: ReaderImageSurface(
                                                  source: source,
                                                  sourceSize:
                                                      const Size(8192, 8192),
                                                  viewportKey: viewport,
                                                  mode: ReaderDisplayMode
                                                      .sharpFirst,
                                                  transformChanges: transform,
                                                  tilePixels: 1024,
                                                  nativeTilePixels: 512,
                                                  backend: backend,
                                                  onPresented:
                                                      presented.add))))))))))));
      const fitRect = Rect.fromLTWH(0, 0, 4096, 4096);
      await waitForFrame(fitRect, 0.5);
      final fitRequests = backend.requests.toList();
      expect(fitRequests, hasLength(4));
      expect(fitRequests.every((d) => d.density == 0.5), isTrue);
      expect(fitRequests.every((d) => d.outputWidth <= 1028), isTrue);
      final fitPixels = await _capture(tester, capture);

      backend.holdNative = true;
      transform.value = (zoom: 1.0, pan: Offset.zero);
      for (var i = 0; i < 60 && backend.held.isEmpty; i++) {
        await _pump(tester);
      }
      expect(backend.held, isNotEmpty);
      final upgradingPixels = await _capture(tester, capture);
      final nonblank = <int>[100, 800, 1800];
      for (final y in nonblank) {
        for (final x in nonblank) {
          final offset = (y * 2048 + x) * 4;
          expect(upgradingPixels.sublist(offset, offset + 4),
              isNot([0, 0, 0, 255]),
              reason:
                  'completed fit rasters must remain visible during upgrade');
        }
      }
      expect(presented.where((f) => f.density == 1), isEmpty);

      // Move to a disjoint viewport while two native jobs are still held.
      // Their late results must be disposed and cannot mark the new pan done.
      transform.value = (zoom: 1.0, pan: const Offset(-4096, -4096));
      for (var i = 0; i < 8; i++) {
        await _pump(tester);
      }
      expect(backend.held.any((work) => work.isCancelled()), isTrue);
      backend.releaseAll();
      const pannedRect = Rect.fromLTWH(4096, 4096, 2048, 2048);
      await waitForFrame(pannedRect, 1);
      expect(backend.lateImages, isNotEmpty);
      expect(backend.lateImages.every((image) => image.debugDisposed), isTrue);
      expect(
          presented.where((f) => f.density == 1).every((f) =>
              f.sourceRect == pannedRect && f.nativePixels && f.complete),
          isTrue);
      final nativeRequests = backend.requests.where((d) => d.density == 1);
      expect(nativeRequests, isNotEmpty);
      expect(nativeRequests.every((d) => d.outputWidth == 512), isTrue);
      expect(nativeRequests.every((d) => d.outputHeight == 512), isTrue);
      final surface = ReaderSurfaceDiagnostics.snapshot().single;
      expect(surface['ticketVariants'], isEmpty);
      expect(surface['estimating'], isEmpty);
      expect(
          ReaderSurfaceDiagnostics.residentBytes, lessThanOrEqualTo(64 << 20));
      expect(
          ReaderSurfaceDiagnostics.residentBytes +
              ReaderSurfaceDiagnostics.pendingBytes,
          lessThanOrEqualTo(192 << 20));

      // Return through the inverse transition. No native grid may masquerade
      // as the requested fit; the same original fit pixels must be restored.
      presented.clear();
      transform.value = (zoom: 0.5, pan: Offset.zero);
      await waitForFrame(fitRect, 0.5);
      final returned = await _capture(tester, capture);
      expect(returned.length, fitPixels.length);
      var differences = 0;
      for (var i = 0; i < returned.length; i++) {
        if (returned[i] != fitPixels[i]) differences++;
      }
      expect(differences, 0);
      expect(tester.takeException(), isNull);
    } finally {
      backend.releaseAll();
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 8; i++) {
        await _pump(tester);
      }
      transform.dispose();
    }
    expect(backend.images.every((image) => image.debugDisposed), isTrue);
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ReaderSurfaceDiagnostics.pendingBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });
}
