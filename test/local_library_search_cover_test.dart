import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';
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
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/illust_card_info_config.dart';
import 'package:picakeep/foundation/illust_folder_preferences.dart';
import 'package:picakeep/foundation/illust_page_count_cache.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/local_trash_store.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart';
import 'package:picakeep/foundation/pixiv_library.dart';
import 'package:picakeep/pages/local_library_illust_card.dart';
import 'package:picakeep/pages/local_library_illust_view.dart';
import 'package:picakeep/pages/local_library_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/image_disk_quota_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// Hold real source readability probes, leaving page/layout/filtering real.
/// The observer does not replace the manager, queue or image decoder.
final class _ProbeGate extends IOOverrides {
  _ProbeGate(this.sources);
  final Set<String> sources;
  final release = Completer<void>();
  final reads = <String>[];
  int closed = 0;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return sources.contains(p.normalize(path))
        ? _ObservedFile(file, this)
        : file;
  }
}

class _ObservedFile implements File {
  _ObservedFile(this.file, this.gate);
  final File file;
  final _ProbeGate gate;
  @override
  String get path => file.path;
  @override
  Uri get uri => file.uri;
  @override
  File get absolute => file.absolute;
  @override
  Directory get parent => file.parent;
  @override
  Future<bool> exists() => file.exists();
  @override
  bool existsSync() => file.existsSync();
  @override
  Future<FileStat> stat() => file.stat();
  @override
  FileStat statSync() => file.statSync();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      _ObservedHandle(await file.open(mode: mode), gate);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected source call: ${invocation.memberName}');
}

class _ObservedHandle implements RandomAccessFile {
  _ObservedHandle(this.file, this.gate);
  final RandomAccessFile file;
  final _ProbeGate gate;
  @override
  String get path => file.path;
  @override
  Future<Uint8List> read(int bytes) async {
    if (bytes == 32) {
      gate.reads.add(path);
      await gate.release.future;
    }
    return file.read(bytes);
  }

