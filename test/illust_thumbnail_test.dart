import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  final savedDiskQuota = ImageDiskQuota.overrideForTesting;
  ImageDiskQuota testQuota({int available = 100 << 30}) => ImageDiskQuota(
      roots: () => [App.cachePath, p.join(App.dataPath, 'local_library_cache')],
      idleLimitBytes: () => 512 << 20,
      space: (_) async => ImageDiskSpace(available, 'cover-test-volume'));
  setUpAll(() async {
    final parent = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    workspace = await parent.createTemp('pk51_thumbs_');
    App.dataPath = p.join(workspace.path, 'app');
    App.cachePath = p.join(workspace.path, 'cache');
    ImageDiskQuota.overrideForTesting = testQuota();
  });
  tearDownAll(() async {
    ImageDiskQuota.overrideForTesting = savedDiskQuota;
    await workspace.delete(recursive: true);
  });
  tearDown(() async {
    CoverThumbnailCache.beforeProviderPersistenceForTesting = null;
    await CoverThumbnailCache.waitForProviderPersistenceForTesting();
    await CoverThumbnailCache.waitForMaintenanceForTesting();
    CoverThumbnailCache.maintenanceForTesting = null;
  });

  Future<String> source(int width, int height,
      {String name = 'source.png'}) async {
    final file = File(p.join(workspace.path, name));
    await file
        .writeAsBytes(img.encodePng(img.Image(width: width, height: height)));
    return file.path;
  }

  Future<(int, int)> dimensions(String path) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = (descriptor.width, descriptor.height);
    descriptor.dispose();
    buffer.dispose();
    return size;
  }

  testWidgets('visible cover backlog defers encoding while pixels can paint',
      (tester) async {
    final firstRelease =
        CoverThumbnailCache.deferProviderPersistenceForVisibleWork();
    final lastRelease =
        CoverThumbnailCache.deferProviderPersistenceForVisibleWork();
    var encoders = 0;
    CoverThumbnailCache.beforeProviderPersistenceForTesting = () async {
      encoders++;
    };
    try {
      final path = await tester
          .runAsync(() => source(512, 256, name: 'idle-persistence.png'));
      final provider = await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(path!, 384,
              canContinue: () => true));
      await tester.pumpWidget(MaterialApp(home: Image(image: provider!)));
      await tester.pump();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(encoders, 0, reason: 'visible cover preparation owns the lane');
      firstRelease();
      firstRelease();
      await tester.pump();
      expect(encoders, 0, reason: 'another page still has visible work');
      lastRelease();
      var drained = false;
      unawaited(CoverThumbnailCache.waitForProviderPersistenceForTesting()
          .then((_) => drained = true));
      for (var i = 0; i < 300 && !drained; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(drained, isTrue);
      expect(encoders, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      firstRelease();
      lastRelease();
    }
  });

  testWidgets('cold cover paints before PNG persistence is allowed',
      (tester) async {
    Future<List<String>> persistedPaths() async {
      final root = Directory(
          p.join(App.dataPath, 'local_library_cache', 'covers', 'thumbs'));
      if (!await root.exists()) return [];
      return (await root.list().where((f) => f is File).toList())
          .map((f) => f.path)
          .toList()
        ..sort();
    }

    final existingPaths = await tester.runAsync(persistedPaths);
    // Completers awaited from runAsync must use its real async zone. Creating
    // them in the widget's fake zone strands completion microtasks until pump.
    final barriers = (await tester
        .runAsync(() async => (Completer<void>(), Completer<void>())))!;
    final persistenceEntered = barriers.$1;
    final releasePersistence = barriers.$2;
    CoverThumbnailCache.beforeProviderPersistenceForTesting = () async {
      persistenceEntered.complete();
      await releasePersistence.future;
    };
    try {
      final path = await tester
          .runAsync(() => source(4096, 1024, name: 'paint-first.png'));
      final provider = await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(path!, 384,
              canContinue: () => true));
      expect(provider, isNotNull);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      expect(persistenceEntered.isCompleted, isFalse,
          reason: 'preparing a provider must not start PNG encoding');
      await tester.pumpWidget(MaterialApp(
          home: SizedBox(
              width: 128,
              height: 128,
              child: Image(image: provider!, fit: BoxFit.contain))));
      await tester.pump();
      final image = tester.widget<RawImage>(find.byType(RawImage)).image;
      expect(image, isNotNull);
      expect((image!.width, image.height), (384, 96));
      await tester.runAsync(
          () => persistenceEntered.future.timeout(const Duration(seconds: 5)));
      final files = await tester.runAsync(persistedPaths);
      // This test's new key has not been persisted while the real image is painted.
      expect(files, existingPaths);
      expect(releasePersistence.isCompleted, isFalse);
    } finally {
      releasePersistence.complete();
      await tester
          .runAsync(CoverThumbnailCache.waitForProviderPersistenceForTesting);
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      final warm = await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(
              p.join(workspace.path, 'paint-first.png'), 384,
              canContinue: () => true));
      await tester.runAsync(() async {
        final stream = warm!.resolve(ImageConfiguration.empty);
        final ready = Completer<void>();
        final listener = ImageStreamListener((_, __) {
          if (!ready.isCompleted) ready.complete();
        }, onError: (error, stack) {
          ready.completeError(error, stack);
        });
        stream.addListener(listener);
        try {
          await ready.future.timeout(const Duration(seconds: 5));
        } finally {
          stream.removeListener(listener);
        }
      });
      await tester.pumpWidget(MaterialApp(home: Image(image: warm!)));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
      final warmImage = tester.widget<RawImage>(find.byType(RawImage)).image;
      expect(warmImage, isNotNull);
      expect((warmImage!.width, warmImage.height), (384, 96));
      expect(tester.takeException(), isNull,
          reason: 'decoder callback owns its buffer; no double dispose');
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    }
  });

  testWidgets('disk refusal preserves the prepared cover and publishes no PNG',
      (tester) async {
    final saved = ImageDiskQuota.overrideForTesting;
    final denied =
        (await tester.runAsync(() async => testQuota(available: 0)))!;
    ImageDiskQuota.overrideForTesting = denied;
    try {
      final path = (await tester
          .runAsync(() => source(1024, 512, name: 'disk-refused.png')))!;
      final provider = await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(path, 384,
              canContinue: () => true));
      expect(provider, isNotNull);
      await tester.pumpWidget(MaterialApp(home: Image(image: provider!)));
      await tester.pump();
      await tester
          .runAsync(CoverThumbnailCache.waitForProviderPersistenceForTesting);
      final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
      expect((image.width, image.height), (384, 192));
      expect(denied.pendingCount, 0);
      expect(denied.activeBytes, 0);
      final display = await tester.runAsync(() =>
          CoverThumbnailCache.prepareDisplay(path, 768,
              canContinue: () => true));
      final legacy = await tester
          .runAsync(() => CoverThumbnailCache.ensureForCoverPath(path));
      expect(display, isNull);
      expect(legacy, isNull);
      final original = (await tester.runAsync(() => File(path).stat()))!;
      expect(original.type, FileSystemEntityType.file);
      expect(original.size, greaterThan(0));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester
          .runAsync(CoverThumbnailCache.waitForProviderPersistenceForTesting);
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      ImageDiskQuota.overrideForTesting = saved;
    }
  });

  test('an unpainted cover abandons its persistence clone', () async {
    final path = await source(100, 160, name: 'never-painted.png');
    var encodes = 0;
    CoverThumbnailCache.beforeProviderPersistenceForTesting = () async {
      encodes++;
    };
    final trace = CoverThumbnailTrace();
    final provider = await CoverThumbnailCache.prepareProvider(path, 384,
        canContinue: () => true, trace: trace);
    expect(provider, isNotNull);
    await CoverThumbnailCache.waitForProviderPersistenceForTesting()
        .timeout(const Duration(seconds: 5));
    expect(encodes, 0);
    // Consume and cancel the separate provider-expiry timer. The expired
    // optional persistence is not revived by a later image stream resolution.
    final stream = provider!.resolve(ImageConfiguration.empty);
    final ready = Completer<void>();
    final listener = ImageStreamListener((_, __) => ready.complete());
    stream.addListener(listener);
    await ready.future;
    stream.removeListener(listener);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    expect(trace.stages.where((stage) => stage['stage'] == 'persistEncode'),
        isEmpty);
  });

  for (final replaceSource in [false, true]) {
    testWidgets(
        replaceSource
            ? 'source replacement before persistence never publishes old pixels'
            : 'cache invalidation before persistence never publishes old pixels',
        (tester) async {
      final barriers = (await tester
          .runAsync(() async => (Completer<void>(), Completer<void>())))!;
      final entered = barriers.$1;
      final release = barriers.$2;
      CoverThumbnailCache.beforeProviderPersistenceForTesting = () async {
        entered.complete();
        await release.future;
      };
      final trace = CoverThumbnailTrace();
      final path = (await tester.runAsync(
          () => source(110, 170, name: 'not-published-$replaceSource.png')))!;
      final provider = await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(path, 384,
              canContinue: () => true, trace: trace));
      try {
        await tester.pumpWidget(MaterialApp(home: Image(image: provider!)));
        final image = tester.widget<RawImage>(find.byType(RawImage)).image;
        expect((image!.width, image.height), (110, 170));
        await tester
            .runAsync(() => entered.future.timeout(const Duration(seconds: 5)));
        if (replaceSource) {
          await tester.runAsync(() => File(path)
              .writeAsBytes(img.encodePng(img.Image(width: 130, height: 180))));
        } else {
          CoverThumbnailCache.invalidatePendingPublications();
        }
      } finally {
        release.complete();
        await tester
            .runAsync(CoverThumbnailCache.waitForProviderPersistenceForTesting);
        await tester.pumpWidget(const SizedBox.shrink());
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      }
      final nextTrace = CoverThumbnailTrace();
      final next = await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(path, 384,
              canContinue: () => true, trace: nextTrace));
      expect(nextTrace.details['diskHit'], isFalse);
      await tester.pumpWidget(MaterialApp(home: Image(image: next!)));
      final nextImage = tester.widget<RawImage>(find.byType(RawImage)).image;
      expect((nextImage!.width, nextImage.height),
          replaceSource ? (130, 180) : (110, 170));
      // This request must not reuse the completed barrier callback.
      CoverThumbnailCache.beforeProviderPersistenceForTesting = null;
      await tester
          .runAsync(CoverThumbnailCache.waitForProviderPersistenceForTesting);
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      expect(tester.takeException(), isNull);
    });
  }

  test('real thumbnail uses width buckets and app-internal path; warm reuse',
      () async {
    final path = await source(1000, 1500);
    final result = await CoverThumbnailCache.prepareDisplay(path, 300,
        canContinue: () => true);
    expect(result, isNotNull);
    expect(
        p.isWithin(
            p.join(App.dataPath, 'local_library_cache', 'covers', 'thumbs'),
            result!),
        isTrue);
    expect(await dimensions(result), (384, 576));
    final modified = await File(result).lastModified();
    expect(
        await CoverThumbnailCache.prepareDisplay(path, 380,
            canContinue: () => true),
        result);
    expect(await File(result).lastModified(), modified);
    final larger = await CoverThumbnailCache.prepareDisplay(path, 500,
        canContinue: () => true);
    expect(await dimensions(larger!), (768, 1152));
    expect(await dimensions(path), (1000, 1500));
  });
  test('small images are not enlarged; long image stays complete within bounds',
      () async {
    final small = await source(20, 30);
    final prepared = await CoverThumbnailCache.prepareDisplay(small, 768,
        canContinue: () => true);
    expect(await dimensions(prepared!), (20, 30));
    final long = await source(80, 12000, name: 'long.png');
    final output = await CoverThumbnailCache.prepareDisplay(long, 384,
        canContinue: () => true);
    final size = await dimensions(output!);
    expect(size.$2, lessThanOrEqualTo(4096));
    expect(size.$1 / size.$2, closeTo(80 / 12000, 0.001));
    expect(size.$1 * size.$2, lessThanOrEqualTo(4 * 1024 * 1024));
  });
  test('same-key requests share output, deletion and replacement regenerate',
      () async {
    final path = await source(800, 1000);
    final results = await Future.wait(List.generate(
        4,
        (_) => CoverThumbnailCache.prepareDisplay(path, 300,
            canContinue: () => true)));
    expect(results.toSet().length, 1);
    await File(results.first!).delete();
    final regenerated = await CoverThumbnailCache.prepareDisplay(path, 300,
        canContinue: () => true);
    expect(await File(regenerated!).exists(), isTrue);
    await File(path)
        .writeAsBytes(img.encodePng(img.Image(width: 600, height: 800)));
    final changed = await CoverThumbnailCache.prepareDisplay(path, 300,
        canContinue: () => true);
    expect(changed, isNot(regenerated));
    expect(await dimensions(changed!), (384, 512));
    expect(
        await Directory(App.dataPath)
            .list(recursive: true)
            .where((f) => f.path.endsWith('.part'))
            .isEmpty,
        isTrue);
  });
  test('paused or failed generation exposes no half-file; retry succeeds',
      () async {
    final path = await source(1000, 1500, name: 'paused.png');
    var checks = 0;
    expect(
        await CoverThumbnailCache.prepareDisplay(path, 384,
            canContinue: () => ++checks < 4),
        isNull);
    expect(
        await CoverThumbnailCache.prepareDisplay(path, 384,
            canContinue: () => false),
        isNull);
    final output = await CoverThumbnailCache.prepareDisplay(path, 384,
        canContinue: () => true);
    expect(output, isNotNull);
    final broken = File(p.join(workspace.path, 'broken.png'));
    await broken.writeAsString('invalid');
    expect(
        await CoverThumbnailCache.prepareDisplay(broken.path, 384,
            canContinue: () => true),
        isNull);
    expect(
        await Directory(App.dataPath)
            .list(recursive: true)
            .where((f) => f.path.endsWith('.part'))
            .isEmpty,
        isTrue);
  });

  test('a cancelled requester does not cancel a visible shared requester',
      () async {
    final path = await source(1600, 1800, name: 'shared-cancellation.png');
    var firstActive = true;
    final first = CoverThumbnailCache.prepareDisplay(path, 384,
        canContinue: () => firstActive);
    var secondChecks = 0;
    final second =
        CoverThumbnailCache.prepareDisplay(path, 384, canContinue: () {
      // The second request has finished checking the warm cache and is ready
      // to share work when the first card leaves the viewport.
      if (++secondChecks >= 2) firstActive = false;
      return true;
    });
    expect(await first, isNull);
    final result = await second;
    expect(result, isNotNull);
    expect(await dimensions(result!), (384, 432));
  });

  test('slow quota maintenance does not delay this or the next thumbnail',
      () async {
    final quotaEntered = Completer<void>();
    final releaseQuota = Completer<void>();
    var quotaCalls = 0;
    CoverThumbnailCache.maintenanceForTesting = (_) async {
      quotaCalls++;
      quotaEntered.complete();
      await releaseQuota.future;
    };
    try {
      final firstPath = await source(800, 1000, name: 'slow-quota-a.png');
      final first = await CoverThumbnailCache.prepareDisplay(firstPath, 384,
          canContinue: () => true).timeout(const Duration(seconds: 5));
      expect(first, isNotNull);
      await quotaEntered.future.timeout(const Duration(seconds: 5));
      final secondPath = await source(800, 1000, name: 'slow-quota-b.png');
      final second = await CoverThumbnailCache.prepareDisplay(secondPath, 384,
          canContinue: () => true).timeout(const Duration(seconds: 5));
      expect(second, isNotNull);
      expect(await File(first!).exists(), isTrue);
      expect(await File(second!).exists(), isTrue);
      expect(quotaCalls, 1);
    } finally {
      releaseQuota.complete();
      await CoverThumbnailCache.waitForMaintenanceForTesting();
    }
  });

  test('quota leases retain all in-use thumbnails and release independently',
      () async {
    final originalLimit = appdata.appSettings.cacheLimit;
    final root = Directory(
        p.join(App.dataPath, 'local_library_cache', 'covers', 'thumbs'));
    await root.create(recursive: true);
    final first = File(p.join(root.path, 'leased-a.png'));
    final second = File(p.join(root.path, 'leased-b.png'));
    await first.writeAsBytes(List.filled(2 * 1024 * 1024, 0));
    await second.writeAsBytes(List.filled(2 * 1024 * 1024, 0));
    final releaseFirst = RemoteLibraryDataSource.protectCacheFile(first.path);
    final releaseFirstAgain =
        RemoteLibraryDataSource.protectCacheFile(first.path);
    final releaseSecond = RemoteLibraryDataSource.protectCacheFile(second.path);
    try {
      appdata.appSettings.cacheLimit = 1;
      await RemoteLibraryDataSource.trimCacheToLimit();
      expect(await first.exists(), isTrue);
      expect(await second.exists(), isTrue);
      releaseFirst();
      releaseFirst(); // Idempotent: another consumer still owns the first file.
      releaseSecond();
      await RemoteLibraryDataSource.trimCacheToLimit();
      expect(await first.exists(), isTrue);
      expect(await second.exists(), isFalse);
      releaseFirstAgain();
      await RemoteLibraryDataSource.trimCacheToLimit();
      expect(await first.exists(), isFalse);
    } finally {
      releaseFirst();
      releaseFirstAgain();
      releaseSecond();
      appdata.appSettings.cacheLimit = originalLimit;
    }
  });
}
