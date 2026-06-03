import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';

import '../server_config.dart';
import 'web_user_store.dart';

typedef JsonResponseBuilder = Response Function(
  Map<String, dynamic> body, {
  int statusCode,
});

class WebAuthHandler {
  WebAuthHandler({
    required PicaKeepServerConfig Function() configProvider,
    required WebConsoleUserStore userStore,
    required JsonResponseBuilder jsonResponse,
  })  : _configProvider = configProvider,
        _userStore = userStore,
        _jsonResponse = jsonResponse,
        _secret = _makeSecret();

  final PicaKeepServerConfig Function() _configProvider;
  final WebConsoleUserStore _userStore;
  final JsonResponseBuilder _jsonResponse;
  final String _secret;

  Future<Response?> handleLogin(Request request) async {
    if (request.url.path != 'api/console/login') {
      return null;
    }
    if (request.method != 'POST') {
      return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
    }
    final payload = await _readJsonMap(request);
    final requestedUsername = payload['username']?.toString().trim() ?? '';
    final username = requestedUsername.isEmpty ? 'admin' : requestedUsername;
    final password = payload['password']?.toString() ?? '';
    final configuredPassword = _configProvider().consolePassword;
    final isEmptyPassword = configuredPassword.trim().isEmpty;

    if (username == 'admin') {
      await _userStore.ensureAdmin(configuredPassword);
    }

    final user = _userStore.verifyLogin(username, password);
    if (user == null) {
      return _jsonResponse(
        {'ok': false, 'error': '用户名或密码错误'},
        statusCode: 401,
      );
    }
    return _jsonResponse({
      'ok': true,
      'token': tokenForUser(user),
      'emptyPassword': user.isAdmin && isEmptyPassword,
      'user': user.toJson(),
    });
  }

  WebConsoleUser? currentUser(Request request) {
    final token = _tokenFromRequest(request);
    if (token == null || token.isEmpty) {
      return null;
    }
    final payload = _decodeTokenPayload(token);
    if (payload == null) {
      return null;
    }
    final user = _userStore.findUserById(payload.userId);
    if (user == null) {
      return null;
    }
    if (!_constantTimeEquals(user.passwordHash, payload.passwordHash)) {
      return null;
    }
    if (!_constantTimeEquals(token, tokenForUser(user))) {
      return null;
    }
    return user;
  }

  bool isAuthorized(Request request) => currentUser(request) != null;

  bool isAdmin(Request request) => currentUser(request)?.isAdmin == true;

  String tokenForUser(WebConsoleUser user) {
    final payload = 'picakeep-console:${user.id}:${user.passwordHash}';
    final signature = base64Url.encode(
      Hmac(sha256, utf8.encode(_secret)).convert(utf8.encode(payload)).bytes,
    );
    return '${base64Url.encode(utf8.encode(payload))}.$signature';
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

  _TokenPayload? _decodeTokenPayload(String token) {
    final parts = token.split('.');
    if (parts.length != 2) {
      return null;
    }
    final encodedPayload = parts[0];
    final signature = parts[1];
    String payload;
    try {
      payload = utf8.decode(
        base64Url.decode(base64Url.normalize(encodedPayload)),
      );
    } catch (_) {
      return null;
    }
    final expectedSignature = base64Url.encode(
      Hmac(sha256, utf8.encode(_secret)).convert(utf8.encode(payload)).bytes,
    );
    if (!_constantTimeEquals(signature, expectedSignature)) {
      return null;
    }
    const prefix = 'picakeep-console:';
    if (!payload.startsWith(prefix)) {
      return null;
    }
    final values = payload.substring(prefix.length).split(':');
    if (values.length != 2) {
      return null;
    }
    final userId = int.tryParse(values[0]);
    final passwordHash = values[1];
    if (userId == null || passwordHash.isEmpty) {
      return null;
    }
    return _TokenPayload(userId: userId, passwordHash: passwordHash);
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

  static String _makeSecret() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  static bool _constantTimeEquals(String a, String b) {
    final aBytes = utf8.encode(a);
    final bBytes = utf8.encode(b);
    var diff = aBytes.length ^ bBytes.length;
    final maxLength =
        aBytes.length > bBytes.length ? aBytes.length : bBytes.length;
    for (var i = 0; i < maxLength; i++) {
      final av = i < aBytes.length ? aBytes[i] : 0;
      final bv = i < bBytes.length ? bBytes[i] : 0;
      diff |= av ^ bv;
    }
    return diff == 0;
  }
}

class _TokenPayload {
  const _TokenPayload({required this.userId, required this.passwordHash});

  final int userId;
  final String passwordHash;
}
