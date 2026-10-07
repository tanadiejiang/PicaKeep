import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/service_data_source.dart';
import 'package:picakeep/pages/service_info_page.dart';
import 'package:picakeep/server/local_server_runtime.dart';
import 'package:picakeep/server/server_config.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';
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

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final oldPaths = PathProviderPlatform.instance;
  final oldAppdata = appdata;
  final oldMode = managedDataSourceMode;
  final oldHttp = HttpOverrides.current;
  late Directory task;
  late String configPath;
  late Uri status;
  late File original;
  late List<int> originalBytes;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows,
          () => DynamicLibrary.open(
              p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
    }
    final parent = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    task = await parent.createTemp('service_gui_isolated_');
    PathProviderPlatform.instance = _Paths(task.path);
    await App.init(
        dataPathOverride: task.path,
        cachePathOverride: p.join(task.path, 'cache'));
    appdata = Appdata();
    appdata.settings[appRuntimeModeSettingIndex] = appRuntimeModeServer;
    appdata.settings[remoteServerAddressSettingIndex] = '';
    setManagedDataRootOverride(task.path);
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
    final library = await Directory(p.join(task.path, 'library', 'fixture'))
        .create(recursive: true);
    originalBytes = img.encodePng(img.Image(width: 12, height: 18));
    original =
        await File(p.join(library.path, '1.png')).writeAsBytes(originalBytes);
    await File(p.join(library.path, 'cover.png')).writeAsBytes(originalBytes);
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    final port = socket.port;
    await socket.close();
    status = Uri.parse('http://127.0.0.1:$port/status');
    configPath = p.join(task.path, 'isolated-server.data');
    await PicaKeepServerConfig.save(
        configPath,
        PicaKeepServerConfig.defaults().copyWith(
            host: '127.0.0.1',
            port: port,
            currentDownloadRoot: '',
            originalDownloadRoot: '',
            customLibraryRoots: [p.dirname(library.path)],
            managedDataRoot: task.path,
            consolePassword: 'isolated-gui-fixture'));
    LocalServerRuntime.instance.configPathOverride = configPath;
    HttpOverrides.global = _RealHttp();
  });
  tearDownAll(() async {
    if (LocalServerRuntime.instance.isRunning) {
      await LocalServerRuntime.instance.stop();
    }
    LocalServerRuntime.instance.configPathOverride = null;
    HttpOverrides.global = oldHttp;
    HistoryManager().dispose();
    LocalFavoritesManager().dispose();
    setManagedDataRootOverride(null);
    setManagedDataSourceMode(oldMode);
    appdata = oldAppdata;
    PathProviderPlatform.instance = oldPaths;
    try {
      await task.delete(recursive: true);
    } catch (_) {}
  });

  testWidgets('actual ServiceInfoPage starts, restarts and stops task HTTP',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final before = (await tester.runAsync(original.stat))!;
    await tester.pumpWidget(MaterialApp(
        home: ServiceInfoPage(
            standalone: true,
            dataSource: LocalRuntimeServiceDataSource(),
            enableInlineAutoDiscovery: false)));

    Future<void> until(bool Function() predicate) async {
      for (var i = 0; i < 600; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 16));
        if (predicate()) return;
      }
      expect(predicate(), isTrue, reason: 'real service GUI did not settle');
    }

    Future<Map<String, dynamic>> requestStatus() async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      try {
        final response = await (await client.getUrl(status)).close();
        if (response.statusCode != 200) {
          throw StateError('status request returned ${response.statusCode}');
        }
        return jsonDecode(await response.transform(utf8.decoder).join())
            as Map<String, dynamic>;
      } finally {
        client.close(force: true);
      }
    }

    Future<T> awaitHttp<T>(Future<T> Function() action) async {
      T? result;
      Object? error;
      StackTrace? stack;
      var finished = false;
      unawaited(
          HttpOverrides.runWithHttpOverrides(action, _RealHttp()).then((value) {
        result = value;
        finished = true;
      }, onError: (Object value, StackTrace trace) {
        error = value;
        stack = trace;
        finished = true;
      }));
      await until(() => finished);
      if (error != null) Error.throwWithStackTrace(error!, stack!);
      return result as T;
    }

    Finder button(String label) => find.widgetWithText(FilledButton, label);
    bool enabled(String label) =>
        button(label).evaluate().isNotEmpty &&
        tester.widget<FilledButton>(button(label)).onPressed != null;
    await until(() => enabled('启动服务'));
    expect(LocalServerRuntime.instance.isRunning, isFalse);
    await tester.ensureVisible(button('启动服务'));
    await tester.tap(button('启动服务'));
    await until(() => LocalServerRuntime.instance.isRunning && enabled('停止服务'));
    final firstStatus = await awaitHttp(requestStatus);
    expect(firstStatus['comicCount'], 1);
    final running =
        (await tester.runAsync(LocalServerRuntime.instance.readSnapshot))!;
    expect(running.configPath, configPath);
    expect(running.customLibraryRoots, [p.dirname(original.parent.path)]);
    expect(running.currentDownloadRoot, isEmpty);
    expect(running.originalDownloadRoot, isEmpty);

    await tester.ensureVisible(button('重启服务'));
    await tester.tap(button('重启服务'));
    await until(() => LocalServerRuntime.instance.isRunning && enabled('停止服务'));
    final secondStatus = await awaitHttp(requestStatus);
    expect(secondStatus['comicCount'], firstStatus['comicCount']);

    await tester.ensureVisible(button('停止服务'));
    await tester.tap(button('停止服务'));
    await until(
        () => !LocalServerRuntime.instance.isRunning && enabled('启动服务'));
    final stoppedRefusesConnection = await awaitHttp(() async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);
      try {
        await client.getUrl(status);
        return false;
      } on SocketException {
        return true;
      } finally {
        client.close(force: true);
      }
    });
    expect(stoppedRefusesConnection, isTrue);
    final after = (await tester.runAsync(original.stat))!;
    expect((after.size, after.modified), (before.size, before.modified));
    expect(await tester.runAsync(original.readAsBytes), originalBytes);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(PicakeepImageEngine.workerDiagnostics['activeJobs'], 0);
    expect(PicakeepImageEngine.workerDiagnostics['queuedJobs'], 0);
    final shutdown = PicakeepImageEngine.shutdownIdleWorkers();
    await until(
        () => PicakeepImageEngine.workerDiagnostics['workersAlive'] == 0);
    await shutdown;
    debugDefaultTargetPlatformOverride = null;
  });
}
