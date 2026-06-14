import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'server_config.dart';
import 'server_runtime_state.dart';
import 'web_console/web_console_handler.dart';

class PicaKeepHeadlessCliServer {
  PicaKeepHeadlessCliServer({
    required this.configPath,
    required this.version,
  });

  final String configPath;
  final String version;
  final ServerRuntimeState _state = ServerRuntimeState();

  PicaKeepServerConfig _config = PicaKeepServerConfig.defaults();
  HttpServer? _server;
  String? _token;
  String? _tokenPassword;
  _HeadlessResourceSnapshot _snapshot = _HeadlessResourceSnapshot.empty();

  PicaKeepServerConfig get config => _config;

  Future<void> start({required PicaKeepServerConfig config}) async {
    _state.markStarting('正在启动 headless 服务端');
    _config = config;
    _snapshot = await _scanResources();
    try {
      final server = await shelf_io.serve(
        _handleRequest,
        InternetAddress(config.host),
        config.port,
        poweredByHeader: null,
      );
      _server = server;
      _state.markRunning('headless 服务端已启动');
    } catch (error, stackTrace) {
      _state.markError(error, stackTrace);
      rethrow;
    }
  }

  Future<void> stop() async {
    final server = _server;
    if (server == null) {
      return;
    }
    _state.markStopping('正在停止 headless 服务端');
    _server = null;
    await server.close(force: true);
    _state.markStopped('headless 服务端已停止');
  }

  Future<Response> _handleRequest(Request request) async {
    _state.beginRequest(request.method, '/${request.url.path}');
    try {
      if (request.method == 'OPTIONS') {
        return _withCors(Response.ok(''));
      }
      return _withCors(await _dispatch(request));
    } catch (error, stackTrace) {
      _state.addLog('error', '$error\n$stackTrace');
      return _withCors(
        _jsonResponse({'error': 'server error', 'detail': error.toString()},
            statusCode: 500),
      );
    } finally {
      _state.endRequest();
    }
  }

  Future<Response> _dispatch(Request request) async {
    final path = request.url.path;

    if (path.isEmpty || path == 'status' || path == 'api/admin/status') {
      if (path.isEmpty) {
        final webConsoleResponse = await handleWebConsoleRequest(request);
        if (webConsoleResponse != null) {
          return webConsoleResponse;
        }
      }
      return _jsonResponse(buildStatusPayload());
    }

    if (path == 'api/console/login') {
      return _handleLogin(request);
    }

    final consoleResponse = await _handleConsoleRequest(request);
    if (consoleResponse != null) {
      return consoleResponse;
    }

    if (path.startsWith('api/')) {
      final user = _currentUser(request);
      if (user == null) {
        return _jsonResponse({'error': 'unauthorized'}, statusCode: 401);
      }
      final apiResponse = await _handleApiRequest(request, user);
      if (apiResponse != null) {
        return apiResponse;
      }
      return _jsonResponse({
        'ok': false,
        'error': 'CLI headless 服务端暂未实现该业务接口',
        'path': '/$path',
      }, statusCode: 501);
    }

    final webConsoleResponse = await handleWebConsoleRequest(request);
    if (webConsoleResponse != null) {
      return webConsoleResponse;
    }

    return _jsonResponse({'error': 'not found'}, statusCode: 404);
  }

