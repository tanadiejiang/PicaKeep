// Actual application UI with persistent, explicitly isolated verification data.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/window_frame.dart';
import 'package:picakeep/foundation/ai/ai_download_queue.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/archive/archive_registry.dart';
import 'package:picakeep/foundation/archive/backends/dart_zip_backend.dart';
import 'package:picakeep/foundation/explore/explore_bindings.dart';
import 'package:picakeep/foundation/image_pipeline/background_image_preparer.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/log_file_service.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart';
import 'package:picakeep/main.dart' as normal;
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/server/local_server_runtime.dart';
import 'package:picakeep/server/server_config.dart';
import 'package:picakeep/tools/tags_translation.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'image_pipeline_022_task_storage.dart';
import 'image_pipeline_022_normal_ui_observer.dart';

const _jpegDigest =
    'd5dec8bd5d19d8170b21a725c4b4e025751f1b22ed9ac6f62293c51e83aef690';
const _zipDigest =
    '0d65012191602d018fcb14b5fb909c7da74691365b468d90e3c89e92377ccd35';
const _pngDigests = [
  '8811fe1a50a009f754b59cc169e73f3a506564baba77b6415ae127856f753ffe',
  'c868636157f575a502f4debc9f536c43dab60669a3b41e405c96fa1673258990',
];
const _preferencePrefix = 'picakeep022.';

Future<void> main(List<String> arguments) async {
  if (kReleaseMode) {
    throw StateError('Verification supports debug/profile only');
  }
  var args = List<String>.of(arguments);
  if (args.isEmpty && Platform.isAndroid) {
    // The device operator must create this task-only options file explicitly.
    final options =
        File('/data/local/tmp/picakeep-native-022/normal-ui-options.json');
    final values = jsonDecode(await options.readAsString());
    if (values is! Map) {
      throw const FormatException('Invalid normal UI options');
    }
    args =
        values.entries.map((entry) => '--${entry.key}=${entry.value}').toList();
  }
  final work = _option(args, '--work');
  final sources = _option(args, '--sources');
  if (work == null || sources == null || !p.isAbsolute(sources)) {
    throw ArgumentError(
        'Explicit --work=<absolute normal-ui-022-* task> and --sources=<anonymous source directory> are required');
  }
  final storage = await ImagePipelineTaskStorage.prepare(work);
  await IOOverrides.runZoned(
      () => _runTask(storage, sources,
          prepareOnly: _option(args, '--prepare-only') == 'true'),
      getSystemTempDirectory: () => Directory(storage.temporary));
}

Future<void> _runTask(ImagePipelineTaskStorage storage, String sources,
    {required bool prepareOnly}) async {
  // Bindings and runApp must share the zone that scopes Dart temporary files.
  WidgetsFlutterBinding.ensureInitialized();
  final store = await TaskSharedPreferencesStore.open(storage);
  PathProviderPlatform.instance = TaskPathProvider(storage);
  SharedPreferencesStorePlatform.instance = store;
  // No getInstance call has occurred: a cached/default OS store is a startup error.
  SharedPreferences.setPrefix(_preferencePrefix);
  await _seedTask(storage, sources, store);
  final preferences = await SharedPreferences.getInstance();
  await _validateTaskSettings(storage, preferences);
  if (prepareOnly) {
    stdout.writeln('PICAKEEP_022_NORMAL_UI_PREPARED ${jsonEncode({
          'taskRoot': storage.root,
          'preferences': storage.preferences,
          'serverConfig':
              p.join(storage.support, PicaKeepServerConfig.defaultFileName),
          'uiStarted': false,
          'accountsSeeded': false,
        })}');
    return;
  }
  await App.init(
      dataPathOverride: storage.support,
      cachePathOverride: storage.cache,
      migrateExistingData: false);
  setManagedDataRootOverride(storage.support);
  setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
  LocalServerRuntime.instance.configPathOverride =
      p.join(storage.support, PicaKeepServerConfig.defaultFileName);

  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSizeBytes = 192 * 1024 * 1024;
  imageCache.maximumSize = 180;
  await appdata.readEssentialData();
  ArchiveRegistry.initDefaults();
  await LogFileService.instance.init();
  BackgroundImagePreparer.instance.activate();
  SingleInstanceCookieJar(p.join(storage.support, 'cookies.db'));
  await ComicSource.init();
  await AiDownloadQueue.instance.load();
  await OnlineDownloadManager.instance.loadQueue();
  ExploreBindings.comicSourceSettingsReader = (index) =>
      index >= 0 && index < appdata.settings.length
          ? appdata.settings[index]
          : '';
  ExploreBindings.install();
  unawaited(loadTagTranslations());
  await loadTranslations();
  if (App.isDesktop) await initWindowManagerIfDesktop();
  stdout.writeln('PICAKEEP_022_NORMAL_UI ${jsonEncode({
        'taskRoot': storage.root,
        'dataRoot': App.dataPath,
        'cacheRoot': App.cachePath,
        'preferences': storage.preferences,
        'preferencePrefix': _preferencePrefix,
        'serverConfig': LocalServerRuntime.instance.configPath,
        'jpegSha256': _jpegDigest,
        'zipSha256': _zipDigest,
        'ui': 'actual PicaKeepApp with native file/share/window plugins',
        'boundary':
            'Task path/preferences adapters; not an OS filesystem sandbox',
        'onlineWarmup':
            'Automatic JM domain probe omitted; online navigation remains real',
      })}');
  runApp(const normal.PicaKeepApp());
  ImagePipelineNormalUiObserver(storage).start();
  if (App.isDesktop) unawaited(showWindowWhenReady());
}

