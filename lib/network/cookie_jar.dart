import 'dart:io';

import 'package:dio/dio.dart';
import 'package:sqlite3/sqlite3.dart';

class CookieJarSql {
  CookieJarSql(this.path) {
    init();
  }

  late Database _db;
  final String path;

  void init() {
    File(path).parent.createSync(recursive: true);
    _db = sqlite3.open(path);
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cookies (
        name TEXT NOT NULL,
        value TEXT NOT NULL,
        domain TEXT NOT NULL,
        path TEXT,
        expires INTEGER,
        secure INTEGER,
        httpOnly INTEGER,
        PRIMARY KEY (name, domain, path)
      );
    ''');
  }

  void saveFromResponse(Uri uri, List<Cookie> cookies) {
    final current = loadForRequest(uri);
    for (final cookie in cookies) {
      final currentCookie = current.where((element) {
        final cookiePath = cookie.path;
        return element.name == cookie.name &&
            (cookiePath == null ||
                cookiePath.isEmpty ||
                cookiePath.startsWith(element.path ?? '/'));
      }).firstOrNull;
      if (currentCookie != null) {
        cookie.domain = currentCookie.domain;
      }
      _db.execute('''
        INSERT OR REPLACE INTO cookies
          (name, value, domain, path, expires, secure, httpOnly)
        VALUES (?, ?, ?, ?, ?, ?, ?);
      ''', [
        cookie.name,
        cookie.value,
        cookie.domain ?? uri.host,
        cookie.path?.isEmpty == true ? '/' : cookie.path ?? '/',
        cookie.expires?.millisecondsSinceEpoch,
        cookie.secure ? 1 : 0,
        cookie.httpOnly ? 1 : 0,
      ]);
    }
  }

  List<Cookie> _loadWithDomain(String domain) {
    final rows = _db.select('''
      SELECT name, value, domain, path, expires, secure, httpOnly
      FROM cookies
      WHERE domain = ?;
    ''', [domain]);

    return rows.map((row) {
      return Cookie(row['name'] as String, row['value'] as String)
        ..domain = row['domain'] as String
        ..path = row['path'] as String? ?? '/'
        ..expires = row['expires'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['expires'] as int)
        ..secure = row['secure'] == 1
        ..httpOnly = row['httpOnly'] == 1;
    }).toList();
  }

  List<String> _getAcceptedDomains(String host) {
    final acceptedDomains = <String>[host];
    final hostParts = host.split('.');
    for (var i = 0; i < hostParts.length - 1; i++) {
      acceptedDomains.add('.${hostParts.sublist(i).join('.')}');
    }
    return acceptedDomains;
  }

  List<Cookie> loadForRequest(Uri uri) {
    final cookies = <Cookie>[];
    for (final domain in _getAcceptedDomains(uri.host)) {
      cookies.addAll(_loadWithDomain(domain));
    }

    final expired = cookies
        .where((cookie) =>
            cookie.expires != null && cookie.expires!.isBefore(DateTime.now()))
        .toSet();
    for (final cookie in expired) {
      _db.execute('''
        DELETE FROM cookies
        WHERE name = ? AND domain = ? AND path = ?;
      ''', [cookie.name, cookie.domain, cookie.path]);
    }

    return cookies
        .where((cookie) =>
            !expired.contains(cookie) && _checkPathMatch(uri, cookie.path))
        .toList();
  }

  bool _checkPathMatch(Uri uri, String? cookiePath) {
    if (cookiePath == null || cookiePath == '/') {
      return true;
    }
    if (cookiePath == uri.path) {
      return true;
    }
    if (cookiePath.endsWith('/')) {
      return uri.path.startsWith(cookiePath);
    }
    return uri.path.startsWith(cookiePath);
  }

  void saveFromResponseCookieHeader(Uri uri, List<String> cookieHeader) {
    final cookies = <Cookie>[];
    for (final header in cookieHeader) {
      try {
        cookies.add(Cookie.fromSetCookieValue(header));
      } catch (_) {}
    }
    saveFromResponse(uri, cookies);
  }

  String loadForRequestCookieHeader(Uri uri) {
    final map = <String, Cookie>{};
    for (final cookie in loadForRequest(uri)) {
      final current = map[cookie.name];
      if (current == null) {
        map[cookie.name] = cookie;
        continue;
      }
      final domain = cookie.domain ?? '';
      final currentDomain = current.domain ?? '';
      if (!domain.startsWith('.') && currentDomain.startsWith('.')) {
        map[cookie.name] = cookie;
      } else if (domain.length > currentDomain.length) {
        map[cookie.name] = cookie;
      }
    }
    return map.values
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
  }

  void delete(Uri uri, String name) {
    for (final domain in _getAcceptedDomains(uri.host)) {
      _db.execute('''
        DELETE FROM cookies
        WHERE name = ? AND domain = ? AND path = ?;
      ''', [name, domain, uri.path]);
    }
  }

  void deleteUri(Uri uri) {
    for (final domain in _getAcceptedDomains(uri.host)) {
      _db.execute('''
        DELETE FROM cookies
        WHERE domain = ?;
      ''', [domain]);
    }
  }

  void deleteAll() {
    _db.execute('DELETE FROM cookies;');
  }

  void dispose() {
    _db.dispose();
  }
}

class SingleInstanceCookieJar extends CookieJarSql {
  factory SingleInstanceCookieJar(String path) =>
      instance ??= SingleInstanceCookieJar._create(path);

  SingleInstanceCookieJar._create(super.path);

  static SingleInstanceCookieJar? instance;
}

class CookieManagerSql extends Interceptor {
  CookieManagerSql(this.cookieJar);

  final CookieJarSql cookieJar;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final cookies = cookieJar.loadForRequestCookieHeader(options.uri);
    if (cookies.isNotEmpty) {
      options.headers['cookie'] = cookies;
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    cookieJar.saveFromResponseCookieHeader(
      response.requestOptions.uri,
      response.headers['set-cookie'] ?? const <String>[],
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    handler.next(err);
  }
}
