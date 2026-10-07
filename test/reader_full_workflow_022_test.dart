// These tests isolate the real reader and original operations from user data.
// Native raster IO has a deterministic bitmap backend; original export bytes,
// page selection, toolbar callbacks, SQLite writes and widget lifecycles are
// production code. Native pixel accuracy/performance is measured separately.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/image_favorites.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/original_image_operations.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep/pages/reader/reader_page_image.dart';
import 'package:share_plus_platform_interface/method_channel/method_channel_share.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' as sqlite_loader;

class _TaskPaths extends PathProviderPlatform {
  _TaskPaths(this.root);
  final Directory root;
  @override
  Future<String?> getApplicationSupportPath() async => root.path;
  @override
  Future<String?> getApplicationCachePath() async => '${root.path}/cache';
  @override
  Future<String?> getTemporaryPath() async => '${root.path}/temporary';
}

class _TaskSaveDialog extends FileSelectorPlatform {
  _TaskSaveDialog(this.target);
  final File target;
  int calls = 0;
  @override
  Future<FileSaveLocation?> getSaveLocation(
      {List<XTypeGroup>? acceptedTypeGroups,
      SaveDialogOptions options = const SaveDialogOptions()}) async {
    calls++;
    return FileSaveLocation(target.path);
  }
}

class _BitmapBackend extends ReaderRasterBackend {
  _BitmapBackend(this.color);
  final Color color;
  int decodes = 0;
  @override
  bool get requiresFileBacking => false;
  @override
  Future<ReaderRasterMetadata> probe(File file) async => _metadata;
  static const _metadata = ReaderRasterMetadata(
      size: Size(1600, 2400),
      animated: false,
      format: 'test-png',
      workingBytes: 1);
  @override
  Future<ui.Image> decode(
    File file,
    ReaderTileDemand demand, {
    required String backingPath,
    required int memoryBudgetBytes,
    required bool Function() isCancelled,
    Future<void>? cancelled,
  }) async {
    if (isCancelled()) throw const ImageWorkCancelled();
    decodes++;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
        Rect.fromLTWH(0, 0, demand.outputWidth.toDouble(),
            demand.outputHeight.toDouble()),
        Paint()..color = color);
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(demand.outputWidth, demand.outputHeight);
    } finally {
      picture.dispose();
    }
  }
}

class _TaskSource extends FileReaderPageSource
    implements RasterReaderPageSource {
  _TaskSource(
      {required super.identity,
      required File file,
      required this.rasterBackend,
      this.gate,
      this.exportEntered})
      : rasterLocator = file,
        super(
            file: file,
            width: 1600,
            height: 2400,
            extension: '.png',
            mimeType: 'image/png');
  @override
  final File rasterLocator;
  @override
  final ReaderRasterBackend rasterBackend;
  final Completer<void>? gate;
  final Completer<ReaderPageIdentity>? exportEntered;
  bool disposed = false;
  @override
  Future<ReaderRasterMetadata> openRasterMetadata() async =>
      _BitmapBackend._metadata;
  @override
  Future<File> openOriginalFile({ReaderPageCancellation? cancellation}) async {
    if (exportEntered != null && !exportEntered!.isCompleted) {
      exportEntered!.complete(identity);
    }
    if (gate != null) await gate!.future;
    return super.openOriginalFile(cancellation: cancellation);
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    disposed = true;
  }
}

