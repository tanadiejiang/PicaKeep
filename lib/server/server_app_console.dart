part of 'server_app.dart';

extension ServerAppConsole on PicaKeepAdminServer {
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
        return _jsonResponse({'error': 'old password mismatch'},
            statusCode: 403);
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
          'users':
              _webUserStore.listUsers().map((entry) => entry.toJson()).toList(),
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
}
