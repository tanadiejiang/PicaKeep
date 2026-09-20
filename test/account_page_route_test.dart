import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/accounts/account_page_route.dart';
import 'package:picakeep/pages/accounts/accounts_page.dart';
import 'package:picakeep/pages/accounts/login_page.dart';

/// A14 / A15：账号容器的自适应宽度与返回栈顺序。

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
    workspace = await Directory.systemTemp.createTemp('picakeep_acct_route_');
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
    ComicSource.sources
      ..clear()
      ..add(
        ComicSource.named(
          key: 'alpha',
          name: 'Alpha',
          data: <String, dynamic>{},
          account: AccountConfig(
            login: (account, password) async => const Res(true),
          ),
        ),
      );
  });

  tearDown(() {
    ComicSource.sources
      ..clear()
      ..addAll(originalSources);
  });

  Future<void> openAccounts(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
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
  }

  testWidgets('A14 500dp 及以下全屏，501dp 以上固定 500 宽居中', (tester) async {
    await openAccounts(tester, const Size(500, 900));
    expect(find.byType(AccountsPage), findsOneWidget);
    expect(tester.getSize(find.byType(AccountsPage)).width, 500);
    expect(tester.takeException(), isNull);

    for (final width in <double>[501, 1024]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await openAccounts(tester, Size(width, 900));
      expect(find.byType(AccountsPage), findsOneWidget);
      expect(
        tester.getSize(find.byType(AccountsPage)).width,
        500,
        reason: '${width}dp 时容器应固定 500 宽居中',
      );
    }
  });

  testWidgets('A15 容器根页面返回即关闭容器并完成入口 Future', (tester) async {
    await openAccounts(tester, const Size(500, 900));

    var closed = false;
    // 重新走一次以观察 Future 完成时机
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  await showAccountsPage(context);
                  closed = true;
                },
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
    expect(find.byType(AccountsPage), findsOneWidget);
    expect(closed, isFalse);

    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(AccountsPage), findsNothing);
    expect(closed, isTrue, reason: '容器关闭时入口 Future 才完成');
    addTearDown(tester.view.reset);
  });

  testWidgets('A15 直接 pop 最外层路由时先退内层登录页，容器保留', (tester) async {
    await openAccounts(tester, const Size(500, 900));

    // 进入登录页（内层 push）
    await tester.tap(find.text('登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LoginPage), findsOneWidget);
    // 被登录页覆盖的总览会进入 offstage，但仍在树中。
    expect(
      find.byType(AccountsPage, skipOffstage: false),
      findsOneWidget,
    );

    // 模拟主导航里"直接 pop 最上层路由"的返回分派
    final rootNavigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    rootNavigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byType(LoginPage),
      findsNothing,
      reason: '这一次返回应只退掉内层登录页',
    );
    expect(
      find.byType(AccountsPage),
      findsOneWidget,
      reason: '账号容器不能被一次返回直接关掉',
    );

    // 再返回一次：容器关闭，且没有遗留 entry 需要多按一次
    rootNavigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AccountsPage), findsNothing);
  });

  testWidgets('A15 内层自行返回后不遗留镜像 entry', (tester) async {
    await openAccounts(tester, const Size(500, 900));

    await tester.tap(find.text('登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LoginPage), findsOneWidget);

    // 登录页自己返回（不走外层消耗）
    await tester.tap(find.byType(BackButton).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LoginPage), findsNothing);

    final rootNavigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    rootNavigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byType(AccountsPage),
      findsNothing,
      reason: '内层返回后镜像 entry 必须已移除，不能多消耗一次返回',
    );
  });

  testWidgets('A15 外层 pop 与 maybePop 尊重内层对话框保护且不丢镜像', (tester) async {
    await openAccounts(tester, const Size(500, 900));
    await tester.tap(find.text('登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final allowPop = ValueNotifier<bool>(false);
    addTearDown(allowPop.dispose);
    var blockedBacks = 0;
    final dialogResult = showDialog<void>(
      context: tester.element(find.byType(LoginPage)),
      useRootNavigator: false,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<bool>(
        valueListenable: allowPop,
        builder: (context, canPop, child) => PopScope<void>(
          canPop: canPop,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) blockedBacks++;
          },
          child: const AlertDialog(content: Text('protected dialog')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final rootNavigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );

    rootNavigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('protected dialog'), findsOneWidget);
    expect(blockedBacks, 1);
    expect(find.byType(LoginPage, skipOffstage: false), findsOneWidget);

    expect(await rootNavigator.maybePop(), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('protected dialog'), findsOneWidget);
    expect(blockedBacks, 2);
    expect(find.byType(AccountsPage, skipOffstage: false), findsOneWidget);

    allowPop.value = true;
    await tester.pump();
    rootNavigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await dialogResult;
    expect(find.text('protected dialog'), findsNothing);
    expect(find.byType(LoginPage), findsOneWidget);
    expect(blockedBacks, 2);

    expect(await rootNavigator.maybePop(), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LoginPage), findsNothing);
    expect(find.byType(AccountsPage), findsOneWidget);

    rootNavigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AccountsPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A14 360dp 全屏且无溢出', (tester) async {
    await openAccounts(tester, const Size(360, 800));

    expect(find.byType(AccountsPage), findsOneWidget);
    expect(tester.getSize(find.byType(AccountsPage)).width, 360);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A14 键盘弹出时宽屏容器按剩余高度收缩', (tester) async {
    await openAccounts(tester, const Size(900, 900));
    final before = tester.getSize(find.byType(AccountsPage)).height;

    // 模拟软键盘：底部 300 的视口内边距
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final after = tester.getSize(find.byType(AccountsPage)).height;
    expect(
      after,
      lessThan(before),
      reason: '键盘弹出后容器必须收缩，不能遮住登录/确认按钮',
    );
    expect(tester.takeException(), isNull);

    tester.view.resetViewInsets();
    addTearDown(tester.view.reset);
  });

  testWidgets('A14 窗口 resize 不重建内层导航、不丢输入', (tester) async {
    await openAccounts(tester, const Size(900, 900));

    await tester.tap(find.text('登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField).first, 'kept-input');
    await tester.pump();

    // 从宽屏切到窄屏（跨过 500dp 分支）
    tester.view.physicalSize = const Size(400, 900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byType(LoginPage),
      findsOneWidget,
      reason: 'resize 不能重建内层 Navigator（否则会退回总览）',
    );
    expect(find.text('kept-input'), findsOneWidget, reason: 'resize 不能丢输入');

    addTearDown(tester.view.reset);
  });

  testWidgets('A15 遮罩与返回一致：先退内层，再关闭容器', (tester) async {
    await openAccounts(tester, const Size(900, 900));
    expect(find.byType(AccountsPage), findsOneWidget);

    // 反复进入登录页并取消
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('登录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LoginPage), findsOneWidget);

      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LoginPage), findsNothing);
    }

    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byType(AccountsPage),
      findsNothing,
      reason: '反复取消后不应残留需要额外按一次的返回',
    );
  });
}
