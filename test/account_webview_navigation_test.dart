import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/accounts/account_page_route.dart';
import 'package:picakeep/pages/accounts/accounts_page.dart';
import 'package:picakeep/pages/online_comic/account_webview_login.dart';
import 'package:picakeep/pages/online_comic/nhentai_login_page.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

class _PopObserver extends NavigatorObserver {
  final List<Route<dynamic>> popped = [];

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousPaths = PathProviderPlatform.instance;
  late Directory directory;

  setUpAll(() async {
    directory =
        await Directory.systemTemp.createTemp('picakeep_web_navigation_');
    PathProviderPlatform.instance = _Paths(directory.path);
    await App.init(dataPathOverride: '${directory.path}/data');
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = previousPaths;
    await directory.delete(recursive: true);
  });

  testWidgets(
      'real account host prioritizes root webview for main pop and focused inner back',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final originalSources = List<ComicSource>.of(ComicSource.sources);
    addTearDown(() {
      ComicSource.sources
        ..clear()
        ..addAll(originalSources);
    });

    final rootKey = GlobalKey<NavigatorState>();
    final mainKey = GlobalKey<NavigatorState>();
    final rootObserver = _PopObserver();
    final mainObserver = _PopObserver();
    var accountClosed = false;
    var submissions = 0;
    var browserRoutesCreated = 0;

    ComicSource.sources
      ..clear()
      ..add(ComicSource.named(
        key: 'nhentai',
        name: 'Nhentai',
        account: AccountConfig(
          login: (_, __) async => const Res.error('use custom login'),
          onLogin: (context) async {
            await Navigator.of(context).push<void>(MaterialPageRoute<void>(
              settings: const RouteSettings(name: 'test-nh-login'),
              builder: (_) => NhentaiLoginPage(
                prepareWebview: () async {},
                submitCredentials: (_) async {
                  submissions++;
                },
                webviewFactory: (context, url, event, onClosed) {
                  browserRoutesCreated++;
                  return createRouteAccountLoginWebview(
                    context,
                    url,
                    event,
                    onClosed,
                    pageBuilder: (_) => const Scaffold(
                      body: Center(child: Text('root-login-browser')),
                    ),
                  );
                },
              ),
            ));
          },
        ),
      ));

    await tester.pumpWidget(MaterialApp(
      navigatorKey: rootKey,
      navigatorObservers: [rootObserver],
      home: Navigator(
        key: mainKey,
        observers: [mainObserver],
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'main-launcher'),
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                await showAccountsPage(context);
                accountClosed = true;
              },
              child: const Text('open-accounts'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open-accounts'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountPageHost), findsOneWidget);
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(find.byType(NhentaiLoginPage), findsOneWidget);

    // This is the navigator a focused input inside the real login page finds.
    final inner = Navigator.of(tester.element(find.byType(NhentaiLoginPage)));
    expect(inner, isNot(same(mainKey.currentState)));
    expect(inner, isNot(same(rootKey.currentState)));

    Future<void> openBrowser() async {
      await tester.tap(find.text('在 Webview 中登录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('root-login-browser'), findsOneWidget);
      expect(rootKey.currentState!.canPop(), isTrue);
      expect(find.byType(AccountPageHost, skipOffstage: false), findsOneWidget);
      expect(
          find.byType(NhentaiLoginPage, skipOffstage: false), findsOneWidget);
    }

    await openBrowser();
    mainKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('root-login-browser'), findsNothing);
    expect(rootObserver.popped, hasLength(1));
    expect(mainObserver.popped, isEmpty);
    expect(rootKey.currentState!.canPop(), isFalse);
    expect(find.byType(NhentaiLoginPage), findsOneWidget);
    expect(find.byType(AccountPageHost), findsOneWidget);
    expect(accountClosed, isFalse);
    expect(submissions, 0);
    expect(tester.takeException(), isNull);

    await openBrowser();
    expect(await inner.maybePop(), isTrue);
    await tester.pumpAndSettle();
    expect(browserRoutesCreated, 2);
    expect(find.text('root-login-browser'), findsNothing);
    expect(rootObserver.popped, hasLength(2));
    expect(mainObserver.popped, isEmpty);
    expect(find.byType(NhentaiLoginPage), findsOneWidget);
    expect(find.byType(AccountPageHost), findsOneWidget);
    expect(accountClosed, isFalse);
    expect(submissions, 0);
    expect(tester.takeException(), isNull);

    // With the webview gone, the next two returns retire the login and host.
    expect(await inner.maybePop(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(NhentaiLoginPage), findsNothing);
    expect(find.byType(AccountsPage), findsOneWidget);
    expect(find.byType(AccountPageHost), findsOneWidget);
    expect(accountClosed, isFalse);
    expect(mainObserver.popped, isEmpty);

    mainKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(AccountPageHost), findsNothing);
    expect(find.text('open-accounts'), findsOneWidget);
    expect(mainObserver.popped, hasLength(1));
    expect(rootObserver.popped, hasLength(2));
    expect(accountClosed, isTrue);
    expect(mainKey.currentState!.canPop(), isFalse);
    expect(rootKey.currentState!.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });
}