class _TaskReadingData extends ReadingData {
  _TaskReadingData(this.files, this.workId);
  final List<File> files;
  String workId;
  String label = 'task-original-title';
  final sources = <_TaskSource>[];
  Completer<void>? exportGate;
  Completer<ReaderPageIdentity>? exportEntered;
  @override
  String get id => workId;
  @override
  String get downloadId => 'task-download-$workId';
  @override
  String get sourceKey => 'task-original-reader';
  @override
  String get title => label;
  @override
  ComicType get comicType => ComicType.picacg;
  @override
  FavoriteType get favoriteType => FavoriteType.picacg;
  @override
  bool get hasEp => true;
  @override
  Map<String, String> get eps => const {'1': 'chapter-one', '2': 'chapter-two'};
  @override
  bool get downloaded => false;
  @override
  Future<List<String>> loadEpNetwork(int ep) async =>
      files.map((file) => file.path).toList();
  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) =>
      files[page].openRead();
  @override
  Future<ReaderPageSource> resolvePageSource(
      int ep, int page, String url) async {
    final source = _TaskSource(
        identity: ReaderPageIdentity(
            sourceKey: sourceKey,
            workId: workId,
            downloadId: downloadId,
            episode: ep,
            page: page,
            sourceVersion: '${files[page].path}:version1'),
        file: files[page],
        rasterBackend: _BitmapBackend(_colors[page]),
        gate: exportGate,
        exportEntered: exportEntered);
    sources.add(source);
    return source;
  }
}

const _colors = [
  Color(0xffee1122),
  Color(0xff2255ee),
  Color(0xff33aa44),
  Color(0xffaa44cc)
];

Future<void> _pump(WidgetTester tester, {int frames = 24}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
  }
}

