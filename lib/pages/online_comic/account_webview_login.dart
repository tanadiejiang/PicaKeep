import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/pages/accounts/account_operation_scope.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'webview.dart';
import 'webview_login_round.dart';

class AccountLoginCandidate {
  AccountLoginCandidate(Map<String, String> cookies, this.userAgent)
      : cookies = Map.unmodifiable(cookies);

  final Map<String, String> cookies;
  final String? userAgent;
}

typedef AccountLoginSubmit = Future<void> Function(AccountLoginCandidate);
typedef AccountLoginTitle = void Function(String, AccountLoginReader);
typedef AccountLoginWebviewFactory = AccountLoginWebview Function(
  BuildContext context,
  String url,
  AccountLoginTitle onTitle,
  VoidCallback onClosed,
);

abstract interface class AccountLoginReader {
  Future<Map<String, String>> cookies(String url);
  Future<String?> userAgent();
}

abstract interface class AccountLoginWebview {
  bool get requiresLoginTransition;
  Future<void> open();
  void requestClose();
  void dispose();
}

AccountLoginWebview createAccountLoginWebview(BuildContext context, String url,
    AccountLoginTitle onTitle, VoidCallback onClosed) {
  if (App.isMobile) {
    return createRouteAccountLoginWebview(context, url, onTitle, onClosed);
  }
  return _DesktopLoginWebview(url, onTitle, onClosed);
}

@visibleForTesting
AccountLoginWebview createRouteAccountLoginWebview(BuildContext context,
    String url, AccountLoginTitle onTitle, VoidCallback onClosed,
    {Widget Function(AccountLoginTitle)? pageBuilder}) {
  return _MobileLoginWebview(
      Navigator.of(context, rootNavigator: true), url, onTitle, onClosed,
      pageBuilder: pageBuilder);
}

class _LoginRoute extends MaterialPageRoute<void> {
  _LoginRoute({required super.builder, required this.onClosed});

  final VoidCallback onClosed;

  @override
  bool didPop(Object? result) {
    final popped = super.didPop(null);
    if (popped) onClosed();
    return popped;
  }

  @override
  void dispose() {
    onClosed();
    super.dispose();
  }
}

class _MobileLoginWebview implements AccountLoginWebview {
  _MobileLoginWebview(this.navigator, this.url, this.onTitle, this.onClosed,
      {this.pageBuilder});

  final NavigatorState navigator;
  final String url;
  final AccountLoginTitle onTitle;
  final VoidCallback onClosed;
  final Widget Function(AccountLoginTitle)? pageBuilder;
  _LoginRoute? _route;
  bool _disposed = false;
  bool _closed = false;

  @override
  bool get requiresLoginTransition => true;

  void _finish() {
    if (_closed) return;
    _closed = true;
    onClosed();
  }

  @override
  Future<void> open() async {
    if (_disposed) {
      _finish();
      return;
    }
    final route = _LoginRoute(
      onClosed: _finish,
      builder: (_) =>
          pageBuilder?.call(onTitle) ??
          AppWebview(
            initialUrl: url,
            singlePage: true,
            onTitleChange: (title, controller) {
              if (_closed) return;
              onTitle(
                  title,
                  _CallbackLoginReader(
                    (url) async => await controller.getCookies(url) ?? {},
                    controller.getUA,
                  ));
            },
          ),
    );
    _route = route;
    unawaited(navigator.push<void>(route).then((_) => _finish()));
  }

