import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/pages/accounts/account_operation_scope.dart';
import 'package:picakeep/pages/online_comic/account_webview_login.dart';
import 'package:picakeep/pages/online_comic/nhentai_login_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

class _CancelledBrowser implements AccountLoginWebview {
  _CancelledBrowser(this.onClosed);
  final VoidCallback onClosed;
  @override
  bool get requiresLoginTransition => false;
  @override
  Future<void> open() async {}
  @override
  void requestClose() => onClosed();
  @override
  void dispose() => onClosed();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
      OperatingSystem.windows,
      () =>
          DynamicLibrary.open('${Directory.current.path}/windows/sqlite3.dll'));
  final originalPaths = PathProviderPlatform.instance;
  late Directory directory;
  late CookieJarSql jar;
  var counter = 0;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('picakeep_login_commit_');
    PathProviderPlatform.instance = _Paths(directory.path);
    SharedPreferences.setMockInitialValues({});
    await App.init(dataPathOverride: '${directory.path}/data');
  });
  setUp(() {
    jar = CookieJarSql('${directory.path}/cookies-${counter++}.db');
  });
  tearDown(() => jar.dispose());
  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  test(
      'failed credential save restores root cookies, identity, attributes and UA',
      () async {
    final uri = Uri.parse('https://e-hentai.org/');
    final other = Uri.parse('https://exhentai.org/');
    final expiry = DateTime(2099);
    jar.saveFromResponse(uri, [
      Cookie('ipb_member_id', 'old-id')
        ..domain = 'e-hentai.org'
        ..path = '/',
      Cookie('ipb_pass_hash', 'old-hash')
        ..domain = '.e-hentai.org'
        ..path = '/'
        ..secure = true
        ..httpOnly = true
        ..expires = expiry,
      Cookie('nw', '1')..path = '/',
    ]);
    final originalUa = appdata.implicitData[3];
    final source = ComicSource.named(key: 'test-eh', name: 'Test', data: {
      'token': 'old-token',
      'name': 'old-name',
      'preference': 'keep',
    });
    var attempts = 0;
    final writes = <Map<String, dynamic>>[];
    source.writeDataFile = (path, value) async {
      attempts++;
      if (attempts == 1) throw StateError('disk failure');
      writes.add(jsonDecode(value) as Map<String, dynamic>);
    };
    await expectLater(
        persistAccountCookies(
          jar: jar,
          source: source,
          replacements: {
            uri: {'ipb_member_id': 'new-id', 'ipb_pass_hash': 'new-hash'},
            other: {'ipb_member_id': 'new-id', 'ipb_pass_hash': 'new-hash'},
          },
          identityCookieNames: const {
            'ipb_member_id',
            'ipb_pass_hash',
            'igneous'
          },
          userAgent: 'new-ua',
          authenticate: () async => {'token': 'new-token', 'name': 'new-name'},
        ),
        throwsA(isA<StateError>()));
    expect(source.data, {
      'token': 'old-token',
      'name': 'old-name',
      'preference': 'keep',
    });
    expect(writes.single, source.data);
    expect(appdata.implicitData[3], originalUa);
    final saved = jar.loadForRequest(uri);
    expect(saved.singleWhere((c) => c.name == 'ipb_member_id').value, 'old-id');
    final hash = saved.singleWhere((c) => c.name == 'ipb_pass_hash');
    expect(hash.value, 'old-hash');
    expect(hash.domain, '.e-hentai.org');
    expect(hash.path, '/');
    expect(hash.secure, isTrue);
    expect(hash.httpOnly, isTrue);
    expect(hash.expires, expiry);
    expect(saved.singleWhere((c) => c.name == 'nw').value, '1');
    expect(jar.loadForRequest(other), isEmpty);
  });

  test(
      'credential commit Future stays pending until the source writer completes',
      () async {
    final uri = Uri.parse('https://nhentai.net/');
    final source = ComicSource.named(key: 'test-nh', name: 'Test');
    final writer = Completer<void>();
    source.writeDataFile = (_, __) => writer.future;
    var completed = false;
    final task = persistAccountCookies(
      jar: jar,
      source: source,
      replacements: {
        uri: {'access_token': 'new-access'}
      },
      identityCookieNames: const {'access_token', 'refresh_token'},
      authenticate: () async => {'token': 'ok'},
    ).then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    writer.complete();
    await task;
    expect(completed, isTrue);
  });

  testWidgets('real NH page cancellation leaves pre-existing app JWT untouched',
      (tester) async {
    final originalSources = List<ComicSource>.of(ComicSource.sources);
    final originalShared = SingleInstanceCookieJar.instance;
    final network = NhentaiNetwork();
    final originalJar = network.cookieJar;
    final originalLogged = network.logged;
    SingleInstanceCookieJar.instance = null;
    final shared = SingleInstanceCookieJar('${directory.path}/old-session.db');
    network.cookieJar = shared;
    network.logged = false;
    final uri = Uri.parse('https://nhentai.net/');
    shared.saveFromResponse(uri, [
      Cookie('access_token', 'old-access')
        ..domain = '.nhentai.net'
        ..path = '/',
      Cookie('refresh_token', 'old-refresh')
        ..domain = '.nhentai.net'
        ..path = '/',
    ]);
    final source = ComicSource.named(key: 'nhentai', name: 'Nhentai');
    var writes = 0;
    source.writeDataFile = (_, __) async {
      writes++;
    };
    ComicSource.sources
      ..clear()
      ..add(source);
    final operations = AccountOperationController();
    addTearDown(() {
      operations.dispose();
      ComicSource.sources
        ..clear()
        ..addAll(originalSources);
      network.cookieJar = originalJar;
      network.logged = originalLogged;
      shared.dispose();
      SingleInstanceCookieJar.instance = originalShared;
    });
    late _CancelledBrowser browser;
    await tester.pumpWidget(MaterialApp(
        home: AccountOperationScope(
      controller: operations,
      child: NhentaiLoginPage(
        prepareWebview: () async {},
        webviewFactory: (context, url, event, close) =>
            browser = _CancelledBrowser(close),
      ),
    )));
    await tester.tap(find.text('在 Webview 中登录'));
    await tester.pump();
    browser.requestClose();
    await tester.pump();
    expect(source.isLoggedIn, isFalse);
    expect(network.logged, isFalse);
    expect(writes, 0);
    expect(shared.loadForRequest(uri).map((c) => c.value),
        unorderedEquals(['old-access', 'old-refresh']));
    expect(find.byType(NhentaiLoginPage), findsOneWidget);
    expect(find.text('登录成功'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
