import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as web_socket_status;

import '../foundation/archive/archive_errors.dart';
import '../foundation/archive/archive_models.dart';
import '../foundation/archive/archive_reading_service.dart';
import '../foundation/archive/archive_registry.dart';
import '../foundation/app.dart';
import '../foundation/local_trash_store.dart';
import '../foundation/local_library_settings.dart';
import '../foundation/privileged_storage_access.dart';
import '../foundation/trash.dart';
import '../foundation/local_favorites.dart';
import '../foundation/image_favorites.dart';
import 'library_event_bus.dart';
import 'library_trash_store.dart';
import 'local_resource_scanner.dart';
import 'managed_data_root_resolver.dart';
import 'server_config.dart';
import 'server_runtime_state.dart';
import 'web_console/remote_proxy_handler.dart';
import 'web_console/web_auth_handler.dart';
import 'web_console/web_console_handler.dart';
import 'web_console/web_user_store.dart';

part 'server_app_routing.dart';
part 'server_app_browse.dart';
part 'server_app_console.dart';
part 'server_app_trash.dart';
part 'server_app_library.dart';
part 'server_app_favorites.dart';
part 'server_app_files.dart';
part 'server_app_status.dart';
part 'server_app_util.dart';

class PicaKeepAdminServer {
  PicaKeepAdminServer({
    required this.configPath,
    ServerRuntimeState? runtimeState,
  })  : _state = runtimeState ?? ServerRuntimeState(),
        _trashStore = LibraryTrashStore(
          '${App.dataPath}${Platform.pathSeparator}library_trash.json',
        );

  final String configPath;
  final ServerRuntimeState _state;
  final LocalResourceScanner _scanner = LocalResourceScanner();
  final LibraryTrashStore _trashStore;
  final WebConsoleUserStore _webUserStore = WebConsoleUserStore();

  late final WebAuthHandler _authHandler = WebAuthHandler(
    configProvider: () => _config ?? PicaKeepServerConfig.defaults(),
    userStore: _webUserStore,
    jsonResponse: _jsonResponse,
  );

  PicaKeepServerConfig? _config;
  ServerResourceSnapshot? _snapshot;
  HttpServer? _server;
  String? _librarySignature;
  final LibraryEventBus _eventBus = LibraryEventBus();
  final Set<WebSocketChannel> _eventChannels = <WebSocketChannel>{};
  final Map<String, ServerResourceItemSummary> _deepItemCache =
      <String, ServerResourceItemSummary>{};
  final Map<String, Future<ServerResourceItemSummary>> _deepItemInFlight =
      <String, Future<ServerResourceItemSummary>>{};
  final Map<String, String> _coverPathCache = <String, String>{};
  final Map<String, String> _favoriteCoverFallbackCache = <String, String>{};
  final int _maxConcurrentDeepScans = Platform.isAndroid ? 2 : 6;
  int _activeDeepScanCount = 0;
  final List<Completer<void>> _deepScanWaiters = <Completer<void>>[];
  Timer? _pendingLibraryChangedTimer;
  String? _pendingLibraryChangedSignature;
  DateTime? _pendingLibraryChangedGeneratedAt;
  final List<StreamSubscription<FileSystemEvent>> _libraryWatchers =
      <StreamSubscription<FileSystemEvent>>[];
  Timer? _libraryWatchDebounceTimer;
  bool _libraryWatchRescanRunning = false;

  ServerRuntimeState get state => _state;
  PicaKeepServerConfig? get config => _config;
  ServerResourceSnapshot? get snapshot => _snapshot;
  bool get isRunning => _server != null;

  Future<void> serve() async {
    await start();
  }

  Future<void> start({PicaKeepServerConfig? config}) async {
    if (_server != null) {
      return;
    }
    _state.markStarting('正在启动服务');
    try {
      _config = config ?? await PicaKeepServerConfig.load(configPath);
      ArchiveRegistry.initDefaults();
      await reloadManagedDataStoresForServerConfig(_config!);
      await _webUserStore.init(_config!);
      _setSnapshot(await _scanResources(), emitEvent: true);
      final handler = const Pipeline()
          .addMiddleware(_requestMiddleware())
          .addHandler(_handleRequest);
      _server = await shelf_io.serve(
        handler,
        _config!.host,
        _config!.port,
        shared: true,
      );
      final message =
          'Listening on http://${_server!.address.address}:${_server!.port}';
      _restartLibraryWatchers();
      _state.markRunning(message);
      stdout.writeln('[PicaKeepServer] $message');
    } catch (e, s) {
      _server = null;
      _state.markError(e, s);
      rethrow;
    }
  }

