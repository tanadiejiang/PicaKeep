import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart' as native;

class _AfterStage extends CoverThumbnailTrace {
  _AfterStage(this.after);
  final Future<void> Function(String stage) after;
  @override
  Future<T> measure<T>(String stage, Future<T> Function() action) async {
    final result = await super.measure(stage, action);
    await after(stage);
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  final savedQuota = ImageDiskQuota.overrideForTesting;
  var sourceSequence = 0;

  setUpAll(() async {
    final parent = Platform.isWindows
        ? Directory(r'D:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    workspace = await parent.createTemp('cover-recovery-');
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
  });

  tearDown(() async {
    CoverThumbnailCache.nativeProbeForTesting = null;
    CoverThumbnailCache.preparedImageLifetimeForTesting = null;
    CoverThumbnailCache.beforeProviderPersistenceForTesting = null;
    await CoverThumbnailCache.waitForProviderPersistenceForTesting();
    await CoverThumbnailCache.waitForMaintenanceForTesting();
    CoverThumbnailCache.nativeAvailableForTesting = null;
    CoverThumbnailCache.maintenanceForTesting = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDownAll(() async {
    ImageDiskQuota.overrideForTesting = savedQuota;
    await workspace.delete(recursive: true);
  });

  Future<File> source() async {
    final file = File(p.join(workspace.path, 'source-${sourceSequence++}.png'));
    final pixels = img.Image(width: 80, height: 120);
    for (var y = 0; y < pixels.height; y++) {
      for (var x = 0; x < pixels.width; x++) {
        pixels.setPixelRgb(x, y, x * 3, y * 2, (x + y) % 256);
      }
    }
    await file.writeAsBytes(img.encodePng(pixels));
    return file;
  }

  Future<void> paint(WidgetTester tester, ImageProvider<Object> provider,
      {void Function(Object)? onError}) async {
    await tester.pumpWidget(MaterialApp(
        home: Image(
            image: provider,
            errorBuilder: onError == null
                ? null
                : (_, error, __) {
                    onError(error);
                    return const SizedBox.shrink();
                  })));
    for (var attempt = 0; attempt < 150; attempt++) {
      final raw = find.byType(RawImage);
      if (raw.evaluate().isNotEmpty &&
          tester.widget<RawImage>(raw).image != null) {
        return;
      }
      if (onError != null && find.byType(RawImage).evaluate().isEmpty) return;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() completed,
      {required String reason}) async {
    for (var attempt = 0; !completed() && attempt < 400; attempt++) {
      // Async provider reloads originate in the widget's fake zone. Progress
      // its zero-duration event Futures as well as real file/codec callbacks.
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(completed(), isTrue, reason: reason);
  }

  Future<void> drain(
      WidgetTester tester, Future<void> Function() waiting) async {
    var completed = false;
    Object? error;
    await tester.runAsync(() async {
      unawaited(waiting().then((_) => completed = true,
          onError: (Object failure, StackTrace _) {
        error = failure;
        completed = true;
      }));
    });
    await pumpUntil(tester, () => completed,
        reason: 'bounded persistence/maintenance drain must finish');
    if (error != null) throw error!;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await drain(
        tester, CoverThumbnailCache.waitForProviderPersistenceForTesting);
    await drain(tester, CoverThumbnailCache.waitForMaintenanceForTesting);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  testWidgets(
      'corrupt nonempty warm thumbnail rebuilds once and preserves source',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final original = (await tester.runAsync(file.readAsBytes))!;
    final thumb = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareDisplay(file.path, 384,
            canContinue: () => true)))!;
    await tester.runAsync(() => File(thumb).writeAsString('corrupt PNG cache'));
    final trace = CoverThumbnailTrace();
    final provider = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true, trace: trace)))!;
    expect(trace.details['diskHit'], isTrue);
    await paint(tester, provider);
    final shown = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect((shown.width, shown.height), (80, 120));
    expect(
        trace.stages
            .where((stage) => stage['stage'] == 'warmThumbnailInvalidated'),
        hasLength(1));
    await close(tester);
    expect(await tester.runAsync(file.readAsBytes), original);
    final warmTrace = CoverThumbnailTrace();
    final warm = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true, trace: warmTrace)))!;
    await paint(tester, warm);
    expect(
        warmTrace.stages
            .where((stage) => stage['stage'] == 'flutterFirstFrame'),
        isEmpty,
        reason: 'repaired thumbnail must be reused without source decode');
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('expired unpainted provider redecodes then persists after paint',
      (tester) async {
    CoverThumbnailCache.preparedImageLifetimeForTesting =
        const Duration(milliseconds: 1);
    final file = (await tester.runAsync(source))!;
    final trace = CoverThumbnailTrace();
    final provider = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true, trace: trace)))!;
    await drain(
        tester, CoverThumbnailCache.waitForProviderPersistenceForTesting);
    expect(trace.stages.where((stage) => stage['stage'] == 'persistEncode'),
        isEmpty);
    await paint(tester, provider);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(trace.stages.where((stage) => stage['stage'] == 'flutterFirstFrame'),
        hasLength(2),
        reason: 'the first prepared image has actually expired');
    await close(tester);
    expect(trace.stages.where((stage) => stage['stage'] == 'persistEncode'),
        hasLength(1));
    final warmTrace = CoverThumbnailTrace();
    final warm = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true, trace: warmTrace)))!;
    expect(warmTrace.details['diskHit'], isTrue);
    await paint(tester, warm);
    expect(
        warmTrace.stages
            .where((stage) => stage['stage'] == 'flutterFirstFrame'),
        isEmpty);
    await close(tester);
  });

  testWidgets('already prepared pixels remain paintable when page work pauses',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final trace = CoverThumbnailTrace();
    var active = true;
    final provider = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => active, trace: trace)))!;
    active = false;
    final errors = <Object>[];
    await paint(tester, provider, onError: errors.add);
    expect(errors, isEmpty);
    final shown = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect((shown.width, shown.height), (80, 120));
    expect(trace.stages.where((stage) => stage['stage'] == 'flutterFirstFrame'),
        hasLength(1),
        reason: 'prepared first image requires no new decode');
    await close(tester);
  });

  testWidgets(
      'corrupt read cannot remove a thumbnail replaced by another publisher',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final thumb = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareDisplay(file.path, 384,
            canContinue: () => true)))!;
    await tester
        .runAsync(() => File(thumb).writeAsString('corrupt cached PNG'));
    final barriers = (await tester
        .runAsync(() async => (Completer<void>(), Completer<void>())))!;
    var persistenceEntered = false;
    CoverThumbnailCache.beforeProviderPersistenceForTesting = () async {
      persistenceEntered = true;
      barriers.$1.complete();
      await barriers.$2.future;
    };
    final trace = _AfterStage((stage) async {
      if (stage != 'warmBuffer') return;
      await File(thumb).writeAsBytes(await file.readAsBytes(), flush: true);
      await File(thumb)
          .setLastModified(DateTime.now().add(const Duration(seconds: 1)));
    });
    final provider = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true, trace: trace)))!;
    try {
      await paint(tester, provider);
      await pumpUntil(tester, () => persistenceEntered,
          reason: 'recovery persistence must reach its controlled barrier');
      expect(await tester.runAsync(() => File(thumb).exists()), isTrue,
          reason:
              'the newer publisher file must survive before recovery publishes');
      final bytes = (await tester.runAsync(() => File(thumb).readAsBytes()))!;
      expect(img.decodePng(bytes), isNotNull);
    } finally {
      barriers.$2.complete();
      await close(tester);
    }
  });

  for (final invalidate in [false, true]) {
    testWidgets(
        invalidate
            ? 'publication invalidation prevents old provider reload and publication'
            : 'leaving page prevents old expired provider reload',
        (tester) async {
      CoverThumbnailCache.preparedImageLifetimeForTesting =
          const Duration(milliseconds: 1);
      final file = (await tester.runAsync(source))!;
      final trace = CoverThumbnailTrace();
      var active = true;
      final provider = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => active, trace: trace)))!;
      await drain(
          tester, CoverThumbnailCache.waitForProviderPersistenceForTesting);
      if (invalidate) {
        CoverThumbnailCache.invalidatePendingPublications();
      } else {
        active = false;
      }
      final errors = <Object>[];
      await paint(tester, provider, onError: errors.add);
      for (var attempt = 0; errors.isEmpty && attempt < 20; attempt++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(errors, hasLength(1));
      expect(errors.single, isA<ImageWorkCancelled>());
      expect(
          trace.stages.where((stage) => stage['stage'] == 'flutterFirstFrame'),
          hasLength(1));
      expect(trace.stages.where((stage) => stage['stage'] == 'persistEncode'),
          isEmpty);
      await close(tester);
    });
  }

  testWidgets(
      'bad source during corrupt-thumbnail repair fails without retry loop',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    await tester.runAsync(() => file.writeAsString('invalid original image'));
    final stat = (await tester.runAsync(file.stat))!;
    final key = p.join(App.dataPath, 'local_library_cache', 'covers', 'thumbs');
    // Generate the exact destination identity without reading or decoding an
    // invalid original: a temporary cache stat override is unnecessary.
    final stamp = '${stat.size}|${stat.modified.microsecondsSinceEpoch}';
    final hash = LocalCoverCache.stableHashForFileName(
        '${file.path}|$stamp|384|${CoverThumbnailCache.derivativeAlgorithm}');
    final thumb = File(p.join(key, '$hash.png'));
    await tester.runAsync(() async {
      await thumb.parent.create(recursive: true);
      await thumb.writeAsString('invalid cached image');
    });
    final trace = CoverThumbnailTrace();
    final provider = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true, trace: trace)))!;
    final errors = <Object>[];
    await paint(tester, provider, onError: errors.add);
    for (var attempt = 0; errors.isEmpty && attempt < 30; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(errors, hasLength(1));
    expect(
        trace.stages
            .where((stage) => stage['stage'] == 'warmThumbnailInvalidated'),
        hasLength(1));
    expect(await tester.runAsync(() => file.readAsString()),
        'invalid original image');
    await close(tester);
  });

  test(
      'native probe queue pressure is typed; only unsupported uses Flutter fallback',
      () async {
    final file = await source();
    CoverThumbnailCache.nativeAvailableForTesting = true;
    CoverThumbnailCache.nativeProbeForTesting =
        (_) async => throw const native.ImageEngineQueueExceeded(128);
    final busyTrace = CoverThumbnailTrace();
    await expectLater(
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true, trace: busyTrace),
        throwsA(isA<ImageWorkQueueExceeded>()));
    expect(
        busyTrace.stages
            .where((stage) => stage['stage'] == 'flutterFirstFrame'),
        isEmpty);
    CoverThumbnailCache.nativeProbeForTesting =
        (_) async => throw const native.ImageEngineException(2, 'Cancelled');
    expect(
        await CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true),
        isNull);
    CoverThumbnailCache.nativeProbeForTesting =
        (_) async => throw const native.ImageEngineException(4, 'Unsupported');
    final fallbackTrace = CoverThumbnailTrace();
    final fallback = await CoverThumbnailCache.prepareProvider(file.path, 384,
        canContinue: () => true, trace: fallbackTrace);
    expect(fallback, isNotNull);
    expect(fallbackTrace.details['backend'], 'flutter');
    expect(
        fallbackTrace.stages
            .where((stage) => stage['stage'] == 'flutterFirstFrame'),
        hasLength(1));
    final stream = fallback!.resolve(ImageConfiguration.empty);
    final ready = Completer<void>();
    final listener = ImageStreamListener((_, __) => ready.complete(),
        onError: ready.completeError);
    stream.addListener(listener);
    await ready.future;
    stream.removeListener(listener);
    // No frame was painted in this plain test; its optional write times out.
    // Consuming the first handle also cancels its separate five-second expiry.
    await CoverThumbnailCache.waitForProviderPersistenceForTesting();
  });
}