String? _option(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('$name=')) return args[i].substring(name.length + 1);
    if (args[i] == name) {
      if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
        throw ArgumentError('$name requires a value');
      }
      return args[i + 1];
    }
  }
  return null;
}

Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> _copyAnonymous(ImagePipelineTaskStorage storage, File source,
    String destination, String expectedDigest) async {
  if (await _digest(source) != expectedDigest) {
    throw StateError('Anonymous source hash does not match: ${source.path}');
  }
  await storage.checkPath(destination);
  final target = File(destination);
  await target.parent.create(recursive: true);
  if (await target.exists()) {
    if (await _digest(target) != expectedDigest) {
      throw StateError('Existing task input differs; refusing to overwrite it');
    }
    return;
  }
  final part = File('$destination.part');
  await storage.checkPath(part.path);
  try {
    await source.copy(part.path);
    if (await _digest(part) != expectedDigest ||
        await _digest(source) != expectedDigest) {
      throw StateError('Anonymous source changed while copying');
    }
    await part.rename(target.path);
  } finally {
    if (await part.exists()) await part.delete();
  }
}

Future<void> _seedTask(ImagePipelineTaskStorage storage, String sources,
    TaskSharedPreferencesStore store) async {
  await _copyAnonymous(storage, File(p.join(sources, 'page-001.jpg')),
      p.join(storage.library, 'real-jpeg', '1.jpg'), _jpegDigest);
  await _copyAnonymous(storage, File(p.join(sources, 'page-001.jpg')),
      p.join(storage.library, 'real-jpeg', 'cover.jpg'), _jpegDigest);
  await _copyAnonymous(storage, File(p.join(sources, 'archive-001.zip')),
      p.join(storage.library, 'archive-001.zip'), _zipDigest);
  await _seedWorkflowPages(storage);
  final values = await store.getAllWithPrefix(_preferencePrefix);
  final configPath =
      p.join(storage.support, PicaKeepServerConfig.defaultFileName);
  await storage.checkPath(configPath);
  if (values.containsKey('${_preferencePrefix}settings')) {
    if (!await File(configPath).exists()) {
      throw StateError('Seeded task server config is missing');
    }
    return;
  }
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  final settings = List<String>.from(Appdata().settings);
  settings[22] = p.join(storage.support, 'download');
  settings[pixivDownloadDirSettingIndex] =
      p.join(storage.support, 'download_pixiv');
  settings[managedDataSourceModeSettingIndex] =
      managedDataSourceModeCurrentOnly;
  settings[originalDownloadDirSettingIndex] = '';
  settings[localComicPathsSettingIndex] =
      encodeLocalComicPathList([storage.library]);
  settings[localLibraryCollectionShellSettingIndex] =
      encodeLocalCollectionShellPathMap({storage.library: true});
  settings[appRuntimeModeSettingIndex] = appRuntimeModeClient;
  settings[remoteServerAddressSettingIndex] = 'http://127.0.0.1:$port';
  settings[serviceAdminPortSettingIndex] = '$port';
  final config = PicaKeepServerConfig.defaults().copyWith(
      host: '127.0.0.1',
      port: port,
      managedDataRoot: storage.support,
      currentDownloadRoot: settings[22],
      customLibraryRoots: [storage.library],
      customLibraryCollectionShellModes: {storage.library: true},
      consolePassword: 'verification-only-022');
  await storage.checkPath(configPath);
  await PicaKeepServerConfig.save(configPath, config);
  await store.setValue('StringList', '${_preferencePrefix}firstUse',
      List<String>.from(Appdata().firstUse));
  await store.setValue('StringList', '${_preferencePrefix}settings', settings);
  await File(p.join(storage.root, 'seed.json')).writeAsString(
      jsonEncode({
        'version': 1,
        'jpegSha256': _jpegDigest,
        'zipSha256': _zipDigest,
        'loopback': 'http://127.0.0.1:$port',
        'accountsSeeded': false,
        'downloadDatabaseSeeded': false,
        'scope': ImagePipelineTaskStorage.scope,
      }),
      flush: true);
}

