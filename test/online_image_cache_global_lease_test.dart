import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/base.dart' show appdata;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/network/online_image/online_image_cache.dart';
import 'package:picakeep/tools/io_tools.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  setUpAll(() async {
    final parent = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    workspace = await parent.createTemp('original-leases-');
    App.dataPath = p.join(workspace.path, 'data');
    App.cachePath = p.join(workspace.path, 'cache');
  });
  tearDownAll(() => workspace.delete(recursive: true));

  test('global trim and cache clear retain every active original and metadata',
      () async {
    final originalLimit = appdata.appSettings.cacheLimit;
    final directory = Directory(p.join(App.cachePath, 'online_images'));
    await directory.create(recursive: true);
    final original = File(p.join(directory.path, 'selected.png'));
    final metadata = File(p.join(directory.path, 'selected.json'));
    await original.writeAsBytes(List.filled(2 << 20, 7));
    await metadata.writeAsString('{"length":2097152}');
    final first = OnlineImageCache.instance.lease(original);
    final second = OnlineImageCache.instance.lease(original);
    try {
      appdata.appSettings.cacheLimit = 1;
      await RemoteLibraryDataSource.trimCacheToLimit();
      expect(await original.exists(), isTrue);
      expect(await metadata.exists(), isTrue);
      await eraseCache();
      expect(await original.exists(), isTrue);
      expect(await metadata.exists(), isTrue);
      first();
      first();
      await RemoteLibraryDataSource.trimCacheToLimit();
      expect(await original.exists(), isTrue);
      expect(await metadata.exists(), isTrue);
      second();
      expect(DerivedImageStore.isPathLeased(original.path), isFalse);
      expect(DerivedImageStore.isPathLeased(metadata.path), isFalse);
      await eraseCache();
      expect(await original.exists(), isFalse);
      expect(await metadata.exists(), isFalse);
    } finally {
      first();
      second();
      appdata.appSettings.cacheLimit = originalLimit;
    }
  });
}
