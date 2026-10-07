import 'dart:async';
import 'dart:io';
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
  _Source(String name, File file)
      : super(
            identity: ReaderPageIdentity(
                sourceKey: 'first-raster-test',
                workId: name,
                downloadId: name,
                episode: 1,
                page: 0,
                sourceVersion: '1'),
            file: file);
}

class _Estimate {
  _Estimate(this.file, this.demand);
  final File file;
  final ReaderTileDemand demand;
  final ready = Completer<int>();
  void release() {
    if (!ready.isCompleted) ready.complete(2 << 20);
  }
}

class _Decode {
  _Decode(this.file, this.demand, this.isCancelled);
  final File file;
  final ReaderTileDemand demand;
  final bool Function() isCancelled;
  final ready = Completer<void>();
  ui.Image? image;
  void release() {
    if (!ready.isCompleted) ready.complete();
  }
}

class _Backend extends ReaderRasterBackend {
  final estimates = <_Estimate>[];
  final decodes = <_Decode>[];
  bool automatic = false;
  bool transparentCorner = false;
  @override
  bool get requiresFileBacking => false;
  @override
  Future<ReaderRasterMetadata> probe(File file) async =>
      const ReaderRasterMetadata(
          size: Size(2048, 2048),
          animated: false,
          format: 'first-raster-fixture',
          workingBytes: 2 << 20);
  @override
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
      {required String backingPath}) {
    final call = _Estimate(file, demand);
    estimates.add(call);
    if (automatic) call.release();
    return call.ready.future;
  }

  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    final call = _Decode(file, demand, isCancelled);
    decodes.add(call);
    if (automatic) call.release();
    await call.ready.future;
    // Deliberately return late pixels even after cancellation. The surface,
    // rather than this fixture, must reject and dispose a stale result.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(
        file.path.endsWith('new-source')
            ? Colors.green
            : const Color(0xffff0000),
        BlendMode.src);
    if (transparentCorner) {
      canvas.drawRect(const Rect.fromLTWH(0, 0, 32, 32),
          Paint()..blendMode = BlendMode.clear);
    }
    final picture = recorder.endRecording();
    try {
      return call.image =
          picture.toImageSync(demand.outputWidth, demand.outputHeight);
    } finally {
      picture.dispose();
    }
  }

  void releaseAll() {
    automatic = true;
    for (final call in estimates) {
      call.release();
    }
    for (final call in decodes) {
      call.release();
    }
  }
}

class _Harness {
  _Harness(this.backend, ReaderPageSource initial,
      {this.mode = ReaderDisplayMode.sharpFirst,
      this.resolved = const {},
      this.loadCachedPreview})
      : source = ValueNotifier(initial);
  final _Backend backend;
  final ReaderDisplayMode mode;
  final Map<String, ReaderResolvedOriginal> resolved;
  final Future<ui.Image?> Function(ReaderResolvedOriginal)? loadCachedPreview;
  final ValueNotifier<ReaderPageSource> source;
  final pan = ValueNotifier(Offset.zero);
  final viewport = GlobalKey();
  final capture = GlobalKey();
  final first = <({String source, int buildAt})>[];
  final complete = <ReaderPresentedFrame>[];

  Widget get widget => MaterialApp(
      home: Center(
          child: RepaintBoundary(
              key: capture,
              child: SizedBox(
                  key: viewport,
                  width: 512,
                  height: 512,
                  child: ColoredBox(
                      color: Colors.black,
                      child: ClipRect(
                          child: OverflowBox(
                              minWidth: 2048,
                              maxWidth: 2048,
                              minHeight: 2048,
                              maxHeight: 2048,
                              alignment: Alignment.topLeft,
                              child: ValueListenableBuilder<ReaderPageSource>(
                                  valueListenable: source,
                                  builder: (_, selected, __) => ValueListenableBuilder<Offset>(
                                      valueListenable: pan,
                                      builder: (_, offset, __) => Transform.translate(
                                          offset: offset,
                                          child: SizedBox(
                                              width: 2048,
                                              height: 2048,
                                              child: ReaderImageSurface(
                                                  source: selected,
                                                  sourceSize: const Size(2048, 2048),
                                                  viewportKey: viewport,
                                                  mode: mode,
                                                  transformChanges: pan,
                                                  tilePixels: 256,
                                                  backend: backend,
                                                  resolvedOriginal: resolved[selected.identity.stableKey],
                                                  loadCachedPreview: loadCachedPreview,
                                                  onPresented: complete.add,
                                                  onFirstRasterPresented: (at) => first.add((source: selected.identity.stableKey, buildAt: at))))))))))))));

