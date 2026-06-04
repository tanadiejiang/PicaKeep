import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as web_socket_status;

import '../foundation/local_trash_store.dart';
import '../foundation/privileged_storage_access.dart';
import '../foundation/trash.dart';
import '../foundation/local_favorites.dart';
import '../foundation/image_favorites.dart';
import 'library_event_bus.dart';
import 'library_trash_store.dart';
import 'local_resource_scanner.dart';
import 'server_config.dart';
import 'server_runtime_state.dart';
import 'web_console/remote_proxy_handler.dart';
import 'web_console/web_auth_handler.dart';
import 'web_console/web_console_handler.dart';
import 'web_console/web_user_store.dart';

class PicaKeepAdminServer {
  PicaKeepAdminServer({
    required this.configPath,
    ServerRuntimeState? runtimeState,
  })  : _state = runtimeState ?? ServerRuntimeState(),
        _trashStore = LibraryTrashStore(
          '${File(configPath).parent.path}${Platform.pathSeparator}library_trash.json',
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
      final closeFutures = <Future<void>>[
        for (final channel in _eventChannels.toList())
          channel.sink.close(web_socket_status.goingAway),
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
    final snapshot = await _scanResources();
    _setSnapshot(snapshot, emitEvent: true);
    _state.addLog('config', '已热更新配置 + 重新扫描');
    return snapshot;
  }

  Future<LibraryTrashEntry> restoreTrashItem(String trashId) async {
    final restored = await _trashStore.restoreItem(trashId);
    await rescanResources();
    _state.addLog('trash', '已恢复 ${restored.title}');
    return restored;
  }

  Future<LibraryTrashEntry?> purgeTrashItem(String trashId) async {
    final deleted = await _trashStore.purgeItem(trashId);
    if (deleted == null) {
      return null;
    }
    await rescanResources();
    _state.addLog('trash', '已彻底删除 ${deleted.title}');
    return deleted;
  }

  Future<Map<String, dynamic>> batchRestoreTrashItems(
    Iterable<String> trashIds,
  ) async {
    final ids = _normalizedIdList(trashIds);
    final succeeded = <String>[];
    final failed = <Map<String, String>>[];
    for (final trashId in ids) {
      try {
        if (_isServerTrashId(trashId)) {
          await _trashStore.restoreItem(trashId);
        } else {
          final record = await LocalTrashStore.instance.find(trashId);
          if (record == null || !_shouldExposeLocalTrashRecord(record)) {
            throw StateError('trash item not found');
          }
          await TrashManager.instance.restoreLocalItem(trashId);
        }
        succeeded.add(trashId);
      } catch (e) {
        failed.add({'id': trashId, 'error': e.toString()});
      }
    }
    if (succeeded.isNotEmpty) {
      await rescanResources();
      _state.addLog('trash', '批量恢复 ${succeeded.length} 项');
    }
    return _buildBatchResult(ids, succeeded, failed);
  }

  Future<Map<String, dynamic>> batchPurgeTrashItems(
    Iterable<String> trashIds,
  ) async {
    final ids = _normalizedIdList(trashIds);
    final succeeded = <String>[];
    final failed = <Map<String, String>>[];
    for (final trashId in ids) {
      try {
        if (_isServerTrashId(trashId)) {
          final deleted = await _trashStore.purgeItem(trashId);
          if (deleted == null) {
            throw StateError('trash item not found');
          }
        } else {
          final record = await LocalTrashStore.instance.find(trashId);
          if (record == null || !_shouldExposeLocalTrashRecord(record)) {
            throw StateError('trash item not found');
          }
          await TrashManager.instance.permanentlyDeleteTrashItem(trashId);
        }
        succeeded.add(trashId);
      } catch (e) {
        failed.add({'id': trashId, 'error': e.toString()});
      }
    }
    if (succeeded.isNotEmpty) {
      await rescanResources();
      _state.addLog('trash', '批量彻底删除 ${succeeded.length} 项');
    }
    return _buildBatchResult(ids, succeeded, failed);
  }

  Future<Map<String, dynamic>> batchTrashItems(Iterable<String> itemIds) async {
    final ids = _normalizedIdList(itemIds);
    final snapshot = await _currentSnapshot();
    final succeeded = <String>[];
    final failed = <Map<String, String>>[];
    for (final itemId in ids) {
      try {
        final item = snapshot.findItemById(itemId);
        if (item == null) {
          throw StateError('item not found');
        }
        final rootPath = _rootPathForRootId(item.rootId);
        if (rootPath == null || rootPath.trim().isEmpty) {
          throw StateError('root path not found');
        }
        await _trashStore.moveItemToTrash(item: item, rootPath: rootPath);
        await _deleteManagedDownloadDbRow(item);
        succeeded.add(itemId);
      } catch (e) {
        failed.add({'id': itemId, 'error': e.toString()});
      }
    }
    if (succeeded.isNotEmpty) {
      await rescanResources();
      _state.addLog('trash', '批量移入回收站 ${succeeded.length} 项');
    }
    return _buildBatchResult(ids, succeeded, failed);
  }

  Future<Map<String, dynamic>> batchDeleteItemsPermanently(
    Iterable<String> itemIds,
  ) async {
    final ids = _normalizedIdList(itemIds);
    final snapshot = await _currentSnapshot();
    final succeeded = <String>[];
    final failed = <Map<String, String>>[];
    for (final itemId in ids) {
      try {
        final item = snapshot.findItemById(itemId);
        if (item == null) {
          throw StateError('item not found');
        }
        final dir = Directory(item.path);
        if (dir.existsSync()) {
          await dir.delete(recursive: true);
        }
        await _deleteManagedDownloadDbRow(item);
        succeeded.add(itemId);
      } catch (e) {
        failed.add({'id': itemId, 'error': e.toString()});
      }
    }
    if (succeeded.isNotEmpty) {
      await rescanResources();
      _state.addLog('trash', '批量直接删除 ${succeeded.length} 项');
    }
    return _buildBatchResult(ids, succeeded, failed);
  }

  List<String> _normalizedIdList(Iterable<String> ids) {
    final result = <String>[];
    final seen = <String>{};
    for (final id in ids) {
      final normalized = id.trim();
      if (normalized.isEmpty || !seen.add(normalized)) {
        continue;
      }
      result.add(normalized);
    }
    return result;
  }

  Map<String, dynamic> _buildBatchResult(
    List<String> requested,
    List<String> succeeded,
    List<Map<String, String>> failed,
  ) {
    return {
      'ok': failed.isEmpty,
      'requested': requested.length,
      'succeeded': succeeded.length,
      'succeededIds': succeeded,
      'failed': failed,
    };
  }

  bool _isServerTrashId(String trashId) =>
      trashId.trim().startsWith('srvtrash_');

  String _normalizePath(String path) {
    final normalized = path.trim().replaceAll('\\', '/');
    if (normalized.isEmpty) {
      return '';
    }
    final collapsed = normalized.replaceAll(RegExp(r'/+'), '/');
    final trimmed = collapsed.replaceFirst(RegExp(r'/+$'), '');
    return trimmed.toLowerCase();
  }

  bool _isPathInsideRoot(String path, String rootPath) {
    final normalizedPath = _normalizePath(path);
    final normalizedRoot = _normalizePath(rootPath);
    if (normalizedPath.isEmpty || normalizedRoot.isEmpty) {
      return false;
    }
    return normalizedPath == normalizedRoot ||
        normalizedPath.startsWith('$normalizedRoot/');
  }

  bool _isManagedRootId(String rootId) =>
      rootId == 'current_download' || rootId == 'original_download';

  String? _managedRootPathForRootId(String rootId) {
    final currentConfig = _config;
    if (currentConfig == null) {
      return null;
    }
    return switch (rootId) {
      'current_download' => currentConfig.currentDownloadRoot.trim(),
      'original_download' => currentConfig.originalDownloadRoot.trim(),
      _ => null,
    };
  }

  String _relativeManagedDirectoryPath(String rootPath, String directoryPath) {
    final normalizedRoot = _normalizePath(rootPath);
    final normalizedDirectory = _normalizePath(directoryPath);
    if (normalizedRoot.isEmpty || normalizedDirectory.isEmpty) {
      return '';
    }
    if (normalizedDirectory == normalizedRoot) {
      return '';
    }
    final prefix = '$normalizedRoot/';
    if (!normalizedDirectory.startsWith(prefix)) {
      return '';
    }
    return normalizedDirectory.substring(prefix.length);
  }

  bool _shouldExposeLocalTrashRecord(LocalTrashRecordData record) {
    final currentConfig = _config;
    if (currentConfig == null) {
      return false;
    }
    final originalPath = record.originalPath.trim();
    final trashedPath = record.trashedPath.trim();
    if (originalPath.isEmpty || trashedPath.isEmpty) {
      return false;
    }
    if (!FileSystemEntity.isDirectorySync(trashedPath)) {
      return false;
    }
    return currentConfig.allLibraryRoots
        .any((root) => _isPathInsideRoot(originalPath, root));
  }

  Future<List<Map<String, dynamic>>> _buildCombinedTrashItemsPayload() async {
    final serverEntries = await _trashStore.listEntries();
    final localEntries = (await LocalTrashStore.instance.listTrashed())
        .where(_shouldExposeLocalTrashRecord)
        .toList(growable: false);
    final combined = <({int deletedAtMillis, Map<String, dynamic> payload})>[
      for (final entry in serverEntries)
        (
          deletedAtMillis: entry.deletedAt.millisecondsSinceEpoch,
          payload: _buildTrashItemPayload(entry),
        ),
      for (final record in localEntries)
        (
          deletedAtMillis: record.deletedAtMillis,
          payload: _buildLocalTrashItemPayload(record),
        ),
    ];
    combined.sort((a, b) => b.deletedAtMillis.compareTo(a.deletedAtMillis));
    return combined.map((entry) => entry.payload).toList(growable: false);
  }

  Map<String, dynamic> _buildLocalTrashItemPayload(
      LocalTrashRecordData record) {
    final encodedId = Uri.encodeComponent(record.id);
    return {
      'id': record.id,
      'itemId': record.itemId,
      'rootId': record.rootId,
      'itemKind': record.itemKind,
      'title': record.title,
      'subtitle': record.subtitle,
      'sourceDisplayName': record.sourceLabel,
      'originalPath': record.originalPath,
      'trashedPath': record.trashedPath,
      'deletedAt': DateTime.fromMillisecondsSinceEpoch(record.deletedAtMillis)
          .toIso8601String(),
      'sizeBytes': record.sizeBytes,
      'coverUrl': '/api/library/trash/$encodedId/cover',
      'source': 'local',
    };
  }

  Future<File?> _trashCoverFileForId(String trashId) async {
    if (_isServerTrashId(trashId)) {
      final entry = await _trashStore.findById(trashId);
      if (entry == null) {
        return null;
      }
      final coverFile = _trashStore.coverFileFor(entry);
      return coverFile.path.trim().isEmpty ? null : coverFile;
    }
    final record = await LocalTrashStore.instance.find(trashId);
    if (record == null) {
      return null;
    }
    final coverPath = resolveLocalTrashCoverPath(
      trashedPath: record.trashedPath,
      coverRelativePath: record.coverRelativePath,
      cover: record.cover,
    );
    if (coverPath.trim().isEmpty) {
      return null;
    }
    final file = File(coverPath);
    return file.existsSync() ? file : null;
  }

  Future<void> _deleteManagedDownloadDbRow(
      ServerResourceItemSummary item) async {
    if (!_isManagedRootId(item.rootId)) {
      return;
    }
    final rootPath = _managedRootPathForRootId(item.rootId);
    if (rootPath == null || rootPath.isEmpty) {
      return;
    }
    final dbFile = File('$rootPath${Platform.pathSeparator}download.db');
    if (!dbFile.existsSync()) {
      return;
    }
    final relativeDirectory =
        _relativeManagedDirectoryPath(rootPath, item.path);
    Database? db;
    try {
      db = sqlite3.open(dbFile.path);
      var deletedAny = false;
      if (relativeDirectory.isNotEmpty) {
        deletedAny = db.select(
          'select 1 from download where directory = ? limit 1',
          [relativeDirectory],
        ).isNotEmpty;
        if (deletedAny) {
          db.execute(
              'delete from download where directory = ?', [relativeDirectory]);
        }
      }
      if (!deletedAny) {
        deletedAny = db.select(
          'select 1 from download where directory = ? limit 1',
          [item.path],
        ).isNotEmpty;
        if (deletedAny) {
          db.execute('delete from download where directory = ?', [item.path]);
        }
      }
      if (!deletedAny) {
        db.execute('delete from download where id = ?', [item.id]);
      }
    } catch (e, s) {
      _state.addLog('trash', '同步清理 download.db 行失败: $e');
      _state.addLog('trash', s.toString());
    } finally {
      db?.dispose();
    }
  }

  Middleware _requestMiddleware() {
    return (innerHandler) {
      return (request) async {
        _state.beginRequest(request.method, request.requestedUri.path);
        try {
          if ((_config?.logRequests ?? false) == true) {
            stdout.writeln(
              '[PicaKeepServer] ${request.method} ${request.requestedUri}',
            );
          }
          if (request.method == 'OPTIONS') {
            return _withCors(Response(204));
          }
          final response = await innerHandler(request);
          return _withCors(response);
        } finally {
          _state.endRequest();
        }
      };
    };
  }

  Response _withCors(Response response) {
    return response.change(headers: {
      'access-control-allow-origin': '*',
      'access-control-allow-methods': 'GET, POST, PUT, DELETE, OPTIONS',
      'access-control-allow-headers': 'Authorization, Content-Type, Range',
      'access-control-expose-headers':
          'Content-Range, Accept-Ranges, Content-Length',
    });
  }

  bool _requiresAuthorization(String path) {
    if (path.isEmpty || path == 'status' || path == 'api/console/login') {
      return false;
    }
    if (!path.startsWith('api/')) {
      return false;
    }
    return true;
  }

  Future<Response> _handleRequest(Request request) async {
    final path = request.url.path;

    final loginResponse = await _authHandler.handleLogin(request);
    if (loginResponse != null) {
      return loginResponse;
    }

    if (_requiresAuthorization(path) && !_authHandler.isAuthorized(request)) {
      return _jsonResponse({'error': 'unauthorized'}, statusCode: 401);
    }

    final remoteProxyResponse = await handleRemoteProxyRequest(
      request,
      state: _state,
      jsonResponse: _jsonResponse,
    );
    if (remoteProxyResponse != null) {
      return remoteProxyResponse;
    }

    final consoleResponse = await _handleConsoleRequest(request);
    if (consoleResponse != null) {
      return consoleResponse;
    }

    final historyResponse = await _handleWebHistoryRequest(request);
    if (historyResponse != null) {
      return historyResponse;
    }

    final trashResponse = await _handleTrashRequest(request);
    if (trashResponse != null) {
      return trashResponse;
    }

    final favoritesResponse = await _handleFavoritesRequest(request);
    if (favoritesResponse != null) {
      return favoritesResponse;
    }

    final imageFavoritesResponse = await _handleImageFavoritesRequest(request);
    if (imageFavoritesResponse != null) {
      return imageFavoritesResponse;
    }

    final libraryResponse = await _handleLibraryRequest(request);
    if (libraryResponse != null) {
      return libraryResponse;
    }

    if (path == 'status') {
      return _jsonResponse(buildStatusPayload());
    }
    if (path == 'api/admin/status') {
      return _jsonResponse(buildStatusPayload());
    }
    if (path == 'api/events') {
      return webSocketHandler(_handleEventSocket)(request);
    }
    if (path == 'api/admin/summary') {
      return _jsonResponse(buildSummaryPayload());
    }
    if (path == 'api/admin/resources') {
      return _jsonResponse((_snapshot ?? await _scanResources()).toJson());
    }
    if (path == 'api/admin/config') {
      if (request.method == 'GET') {
        return _jsonResponse(
            (_config ?? PicaKeepServerConfig.defaults()).toJson());
      }
      if (request.method == 'PUT') {
        final body = await request.readAsString();
        final payload = jsonDecode(body);
        if (payload is! Map) {
          return _jsonResponse({'error': 'invalid payload'}, statusCode: 400);
        }
        final nextConfig = PicaKeepServerConfig.fromJson(
          payload.map((k, v) => MapEntry(k.toString(), v)),
        );
        _config = nextConfig;
        await PicaKeepServerConfig.save(configPath, _config!);
        await _webUserStore.ensureAdmin(_config!.consolePassword);
        _setSnapshot(await _scanResources(), emitEvent: true);
        _state.addLog('config', '配置已更新');
        return _jsonResponse({
          'ok': true,
          'message': '配置已保存，host/port 改动重启后完全生效',
          'config': _config!.toJson(),
        });
      }
    }
    if (path == 'api/admin/logs') {
      return _jsonResponse({
        'logs': _state.recentLogs(),
      });
    }
    if (path == 'api/admin/scan' && request.method == 'POST') {
      final snapshot = await rescanResources();
      return _jsonResponse({
        'ok': true,
        'snapshot': snapshot.toJson(),
      });
    }

    final webConsoleResponse = await handleWebConsoleRequest(request);
    if (webConsoleResponse != null) {
      return webConsoleResponse;
    }

    return _jsonResponse({'error': 'not found'}, statusCode: 404);
  }

  Future<Response?> _handleConsoleRequest(Request request) async {
    final segments = request.url.pathSegments;
    if (segments.length < 3 ||
        segments[0] != 'api' ||
        segments[1] != 'console') {
      return null;
    }
    final user = _authHandler.currentUser(request);
    if (user == null) {
      return _jsonResponse({'error': 'unauthorized'}, statusCode: 401);
    }
    final action = segments[2];
    if (segments.length == 3 && action == 'me') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _jsonResponse({
        'ok': true,
        'user': user.toJson(),
        'emptyPassword': user.isAdmin &&
            (_config ?? PicaKeepServerConfig.defaults())
                .consolePassword
                .trim()
                .isEmpty,
      });
    }
    if (segments.length == 3 && action == 'logout') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _jsonResponse({'ok': true});
    }
    if (segments.length == 3 && action == 'change-password') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final payload = await _readJsonMapFromBody(request);
      final oldPassword = payload['oldPassword']?.toString() ?? '';
      final newPassword = payload['newPassword']?.toString() ?? '';
      if (!user.isAdmin && newPassword.isEmpty) {
        return _jsonResponse(
          {'error': 'empty password is not allowed'},
          statusCode: 400,
        );
      }
      if (_webUserStore.verifyLogin(user.username, oldPassword) == null) {
        return _jsonResponse({'error': 'old password mismatch'}, statusCode: 403);
      }
      final updated = _webUserStore.resetPassword(
        userId: user.id,
        password: newPassword,
        allowEmptyPassword: user.isAdmin,
      );
      if (updated.isAdmin) {
        _config = (_config ?? PicaKeepServerConfig.defaults())
            .copyWith(consolePassword: newPassword);
        await PicaKeepServerConfig.save(configPath, _config!);
      }
      return _jsonResponse({
        'ok': true,
        'token': _authHandler.tokenForUser(updated),
        'user': updated.toJson(),
        'emptyPassword': updated.isAdmin && newPassword.trim().isEmpty,
      });
    }
    if (segments.length == 3 && action == 'users') {
      if (!user.isAdmin) {
        return _jsonResponse({'error': 'forbidden'}, statusCode: 403);
      }
      if (request.method == 'GET') {
        return _jsonResponse({
          'users': _webUserStore
              .listUsers()
              .map((entry) => entry.toJson())
              .toList(),
        });
      }
      if (request.method == 'POST') {
        final payload = await _readJsonMapFromBody(request);
        final username = payload['username']?.toString() ?? '';
        final password = payload['password']?.toString() ?? '';
        final role =
            payload['role']?.toString() ?? WebConsoleUserStore.userRole;
        try {
          final created = _webUserStore.createUser(
            username: username,
            password: password,
            role: role,
          );
          return _jsonResponse({'ok': true, 'user': created.toJson()});
        } on WebConsoleStoreException catch (e) {
          return _jsonResponse({'error': e.message}, statusCode: 400);
        }
      }
      return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
    }
    if (segments.length == 4 && action == 'users') {
      if (!user.isAdmin) {
        return _jsonResponse({'error': 'forbidden'}, statusCode: 403);
      }
      final targetUserId = int.tryParse(segments[3]);
      if (targetUserId == null) {
        return _jsonResponse({'error': 'invalid user'}, statusCode: 400);
      }
      if (request.method == 'DELETE') {
        try {
          _webUserStore.deleteUser(targetUserId);
          return _jsonResponse({'ok': true});
        } on WebConsoleStoreException catch (e) {
          return _jsonResponse({'error': e.message}, statusCode: 400);
        }
      }
      return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
    }
    if (segments.length == 5 &&
        action == 'users' &&
        segments[4] == 'reset-password') {
      if (!user.isAdmin) {
        return _jsonResponse({'error': 'forbidden'}, statusCode: 403);
      }
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final targetUserId = int.tryParse(segments[3]);
      if (targetUserId == null) {
        return _jsonResponse({'error': 'invalid user'}, statusCode: 400);
      }
      final payload = await _readJsonMapFromBody(request);
      final password = payload['password']?.toString() ?? '';
      final targetUser = _webUserStore.findUserById(targetUserId);
      if (targetUser == null) {
        return _jsonResponse({'error': 'user not found'}, statusCode: 404);
      }
      try {
        final updated = _webUserStore.resetPassword(
          userId: targetUserId,
          password: password,
          allowEmptyPassword: targetUser.isAdmin,
        );
        if (updated.isAdmin) {
          _config = (_config ?? PicaKeepServerConfig.defaults())
              .copyWith(consolePassword: password);
          await PicaKeepServerConfig.save(configPath, _config!);
        }
        return _jsonResponse({'ok': true, 'user': updated.toJson()});
      } on WebConsoleStoreException catch (e) {
        return _jsonResponse({'error': e.message}, statusCode: 400);
      }
    }
    return _jsonResponse({'error': 'not found'}, statusCode: 404);
  }

  Future<Response?> _handleWebHistoryRequest(Request request) async {
    final segments = request.url.pathSegments;
    if (segments.length != 3 ||
        segments[0] != 'api' ||
        segments[1] != 'library' ||
        segments[2] != 'history') {
      return null;
    }
    final user = _authHandler.currentUser(request);
    if (user == null) {
      return _jsonResponse({'error': 'unauthorized'}, statusCode: 401);
    }
    if (request.method == 'GET') {
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 50;
      return _jsonResponse({
        'items': _webUserStore
            .listHistory(user.id, limit: limit)
            .map((entry) => entry.toJson())
            .toList(),
      });
    }
    if (request.method == 'POST') {
      final payload = await _readJsonMapFromBody(request);
      final target = payload['target']?.toString().trim() ?? '';
      if (!_isValidHistoryTarget(target)) {
        return _jsonResponse({'error': 'invalid target'}, statusCode: 400);
      }
      final entry = _webUserStore.upsertHistory(
        userId: user.id,
        target: target,
        title: payload['title']?.toString() ?? '',
        cover: (payload['cover'] ?? payload['coverUrl'])?.toString() ?? '',
        ep: _readIntValue(payload['ep']) ??
            _readIntValue(payload['episode']) ??
            0,
        page: _readIntValue(payload['page']) ?? 0,
        maxPage: _readIntValue(payload['maxPage']) ??
            _readIntValue(payload['max_page']),
        readEpisode: _readIntSetValue(payload['readEpisode']),
      );
      return _jsonResponse({'ok': true, 'item': entry.toJson()});
    }
    if (request.method == 'DELETE') {
      final payload = await _readJsonMapFromBody(request);
      final target = (request.url.queryParameters['target'] ??
              payload['target']?.toString() ??
              '')
          .trim();
      if (target.isNotEmpty && !_isValidHistoryTarget(target)) {
        return _jsonResponse({'error': 'invalid target'}, statusCode: 400);
      }
      _webUserStore.deleteHistory(userId: user.id, target: target);
      return _jsonResponse({'ok': true});
    }
    return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
  }

  bool _isValidHistoryTarget(String target) {
    if (target.isEmpty || target.length > 512) {
      return false;
    }
    if (target.codeUnits.contains(0) || target.contains('..')) {
      return false;
    }
    return true;
  }

  Future<Response?> _handleTrashRequest(Request request) async {
    final segments = request.url.pathSegments;
    if (segments.length < 3 ||
        segments[0] != 'api' ||
        segments[1] != 'library' ||
        segments[2] != 'trash') {
      return null;
    }

    if (segments.length == 3) {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _jsonResponse({
        'items': await _buildCombinedTrashItemsPayload(),
      });
    }

    if (segments.length == 4 && segments[3] == 'batch-restore') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final ids = await _readStringListFromBody(request, 'trashIds');
      return _jsonResponse(await batchRestoreTrashItems(ids));
    }

    if (segments.length == 4 && segments[3] == 'batch-purge') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final ids = await _readStringListFromBody(request, 'trashIds');
      return _jsonResponse(await batchPurgeTrashItems(ids));
    }

    // request.url.pathSegments is already percent-decoded by Uri; calling
    // Uri.decodeComponent on it again is a double-decode that throws
    // "Illegal percent encoding" on multi-byte characters (e.g. CJK folder
    // names like "%E4%B8%AD..."). Use the segment as-is.
    final trashId = segments[3];

    if (segments.length == 5 && segments[4] == 'cover') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final coverFile = await _trashCoverFileForId(trashId);
      if (coverFile == null || coverFile.path.trim().isEmpty) {
        return _jsonResponse({'error': 'cover not found'}, statusCode: 404);
      }
      return _fileResponse(request, coverFile.path);
    }

    if (segments.length == 5 && segments[4] == 'restore') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      if (_isServerTrashId(trashId)) {
        final restored = await restoreTrashItem(trashId);
        return _jsonResponse({
          'ok': true,
          'item': _buildTrashItemPayload(restored),
        });
      }
      final record = await LocalTrashStore.instance.find(trashId);
      if (record == null || !_shouldExposeLocalTrashRecord(record)) {
        return _jsonResponse({'error': 'trash item not found'},
            statusCode: 404);
      }
      await TrashManager.instance.restoreLocalItem(trashId);
      await rescanResources();
      return _jsonResponse({'ok': true});
    }

    if (segments.length == 4 && request.method == 'DELETE') {
      if (_isServerTrashId(trashId)) {
        final deleted = await purgeTrashItem(trashId);
        if (deleted == null) {
          return _jsonResponse({'error': 'trash item not found'},
              statusCode: 404);
        }
        return _jsonResponse({'ok': true});
      }
      final record = await LocalTrashStore.instance.find(trashId);
      if (record == null || !_shouldExposeLocalTrashRecord(record)) {
        return _jsonResponse({'error': 'trash item not found'},
            statusCode: 404);
      }
      await TrashManager.instance.permanentlyDeleteTrashItem(trashId);
      await rescanResources();
      return _jsonResponse({'ok': true});
    }

    return _jsonResponse({'error': 'not found'}, statusCode: 404);
  }

  Future<Response?> _handleLibraryRequest(Request request) async {
    final segments = request.url.pathSegments;
    if (segments.length < 3 ||
        segments[0] != 'api' ||
        segments[1] != 'library' ||
        segments[2] != 'items') {
      return null;
    }

    final snapshot = await _currentSnapshot();
    if (segments.length == 3) {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _jsonResponse({
        'generatedAt': snapshot.generatedAt.toIso8601String(),
        'librarySignature': _librarySignature ?? '',
        'totalComicCount': snapshot.totalComicCount,
        'totalBytes': snapshot.totalBytes,
        'roots': snapshot.roots
            .map((root) => _buildLibraryRootPayload(root, snapshot.items))
            .toList(),
        'items': snapshot.items.map(_buildLibraryItemPayload).toList(),
      });
    }

    if (segments.length == 4 && segments[3] == 'refresh') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final refreshed = await rescanResources();
      return _jsonResponse({
        'ok': true,
        'generatedAt': refreshed.generatedAt.toIso8601String(),
        'librarySignature': _librarySignature ?? '',
        'totalComicCount': refreshed.totalComicCount,
        'totalBytes': refreshed.totalBytes,
        'roots': refreshed.roots
            .map((root) => _buildLibraryRootPayload(root, refreshed.items))
            .toList(),
        'items': refreshed.items.map(_buildLibraryItemPayload).toList(),
      });
    }

    if (segments.length == 4 && segments[3] == 'batch-trash') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final ids = await _readStringListFromBody(request, 'itemIds');
      return _jsonResponse(await batchTrashItems(ids));
    }

    if (segments.length == 4 && segments[3] == 'batch-delete') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final ids = await _readStringListFromBody(request, 'itemIds');
      return _jsonResponse(await batchDeleteItemsPermanently(ids));
    }

    final itemId = segments[3];
    final item = snapshot.findItemById(itemId);
    if (item == null) {
      return _jsonResponse({'error': 'item not found'}, statusCode: 404);
    }
    final rootPath = _rootPathForRootId(item.rootId);

    if (segments.length == 5 && segments[4] == 'trash') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final rootPath = _rootPathForRootId(item.rootId);
      if (rootPath == null || rootPath.trim().isEmpty) {
        return _jsonResponse({'error': 'root path not found'}, statusCode: 404);
      }
      final entry =
          await _trashStore.moveItemToTrash(item: item, rootPath: rootPath);
      await _deleteManagedDownloadDbRow(item);
      await rescanResources();
      _state.addLog('trash', '已移入回收站 ${item.title}');
      return _jsonResponse({
        'ok': true,
        'item': _buildTrashItemPayload(entry),
      });
    }

    if (segments.length == 5 && segments[4] == 'recommendations') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final limit = _clampIntQuery(request.url.queryParameters['limit'], 10, 1, 30);
      return _jsonResponse(_buildLibraryRecommendationsPayload(
        snapshot,
        item,
        limit: limit,
      ));
    }

    if (segments.length == 4 && request.method == 'DELETE') {
      final dir = Directory(item.path);
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
      await _deleteManagedDownloadDbRow(item);
      await rescanResources();
      _state.addLog('trash', '已直接删除 ${item.title}');
      return _jsonResponse({'ok': true});
    }

    if (segments.length == 4) {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final deepItem = await _ensureDeepItem(item, rootPath: rootPath);
      return _jsonResponse(
          _buildLibraryItemPayload(deepItem, includePages: true));
    }

    if (segments.length == 5 && segments[4] == 'cover') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final cachedCoverPath = _coverPathCache[item.id]?.trim() ?? '';
      if (cachedCoverPath.isNotEmpty) {
        final cached = await _fileResponse(request, cachedCoverPath);
        if (cached.statusCode != 404) {
          return cached;
        }
        _coverPathCache.remove(item.id);
      }
      final coverPath = await _scanner.resolveCoverPathOnly(
        item,
        rootPath: rootPath,
      );
      if (coverPath.isEmpty) {
        return _jsonResponse({'error': 'cover not found'}, statusCode: 404);
      }
      _coverPathCache[item.id] = coverPath;
      return _fileResponse(request, coverPath);
    }

    if (segments.length == 6 && segments[4] == 'episodes') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final episodeIndex = int.tryParse(segments[5]);
      if (episodeIndex == null) {
        return _jsonResponse({'error': 'invalid episode'}, statusCode: 400);
      }
      final deepItem = await _ensureDeepItem(item, rootPath: rootPath);
      final episode = _findEpisode(deepItem, episodeIndex);
      if (episode == null) {
        return _jsonResponse({'error': 'episode not found'}, statusCode: 404);
      }
      return _jsonResponse(
        _buildLibraryEpisodePayload(deepItem.id, episode, includePages: true),
      );
    }

    if (segments.length == 7 && segments[4] == 'images') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final episodeIndex = int.tryParse(segments[5]);
      final pageIndex = int.tryParse(segments[6]);
      if (episodeIndex == null || pageIndex == null) {
        return _jsonResponse({'error': 'invalid image target'},
            statusCode: 400);
      }
      final deepItem = await _ensureDeepItem(item, rootPath: rootPath);
      final episode = _findEpisode(deepItem, episodeIndex);
      if (episode == null) {
        return _jsonResponse({'error': 'episode not found'}, statusCode: 404);
      }
      if (pageIndex < 0 || pageIndex >= episode.imagePaths.length) {
        return _jsonResponse({'error': 'page not found'}, statusCode: 404);
      }
      return _fileResponse(request, episode.imagePaths[pageIndex]);
    }

    return _jsonResponse({'error': 'not found'}, statusCode: 404);
  }

  Future<Response?> _handleFavoritesRequest(Request request) async {
    final segments = request.url.pathSegments;
    if (segments.length < 3 ||
        segments[0] != 'api' ||
        segments[1] != 'library' ||
        segments[2] != 'favorites') {
      return null;
    }

    // LocalFavoritesManager is a singleton that is initialized once during
    // app startup (main.dart). Calling init() here per request would re-open
    // the SQLite db, dispose the previous handle (potentially breaking
    // concurrent UI reads), and add latency that can push small clients past
    // their request timeouts — manifesting as "远程加载失败" on the client.
    final favorites = LocalFavoritesManager();

    if (segments.length == 3) {
      if (request.method == 'GET') {
        return _jsonResponse({
          'folders': [
            for (final folder in favorites.folderNames)
              {
                'name': folder,
                'count': favorites.count(folder),
              },
          ],
        });
      }
      if (request.method == 'POST') {
        final payload = await _readJsonMapFromBody(request);
        final name = payload['name']?.toString().trim() ?? '';
        if (name.isEmpty) {
          return _jsonResponse({'error': 'invalid folder name'},
              statusCode: 400);
        }
        favorites.createFolder(name);
        _state.addLog('favorites', '已新建收藏夹 $name');
        _notifyLibraryChanged();
        return _jsonResponse({'ok': true, 'name': name});
      }
      return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
    }

    final folder = segments[3];

    if (segments.length == 4) {
      if (request.method == 'GET') {
        final snapshot = await _currentSnapshot();
        return _jsonResponse({
          'folder': folder,
          'items': favorites
              .getAllComics(folder)
              .map((item) => _buildFavoriteItemPayload(
                    folder,
                    item,
                    matched: _resolveFavoriteResourceItem(snapshot, item),
                  ))
              .toList(growable: false),
        });
      }
      if (request.method == 'POST') {
        final payload = await _readJsonMapFromBody(request);
        final item = _favoriteItemFromPayload(payload);
        favorites.addComic(folder, item);
        _state.addLog('favorites', '已添加收藏 ${item.name} -> $folder');
        _notifyLibraryChanged();
        return _jsonResponse({'ok': true});
      }
      if (request.method == 'PUT') {
        final payload = await _readJsonMapFromBody(request);
        final newName = payload['newName']?.toString().trim() ?? '';
        if (newName.isEmpty) {
          return _jsonResponse({'error': 'invalid folder name'},
              statusCode: 400);
        }
        favorites.rename(folder, newName);
        _state.addLog('favorites', '已重命名收藏夹 $folder -> $newName');
        _notifyLibraryChanged();
        return _jsonResponse({'ok': true, 'name': newName});
      }
      if (request.method == 'DELETE') {
        favorites.deleteFolder(folder);
        _state.addLog('favorites', '已删除收藏夹 $folder');
        _notifyLibraryChanged();
        return _jsonResponse({'ok': true});
      }
      return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
    }

    final target = segments[4];

    if (segments.length == 6 && segments[5] == 'cover') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final item = _findFavoriteItemByTarget(
        favorites,
        folder,
        target,
        type: _readIntValue(request.url.queryParameters['type']),
      );
      if (item == null) {
        return _jsonResponse({'error': 'favorite not found'}, statusCode: 404);
      }

      final cacheKey = _favoriteCoverCacheKey(folder, item);
      final localCoverPath = item.coverPath.trim();
      if (localCoverPath.isNotEmpty) {
        final localResponse = await _fileResponse(request, localCoverPath);
        if (localResponse.statusCode != 404) {
          return localResponse;
        }
      }

      final cachedCoverPath = _favoriteCoverFallbackCache[cacheKey]?.trim() ?? '';
      if (cachedCoverPath.isNotEmpty) {
        final cachedResponse = await _fileResponse(request, cachedCoverPath);
        if (cachedResponse.statusCode != 404) {
          return cachedResponse;
        }
        _favoriteCoverFallbackCache.remove(cacheKey);
      }

      final snapshot = await _currentSnapshot();
      final matched = _resolveFavoriteResourceItem(snapshot, item);
      if (matched == null) {
        return _jsonResponse({'error': 'cover not found'}, statusCode: 404);
      }

      var resolvedCoverPath = matched.coverPath?.trim() ?? '';
      if (resolvedCoverPath.isEmpty) {
        final rootPath = _rootPathForRootId(matched.rootId);
        if (rootPath != null && rootPath.trim().isNotEmpty) {
          resolvedCoverPath = await _scanner.resolveCoverPathOnly(
            matched,
            rootPath: rootPath,
          );
        }
      }
      if (resolvedCoverPath.isEmpty) {
        return _jsonResponse({'error': 'cover not found'}, statusCode: 404);
      }
      final resolvedResponse = await _fileResponse(request, resolvedCoverPath);
      if (resolvedResponse.statusCode == 404) {
        return _jsonResponse({'error': 'cover not found'}, statusCode: 404);
      }
      _favoriteCoverFallbackCache[cacheKey] = resolvedCoverPath;
      return resolvedResponse;
    }

    if (segments.length == 5 && request.method == 'DELETE') {
      final item = _findFavoriteItemByTarget(
        favorites,
        folder,
        target,
        type: _readIntValue(request.url.queryParameters['type']),
      );
      if (item == null) {
        return _jsonResponse({'error': 'favorite not found'}, statusCode: 404);
      }
      favorites.deleteComic(folder, item);
      _state.addLog('favorites', '已删除收藏 ${item.name} <- $folder');
      _notifyLibraryChanged();
      return _jsonResponse({'ok': true});
    }

    return _jsonResponse({'error': 'not found'}, statusCode: 404);
  }

  Future<Response?> _handleImageFavoritesRequest(Request request) async {
    final segments = request.url.pathSegments;
    if (segments.length < 3 ||
        segments[0] != 'api' ||
        segments[1] != 'library' ||
        segments[2] != 'image-favorites') {
      return null;
    }

    if (segments.length == 3) {
      if (request.method == 'GET') {
        return _jsonResponse({
          'items': ImageFavoriteManager.getAll()
              .map(_buildImageFavoritePayload)
              .toList(growable: false),
        });
      }
      if (request.method == 'POST') {
        final payload = await _readJsonMapFromBody(request);
        final item = _imageFavoriteFromPayload(payload);
        ImageFavoriteManager.add(item);
        _state.addLog('image_favorites', '已添加图片收藏 ${item.title}');
        _notifyLibraryChanged();
        return _jsonResponse({'ok': true});
      }
      return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
    }

    if (segments.length < 6) {
      return _jsonResponse({'error': 'not found'}, statusCode: 404);
    }

    final id = segments[3];
    final ep = int.tryParse(segments[4]);
    final page = int.tryParse(segments[5]);
    if (ep == null || page == null) {
      return _jsonResponse({'error': 'invalid image favorite key'},
          statusCode: 400);
    }
    final item = _findImageFavorite(id, ep, page);
    if (item == null) {
      return _jsonResponse({'error': 'image favorite not found'},
          statusCode: 404);
    }

    if (segments.length == 7 && segments[6] == 'image') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      if (item.imagePath.trim().isEmpty) {
        return _jsonResponse({'error': 'image not found'}, statusCode: 404);
      }
      return _fileResponse(request, item.imagePath);
    }

    if (segments.length == 6 && request.method == 'DELETE') {
      ImageFavoriteManager.delete(item);
      _state.addLog('image_favorites', '已删除图片收藏 ${item.title}');
      _notifyLibraryChanged();
      return _jsonResponse({'ok': true});
    }

    return _jsonResponse({'error': 'not found'}, statusCode: 404);
  }

  Future<ServerResourceItemSummary> _ensureDeepItem(
    ServerResourceItemSummary shallow, {
    required String? rootPath,
  }) async {
    if (shallow.rootId.startsWith('custom_') ||
        rootPath == null ||
        rootPath.trim().isEmpty) {
      return shallow;
    }
    final cached = _deepItemCache[shallow.id];
    if (cached != null) {
      return cached;
    }
    final inFlight = _deepItemInFlight[shallow.id];
    if (inFlight != null) {
      return await inFlight;
    }
    final future = _runDeepItemScan(shallow, rootPath: rootPath);
    _deepItemInFlight[shallow.id] = future;
    try {
      return await future;
    } finally {
      _deepItemInFlight.remove(shallow.id);
    }
  }

  Future<ServerResourceItemSummary> _runDeepItemScan(
    ServerResourceItemSummary shallow, {
    required String rootPath,
  }) async {
    await _acquireDeepScanSlot();
    try {
      final deepItem = await _scanner.deepScanItem(shallow, rootPath: rootPath);
      final resolved = deepItem ?? shallow;
      _deepItemCache[shallow.id] = resolved;
      return resolved;
    } finally {
      _releaseDeepScanSlot();
    }
  }

  Future<void> _acquireDeepScanSlot() async {
    while (_activeDeepScanCount >= _maxConcurrentDeepScans) {
      final completer = Completer<void>();
      _deepScanWaiters.add(completer);
      await completer.future;
    }
    _activeDeepScanCount += 1;
  }

  void _releaseDeepScanSlot() {
    if (_activeDeepScanCount > 0) {
      _activeDeepScanCount -= 1;
    }
    if (_deepScanWaiters.isEmpty) {
      return;
    }
    final completer = _deepScanWaiters.removeAt(0);
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  Future<ServerResourceSnapshot> _currentSnapshot() async {
    final snapshot = _snapshot;
    if (snapshot != null) {
      return snapshot;
    }
    final nextSnapshot = await _scanResources();
    _setSnapshot(nextSnapshot, emitEvent: false);
    return nextSnapshot;
  }

  void _handleEventSocket(WebSocketChannel channel) {
    _eventChannels.add(channel);
    final eventSubscription = _eventBus.stream.listen((event) {
      _sendSocketJson(channel, event.toJson());
    });
    final heartbeatTimer = Timer.periodic(
      const Duration(seconds: 25),
      (_) {
        _sendSocketJson(channel, {
          'type': 'ping',
          'generatedAt': DateTime.now().toIso8601String(),
        });
      },
    );

    final signature = _librarySignature?.trim() ?? '';
    final snapshot = _snapshot;
    if (signature.isNotEmpty && snapshot != null) {
      _sendSocketJson(
        channel,
        LibraryEvent.libraryChanged(signature, snapshot.generatedAt).toJson(),
      );
    }

    var cleanedUp = false;
    Future<void> cleanup() async {
      if (cleanedUp) {
        return;
      }
      cleanedUp = true;
      heartbeatTimer.cancel();
      _eventChannels.remove(channel);
      await eventSubscription.cancel();
    }

    channel.stream.listen(
      (_) {},
      onDone: () {
        unawaited(cleanup());
      },
      onError: (_) {
        unawaited(cleanup());
      },
      cancelOnError: true,
    );
  }

  void _sendSocketJson(WebSocketChannel channel, Map<String, dynamic> payload) {
    if (!_eventChannels.contains(channel)) {
      return;
    }
    try {
      channel.sink.add(jsonEncode(payload));
    } catch (_) {
      _eventChannels.remove(channel);
      unawaited(channel.sink.close(web_socket_status.goingAway));
    }
  }

  ServerResourceEpisodeSummary? _findEpisode(
    ServerResourceItemSummary item,
    int episodeIndex,
  ) {
    if (item.episodes.isEmpty) {
      return null;
    }
    if (episodeIndex <= 0) {
      return item.episodes.first;
    }
    for (final episode in item.episodes) {
      if (episode.index == episodeIndex) {
        return episode;
      }
    }
    if (item.episodes.length == 1 && episodeIndex == 1) {
      return item.episodes.first;
    }
    return null;
  }

  Map<String, dynamic> _buildTrashItemPayload(LibraryTrashEntry entry) {
    final encodedId = Uri.encodeComponent(entry.id);
    return {
      'id': entry.id,
      'itemId': entry.itemId,
      'rootId': entry.rootId,
      'itemKind': entry.itemKind,
      'title': entry.title,
      'subtitle': entry.subtitle,
      'sourceDisplayName': entry.sourceDisplayName,
      'tags': entry.tags,
      'originalPath': entry.originalPath,
      'imageCount': entry.imageCount,
      'totalBytes': entry.totalBytes,
      'deletedAt': entry.deletedAt.toIso8601String(),
      'coverUrl': '/api/library/trash/$encodedId/cover',
      'source': 'server',
    };
  }

  Map<String, dynamic> _buildFavoriteItemPayload(
    String folder,
    FavoriteItem item, {
    ServerResourceItemSummary? matched,
  }) {
    final encodedFolder = Uri.encodeComponent(folder);
    final encodedTarget = Uri.encodeComponent(item.target);
    return {
      'name': item.name,
      'author': item.author,
      'type': item.type.key,
      'tags': item.tags,
      'target': item.target,
      'time': item.time,
      if (matched != null) ...{
        'itemId': matched.id,
        'id': matched.id,
        'displayId': matched.displayId,
        'sourceDisplayName': matched.sourceDisplayName,
        'imageCount': matched.imageCount,
        'totalBytes': matched.totalBytes,
        'updatedAt': matched.updatedAt.toIso8601String(),
      },
      'coverUrl':
          '/api/library/favorites/$encodedFolder/$encodedTarget/cover?type=${item.type.key}',
    };
  }

  Map<String, dynamic> _buildImageFavoritePayload(ImageFavorite item) {
    final encodedId = Uri.encodeComponent(item.id);
    return {
      'id': item.id,
      'title': item.title,
      'ep': item.ep,
      'page': item.page,
      'otherInfo': item.otherInfo,
      'imageUrl':
          '/api/library/image-favorites/$encodedId/${item.ep}/${item.page}/image',
    };
  }

  FavoriteItem? _findFavoriteItemByTarget(
    LocalFavoritesManager favorites,
    String folder,
    String target, {
    int? type,
  }) {
    for (final item in favorites.getAllComics(folder)) {
      if (item.target == target && (type == null || item.type.key == type)) {
        return item;
      }
    }
    return null;
  }

  String _favoriteCoverCacheKey(String folder, FavoriteItem item) {
    return '$folder|${item.type.key}|${item.target}';
  }

  ServerResourceItemSummary? _resolveFavoriteResourceItem(
    ServerResourceSnapshot snapshot,
    FavoriteItem item,
  ) {
    final candidates = _buildFavoriteServerCandidates(item);
    return _findResourceItemByCandidates(snapshot.items, candidates);
  }

  List<String> _buildFavoriteServerCandidates(FavoriteItem item) {
    final candidates = <String>[];
    final seen = <String>{};
    final rawTarget = item.target.trim();

    void addCandidate(String value) {
      final normalized = value.trim();
      if (normalized.isNotEmpty && seen.add(normalized)) {
        candidates.add(normalized);
      }
    }

    for (final candidate in item.candidateDownloadIds()) {
      if (candidate.trim() != rawTarget) {
        addCandidate(candidate);
      }
    }
    addCandidate(rawTarget);
    return candidates;
  }

  ServerResourceItemSummary? _findResourceItemByCandidates(
    List<ServerResourceItemSummary> items,
    List<String> candidates,
  ) {
    if (candidates.isEmpty) return null;

    final normalizedCandidates = candidates
        .map((candidate) => candidate.trim())
        .where((candidate) => candidate.isNotEmpty)
        .toList(growable: false);
    if (normalizedCandidates.isEmpty) return null;

    final itemPools = <({ServerResourceItemSummary item, Set<String> pool})>[
      for (final item in items) (item: item, pool: _resourceItemCandidatePool(item)),
    ];

    for (final candidate in normalizedCandidates) {
      for (final entry in itemPools) {
        if (entry.pool.contains(candidate)) {
          return entry.item;
        }
      }
    }

    return null;
  }

  Set<String> _resourceItemCandidatePool(ServerResourceItemSummary item) {
    return <String>{
      item.id,
      item.title,
      item.displayId,
      item.sourceTitle,
      item.sourceDisplayName,
      item.subtitle,
      item.path,
    }
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  ImageFavorite? _findImageFavorite(String id, int ep, int page) {
    for (final item in ImageFavoriteManager.getAll()) {
      if (item.id == id && item.ep == ep && item.page == page) {
        return item;
      }
    }
    return null;
  }

  FavoriteItem _favoriteItemFromPayload(Map<String, dynamic> payload) {
    return FavoriteItem(
      target: payload['target']?.toString() ?? '',
      name: payload['name']?.toString() ?? '',
      coverPath: payload['coverPath']?.toString() ?? '',
      author: payload['author']?.toString() ?? '',
      type: FavoriteType(_readIntValue(payload['type']) ?? 0),
      tags: _readStringListValue(payload['tags']),
    )..time = payload['time']?.toString().trim().isNotEmpty == true
        ? payload['time'].toString().trim()
        : getCurTime();
  }

  ImageFavorite _imageFavoriteFromPayload(Map<String, dynamic> payload) {
    return ImageFavorite(
      payload['id']?.toString() ?? '',
      payload['imagePath']?.toString() ?? '',
      payload['title']?.toString() ?? '',
      _readIntValue(payload['ep']) ?? 0,
      _readIntValue(payload['page']) ?? 0,
      _readJsonLikeMap(payload['otherInfo']),
    );
  }

  void _notifyLibraryChanged() {
    // Favorites and image favorites live in their own SQLite stores; changing
    // them must not trigger a full resource rescan, which would block existing
    // remote library endpoints on large libraries.
  }

  String? _rootPathForRootId(String rootId) {
    final config = _config ?? PicaKeepServerConfig.defaults();
    return switch (rootId) {
      'current_download' => config.currentDownloadRoot,
      'original_download' => config.originalDownloadRoot,
      _ when rootId.startsWith('custom_') => () {
          final index = int.tryParse(rootId.substring('custom_'.length));
          if (index == null ||
              index < 0 ||
              index >= config.customLibraryRoots.length) {
            return null;
          }
          return config.customLibraryRoots[index];
        }(),
      _ => null,
    };
  }

  Map<String, dynamic> _buildLibraryRootPayload(
    ServerResourceRootSummary root,
    Iterable<ServerResourceItemSummary> items,
  ) {
    final previewCoverUrls = <String>[];
    for (final item in items) {
      if (item.rootId != root.id || item.coverPath?.trim().isEmpty != false) {
        continue;
      }
      previewCoverUrls.add(
        _buildItemCoverUrl(item),
      );
      if (previewCoverUrls.length >= 6) {
        break;
      }
    }
    return {
      'id': root.id,
      'title': root.title,
      'path': root.path,
      'exists': root.exists,
      'itemCount': root.itemCount,
      'totalBytes': root.totalBytes,
      'previewCoverUrls': previewCoverUrls,
    };
  }


  int _clampIntQuery(String? value, int fallback, int min, int max) {
    final parsed = int.tryParse((value ?? '').trim()) ?? fallback;
    if (parsed < min) return min;
    if (parsed > max) return max;
    return parsed;
  }

  Map<String, dynamic> _buildLibraryRecommendationsPayload(
    ServerResourceSnapshot snapshot,
    ServerResourceItemSummary item, {
    required int limit,
  }) {
    final scored = <Map<String, dynamic>>[];
    for (final candidate in snapshot.items) {
      if (candidate.id == item.id || candidate.title == item.title) {
        continue;
      }
      final score = _recommendationScore(item, candidate);
      if (score <= 0) {
        continue;
      }
      scored.add({
        'item': candidate,
        'score': score,
        'reason': _recommendationReason(item, candidate),
      });
    }
    scored.sort((a, b) {
      final scoreCompare = (b['score'] as double).compareTo(a['score'] as double);
      if (scoreCompare != 0) return scoreCompare;
      final left = (b['item'] as ServerResourceItemSummary).updatedAt;
      final right = (a['item'] as ServerResourceItemSummary).updatedAt;
      return left.compareTo(right);
    });
    return {
      'generatedAt': DateTime.now().toIso8601String(),
      'librarySignature': _librarySignature ?? '',
      'itemId': item.id,
      'items': [
        for (final entry in scored.take(limit))
          {
            ..._buildLibraryItemPayload(entry['item'] as ServerResourceItemSummary),
            'reason': entry['reason'],
            'score': entry['score'],
          },
      ],
    };
  }

  double _recommendationScore(
    ServerResourceItemSummary base,
    ServerResourceItemSummary candidate,
  ) {
    var score = 0.0;
    final baseName = _recommendationNormalize(base.title);
    final candidateName = _recommendationNormalize(candidate.title);
    if (baseName.isNotEmpty && candidateName.isNotEmpty) {
      if (baseName.contains(candidateName) || candidateName.contains(baseName)) {
        score += 90;
      }
      score += _bigramOverlap(baseName, candidateName) * 70;
    }
    final baseTopics = _recommendationTopics(base.title);
    final candidateTopics = _recommendationTopics(candidate.title);
    final topicMatches = baseTopics.intersection(candidateTopics).length;
    score += topicMatches * 22;
    final tagMatches = base.tags.toSet().intersection(candidate.tags.toSet()).length;
    score += tagMatches * 18;
    if (base.subtitle.isNotEmpty && base.subtitle == candidate.subtitle) {
      score += 28;
    }
    if (base.sourceDisplayName.isNotEmpty &&
        base.sourceDisplayName == candidate.sourceDisplayName) {
      score += 8;
    }
    return score;
  }

  String _recommendationReason(
    ServerResourceItemSummary base,
    ServerResourceItemSummary candidate,
  ) {
    final baseName = _recommendationNormalize(base.title);
    final candidateName = _recommendationNormalize(candidate.title);
    final overlap = _bigramOverlap(baseName, candidateName);
    if (overlap >= 0.62 ||
        (baseName.isNotEmpty &&
            candidateName.isNotEmpty &&
            (baseName.contains(candidateName) || candidateName.contains(baseName)))) {
      return '名称高度相似';
    }
    if (overlap >= 0.32) return '名称相似';
    final tagMatches = base.tags.toSet().intersection(candidate.tags.toSet()).length;
    if (base.subtitle.isNotEmpty &&
        base.subtitle == candidate.subtitle &&
        tagMatches > 0) {
      return '同作者 + 同题材';
    }
    if (tagMatches > 0) return '同标签';
    return '同题材';
  }

  String _recommendationNormalize(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  }

  Set<String> _recommendationTopics(String value) {
    final normalized = value.toLowerCase();
    return RegExp(r'[a-z0-9]+|[一-鿿぀-ヿ]{2,}')
        .allMatches(normalized)
        .map((match) => match.group(0) ?? '')
        .where((token) => token.length >= 2)
        .toSet();
  }

  double _bigramOverlap(String a, String b) {
    final left = _bigrams(a);
    final right = _bigrams(b);
    if (left.isEmpty || right.isEmpty) return 0;
    final intersection = left.intersection(right).length;
    return intersection / (left.length < right.length ? left.length : right.length);
  }

  Set<String> _bigrams(String value) {
    if (value.length < 2) return value.isEmpty ? <String>{} : <String>{value};
    return {
      for (var i = 0; i < value.length - 1; i++) value.substring(i, i + 2),
    };
  }

  Map<String, dynamic> _buildLibraryItemPayload(
    ServerResourceItemSummary item, {
    bool includePages = false,
  }) {
    final encodedId = Uri.encodeComponent(item.id);
    return {
      'id': item.id,
      'rootId': item.rootId,
      'sourceTitle': item.sourceTitle,
      'sourceDisplayName': item.sourceDisplayName,
      'title': item.title,
      'displayId': item.displayId,
      'subtitle': item.subtitle,
      'tags': item.tags,
      'path': item.path,
      'imageCount': item.imageCount,
      'totalBytes': item.totalBytes,
      'updatedAt': item.updatedAt.toIso8601String(),
      'coverUrl': _buildItemCoverUrl(item),
      'detailUrl': '/api/library/items/$encodedId',
      'episodeCount': item.episodes.length,
      'hasMultipleEpisodes': item.hasMultipleEpisodes,
      'episodes': item.episodes
          .map(
            (episode) => _buildLibraryEpisodePayload(
              item.id,
              episode,
              includePages: includePages,
              item: item,
            ),
          )
          .toList(),
    };
  }

  Map<String, dynamic> _buildLibraryEpisodePayload(
    String itemId,
    ServerResourceEpisodeSummary episode, {
    bool includePages = false,
    ServerResourceItemSummary? item,
  }) {
    final encodedId = Uri.encodeComponent(itemId);
    final coverUrl = item == null
        ? '/api/library/items/$encodedId/cover'
        : _buildItemCoverUrl(item);
    return {
      'index': episode.index,
      'title': episode.title,
      'path': episode.path,
      'imageCount': episode.imageCount,
      'totalBytes': episode.totalBytes,
      'coverUrl': coverUrl,
      if (includePages) ...{
        'pages': [
          for (var i = 0; i < episode.imagePaths.length; i++)
            '/api/library/items/$encodedId/images/${episode.index}/$i',
        ],
        'pageSizes': [
          for (final size in episode.imageSizes) size?.toJson(),
        ],
      },
    };
  }

  String _buildItemCoverUrl(ServerResourceItemSummary item) {
    final encodedId = Uri.encodeComponent(item.id);
    final coverVersion = _coverVersionToken(item);
    final version = Uri.encodeQueryComponent(coverVersion);
    return '/api/library/items/$encodedId/cover?v=$version';
  }

  String _coverVersionToken(ServerResourceItemSummary item) {
    final coverPath = item.coverPath?.trim() ?? '';
    if (coverPath.isEmpty) {
      return item.updatedAt.millisecondsSinceEpoch.toString();
    }
    try {
      final stat = File(coverPath).statSync();
      return '${item.updatedAt.millisecondsSinceEpoch}:${_basename(coverPath)}:${stat.modified.millisecondsSinceEpoch}:${stat.size}';
    } catch (_) {
      return '${item.updatedAt.millisecondsSinceEpoch}:${_basename(coverPath)}';
    }
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts =
        normalized.split('/').where((entry) => entry.isNotEmpty).toList();
    return parts.isEmpty ? normalized : parts.last;
  }

  Future<Response> _fileResponse(Request request, String filePath) async {
    final directFile = File(filePath);

    if (await directFile.exists()) {
      try {
        final length = await directFile.length();
        final headers = <String, String>{
          HttpHeaders.contentTypeHeader: _contentTypeForPath(filePath),
          HttpHeaders.acceptRangesHeader: 'bytes',
          HttpHeaders.cacheControlHeader: 'public, max-age=300',
        };

        final range = request.headers[HttpHeaders.rangeHeader];
        if (range != null) {
          final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
          if (match != null) {
            var start = int.tryParse(match.group(1) ?? '') ?? 0;
            var end = int.tryParse(match.group(2) ?? '') ?? (length - 1);
            if (start < 0 || start >= length || end < start) {
              return Response(
                416,
                headers: {
                  HttpHeaders.contentRangeHeader: 'bytes */$length',
                  HttpHeaders.acceptRangesHeader: 'bytes',
                },
              );
            }
            if (end >= length) {
              end = length - 1;
            }
            final chunkLength = end - start + 1;
            return Response(
              206,
              body: directFile.openRead(start, end + 1),
              headers: {
                ...headers,
                HttpHeaders.contentLengthHeader: chunkLength.toString(),
                HttpHeaders.contentRangeHeader: 'bytes $start-$end/$length',
              },
            );
          }
        }

        return Response.ok(
          directFile.openRead(),
          headers: {
            ...headers,
            HttpHeaders.contentLengthHeader: length.toString(),
          },
        );
      } catch (_) {
        // dart:io access failed — try privileged fallback below.
      }
    }

    final bytes = await PrivilegedStorageAccess.readFileBytes(filePath);
    if (bytes == null || bytes.isEmpty) {
      return _jsonResponse({'error': 'file not found'}, statusCode: 404);
    }

    return Response.ok(
      bytes,
      headers: {
        HttpHeaders.contentTypeHeader: _contentTypeForPath(filePath),
        HttpHeaders.contentLengthHeader: bytes.length.toString(),
        HttpHeaders.cacheControlHeader: 'public, max-age=300',
      },
    );
  }

  String _contentTypeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) {
      return ContentType('image', 'png').toString();
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.bmp')) {
      return 'image/bmp';
    }
    return ContentType('image', 'jpeg').toString();
  }

  Future<ServerResourceSnapshot> _scanResources() {
    final config = _config ?? PicaKeepServerConfig.defaults();
    return _scanner.scan(
      currentDownloadRoot: config.currentDownloadRoot,
      originalDownloadRoot: config.originalDownloadRoot,
      customLibraryRoots: config.customLibraryRoots,
    );
  }

  void _setSnapshot(
    ServerResourceSnapshot snapshot, {
    required bool emitEvent,
  }) {
    final previousSignature = _librarySignature;
    _snapshot = snapshot;
    _recomputeLibrarySignature(emitEvent: emitEvent);
    if (previousSignature != _librarySignature) {
      _deepItemCache.clear();
      _deepItemInFlight.clear();
      _favoriteCoverFallbackCache.clear();
    }
  }

  void _recomputeLibrarySignature({required bool emitEvent}) {
    final snapshot = _snapshot;
    if (snapshot == null) {
      _librarySignature = null;
      return;
    }
    final nextSignature = _computeLibrarySignature(snapshot);
    final changed = _librarySignature != nextSignature;
    _librarySignature = nextSignature;
    if (!emitEvent || !changed) {
      return;
    }
    _pendingLibraryChangedSignature = nextSignature;
    _pendingLibraryChangedGeneratedAt = snapshot.generatedAt;
    _pendingLibraryChangedTimer?.cancel();
    _pendingLibraryChangedTimer = Timer(
      const Duration(milliseconds: 250),
      _flushPendingLibraryChangedEvent,
    );
  }

  void _flushPendingLibraryChangedEvent() {
    _pendingLibraryChangedTimer?.cancel();
    _pendingLibraryChangedTimer = null;
    final signature = _pendingLibraryChangedSignature?.trim() ?? '';
    final generatedAt = _pendingLibraryChangedGeneratedAt;
    _pendingLibraryChangedSignature = null;
    _pendingLibraryChangedGeneratedAt = null;
    if (signature.isEmpty || generatedAt == null) {
      return;
    }
    _eventBus.emit(LibraryEvent.libraryChanged(signature, generatedAt));
  }

  String _computeLibrarySignature(ServerResourceSnapshot snapshot) {
    final buffer = StringBuffer();
    final config = _config ?? PicaKeepServerConfig.defaults();
    buffer
      ..writeln(config.currentDownloadRoot.trim())
      ..writeln(config.originalDownloadRoot.trim());
    for (final root in [...snapshot.roots]..sort((a, b) {
        final idCompare = a.id.compareTo(b.id);
        if (idCompare != 0) {
          return idCompare;
        }
        return a.path.compareTo(b.path);
      })) {
      buffer.writeln(
        '${root.id}|${root.path}|${root.exists}|${root.itemCount}|${root.totalBytes}',
      );
    }
    buffer
      ..writeln(snapshot.totalComicCount.toString())
      ..writeln(snapshot.totalBytes.toString());
    return _fnv1a64(buffer.toString());
  }

  String _fnv1a64(String input) {
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    const mask = 0xffffffffffffffff;
    for (final byte in utf8.encode(input)) {
      hash ^= byte;
      hash = (hash * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  Map<String, dynamic> buildStatusPayload() {
    final config = _config ?? PicaKeepServerConfig.defaults();
    final snapshot = _snapshot;
    final availableLibraryRootCount =
        snapshot?.roots.where((root) => root.exists).length ?? 0;
    final missingLibraryRootCount =
        snapshot?.roots.where((root) => !root.exists).length ?? 0;
    return {
      'serviceName': 'PicaKeepServer',
      'lifecycle': _state.lifecycle,
      'statusText': _state.isRunning ? '在线' : _runtimeStatusText(),
      'online': _state.isRunning,
      'message': _runtimeMessage(),
      'lastError': _state.lastError,
      'startedAt': _state.startedAt?.toIso8601String(),
      'activeConnections': _state.activeConnections,
      'totalRequests': _state.totalRequests,
      'comicCount': snapshot?.totalComicCount ?? 0,
      'connectionCount': _state.activeConnections,
      'libraryRootCount': config.allLibraryRoots.length,
      'availableLibraryRootCount': availableLibraryRootCount,
      'missingLibraryRootCount': missingLibraryRootCount,
      'resourceBytes': snapshot?.totalBytes ?? 0,
      'resourceGeneratedAt': snapshot?.generatedAt.toIso8601String(),
      'librarySignature': _librarySignature ?? '',
      'statusUrl': _buildStatusUrl(),
      'adminUrl': _buildAdminUrl(),
      'consolePasswordEmpty': config.consolePassword.trim().isEmpty,
    };
  }

  Map<String, dynamic> buildSummaryPayload() {
    final config = _config ?? PicaKeepServerConfig.defaults();
    final snapshot = _snapshot;
    return {
      ...buildStatusPayload(),
      'host': config.host,
      'port': _server?.port ?? config.port,
      'logRequests': config.logRequests,
      'configPath': configPath,
      'currentDownloadRoot': config.currentDownloadRoot,
      'originalDownloadRoot': config.originalDownloadRoot,
      'customLibraryRoots': config.customLibraryRoots,
      'rootSummaries':
          snapshot?.roots.map((root) => root.toJson()).toList() ?? const [],
    };
  }

  String _buildStatusUrl() {
    final config = _config ?? PicaKeepServerConfig.defaults();
    final port = _server?.port ?? config.port;
    return 'http://${_buildDisplayHost(config.host)}:$port/status';
  }

  String _buildAdminUrl() {
    final config = _config ?? PicaKeepServerConfig.defaults();
    final port = _server?.port ?? config.port;
    return 'http://${_buildDisplayHost(config.host)}:$port/';
  }

  String _buildDisplayHost(String host) {
    final trimmed = host.trim();
    if (trimmed.isEmpty ||
        trimmed == '0.0.0.0' ||
        trimmed == '::' ||
        trimmed == '::0') {
      return '<当前设备IP>';
    }
    return trimmed;
  }

  String _runtimeStatusText() {
    return switch (_state.lifecycle) {
      serverRuntimeLifecycleStarting => '启动中',
      serverRuntimeLifecycleStopping => '停止中',
      serverRuntimeLifecycleError => '启动失败',
      _ => '未启动',
    };
  }

  String _runtimeMessage() {
    if (_state.isRunning) {
      return '当前服务端仅基于本机可访问的本地资源提供服务，客户端模式连接后访问的也是这些资源。';
    }
    if (_state.lastError?.trim().isNotEmpty == true) {
      return _state.lastError!.trim();
    }
    if (_state.lastMessage?.trim().isNotEmpty == true) {
      return _state.lastMessage!.trim();
    }
    return '当前本地服务尚未启动。';
  }

  Response _jsonResponse(
    Map<String, dynamic> body, {
    int statusCode = 200,
  }) {
    return Response(
      statusCode,
      body: const JsonEncoder.withIndent('  ').convert(body),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  Future<List<String>> _readStringListFromBody(
    Request request,
    String key,
  ) async {
    final body = await request.readAsString();
    if (body.trim().isEmpty) {
      return const <String>[];
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      return const <String>[];
    }
    final value = decoded[key];
    if (value is! List) {
      return const <String>[];
    }
    return value
        .map((entry) => entry.toString().trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> _readJsonMapFromBody(Request request) async {
    final body = await request.readAsString();
    if (body.trim().isEmpty) {
      return const <String, dynamic>{};
    }
    final decoded = jsonDecode(body);
    return _readJsonLikeMap(decoded);
  }

  Map<String, dynamic> _readJsonLikeMap(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return const <String, dynamic>{};
  }

  List<String> _readStringListValue(Object? value) {
    if (value is! List) {
      return const <String>[];
    }
    return value
        .map((entry) => entry.toString().trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }

  Set<int> _readIntSetValue(Object? value) {
    if (value is List) {
      return value
          .map(_readIntValue)
          .whereType<int>()
          .where((entry) => entry >= 0)
          .toSet();
    }
    if (value is String) {
      return value
          .split(',')
          .map((entry) => int.tryParse(entry.trim()))
          .whereType<int>()
          .where((entry) => entry >= 0)
          .toSet();
    }
    return const <int>{};
  }

  int? _readIntValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }
}