Future<void> _until(WidgetTester tester, bool Function() condition,
    {String reason = 'condition', int limit = 180}) async {
  for (var i = 0; i < limit; i++) {
    if (condition()) return;
    await _pump(tester, frames: 1);
  }
  expect(condition(), isTrue, reason: reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late List<File> originals;
  late Appdata previousAppdata;
  late FileSelectorPlatform previousFileSelector;
  late SharePlatform previousShare;
  late _TaskSaveDialog saveDialog;
  final shared = <File>[];

  setUpAll(() async {
    previousFileSelector = FileSelectorPlatform.instance;
    previousShare = SharePlatform.instance;
    if (Platform.isWindows) {
      sqlite_loader.open.overrideFor(
          sqlite_loader.OperatingSystem.windows,
          () => DynamicLibrary.open(
              '${Directory.current.path}/windows/sqlite3.dll'));
    }
    // Only this task-owned directory is created/removed. All large verification
    // output stays on E on Windows; no normal user app directory is opened.
    final base = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-runtime')
        : Directory.systemTemp;
    await base.create(recursive: true);
    root = await base.createTemp('workflow-widget-');
    final paths = _TaskPaths(root);
    PathProviderPlatform.instance = paths;
    App.dataPath = root.path;
    App.cachePath = '${root.path}/cache';
    await Directory(App.cachePath).create(recursive: true);
    setManagedDataRootOverride(root.path);
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
    SharedPreferences.setMockInitialValues({});
    previousAppdata = appdata;
    appdata = Appdata();
    await HistoryManager().init();
    await LocalFavoritesManager().init(dataRoots: [root.path]);
    SharePlatform.instance = MethodChannelShare();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelShare.channel, (call) async {
      if (call.method == 'shareFilesWithResult') {
        final arguments = call.arguments as Map;
        final path = (arguments['paths'] as List).single as String;
        final captured =
            File('${root.path}/captured-share-${shared.length}.png');
        await File(path).copy(captured.path);
        shared.add(captured);
        return 'task-share-complete';
      }
      return null;
    });
    originals = [];
    for (var i = 0; i < _colors.length; i++) {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 1600, 2400), Paint()..color = _colors[i]);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(1600, 2400);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      final file = File('${root.path}/original-$i.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      originals.add(file);
    }
  });

  setUp(() {
    appdata.settings = List.of(Appdata().settings);
    appdata.settings[0] = '0';
    appdata.settings[7] = '0';
    appdata.settings[14] = '0';
    appdata.settings[43] = '0';
    appdata.settings[49] = '1';
    appdata.settings[50] = 'cn';
    appdata.settings[55] = '0';
    appdata.settings[76] = '0';
    appdata.implicitData[1] = '0';
    saveDialog = _TaskSaveDialog(File(
        '${root.path}/saved-${DateTime.now().microsecondsSinceEpoch}.png'));
    FileSelectorPlatform.instance = saveDialog;
    shared.clear();
    for (final favorite in ImageFavoriteManager.getAll()) {
      ImageFavoriteManager.delete(favorite);
    }
  });

  tearDownAll(() async {
    FileSelectorPlatform.instance = previousFileSelector;
    SharePlatform.instance = previousShare;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelShare.channel, null);
    HistoryManager().dispose();
    LocalFavoritesManager().dispose();
    setManagedDataRootOverride(null);
    appdata = previousAppdata;
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<ComicReadingPageLogic> open(WidgetTester tester, _TaskReadingData data,
      String layout, ReaderDisplayMode mode,
      {int initialPage = 1}) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    appdata.settings[9] = layout;
    appdata.settings[readerImagePipelineSettingIndex] =
        ReaderImagePipelineSettings(comic: mode, illust: mode).encode();
    final page = ComicReadingPage(data, initialPage, 1);
    await tester.pumpWidget(MaterialApp(
        navigatorKey: App.navigatorKey,
        home: page,
        theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue))));
    final logic = StateController.find<ComicReadingPageLogic>();
    await _until(tester,
        () => !logic.isLoading && ReaderSurfaceDiagnostics.residentBytes > 0,
        reason: 'real ComicReadingPage should load authoritative sources');
    await _pump(tester);
    expect(find.byType(ReaderPageImage), findsWidgets);
    expect(tester.takeException(), isNull);
    return logic;
  }

  Future<void> close(WidgetTester tester, ComicReadingPageLogic logic,
      _TaskReadingData data) async {
    await tester.pumpWidget(const SizedBox());
    await _until(
        tester,
        () =>
            ReaderSurfaceDiagnostics.activeSurfaces == 0 &&
            ReaderSurfaceDiagnostics.residentBytes == 0 &&
            !ImageWorkScheduler.shared.hasWork &&
            ReaderPageFileLease.activeLeaseCount == 0 &&
            data.sources.every((source) => source.disposed),
        reason:
            'full reader exit must release sources/native work/decoded layers');
    expect(StateController.findOrNull<ComicReadingPageLogic>(), isNull);
    expect(App.isReadingActive.value, isFalse);
    expect(ImageTemporaryPool.shared.reservedBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    // The existing reader currently owns these non-image controllers through
    // logic; explicit test finalisation prevents unrelated test binding leaks.
    logic.pageController.dispose();
    logic.scrollController.dispose();
    logic.focusNode.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    expect(tester.takeException(), isNull);
  }

  for (final layout in ['1', '4', '5']) {
    for (final mode in ReaderDisplayMode.values) {
      testWidgets(
          'full reader layout $layout ${mode.name}: native button and ten exits release original sources',
          (tester) async {
        for (var iteration = 0; iteration < 10; iteration++) {
          final data = _TaskReadingData(
              originals, 'lifecycle-$layout-${mode.name}-$iteration');
          final logic = await open(tester, data, layout, mode);
          logic.tools = true;
          logic.update();
          await _pump(tester);
          final before = logic.photoViewController;
          final sourceCount = data.sources.length;
          await tester.tap(find.byIcon(Icons.zoom_in_map));
          await _pump(tester);
          final scaleKey =
              layout == '4' ? -logic.index : logic.activePhotoControllerIndex;
          expect(logic.photoViewController, same(before),
              reason: 'native pixels keeps the pan controller');
          expect(before.scale,
              closeTo(logic.nativePixelScales[scaleKey]!, .00001));
          expect(data.sources.length, sourceCount,
              reason: 'quality upgrade should not reopen original sources');
          expect(tester.takeException(), isNull);
          await close(tester, logic, data);
          for (final original in originals) {
            expect(await tester.runAsync(original.exists), isTrue);
          }
        }
      });
    }
  }

  for (final operation in ['save', 'share', 'favorite']) {
    testWidgets(
        '$operation freezes selected original and metadata while page/chapter/work change',
        (tester) async {
      final data = _TaskReadingData(originals, 'frozen-$operation');
      final logic = await open(tester, data, '1', ReaderDisplayMode.sharpFirst);
      logic.tools = true;
      logic.update();
      await _pump(tester);
      data.exportGate = Completer<void>();
      data.exportEntered = Completer<ReaderPageIdentity>();
      await tester.tap(find.byIcon(operation == 'save'
          ? Icons.save_alt
          : operation == 'share'
              ? Icons.share
              : Icons.favorite_outline));
      await _until(tester, () => data.exportEntered!.isCompleted,
          reason: 'operation must open the frozen page');
      final selected = await data.exportEntered!.future;
      expect(selected.page, 0);
      expect(selected.episode, 1);
      final originalId = data.workId;
      logic.pageController.jumpToPage(2);
      logic.order = 2;
      data.workId = 'other-work';
      data.label = 'changed-title';
      data.exportGate!.complete();
      if (operation == 'save') {
        await _until(tester, () => saveDialog.calls == 1,
            reason: 'save dialog should receive source file');
        await _pump(tester);
        final digest =
            await tester.runAsync(() => originalImageDigest(saveDialog.target));
        expect(digest,
            await tester.runAsync(() => originalImageDigest(originals[0])));
      } else if (operation == 'share') {
        await _until(tester, () => shared.isNotEmpty,
            reason: 'share plugin should receive source file');
        expect(await tester.runAsync(() => originalImageDigest(shared.single)),
            await tester.runAsync(() => originalImageDigest(originals[0])));
      } else {
        await _until(tester, () => ImageFavoriteManager.length == 1,
            reason: 'favorite transaction should finish');
        final favorite = ImageFavoriteManager.getAll().single;
        expect(favorite.id, 'task-original-reader-$originalId');
        expect(favorite.title, 'task-original-title');
        expect(favorite.ep, 1);
        expect(favorite.page, 1);
        expect(favorite.otherInfo['url'], originals[0].path);
        expect(favorite.otherInfo['sourceVersion'], selected.sourceVersion);
        expect(favorite.otherInfo['downloadId'], 'task-download-$originalId');
        expect(
            await tester
                .runAsync(() => originalImageDigest(File(favorite.imagePath))),
            await tester.runAsync(() => originalImageDigest(originals[0])));
      }
      data.exportGate = null;
      data.exportEntered = null;
      await close(tester, logic, data);
    });
  }

  for (final layout in ['4', '5']) {
    testWidgets(
        'layout $layout offers actual visible originals and freezes modal selection across a later pan',
        (tester) async {
      final data = _TaskReadingData(originals, 'selection-$layout');
      final logic =
          await open(tester, data, layout, ReaderDisplayMode.previewFirst);
      if (layout == '4') {
        logic.itemScrollController.jumpTo(index: 0, alignment: -1.3);
        await _pump(tester);
      }
      logic.tools = true;
      logic.update();
      await _pump(tester);
      final visible = layout == '5'
          ? [0, 1]
          : (logic.itemScrollListener.itemPositions.value
              .where((item) =>
                  item.itemLeadingEdge < 1 && item.itemTrailingEdge > 0)
              .map((item) => item.index)
              .toSet()
              .toList()
            ..sort());
      expect(visible.length, greaterThan(1));
      await tester.tap(find.byIcon(Icons.share));
      await _pump(tester);
      expect(find.text('选择屏幕上的图片'), findsOneWidget);
      for (final index in visible) {
        expect(
            find.descendant(
                of: find.byType(SimpleDialog),
                matching: find.widgetWithText(ListTile, '${index + 1}')),
            findsOneWidget);
      }
      logic.index = 4;
      logic.order = 2;
      final chosen = visible.last;
      await tester.tap(find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.widgetWithText(ListTile, '${chosen + 1}')));
      await _until(tester, () => shared.isNotEmpty);
      expect(await tester.runAsync(() => originalImageDigest(shared.single)),
          await tester.runAsync(() => originalImageDigest(originals[chosen])));
      await close(tester, logic, data);
    });
  }
}
