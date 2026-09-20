import 'dart:async';
import 'dart:convert';
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
import 'package:picakeep/pages/accounts/login_page.dart';

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
  final originalPaths = PathProviderPlatform.instance;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_acct_review_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  setUp(() {
    originalSources = List<ComicSource>.of(ComicSource.sources);
    ComicSource.sources.clear();
  });

  tearDown(() {
    ComicSource.sources
      ..clear()
      ..addAll(originalSources);
  });

  Future<void> pumpFrames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  void setViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpAccounts(
    WidgetTester tester,
    AccountOperationController controller,
  ) async {
    setViewport(tester);
    await tester.pumpWidget(MaterialApp(
      home: AccountOperationScope(
        controller: controller,
        child: const AccountsPage(),
      ),
    ));
    await pumpFrames(tester);
  }

  ListTile actionTile(WidgetTester tester, String title) {
    return tester.widget<ListTile>(find.ancestor(
      of: find.text(title),
      matching: find.byType(ListTile),
    ));
  }

  for (final afterTransition in [false, true]) {
    testWidgets(
        'login completion refreshes overview after return (animation ended: $afterTransition)',
        (tester) async {
      final gate = Completer<void>();
      var loginCalls = 0;
      var infoCalls = 0;
      late ComicSource source;
      source = ComicSource.named(
        key: 'alpha',
        name: 'Alpha',
        account: AccountConfig(
          login: (username, password) async {
            loginCalls++;
            await gate.future;
            source.data['token'] = 'test-token';
            return const Res(true);
          },
          logout: () async => source.data.remove('token'),
          infoItems: () async {
            infoCalls++;
            return const Res(<AccountInfoItem>[
              AccountInfoItem(title: '用户名', value: 'new-profile'),
            ]);
          },
        ),
      );
      ComicSource.sources.add(source);
      setViewport(tester);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showAccountsPage(context),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await pumpFrames(tester);
      await tester.tap(find.text('登录'));
      await pumpFrames(tester);
      await tester.enterText(find.byType(TextField).first, 'test-user');
      await tester.enterText(find.byType(TextField).last, 'test-password');
      await tester.tap(find.text('继续'));
      await pumpFrames(tester);

      expect(loginCalls, 1);
      expect(infoCalls, 0);
      await tester.tap(find.byType(BackButton).last);
      if (afterTransition) {
        await pumpFrames(tester);
        expect(find.byType(LoginPage), findsNothing);
        expect(find.byType(AccountsPage), findsOneWidget);
        expect(actionTile(tester, '登录').onTap, isNull);
      } else {
        await tester.pump();
        expect(find.byType(LoginPage, skipOffstage: false), findsOneWidget);
      }

      gate.complete();
      await pumpFrames(tester);

      expect(find.text('new-profile'), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);
      expect(find.text('登录'), findsNothing);
      expect(infoCalls, 1);
      expect(loginCalls, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('logout persistence failure keeps retry after token is cleared',
      (tester) async {
    final controller = AccountOperationController();
    addTearDown(controller.dispose);
    var logoutCalls = 0;
    var writeCalls = 0;
    var persisted = '{"token":"test-token"}';
    late ComicSource source;
    source = ComicSource.named(
      key: 'alpha',
      name: 'Alpha',
      data: <String, dynamic>{'token': 'test-token'},
      account: AccountConfig(
        login: (username, password) async => const Res(true),
        logout: () async {
          logoutCalls++;
          source.data.remove('token');
          await source.saveData();
        },
        infoItems: () async => const Res(<AccountInfoItem>[]),
      ),
    );
    source.writeDataFile = (path, contents) async {
      writeCalls++;
      if (writeCalls == 1) throw const FileSystemException('test disk full');
      persisted = contents;
    };
    ComicSource.sources.add(source);
    await pumpAccounts(tester, controller);

    await tester.tap(find.text('退出登录'));
    await pumpFrames(tester);

    expect(source.isLoggedIn, isFalse);
    expect(jsonDecode(persisted), containsPair('token', 'test-token'));
    expect(controller.failedOperationOf('alpha'), 'logout');
    expect(actionTile(tester, '重试退出').onTap, isNotNull);
    expect(find.text('登录'), findsNothing);
    expect(find.textContaining('test disk full'), findsWidgets);

    await tester.tap(find.text('重试退出'));
    await pumpFrames(tester);

    expect(logoutCalls, 2);
    expect(writeCalls, 2);
    expect(jsonDecode(persisted), isEmpty);
    expect(controller.errorOf('alpha'), isNull);
    expect(controller.failedOperationOf('alpha'), isNull);
    expect(find.text('重试退出'), findsNothing);
    expect(actionTile(tester, '登录').onTap, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('relogin false reports failure without success notification',
      (tester) async {
    final controller = AccountOperationController();
    addTearDown(controller.dispose);
    var reLoginCalls = 0;
    ComicSource.sources.add(ComicSource.named(
      key: 'alpha',
      name: 'Alpha',
      data: <String, dynamic>{'token': 'test-token'},
      account: AccountConfig(
        login: (username, password) async => const Res(true),
        reLogin: () async {
          reLoginCalls++;
          return const Res(false);
        },
        infoItems: () async => const Res(<AccountInfoItem>[]),
      ),
    ));
    await pumpAccounts(tester, controller);
    await tester.tap(find.text('重新登录'));
    await pumpFrames(tester);

    expect(reLoginCalls, 1);
    expect(controller.failedOperationOf('alpha'), 'relogin');
    expect(find.text('重新登录成功'), findsNothing);
    expect(find.textContaining('登录未完成，请重试'), findsWidgets);
    expect(actionTile(tester, '重新登录').onTap, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending profile load disables logout until the load completes',
      (tester) async {
    final controller = AccountOperationController();
    addTearDown(controller.dispose);
    final gate = Completer<Res<List<AccountInfoItem>>>();
    var infoCalls = 0;
    var logoutCalls = 0;
    late ComicSource source;
    source = ComicSource.named(
      key: 'alpha',
      name: 'Alpha',
      data: <String, dynamic>{'token': 'test-token'},
      account: AccountConfig(
        login: (username, password) async => const Res(true),
        logout: () async {
          logoutCalls++;
          source.data.remove('token');
        },
        infoItems: () {
          infoCalls++;
          return gate.future;
        },
      ),
    );
    ComicSource.sources.add(source);
    await pumpAccounts(tester, controller);

    expect(infoCalls, 1);
    expect(controller.isBusy('alpha'), isTrue);
    expect(actionTile(tester, '退出登录').onTap, isNull);
    await tester.tap(find.text('退出登录'));
    await pumpFrames(tester);
    expect(logoutCalls, 0);
    expect(infoCalls, 1);

    gate.complete(const Res(<AccountInfoItem>[]));
    await pumpFrames(tester);
    expect(controller.isBusy('alpha'), isFalse);
    expect(actionTile(tester, '退出登录').onTap, isNotNull);
    await tester.tap(find.text('退出登录'));
    await pumpFrames(tester);
    expect(logoutCalls, 1);
    expect(infoCalls, 1);
    expect(find.text('登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
      'execute rejects a different same-source action without borrowing result',
      () async {
    final controller = AccountOperationController();
    addTearDown(controller.dispose);
    final gate = Completer<int>();
    var rejectedActionCalls = 0;
    final first = controller.execute<int>('alpha', () => gate.future);
    final second = controller.execute<String>('alpha', () async {
      rejectedActionCalls++;
      return 'unrelated-result';
    });

    await expectLater(second, throwsA(isA<AccountOperationBusyException>()));
    expect(rejectedActionCalls, 0);
    expect(controller.isBusy('alpha'), isTrue);
    expect(controller.errorOf('alpha'), isNull);
    expect(controller.revisionOf('alpha'), 0);

    gate.complete(42);
    expect(await first, 42);
    expect(controller.isBusy('alpha'), isFalse);
    expect(controller.revisionOf('alpha'), 1);
    expect(
        await controller.execute<String>('alpha', () async => 'next'), 'next');
  });

  test('pending execution completes without notifying a disposed controller',
      () async {
    final controller = AccountOperationController();
    final gate = Completer<int>();
    var notifications = 0;
    controller.addListener(() => notifications++);
    final result = controller.execute<int>('alpha', () => gate.future);
    expect(notifications, 1);

    controller.dispose();
    gate.complete(42);

    expect(await result, 42);
    expect(notifications, 1);
    expect(controller.anyBusy, isFalse);
  });

  test('pending error after dispose still reaches its original caller',
      () async {
    final controller = AccountOperationController();
    final gate = Completer<void>();
    final failure = StateError('controlled failure');
    final result = controller.execute<void>('alpha', () => gate.future);
    final assertion = expectLater(result, throwsA(same(failure)));

    controller.dispose();
    gate.completeError(failure);

    await assertion;
    expect(controller.anyBusy, isFalse);
  });
}
