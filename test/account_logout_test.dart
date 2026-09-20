import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/accounts/login_page.dart';
import 'package:sqlite3/open.dart';

/// A08 / A09 / A18：退出白名单与文件回读、NH 根路径 JWT 清除、注册入口。
///
/// 退出路径只做本地清理（不发起网络请求），因此可以用真实内置源 + 临时目录验证。

class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  open.overrideFor(
    OperatingSystem.windows,
    () => DynamicLibrary.open(
      '${Directory.current.path}${Platform.pathSeparator}windows'
      '${Platform.pathSeparator}sqlite3.dll',
    ),
  );

  late Directory workspace;
  final PathProviderPlatform originalPaths = PathProviderPlatform.instance;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_logout_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    try {
      if (await workspace.exists()) {
        await workspace.delete(recursive: true);
      }
    } catch (_) {
      // 单例 jar 仍持有文件句柄时清理失败不影响断言。
    }
  });

  /// 从磁盘重新读回同一个 key 的源数据（不依赖内存里的实例）。
  Future<ComicSource> reloadFromDisk(String key) async {
    final fresh = ComicSource.named(key: key, name: key);
    await fresh.loadData();
    return fresh;
  }

  group('A08 退出白名单', () {
    test('Picacg 退出清 token/user/account，偏好保留且重启读回一致', () async {
      await ComicSource.init();
      final source = ComicSource.require('picacg');
      source.data.addAll(<String, dynamic>{
        'token': 'token-value',
        'user': <String, dynamic>{'name': 'someone'},
        'account': <String>['user@example.com', 'pw'],
        'appChannel': '3',
        'imageQuality': 'original',
      });
      await source.saveData();

      await source.account!.logout!();

      // 内存
      expect(source.data.containsKey('token'), isFalse);
      expect(source.data.containsKey('user'), isFalse);
      expect(source.data.containsKey('account'), isFalse);
      expect(source.data['appChannel'], '3');
      expect(source.data['imageQuality'], 'original');
      expect(source.isLoggedIn, isFalse);

      // 磁盘回读：凭据确实已从文件消失，而不是只改了内存标记
      final reloaded = await reloadFromDisk('picacg');
      expect(reloaded.data.containsKey('token'), isFalse);
      expect(reloaded.data.containsKey('account'), isFalse);
      expect(reloaded.data['appChannel'], '3');
      expect(reloaded.data['imageQuality'], 'original');
    });

    test('JM 退出清 token/account/name/uid', () async {
      await ComicSource.init();
      final source = ComicSource.require('jm');
      source.data.addAll(<String, dynamic>{
        'token': 'logged_in',
        'account': <String>['user', 'pw'],
        'name': '昵称',
        'uid': '4215436',
      });
      await source.saveData();

      await source.account!.logout!();

      expect(source.data.containsKey('token'), isFalse);
      expect(source.data.containsKey('account'), isFalse);
      expect(source.data.containsKey('name'), isFalse);
      expect(source.data.containsKey('uid'), isFalse);

      final reloaded = await reloadFromDisk('jm');
      expect(reloaded.data.containsKey('name'), isFalse);
      expect(reloaded.data.containsKey('uid'), isFalse);
    });

    test('EH 退出清显示快照（id/hash/igneous/cookiesStr）', () async {
      await ComicSource.init();
      final source = ComicSource.require('ehentai');
      final net = EhNetwork();
      net.id = 'old-id';
      net.hash = 'old-hash';
      net.igneous = 'old-igneous';
      net.cookiesStr = 'ipb_member_id=old-id';
      source.data.addAll(<String, dynamic>{'token': 'ok', 'name': 'old-name'});

      await source.account!.logout!();

      expect(net.id, isEmpty);
      expect(net.hash, isEmpty);
      expect(net.igneous, isEmpty);
      expect(net.cookiesStr, isEmpty);
      expect(source.data.containsKey('token'), isFalse);
      expect(source.data.containsKey('name'), isFalse);
    });
  });

  group('A09 NH 根路径 JWT 清除', () {
    test('冷启动退出后首次请求仍会初始化 Dio，且不会访问网络', () async {
      final jar = SingleInstanceCookieJar(
        '${workspace.path}${Platform.pathSeparator}nh_cold.db',
      );
      final network = NhentaiNetwork();
      network.cookieJar = null;
      network.logged = true;
      final uri = Uri.parse('https://nhentai.net/');
      jar.saveFromResponse(uri, <Cookie>[
        Cookie('access_token', 'test-access')..path = '/',
        Cookie('refresh_token', 'test-refresh')..path = '/',
      ]);

      await network.logout();
      expect(network.cookieJar, isNull);
      expect(network.logged, isFalse);
      expect(jar.loadForRequest(uri), isEmpty);

      final result = await HttpOverrides.runZoned(
        () => network.get('https://account-probe.invalid/'),
        createHttpClient: (_) => throw StateError('offline test transport'),
      );
      expect(result.error, isTrue);
      expect(result.errorMessage, isNot(contains('LateInitializationError')));
    });

    test('退出清根路径 host/点域 JWT，其它 Cookie 保留', () async {
      final jar = SingleInstanceCookieJar(
        '${workspace.path}${Platform.pathSeparator}nh_shared.db',
      );
      final network = NhentaiNetwork();
      network.cookieJar = jar;

      final uri = Uri.parse('https://nhentai.net/');
      jar.saveFromResponse(uri, <Cookie>[
        Cookie('access_token', 'a')
          ..domain = 'nhentai.net'
          ..path = '/',
        Cookie('refresh_token', 'r')
          ..domain = 'nhentai.net'
          ..path = '/',
        Cookie('csrftoken', 'c')
          ..domain = 'nhentai.net'
          ..path = '/',
      ]);

      await network.logout();

      final left = jar.loadForRequest(uri);
      final names = left.map((c) => c.name).toSet();
      expect(
        names.contains('access_token'),
        isFalse,
        reason: '不带根路径的 Uri 删不到 path=/ 的 Cookie',
      );
      expect(names.contains('refresh_token'), isFalse);
      expect(
        names.contains('csrftoken'),
        isTrue,
        reason: '非目标 Cookie 必须保留',
      );
    });

    test('没有可用 jar 时抛出明确错误而不是空断言崩溃', () async {
      final network = NhentaiNetwork();
      network.cookieJar = null;
      final saved = SingleInstanceCookieJar.instance;
      SingleInstanceCookieJar.instance = null;
      addTearDown(() {
        SingleInstanceCookieJar.instance = saved;
      });

      await expectLater(network.logout(), throwsA(isA<StateError>()));
    });
  });

  group('A18 注册入口', () {
    test('只有 JM 声明注册地址', () {
      ComicSource builtIn(String key) =>
          ComicSource.builtIn.firstWhere((s) => s.key == key);

      expect(
        builtIn('jm').account?.registerWebsite,
        'https://18comic.vip/signup',
      );
      for (final key in <String>['picacg', 'ehentai', 'nhentai']) {
        expect(
          builtIn(key).account?.registerWebsite,
          isNull,
          reason: '$key 不应凭空获得注册接口',
        );
      }
    });

    testWidgets('声明了注册地址才显示注册入口', (tester) async {
      final withRegister = ComicSource.named(
        key: 'jm',
        name: '禁漫',
        data: <String, dynamic>{},
        account: AccountConfig(
          login: (a, p) async => const Res(true),
          registerWebsite: 'https://example.test/signup',
        ),
      );
      await tester
          .pumpWidget(MaterialApp(home: LoginPage(source: withRegister)));
      await tester.pump();
      expect(find.text('注册'), findsOneWidget);

      final withoutRegister = ComicSource.named(
        key: 'picacg',
        name: 'Picacg',
        data: <String, dynamic>{},
        account: AccountConfig(login: (a, p) async => const Res(true)),
      );
      await tester.pumpWidget(
        MaterialApp(home: LoginPage(source: withoutRegister)),
      );
      await tester.pump();
      expect(find.text('注册'), findsNothing);
    });
  });
}

// 说明：EH 的显示快照（id/hash/igneous/cookiesStr）在 logout 与 getCookies 重建
// 两条路径上都会清空，用例锁定的是"退出后终态为空"这一可观察结果。
