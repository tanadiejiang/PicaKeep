import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('pk51_thumbs_');
    App.dataPath = p.join(workspace.path, 'app');
    App.cachePath = p.join(workspace.path, 'cache');
  });
  tearDownAll(() async => workspace.delete(recursive: true));
  tearDown(() async {
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
