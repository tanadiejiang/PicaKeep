import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/image_pipeline/cover_decode_target.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  final savedQuota = ImageDiskQuota.overrideForTesting;
  final imageCache = PaintingBinding.instance.imageCache;
  final savedMaximumSize = imageCache.maximumSize;
  final savedMaximumBytes = imageCache.maximumSizeBytes;
  var sourceSequence = 0;

  setUpAll(() async {
    final parent = Platform.isWindows
        ? Directory(r'D:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    workspace = await parent.createTemp('cover-memory-reentry-');
    App.dataPath = p.join(workspace.path, 'app');
    App.cachePath = p.join(workspace.path, 'cache');
    ImageDiskQuota.overrideForTesting = ImageDiskQuota(
        roots: () =>
            [App.cachePath, p.join(App.dataPath, 'local_library_cache')],
        idleLimitBytes: () => 512 << 20,
        space: (_) async => const ImageDiskSpace(100 << 30, 'cover-test'));
  });

  setUp(() {
    CoverThumbnailCache.nativeAvailableForTesting = false;
    CoverThumbnailCache.maintenanceForTesting = (_) async {};
    imageCache.maximumSize = 100;
    imageCache.maximumSizeBytes = 32 << 20;
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  tearDown(() async {
    CoverThumbnailCache.beforeProviderPersistenceForTesting = null;
    await CoverThumbnailCache.waitForProviderPersistenceForTesting();
    await CoverThumbnailCache.waitForMaintenanceForTesting();
    CoverThumbnailCache.nativeAvailableForTesting = null;
    CoverThumbnailCache.maintenanceForTesting = null;
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  tearDownAll(() async {
    imageCache.maximumSize = savedMaximumSize;
    imageCache.maximumSizeBytes = savedMaximumBytes;
    ImageDiskQuota.overrideForTesting = savedQuota;
    await workspace.delete(recursive: true);
  });

  Future<File> source() async {
    final file = File(p.join(workspace.path, 'source-${sourceSequence++}.png'));
    await file.writeAsBytes(img.encodePng(img.Image(width: 80, height: 120)));
    return file;
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() done,
      {required String reason}) async {
    for (var attempt = 0; !done() && attempt < 400; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(done(), isTrue, reason: reason);
  }

  Future<void> drain(WidgetTester tester) async {
    var done = false;
    Object? error;
    await tester.runAsync(() async {
      unawaited(() async {
        await CoverThumbnailCache.waitForProviderPersistenceForTesting();
        await CoverThumbnailCache.waitForMaintenanceForTesting();
      }()
          .then((_) => done = true, onError: (Object failure, StackTrace _) {
        error = failure;
        done = true;
      }));
    });
    await pumpUntil(tester, () => done,
        reason: 'bounded persistence and fake event drain must complete');
    if (error != null) throw error!;
  }

  Future<void> paint(WidgetTester tester, ImageProvider<Object> provider,
      {int frameWidth = 80,
      int frameHeight = 120,
      int maximumEdge = 4096}) async {
    await tester.pumpWidget(MaterialApp(
        home: Image(
            image: CoverDecodeTarget(provider,
                frameWidth: frameWidth,
                frameHeight: frameHeight,
                maximumEdge: maximumEdge,
                fit: BoxFit.contain))));
    await pumpUntil(tester, () {
      final found = find.byType(RawImage);
      return found.evaluate().isNotEmpty &&
          tester.widget<RawImage>(found).image != null;
    }, reason: 'a prepared or cached cover must paint');
    expect(tester.takeException(), isNull);
  }

  Future<({Completer<void> entered, Completer<void> release})> blockPersistence(
      WidgetTester tester) async {
    final barriers = (await tester.runAsync(
        () async => (entered: Completer<void>(), release: Completer<void>())))!;
    CoverThumbnailCache.beforeProviderPersistenceForTesting = () async {
      if (!barriers.entered.isCompleted) barriers.entered.complete();
      await barriers.release.future;
    };
    return barriers;
  }

  Future<void> removeAndDrain(WidgetTester tester,
      ({Completer<void> entered, Completer<void> release}) barriers) async {
    if (!barriers.release.isCompleted) barriers.release.complete();
    await tester.pumpWidget(const SizedBox.shrink());
    await drain(tester);
  }

  testWidgets('persistence retries if scrolling resumes before its queued job',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final barriers = await blockPersistence(tester);
    final trace = CoverThumbnailTrace();
    var release = CoverThumbnailCache.deferProviderPersistenceForVisibleWork();
    try {
      final provider = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => true, trace: trace)))!;
      await paint(tester, provider);
      expect(barriers.entered.isCompleted, isFalse);
      release();
      await pumpUntil(tester, () => barriers.entered.isCompleted,
          reason: 'persistence must wait for stable idle after first paint');
      release = CoverThumbnailCache.deferProviderPersistenceForVisibleWork();
      barriers.release.complete();
      await pumpUntil(tester,
          () => trace.stages.any((s) => s['stage'] == 'persistSubmitted'),
          reason: 'controlled background job must be submitted');
      expect(trace.stages.where((s) => s['stage'] == 'persistEncode'), isEmpty);
      release();
      await drain(tester);
      expect(trace.stages.where((s) => s['stage'] == 'persistEncode'),
          hasLength(1),
          reason: 'resuming scroll must defer, not discard, disk persistence');
      expect(trace.stages.where((s) => s['stage'] == 'persistSubmitted'),
          hasLength(2));
    } finally {
      release();
      await removeAndDrain(tester, barriers);
    }
  });

  testWidgets('route reentry reuses decoded pixels before PNG persistence',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final barriers = await blockPersistence(tester);
    var firstPageActive = true;
    final firstTrace = CoverThumbnailTrace();
    final first = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => firstPageActive, trace: firstTrace)))!;
    try {
      await paint(tester, first);
      await pumpUntil(tester, () => barriers.entered.isCompleted,
          reason: 'persistence must be blocked after first paint');
      expect(firstTrace.stages.where((s) => s['stage'] == 'flutterFirstFrame'),
          hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      firstPageActive = false;
      final firstKey = CoverDecodeTarget.cacheKeyForBoundedProvider(first);
      expect(imageCache.statusForKey(firstKey).keepAlive, isTrue);

      final nextTrace = CoverThumbnailTrace();
      final next = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => true, trace: nextTrace)))!;
      expect(identical(next, first), isFalse,
          reason: 'the new route must own a fresh cancellation callback');
      expect(nextTrace.details['memoryHit'], isTrue);
      expect(
          nextTrace.stages.where((s) => s['stage'] == 'nativeProbe'), isEmpty);
      expect(nextTrace.stages.where((s) => s['stage'] == 'flutterFirstFrame'),
          isEmpty);
      expect(nextTrace.stages.where((s) => s['stage'] == 'cacheStat'), isEmpty);
      await paint(tester, next, frameWidth: 160, frameHeight: 80);
      expect(nextTrace.stages.where((s) => s['stage'] == 'warmFirstFrame'),
          isEmpty,
          reason: 'reentry must resolve the cached raster, not a PNG');
      expect(
          await tester.runAsync(() => CoverDecodeTarget(next,
                  frameWidth: 160, frameHeight: 80, fit: BoxFit.contain)
              .obtainKey(ImageConfiguration.empty)),
          firstKey,
          reason: 'a new placeholder aspect cannot change the bounded key');

      // When Flutter RAM is evicted before PNG publication, the independently
      // bounded persistence clone must keep the source from being decoded again.
      await tester.pumpWidget(const SizedBox.shrink());
      imageCache.clear();
      imageCache.clearLiveImages();
      final clearedTrace = CoverThumbnailTrace();
      final cleared = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => true, trace: clearedTrace)))!;
      expect(clearedTrace.details['memoryHit'], isFalse);
      expect(clearedTrace.details['pendingRasterHit'], isTrue);
      expect(
          clearedTrace.stages.where((s) => s['stage'] == 'flutterFirstFrame'),
          isEmpty);
      await paint(tester, cleared);
    } finally {
      await removeAndDrain(tester, barriers);
    }
  });

  testWidgets(
      'memory provider reload uses the new route callback after eviction',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final barriers = await blockPersistence(tester);
    var oldPageActive = true;
    final old = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => oldPageActive)))!;
    try {
      await paint(tester, old);
      await pumpUntil(tester, () => barriers.entered.isCompleted,
          reason: 'first PNG must remain unpublished');
      await tester.pumpWidget(const SizedBox.shrink());
      oldPageActive = false;
      final trace = CoverThumbnailTrace();
      final current = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => true, trace: trace)))!;
      expect(trace.details['memoryHit'], isTrue);
      imageCache.clear();
      imageCache.clearLiveImages();
      await paint(tester, current);
      expect(
          trace.stages.where((s) => s['stage'] == 'flutterFirstFrame'), isEmpty,
          reason:
              'eviction must reuse pending pixels with the active callback');
      expect(trace.details['pendingRasterHit'], isTrue);
    } finally {
      await removeAndDrain(tester, barriers);
    }
  });

  testWidgets('a live pending stream is not a completed memory hit',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final barriers = await blockPersistence(tester);
    final first = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true)))!;
    ui.Image? retained;
    Completer<ImageInfo>? pending;
    try {
      await paint(tester, first);
      retained = tester.widget<RawImage>(find.byType(RawImage)).image!.clone();
      await pumpUntil(tester, () => barriers.entered.isCompleted,
          reason: 'first image must be painted before test pending loader');
      await tester.pumpWidget(const SizedBox.shrink());
      final key = CoverDecodeTarget.cacheKeyForBoundedProvider(first);
      imageCache.evict(key);
      pending = (await tester.runAsync(() async => Completer<ImageInfo>()))!;
      imageCache.putIfAbsent(
          key, () => OneFrameImageStreamCompleter(pending!.future));
      expect(imageCache.statusForKey(key).pending, isTrue);
      expect(imageCache.statusForKey(key).live, isTrue);
      final trace = CoverThumbnailTrace();
      final next = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => true, trace: trace)))!;
      expect(trace.details['memoryHit'], isFalse);
      expect(
          trace.stages.where((s) => s['stage'] == 'flutterFirstFrame'), isEmpty,
          reason:
              'an old pending stream cannot hide independent retained pixels');
      expect(trace.details['pendingRasterHit'], isTrue);
      pending.complete(ImageInfo(image: retained));
      retained = null;
      await pumpUntil(tester, () => !imageCache.statusForKey(key).pending,
          reason: 'controlled pending loader must complete');
      imageCache.evict(key);
      await paint(tester, next);
    } finally {
      if (pending != null && !pending.isCompleted && retained != null) {
        pending.complete(ImageInfo(image: retained));
        retained = null;
      }
      retained?.dispose();
      await removeAndDrain(tester, barriers);
    }
  });

  testWidgets('source replacement and invalidation reject old memory keys',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final barriers = await blockPersistence(tester);
    final first = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true)))!;
    try {
      await paint(tester, first);
      await pumpUntil(tester, () => barriers.entered.isCompleted,
          reason: 'old disk publication must remain blocked');
      await tester.pumpWidget(const SizedBox.shrink());
      CoverThumbnailCache.invalidatePendingPublications();
      final invalidatedTrace = CoverThumbnailTrace();
      final invalidated = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => true, trace: invalidatedTrace)))!;
      expect(invalidatedTrace.details['memoryHit'], isFalse);
      expect(
          invalidatedTrace.stages
              .where((s) => s['stage'] == 'flutterFirstFrame'),
          hasLength(1));
      expect(invalidated, isNot(first),
          reason: 'publication generations must own distinct decoded keys');
      await paint(tester, invalidated);
      await tester.pumpWidget(const SizedBox.shrink());

      await tester.runAsync(() => file.writeAsString('changed invalid source'));
      final changedTrace = CoverThumbnailTrace();
      final changed = await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => true, trace: changedTrace));
      expect(changed, isNull);
      expect(changedTrace.details['memoryHit'], isFalse,
          reason: 'new source stat must not alias the old decoded image');
    } finally {
      await removeAndDrain(tester, barriers);
    }
  });

  testWidgets(
      'disk warm keeps bounded pixels and honors stricter caller limits',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final first = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true)))!;
    await paint(tester, first);
    await tester.pumpWidget(const SizedBox.shrink());
    await drain(tester);
    imageCache.clear();
    imageCache.clearLiveImages();

    final trace = CoverThumbnailTrace();
    final warm = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true, trace: trace)))!;
    expect(trace.details['diskHit'], isTrue);
    await paint(tester, warm, frameWidth: 20, frameHeight: 30);
    final pixels = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect((pixels.width, pixels.height), (80, 120),
        reason:
            'a thumbnail already bounded at its bucket must not be resized');
    expect(
        trace.stages.where((s) => s['stage'] == 'flutterFirstFrame'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());

    final strict = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true)))!;
    await paint(tester, strict,
        frameWidth: 400, frameHeight: 400, maximumEdge: 40);
    final constrained = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect(constrained.width, lessThanOrEqualTo(40));
    expect(constrained.height, lessThanOrEqualTo(40),
        reason: 'the marker cannot bypass an explicit stricter pixel budget');
    await tester.pumpWidget(const SizedBox.shrink());
    await drain(tester);
  });
}
