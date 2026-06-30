part of 'server_app.dart';

extension ServerAppRouting on PicaKeepAdminServer {
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
    if (path == 'api/events' || path == 'api/library') {
      return false;
    }
    if (path.startsWith('api/library/')) {
      return false;
    }
    return path.startsWith('api/admin/') ||
        path.startsWith('api/console/') ||
        path == 'api/remote/proxy';
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
    if (path == 'api/admin/browse') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _handleAdminBrowse(request);
    }
    if (path == 'api/admin/config') {
      if (request.method == 'GET') {
        return _jsonResponse(_configPayload());
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
        await reloadManagedDataStoresForServerConfig(_config!);
        await _webUserStore.ensureAdmin(_config!.consolePassword);
        _setSnapshot(await _scanResources(), emitEvent: true);
        _state.addLog('config', '配置已更新');
        return _jsonResponse({
          'ok': true,
          'message': '配置已保存，host/port 改动重启后完全生效',
          'config': _configPayload(),
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

  void _handleEventSocket(WebSocketChannel channel, [String? protocol]) {
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
}
