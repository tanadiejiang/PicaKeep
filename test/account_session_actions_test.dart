import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/accounts/account_operation_scope.dart';
import 'package:picakeep/pages/accounts/account_page_route.dart';
import 'package:picakeep/pages/accounts/accounts_page.dart';

/// A06 / A17：单源操作门禁、失败重试、容器忙碌时拒绝关闭、Scope 缺失不崩。

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
    workspace = await Directory.systemTemp.createTemp('picakeep_acct_ops_');
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

  group('A06 单源操作门禁', () {
    test('同源在途操作期间重复调用只执行一份', () async {
      final controller = AccountOperationController();
      final gate = Completer<void>();
      var calls = 0;

      final first = controller.run('alpha', () async {
        calls++;
        await gate.future;
      });
      final second = controller.run('alpha', () async {
        calls++;
      });

      expect(calls, 1, reason: '同源重复操作不应再执行一份');
      expect(controller.isBusy('alpha'), isTrue);
      expect(controller.anyBusy, isTrue);

      gate.complete();
      await Future.wait(<Future<void>>[first, second]);

      expect(calls, 1);
      expect(controller.isBusy('alpha'), isFalse);
      expect(controller.anyBusy, isFalse);
      controller.dispose();
    });

    test('不同源互不阻塞', () async {
      final controller = AccountOperationController();
      final gate = Completer<void>();
      var alphaDone = false;

      unawaited(controller.run('alpha', () async {
        await gate.future;
        alphaDone = true;
      }));
      await controller.run('beta', () async {});

      expect(controller.isBusy('beta'), isFalse);
      expect(controller.isBusy('alpha'), isTrue);
      expect(alphaDone, isFalse);
      expect(controller.anyBusy, isTrue);

      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(alphaDone, isTrue);
      controller.dispose();
    });

    test('失败释放门禁、保留可重试错误，重试时清空错误', () async {
      final controller = AccountOperationController();
      var calls = 0;

      await controller.run('alpha', () async {
        calls++;
        throw StateError('boom');
      });

      expect(calls, 1);
      expect(controller.isBusy('alpha'), isFalse, reason: '失败必须释放门禁');
      expect(controller.errorOf('alpha'), contains('boom'));

      await controller.run('alpha', () async {
        calls++;
      });
      expect(calls, 2, reason: '失败后必须允许重试');
      expect(controller.errorOf('alpha'), isNull);
      controller.dispose();
    });
  });

  group('A06 账号容器', () {
    testWidgets('真实操作未完成时拒绝关闭容器，完成后才能关闭', (tester) async {
      final gate = Completer<void>();
      ComicSource.sources
        ..clear()
        ..add(
          ComicSource.named(
            key: 'alpha',
            name: 'Alpha',
            data: <String, dynamic>{'token': 'ok'},
            account: AccountConfig(
              login: (account, password) async => const Res(true),
              logout: () async {
                await gate.future;
              },
              infoItems: () async => const Res(<AccountInfoItem>[]),
            ),
          ),
        );

      tester.view.physicalSize = const Size(900, 900);
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
      expect(find.byType(AccountsPage), findsOneWidget);

      // 触发一个挂起的真实操作
      await tester.tap(find.text('退出登录'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      // 此时返回应被拒绝
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byType(AccountsPage),
        findsOneWidget,
        reason: '真实操作未完成时不能关闭容器',
      );
      // SnackBar 退场动画期间文本可能同时存在两份，这里只断言提示已出现。
      expect(find.text('账号操作正在进行，请稍候'), findsWidgets);

      final outer = tester.state<NavigatorState>(find.byType(Navigator).first);
      outer.pop();
      await tester.pump();
      expect(find.byType(AccountsPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(AccountsPage), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      expect(find.byType(AccountsPage), findsOneWidget);

      // 操作完成后可以关闭
      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AccountsPage), findsNothing);
    });

    testWidgets('没有账号 Scope 时（直接 push）不崩且操作可用', (tester) async {
      var reLoginCalls = 0;
      ComicSource.sources
        ..clear()
        ..add(
          ComicSource.named(
            key: 'alpha',
            name: 'Alpha',
            data: <String, dynamic>{'token': 'ok'},
            account: AccountConfig(
              login: (account, password) async => const Res(true),
              reLogin: () async {
                reLoginCalls++;
                return const Res(true);
              },
              infoItems: () async => const Res(<AccountInfoItem>[]),
            ),
          ),
        );

      await tester.pumpWidget(
        const MaterialApp(home: AccountsPage()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(AccountsPage), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('重新登录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(reLoginCalls, 1);
      expect(tester.takeException(), isNull);
    });
  });
}
