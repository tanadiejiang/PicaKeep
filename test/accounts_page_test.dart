import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/accounts/account_mode_controller.dart';
import 'package:picakeep/pages/accounts/account_page_route.dart';
import 'package:picakeep/pages/accounts/accounts_page.dart';
import 'package:picakeep/pages/accounts/login_page.dart';

/// A01–A05：账号页能力表、资料加载与重试、重登显隐、本地/NAS、登录页错误路径。
///
/// 全部使用假源与受控回调，不触碰真实账号或网络。

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
    workspace = await Directory.systemTemp.createTemp('picakeep_acct_page_');
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

  ComicSource buildSource({
    required String key,
    required String name,
    bool loggedIn = true,
    AccountConfig? account,
  }) {
    return ComicSource.named(
      key: key,
      name: name,
      data: <String, dynamic>{if (loggedIn) 'token': 'ok'},
      account: account ?? AccountConfig(login: (a, p) async => const Res(true)),
    );
  }

  Future<void> pumpAccounts(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: AccountsPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  group('A01 能力表', () {
    testWidgets('未登录源只显示一行登录，不出现资料或重登', (tester) async {
      ComicSource.sources
        ..clear()
        ..add(buildSource(key: 'alpha', name: 'Alpha', loggedIn: false));

      await pumpAccounts(tester);

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('登录'), findsOneWidget);
      expect(find.text('重新登录'), findsNothing);
      expect(find.text('退出登录'), findsNothing);
    });

    testWidgets('已登录源显示资料与退出；无资料源不显示噪声行', (tester) async {
      ComicSource.sources
        ..clear()
        ..add(
          buildSource(
            key: 'alpha',
            name: 'Alpha',
            account: AccountConfig(
              login: (a, p) async => const Res(true),
              infoItems: () async => const Res(<AccountInfoItem>[
                AccountInfoItem(title: '用户名', value: 'someone'),
              ]),
            ),
          ),
        )
        ..add(
          buildSource(
            key: 'beta',
            name: 'Beta',
            account: AccountConfig(
              login: (a, p) async => const Res(true),
              // 原项目里没有资料项的源：不应出现"暂无账号信息"这类噪声行。
              infoItems: () async => const Res(<AccountInfoItem>[]),
            ),
          ),
        );

      await pumpAccounts(tester);

      expect(find.text('用户名'), findsOneWidget);
      expect(find.text('someone'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('暂无账号信息'), findsNothing);
      expect(find.text('退出登录'), findsNWidgets(2));
    });
  });

  group('A03 重登显隐', () {
    testWidgets('allowReLogin=false 时不显示，即使有 handler', (tester) async {
      ComicSource.sources
        ..clear()
        ..add(
          buildSource(
            key: 'eh',
            name: 'E-Hentai',
            account: AccountConfig(
              login: (a, p) async => const Res(true),
              allowReLogin: false,
              reLogin: () async => const Res(true),
            ),
          ),
        );

      await pumpAccounts(tester);
      expect(find.text('重新登录'), findsNothing);
    });

    testWidgets('allowReLogin=true 但没有 handler 时不显示', (tester) async {
      ComicSource.sources
        ..clear()
        ..add(
          buildSource(
            key: 'alpha',
            name: 'Alpha',
            account: AccountConfig(login: (a, p) async => const Res(true)),
          ),
        );

      await pumpAccounts(tester);
      expect(find.text('重新登录'), findsNothing);
    });

    testWidgets('允许且有 handler 时显示并可触发', (tester) async {
      var calls = 0;
      ComicSource.sources
        ..clear()
        ..add(
          buildSource(
            key: 'alpha',
            name: 'Alpha',
            account: AccountConfig(
              login: (a, p) async => const Res(true),
              reLogin: () async {
                calls++;
                return const Res(true);
              },
            ),
          ),
        );

      await pumpAccounts(tester);
      expect(find.text('重新登录'), findsOneWidget);

      await tester.tap(find.text('重新登录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(calls, 1);
    });
  });

  group('A04 资料加载与重试', () {
    testWidgets('加载失败显示错误与重试入口，重试后可成功', (tester) async {
      var attempt = 0;
      ComicSource.sources
        ..clear()
        ..add(
          buildSource(
            key: 'alpha',
            name: 'Alpha',
            account: AccountConfig(
              login: (a, p) async => const Res(true),
              infoItems: () async {
                attempt++;
                if (attempt == 1) {
                  return const Res<List<AccountInfoItem>>.error('资料读取失败');
                }
                return const Res(<AccountInfoItem>[
                  AccountInfoItem(title: '用户名', value: 'recovered'),
                ]);
              },
            ),
          ),
        );

      await pumpAccounts(tester);

      expect(find.text('账号信息加载失败'), findsOneWidget);
      // 失败不等于登出：退出登录入口仍在
      expect(find.text('退出登录'), findsOneWidget);
      expect(attempt, 1, reason: '每次只应发起一次加载');

      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(attempt, 2);
      expect(find.text('账号信息加载失败'), findsNothing);
      expect(find.text('recovered'), findsOneWidget);
    });

    testWidgets('builder 项优先于 title/value（EH cookies 区接入方式）', (tester) async {
      ComicSource.sources
        ..clear()
        ..add(
          buildSource(
            key: 'eh',
            name: 'E-Hentai',
            account: AccountConfig(
              login: (a, p) async => const Res(true),
              infoItems: () async => Res(<AccountInfoItem>[
                const AccountInfoItem(title: '用户名', value: 'someone'),
                AccountInfoItem(
                  title: 'cookies',
                  value: '不应显示的占位值',
                  builder: (context) => const Text('自定义 cookies 区'),
                ),
              ]),
            ),
          ),
        );

      await pumpAccounts(tester);

      expect(find.text('自定义 cookies 区'), findsOneWidget);
      expect(find.text('不应显示的占位值'), findsNothing);
    });
  });

  group('A02 本地 / NAS', () {
    testWidgets('NAS 只提示未接入，且模式仍停在本地', (tester) async {
      ComicSource.sources
        ..clear()
        ..add(buildSource(key: 'alpha', name: 'Alpha', loggedIn: false));

      await pumpAccounts(tester);

      expect(find.text('本地'), findsOneWidget);
      expect(find.text('NAS'), findsOneWidget);

      await tester.tap(find.text('NAS'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('NAS'), findsWidgets);
      expect(
        AccountModeController.instance.mode,
        AccountStorageMode.local,
        reason: 'NAS 未接入时不能把有效模式留在 NAS',
      );
    });
  });

  group('A05 登录页', () {
    testWidgets('空输入不提交；Res(false) 不算成功；密码原样提交', (tester) async {
      final received = <String>[];
      final source = buildSource(
        key: 'alpha',
        name: 'Alpha',
        loggedIn: false,
        account: AccountConfig(
          login: (account, password) async {
            received.add('$account|$password');
            return const Res(false);
          },
        ),
      );

      await tester.pumpWidget(MaterialApp(home: LoginPage(source: source)));
      await tester.pump();

      // 空输入：不调用 login
      await tester.tap(find.text('继续'));
      await tester.pump();
      expect(received, isEmpty);
      expect(find.text('请输入用户名和密码'), findsOneWidget);

      // 有输入但源返回 Res(false)：不能当成登录成功
      await tester.enterText(find.byType(TextField).first, '  user  ');
      await tester.enterText(find.byType(TextField).last, ' pass ');
      await tester.tap(find.text('继续'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(received, hasLength(1));
      expect(
        received.single,
        'user| pass ',
        reason: '用户名 trim、密码原样，不能被 trim 掉空格',
      );
      expect(find.text('登录未完成，请重试'), findsOneWidget);
    });

    testWidgets('同步抛异常与 Res.error 都留在页面且可重试', (tester) async {
      var attempt = 0;
      final source = buildSource(
        key: 'alpha',
        name: 'Alpha',
        loggedIn: false,
        account: AccountConfig(
          login: (account, password) async {
            attempt++;
            if (attempt == 1) {
              throw StateError('sync-boom');
            }
            return const Res<bool>.error('bad-credentials');
          },
        ),
      );

      await tester.pumpWidget(MaterialApp(home: LoginPage(source: source)));
      await tester.pump();

      await tester.enterText(find.byType(TextField).first, 'user');
      await tester.enterText(find.byType(TextField).last, 'pass');
      await tester.tap(find.text('继续'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('sync-boom'), findsOneWidget);
      // 失败后必须解锁：按钮可再次点击
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '继续'),
      );
      expect(button.onPressed, isNotNull);

      await tester.tap(find.text('继续'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(attempt, 2);
    });

    testWidgets('异步异常同样留在页面并可重试', (tester) async {
      var attempt = 0;
      final source = buildSource(
        key: 'alpha',
        name: 'Alpha',
        loggedIn: false,
        account: AccountConfig(
          login: (account, password) async {
            attempt++;
            if (attempt == 1) {
              return Future<Res<bool>>.error(StateError('async-boom'));
            }
            return const Res(true);
          },
        ),
      );

      await tester.pumpWidget(MaterialApp(home: LoginPage(source: source)));
      await tester.pump();

      await tester.enterText(find.byType(TextField).first, 'user');
      await tester.enterText(find.byType(TextField).last, 'pass');
      await tester.tap(find.text('继续'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('async-boom'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '继续'))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('连击提交在 loading 期间只执行一次', (tester) async {
      var calls = 0;
      final gate = Completer<Res<bool>>();
      final source = buildSource(
        key: 'alpha',
        name: 'Alpha',
        loggedIn: false,
        account: AccountConfig(
          login: (account, password) {
            calls++;
            return gate.future;
          },
        ),
      );

      await tester.pumpWidget(MaterialApp(home: LoginPage(source: source)));
      await tester.pump();

      await tester.enterText(find.byType(TextField).first, 'user');
      await tester.enterText(find.byType(TextField).last, 'pass');
      await tester.tap(find.text('继续'));
      await tester.pump();

      // 提交进行中：按钮已禁用，连点不会产生第二次提交
      await tester.tap(find.text('继续'), warnIfMissed: false);
      await tester.tap(find.text('继续'), warnIfMissed: false);
      await tester.pump();
      expect(calls, 1);

      gate.complete(const Res(true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls, 1);
    });

    testWidgets('键盘回车提交与点按钮等价', (tester) async {
      var calls = 0;
      final source = buildSource(
        key: 'alpha',
        name: 'Alpha',
        loggedIn: false,
        account: AccountConfig(
          login: (account, password) async {
            calls++;
            return const Res(true);
          },
        ),
      );

      await tester.pumpWidget(MaterialApp(home: LoginPage(source: source)));
      await tester.pump();

      await tester.enterText(find.byType(TextField).first, 'user');
      await tester.enterText(find.byType(TextField).last, 'pass');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(calls, 1, reason: '密码框回车应触发登录');
    });
  });

  // A04 的"旧 Future 晚到不覆盖新状态"：当前实现下**不可达**——
  // 资料加载只在 initState 与"失败后的重试"两处发起，而重试按钮只在错误态出现
  // （挂起态没有任何刷新入口），因此不存在两个同时在途的资料请求。
  // 该保证由 FutureBuilder 只认最新 future 的语义提供；上一条"失败→重试→成功"
  // 用例已覆盖其可观察结果。若将来新增下拉刷新/自动重试，需要补这里。

  group('A02 账号存储模式回退', () {
    Future<void> writeModeFile(String content) async {
      final file = File(
        '${App.dataPath}${Platform.pathSeparator}account_mode.json',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    }

    test('旧文件写入 nas 时读取后有效模式仍为 local', () async {
      await writeModeFile('{"mode":"nas"}');

      await AccountModeController.instance.load();

      expect(
        AccountModeController.instance.mode,
        AccountStorageMode.local,
        reason: 'NAS 尚未接入，历史 nas 不能成为有效模式（否则入口会高亮 NAS）',
      );
    });

    test('文件损坏时回退 local 且不抛', () async {
      await writeModeFile('{not json');

      await AccountModeController.instance.load();

      expect(AccountModeController.instance.mode, AccountStorageMode.local);
    });
  });

  group('A18 注册外链', () {
    const registerUrl = 'https://18comic.vip/signup';
    const launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');

    void mockLauncher(
      WidgetTester tester,
      List<String> launched, {
      required bool succeed,
    }) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        launcherChannel,
        (call) async {
          if (call.method == 'launch') {
            final arguments = call.arguments as Map?;
            launched.add(arguments?['url']?.toString() ?? '');
            return succeed;
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(launcherChannel, null);
      });
    }

    testWidgets('点注册把源声明的 URL 交给 url_launcher', (tester) async {
      final launched = <String>[];
      mockLauncher(tester, launched, succeed: true);

      final source = buildSource(
        key: 'jm',
        name: '禁漫',
        loggedIn: false,
        account: AccountConfig(
          login: (a, p) async => const Res(true),
          registerWebsite: registerUrl,
        ),
      );

      await tester.pumpWidget(MaterialApp(home: LoginPage(source: source)));
      await tester.pump();
      await tester.tap(find.text('注册'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(launched, contains(registerUrl));
    });

    testWidgets('打开失败时给出可见提示，不静默', (tester) async {
      final launched = <String>[];
      mockLauncher(tester, launched, succeed: false);

      final source = buildSource(
        key: 'jm',
        name: '禁漫',
        loggedIn: false,
        account: AccountConfig(
          login: (a, p) async => const Res(true),
          registerWebsite: registerUrl,
        ),
      );

      await tester.pumpWidget(MaterialApp(home: LoginPage(source: source)));
      await tester.pump();
      await tester.tap(find.text('注册'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('无法打开注册页面'), findsOneWidget);
    });

    test('账号相关文案在翻译表里有键（简中→繁中/英文）', () {
      final file = File('assets/translation.json');
      expect(file.existsSync(), isTrue, reason: '翻译表应存在于 assets 下');
      final content = file.readAsStringSync();
      for (final key in <String>[
        '账号管理',
        '已登录',
        '登录',
        '重新登录',
        '退出登录',
        '注册',
        '继续',
      ]) {
        expect(
          content.contains('"$key"'),
          isTrue,
          reason: '“$key”缺少翻译键，非简中环境会显示原文',
        );
      }
    });
  });

  group('A06 登录门禁跨子页', () {
    testWidgets('提交挂起时返回总览，同源登录入口禁用直到真实完成', (tester) async {
      var calls = 0;
      final gate = Completer<Res<bool>>();
      final source = ComicSource.named(
        key: 'alpha',
        name: 'Alpha',
        data: <String, dynamic>{},
        account: AccountConfig(
          login: (account, password) {
            calls++;
            return gate.future;
          },
        ),
      );
      ComicSource.sources
        ..clear()
        ..add(source);

      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showAccountsPage(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      Future<void> submit() async {
        await tester.enterText(find.byType(TextField).first, 'user');
        await tester.enterText(find.byType(TextField).last, 'pass');
        await tester.tap(find.text('继续'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await tester.tap(find.text('登录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await submit();
      expect(calls, 1);
      expect(find.byType(LoginPage), findsOneWidget);

      // 提交仍在途时退出登录页：子页返回不释放在途操作
      await tester.tap(find.byType(BackButton).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LoginPage), findsNothing);

      // 同源真实提交仍在途，不能把别的操作结果借给第二次提交。
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, '登录')).onTap,
          isNull);
      await tester.tap(find.text('登录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LoginPage), findsNothing);

      expect(
        calls,
        1,
        reason: '同源在途提交不能被第二次提交重复执行',
      );

      gate.complete(const Res(true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, '登录')).onTap,
          isNotNull);
    });
  });
}
