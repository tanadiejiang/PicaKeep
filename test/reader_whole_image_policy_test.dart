import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_session_raster_cache.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep/pages/reader/reader_page_image.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

const _identity = ReaderPageIdentity(
    sourceKey: 'whole-policy-test',
    workId: 'page',
    downloadId: 'page',
    episode: 1,
    page: 0,
    sourceVersion: '1');

ReaderRasterMetadata _metadata(
        {Size size = const Size(1200, 1800),
        String format = 'png',
        bool animated = false,
        int bitDepth = 8,
        bool hasColorProfile = false}) =>
    ReaderRasterMetadata(
        size: size,
        animated: animated,
        format: format,
        workingBytes: 1,
        bitDepth: bitDepth,
        hasColorProfile: hasColorProfile);

Future<File> _png(Directory root) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0x00000000), BlendMode.src);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 160, 480),
      Paint()..color = const Color(0x804080c0));
  canvas.drawRect(const Rect.fromLTWH(160, 0, 160, 480),
      Paint()..color = const Color(0xffff8000));
  final picture = recorder.endRecording();
  final image = await picture.toImage(320, 480);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return File('${root.path}/alpha.png')
      ..writeAsBytesSync(data!.buffer.asUint8List());
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File file;
  late FileStat snapshot;
  late FileReaderPageSource source;

  setUpAll(() async {
    final parent = Platform.isWindows
        ? Directory(r'D:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    root = await parent.createTemp('whole-policy-test-');
    await App.init(
        cachePathOverride: '${root.path}/cache',
        dataPathOverride: '${root.path}/data');
    file = await _png(root);
    snapshot = await file.stat();
    source = FileReaderPageSource(identity: _identity, file: file);
  });
  tearDownAll(() async {
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    await root.delete(recursive: true);
  });

  bool eligible(ReaderRasterMetadata metadata,
          {ReaderPageSource? selectedSource,
          ReaderRasterBackend? backend,
          int textureEdgeLowerBound = 0}) =>
      ReaderWholeImagePolicy.isEligible(
          source: selectedSource ?? source,
          metadata: metadata,
          snapshot: snapshot,
          backend: backend ?? FlutterReaderRasterBackend(metadata),
          textureEdgeLowerBound: textureEdgeLowerBound);

  test('ordinary local pages fit while large illustrations retain ROI', () {
    for (final format in ['jpeg', 'png', 'webp']) {
      expect(eligible(_metadata(format: format)), isTrue);
    }
    expect(eligible(_metadata(size: const Size(2048, 2048))), isTrue);
    expect(eligible(_metadata(size: const Size(2048, 2049))), isFalse);
    expect(eligible(_metadata(size: const Size(3000, 4000))), isFalse);
    expect(eligible(_metadata(size: const Size(4096, 500))), isTrue);
    expect(eligible(_metadata(size: const Size(4097, 500))), isFalse);
    expect(
        eligible(_metadata(size: const Size(2400, 1000)),
            textureEdgeLowerBound: 2048),
        isFalse);
  });

  test('color, animation, format and invalid dimensions stay on existing paths',
      () {
    expect(eligible(_metadata(animated: true)), isFalse);
    expect(eligible(_metadata(hasColorProfile: true)), isFalse);
    expect(eligible(_metadata(bitDepth: 16)), isFalse);
    expect(eligible(_metadata(format: 'tiff')), isFalse);
    expect(eligible(_metadata(size: const Size(0, 1800))), isFalse);
    expect(
        eligible(_metadata(size: const Size(double.infinity, 1800))), isFalse);
    expect(eligible(_metadata(size: const Size(1200.5, 1800))), isFalse);
    expect(eligible(_metadata(), backend: const NativeReaderRasterBackend()),
        isFalse);
  });

  test(
      'preview renditions and deferred sources do not enter local whole policy',
      () {
    expect(
        eligible(_metadata(),
            selectedSource: FileReaderPageSource(
                identity: _identity,
                file: file,
                isAuthoritativeOriginal: false)),
        isFalse);
    expect(
        eligible(_metadata(),
            selectedSource: FileReaderPageSource(
                identity: _identity, file: file, isPreviewOnly: true)),
        isFalse);
    expect(
        eligible(_metadata(),
            selectedSource: DeferredReaderPageSource(
                identity: _identity, opener: (_) async => file)),
        isFalse);
  });

  test('real transparent PNG is admitted without changing original bytes',
      () async {
    final before = await file.readAsBytes();
    final metadata = _metadata(size: const Size(320, 480));
    expect(
        await ReaderWholeImagePolicy.canUseOriginal(
            source: source,
            file: file,
            metadata: metadata,
            snapshot: snapshot,
            backend: FlutterReaderRasterBackend(metadata)),
        isTrue);
    expect(await file.readAsBytes(), before);
  });

  test('codec dimension or orientation mismatch keeps the region path',
      () async {
    final metadata = _metadata(size: const Size(480, 320));
    expect(
        await ReaderWholeImagePolicy.canUseOriginal(
            source: source,
            file: file,
            metadata: metadata,
            snapshot: snapshot,
            backend: FlutterReaderRasterBackend(metadata)),
        isFalse);
  });

  test('a descriptor unsupported by Flutter does not become a page error',
      () async {
    final unsupported = File('${root.path}/not-flutter-readable.png')
      ..writeAsBytesSync([1, 2, 3, 4]);
    final metadata = _metadata(size: const Size(320, 480));
    expect(
        await ReaderWholeImagePolicy.canUseOriginal(
            source:
                FileReaderPageSource(identity: _identity, file: unsupported),
            file: unsupported,
            metadata: metadata,
            snapshot: await unsupported.stat(),
            backend: FlutterReaderRasterBackend(metadata)),
        isFalse);
  });

  testWidgets(
      'normal entry retains original pixels and metadata across revisit',
      (tester) async {
    final changes = ChangeNotifier();
    final controller = PhotoViewController();
    final viewport = GlobalKey();
    final session = ReaderSessionRasterCache();
    addTearDown(session.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(160, 240);
    addTearDown(() {
      changes.dispose();
      controller.dispose();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    Future<void> stopWorkers() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      // Native metadata probing keeps an idle worker for ten seconds in the
      // app. Close it explicitly so the fixture leaves no fake-clock timer.
      final shutdown = PicakeepImageEngine.shutdownIdleWorkers();
      for (var i = 0;
          i < 80 && PicakeepImageEngine.workerDiagnostics['workersAlive'] != 0;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)));
        await tester.pump();
      }
      expect(PicakeepImageEngine.workerDiagnostics['workersAlive'], 0);
      await shutdown;
    }

    addTearDown(stopWorkers);
    ReaderRasterDiagnostics.drainSamples();
    Future<void> mount() => tester.pumpWidget(MaterialApp(
        home: SizedBox.expand(
            key: viewport,
            child: ReaderPageImage(
                loadSource: () async => source,
                resourceKey: 'normal-local-whole',
                viewportKey: viewport,
                transformChanges: changes,
                controller: controller,
                sessionRasterCache: session,
                persistRaster: false,
                mode: ReaderDisplayMode.sharpFirst))));
    await mount();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final whole =
        ReaderTileDemand(Offset.zero & const Size(320, 480), 1, -1, -1).variant;
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 4)));
      await tester.pump();
      final diagnostics = ReaderSurfaceDiagnostics.snapshot();
      if (diagnostics.isNotEmpty &&
          (diagnostics.single['residentVariants'] as List).contains(whole)) {
        break;
      }
    }
    expect(find.byType(ReaderImageSurface), findsOneWidget);
    expect(
        tester
            .widget<ReaderImageSurface>(find.byType(ReaderImageSurface))
            .fullOrdinaryImage,
        isTrue,
        reason: 'normal entry must choose the bounded policy without a flag');
    expect(ReaderSurfaceDiagnostics.snapshot().single['desired'], [whole]);
    expect(ReaderSurfaceDiagnostics.snapshot().single['residentVariants'],
        [whole]);
    final firstSamples = ReaderRasterDiagnostics.drainSamples();
    final firstDecodes = firstSamples
        .where((sample) => sample.containsKey('flutterCodecWallUs'))
        .length;
    expect(firstDecodes, 1);
    expect(firstSamples.where((sample) => sample['sourceMetadataProbe'] == 1),
        hasLength(1));
    expect(
        firstSamples
            .where((sample) => sample['sourcePolicyDescriptorCheck'] == 1),
        hasLength(1));
    controller.scale = 2;
    controller.position = const Offset(-60, -80);
    changes.notifyListeners();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(ReaderSurfaceDiagnostics.snapshot().single['desired'], [whole]);
    expect(ReaderSurfaceDiagnostics.snapshot().single['residentVariants'],
        [whole]);
    expect(
        ReaderRasterDiagnostics.drainSamples()
            .where((sample) => sample.containsKey('flutterCodecWallUs')),
        isEmpty,
        reason: 'zooming/panning reuses the exact same original raster');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(ReaderSurfaceDiagnostics.activeSurfaces, 0);
    expect(ReaderSurfaceDiagnostics.residentBytes, 320 * 480 * 4);
    expect(session.sourceMetadataCount, 1);
    expect(session.retainedBytes, 320 * 480 * 4);
    ReaderRasterDiagnostics.drainSamples();
    await mount();
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'a quick warm resolution must not flash a spinner');
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 4)));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final diagnostics = ReaderSurfaceDiagnostics.snapshot();
      if (diagnostics.isNotEmpty &&
          (diagnostics.single['residentVariants'] as List).contains(whole)) {
        break;
      }
    }
    expect(ReaderSurfaceDiagnostics.snapshot().single['residentVariants'],
        [whole]);
    final warmSamples = ReaderRasterDiagnostics.drainSamples();
    expect(warmSamples.where((sample) => sample['sourceMetadataCacheHit'] == 1),
        hasLength(1));
    expect(warmSamples.where((sample) => sample['sessionRasterRestored'] == 1),
        hasLength(1));
    expect(
        warmSamples.where((sample) =>
            sample.containsKey('sourceMetadataProbe') ||
            sample.containsKey('sourcePolicyDescriptorCheck') ||
            sample.containsKey('flutterCodecWallUs')),
        isEmpty,
        reason: 'revisit verifies the file without probing or decoding again');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    session.dispose();
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    await stopWorkers();
  }, skip: !PicakeepImageEngine.isAvailable);

  testWidgets('unresolved pages delay the source spinner for 500 milliseconds',
      (tester) async {
    final changes = ChangeNotifier();
    final pending = Completer<ReaderPageSource>();
    addTearDown(changes.dispose);
    await tester.pumpWidget(MaterialApp(
        home: ReaderPageImage(
            loadSource: () => pending.future,
            resourceKey: 'delayed-source',
            viewportKey: GlobalKey(),
            transformChanges: changes,
            mode: ReaderDisplayMode.sharpFirst)));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 499));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(source);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
