import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/image_pipeline/cover_decode_target.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  final savedQuota = ImageDiskQuota.overrideForTesting;
  final imageCache = PaintingBinding.instance.imageCache;
  var sequence = 0;

  setUpAll(() async {
    final parent = Platform.isWindows
        ? Directory(r'D:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    workspace = await parent.createTemp('cover-backfill-');
    App.dataPath = p.join(workspace.path, 'app');
    App.cachePath = p.join(workspace.path, 'cache');
    ImageDiskQuota.overrideForTesting = ImageDiskQuota(
        roots: () =>
            [App.cachePath, p.join(App.dataPath, 'local_library_cache')],
        idleLimitBytes: () => 512 << 20,
        space: (_) async => const ImageDiskSpace(100 << 30, 'cover-backfill'));
  });

  setUp(() {
    CoverThumbnailCache.nativeAvailableForTesting = false;
    CoverThumbnailCache.maintenanceForTesting = (_) async {};
    CoverThumbnailCache.providerPersistenceItemLimitForTesting = 1;
    CoverThumbnailCache.providerPersistenceByteLimitForTesting = 80 * 120 * 4;
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  tearDown(() async {
    await CoverThumbnailCache.waitForProviderPersistenceForTesting();
    await CoverThumbnailCache.waitForMaintenanceForTesting();
    expect(CoverThumbnailCache.providerPersistenceBytesForTesting, 0);
    expect(CoverThumbnailCache.providerBackfillCountForTesting, 0);
    CoverThumbnailCache.nativeAvailableForTesting = null;
    CoverThumbnailCache.maintenanceForTesting = null;
    CoverThumbnailCache.providerPersistenceItemLimitForTesting = null;
    CoverThumbnailCache.providerPersistenceByteLimitForTesting = null;
    CoverThumbnailCache.providerBackfillLimitForTesting = null;
    CoverThumbnailCache.preparedImageLifetimeForTesting = null;
    CoverThumbnailCache.warmSchedulerForTesting = null;
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  tearDownAll(() async {
    ImageDiskQuota.overrideForTesting = savedQuota;
    await workspace.delete(recursive: true);
  });

  Future<File> source() async {
    final pixels = img.Image(width: 80, height: 120);
    pixels.setPixelRgb(0, 0, sequence % 256, 40, 160);
    final file = File(p.join(workspace.path, 'source-${sequence++}.png'));
    await file.writeAsBytes(img.encodePng(pixels));
    return file;
  }

  Future<File> destination(File source, {bool nativeEncodedFit = false}) async {
    final stat = await source.stat();
    final stamp = '${stat.size}|${stat.modified.microsecondsSinceEpoch}';
    final algorithm = nativeEncodedFit
        ? '${CoverThumbnailCache.derivativeAlgorithm}-native-encoded-png-v1'
        : CoverThumbnailCache.derivativeAlgorithm;
    final key = LocalCoverCache.stableHashForFileName(
        '${source.path}|$stamp|384|$algorithm');
    return File(
        p.join(LocalCoverCache.rootDirectory().path, 'thumbs', '$key.png'));
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() done,
      {required String reason}) async {
    for (var attempt = 0; !done() && attempt < 500; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(done(), isTrue, reason: reason);
  }

  Future<void> paint(
      WidgetTester tester, ImageProvider<Object> provider) async {
    await tester.pumpWidget(MaterialApp(
        home: Image(
            image: CoverDecodeTarget(provider,
                frameWidth: 80, frameHeight: 120, fit: BoxFit.contain))));
    await pumpUntil(
        tester,
        () =>
            find.byType(RawImage).evaluate().isNotEmpty &&
            tester.widget<RawImage>(find.byType(RawImage)).image != null,
        reason: 'the bounded thumbnail must paint');
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  Future<void> remove(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    imageCache.clear();
    imageCache.clearLiveImages();
  }

  Future<void> drain(WidgetTester tester) async {
    var done = false;
    Object? failure;
    await tester.runAsync(() async {
      unawaited(CoverThumbnailCache.waitForProviderPersistenceForTesting()
          .then((_) => done = true, onError: (Object error, StackTrace _) {
        failure = error;
        done = true;
      }));
    });
    await pumpUntil(tester, () => done,
        reason: 'pixel persistence and metadata backfill must finish');
    if (failure != null) throw failure!;
  }

  testWidgets('pending raster survives eviction and owns a new route callback',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final release =
        CoverThumbnailCache.deferProviderPersistenceForVisibleWork();
    var oldPageActive = true;
    try {
      final first = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => oldPageActive)))!;
      await paint(tester, first);
      await remove(tester);
      oldPageActive = false;
      final trace = CoverThumbnailTrace();
      final next = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => true, trace: trace)))!;
      expect(trace.details['memoryHit'], isFalse);
      expect(trace.details['pendingRasterHit'], isTrue);
      expect(trace.stages.where((s) => s['stage'] == 'flutterFirstFrame'),
          isEmpty);
      await paint(tester, next);
      await remove(tester);
      // Reuse the consumed provider itself after RAM eviction, as a long
      // waterfall does. It must clone pending pixels, not decode the source.
      await paint(tester, next);
      expect(trace.stages.where((s) => s['stage'] == 'pendingRasterHit'),
          hasLength(2));
      expect(trace.stages.where((s) => s['stage'] == 'flutterFirstFrame'),
          isEmpty);
      expect(
          CoverThumbnailCache.providerPersistenceBytesForTesting, 80 * 120 * 4);
    } finally {
      release();
      await remove(tester);
      await drain(tester);
    }
  });

  testWidgets(
      'painted overflow covers backfill after a long scroll and eviction',
      (tester) async {
    final release =
        CoverThumbnailCache.deferProviderPersistenceForVisibleWork();
    final files = <File>[];
    final traces = <CoverThumbnailTrace>[];
    try {
      for (var i = 0; i < 8; i++) {
        final file = (await tester.runAsync(source))!;
        final trace = CoverThumbnailTrace();
        files.add(file);
        traces.add(trace);
        final provider = (await tester.runAsync(() =>
            CoverThumbnailCache.prepareProvider(file.path, 384,
                canContinue: () => true, trace: trace)))!;
        await paint(tester, provider);
        await remove(tester);
        expect(CoverThumbnailCache.providerPersistenceBytesForTesting,
            lessThanOrEqualTo(80 * 120 * 4));
      }
      expect(CoverThumbnailCache.providerBackfillCountForTesting, 7);
      expect(
          traces.skip(1).every((trace) => trace.stages
              .any((stage) => stage['stage'] == 'persistBackfillQueued')),
          isTrue);
    } finally {
      release();
      await drain(tester);
    }
    for (final file in files.reversed) {
      final trace = CoverThumbnailTrace();
      final provider = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => true, trace: trace)))!;
      expect(trace.details['diskHit'], isTrue,
          reason: 'each consumed cover must survive loss of decoded RAM');
      expect(trace.stages.where((s) => s['stage'] == 'flutterFirstFrame'),
          isEmpty);
      await paint(tester, provider);
      await remove(tester);
      expect(trace.stages.where((s) => s['stage'] == 'warmFirstFrame'),
          hasLength(1));
    }
    expect(
        traces.skip(1).every((trace) => trace.stages
            .any((stage) => stage['stage'] == 'persistBackfillPublished')),
        isTrue);
  });

  testWidgets('unpainted overflow does not enqueue a source or retain a clone',
      (tester) async {
    CoverThumbnailCache.providerPersistenceItemLimitForTesting = 0;
    CoverThumbnailCache.preparedImageLifetimeForTesting =
        const Duration(milliseconds: 1);
    final file = (await tester.runAsync(source))!;
    final trace = CoverThumbnailTrace();
    final provider = await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true, trace: trace));
    expect(provider, isNotNull);
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    expect(CoverThumbnailCache.providerPersistenceBytesForTesting, 0);
    expect(CoverThumbnailCache.providerBackfillCountForTesting, 0);
    expect(trace.stages.where((s) => s['stage'] == 'persistBackfillQueued'),
        isEmpty);
    final thumbnail = (await tester.runAsync(() => destination(file)))!;
    expect(await tester.runAsync(thumbnail.exists), isFalse);
  });

  testWidgets('an actual queued warm load defers optional PNG persistence',
      (tester) async {
    final queue =
        ImageWorkScheduler(maxConcurrent: 1, memoryBudgetBytes: 128 << 20);
    CoverThumbnailCache.warmSchedulerForTesting = queue;
    final gate = (await tester.runAsync(() async => Completer<void>()))!;
    final blocker = (await tester.runAsync(() async => queue.submit<void>(
        key: 'warm-blocker',
        priority: ImageWorkPriority.visible,
        estimatedBytes: 1,
        run: (_) => gate.future)))!;
    final warmSource = (await tester.runAsync(source))!;
    final thumbnail = (await tester.runAsync(() => destination(warmSource)))!;
    await tester.runAsync(() async {
      await thumbnail.parent.create(recursive: true);
      await thumbnail.writeAsBytes(await warmSource.readAsBytes());
    });
    final warm = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(warmSource.path, 384,
            canContinue: () => true)))!;
    final coldSource = (await tester.runAsync(source))!;
    final trace = CoverThumbnailTrace();
    final cold = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(coldSource.path, 384,
            canContinue: () => true, trace: trace)))!;
    try {
      await tester.pumpWidget(MaterialApp(
          home: Row(children: [
        for (final provider in [warm, cold])
          Image(
              image: CoverDecodeTarget(provider,
                  frameWidth: 80, frameHeight: 120, fit: BoxFit.contain)),
      ])));
      await pumpUntil(
          tester,
          () =>
              queue.pendingCount == 2 &&
              tester
                  .widgetList<RawImage>(find.byType(RawImage))
                  .any((image) => image.image != null),
          reason:
              'warm loading must be queued while the cold first frame paints');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      expect(trace.stages.where((s) => s['stage'] == 'persistEncode'), isEmpty,
          reason:
              'provider preparation finishing must not hide queued warm work');
      await tester.runAsync(() async => gate.complete());
      await pumpUntil(tester, () => !queue.hasWork,
          reason: 'the warm load must release its real work claim');
      await tester.runAsync(() => blocker.future);
      await pumpUntil(
          tester,
          () => tester
              .widgetList<RawImage>(find.byType(RawImage))
              .every((image) => image.image != null),
          reason: 'both bounded covers must finish painting');
      await remove(tester);
      await drain(tester);
      expect(trace.stages.where((s) => s['stage'] == 'persistEncode'),
          hasLength(1));
    } finally {
      await tester.runAsync(() async {
        if (!gate.isCompleted) gate.complete();
      });
      await pumpUntil(tester, () => !queue.hasWork,
          reason: 'the test blocker must release its scheduler reservation');
      await remove(tester);
      await drain(tester);
      expect(queue.reservedBytes, 0);
    }
  });

  testWidgets(
      'backfill rejects changed and removed sources and preserves algorithm',
      (tester) async {
    CoverThumbnailCache.providerPersistenceItemLimitForTesting = 0;
    final release =
        CoverThumbnailCache.deferProviderPersistenceForVisibleWork();
    final files = <File>[];
    final thumbnails = <File>[];
    try {
      for (var i = 0; i < 3; i++) {
        final file = (await tester.runAsync(source))!;
        files.add(file);
        thumbnails.add((await tester
            .runAsync(() => destination(file, nativeEncodedFit: i == 2)))!);
        final provider = (await tester.runAsync(() =>
            CoverThumbnailCache.prepareProvider(file.path, 384,
                canContinue: () => true, nativeEncodedFit: i == 2)))!;
        await paint(tester, provider);
        await remove(tester);
      }
      await tester
          .runAsync(() => files[0].writeAsString('changed invalid source'));
      await tester.runAsync(files[1].delete);
    } finally {
      release();
      await drain(tester);
    }
    expect(await tester.runAsync(thumbnails[0].exists), isFalse);
    expect(await tester.runAsync(thumbnails[1].exists), isFalse);
    expect(await tester.runAsync(thumbnails[2].exists), isTrue);
    final trace = CoverThumbnailTrace();
    final warm = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(files[2].path, 384,
            canContinue: () => true, nativeEncodedFit: true, trace: trace)))!;
    expect(trace.details['diskHit'], isTrue);
    await paint(tester, warm);
    await remove(tester);
    final ordinary = (await tester.runAsync(() => destination(files[2])))!;
    expect(await tester.runAsync(ordinary.exists), isFalse,
        reason: 'backfill must publish under the requested algorithm identity');
  });

  testWidgets('invalidated backfill cannot republish cleared cache generation',
      (tester) async {
    CoverThumbnailCache.providerPersistenceItemLimitForTesting = 0;
    final release =
        CoverThumbnailCache.deferProviderPersistenceForVisibleWork();
    final file = (await tester.runAsync(source))!;
    final thumbnail = (await tester.runAsync(() => destination(file)))!;
    final trace = CoverThumbnailTrace();
    try {
      final provider = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => true, trace: trace)))!;
      await paint(tester, provider);
      await remove(tester);
      expect(CoverThumbnailCache.providerBackfillCountForTesting, 1);
      await pumpUntil(
          tester,
          () => trace.stages.any(
              (stage) => stage['stage'] == 'persistBackfillWaitingForIdle'),
          reason: 'invalidation must happen while the worker awaits idle');
      CoverThumbnailCache.invalidatePendingPublications();
      expect(CoverThumbnailCache.providerBackfillCountForTesting, 0);
    } finally {
      release();
      await drain(tester);
    }
    expect(await tester.runAsync(thumbnail.exists), isFalse);
    expect(await tester.runAsync(file.exists), isTrue);
  });

  testWidgets('metadata backlog has an independent finite limit without pixels',
      (tester) async {
    CoverThumbnailCache.providerPersistenceItemLimitForTesting = 0;
    CoverThumbnailCache.providerBackfillLimitForTesting = 2;
    final release =
        CoverThumbnailCache.deferProviderPersistenceForVisibleWork();
    final files = <File>[];
    try {
      for (var i = 0; i < 5; i++) {
        final file = (await tester.runAsync(source))!;
        files.add(file);
        final provider = (await tester.runAsync(() =>
            CoverThumbnailCache.prepareProvider(file.path, 384,
                canContinue: () => true)))!;
        await paint(tester, provider);
        await remove(tester);
        expect(CoverThumbnailCache.providerPersistenceBytesForTesting, 0);
        expect(CoverThumbnailCache.providerBackfillCountForTesting,
            lessThanOrEqualTo(2));
      }
    } finally {
      release();
      await drain(tester);
    }
    for (var i = 0; i < files.length; i++) {
      final thumbnail = (await tester.runAsync(() => destination(files[i])))!;
      expect(await tester.runAsync(thumbnail.exists), i >= 3);
    }
  });
}