  void dispose() {
    source.dispose();
    pan.dispose();
  }
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 16));
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 3)));
}

Future<void> _wait(WidgetTester tester, bool Function() done,
    {bool paint = true}) async {
  for (var i = 0; i < 100 && !done(); i++) {
    if (paint) {
      await _pump(tester);
    } else {
      await tester.idle();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 3)));
    }
  }
  expect(done(), isTrue, reason: '${ReaderSurfaceDiagnostics.snapshot()}');
}

Future<List<int>> _pixel(WidgetTester tester, GlobalKey key,
    {int x = 10, int y = 10}) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
  try {
    final bytes = (await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    return bytes.buffer
        .asUint8List(bytes.offsetInBytes, bytes.lengthInBytes)
        .sublist((y * 512 + x) * 4, (y * 512 + x) * 4 + 4);
  } finally {
    image!.dispose();
  }
}

Future<void> _clean(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(const SizedBox.shrink());
  harness.backend.releaseAll();
  await _wait(
      tester,
      () =>
          !ImageWorkScheduler.shared.hasWork &&
          ReaderPageFileLease.activeLeaseCount == 0);
  for (var i = 0; i < 3; i++) {
    await _pump(tester);
  }
  harness.dispose();
  expect(ReaderSurfaceDiagnostics.activeSurfaces, 0);
  expect(ReaderSurfaceDiagnostics.residentBytes, 0);
  expect(ReaderSurfaceDiagnostics.pendingBytes, 0);
  expect(ImageWorkScheduler.shared.reservedBytes, 0);
  expect(ReaderPageFileLease.activeLeaseCount, 0);
}