  @override
  void requestClose() {
    scheduleMicrotask(() {
      final route = _route;
      if (!_closed && navigator.mounted && route != null && route.isCurrent) {
        navigator.pop();
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    scheduleMicrotask(() {
      final route = _route;
      if (!_closed && navigator.mounted && route != null && route.isActive) {
        navigator.removeRoute(route);
      }
      _finish();
    });
  }
}

class _CallbackLoginReader implements AccountLoginReader {
  _CallbackLoginReader(this.readCookies, this.readUserAgent);
  final Future<Map<String, String>> Function(String) readCookies;
  final Future<String?> Function() readUserAgent;
  @override
  Future<Map<String, String>> cookies(String url) => readCookies(url);
  @override
  Future<String?> userAgent() => readUserAgent();
}

class _DesktopLoginWebview implements AccountLoginWebview {
  _DesktopLoginWebview(this.url, this.onTitle, this.onClosed);
  final String url;
  final AccountLoginTitle onTitle;
  final VoidCallback onClosed;
  DesktopWebview? _window;
  bool _closeRequested = false;
  bool _closed = false;

  @override
  bool get requiresLoginTransition => false;

  void _finish() {
    if (_closed) return;
    _closed = true;
    onClosed();
  }

  @override
  Future<void> open() async {
    if (!await DesktopWebview.isAvailable()) {
      throw StateError('当前设备不支持 Webview 登录'.tl);
    }
    if (_closeRequested) {
      _finish();
      return;
    }
    final window = DesktopWebview(
      initialUrl: url,
      onClose: _finish,
      onTitleChange: (title, controller) {
        if (_closed || _closeRequested) return;
        onTitle(
            title,
            _CallbackLoginReader(
              controller.getCookies,
              () async => controller.userAgent,
            ));
      },
    );
    _window = window;
    await window.open();
  }

  @override
  void requestClose() {
    if (_closeRequested) return;
    _closeRequested = true;
    final window = _window;
    if (window == null) {
      _finish();
    } else {
      unawaited(window.close());
    }
  }

  @override
  void dispose() => requestClose();
}

enum AccountLoginSite { ehentai, nhentai }

/// A session owns candidate reads; platform callbacks never persist credentials.
class AccountWebLoginSession {
  AccountWebLoginSession({
    required this.site,
    required this.operations,
    required this.changed,
  });

  final AccountLoginSite site;
  final AccountOperationController operations;
  final VoidCallback changed;
  final WebviewLoginRound _round = WebviewLoginRound();
  final Completer<void> _closed = Completer<void>();
  AccountLoginWebview? _webview;
  AccountLoginCandidate? _candidate;
  Object? _error;
  bool _cancelled = false;
  bool _seenLoginPage = false;

  bool get active => !_closed.isCompleted;

  void _didClose() {
    _round.markClosed();
    if (!_closed.isCompleted) _closed.complete();
    changed();
  }

  void requestClose() {
    if (!_round.requestClose()) return;
    _webview?.requestClose();
  }

  void cancel() {
    _cancelled = true;
    _candidate = null;
    _round.markClosed();
    _webview?.dispose();
  }

  Future<AccountLoginCandidate?> collect(BuildContext context, String url,
      AccountLoginWebviewFactory factory) async {
    final id = _round.begin();
    final webview = factory(context, url, (title, reader) {
      unawaited(_readCandidate(id, title, reader));
    }, _didClose);
    _webview = webview;
    operations.registerWebview(this, requestClose);
    try {
      await webview.open();
      await _closed.future;
      if (_cancelled) return null;
      if (_error != null) throw _error!;
      if (_candidate == null) return null;
      return _round.beginCommit(id) ? _candidate : null;
    } finally {
      _round.markClosed();
      operations.unregisterWebview(this);
      webview.dispose();
    }
  }

  Future<void> _readCandidate(
      int id, String title, AccountLoginReader reader) async {
    if (!_round.canAccept(id)) return;
    final isLogin = title.contains('Login') || title.contains('Register');
    if (site == AccountLoginSite.nhentai && isLogin) {
      _seenLoginPage = true;
      return;
    }
    if (site == AccountLoginSite.ehentai && title != 'E-Hentai Forums') return;
    if (!_round.beginHarvest(id)) return;
    try {
      final Map<String, String> cookies;
      if (site == AccountLoginSite.ehentai) {
        final normal = await reader.cookies('https://e-hentai.org/');
        if (!_round.canAccept(id)) return;
        final ex = await reader.cookies('https://exhentai.org/');
        cookies = {...normal, ...ex};
      } else {
        cookies = await reader.cookies('https://nhentai.net/');
      }
      if (!_round.canAccept(id)) return;
      final ua = await reader.userAgent();
      if (!_round.canAccept(id)) return;
      final valid = site == AccountLoginSite.ehentai
          ? (cookies['ipb_member_id']?.isNotEmpty == true &&
              cookies['ipb_pass_hash']?.isNotEmpty == true)
          : (cookies['access_token']?.isNotEmpty == true ||
              cookies['refresh_token']?.isNotEmpty == true);
      if (!valid) return;
      if (site == AccountLoginSite.nhentai &&
          _webview!.requiresLoginTransition &&
          (!_seenLoginPage || isLogin)) {
        return;
      }
      _candidate = AccountLoginCandidate(cookies, ua);
      requestClose();
    } catch (error) {
      if (_round.canAccept(id)) {
        _error = error;
        requestClose();
      }
    } finally {
      _round.endHarvest();
    }
  }
}

/// Shared UI ownership, while each source keeps its own authentication protocol.
abstract class AccountCookieLoginState<T extends StatefulWidget>
    extends State<T> {
  String get sourceKey;
  AccountOperationController? _operations;
  AccountOperationController? _localOperations;
  AccountWebLoginSession? webSession;
  Future<void>? _pending;
  bool _disposing = false;
  bool logging = false;
  String? loginError;

  AccountOperationController get operations => _operations!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _operations ??= AccountOperationScope.maybeOf(context) ??
        (_localOperations = AccountOperationController());
  }

  Future<void> runLogin(Future<bool> Function() action) async {
    if (logging) return;
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    setState(() {
      logging = true;
      loginError = null;
    });
    final task = () async {
      try {
        final success = await operations.execute<bool>(sourceKey, action,
            operation: 'login');
        if (success && mounted && route?.isCurrent == true) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('登录成功'.tl)));
          navigator.pop(true);
        }
      } catch (error) {
        if (mounted) setState(() => loginError = error.toString());
      } finally {
        if (mounted) setState(() => logging = false);
      }
    }();
    _pending = task;
    await task;
  }

  Future<bool> collectAndSubmit({
    required AccountLoginSite site,
    required String url,
    required AccountLoginWebviewFactory factory,
    required AccountLoginSubmit submit,
    Future<void> Function()? prepare,
  }) async {
    final route = ModalRoute.of(context);
    if (prepare != null) await prepare();
    if (!mounted || route?.isCurrent != true) return false;
    final session = AccountWebLoginSession(
      site: site,
      operations: operations,
      changed: () {
        if (mounted && !_disposing) setState(() {});
      },
    );
    setState(() => webSession = session);
    try {
      final candidate = await session.collect(context, url, factory);
      if (!mounted || route?.isCurrent != true) return false;
      if (candidate == null) {
        throw StateError('未检测到本次登录会话，请重试'.tl);
      }
      await submit(candidate);
      return true;
    } finally {
      if (mounted) setState(() => webSession = null);
    }
  }

  Widget withLoginBackHandling(Widget child) => PopScope(
        canPop: webSession?.active != true,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) webSession?.requestClose();
        },
        child: child,
      );

  @override
  void dispose() {
    _disposing = true;
    webSession?.cancel();
    final local = _localOperations;
    if (local != null) {
      final pending = _pending;
      if (pending == null) {
        local.dispose();
      } else {
        unawaited(pending.whenComplete(local.dispose));
      }
    }
    super.dispose();
  }
}

