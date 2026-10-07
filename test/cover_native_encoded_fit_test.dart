import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

class _AfterStage extends CoverThumbnailTrace {
  _AfterStage(this.after);
  final Future<void> Function(String, Object?) after;

  @override
  Future<T> measure<T>(String stage, Future<T> Function() action) async {
    final result = await super.measure(stage, action);
    await after(stage, result);
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final supported = PicakeepImageEngine.isAvailable;
  final oldQuota = ImageDiskQuota.overrideForTesting;
  late Directory workspace;
  var serial = 0;

  setUpAll(() async {
    final parent = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    workspace = await parent.createTemp('cover-native-encoded-fit-');
    App.dataPath = p.join(workspace.path, 'data');
    App.cachePath = p.join(workspace.path, 'cache');
    CoverThumbnailCache.maintenanceForTesting = (_) async {};
    ImageDiskQuota.overrideForTesting = ImageDiskQuota(
        roots: () =>
            [App.cachePath, p.join(App.dataPath, 'local_library_cache')],
        idleLimitBytes: () => 512 << 20,
        space: (_) async =>
            const ImageDiskSpace(100 << 30, 'candidate-fixture'));
  });
  tearDownAll(() async {
    await CoverThumbnailCache.waitForProviderPersistenceForTesting();
    await CoverThumbnailCache.waitForMaintenanceForTesting();
    await PicakeepImageEngine.shutdownIdleWorkers();
    CoverThumbnailCache.maintenanceForTesting = null;
    ImageDiskQuota.overrideForTesting = oldQuota;
    await workspace.delete(recursive: true);
  });

  Future<File> source({bool alpha = false, bool jpeg = false}) async {
    final image = img.Image(width: 1001, height: 777, numChannels: 4);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgba(
            x,
            y,
            (x * 19 + y * 3) & 255,
            (x * 7 + y * 31) & 255,
            (x * 5 + y * 13) & 255,
            alpha ? [0, 1, 64, 128, 254, 255][(x ~/ 21 + y ~/ 17) % 6] : 255);
      }
    }
    return File(p.join(
            workspace.path, 'source-${serial++}.${jpeg ? 'jpg' : 'png'}'))
        .writeAsBytes(jpeg ? img.encodeJpg(image) : img.encodePng(image));
  }

  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 300; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
      if (ready()) return;
    }
    expect(ready(), isTrue, reason: 'candidate fixture did not drain');
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester
        .runAsync(CoverThumbnailCache.waitForProviderPersistenceForTesting);
    await tester.runAsync(CoverThumbnailCache.waitForMaintenanceForTesting);
    await until(tester, () => !ImageWorkScheduler.shared.hasWork);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ImageTemporaryPool.shared.reservedBytes, 0);
    expect(ImageDiskQuota.shared.activeBytes, 0);
    expect(PicakeepImageEngine.workerDiagnostics['activeJobs'], 0);
    expect(PicakeepImageEngine.workerDiagnostics['queuedJobs'], 0);
    final shutdown = PicakeepImageEngine.shutdownIdleWorkers();
    await until(tester,
        () => PicakeepImageEngine.workerDiagnostics['workersAlive'] == 0);
    await shutdown;
    expect(tester.takeException(), isNull);
  }

  Future<Uint8List> pixels(WidgetTester tester) async {
    final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
    final bytes = (await tester
        .runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    return bytes.buffer.asUint8List();
  }

  for (final alpha in [false, true]) {
    testWidgets(
        'lossless encoded cover exact pixels and warm cache alpha=$alpha',
        (tester) async {
      final file = (await tester.runAsync(() => source(alpha: alpha)))!;
      final original = (await tester.runAsync(file.readAsBytes))!;
      final stat = (await tester.runAsync(file.stat))!;
      final trace = CoverThumbnailTrace();
      final provider = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => true, nativeEncodedFit: true, trace: trace)))!;
      expect(trace.details['backend'], 'native-encoded-png');
      await tester.pumpWidget(MaterialApp(home: Image(image: provider)));
      final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
      expect((image.width, image.height), (384, 299));
      final actual = await pixels(tester);
      final reference = (await tester.runAsync(() async {
        final referencePixels = await const PicakeepImageEngine().decodeRegion(
            file.path, const NativeImageRect(0, 0, 1001, 777),
            backingPath: p.join(workspace.path, 'reference-${serial++}.rgba'),
            outputWidth: 384,
            outputHeight: 299,
            memoryBudgetBytes: 64 << 20,
            diskBudgetBytes: 1,
            premultiplyAlpha: true);
        try {
          return Uint8List.fromList(referencePixels.bytes);
        } finally {
          referencePixels.dispose();
        }
      }))!;
      expect(actual, reference,
          reason:
              'PNG codec must retain native thumbnail premultiplied pixels');
      await tester
          .runAsync(CoverThumbnailCache.waitForProviderPersistenceForTesting);
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      final warmTrace = CoverThumbnailTrace();
      final warm = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => true,
              nativeEncodedFit: true,
              trace: warmTrace)))!;
      expect(warmTrace.details['diskHit'], isTrue);
      await tester.pumpWidget(MaterialApp(home: Image(image: warm)));
      await until(tester,
          () => tester.widget<RawImage>(find.byType(RawImage)).image != null);
      expect(await pixels(tester), actual,
          reason: 'warm PNG must retain actual cold pixels');
      final defaultTrace = CoverThumbnailTrace();
      final ordinary = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => true, trace: defaultTrace)))!;
      expect(defaultTrace.details['diskHit'], isFalse,
          reason:
              'opt-in native thumbnail must not overwrite default Flutter cache');
      expect(defaultTrace.details['backend'], 'flutter');
      await tester.pumpWidget(MaterialApp(home: Image(image: ordinary)));
      await close(tester);
      expect(await tester.runAsync(file.readAsBytes), original);
      final after = (await tester.runAsync(file.stat))!;
      expect((after.size, after.modified), (stat.size, stat.modified));
      expect(trace.details['nativePngEncodedBytes'],
          lessThanOrEqualTo(trace.details['encodedLimitBytes'] as int));
    }, skip: !supported);
  }

  for (final late in [false, true]) {
    testWidgets(
        'cancel encoded cover ${late ? 'after ui.Image creation' : 'after native encoding'} releases results',
        (tester) async {
      final file = (await tester.runAsync(source))!;
      var allowed = true;
      ui.Image? lateImage;
      NativeEncodedImage? cancelledPng;
      final stage = late ? 'nativePngFirstFrame' : 'nativePngEncode';
      final trace = _AfterStage((name, value) async {
        if (name == stage) {
          expect(DerivedImageStore.isPathLeased(file.path), isTrue);
          if (late) {
            lateImage = (value as ui.FrameInfo).image;
          } else {
            cancelledPng = value as NativeEncodedImage;
          }
          allowed = false;
        }
      });
      final provider = await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => allowed,
              nativeEncodedFit: true,
              trace: trace));
      expect(provider, isNull);
      expect(trace.stages.where((item) => item['stage'] == stage), isNotEmpty);
      if (late) {
        expect(lateImage!.debugDisposed, isTrue);
        expect(lateImage!.debugGetOpenHandleStackTraces(), isEmpty);
      } else {
        expect(() => cancelledPng!.bytes, throwsStateError);
        expect(
            trace.stages
                .where((item) => item['stage'] == 'nativePngFirstFrame'),
            isEmpty);
      }
      await close(tester);
      expect(DerivedImageStore.isPathLeased(file.path), isFalse);
      final retry = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => true, nativeEncodedFit: true)))!;
      await tester.pumpWidget(MaterialApp(home: Image(image: retry)));
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      await close(tester);
    }, skip: !supported);
  }

  testWidgets(
      'shared candidate keeps the remaining consumer after cancellation',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final barrier = (await tester
        .runAsync(() async => (Completer<void>(), Completer<void>())))!;
    var firstAllowed = true;
    var secondAllowed = true;
    final trace = _AfterStage((name, _) async {
      if (name == 'nativePngEncode') {
        barrier.$1.complete();
        await barrier.$2.future;
      }
    });
    final results = (await tester.runAsync(() async {
      final first = CoverThumbnailCache.prepareProvider(file.path, 384,
          canContinue: () => firstAllowed,
          nativeEncodedFit: true,
          trace: trace);
      await barrier.$1.future;
      final second = CoverThumbnailCache.prepareProvider(file.path, 384,
          canContinue: () => secondAllowed, nativeEncodedFit: true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      firstAllowed = false;
      barrier.$2.complete();
      return Future.wait([first, second]);
    }))!;
    expect(results[0], isNull);
    expect(results[1], isNotNull);
    expect(trace.stages.where((stage) => stage['stage'] == 'nativePngDecode'),
        hasLength(1));
    await tester.pumpWidget(MaterialApp(home: Image(image: results[1]!)));
    final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect((image.width, image.height), (384, 299));
    await close(tester);
    secondAllowed = false;
    expect(DerivedImageStore.isPathLeased(file.path), isFalse);
  }, skip: !supported);

  testWidgets('source replacement during native encoding rejects old image',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final trace = _AfterStage((name, _) async {
      if (name == 'nativePngEncode') {
        await file
            .writeAsBytes(img.encodePng(img.Image(width: 900, height: 600)));
      }
    });
    final provider = await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true, nativeEncodedFit: true, trace: trace));
    expect(provider, isNull);
    await close(tester);
    final next = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true, nativeEncodedFit: true)))!;
    await tester.pumpWidget(MaterialApp(home: Image(image: next)));
    final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect((image.width, image.height), (384, 256));
    await close(tester);
  }, skip: !supported);

  testWidgets('encoded PNG candidate does not change JPEG backend',
      (tester) async {
    final file = (await tester.runAsync(() => source(jpeg: true)))!;
    final trace = CoverThumbnailTrace();
    final provider = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true, nativeEncodedFit: true, trace: trace)))!;
    expect(trace.details['backend'], 'flutter');
    expect(trace.details['nativeEncodedFitUsed'], isFalse);
    await tester.pumpWidget(MaterialApp(home: Image(image: provider)));
    await close(tester);
  }, skip: !supported);
}