  Future<Response?> _handleApiRequest(
    Request request,
    _HeadlessUser user,
  ) async {
    final path = request.url.path;
    if (path == 'api/admin/summary') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _jsonResponse(buildSummaryPayload());
    }
    if (path == 'api/admin/resources') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _jsonResponse(_snapshot.toJson());
    }
    if (path == 'api/admin/config') {
      if (request.method == 'GET') {
        return _jsonResponse(_config.toJson());
      }
      if (request.method == 'PUT') {
        final payload = await _readJsonMap(request);
        final nextConfig = PicaKeepServerConfig.fromJson(payload);
        final passwordChanged = nextConfig.consolePassword != _config.consolePassword;
        _config = nextConfig;
        await PicaKeepServerConfig.save(configPath, _config);
        _snapshot = await _scanResources();
        _state.addLog('config', '配置已保存');
        if (passwordChanged) {
          _token = null;
          _tokenPassword = null;
        }
        return _jsonResponse({
          'ok': true,
          'message': '配置已保存，host/port 改动重启后完全生效',
          'config': _config.toJson(),
        });
      }
      return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
    }
    if (path == 'api/admin/logs') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _jsonResponse({'logs': _state.recentLogs()});
    }
    if (path == 'api/admin/scan') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      _snapshot = await _scanResources();
      _state.addLog('scan', 'headless 资源状态已刷新');
      return _jsonResponse({'ok': true, 'snapshot': _snapshot.toJson()});
    }
    if (path == 'api/admin/browse') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _handleAdminBrowse(request);
    }
    if (path == 'api/console/users') {
      if (request.method == 'GET') {
        return _jsonResponse({'users': [user.toJson()]});
      }
      return _jsonResponse({
        'ok': false,
        'error': 'CLI headless 服务端暂不支持用户管理',
      }, statusCode: 501);
    }
    if (path == 'api/library/items') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _jsonResponse({
        'items': const [],
        'generatedAt': _snapshot.generatedAt.toIso8601String(),
        'source': 'headless',
      });
    }
    if (path == 'api/library/trash') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _jsonResponse({'items': const []});
    }
    if (path == 'api/library/favorites') {
      if (request.method == 'GET') {
        return _jsonResponse({'folders': const []});
      }
      return _jsonResponse({
        'ok': false,
        'error': 'CLI headless 服务端暂不支持收藏夹写入',
      }, statusCode: 501);
    }
    if (path.startsWith('api/library/favorites/')) {
      if (request.method == 'GET') {
        return _jsonResponse({'items': const []});
      }
      return _jsonResponse({
        'ok': false,
        'error': 'CLI headless 服务端暂不支持收藏夹写入',
      }, statusCode: 501);
    }
    if (path == 'api/library/image-favorites') {
      if (request.method == 'GET') {
        return _jsonResponse({'items': const []});
      }
      return _jsonResponse({
        'ok': false,
        'error': 'CLI headless 服务端暂不支持图片收藏写入',
      }, statusCode: 501);
    }
    if (path == 'api/library/history') {
      if (request.method == 'GET') {
        return _jsonResponse({'items': const [], 'history': const []});
      }
      if (request.method == 'POST' || request.method == 'DELETE') {
        return _jsonResponse({'ok': true});
      }
      return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
    }
    return null;
  }

  Future<Response?> _handleConsoleRequest(Request request) async {
    final path = request.url.path;
    if (!path.startsWith('api/console/')) {
      return null;
    }
    final user = _currentUser(request);
    if (user == null) {
      return _jsonResponse({'error': 'unauthorized'}, statusCode: 401);
    }
    if (path == 'api/console/me') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _jsonResponse({
        'ok': true,
        'user': user.toJson(),
        'emptyPassword': _config.consolePassword.trim().isEmpty,
      });
    }
    if (path == 'api/console/logout') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      _token = null;
      _tokenPassword = null;
      return _jsonResponse({'ok': true});
    }
    return null;
  }

  Future<Response> _handleLogin(Request request) async {
    if (request.method != 'POST') {
      return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
    }
    final payload = await _readJsonMap(request);
    final requestedUsername = payload['username']?.toString().trim() ?? '';
    final username = requestedUsername.isEmpty ? 'admin' : requestedUsername;
    final password = payload['password']?.toString() ?? '';
    final configuredPassword = _config.consolePassword;
    final emptyPassword = configuredPassword.trim().isEmpty;

    if (username != 'admin' || password != configuredPassword) {
      return _jsonResponse({
        'ok': false,
        'error': '用户名或密码错误',
      }, statusCode: 401);
    }

    _token = _makeToken();
    _tokenPassword = configuredPassword;
    final user = _HeadlessUser.admin();
    return _jsonResponse({
      'ok': true,
      'token': _token,
      'emptyPassword': emptyPassword,
      'user': user.toJson(),
    });
  }

  Future<Response> _handleAdminBrowse(Request request) async {
    final rawPath = request.url.queryParameters['path']?.trim() ?? '';
    final roots = _adminBrowseRoots();
    if (rawPath.isEmpty) {
      return _jsonResponse({
        'path': '',
        'parent': '',
        'entries': roots
            .map(
              (path) => {
                'name': _adminBrowseRootName(path),
                'path': path,
                'isDirectory': true,
              },
            )
            .toList(),
        'roots': roots,
      });
    }

    final normalizedPath = _normalizeBrowsePath(rawPath);
    try {
      final directory = Directory(normalizedPath);
      if (!await directory.exists()) {
        return _jsonResponse({'error': '目录不存在或无法访问'}, statusCode: 404);
      }
      final entries = <Map<String, dynamic>>[];
      await for (final entity in directory.list(followLinks: false)) {
        final stat = await entity.stat();
        if (stat.type != FileSystemEntityType.directory) {
          continue;
        }
        entries.add({
          'name': _basename(entity.path),
          'path': _normalizeBrowsePath(entity.path),
          'isDirectory': true,
        });
      }
      entries.sort(
        (a, b) => a['name'].toString().toLowerCase().compareTo(
              b['name'].toString().toLowerCase(),
            ),
      );
      return _jsonResponse({
        'path': normalizedPath,
        'parent': _parentBrowsePath(normalizedPath),
        'entries': entries,
        'roots': roots,
      });
    } catch (error) {
      return _jsonResponse({'error': '无法读取目录：$error'}, statusCode: 400);
    }
  }

  Map<String, dynamic> buildStatusPayload() {
    final summary = buildSummaryPayload();
    return {
      ...summary,
      'running': _state.isRunning,
      'mode': 'headless server',
      'version': version,
      'system': {
        'os': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
      },
      'dart': Platform.version.split('\n').first.trim(),
      'host': _config.host,
      'port': _config.port,
      'listenUrl': _listenUrl(),
      'appUrl': _localUrls().app,
      'adminUrl': _localUrls().admin,
      'statusUrl': _localUrls().status,
    };
  }

  Map<String, dynamic> buildSummaryPayload() {
    final urls = _localUrls();
    final rootCount = _snapshot.roots.length;
    final availableRootCount = _snapshot.roots.where((root) => root.exists).length;
    final missingRootCount = rootCount - availableRootCount;
    return {
      'serviceName': 'PicaKeep Headless Server',
      'statusText': _statusText(),
      'lifecycle': _state.lifecycle,
      'message': 'CLI headless 服务端已启动；第一版提供网页后台入口、状态、配置与基础空资源视图。',
      'startedAt': _state.startedAt?.toIso8601String(),
      'deviceSystem': Platform.operatingSystem,
      'deviceName': Platform.localHostname,
      'deviceSummary':
          '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'comicCount': 0,
      'connectionCount': _state.activeConnections,
      'activeConnections': _state.activeConnections,
      'libraryRootCount': rootCount,
      'availableLibraryRootCount': availableRootCount,
      'missingLibraryRootCount': missingRootCount,
      'resourceBytes': _snapshot.totalBytes,
      'resourceGeneratedAt': _snapshot.generatedAt.toIso8601String(),
      'librarySignature': _snapshot.signature,
      'totalRequests': _state.totalRequests,
      'statusUrl': urls.status,
      'adminUrl': urls.admin,
      'appUrl': urls.app,
      'consolePasswordEmpty': _config.consolePassword.trim().isEmpty,
      'logRequests': _config.logRequests,
    };
  }

  Future<_HeadlessResourceSnapshot> _scanResources() async {
    final roots = <_HeadlessRootSummary>[];
    final seen = <String>{};
    for (final path in _config.allLibraryRoots) {
      final normalized = _normalizeBrowsePath(path);
      if (normalized.isEmpty || !seen.add(normalized)) {
        continue;
      }
      final exists = await Directory(normalized).exists();
      roots.add(
        _HeadlessRootSummary(
          id: _safeBase64(normalized),
          title: _adminBrowseRootName(normalized),
          path: normalized,
          exists: exists,
          itemCount: 0,
          totalBytes: 0,
        ),
      );
    }
    return _HeadlessResourceSnapshot(
      generatedAt: DateTime.now(),
      roots: roots,
      items: const [],
      totalBytes: 0,
    );
  }

  _HeadlessUser? _currentUser(Request request) {
    final token = _tokenFromRequest(request);
    if (token == null || token.isEmpty || _token == null) {
      return null;
    }
    if (token != _token || _tokenPassword != _config.consolePassword) {
      return null;
    }
    return _HeadlessUser.admin();
  }

  String? _tokenFromRequest(Request request) {
    final auth =
        request.headers['authorization'] ?? request.headers['Authorization'];
    if (auth != null) {
      final match = RegExp(r'^Bearer\s+(.+)$', caseSensitive: false)
          .firstMatch(auth.trim());
      if (match != null) {
        return match.group(1)?.trim();
      }
    }
    return request.url.queryParameters['__token']?.trim();
  }

  Future<Map<String, dynamic>> _readJsonMap(Request request) async {
    final body = await request.readAsString();
    if (body.trim().isEmpty) {
      return const <String, dynamic>{};
    }
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    return const <String, dynamic>{};
  }

  Response _jsonResponse(Map<String, dynamic> body, {int statusCode = 200}) {
    return Response(
      statusCode,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  Response _withCors(Response response) {
    final headers = Map<String, String>.from(response.headers)
      ..putIfAbsent('access-control-allow-origin', () => '*')
      ..putIfAbsent(
        'access-control-allow-methods',
        () => 'GET, POST, PUT, DELETE, OPTIONS',
      )
      ..putIfAbsent(
        'access-control-allow-headers',
        () => 'Authorization, Content-Type, Accept',
      );
    return response.change(headers: headers);
  }

  _ServiceUrls _localUrls() {
    return _buildServiceUrls(
      scheme: 'http',
      host: _displayHostForLocal(_config.host),
      port: _config.port,
    );
  }

  String _listenUrl() {
    return Uri(
      scheme: 'http',
      host: _config.host,
      port: _config.port,
      path: '/',
    ).toString();
  }

  String _statusText() {
    return switch (_state.lifecycle) {
      serverRuntimeLifecycleRunning => '运行中',
      serverRuntimeLifecycleStarting => '启动中',
      serverRuntimeLifecycleStopping => '停止中',
      serverRuntimeLifecycleError => '异常',
      _ => '已停止',
    };
  }

  List<String> _adminBrowseRoots() {
    final roots = <String>[];
    void addRoot(String path) {
      final normalized = _normalizeBrowsePath(path);
      if (normalized.isEmpty || roots.contains(normalized)) {
        return;
      }
      roots.add(normalized);
    }

    if (Platform.isWindows) {
      for (var code = 65; code <= 90; code++) {
        final path = '${String.fromCharCode(code)}:${Platform.pathSeparator}';
        try {
          if (Directory(path).existsSync()) {
            addRoot(path);
          }
        } catch (_) {}
      }
    } else {
      addRoot('/');
      if (Platform.isAndroid) {
        addRoot('/storage/emulated/0');
        addRoot('/sdcard');
      }
    }
    for (final root in _config.allLibraryRoots) {
      addRoot(root);
    }
    return roots;
  }

  String _adminBrowseRootName(String path) {
    final normalized = _normalizeBrowsePath(path);
    if (Platform.isWindows && normalized.endsWith(':${Platform.pathSeparator}')) {
      return normalized;
    }
    if (normalized == '/') {
      return '/';
    }
    final basename = _basename(normalized);
    return basename.isEmpty ? normalized : basename;
  }

  String _normalizeBrowsePath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    try {
      return Directory(trimmed).absolute.path;
    } catch (_) {
      return trimmed;
    }
  }

  String _parentBrowsePath(String path) {
    final normalized = _normalizeBrowsePath(path);
    if (normalized.isEmpty) {
      return '';
    }
    final parent = Directory(normalized).parent.path;
    if (_normalizeBrowsePath(parent) == normalized) {
      return '';
    }
    return _normalizeBrowsePath(parent);
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/').where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? normalized : parts.last;
  }

  String _safeBase64(String value) {
    return base64Url.encode(utf8.encode(value)).replaceAll('=', '');
  }

  String _makeToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }
}

