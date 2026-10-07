import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_session_raster_cache.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _CountingCover extends FileImage {
  _CountingCover(super.file);
  final List<String> loadCalls = [];
  int get loads => loadCalls.length;
  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) {
    loadCalls.add(key.file.path);
    return super.loadImage(key, decode);
  }
}

class _ReaderBackend extends ReaderRasterBackend {
  int decodes = 0;
  @override
  bool get requiresFileBacking => false;
  @override
  Future<ReaderRasterMetadata> probe(File file) async =>
      const ReaderRasterMetadata(
          size: Size(64, 96),
          animated: false,
          format: 'fixture',
          workingBytes: 64 << 10);
  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    if (isCancelled()) throw const ImageWorkCancelled();
    decodes++;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(const Color(0xff316f93), BlendMode.src);
    final picture = recorder.endRecording();
    try {
      final result =
          await picture.toImage(demand.outputWidth, demand.outputHeight);
      if (isCancelled()) {
        result.dispose();
        throw const ImageWorkCancelled();
      }
      return result;
    } finally {
      picture.dispose();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final savedPaths = PathProviderPlatform.instance;
  final savedSettings = List<String>.of(appdata.settings);
  final cache = PaintingBinding.instance.imageCache;
  final savedMaximumBytes = cache.maximumSizeBytes;
  final savedMaximumEntries = cache.maximumSize;
  late Directory workspace;
  late File coverFile;

  setUpAll(() async {
    workspace =
        await Directory.systemTemp.createTemp('reader_cover_keepalive_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: p.join(workspace.path, 'app'));
    final image = img.Image(width: 64, height: 96);
    img.fill(image, color: img.ColorRgba8(47, 131, 209, 255));
    coverFile = await File(p.join(workspace.path, 'cover.png'))
        .writeAsBytes(img.encodePng(image));
    appdata.settings[9] = '0';
  });
  tearDownAll(() async {
    cache.clear();
    cache.clearLiveImages();
    cache.maximumSizeBytes = savedMaximumBytes;
    cache.maximumSize = savedMaximumEntries;
    PathProviderPlatform.instance = savedPaths;
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    await workspace.delete(recursive: true);
  });

  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
      if (done()) return;
    }
    expect(done(), isTrue, reason: 'real image workflow did not complete');
  }

  Widget cover(_CountingCover provider) => MaterialApp(
      home: Center(
          child:
              SizedBox(width: 64, height: 96, child: Image(image: provider))));

  testWidgets('reader exit retains painted cover and releases owned rasters',
      (tester) async {
    final provider = _CountingCover(coverFile);
    await tester.pumpWidget(cover(provider));
    await waitFor(
        tester,
        () =>
            find.byType(RawImage).evaluate().isNotEmpty &&
            tester.renderObject<RenderImage>(find.byType(RawImage)).image !=
                null);
    expect(provider.loads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(cache.statusForKey(provider).keepAlive, isTrue);
    expect(cache.statusForKey(provider).live, isFalse);

    final logic = ComicReadingPageLogic(
        1,
        LocalReadingData(
            title: 'fixture',
            id: 'fixture',
            downloadId: 'fixture',
            sourceKey: 'local',
            hasEp: false,
            comicType: ComicType.other),
        1,
        () {});
    addTearDown(() {
      logic.restoreReaderCacheLimits();
      logic.dispose();
      logic.pageController.dispose();
      logic.scrollController.dispose();
      logic.focusNode.dispose();
      logic.viewportChanges.dispose();
    });
    final beforeBytes = cache.maximumSizeBytes;
    final beforeEntries = cache.maximumSize;
    logic.configureReaderCacheLimits();
    expect(cache.statusForKey(provider).keepAlive, isTrue);
    expect(cache.currentSizeBytes, lessThanOrEqualTo(cache.maximumSizeBytes));
    expect(cache.currentSize, lessThanOrEqualTo(cache.maximumSize));

    final source = FileReaderPageSource(
        identity: const ReaderPageIdentity(
            sourceKey: 'fixture',
            workId: 'reader',
            downloadId: 'reader',
            episode: 1,
            page: 0,
            sourceVersion: '1'),
        file: coverFile);
    final backend = _ReaderBackend();
    final metadata = await backend.probe(coverFile);
    final snapshot = (await tester.runAsync(coverFile.stat))!;
    final resolved = ReaderResolvedOriginal(
        source: source,
        file: coverFile,
        metadata: metadata,
        fileSnapshot: snapshot);
    final transform = ValueNotifier(1.0);
    addTearDown(transform.dispose);
    final viewport = GlobalKey();
    var presented = false;
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
                key: viewport,
                width: 64,
                height: 96,
                child: ReaderImageSurface(
                    source: source,
                    sourceSize: metadata.size,
                    metadata: metadata,
                    resolvedOriginal: resolved,
                    viewportKey: viewport,
                    mode: ReaderDisplayMode.sharpFirst,
                    transformChanges: transform,
                    backend: backend,
                    sessionRasterCache: logic.sessionRasterCache,
                    onPresented: (frame) => presented = frame.complete)))));
    await waitFor(tester, () => presented);
    expect(backend.decodes, greaterThan(0));
    expect(ReaderSurfaceDiagnostics.residentBytes, greaterThan(0));
    expect(
        ReaderSurfaceDiagnostics.residentBytes, lessThanOrEqualTo(192 << 20));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(ReaderSurfaceDiagnostics.activeSurfaces, 0);
    expect(logic.sessionRasterCache.retainedBytes, greaterThan(0));
    logic.sessionRasterCache.dispose();
    logic.restoreReaderCacheLimits();
    await waitFor(tester, () => ImageWorkScheduler.shared.activeCount == 0);
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ReaderSurfaceDiagnostics.pendingBytes, 0);
    expect(ReaderSessionRasterCache.totalRetainedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    expect(ImageWorkScheduler.shared.pendingCount, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(cache.maximumSizeBytes, beforeBytes);
    expect(cache.maximumSize, beforeEntries);
    expect(cache.statusForKey(provider).keepAlive, isTrue);

    await tester.pumpWidget(cover(provider));
    await tester.pump();
    expect(provider.loads, 1,
        reason: 'returning to the cover should reuse its decoded image');
    final retainedImage =
        tester.renderObject<RenderImage>(find.byType(RawImage)).image!;
    final pixels = (await tester.runAsync(
        () => retainedImage.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    expect(pixels.buffer.asUint8List().take(4), [47, 131, 209, 255]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
