import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  setUpAll(() async {
    final parent = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    workspace = await parent.createTemp('cover-fallback-');
    App.dataPath = p.join(workspace.path, 'data');
    App.cachePath = p.join(workspace.path, 'cache');
    CoverThumbnailCache.nativeAvailableForTesting = false;
    CoverThumbnailCache.maintenanceForTesting = (_) async {};
  });
  tearDownAll(() async {
    await CoverThumbnailCache.waitForProviderPersistenceForTesting();
    await CoverThumbnailCache.waitForMaintenanceForTesting();
    CoverThumbnailCache.nativeAvailableForTesting = null;
    CoverThumbnailCache.maintenanceForTesting = null;
    await workspace.delete(recursive: true);
  });

  Future<String> source(int width, int height) async {
    final file = File(p.join(workspace.path, '$width-$height.png'));
    await file
        .writeAsBytes(img.encodePng(img.Image(width: width, height: height)));
    return file.path;
  }

  test('without native, a 48 MiB original still produces a bounded cover',
      () async {
    final path = await source(3000, 4000);
    final stat = await File(path).stat();
    final oldKey = LocalCoverCache.stableHashForFileName(
        '$path|${stat.size}|${stat.modified.microsecondsSinceEpoch}|384|thumb-v2');
    final oldCache = File(p.join(App.dataPath, 'local_library_cache', 'covers',
        'thumbs', '$oldKey.png'));
    await oldCache.parent.create(recursive: true);
    await oldCache.writeAsBytes(img.encodePng(img.Image(width: 1, height: 1)));
    final prepared = await CoverThumbnailCache.prepareDisplay(path, 384,
        canContinue: () => true);
    expect(prepared, isNotNull);
    expect(prepared, isNot(oldCache.path),
        reason: 'an earlier filter result must not become the new warm cover');
    final buffer = await ui.ImmutableBuffer.fromFilePath(prepared!);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      expect((descriptor.width, descriptor.height), (384, 512));
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  });

  test('without native, over 64 MiB is rejected before full-image decoding',
      () async {
    final path = await source(4097, 4097);
    expect(
        await CoverThumbnailCache.prepareDisplay(path, 384,
            canContinue: () => true),
        isNull);
  });
}