/// Compensate only the source's replaced root cookies and identity fields.
Future<void> persistAccountCookies({
  required CookieJarSql jar,
  required ComicSource source,
  required Map<Uri, Map<String, String>> replacements,
  required Set<String> identityCookieNames,
  required Future<Map<String, String>> Function() authenticate,
  String? userAgent,
}) async {
  final values = <Uri, List<Cookie>>{};
  final names = <Uri, Set<String>>{};
  final before = <Uri, List<Cookie>>{};
  for (final entry in replacements.entries) {
    names[entry.key] = {...identityCookieNames, ...entry.value.keys};
    values[entry.key] = [
      for (final cookie in entry.value.entries)
        Cookie(cookie.key, cookie.value)
          ..domain = '.${entry.key.host}'
          ..path = '/',
    ];
    before[entry.key] = jar
        .loadForRequest(entry.key)
        .where((cookie) =>
            cookie.path == '/' && names[entry.key]!.contains(cookie.name))
        .toList();
  }
  final previousIdentity = <String, dynamic>{
    for (final key in ['token', 'name'])
      if (source.data.containsKey(key)) key: source.data[key],
  };
  final previousUa = appdata.implicitData[3];
  var saveAttempted = false;
  SharedPreferences? preferences;
  try {
    for (final uri in replacements.keys) {
      for (final name in names[uri]!) {
        jar.delete(uri, name);
      }
      jar.saveFromResponse(uri, values[uri]!);
    }
    if (userAgent?.isNotEmpty == true) appdata.implicitData[3] = userAgent!;
    final identity = await authenticate();
    source.data.addAll(identity);
    saveAttempted = true;
    await source.saveData();
    if (userAgent?.isNotEmpty == true) {
      preferences = await SharedPreferences.getInstance();
      if (!await preferences.setStringList(
          'implicitData', appdata.implicitData)) {
        throw StateError('登录资料保存失败，请重试'.tl);
      }
    }
  } catch (error) {
    appdata.implicitData[3] = previousUa;
    source.data
      ..remove('token')
      ..remove('name')
      ..addAll(previousIdentity);
    try {
      for (final uri in replacements.keys) {
        for (final name in names[uri]!) {
          jar.delete(uri, name);
        }
        jar.saveFromResponse(uri, before[uri]!);
      }
      if (saveAttempted) await source.saveData();
      if (preferences != null &&
          !await preferences.setStringList(
              'implicitData', appdata.implicitData)) {
        throw StateError('Failed to restore login User-Agent');
      }
    } catch (_) {
      throw StateError('登录保存失败，原状态未能完整恢复，请重试'.tl);
    }
    rethrow;
  }
}