Future<void> _seedWorkflowPages(ImagePipelineTaskStorage storage) async {
  final archive = File(p.join(storage.library, 'archive-001.zip'));
  final backend = DartZipBackend();
  final pages = <File>[];
  for (var index = 0; index < _pngDigests.length; index++) {
    final path = p.join(
        storage.library, 'real-workflow', 'chapter-1', '${index + 2}.png');
    await storage.checkPath(path);
    final file = File(path);
    if (!await file.exists()) {
      final part = File('$path.part');
      await storage.checkPath(part.path);
      try {
        await backend.materializeEntry(archive.path, '${index + 1}.png', part,
            maxBytes: 5 * 1024 * 1024);
        if (await _digest(part) != _pngDigests[index] ||
            await _digest(archive) != _zipDigest) {
          throw StateError(
              'Anonymous ZIP member differs during fixture preparation');
        }
        await part.rename(path);
      } finally {
        if (await part.exists()) await part.delete();
      }
    } else if (await _digest(file) != _pngDigests[index]) {
      throw StateError(
          'Existing task member differs; refusing to overwrite it');
    }
    pages.add(file);
  }
  final jpeg = File(p.join(storage.library, 'real-jpeg', '1.jpg'));
  for (final chapter in ['chapter-1', 'chapter-2']) {
    await _copyAnonymous(
        storage,
        jpeg,
        p.join(storage.library, 'real-workflow', chapter, '1.jpg'),
        _jpegDigest);
  }
  // Chapter 2 reverses PNG page identity. Two distinct works also use 1.png,
  // allowing real same-basename favorite/export checks without re-encoding.
  for (var index = 0; index < pages.length; index++) {
    await _copyAnonymous(
        storage,
        pages[1 - index],
        p.join(
            storage.library, 'real-workflow', 'chapter-2', '${index + 2}.png'),
        _pngDigests[1 - index]);
    for (final filename in ['1.png', 'cover.png']) {
      await _copyAnonymous(
          storage,
          pages[index],
          p.join(storage.library, 'same-name-${index + 1}', filename),
          _pngDigests[index]);
    }
  }
  final manifest = File(p.join(storage.root, 'workflow-fixtures.json'));
  await storage.checkPath(manifest.path);
  await manifest.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'jpegSha256': _jpegDigest,
        'zipSha256': _zipDigest,
        'pngSha256': _pngDigests,
        'chapters': {
          'chapter-1': [_jpegDigest, ..._pngDigests],
          'chapter-2': [_jpegDigest, ..._pngDigests.reversed],
        },
        'sameBasenameWorks': {
          'same-name-1/1.png': _pngDigests[0],
          'same-name-2/1.png': _pngDigests[1],
        },
        'boundary':
            'Fixture preparation only; actual UI operations still required',
      }),
      flush: true);
}

Future<void> _validateTaskSettings(
    ImagePipelineTaskStorage storage, SharedPreferences preferences) async {
  await storage.checkPath(p.join(storage.support, 'settings'));
  final settingsFile = File(p.join(storage.support, 'settings'));
  final settings = await settingsFile.exists()
      ? (jsonDecode(await settingsFile.readAsString()) as List).cast<String>()
      : preferences.getStringList('settings')!;
  if (settings.length <= pixivDownloadDirSettingIndex ||
      settings[managedDataSourceModeSettingIndex] !=
          managedDataSourceModeCurrentOnly ||
      settings[originalDownloadDirSettingIndex].isNotEmpty) {
    throw StateError(
        'Verification settings may not include another application data root');
  }
  for (final path in [
    settings[22],
    settings[pixivDownloadDirSettingIndex],
    ...decodeLocalComicPathList(settings[localComicPathsSettingIndex])
  ]) {
    if (path.isEmpty) throw StateError('Task roots must remain explicit');
    await storage.checkPath(path);
  }
  final configPath =
      p.join(storage.support, PicaKeepServerConfig.defaultFileName);
  await storage.checkPath(configPath);
  final config = await PicaKeepServerConfig.load(configPath);
  if (config.host != '127.0.0.1' || config.originalDownloadRoot.isNotEmpty) {
    throw StateError('Verification server must remain loopback/task-only');
  }
  final remote = Uri.tryParse(settings[remoteServerAddressSettingIndex]);
  if (remote == null ||
      remote.scheme != 'http' ||
      remote.host != '127.0.0.1' ||
      remote.port != config.port ||
      remote.userInfo.isNotEmpty) {
    throw StateError(
        'Verification remote address must match its task loopback server');
  }
  for (final path in [
    config.managedDataRoot,
    config.currentDownloadRoot,
    ...config.customLibraryRoots
  ]) {
    if (path.isEmpty) {
      throw StateError('Task server roots must remain explicit');
    }
    await storage.checkPath(path);
  }
}