  @override
  Future<RandomAccessFile> close() async {
    await file.close();
    gate.closed++;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected handle call: ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final savedSettings = List<String>.of(appdata.settings);
  final savedPaths = PathProviderPlatform.instance;
  final savedMode = managedDataSourceMode;
  final savedQuota = ImageDiskQuota.overrideForTesting;
  late Directory workspace;
  late Directory root;
  var serial = 0;
  final colors = <List<int>>[
    [191, 43, 62, 255],
    [24, 139, 83, 255],
    [38, 71, 203, 255],
  ];

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open(
            p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
    workspace = await Directory.systemTemp.createTemp('inline-cover-030-');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: p.join(workspace.path, 'app'));
    setManagedDataRootOverride(workspace.path);
    await sharedIllustPageCountCache();
    await IllustFolderPreferences.instance.load();
    installTaskDiskQuota(() => [App.dataPath, App.cachePath]);
  });

  setUp(() async {
    root = await Directory(p.join(workspace.path, 'root_${serial++}')).create();
    appdata.settings[22] = root.path;
    appdata.settings[pixivDownloadDirSettingIndex] = root.path;
    appdata.settings[localLibraryShowAllDatabaseRecordsSettingIndex] = '0';
    appdata.settings[localLibraryAlbumOnlySettingIndex] = '1';
    appdata.settings[illustLibraryViewSettingIndex] = 'illust';
    appdata.settings[illustCardInfoSettingIndex] = '{title}';
    appdata.settings[appRuntimeModeSettingIndex] = appRuntimeModeServer;
    appdata.settings[androidRootModeSettingIndex] = '0';
    appdata.settings[androidShizukuModeSettingIndex] = '0';
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
    CoverThumbnailCache.nativeAvailableForTesting = false;
    CoverThumbnailCache.maintenanceForTesting = (_) async {};
  });

  tearDown(() async {
    IOOverrides.global = null;
    CoverThumbnailCache.nativeAvailableForTesting = null;
    CoverThumbnailCache.maintenanceForTesting = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDownAll(() async {
    downloadManager.dispose();
    LocalTrashStore.instance.dispose();
    ImageDiskQuota.overrideForTesting = savedQuota;
    PathProviderPlatform.instance = savedPaths;
    setManagedDataRootOverride(null);
    setManagedDataSourceMode(savedMode);
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    await workspace.delete(recursive: true);
  });

  Future<List<String>> writeWorks({bool inFolders = false}) async {
    final covers = <String>[];
    final folderPaths = <String>[root.path, root.path, root.path];
    if (inFolders) {
      final library = PixivLibrary(root.path);
      await library.initialize();
      folderPaths[1] = (await library.createFolder('Alpha')).path;
      folderPaths[2] = (await library.createFolder('Beta')).path;
    }
    final databases = <String, Database>{};
    try {
      for (var i = 0; i < colors.length; i++) {
        final folderPath = folderPaths[i];
        final db = databases.putIfAbsent(
            folderPath, () => sqlite3.open(p.join(folderPath, 'download.db')));
        db.execute('CREATE TABLE IF NOT EXISTS download(id TEXT PRIMARY KEY,'
            'title TEXT,subtitle TEXT,time INT,directory TEXT,size REAL,json TEXT)');
        final directory =
            await Directory(p.join(folderPath, 'work_$i')).create();
        final image = img.Image(width: 96, height: 48);
        final c = colors[i];
        img.fill(image, color: img.ColorRgba8(c[0], c[1], c[2], c[3]));
        final bytes = img.encodePng(image);
        final cover = p.join(directory.path, 'cover.png');
        await File(cover).writeAsBytes(bytes);
        await File(p.join(directory.path, '1.png')).writeAsBytes(bytes);
        covers.add(cover);
        db.execute('INSERT INTO download VALUES(?,?,?,?,?,?,?)', [
          'pixiv${10000 + i}',
          'Work $i',
          'Artist $i',
          1710000000000 + i,
          'work_$i',
          1.0,
          jsonEncode({
            'id': 'pixiv${10000 + i}',
            'comicId': '${10000 + i}',
            'name': 'Work $i',
            'subTitle': 'Artist $i',
            'sourceKey': 'pixiv',
            'sourceName': 'Pixiv',
            'downloadedEps': [0],
            'tags': ['tag_$i'],
            'cover': cover,
            'width': 96,
            'height': 48,
          }),
        ]);
      }
    } finally {
      for (final db in databases.values) {
        db.dispose();
      }
    }
    await LocalLibraryManager().getManagedDownloads(forceRefresh: true);
    return covers;
  }

  Future<void> waitFor(WidgetTester tester, bool Function() done,
      {required String reason}) async {
    for (var i = 0; i < 350 && !done(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue, reason: reason);
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester
        .pumpWidget(const MaterialApp(home: LocalLibraryPage(albumOnly: true)));
    await waitFor(tester, () => find.byType(IllustCard).evaluate().length == 3,
        reason: 'real managed Pixiv works populate the illustration page');
    await tester.tap(find.byTooltip('搜索'));
    await tester.pump(const Duration(milliseconds: 250));
  }

  Finder card(String title) => find.byWidgetPredicate(
      (widget) => widget is IllustCard && widget.entry.item.name == title);
  Finder pixels(String title) =>
      find.descendant(of: card(title), matching: find.byType(RawImage));
  bool hasPixels(WidgetTester tester, String title) =>
      pixels(title).evaluate().isNotEmpty &&
      tester.renderObject<RenderImage>(pixels(title)).image != null;

  Future<void> checkColor(WidgetTester tester, int index) async {
    final image =
        tester.renderObject<RenderImage>(pixels('Work $index')).image!;
    final bytes = (await tester
        .runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    expect(bytes.buffer.asUint8List().take(4), colors[index]);
  }

  Future<void> unmountAndDrain(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    var done = false;
    unawaited(() async {
      await CoverThumbnailCache.waitForProviderPersistenceForTesting();
      await CoverThumbnailCache.waitForMaintenanceForTesting();
      await ImageDiskQuota.shared.drain();
      done = true;
    }());
    await waitFor(tester, () => done, reason: 'all fixture work drains');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
      'empty inline filter cancels queued source work and restores covers',
      (tester) async {
    final covers = (await tester.runAsync(writeWorks))!;
    final gate = _ProbeGate(covers.map(p.normalize).toSet());
    IOOverrides.global = gate;
    addTearDown(() {
      if (!gate.release.isCompleted) gate.release.complete();
    });
    await mount(tester);
    await waitFor(tester, () => gate.reads.length == 2,
        reason: 'two source probes are held at the bounded queue limit');
    await tester.enterText(find.byType(TextField).first, 'no matching work');
    await tester.pump();
    expect(find.byKey(LocalLibraryIllustSlivers.noTagMatchKey), findsOneWidget);
    gate.release.complete();
    await waitFor(tester, () => gate.closed >= 2,
        reason:
            'in-flight source handles finish and release their queue slots');
    // Allow real IO and microtasks to drain. The third source must not be
    // admitted just because the old masonry no longer reports a layout range.
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(gate.reads, hasLength(2),
        reason: 'zero search results must cancel previously queued covers');
    expect(find.byType(IllustCard), findsNothing);
    await tester.enterText(find.byType(TextField).first, '');
    await waitFor(
        tester,
        () => List.generate(3, (i) => hasPixels(tester, 'Work $i'))
            .every((v) => v),
        reason:
            'clearing the filter restores real source-specific cover pixels');
    for (var i = 0; i < 3; i++) {
      await checkColor(tester, i);
    }
    await unmountAndDrain(tester);
  });

  testWidgets(
      'new matching work wins over late offscreen covers and reuses them',
      (tester) async {
    final covers = (await tester.runAsync(writeWorks))!;
    final gate = _ProbeGate(covers.map(p.normalize).toSet());
    IOOverrides.global = gate;
    addTearDown(() {
      if (!gate.release.isCompleted) gate.release.complete();
    });
    await mount(tester);
    await waitFor(tester, () => gate.reads.length == 2,
        reason: 'the first two source probes are pending');
    expect(gate.reads, isNot(contains(covers[0])),
        reason:
            'time-desc sorting leaves Work 0 queued behind the other works');
    await tester.enterText(find.byType(TextField).first, 'Work 0');
    await tester.pump();
    expect(find.byType(IllustCard), findsOneWidget);
    expect(card('Work 0'), findsOneWidget);
    gate.release.complete();
    await waitFor(tester, () => hasPixels(tester, 'Work 0'),
        reason: 'the newly matching work receives its own real cover');
    await checkColor(tester, 0);
    expect(card('Work 1'), findsNothing);
    expect(card('Work 2'), findsNothing);
    final provider = tester.widget<IllustCard>(card('Work 0')).imageProvider;
    final entry = tester.widget<IllustCard>(card('Work 0')).entry;
    expect(p.equals(entry.item.fileSystemPath!, p.dirname(covers[0])), isTrue);

    await tester.enterText(find.byType(TextField).first, '');
    await waitFor(
        tester,
        () => List.generate(3, (i) => hasPixels(tester, 'Work $i'))
            .every((v) => v),
        reason: 'all three distinct covers recover after clearing search');
    for (var i = 0; i < 3; i++) {
      await checkColor(tester, i);
    }
    expect(tester.widget<IllustCard>(card('Work 0')).imageProvider,
        same(provider));
    final completed = <String, ImageProvider<Object>?>{
      for (var i = 0; i < 3; i++)
        'Work $i': tester.widget<IllustCard>(card('Work $i')).imageProvider,
    };
    await tester.enterText(find.byType(TextField).first, 'Artist 1');
    await tester.pump();
    await waitFor(tester, () => hasPixels(tester, 'Work 1'),
        reason: 'author keyword filtering retains the completed source cover');
    expect(find.byType(IllustCard), findsOneWidget);
    expect(tester.widget<IllustCard>(card('Work 1')).imageProvider,
        same(completed['Work 1']));
    await checkColor(tester, 1);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      expect(tester.widget<IllustCard>(card('Work $i')).imageProvider,
          same(completed['Work $i']));
    }
    await unmountAndDrain(tester);
  });

  testWidgets(
      'local album inline filter keeps manager providers and own pixels',
      (tester) async {
    await tester.runAsync(writeWorks);
    appdata.settings[illustLibraryViewSettingIndex] = 'album';
    // A real local collection child uses comic tiles, unlike the root's folder
    // previews. Filtering still routes each child through the manager.
    await tester.runAsync(() => LocalLibraryManager().refresh());
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: LocalLibraryPage(albumOnly: true, localRootPath: root.path)));
    Finder tile(String title) => find.byWidgetPredicate(
        (widget) => widget is DownloadedComicTile && widget.name == title);
    Finder raster(String title) =>
        find.descendant(of: tile(title), matching: find.byType(RawImage));
    bool ready(String title) =>
        raster(title).evaluate().isNotEmpty &&
        tester.renderObject<RenderImage>(raster(title)).image != null;
    await waitFor(
        tester, () => List.generate(3, (i) => ready('Work $i')).every((v) => v),
        reason: 'actual collection children resolve through manager providers');
    final provider =
        tester.widget<DownloadedComicTile>(tile('Work 1')).imageProvider;
    expect(provider, isNotNull);
    await tester.tap(find.byTooltip('搜索'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(find.byType(TextField).first, 'Work 1');
    await tester.pump();
    await waitFor(tester, () => ready('Work 1'),
        reason: 'the filtered local collection child still paints its cover');
    expect(tile('Work 0'), findsNothing);
    expect(tile('Work 2'), findsNothing);
    expect(tester.widget<DownloadedComicTile>(tile('Work 1')).imageProvider,
        equals(provider));
    final image = tester.renderObject<RenderImage>(raster('Work 1')).image!;
    final bytes = (await tester
        .runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    expect(bytes.buffer.asUint8List().take(4), colors[1]);
    await tester.enterText(find.byType(TextField).first, 'no matching work');
    await tester.pump();
    expect(find.byWidgetPredicate((widget) => widget is DownloadedComicTile),
        findsNothing);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump();
    await waitFor(
        tester, () => List.generate(3, (i) => ready('Work $i')).every((v) => v),
        reason: 'clearing collection search restores all real cover pixels');
    await unmountAndDrain(tester);
  });

  testWidgets('keyword tag and folder filters preserve source-specific covers',
      (tester) async {
    await tester.runAsync(() => writeWorks(inFolders: true));
    await mount(tester);
    await waitFor(
        tester,
        () => List.generate(3, (i) => hasPixels(tester, 'Work $i'))
            .every((v) => v),
        reason: 'all registered folder works paint their own pixels');
    final provider = tester.widget<IllustCard>(card('Work 1')).imageProvider;
    await tester.enterText(find.byType(TextField).first, 'Work');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('illust-search-tag-tag_1')));
    await tester.pump();
    await waitFor(tester, () => hasPixels(tester, 'Work 1'),
        reason: 'keyword and selected tag intersect on the correct work');
    expect(find.byType(IllustCard), findsOneWidget);
    await tester.tap(find.byTooltip('选择插画文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha').last);
    await tester.pumpAndSettle();
    expect(card('Work 1'), findsOneWidget);
    expect(tester.widget<IllustCard>(card('Work 1')).imageProvider,
        same(provider));
    await checkColor(tester, 1);

    await tester.tap(find.byTooltip('选择插画文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta').last);
    await tester.pumpAndSettle();
    expect(find.byKey(LocalLibraryIllustSlivers.noTagMatchKey), findsOneWidget);
    expect(find.byType(IllustCard), findsNothing);
    await tester.tap(find.text('清除').first);
    await tester.pumpAndSettle();
    await waitFor(tester, () => hasPixels(tester, 'Work 2'),
        reason: 'clearing keyword and tag retains the selected Beta folder');
    expect(find.byType(IllustCard), findsOneWidget);
    await checkColor(tester, 2);
    await tester.tap(find.byTooltip('选择插画文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部文件夹').last);
    await tester.pumpAndSettle();
    await waitFor(
        tester,
        () => List.generate(3, (i) => hasPixels(tester, 'Work $i'))
            .every((v) => v),
        reason: 'all-folder restoration returns each correct cached provider');
    expect(tester.widget<IllustCard>(card('Work 1')).imageProvider,
        same(provider));
    await unmountAndDrain(tester);
  });
}
