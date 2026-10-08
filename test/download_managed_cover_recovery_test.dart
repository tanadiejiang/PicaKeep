import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/local_trash_store.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart';
import 'package:picakeep/pages/download_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/image_disk_quota_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final savedPaths = PathProviderPlatform.instance;
  final savedSettings = List<String>.of(appdata.settings);
  final savedQuota = ImageDiskQuota.overrideForTesting;
  final savedMode = managedDataSourceMode;
  late Directory workspace;
  late File originalCover;
  late List<int> originalBytes;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open(
            p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
    workspace = await Directory.systemTemp.createTemp('managed_cover_repair_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: p.join(workspace.path, 'app'));
    installTaskDiskQuota(() => [App.dataPath, App.cachePath]);
    setManagedDataRootOverride(workspace.path);
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
    appdata.settings[managedDataSourceModeSettingIndex] =
        managedDataSourceModeCurrentOnly;
    appdata.settings[downloadedLibraryViewSettingIndex] = 'local';
    appdata.settings[22] = p.join(workspace.path, 'downloads');
    appdata.settings[72] = '0';
    appdata.settings[73] = '0';
    appdata.settings[pixivDownloadDirSettingIndex] = '';

    final directory = await Directory(p.join(appdata.settings[22], 'Fixture'))
        .create(recursive: true);
    final cover = img.Image(width: 64, height: 96);
    img.fill(cover, color: img.ColorRgba8(31, 157, 83, 255));
    originalBytes = img.encodePng(cover);
    originalCover = await File(p.join(directory.path, 'cover.png'))
        .writeAsBytes(originalBytes);
    await File(p.join(directory.path, '1.png')).writeAsBytes(originalBytes);
    final db = sqlite3.open(p.join(appdata.settings[22], 'download.db'));
    try {
      db.execute('CREATE TABLE download(id TEXT PRIMARY KEY,title TEXT,'
          'subtitle TEXT,time INT,directory TEXT,size REAL,json TEXT)');
      db.execute('INSERT INTO download VALUES(?,?,?,?,?,?,?)', [
        'jm123',
        'Recoverable fixture',
        'Author',
        1710000000000,
        'Fixture',
        1.0,
        jsonEncode({
          'comicId': '123',
          'name': 'Recoverable fixture',
          'author': 'Author',
          'downloadedChapters': [0],
          'epNames': ['First'],
        }),
      ]);
    } finally {
      db.dispose();
    }
  });

  tearDownAll(() async {
    downloadManager.dispose();
    // The real managed loader opens this singleton while reading its hidden
    // index. Close its app/local_trash.db handle before deleting the fixture.
    LocalTrashStore.instance.dispose();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    BaseImageProvider.clearCache();
    ImageDiskQuota.overrideForTesting = savedQuota;
    PathProviderPlatform.instance = savedPaths;
    setManagedDataRootOverride(null);
    setManagedDataSourceMode(savedMode);
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    await workspace.delete(recursive: true);
  });

  Finder tiles() => find.byWidgetPredicate((w) => w is DownloadedComicTile);

  Finder coverPixels() =>
      find.descendant(of: tiles(), matching: find.byType(RawImage));

  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
      if (done()) return;
    }
    expect(done(), isTrue, reason: 'real downloaded cover did not recover');
  }

  testWidgets(
      'download page repairs deleted persisted managed cover from source',
      (tester) async {
    final manager = LocalLibraryManager();
    final derivedPath = (await tester.runAsync(() async {
      final items = await manager.getManagedDownloads(forceRefresh: true);
      expect(items, hasLength(1));
      expect(items.single.isManagedDownloadItem, isTrue);
      final path = await manager.resolveCoverPathForItem(items.single);
      expect(path, isNotNull);
      expect(p.isWithin(LocalCoverCache.rootDirectory().path, path!), isTrue);
      expect(await File(path).readAsBytes(), originalBytes);
      await File(path).delete();

      // The real metadata loader still supplies the persisted missing path.
      // The page must repair it while resolving its actual tile provider.
      final reloaded = await manager.getManagedDownloads(forceRefresh: true);
      expect(reloaded.single.localCoverPath, path);
      expect(await File(path).exists(), isFalse);
      return path;
    }))!;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    BaseImageProvider.clearCache();

    await tester.runAsync(() async {
      await tester
          .pumpWidget(const MaterialApp(home: DownloadPage(forceLocal: true)));
      for (var i = 0;
          i < 300 && StateController.find<DownloadPageLogic>().loading;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await waitFor(
        tester,
        () =>
            coverPixels().evaluate().length == 1 &&
            tester.renderObject<RenderImage>(coverPixels()).image != null);

    final logic = StateController.find<DownloadPageLogic>();
    expect(logic.loading, isFalse);
    expect(logic.baseComics, hasLength(1));
    final item = logic.baseComics.single;
    final provider = logic.coverImageProviderFor(item);
    final tileProvider =
        tester.widget<DownloadedComicTile>(tiles()).imageProvider;
    expect(provider, isA<StreamImageProvider>());
    expect(provider, same(tileProvider));
    expect((provider! as StreamImageProvider).imageKey,
        startsWith('local_cover::'));
    expect(logic.coverImageProviderFor(item), same(provider));
    logic.update();
    await tester.pump();
    expect(logic.coverImageProviderFor(item), same(provider));
    await tester.runAsync(() async {
      expect(await File(derivedPath).readAsBytes(), originalBytes);
      expect(await originalCover.readAsBytes(), originalBytes);
    });
    final pixels = tester.renderObject<RenderImage>(coverPixels()).image!;
    final bytes = (await tester.runAsync(
        () => pixels.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    expect(bytes.buffer.asUint8List().take(4), [31, 157, 83, 255]);
    expect(find.byIcon(Icons.image_not_supported), findsNothing);
    expect(tester.takeException(), isNull);

    // The downloaded page's toolbar search filters these same managed tiles.
    // Verify actual pixels/provider identity, including the zero-result state,
    // rather than treating a matching title as proof of a working cover.
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Recoverable');
    await tester.pump(const Duration(milliseconds: 300));
    await waitFor(
        tester,
        () =>
            coverPixels().evaluate().length == 1 &&
            tester.renderObject<RenderImage>(coverPixels()).image != null);
    expect(tester.widget<DownloadedComicTile>(tiles()).imageProvider,
        same(provider));
    expect(logic.comics.single.id, item.id);
    await tester.enterText(find.byType(TextField), 'no matching download');
    await tester.pump(const Duration(milliseconds: 300));
    expect(tiles(), findsNothing);
    expect(logic.baseComics.single.id, item.id);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 300));
    await waitFor(
        tester,
        () =>
            coverPixels().evaluate().length == 1 &&
            tester.renderObject<RenderImage>(coverPixels()).image != null);
    expect(tester.widget<DownloadedComicTile>(tiles()).imageProvider,
        same(provider));
    final restoredPixels =
        tester.renderObject<RenderImage>(coverPixels()).image!;
    final restoredBytes = (await tester.runAsync(
        () => restoredPixels.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    expect(restoredBytes.buffer.asUint8List().take(4), [31, 157, 83, 255]);
    expect(find.byIcon(Icons.image_not_supported), findsNothing);

    // Clearing caches while this page survives must also recover on reload.
    // A new managed source generation replaces its old resolver closure/key.
    await tester.runAsync(() => File(derivedPath).delete());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    BaseImageProvider.clearCache();
    await tester.runAsync(logic.reload);
    await tester.pump();
    expect(
        logic.coverImageProviderFor(logic.baseComics.single), isNot(provider));
    await waitFor(
        tester,
        () =>
            coverPixels().evaluate().length == 1 &&
            tester.renderObject<RenderImage>(coverPixels()).image != null &&
            !identical(
                tester.renderObject<RenderImage>(coverPixels()).image, pixels));
    await tester.runAsync(() async {
      expect(await File(derivedPath).readAsBytes(), originalBytes);
      expect(await originalCover.readAsBytes(), originalBytes);
    });
    expect(find.byIcon(Icons.image_not_supported), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    // Widget-triggered publications leave the quota tail in the fake zone.
    // Complete it while the tester can still pump that zone, rather than
    // awaiting it from tearDownAll, where fake microtasks cannot advance.
    var drained = false;
    unawaited(ImageDiskQuota.shared.drain().then((_) {
      drained = true;
    }));
    await waitFor(tester, () => drained);
    expect(ImageDiskQuota.shared.pendingOperations, 0);
  });
}