  Future<void> stop() async {
    final server = _server;
    if (server == null) {
      _state.markStopped('服务未启动');
      return;
    }
    _state.markStopping('正在停止服务');
    try {
      _pendingLibraryChangedTimer?.cancel();
      _pendingLibraryChangedTimer = null;
      _libraryWatchDebounceTimer?.cancel();
      _libraryWatchDebounceTimer = null;
      await _cancelLibraryWatchers();
      final closeFutures = <Future<void>>[
        for (final channel in _eventChannels.toList())
          channel.sink.close(web_socket_status.normalClosure),
      ];
      _eventChannels.clear();
      if (closeFutures.isNotEmpty) {
        await Future.wait(closeFutures, eagerError: false);
      }
      await _eventBus.close();
      _webUserStore.dispose();
      await server.close(force: true);
      _state.markStopped('服务已停止');
    } catch (e, s) {
      _state.markError(e, s);
      rethrow;
    } finally {
      _server = null;
    }
  }

  Future<ServerResourceSnapshot> rescanResources() async {
    final snapshot = await _scanResources();
    _setSnapshot(snapshot, emitEvent: true);
    _state.addLog('scan', '已重新扫描本地资源');
    return snapshot;
  }

  Future<ServerResourceSnapshot> applyConfig(
    PicaKeepServerConfig newConfig,
  ) async {
    _config = newConfig;
    await reloadManagedDataStoresForServerConfig(newConfig);
    final snapshot = await _scanResources();
    _setSnapshot(snapshot, emitEvent: true);
    _restartLibraryWatchers();
    _state.addLog('config', '已热更新配置 + 重新扫描');
    return snapshot;
  }

  void _restartLibraryWatchers() {
    unawaited(_cancelLibraryWatchers().then((_) async {
      final config = _config;
      if (config == null || _server == null) {
        return;
      }
      final seen = <String>{};
      for (final rawPath in config.allLibraryRoots) {
        final path = rawPath.trim();
        if (path.isEmpty || !seen.add(path)) {
          continue;
        }
        final directory = Directory(path);
        if (!directory.existsSync()) {
          continue;
        }
        try {
          final subscription = directory
              .watch(recursive: true)
              .listen(_handleLibraryFileEvent, onError: (_) {});
          _libraryWatchers.add(subscription);
        } catch (error) {
          _state.addLog('watch', '监听失败：$path ($error)');
        }
      }
      if (_libraryWatchers.isNotEmpty) {
        _state.addLog('watch', '已监听 ${_libraryWatchers.length} 个资源目录');
      }
    }));
  }

  Future<void> _cancelLibraryWatchers() async {
    _libraryWatchDebounceTimer?.cancel();
    _libraryWatchDebounceTimer = null;
    final subscriptions = _libraryWatchers.toList();
    _libraryWatchers.clear();
    if (subscriptions.isEmpty) {
      return;
    }
    await Future.wait(
      subscriptions.map((subscription) => subscription.cancel()),
      eagerError: false,
    );
  }

  void _handleLibraryFileEvent(FileSystemEvent event) {
    if (_server == null) {
      return;
    }
    _libraryWatchDebounceTimer?.cancel();
    _libraryWatchDebounceTimer = Timer(
      const Duration(seconds: 3),
      () => unawaited(_rescanResourcesFromWatch()),
    );
  }

  Future<void> _rescanResourcesFromWatch() async {
    if (_libraryWatchRescanRunning || _server == null) {
      return;
    }
    _libraryWatchRescanRunning = true;
    try {
      await rescanResources();
      _state.addLog('watch', '检测到资源目录变化，已自动刷新');
    } catch (error, stackTrace) {
      _state.addLog('watch', '自动刷新失败：$error');
      _state.markError(error, stackTrace);
    } finally {
      _libraryWatchRescanRunning = false;
    }
  }
}
