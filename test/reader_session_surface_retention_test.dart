import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_session_raster_cache.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';

class _RetentionPaths extends PathProviderPlatform {
  _RetentionPaths(this.root);
  final Directory root;
  @override
  Future<String?> getApplicationCachePath() async => root.path;
  @override
  Future<String?> getApplicationSupportPath() async => root.path;
}

/// A real file snapshot determines the decoded pixels. Only the codec is fake;
/// source opening, metadata, Surface ownership and route caching are real.
class _FileColorBackend extends ReaderRasterBackend {
  int decodes = 0;
  final images = <ui.Image>[];
  final demands = <ReaderTileDemand>[];
  @override
  bool get requiresFileBacking => false;
  @override
  bool get supportsIdlePreparation => false;
  @override
  Future<ReaderRasterMetadata> probe(File file) async =>
      const ReaderRasterMetadata(
          size: Size(1200, 1800),
          animated: false,
          format: 'fixture',
          workingBytes: 1);
  @override
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
          {required String backingPath}) async =>
      1;
  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    final bytes = await file.readAsBytes();
    if (isCancelled()) throw const ImageWorkCancelled();
    decodes++;
    demands.add(demand);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(
        bytes.first == 1 ? const Color(0xffff0000) : const Color(0xff00ff00),
        BlendMode.src);
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

FileReaderPageSource _source(File file, String workId) => FileReaderPageSource(
    identity: ReaderPageIdentity(
        sourceKey: 'session-surface-test',
        workId: workId,
        downloadId: workId,
        episode: 1,
        page: 0,
        sourceVersion: 'same-source-version'),
    file: file,
    width: 1200,
    height: 1800);

Widget _harness({
  required FileReaderPageSource source,
  required _FileColorBackend backend,
  required ReaderSessionRasterCache cache,
  required ReaderResolvedOriginal resolved,
  required Listenable transformChanges,
  required GlobalKey screenshot,
}) {
  final viewport = GlobalKey();
  return MaterialApp(
      home: Scaffold(
          body: Center(
              child: RepaintBoundary(
                  key: screenshot,
                  child: SizedBox(
                      key: viewport,
                      width: 300,
                      height: 450,
                      child: ColoredBox(
                          color: Colors.black,
                          child: ReaderImageSurface(
                              source: source,
                              sourceSize: const Size(1200, 1800),
                              viewportKey: viewport,
                              mode: ReaderDisplayMode.sharpFirst,
                              transformChanges: transformChanges,
                              backend: backend,
                              resolvedOriginal: resolved,
                              sessionRasterCache: cache)))))));
}

Future<void> _mount(WidgetTester tester,
    {required FileReaderPageSource source,
    required _FileColorBackend backend,
    required ReaderSessionRasterCache cache,
    required Listenable transformChanges,
    required GlobalKey screenshot}) async {
  // Production RPI hands the Surface an original already opened and probed.
  // Resolve that same contract through real I/O rather than a fake FileStat.
  final resolved = (await tester.runAsync(() async {
    final file = await source.openOriginalFile();
    final metadata = await backend.probe(file);
    return ReaderResolvedOriginal(
        source: source,
        file: file,
        metadata: metadata,
        fileSnapshot: await file.stat());
  }))!;
  await tester.pumpWidget(_harness(
      source: source,
      backend: backend,
      cache: cache,
      resolved: resolved,
      transformChanges: transformChanges,
      screenshot: screenshot));
}

Future<void> _settle(WidgetTester tester, {int frames = 18}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 3)));
  }
}

