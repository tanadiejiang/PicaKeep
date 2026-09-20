import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:sqlite3/open.dart';

/// A10 / A09 的剩余分支：显示快照重建与站点切换读值、点域 JWT 清除、
/// 退出后的本地登录态与凭据清除。
///
/// 这些路径都在本地完成（不发请求），可直接用真实单例 + 临时目录验证。

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
    workspace = await Directory.systemTemp.createTemp('picakeep_cred_');
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
      // 单例 jar 仍持有句柄时清理失败不影响断言。
    }
  });

  Cookie seed(String host, String name, String value) => Cookie(name, value)
    ..domain = host
    ..path = '/';

  group('A10 EH 显示快照', () {
    test('重建快照前清空：本次没有的身份字段不会残留旧值', () async {
      final net = EhNetwork();
      // 先制造"上一个账号"的快照残留
      net.id = 'old-id';
      net.hash = 'old-hash';
      net.igneous = 'old-igneous';

      // 清掉 jar 里的身份 Cookie，只留 nw/sp 这类非身份项
      net.cookieJar.delete(Uri.parse('https://e-hentai.org/'), 'ipb_member_id');
      net.cookieJar.delete(Uri.parse('https://e-hentai.org/'), 'ipb_pass_hash');
      net.cookieJar.delete(Uri.parse('https://e-hentai.org/'), 'igneous');

      await net.getCookies(false);

      expect(net.id, isEmpty, reason: '缺键时必须留空，不能带出历史值');
      expect(net.hash, isEmpty);
      expect(net.igneous, isEmpty);
    });

    test('切站按当前站点读值', () async {
      final net = EhNetwork();
      final original = appdata.settings[20];
      addTearDown(() => appdata.settings[20] = original);

      net.cookieJar
          .saveFromResponse(Uri.parse('https://e-hentai.org/'), <Cookie>[
        seed('e-hentai.org', 'ipb_member_id', 'normal-site-id'),
      ]);
      net.cookieJar
          .saveFromResponse(Uri.parse('https://exhentai.org/'), <Cookie>[
        seed('exhentai.org', 'ipb_member_id', 'ex-site-id'),
      ]);

      appdata.settings[20] = '0'; // 表站
      await net.getCookies(false);
      expect(net.id, 'normal-site-id');

      appdata.settings[20] = '1'; // 里站
      await net.getCookies(false);
      expect(
        net.id,
        'ex-site-id',
        reason: '切站后必须按当前站点重建显示值',
      );

      // 清理，避免影响其它用例
      net.cookieJar.delete(Uri.parse('https://e-hentai.org/'), 'ipb_member_id');
      net.cookieJar.delete(Uri.parse('https://exhentai.org/'), 'ipb_member_id');
    });
  });

  group('A09 NH 凭据清除', () {
    test('点域（.nhentai.net）JWT 也一并清除', () async {
      final jar = SingleInstanceCookieJar(
        '${workspace.path}${Platform.pathSeparator}nh_dot.db',
      );
      final network = NhentaiNetwork();
      network.cookieJar = jar;

      final uri = Uri.parse('https://nhentai.net/');
      jar.saveFromResponse(uri, <Cookie>[
        seed('.nhentai.net', 'access_token', 'a'),
        seed('.nhentai.net', 'refresh_token', 'r'),
        seed('.nhentai.net', 'csrftoken', 'c'),
      ]);

      await network.logout();

      final names =
          jar.loadForRequest(uri).map((cookie) => cookie.name).toSet();
      expect(names.contains('access_token'), isFalse);
      expect(names.contains('refresh_token'), isFalse);
      expect(names.contains('csrftoken'), isTrue);
    });

    test('退出把本地登录标记置为 false', () async {
      final jar = SingleInstanceCookieJar(
        '${workspace.path}${Platform.pathSeparator}nh_flag.db',
      );
      final network = NhentaiNetwork();
      network.cookieJar = jar;
      network.logged = true;

      await network.logout();

      expect(network.logged, isFalse);
    });

    test('源级退出清 token/name，Cookie 清理由网络层完成', () async {
      await ComicSource.init();
      final source = ComicSource.require('nhentai');
      final jar = SingleInstanceCookieJar(
        '${workspace.path}${Platform.pathSeparator}nh_source.db',
      );
      final network = NhentaiNetwork();
      network.cookieJar = jar;

      final uri = Uri.parse('https://nhentai.net/');
      jar.saveFromResponse(uri, <Cookie>[
        seed('nhentai.net', 'access_token', 'a'),
        seed('nhentai.net', 'refresh_token', 'r'),
      ]);
      source.data.addAll(<String, dynamic>{
        'token': 'ok',
        'name': 'someone',
      });
      await source.saveData();

      await source.account!.logout!();

      expect(source.data.containsKey('token'), isFalse);
      expect(source.data.containsKey('name'), isFalse);
      final names =
          jar.loadForRequest(uri).map((cookie) => cookie.name).toSet();
      expect(names.contains('access_token'), isFalse);
      expect(names.contains('refresh_token'), isFalse);
    });

    test('退出失败后可重试同一个幂等清理', () async {
      final network = NhentaiNetwork();
      final saved = SingleInstanceCookieJar.instance;
      network.cookieJar = null;
      SingleInstanceCookieJar.instance = null;
      addTearDown(() {
        SingleInstanceCookieJar.instance = saved;
      });

      // 第一次：没有可用 jar → 明确失败
      await expectLater(network.logout(), throwsA(isA<StateError>()));

      // 重试：补上 jar 后同一操作应能成功
      final jar = SingleInstanceCookieJar(
        '${workspace.path}${Platform.pathSeparator}nh_retry.db',
      );
      network.cookieJar = jar;
      jar.saveFromResponse(Uri.parse('https://nhentai.net/'), <Cookie>[
        seed('nhentai.net', 'access_token', 'a'),
      ]);

      await network.logout();

      final names = jar
          .loadForRequest(Uri.parse('https://nhentai.net/'))
          .map((cookie) => cookie.name)
          .toSet();
      expect(names.contains('access_token'), isFalse);
    });
  });
}
