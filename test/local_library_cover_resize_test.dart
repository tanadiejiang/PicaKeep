import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/illust_card_info_config.dart';
import 'package:picakeep/foundation/illust_cover_size.dart';
import 'package:picakeep/foundation/illust_folder_preferences.dart';
import 'package:picakeep/foundation/illust_page_count_cache.dart';
import 'package:picakeep/foundation/image_pipeline/cover_decode_target.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart';
import 'package:picakeep/foundation/pixiv_library.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';
import 'package:picakeep/pages/local_library_illust_card.dart';
import 'package:picakeep/pages/local_library_page.dart';
import 'package:picakeep/pages/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
}

typedef _Layout = ({double contentWidth, double ratio});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final savedSettings = List<String>.of(appdata.settings);
  final savedPaths = PathProviderPlatform.instance;
  final savedQuota = ImageDiskQuota.overrideForTesting;
  final savedMode = managedDataSourceMode;
  late Directory workspace;
  late PixivLibrary library;
  var fixture = 0;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open(
            p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
    final parent = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    workspace = await parent.createTemp('cover_resize_workflow_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: p.join(workspace.path, 'app'));
    await sharedIllustPageCountCache();
    await sharedIllustCoverSizeCache();
    await IllustFolderPreferences.instance.load();
    ImageDiskQuota.overrideForTesting = ImageDiskQuota(
        roots: () => [App.cachePath, LocalCoverCache.rootDirectory().path],
        idleLimitBytes: () => 512 << 20,
        space: (_) async => const ImageDiskSpace(100 << 30, 'test-volume'));
  });
  setUp(() async {
    library = PixivLibrary(p.join(workspace.path, 'library_${fixture++}'));
    await library.initialize();
    appdata.settings[pixivDownloadDirSettingIndex] = library.root;
    appdata.settings[22] = p.join(workspace.path, 'other');
    appdata.settings[localLibraryAlbumOnlySettingIndex] = '1';
    appdata.settings[illustLibraryViewSettingIndex] = 'illust';
    appdata.settings[illustWaterfallColumnsSettingIndex] = '3';
    appdata.settings[illustCardInfoSettingIndex] = '{title}';
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
  });
  tearDownAll(() async {
    await CoverThumbnailCache.waitForProviderPersistenceForTesting();
    await CoverThumbnailCache.waitForMaintenanceForTesting();
    ImageDiskQuota.overrideForTesting = savedQuota;
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    PathProviderPlatform.instance = savedPaths;
    setManagedDataSourceMode(savedMode);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    try {
      await workspace.delete(recursive: true);
    } catch (_) {}
  });

  Future<File?> seed({bool missing = false}) async {
    final folder = await library.createFolder('fixture');
    final directory = await Directory(p.join(folder.path, 'pixiv_fixture'))
        .create(recursive: true);
    File? source;
    if (!missing) {
      final image = img.Image(width: 1200, height: 1800);
      img.fill(image, color: img.ColorRgba8(73, 157, 221, 255));
      img.fillRect(image,
          x1: 400,
          y1: 0,
          x2: 800,
          y2: 1799,
          color: img.ColorRgba8(239, 63, 113, 255));
      source = await File(p.join(directory.path, 'cover.png'))
          .writeAsBytes(img.encodePng(image));
      await File(p.join(directory.path, '1.png'))
          .writeAsBytes(await source.readAsBytes());
    }
    final db = PixivLibrary.openDownloads(folder.path);
    try {
      db.execute('INSERT INTO download VALUES(?,?,?,?,?,?,?)', [
        'pixiv_fixture',
        'fixture',
        'author',
        1,
        p.basename(directory.path),
        1.0,
        jsonEncode({
          'id': 'pixiv_fixture',
          'name': 'fixture',
          'subTitle': 'author',
          'sourceKey': 'pixiv',
          'sourceName': 'Pixiv',
          'comicId': 'fixture',
          'tags': [],
          'cover': source?.path ?? '',
          'downloadedEps': [0],
          'width': 1200,
          'height': 1800,
        })
      ]);
    } finally {
      db.dispose();
    }
    final manager = LocalLibraryManager();
    final items = await manager.getManagedDownloads(forceRefresh: true);
    // Source staging/index IO uses a suite-lived real zone. The page still
    // prepares and paints its actual cold target under its own layout queue.
    for (final item in items) {
      await manager.resolveCoverPathForItem(item);
    }
    return source;
  }

  Finder cardImage() => find.descendant(
      of: find.byType(IllustCard), matching: find.byType(Image));

  ImageProvider underlying(WidgetTester tester) =>
      (tester.widget<Image>(cardImage()).image as CoverDecodeTarget)
          .imageProvider;

  int decodedWidth(WidgetTester tester) {
    final raw = find.descendant(
        of: find.byType(IllustCard), matching: find.byType(RawImage));
    return raw.evaluate().isEmpty
        ? 0
        : tester.renderObject<RenderImage>(raw).image?.width ?? 0;
  }

  Future<void> waitFor(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
      if (condition()) return;
    }
    expect(condition(), isTrue, reason: 'real cover workflow did not complete');
  }

  Future<void> mount(WidgetTester tester, ValueNotifier<_Layout> layout,
      {bool settings = false}) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<_Layout>(
            valueListenable: layout,
            builder: (context, value, _) => MediaQuery(
                data: MediaQueryData(
                    size: const Size(1600, 1200),
                    devicePixelRatio: value.ratio),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                          width: value.contentWidth,
                          child: const LocalLibraryPage(albumOnly: true)),
                      if (settings)
                        Expanded(
                            child: Scaffold(
                                body: SingleChildScrollView(
                                    child: Builder(
                                        builder: (context) =>
                                            buildExploreSettings(
                                                600, context))))),
                    ])))));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
    var complete = false;
    unawaited(() async {
      await CoverThumbnailCache.waitForProviderPersistenceForTesting();
      await CoverThumbnailCache.waitForMaintenanceForTesting();
      complete = true;
    }());
    await waitFor(tester, () => complete);
    expect(PicakeepImageEngine.workerDiagnostics['activeJobs'], 0);
    expect(PicakeepImageEngine.workerDiagnostics['queuedJobs'], 0);
    // The native worker pool intentionally keeps idle workers for ten seconds
    // in the application. A test fixture must close them explicitly so the
    // Flutter binding can verify that no timer survives the route teardown.
    final shutdown = PicakeepImageEngine.shutdownIdleWorkers();
    await waitFor(tester,
        () => PicakeepImageEngine.workerDiagnostics['workersAlive'] == 0);
    await shutdown;
  }

  testWidgets('real page upgrades columns and DPR while keeping old cover',
      (tester) async {
    final source = (await tester.runAsync(() => seed()))!;
    final before = (await tester.runAsync(source.stat))!;
    final layout = ValueNotifier<_Layout>((contentWidth: 800, ratio: 1));
    await mount(tester, layout, settings: true);
    await waitFor(tester,
        () => cardImage().evaluate().isNotEmpty && decodedWidth(tester) == 384);
    final first = underlying(tester);
    final cardWidth = tester.getSize(find.byType(AspectRatio)).width;
    expect(cardWidth, closeTo((800 - 4) / 3 - 6, 0.01));

    App.notifyDisplaySettingsChanged();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(identical(underlying(tester), first), isTrue);

    final columnSetting = find.byWidgetPredicate((widget) =>
        widget is SelectSetting &&
        widget.settingsIndex == illustWaterfallColumnsSettingIndex);
    await tester.ensureVisible(columnSetting);
    await tester.tap(find.descendant(
        of: columnSetting, matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '2'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(appdata.settings[illustWaterfallColumnsSettingIndex], '2');
    await tester.pump();
    await waitFor(tester, () => decodedWidth(tester) == 768);
    final second = underlying(tester);
    expect(second, isNot(first));

    layout.value = (contentWidth: 800, ratio: 2.75);
    await tester.pump();
    expect(identical(underlying(tester), second), isTrue);
    await waitFor(tester, () => decodedWidth(tester) == 1200);
    final originalSized = underlying(tester);
    expect(originalSized, isNot(second));
    layout.value = (contentWidth: 800, ratio: 1);
    appdata.settings[illustWaterfallColumnsSettingIndex] = '3';
    App.notifyDisplaySettingsChanged();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(identical(underlying(tester), originalSized), isTrue,
        reason: 'a smaller card reuses its larger prepared source');
    await unmount(tester);
    layout.dispose();
    final after = (await tester.runAsync(source.stat))!;
    expect((after.size, after.modified), (before.size, before.modified));
    expect(ImageDiskQuota.shared.activeBytes, 0);
  });

  testWidgets('content width change upgrades without using full window width',
      (tester) async {
    await tester.runAsync(() => seed());
    final layout = ValueNotifier<_Layout>((contentWidth: 800, ratio: 1));
    await mount(tester, layout);
    await waitFor(tester,
        () => cardImage().evaluate().isNotEmpty && decodedWidth(tester) == 384);
    final first = underlying(tester);
    layout.value = (contentWidth: 1200, ratio: 1);
    await tester.pump();
    expect(identical(underlying(tester), first), isTrue);
    await waitFor(tester, () => decodedWidth(tester) == 768);
    final larger = underlying(tester);
    layout.value = (contentWidth: 1100, ratio: 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(identical(underlying(tester), larger), isTrue,
        reason: 'another width in the same bucket does not reprepare');
    await unmount(tester);
    layout.dispose();
  });

  testWidgets(
      'missing cover reaches bounded failure and route dispose is quiet',
      (tester) async {
    await tester.runAsync(() => seed(missing: true));
    final layout = ValueNotifier<_Layout>((contentWidth: 800, ratio: 1));
    await mount(tester, layout);
    await waitFor(tester, () => find.byType(IllustCard).evaluate().isNotEmpty);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 5));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
    expect(cardImage(), findsNothing);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
    layout.dispose();
    expect(ImageDiskQuota.shared.activeBytes, 0);
  });
}
