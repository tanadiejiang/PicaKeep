import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'admin_web.dart';
import 'local_resource_scanner.dart';
import 'server_config.dart';
import 'server_runtime_state.dart';

class PicaKeepAdminServer {
  PicaKeepAdminServer({
    required this.configPath,
    ServerRuntimeState? runtimeState,
  }) : _state = runtimeState ?? ServerRuntimeState();

  final String configPath;
  final ServerRuntimeState _state;
  final LocalResourceScanner _scanner = LocalResourceScanner();

  PicaKeepServerConfig? _config;
  ServerResourceSnapshot? _snapshot;
  HttpServer? _server;

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
      _snapshot = await _scanResources();
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
    _snapshot = snapshot;
    _state.addLog('scan', '已重新扫描本地资源');
    return snapshot;
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
          return await innerHandler(request);
        } finally {
          _state.endRequest();
        }
      };
    };
  }

  Future<Response> _handleRequest(Request request) async {
    final path = request.url.path;
    if (path.isEmpty) {
      return Response.movedPermanently('/admin');
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
    if (path == 'admin') {
      return Response.ok(
        buildAdminConsoleHtml(),
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }
    if (path == 'api/admin/summary') {
      return _jsonResponse(buildSummaryPayload());
    }
    if (path == 'api/admin/resources') {
      return _jsonResponse((_snapshot ?? await _scanResources()).toJson());
    }
    if (path == 'api/admin/config') {
      if (request.method == 'GET') {
        return _jsonResponse((_config ?? PicaKeepServerConfig.defaults()).toJson());
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
        _snapshot = await _scanResources();
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
        'totalComicCount': snapshot.totalComicCount,
        'totalBytes': snapshot.totalBytes,
        'roots': snapshot.roots.map(_buildLibraryRootPayload).toList(),
        'items': snapshot.items.map(_buildLibraryItemPayload).toList(),
      });
    }

    final itemId = Uri.decodeComponent(segments[3]);
    final item = snapshot.findItemById(itemId);
    if (item == null) {
      return _jsonResponse({'error': 'item not found'}, statusCode: 404);
    }

    if (segments.length == 4) {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _jsonResponse(_buildLibraryItemPayload(item, includePages: true));
    }

    if (segments.length == 5 && segments[4] == 'cover') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final coverPath = item.coverPath;
      if (coverPath == null || coverPath.trim().isEmpty) {
        return _jsonResponse({'error': 'cover not found'}, statusCode: 404);
      }
      return _fileResponse(request, File(coverPath));
    }

    if (segments.length == 6 && segments[4] == 'episodes') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final episodeIndex = int.tryParse(segments[5]);
      if (episodeIndex == null) {
        return _jsonResponse({'error': 'invalid episode'}, statusCode: 400);
      }
      final episode = _findEpisode(item, episodeIndex);
      if (episode == null) {
        return _jsonResponse({'error': 'episode not found'}, statusCode: 404);
      }
      return _jsonResponse(
        _buildLibraryEpisodePayload(item.id, episode, includePages: true),
      );
    }

    if (segments.length == 7 && segments[4] == 'images') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final episodeIndex = int.tryParse(segments[5]);
      final pageIndex = int.tryParse(segments[6]);
      if (episodeIndex == null || pageIndex == null) {
        return _jsonResponse({'error': 'invalid image target'}, statusCode: 400);
      }
      final episode = _findEpisode(item, episodeIndex);
      if (episode == null) {
        return _jsonResponse({'error': 'episode not found'}, statusCode: 404);
      }
      if (pageIndex < 0 || pageIndex >= episode.imagePaths.length) {
        return _jsonResponse({'error': 'page not found'}, statusCode: 404);
      }
      return _fileResponse(request, File(episode.imagePaths[pageIndex]));
    }

    return _jsonResponse({'error': 'not found'}, statusCode: 404);
  }

  Future<ServerResourceSnapshot> _currentSnapshot() async {
    final snapshot = _snapshot;
    if (snapshot != null) {
      return snapshot;
    }
    final nextSnapshot = await _scanResources();
    _snapshot = nextSnapshot;
    return nextSnapshot;
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

  Map<String, dynamic> _buildLibraryRootPayload(
    ServerResourceRootSummary root,
  ) {
    return {
      'id': root.id,
      'title': root.title,
      'path': root.path,
      'exists': root.exists,
      'itemCount': root.itemCount,
      'totalBytes': root.totalBytes,
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
      'subtitle': item.subtitle,
      'tags': item.tags,
      'path': item.path,
      'imageCount': item.imageCount,
      'totalBytes': item.totalBytes,
      'coverUrl': '/api/library/items/$encodedId/cover',
      'detailUrl': '/api/library/items/$encodedId',
      'episodeCount': item.episodes.length,
      'hasMultipleEpisodes': item.hasMultipleEpisodes,
      'episodes': item.episodes
          .map(
            (episode) => _buildLibraryEpisodePayload(
              item.id,
              episode,
              includePages: includePages,
            ),
          )
          .toList(),
    };
  }

  Map<String, dynamic> _buildLibraryEpisodePayload(
    String itemId,
    ServerResourceEpisodeSummary episode, {
    bool includePages = false,
  }) {
    final encodedId = Uri.encodeComponent(itemId);
    return {
      'index': episode.index,
      'title': episode.title,
      'path': episode.path,
      'imageCount': episode.imageCount,
      'totalBytes': episode.totalBytes,
      'coverUrl': '/api/library/items/$encodedId/cover',
      if (includePages)
        'pages': [
          for (var i = 0; i < episode.imagePaths.length; i++)
            '/api/library/items/$encodedId/images/${episode.index}/$i',
        ],
    };
  }

  Future<Response> _fileResponse(Request request, File file) async {
    if (!await file.exists()) {
      return _jsonResponse({'error': 'file not found'}, statusCode: 404);
    }

    final length = await file.length();
    final headers = <String, String>{
      HttpHeaders.contentTypeHeader: _contentTypeForPath(file.path),
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
          body: file.openRead(start, end + 1),
          headers: {
            ...headers,
            HttpHeaders.contentLengthHeader: chunkLength.toString(),
            HttpHeaders.contentRangeHeader: 'bytes $start-$end/$length',
          },
        );
      }
    }

    return Response.ok(
      file.openRead(),
      headers: {
        ...headers,
        HttpHeaders.contentLengthHeader: length.toString(),
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
      'statusUrl': _buildStatusUrl(),
      'adminUrl': _buildAdminUrl(),
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
    return 'http://${_buildDisplayHost(config.host)}:$port/admin';
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
}