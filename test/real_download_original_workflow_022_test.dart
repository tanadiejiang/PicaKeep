// Opt-in verification against the two anonymous, read-only real download
// fixtures. No user library, settings or DB is opened. Raster/source/reader and
// favorite SQL are production code; system dialogs/share delivery are captured.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/archive/archive_registry.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/image_favorites.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/original_image_operations.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep/server/local_server_runtime.dart';
import 'package:picakeep/server/server_config.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';
import 'package:share_plus_platform_interface/method_channel/method_channel_share.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' as sqlite_loader;

const _jpegDigest =
    'd5dec8bd5d19d8170b21a725c4b4e025751f1b22ed9ac6f62293c51e83aef690';
const _zipDigest =
    '0d65012191602d018fcb14b5fb909c7da74691365b468d90e3c89e92377ccd35';
const _memberDigests = [
  '8811fe1a50a009f754b59cc169e73f3a506564baba77b6415ae127856f753ffe',
  'c868636157f575a502f4debc9f536c43dab60669a3b41e405c96fa1673258990'
];

class _TaskPaths extends PathProviderPlatform {
  _TaskPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
  @override
  Future<String?> getTemporaryPath() async => p.join(root, 'temporary');
}

class _TaskSaveDialog extends FileSelectorPlatform {
  _TaskSaveDialog(this.target);
  final File target;
  @override
  Future<FileSaveLocation?> getSaveLocation(
          {List<XTypeGroup>? acceptedTypeGroups,
          SaveDialogOptions options = const SaveDialogOptions()}) async =>
      FileSaveLocation(target.path);
}

class _RealHttpOverrides extends HttpOverrides {}

