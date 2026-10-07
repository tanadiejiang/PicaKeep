import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/image_pipeline/cover_decode_target.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  final imageCache = PaintingBinding.instance.imageCache;
  var sequence = 0;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('cover-warm-queue-');
    App.dataPath = p.join(workspace.path, 'app');
    App.cachePath = p.join(workspace.path, 'cache');
  });

  setUp(() {
    CoverThumbnailCache.nativeAvailableForTesting = false;
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  tearDown(() {
    final queue = CoverThumbnailCache.warmSchedulerForTesting;
    expect(queue?.pendingCount ?? 0, 0);
    expect(queue?.reservedBytes ?? 0, 0);
    CoverThumbnailCache.warmSchedulerForTesting = null;
    CoverThumbnailCache.nativeAvailableForTesting = null;
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  tearDownAll(() async {
    await workspace.delete(recursive: true);
  });

  Future<
      ({
        File source,
        File thumbnail,
        List<int> bytes,
        ImageProvider<Object> provider,
        CoverThumbnailTrace trace
      })> prepare({bool Function()? canContinue}) async {
    final pixels = img.Image(width: 80, height: 120);
    pixels.setPixelRgb(0, 0, 255, 20, 40);
    final bytes = img.encodePng(pixels);
    final source = File(p.join(workspace.path, 'source-${sequence++}.png'));
    await source.writeAsBytes(bytes);
    final stat = await source.stat();
    final stamp = '${stat.size}|${stat.modified.microsecondsSinceEpoch}';
    final key = LocalCoverCache.stableHashForFileName(
        '${source.path}|$stamp|384|${CoverThumbnailCache.derivativeAlgorithm}');
    final thumbnail = File(
        p.join(LocalCoverCache.rootDirectory().path, 'thumbs', '$key.png'));
    await thumbnail.parent.create(recursive: true);
    await thumbnail.writeAsBytes(bytes);
    final trace = CoverThumbnailTrace();
    final provider = (await CoverThumbnailCache.prepareProvider(
        source.path, 384,
        canContinue: canContinue ?? () => true, trace: trace))!;
    expect(trace.details['diskHit'], isTrue);
    return (
      source: source,
      thumbnail: thumbnail,
      bytes: bytes,
      provider: provider,
      trace: trace
    );
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() done,
      {required String reason}) async {
    for (var attempt = 0; !done() && attempt < 300; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(done(), isTrue, reason: reason);
  }

  Future<void> paint(WidgetTester tester, List<ImageProvider<Object>> providers,
      List<Object> errors) async {
    await tester.pumpWidget(MaterialApp(
        home: Row(children: [
      for (final provider in providers)
        Image(
          image: CoverDecodeTarget(provider,
              frameWidth: 80, frameHeight: 120, fit: BoxFit.contain),
          errorBuilder: (_, error, __) {
            errors.add(error);
            return const SizedBox.shrink();
          },
        ),
    ])));
  }

  Future<void> close(WidgetTester tester, ImageWorkScheduler queue) async {
    await pumpUntil(tester, () => !queue.hasWork,
        reason: 'warm image jobs must release their scheduler reservations');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }

  Future<void> releaseGate(WidgetTester tester, Completer<void> gate) async {
    await tester.runAsync(() async {
      if (!gate.isCompleted) gate.complete();
    });
  }

  testWidgets('disk warm uses the reserved slot while a cold cover is blocked',
      (tester) async {
    final queue = ImageWorkScheduler(memoryBudgetBytes: 128 << 20);
    CoverThumbnailCache.warmSchedulerForTesting = queue;
    final gate = (await tester.runAsync(() async => Completer<void>()))!;
    final blocker = (await tester.runAsync(() async => queue.submit<void>(
        key: 'existing-cover',
        priority: ImageWorkPriority.cover,
        estimatedBytes: 1,
        run: (_) => gate.future)))!;
    final first = (await tester.runAsync(prepare))!;
    final second = (await tester.runAsync(prepare))!;
    final third = (await tester.runAsync(prepare))!;
    final fixtures = [first, second, third];
    final errors = <Object>[];
    try {
      await paint(
          tester, [for (final fixture in fixtures) fixture.provider], errors);
      await pumpUntil(
          tester,
          () =>
              find.byType(RawImage).evaluate().length == 3 &&
              tester
                  .widgetList<RawImage>(find.byType(RawImage))
                  .every((image) => image.image != null),
          reason:
              'warm thumbnails must paint before the cold cover is released');
      expect(gate.isCompleted, isFalse);
      expect(queue.stateOf('existing-cover'), ImageWorkState.running);
      expect(queue.reservedBytes, 1,
          reason: 'all warm reservations must be released after their frames');
      await releaseGate(tester, gate);
      // Scheduler callbacks can cross from runAsync into the widget's fake
      // zone. Keep pumping until the blocking job has finished before awaiting
      // its already completed ticket in the real zone.
      await pumpUntil(tester, () => queue.stateOf('existing-cover') == null,
          reason:
              'the released blocking job must finish without a fake-zone wait');
      await tester.runAsync(() => blocker.future);
      await pumpUntil(
          tester,
          () =>
              find.byType(RawImage).evaluate().length == 3 &&
              tester
                  .widgetList<RawImage>(find.byType(RawImage))
                  .every((image) => image.image != null),
          reason: 'all admitted disk thumbnails must paint');
      expect(errors, isEmpty);
      for (final fixture in fixtures) {
        expect(
            fixture.trace.stages
                .where((stage) => stage['stage'] == 'warmQueueWait'),
            hasLength(1));
        expect(
            fixture.trace.stages
                .where((stage) => stage['stage'] == 'warmFirstFrame'),
            hasLength(1));
        expect(
            fixture.trace.stages
                .where((stage) => stage['stage'] == 'flutterFirstFrame'),
            isEmpty,
            reason: 'warm loading must not decode the original');
        expect(await tester.runAsync(fixture.thumbnail.readAsBytes),
            fixture.bytes);
      }
    } finally {
      await releaseGate(tester, gate);
      await close(tester, queue);
    }
  });

  for (final budgetFailure in [false, true]) {
    testWidgets(
        budgetFailure
            ? 'warm budget rejection preserves the valid thumbnail and original'
            : 'warm queue rejection preserves the valid thumbnail and original',
        (tester) async {
      final queue = ImageWorkScheduler(
          maxExecutionPending: 1,
          memoryBudgetBytes: budgetFailure ? 1024 : 128 << 20);
      CoverThumbnailCache.warmSchedulerForTesting = queue;
      final gate = (await tester.runAsync(() async => Completer<void>()))!;
      if (!budgetFailure) {
        await tester.runAsync(() async {
          final blocker = queue.submit<void>(
              key: 'full-cover-queue',
              priority: ImageWorkPriority.cover,
              estimatedBytes: 1,
              run: (_) => gate.future);
          unawaited(blocker.future);
        });
      }
      final fixture = (await tester.runAsync(prepare))!;
      final errors = <Object>[];
      try {
        await paint(tester, [fixture.provider], errors);
        await pumpUntil(tester, () => errors.isNotEmpty,
            reason:
                'admission rejection must propagate as a typed image error');
        expect(
            errors.first,
            budgetFailure
                ? isA<ImageWorkBudgetExceeded>()
                : isA<ImageWorkQueueExceeded>());
        expect(
            fixture.trace.stages
                .where((stage) => stage['stage'] == 'warmThumbnailInvalidated'),
            isEmpty);
        expect(
            fixture.trace.stages
                .where((stage) => stage['stage'] == 'flutterFirstFrame'),
            isEmpty,
            reason:
                'admission must not trigger an original-file recovery decode');
        expect(await tester.runAsync(fixture.thumbnail.readAsBytes),
            fixture.bytes);
        expect(
            await tester.runAsync(fixture.source.readAsBytes), fixture.bytes);
      } finally {
        await releaseGate(tester, gate);
        await close(tester, queue);
      }
    });
  }

  for (final invalidate in [false, true]) {
    testWidgets(
        invalidate
            ? 'queued warm load observes publication invalidation without deleting PNG'
            : 'queued warm load observes leaving the page without deleting PNG',
        (tester) async {
      final queue =
          ImageWorkScheduler(maxConcurrent: 1, memoryBudgetBytes: 128 << 20);
      CoverThumbnailCache.warmSchedulerForTesting = queue;
      final gate = (await tester.runAsync(() async => Completer<void>()))!;
      await tester.runAsync(() async {
        final blocker = queue.submit<void>(
            key: 'cover-before-cancel',
            priority: ImageWorkPriority.cover,
            estimatedBytes: 1,
            run: (_) => gate.future);
        unawaited(blocker.future);
      });
      var active = true;
      final fixture =
          (await tester.runAsync(() => prepare(canContinue: () => active)))!;
      final errors = <Object>[];
      try {
        await paint(tester, [fixture.provider], errors);
        await pumpUntil(tester, () => queue.pendingCount == 2,
            reason: 'the warm load must be awaiting its scheduler slot');
        if (invalidate) {
          CoverThumbnailCache.invalidatePendingPublications();
        } else {
          active = false;
        }
        await releaseGate(tester, gate);
        await pumpUntil(tester, () => errors.isNotEmpty,
            reason: 'stale queued work must be cancelled when admitted');
        expect(errors.first, isA<ImageWorkCancelled>());
        expect(
            fixture.trace.stages
                .where((stage) => stage['stage'] == 'warmBuffer'),
            isEmpty);
        expect(
            fixture.trace.stages
                .where((stage) => stage['stage'] == 'warmThumbnailInvalidated'),
            isEmpty);
        expect(await tester.runAsync(fixture.thumbnail.readAsBytes),
            fixture.bytes);
        expect(
            await tester.runAsync(fixture.source.readAsBytes), fixture.bytes);
      } finally {
        await releaseGate(tester, gate);
        await close(tester, queue);
      }
    });
  }
}