ui.Image _cachedBlueImage() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(const Color(0xff0000ff), BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return picture.toImageSync(512, 512);
  } finally {
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform savedPaths;
  late ImageDiskQuota? savedQuota;
  late _Source oldSource;
  late _Source newSource;
  late Map<String, ReaderResolvedOriginal> resolved;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('reader-first-raster-');
    savedPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory);
    await App.init();
    final oldFile =
        await File('${directory.path}/old-source').writeAsBytes([1]);
    final newFile =
        await File('${directory.path}/new-source').writeAsBytes([2]);
    oldSource = _Source('old', oldFile);
    newSource = _Source('new', newFile);
    const metadata = ReaderRasterMetadata(
        size: Size(2048, 2048),
        animated: false,
        format: 'first-raster-fixture',
        workingBytes: 2 << 20);
    resolved = {
      oldSource.identity.stableKey: ReaderResolvedOriginal(
          source: oldSource,
          file: oldFile,
          metadata: metadata,
          fileSnapshot: await oldFile.stat()),
      newSource.identity.stableKey: ReaderResolvedOriginal(
          source: newSource,
          file: newFile,
          metadata: metadata,
          fileSnapshot: await newFile.stat()),
    };
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
            const ImageDiskSpace(100 << 30, 'first-raster-test'));
  });
  tearDown(() => ImageDiskQuota.overrideForTesting = savedQuota);

  testWidgets(
      'cached clone paints while original is held and sharp alpha replaces it',
      (tester) async {
    final backend = _Backend()..transparentCorner = true;
    final cacheOwner = _cachedBlueImage();
    ui.Image? transferred;
    var loaderCalls = 0;
    final harness = _Harness(backend, oldSource, resolved: resolved,
        loadCachedPreview: (original) async {
      loaderCalls++;
      expect(
          identical(original, resolved[oldSource.identity.stableKey]), isTrue);
      return transferred = cacheOwner.clone();
    });
    try {
      await tester.pumpWidget(harness.widget);
      await _wait(tester, () => harness.first.isNotEmpty);
      expect(loaderCalls, 1);
      expect(harness.first, hasLength(1));
      expect(harness.complete, isEmpty);
      expect(backend.decodes, isEmpty);
      expect(await _pixel(tester, harness.capture), [0, 0, 255, 255]);
      expect(transferred!.debugDisposed, isFalse);
      final firstEstimate = backend.estimates.first;
      expect(firstEstimate.demand.sourceRect.topLeft, Offset.zero);
      firstEstimate.release();
      await _wait(tester, () => backend.decodes.isNotEmpty);
      expect(await _pixel(tester, harness.capture), [0, 0, 255, 255]);
      backend.decodes.single.release();
      await _wait(
          tester, () => ReaderSurfaceDiagnostics.residentBytes > 512 * 512 * 4,
          paint: false);
      await tester.pump();
      expect(harness.first, hasLength(1));
      expect(harness.complete, isEmpty);
      expect(await _pixel(tester, harness.capture), [0, 0, 0, 255],
          reason: 'transparent original pixels reveal background, not preview');
      expect(await _pixel(tester, harness.capture, x: 64, y: 64),
          [255, 0, 0, 255]);
      expect(await _pixel(tester, harness.capture, x: 300), [0, 0, 255, 255],
          reason: 'the uncompleted neighbouring tile retains the preview');
      backend.releaseAll();
      await _wait(tester, () => harness.complete.isNotEmpty);
      expect(harness.first, hasLength(1));
      expect(harness.complete.last.complete, isTrue);
      expect(backend.decodes, hasLength(4));
      expect(cacheOwner.debugDisposed, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await _clean(tester, harness);
      expect(transferred?.debugDisposed, isTrue);
      cacheOwner.dispose();
    }
  });

  for (final result in ['null', 'failure']) {
    testWidgets('cached preview $result falls through to original admission',
        (tester) async {
      final backend = _Backend();
      var loaderCalls = 0;
      final harness = _Harness(backend, oldSource, resolved: resolved,
          loadCachedPreview: (_) async {
        loaderCalls++;
        if (result == 'failure') throw StateError('controlled cache failure');
        return null;
      });
      try {
        await tester.pumpWidget(harness.widget);
        await _wait(
            tester, () => loaderCalls == 1 && backend.estimates.isNotEmpty);
        expect(backend.estimates, hasLength(1));
        expect(harness.first, isEmpty);
        expect(harness.complete, isEmpty);
        backend.releaseAll();
        await _wait(tester, () => harness.complete.isNotEmpty);
        expect(harness.first, hasLength(1));
        expect(loaderCalls, 1);
        expect(await _pixel(tester, harness.capture), [255, 0, 0, 255]);
        expect(tester.takeException(), isNull);
      } finally {
        await _clean(tester, harness);
      }
    });
  }

  for (final replace in [true, false]) {
    testWidgets(
        'late cached clone after ${replace ? 'replacement' : 'dispose'} is disposed',
        (tester) async {
      final backend = _Backend();
      final cacheOwner = _cachedBlueImage();
      final pending = Completer<ui.Image?>();
      ui.Image? transferred;
      var loaderCalls = 0;
      final harness = _Harness(backend, oldSource, resolved: resolved,
          loadCachedPreview: (original) {
        loaderCalls++;
        return identical(original.source, oldSource)
            ? pending.future
            : Future<ui.Image?>.value();
      });
      try {
        await tester.pumpWidget(harness.widget);
        await _wait(
            tester, () => loaderCalls == 1 && backend.estimates.isNotEmpty);
        if (replace) {
          harness.source.value = newSource;
          await _wait(
              tester, () => backend.estimates.length == 2 && loaderCalls == 2);
        } else {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        transferred = cacheOwner.clone();
        pending.complete(transferred);
        await _wait(tester, () => transferred!.debugDisposed, paint: false);
        expect(ReaderSurfaceDiagnostics.residentBytes, 0);
        expect(ReaderSurfaceDiagnostics.pendingBytes, 0);
        expect(harness.first, isEmpty);
        expect(harness.complete, isEmpty);
        expect(cacheOwner.debugDisposed, isFalse);
        if (replace) {
          backend.releaseAll();
          await _wait(tester, () => harness.complete.isNotEmpty);
          expect(harness.first.map((f) => f.source),
              [newSource.identity.stableKey]);
          expect(await _pixel(tester, harness.capture), [76, 175, 80, 255]);
        }
        expect(tester.takeException(), isNull);
      } finally {
        if (!pending.isCompleted) pending.complete();
        await _clean(tester, harness);
        expect(transferred?.debugDisposed, isTrue);
        cacheOwner.dispose();
      }
    });
  }

  testWidgets('cached loader requires an opened resolved original',
      (tester) async {
    final backend = _Backend();
    var loaderCalls = 0;
    final harness = _Harness(backend, oldSource, loadCachedPreview: (_) async {
      loaderCalls++;
      return null;
    });
    try {
      await tester.pumpWidget(harness.widget);
      await _wait(tester, () => backend.estimates.isNotEmpty);
      backend.releaseAll();
      await _wait(tester, () => harness.complete.isNotEmpty);
      expect(loaderCalls, 0);
      expect(harness.first, hasLength(1));
      expect(tester.takeException(), isNull);
    } finally {
      await _clean(tester, harness);
    }
  });

  testWidgets('one initial request stays admitted until its raster paints',
      (tester) async {
    final backend = _Backend();
    final harness = _Harness(backend, oldSource);
    try {
      await tester.pumpWidget(harness.widget);
      await _wait(tester, () => backend.estimates.isNotEmpty);
      expect(
          ReaderSurfaceDiagnostics.snapshot().single['desired'], hasLength(4));
      expect(backend.estimates, hasLength(1));
      expect(backend.decodes, isEmpty);
      backend.estimates.single.release();
      await _wait(tester, () => backend.decodes.isNotEmpty);
      expect(backend.estimates, hasLength(1));
      expect(backend.decodes, hasLength(1));
      backend.decodes.single.release();
      await _wait(tester, () => ReaderSurfaceDiagnostics.residentBytes > 0,
          paint: false);
      expect(harness.first, isEmpty);
      expect(backend.estimates, hasLength(1),
          reason: 'decode ready is earlier than the first painted frame');
      expect(harness.complete, isEmpty);
      await tester.pump();
      expect(harness.first, hasLength(1));
      expect(harness.first.single.buildAt, greaterThan(0));
      expect(backend.estimates, hasLength(4));
      expect(harness.complete, isEmpty);
      expect(await _pixel(tester, harness.capture), [255, 0, 0, 255]);
      backend.releaseAll();
      await _wait(tester, () => harness.complete.isNotEmpty);
      expect(harness.first, hasLength(1));
      expect(backend.decodes, hasLength(4));
      expect(harness.complete.last.complete, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await _clean(tester, harness);
    }
  });

  for (final failureStage in ['estimate', 'decode']) {
    testWidgets('first $failureStage failure admits another visible tile',
        (tester) async {
      final backend = _Backend();
      final harness = _Harness(backend, oldSource);
      try {
        await tester.pumpWidget(harness.widget);
        await _wait(tester, () => backend.estimates.isNotEmpty);
        final rejected = backend.estimates.single;
        if (failureStage == 'estimate') {
          rejected.ready
              .completeError(StateError('controlled estimate failure'));
        } else {
          rejected.release();
          await _wait(tester, () => backend.decodes.isNotEmpty);
          backend.decodes.single.ready
              .completeError(StateError('controlled decode failure'));
        }
        await _wait(tester, () => backend.estimates.length == 2);
        expect(harness.first, isEmpty);
        final next = backend.estimates.last;
        expect(next.demand.variant, isNot(rejected.demand.variant));
        next.release();
        await _wait(
            tester,
            () => backend.decodes
                .any((d) => d.demand.variant == next.demand.variant));
        backend.decodes.last.release();
        await _wait(tester, () => harness.first.isNotEmpty);
        expect(harness.first, hasLength(1));
        expect(harness.complete, isEmpty);
        expect(backend.estimates.length, greaterThan(2));
        expect(tester.takeException(), isNull);
      } finally {
        await _clean(tester, harness);
      }
    });
  }

  testWidgets('initial whole preview survives repeated viewport pans',
      (tester) async {
    final backend = _Backend();
    final harness =
        _Harness(backend, oldSource, mode: ReaderDisplayMode.previewFirst);
    try {
      await tester.pumpWidget(harness.widget);
      await _wait(tester, () => backend.estimates.isNotEmpty);
      final preview = backend.estimates.single;
      expect(preview.demand.column, -1);
      preview.release();
      await _wait(tester, () => backend.decodes.isNotEmpty);
      final held = backend.decodes.single;
      for (final x in [256.0, 512.0, 768.0]) {
        harness.pan.value = Offset(-x, 0);
        await _pump(tester);
        await _pump(tester);
        expect(held.isCancelled(), isFalse);
        expect(backend.estimates, hasLength(1));
        expect(backend.decodes, hasLength(1));
        expect(harness.first, isEmpty);
      }
      held.release();
      await _wait(tester, () => harness.first.isNotEmpty);
      expect(harness.first, hasLength(1));
      expect(harness.complete, isEmpty);
      expect(await _pixel(tester, harness.capture), [255, 0, 0, 255]);
      backend.releaseAll();
      await _wait(tester, () => harness.complete.isNotEmpty);
      expect(harness.complete.last.sourceRect,
          const Rect.fromLTWH(768, 0, 512, 512));
      expect(backend.decodes.where((d) => d.demand.column == -1), hasLength(1));
      expect(tester.takeException(), isNull);
    } finally {
      await _clean(tester, harness);
    }
  });

  testWidgets('pan before first paint does not report an offscreen ready tile',
      (tester) async {
    final backend = _Backend();
    final harness = _Harness(backend, oldSource);
    try {
      await tester.pumpWidget(harness.widget);
      await _wait(tester, () => backend.estimates.isNotEmpty);
      backend.estimates.single.release();
      await _wait(tester, () => backend.decodes.isNotEmpty);
      backend.decodes.single.release();
      await _wait(tester, () => ReaderSurfaceDiagnostics.residentBytes > 0,
          paint: false);
      harness.pan.value = const Offset(-1024, 0);
      await tester.pump();
      expect(await _pixel(tester, harness.capture), [0, 0, 0, 255]);
      expect(harness.first, isEmpty,
          reason: 'the ready tile moved out of the actual painted viewport');
      await _wait(tester, () => backend.estimates.length == 2);
      expect(backend.estimates.last.demand.sourceRect.left,
          greaterThanOrEqualTo(1024));
      backend.estimates.last.release();
      await _wait(tester, () => backend.decodes.length == 2);
      backend.decodes.last.release();
      await _wait(tester, () => harness.first.isNotEmpty);
      expect(harness.first, hasLength(1));
      expect(await _pixel(tester, harness.capture), [255, 0, 0, 255]);
      backend.releaseAll();
      await _wait(tester, () => harness.complete.isNotEmpty);
      expect(harness.complete.last.sourceRect,
          const Rect.fromLTWH(1024, 0, 512, 512));
      expect(tester.takeException(), isNull);
    } finally {
      await _clean(tester, harness);
    }
  });

  testWidgets(
      'source replacement discards late first raster and resets admission',
      (tester) async {
    final backend = _Backend();
    final harness = _Harness(backend, oldSource);
    try {
      await tester.pumpWidget(harness.widget);
      await _wait(tester, () => backend.estimates.isNotEmpty);
      backend.estimates.single.release();
      await _wait(tester, () => backend.decodes.isNotEmpty);
      final stale = backend.decodes.single;
      harness.source.value = newSource;
      await _wait(tester, () => backend.estimates.length == 2);
      expect(stale.isCancelled(), isTrue);
      stale.release();
      await _wait(
          tester, () => stale.image != null && stale.image!.debugDisposed,
          paint: false);
      expect(ReaderSurfaceDiagnostics.residentBytes, 0);
      expect(harness.first, isEmpty);
      expect(harness.complete, isEmpty);
      await tester.pump();
      expect(await _pixel(tester, harness.capture), [0, 0, 0, 255]);
      final replacement = backend.estimates.last;
      expect(replacement.file.path, (await newSource.openOriginalFile()).path);
      replacement.release();
      await _wait(tester, () => backend.decodes.length == 2);
      backend.decodes.last.release();
      await _wait(tester, () => harness.first.isNotEmpty);
      expect(
          harness.first.map((f) => f.source), [newSource.identity.stableKey]);
      expect(await _pixel(tester, harness.capture), [76, 175, 80, 255]);
      backend.releaseAll();
      await _wait(tester, () => harness.complete.isNotEmpty);
      expect(harness.first, hasLength(1));
      expect(stale.image!.debugDisposed, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await _clean(tester, harness);
    }
  });
}