_ServiceUrls _buildServiceUrls({
  required String scheme,
  required String host,
  required int? port,
}) {
  Uri buildUri(String path) {
    return Uri(
      scheme: scheme,
      host: host,
      port: port,
      path: path,
    );
  }

  return _ServiceUrls(
    app: buildUri('/').toString(),
    admin: buildUri('/admin-view').toString(),
    status: buildUri('/status').toString(),
  );
}

String _displayHostForLocal(String host) {
  if (_isWildcardHost(host)) {
    return '127.0.0.1';
  }
  final trimmed = host.trim();
  if (trimmed == 'localhost') {
    return '127.0.0.1';
  }
  return trimmed;
}

bool _isWildcardHost(String host) {
  final trimmed = host.trim();
  return trimmed.isEmpty ||
      trimmed == '0.0.0.0' ||
      trimmed == '::' ||
      trimmed == '::0' ||
      trimmed == '[::]';
}

class _ServiceUrls {
  const _ServiceUrls({
    required this.app,
    required this.admin,
    required this.status,
  });

  final String app;
  final String admin;
  final String status;
}

class _HeadlessUser {
  const _HeadlessUser({
    required this.id,
    required this.username,
    required this.role,
    required this.createdAt,
  });

  factory _HeadlessUser.admin() {
    return _HeadlessUser(
      id: 1,
      username: 'admin',
      role: 'admin',
      createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  final int id;
  final String username;
  final String role;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'role': role,
        'createdAt': createdAt.toIso8601String(),
      };
}

class _HeadlessResourceSnapshot {
  const _HeadlessResourceSnapshot({
    required this.generatedAt,
    required this.roots,
    required this.items,
    required this.totalBytes,
  });

