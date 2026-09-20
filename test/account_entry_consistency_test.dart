import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/accounts/accounts_page.dart';
import 'package:picakeep/pages/me_page.dart';
import 'package:picakeep/pages/online_search/online_search_logic.dart';

/// A01 / A17 的剩余分支：我页账号计数与标签一致性、
/// 搜索可用源随登录态重建、自定义登录入口返回后刷新。

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

  late Directory workspace;
  late List<ComicSource> originalSources;
  final PathProviderPlatform originalPaths = PathProviderPlatform.instance;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_entry_');
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
      // 临时目录清理失败不影响断言。
    }
  });

  setUp(() {
    originalSources = List<ComicSource>.of(ComicSource.sources);
  });

  tearDown(() {
    ComicSource.sources
      ..clear()
      ..addAll(originalSources);
  });

  void useSources(List<ComicSource> sources) {
    ComicSource.sources
      ..clear()
      ..addAll(sources);
  }

  ComicSource source({
    required String key,
    required String name,
    bool loggedIn = false,
    bool withAccount = true,
  }) {
    return ComicSource.named(
      key: key,
      name: name,
      data: <String, dynamic>{if (loggedIn) 'token': 'ok'},
      account: withAccount
          ? AccountConfig(login: (a, p) async => const Res(true))
          : null,
      searchPageData: SearchPageData(
        loadPage: (keyword, page, option) async =>
            const Res<List<BaseComic>>(<BaseComic>[]),
      ),
    );
  }

  group('A01 我页账号计数与标签同源', () {
    test('全部未登录时计数为 0', () {
      useSources(<ComicSource>[
        source(key: 'alpha', name: 'Alpha'),
        source(key: 'beta', name: 'Beta'),
      ]);

      expect(loggedInAccountSources(), isEmpty);
    });

    test('部分登录时数量与标签顺序都取自同一列表', () {
      useSources(<ComicSource>[
        source(key: 'alpha', name: 'Alpha', loggedIn: true),
        source(key: 'beta', name: 'Beta'),
        source(key: 'gamma', name: 'Gamma', loggedIn: true),
      ]);

      final logged = loggedInAccountSources();
      expect(logged.length, 2, reason: '计数应与标签数量一致');
      expect(
        logged.map((item) => item.name).toList(),
        <String>['Alpha', 'Gamma'],
        reason: '标签顺序沿用注册表顺序',
      );
    });

    test('没有账号能力的源不计入', () {
      useSources(<ComicSource>[
        source(key: 'plain', name: 'Plain', loggedIn: true, withAccount: false),
      ]);

      expect(loggedInAccountSources(), isEmpty);
    });
  });

  group('A17 搜索可用源随登录态重建', () {
    test('退出后不再出现在可搜索（已登录）源里', () {
      final logic = OnlineSearchLogic();
      final alpha = source(key: 'alpha', name: 'Alpha', loggedIn: true);
      useSources(<ComicSource>[alpha]);

      expect(
        logic.loggedInSearchableSources.map((item) => item.key),
        contains('alpha'),
      );

      // 退出登录（源层只清标记）
      alpha.data.remove('token');

      expect(
        logic.loggedInSearchableSources,
        isEmpty,
        reason: '退出后入口页的可搜索源必须重建，不能仍把它列为可用',
      );
      expect(
        logic.searchableSources.map((item) => item.key),
        contains('alpha'),
        reason: '它仍有搜索声明，只是当前不可用（未登录）',
      );
    });
  });

  group('A17 自定义登录入口返回层级', () {
    testWidgets('onLogin 返回后刷新资料区，不额外弹层', (tester) async {
      var onLoginCalls = 0;
      var infoLoads = 0;
      late ComicSource eh;
      eh = ComicSource.named(
        key: 'eh',
        name: 'E-Hentai',
        data: <String, dynamic>{},
        account: AccountConfig(
          login: (a, p) async => const Res(true),
          onLogin: (context) async {
            onLoginCalls++;
            // 模拟源自己的登录页完成后写入登录态
            eh.data['token'] = 'ok';
          },
          infoItems: () async {
            infoLoads++;
            return const Res(<AccountInfoItem>[
              AccountInfoItem(title: '用户名', value: 'after-login'),
            ]);
          },
        ),
      );
      useSources(<ComicSource>[eh]);

      await tester.pumpWidget(const MaterialApp(home: AccountsPage()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('登录'), findsOneWidget);
      expect(infoLoads, 0, reason: '未登录时不读取资料');

      await tester.tap(find.text('登录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(onLoginCalls, 1);
      expect(
        infoLoads,
        1,
        reason: '自定义登录入口返回后必须刷新本源资料区',
      );
      expect(find.text('after-login'), findsOneWidget);
      // 仍停留在账号总览（自定义登录入口自己负责内层页面）
      expect(find.byType(AccountsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