Future<List<int>> _pixels(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
  try {
    return (await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!
        .buffer
        .asUint8List()
        .toList();
  } finally {
    image.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final originalPaths = PathProviderPlatform.instance;
  const rasterBytes = 300 * 450 * 4;

  setUpAll(() async {
    final parent = Platform.isWindows
        ? Directory(r'D:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    root = await parent.createTemp('session-surface-test-');
    PathProviderPlatform.instance = _RetentionPaths(root);
    await App.init();
  });
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.devicePixelRatio = 1;
    view.physicalSize = const Size(800, 600);
  });
  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetDevicePixelRatio();
    view.resetPhysicalSize();
    expect(ReaderSurfaceDiagnostics.activeSurfaces, 0);
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ReaderSurfaceDiagnostics.pendingBytes, 0);
    expect(ReaderSessionRasterCache.totalRetainedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    expect(ImageWorkScheduler.shared.activeCount, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets('backscroll restores the same verified pixels without a decode',
      (tester) async {
    final file = File('${root.path}/backscroll-page');
    await tester.runAsync(() async {
      await file.writeAsBytes([1], flush: true);
      await file.setLastModified(DateTime(2001));
    });
    final backend = _FileColorBackend();
    final cache = ReaderSessionRasterCache(maximumBytes: 8 << 20);
    final transform = ValueNotifier(0);
    final screenshot = GlobalKey();
    try {
      await _mount(tester,
          source: _source(file, 'backscroll'),
          backend: backend,
          cache: cache,
          transformChanges: transform,
          screenshot: screenshot);
      await _settle(tester);
      expect(backend.decodes, 1);
      expect(backend.demands.single.density, 0.25);
      expect((
        backend.demands.single.outputWidth,
        backend.demands.single.outputHeight
      ), (
        300,
        450
      ));
      final originalPixels = await _pixels(tester, screenshot);
      expect(originalPixels.sublist(0, 4), [255, 0, 0, 255]);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      expect(cache.length, 1);
      expect(cache.retainedBytes, rasterBytes);
      expect(ReaderSurfaceDiagnostics.residentBytes, rasterBytes,
          reason: 'resident diagnostics include the retained route cache');
      expect(ReaderSurfaceDiagnostics.activeSurfaces, 0);
      expect(ReaderPageFileLease.activeLeaseCount, 0,
          reason: 'retained pixels must not retain the original file lease');
      expect(backend.images.single.debugDisposed, isTrue,
          reason: 'the cache must own a separate surviving image handle');

      // A fresh page object models sliver/gallery reconstruction on backscroll.
      await _mount(tester,
          source: _source(file, 'backscroll'),
          backend: backend,
          cache: cache,
          transformChanges: transform,
          screenshot: screenshot);
      await _settle(tester);
      expect(backend.decodes, 1,
          reason:
              'the same source/stat/geometry must take the retained raster');
      expect(await _pixels(tester, screenshot), originalPixels);
      expect(cache.retainedBytes, 0,
          reason: 'take transfers cache ownership to the active Surface once');
      expect(ReaderSurfaceDiagnostics.residentBytes, rasterBytes);
      expect(tester.takeException(), isNull);
    } finally {
      // Closing the reader releases both route and visible raster ownership.
      cache.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      transform.dispose();
    }
  });

  testWidgets(
      'changed original stat misses retained pixels despite same page ID',
      (tester) async {
    final file = File('${root.path}/changed-page');
    await tester.runAsync(() async {
      await file.writeAsBytes([1], flush: true);
      await file.setLastModified(DateTime(2001));
    });
    final backend = _FileColorBackend();
    final cache = ReaderSessionRasterCache(maximumBytes: 8 << 20);
    final transform = ValueNotifier(0);
    final screenshot = GlobalKey();
    try {
      await _mount(tester,
          source: _source(file, 'changing-original'),
          backend: backend,
          cache: cache,
          transformChanges: transform,
          screenshot: screenshot);
      await _settle(tester);
      expect(
          (await _pixels(tester, screenshot)).sublist(0, 4), [255, 0, 0, 255]);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      expect(cache.retainedBytes, rasterBytes);
      await tester.runAsync(() async {
        await file.writeAsBytes([2, 2], flush: true);
        await file.setLastModified(DateTime(2002));
      });
      await _mount(tester,
          source: _source(file, 'changing-original'),
          backend: backend,
          cache: cache,
          transformChanges: transform,
          screenshot: screenshot);
      await _settle(tester);
      expect(backend.decodes, 2,
          reason: 'source ID alone cannot authorize a stale raster cache hit');
      expect(
          (await _pixels(tester, screenshot)).sublist(0, 4), [0, 255, 0, 255]);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      cache.dispose();
      transform.dispose();
    }
    expect(backend.images.every((image) => image.debugDisposed), isTrue);
  });

  testWidgets(
      'refresh invalidation blocks an old active Surface from refilling',
      (tester) async {
    final file = File('${root.path}/invalidated-page');
    await tester.runAsync(() => file.writeAsBytes([1], flush: true));
    final source = _source(file, 'refresh-original');
    final backend = _FileColorBackend();
    final cache = ReaderSessionRasterCache(maximumBytes: 8 << 20);
    final transform = ValueNotifier(0);
    final screenshot = GlobalKey();
    try {
      await _mount(tester,
          source: source,
          backend: backend,
          cache: cache,
          transformChanges: transform,
          screenshot: screenshot);
      await _settle(tester);
      expect(backend.decodes, 1);
      cache.invalidateSource(source.identity.stableKey);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      expect(cache.length, 0,
          reason: 'dispose cannot issue a fresh epoch key for its old pixels');
      expect(cache.retainedBytes, 0);

      // Keep the source bytes/stat unchanged so only explicit invalidation can
      // prevent a hit; the new Surface must perform a fresh decode.
      await _mount(tester,
          source: _source(file, 'refresh-original'),
          backend: backend,
          cache: cache,
          transformChanges: transform,
          screenshot: screenshot);
      await _settle(tester);
      expect(backend.decodes, 2);
      expect(
          (await _pixels(tester, screenshot)).sublist(0, 4), [255, 0, 0, 255]);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      expect(cache.retainedBytes, rasterBytes);
      cache.dispose();
      expect(cache.isDisposed, isTrue);
      expect(cache.retainedBytes, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      cache.dispose();
      transform.dispose();
    }
    expect(backend.images.every((image) => image.debugDisposed), isTrue);
  });
}