  factory _HeadlessResourceSnapshot.empty() {
    return _HeadlessResourceSnapshot(
      generatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      roots: const [],
      items: const [],
      totalBytes: 0,
    );
  }

  final DateTime generatedAt;
  final List<_HeadlessRootSummary> roots;
  final List<Map<String, dynamic>> items;
  final int totalBytes;

  String get signature {
    return [
      generatedAt.millisecondsSinceEpoch,
      roots.map((root) => '${root.path}:${root.exists}').join('|'),
    ].join(':');
  }

  Map<String, dynamic> toJson() => {
        'generatedAt': generatedAt.toIso8601String(),
        'roots': roots.map((root) => root.toJson()).toList(),
        'items': items,
        'itemCount': items.length,
        'comicCount': items.length,
        'totalBytes': totalBytes,
        'availableRootCount': roots.where((root) => root.exists).length,
        'missingRootCount': roots.where((root) => !root.exists).length,
        'signature': signature,
      };
}

class _HeadlessRootSummary {
  const _HeadlessRootSummary({
    required this.id,
    required this.title,
    required this.path,
    required this.exists,
    required this.itemCount,
    required this.totalBytes,
  });

  final String id;
  final String title;
  final String path;
  final bool exists;
  final int itemCount;
  final int totalBytes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'exists': exists,
        'itemCount': itemCount,
        'totalBytes': totalBytes,
      };
}