LocalPathReadingData _readingData(File input, String id) =>
    LocalPathReadingData(
      title: 'anonymous-real-download',
      id: id,
      downloadId: 'anonymous-$id',
      sourceKey: 'pixiv',
      directoryPath: input.path,
      hasEp: false,
      comicType: ComicType.pixiv,
      episodeFiles: const {},
      downloadedEpisodeIndexes: const [0],
      supportsImageSort: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sourceRoot = Platform.environment['PICAKEEP_022_REAL_SOURCE_ROOT'];
  final enabled = Platform.isWindows && sourceRoot != null;
  final remoteEnabled =
      Platform.environment['PICAKEEP_022_REMOTE_WORKFLOW'] == '1';
  final skip = enabled
      ? false
      : 'Requires explicit PICAKEEP_022_REAL_SOURCE_ROOT and native DLL on Windows';
  late Directory task;
  late File jpeg;
  late File zip;
  late Appdata oldAppdata;
  late PathProviderPlatform oldPaths;
  late FileSelectorPlatform oldDialog;
  late SharePlatform oldShare;
  HttpOverrides? oldHttpOverrides;
  final remoteItems = <String, RemoteLibraryComicItem>{};
  var runtimeStarted = false;
  final shared = <File>[];
  final records = <Map<String, Object?>>[];
  var completedWorkflows = 0;
  final sourceStats = <String, FileStat>{};

  setUpAll(() async {
    if (!enabled) return;
    expect(PicakeepImageEngine.isAvailable, isTrue,
        reason:
            'This real workflow explicitly verifies the native-enabled path');
    jpeg = File(p.join(sourceRoot, 'page-001.jpg'));
    zip = File(p.join(sourceRoot, 'archive-001.zip'));
    for (final input in [jpeg, zip]) {
      expect(await input.exists(), isTrue);
      sourceStats[input.path] = await input.stat();
    }
    expect(await originalImageDigest(jpeg), _jpegDigest);
    expect(await originalImageDigest(zip), _zipDigest);
    final base = Directory(r'E:\picakeep-image-pipeline-022-runtime');
    await base.create(recursive: true);
    task = await base.createTemp('real-source-workflow-');
    oldPaths = PathProviderPlatform.instance;
    oldDialog = FileSelectorPlatform.instance;
    oldShare = SharePlatform.instance;
    PathProviderPlatform.instance = _TaskPaths(task.path);
    sqlite_loader.open.overrideFor(
        sqlite_loader.OperatingSystem.windows,
        () => DynamicLibrary.open(
            p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
    App.dataPath = task.path;
    App.cachePath = p.join(task.path, 'cache');
    await Directory(App.cachePath).create(recursive: true);
    setManagedDataRootOverride(task.path);
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
    SharedPreferences.setMockInitialValues({});
    oldAppdata = appdata;
    appdata = Appdata();
    ArchiveRegistry.initDefaults();
    await HistoryManager().init();
    await LocalFavoritesManager().init(dataRoots: [task.path]);
    SharePlatform.instance = MethodChannelShare();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelShare.channel, (call) async {
      if (call.method == 'shareFilesWithResult') {
        final path =
            ((call.arguments as Map)['paths'] as List).single as String;
        final captured = File(p.join(task.path, 'share-${shared.length}.bin'));
        await File(path).copy(captured.path);
        shared.add(captured);
        return 'verification-captured';
      }
      return null;
    });
  });

  tearDownAll(() async {
    if (!enabled) return;
    if (runtimeStarted) {
      await LocalServerRuntime.instance.stop();
      LocalServerRuntime.instance.configPathOverride = null;
      HttpOverrides.global = oldHttpOverrides;
      await PicakeepImageEngine.shutdownIdleWorkers();
    }
    for (final input in [jpeg, zip]) {
      final before = sourceStats[input.path]!;
      final after = await input.stat();
      expect(after.size, before.size);
      expect(after.modified, before.modified);
      expect(await originalImageDigest(input),
          input == jpeg ? _jpegDigest : _zipDigest);
    }
    final reportPath = Platform.environment['PICAKEEP_022_SOURCE_REPORT'];
    if (reportPath != null) {
      final report = File(reportPath);
      await report.parent.create(recursive: true);
      await report.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'scope': remoteEnabled
            ? 'Windows production LocalServerRuntime with native renderer over real HTTP; RemoteLibraryClient/RemoteLibraryReadingData/ComicReadingPage; system dialogs/share mocked'
            : 'Windows real ComicReadingPage widget; native metadata and Flutter raster; system dialogs/share mocked',
        'jpegSha256': _jpegDigest,
        'zipSha256': _zipDigest,
        'sourcesUnchanged': true,
        'complete': records.length == 39 && completedWorkflows == 12,
        'completedWorkflows': completedWorkflows,
        'records': records,
      }));
    }
    HistoryManager().dispose();
    LocalFavoritesManager().dispose();
    setManagedDataRootOverride(null);
    appdata = oldAppdata;
    PathProviderPlatform.instance = oldPaths;
    FileSelectorPlatform.instance = oldDialog;
    SharePlatform.instance = oldShare;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelShare.channel, null);
    await task.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 16));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 3)));
  }

  Future<void> until(
      WidgetTester tester, bool Function() predicate, String reason) async {
    for (var i = 0; i < 1500 && !predicate(); i++) {
      await pump(tester);
    }
    if (!predicate()) {
      // Keep actual raster diagnostics in any failed integration evidence.
      debugPrint('REAL_022_FAILED ${ReaderSurfaceDiagnostics.snapshot()}');
      debugPrint(
          'REAL_022_DISK pending=${ImageDiskQuota.shared.pendingCount} ops=${ImageDiskQuota.shared.pendingOperations} stage=${ImageDiskQuota.shared.operationStage} active=${ImageDiskQuota.shared.activeBytes} idle=${ImageDiskQuota.shared.idleBytes} rejected=${ImageDiskQuota.shared.rejectedCount} last=${ImageDiskQuota.shared.lastRejection}');
    }
    expect(predicate(), isTrue, reason: reason);
    expect(tester.takeException(), isNull);
  }

  test(
      'real JPEG and every ZIP member resolve production originals and release bounded extraction',
      () async {
    for (final input in [jpeg, zip]) {
      final data = _readingData(input, input == jpeg ? 'jpeg' : 'zip');
      final pages = await data.loadEp(0);
      // The real ZIP includes a separate cover payload. Production page
      // listing correctly excludes it and exposes exactly two reading pages.
      expect(pages.length, input == jpeg ? 1 : 2);
      for (var i = 0; i < pages.length; i++) {
        final source = await data.resolvePageSource(0, i, pages[i]);
        final baseline = ImageTemporaryPool.shared.reservedBytes;
        final file = await source.openOriginalFile();
        final expected = input == jpeg ? _jpegDigest : _memberDigests[i];
        expect(await originalImageDigest(file), expected);
        final size = await file.length();
        final type = await originalImageType(file);
        expect(source.isAuthoritativeOriginal, isTrue);
        expect(source.isPreviewOnly, isFalse);
        expect(source.identity.page, i);
        if (input == zip) {
          expect(ImageTemporaryPool.shared.reservedBytes, baseline + size);
        }
        records.add({
          'source': input == jpeg ? 'jpeg' : 'zip',
          'page': i,
          'size': size,
          'sha256': expected,
          'mime': type.mime
        });
        final release = ReaderPageFileLease.acquire(file);
        final disposal = source.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(await file.exists(), isTrue);
        release();
        await disposal;
        expect(await file.exists(), input == jpeg);
        expect(ImageTemporaryPool.shared.reservedBytes, baseline);
      }
    }
  }, skip: skip);

  if (remoteEnabled) {
    test(
        'production LocalServerRuntime starts native HTTP service from task-only roots',
        () async {
      oldHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = _RealHttpOverrides();
      final library = Directory(p.join(task.path, 'library'));
      await Directory(p.join(library.path, 'real-jpeg'))
          .create(recursive: true);
      await jpeg.copy(p.join(library.path, 'real-jpeg', '1.jpg'));
      await jpeg.copy(p.join(library.path, 'real-jpeg', 'cover.jpg'));
      await zip.copy(p.join(library.path, 'archive-001.zip'));
      final reservation = await ServerSocket.bind('127.0.0.1', 0);
      final port = reservation.port;
      await reservation.close();
      final configPath = p.join(task.path, 'runtime-server.data');
      await PicaKeepServerConfig.save(
          configPath,
          PicaKeepServerConfig.defaults().copyWith(
              host: '127.0.0.1',
              port: port,
              customLibraryRoots: [library.path],
              managedDataRoot: task.path,
              consolePassword: 'isolated-verification-022'));
      LocalServerRuntime.instance.configPathOverride = configPath;
      await LocalServerRuntime.instance.start();
      runtimeStarted = true;
      final snapshot = await LocalServerRuntime.instance.readSnapshot();
      expect(snapshot.isRunning, isTrue);
      expect(snapshot.customLibraryRoots, [library.path]);
      appdata.settings[remoteServerAddressSettingIndex] =
          'http://127.0.0.1:$port';
      final client = RemoteLibraryClient.fromCurrentSettings();
      for (final item in await client.fetchItems()) {
        if (item.title == 'real-jpeg') {
          remoteItems['remote-jpeg'] = await client.fetchItemDetail(item.id);
        } else if (item.title.startsWith('archive-001')) {
          remoteItems['remote-zip'] = await client.fetchItemDetail(item.id);
        }
      }
      expect(remoteItems.keys.toSet(), {'remote-jpeg', 'remote-zip'});
      expect(remoteItems['remote-jpeg']!.pageUrls.length, 1);
      expect(remoteItems['remote-zip']!.pageUrls.length, 2);
      for (final item in remoteItems.values) {
        final source = await RemoteLibraryReadingData(item: item)
            .resolvePageSource(0, 0, item.pageUrls.first);
        expect(source, isA<RasterReaderPageSource>());
        expect(source.isAuthoritativeOriginal, isTrue);
        await source.dispose();
      }
    }, skip: skip);
  }

  for (final kind
      in remoteEnabled ? ['remote-jpeg', 'remote-zip'] : ['jpeg', 'zip']) {
    for (final layout in ['1', '4', '5']) {
      for (final mode in ReaderDisplayMode.values) {
        testWidgets(
            'real $kind layout $layout ${mode.name}: native pixels and original save/share/favorite',
            (tester) async {
          appdata.settings = List.of(Appdata().settings);
          if (remoteEnabled) {
            appdata.settings[remoteServerAddressSettingIndex] =
                remoteItems[kind]!.client.baseUrl;
          }
          appdata.settings[0] = '0';
          appdata.settings[7] = '0';
          appdata.settings[9] = layout;
          appdata.settings[14] = '0';
          appdata.settings[43] = '0';
          appdata.settings[49] = '1';
          appdata.settings[50] = 'cn';
          appdata.settings[55] = '0';
          appdata.settings[76] = '0';
          appdata.implicitData[1] = '0';
          appdata.settings[readerImagePipelineSettingIndex] =
              ReaderImagePipelineSettings(comic: mode, illust: mode).encode();
          for (final favorite in ImageFavoriteManager.getAll()) {
            ImageFavoriteManager.delete(favorite);
          }
          shared.clear();
          final saved =
              File(p.join(task.path, 'save-$kind-$layout-${mode.name}.bin'));
          FileSelectorPlatform.instance = _TaskSaveDialog(saved);
          final ReadingData data = remoteEnabled
              ? RemoteLibraryReadingData(item: remoteItems[kind]!)
              : _readingData(
                  kind == 'jpeg' ? jpeg : zip, '$kind-$layout-${mode.name}');
          tester.view.physicalSize = const Size(1200, 900);
          tester.view.devicePixelRatio = 1;
          await tester.pumpWidget(MaterialApp(
              navigatorKey: App.navigatorKey,
              home: ComicReadingPage(data, 1, 0)));
          final logic = StateController.find<ComicReadingPageLogic>();
          await until(
              tester,
              () =>
                  !logic.isLoading &&
                  ReaderSurfaceDiagnostics.residentBytes > 0,
              'real native-enabled reader must present a raster');
          logic.tools = true;
          logic.update();
          for (var i = 0; i < 12; i++) {
            await pump(tester);
          }
          await tester.tap(find.byIcon(Icons.zoom_in_map));
          for (var i = 0; i < 24; i++) {
            await pump(tester);
          }
          final expected =
              kind.endsWith('jpeg') ? _jpegDigest : _memberDigests.first;
          for (final operation in ['save', 'share', 'favorite']) {
            await tester.tap(find.byIcon(operation == 'save'
                ? Icons.save_alt
                : operation == 'share'
                    ? Icons.share
                    : Icons.favorite_outline));
            for (var i = 0; i < 24; i++) {
              await pump(tester);
            }
            if (find.byType(SimpleDialog).evaluate().isNotEmpty) {
              final firstChoice = find
                  .descendant(
                      of: find.byType(SimpleDialog),
                      matching: find.byType(ListTile))
                  .first;
              await tester.tap(firstChoice);
            }
            await until(
                tester,
                () => operation == 'save'
                    ? saved.existsSync()
                    : operation == 'share'
                        ? shared.isNotEmpty
                        : ImageFavoriteManager.length == 1,
                '$operation should receive the selected original');
            final output = operation == 'save'
                ? saved
                : operation == 'share'
                    ? shared.single
                    : File(ImageFavoriteManager.getAll().single.imagePath);
            expect(await tester.runAsync(() => originalImageDigest(output)),
                expected);
            if (operation == 'favorite') {
              final favorite = ImageFavoriteManager.getAll().single;
              expect(favorite.page, 1);
              expect(favorite.otherInfo['sourceKey'],
                  remoteEnabled ? 'remote_library' : 'pixiv');
              expect(favorite.otherInfo['downloadId'], data.downloadId);
            }
            records.add({
              'source': kind,
              'layout': layout,
              'mode': mode.name,
              'operation': operation,
              'page': 0,
              'sha256': expected
            });
            // Saving shows the production two-second SnackBar over the bottom
            // toolbar. Let it disappear before tapping the next real button.
            for (var i = 0; i < 32; i++) {
              await pump(tester);
            }
            await tester.pump(const Duration(seconds: 3));
            await tester.pump(const Duration(milliseconds: 350));
            await pump(tester);
          }
          await tester.pumpWidget(const SizedBox());
          // A same-process service deliberately owns its 30-second extracted
          // member lease and background covers after a client reader exits.
          // Stop the independent service to verify complete process image
          // cleanup; restart the same task server for the next layout.
          if (remoteEnabled) {
            await tester.runAsync(LocalServerRuntime.instance.stop);
            await tester.pump(const Duration(seconds: 32));
          }
          await until(
              tester,
              () =>
                  ReaderSurfaceDiagnostics.activeSurfaces == 0 &&
                  ReaderSurfaceDiagnostics.residentBytes == 0 &&
                  !ImageWorkScheduler.shared.hasWork &&
                  ReaderPageFileLease.activeLeaseCount == 0 &&
                  ImageTemporaryPool.shared.reservedBytes == 0 &&
                  ImageDiskQuota.shared.pendingOperations == 0,
              'reader exit must release real member files and all image budgets');
          logic.pageController.dispose();
          logic.scrollController.dispose();
          logic.focusNode.dispose();
          final shutdown = PicakeepImageEngine.shutdownIdleWorkers();
          await until(
              tester,
              () => PicakeepImageEngine.workerDiagnostics['workersAlive'] == 0,
              'native metadata workers should close after reader exit');
          await shutdown;
          await tester.pump(const Duration(seconds: 6));
          if (remoteEnabled) {
            await tester.runAsync(LocalServerRuntime.instance.start);
          }
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          completedWorkflows++;
        }, skip: !enabled);
      }
    }
  }
}
