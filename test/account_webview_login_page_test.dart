import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/pages/accounts/account_operation_scope.dart';
import 'package:picakeep/pages/online_comic/account_webview_login.dart';
import 'package:picakeep/pages/online_comic/eh_login_page.dart';
import 'package:picakeep/pages/online_comic/nhentai_login_page.dart';

class _Reader implements AccountLoginReader {
  _Reader(this.values, {this.cookieGate, this.uaGate});
  final Map<String, String> values;
  final Completer<Map<String, String>>? cookieGate;
  final Completer<String?>? uaGate;
  int reads = 0;

  @override
  Future<Map<String, String>> cookies(String url) async {
    reads++;
    return cookieGate == null ? values : await cookieGate!.future;
  }

  @override
  Future<String?> userAgent() async =>
      uaGate == null ? 'test-ua' : await uaGate!.future;
}

class _Browser implements AccountLoginWebview {
  _Browser(this.onTitle, this.onClosed, {this.mobile = false});
  final AccountLoginTitle onTitle;
  final VoidCallback onClosed;
  final bool mobile;
  int closeRequests = 0;
  bool closed = false;
  Object? openError;
  Completer<void>? openGate;
  @override
  bool get requiresLoginTransition => mobile;
  @override
  Future<void> open() async {
    if (openError != null) throw openError!;
    await openGate?.future;
  }

  @override
  void requestClose() => closeRequests++;

  void finish() {
    if (closed) return;
    closed = true;
    onClosed();
  }

  @override
  void dispose() => finish();
}

const _ehCookies = {'ipb_member_id': 'test-id', 'ipb_pass_hash': 'test-hash'};
const _nhCookies = {
  'access_token': 'test-access',
  'refresh_token': 'test-refresh'
};

Future<void> _open(WidgetTester tester, Widget page,
    AccountOperationController operations) async {
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) =>
        AccountOperationScope(controller: operations, child: child!),
    home: Builder(
        builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => page,
                )),
                child: const Text('open-login'),
              ),
            )),
  ));
  await tester.tap(find.text('open-login'));
  await tester.pumpAndSettle();
}

Future<void> _start(WidgetTester tester) async {
  await tester.ensureVisible(find.text('在 Webview 中登录'));
  await tester.tap(find.text('在 Webview 中登录'));
  await tester.pump();
}

void main() {
  for (final eh in [true, false]) {
    final key = eh ? 'ehentai' : 'nhentai';
    final title = eh ? 'E-Hentai Forums' : 'nhentai';
    final cookies = eh ? _ehCookies : _nhCookies;

    testWidgets('$key waits for real window close and persistence before pop',
        (tester) async {
      final operations = AccountOperationController();
      addTearDown(operations.dispose);
      late _Browser browser;
      var submissions = 0;
      final saving = Completer<void>();
      AccountLoginWebview factory(BuildContext context, String url,
              AccountLoginTitle event, VoidCallback close) =>
          browser = _Browser(event, close);
      Future<void> submit(AccountLoginCandidate candidate) async {
        expect(candidate.cookies, cookies);
        submissions++;
        await saving.future;
      }

      final page = eh
          ? EhLoginPage(webviewFactory: factory, submitCredentials: submit)
          : NhentaiLoginPage(
              webviewFactory: factory,
              submitCredentials: submit,
              prepareWebview: () async {});
      await _open(tester, page, operations);
      await _start(tester);
      expect(operations.isBusy(key), isTrue);
      final reader = _Reader(cookies);
      browser.onTitle(title, reader);
      browser.onTitle(title, reader);
      await tester.pump();
      expect(browser.closeRequests, 1);
      expect(submissions, 0);
      browser.finish();
      browser.finish();
      await tester.pump();
      expect(submissions, 1);
      expect(operations.isBusy(key), isTrue);
      expect(find.byWidget(page), findsOneWidget);
      saving.complete();
      await tester.pumpAndSettle();
      expect(operations.isBusy(key), isFalse);
      expect(find.byWidget(page), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$key cancellation ignores late reads and a new round',
        (tester) async {
      final operations = AccountOperationController();
      addTearDown(operations.dispose);
      final browsers = <_Browser>[];
      var submissions = 0;
      AccountLoginWebview factory(BuildContext context, String url,
          AccountLoginTitle event, VoidCallback close) {
        final browser = _Browser(event, close);
        browsers.add(browser);
        return browser;
      }

      Future<void> submit(AccountLoginCandidate candidate) async {
        submissions++;
      }

      final page = eh
          ? EhLoginPage(webviewFactory: factory, submitCredentials: submit)
          : NhentaiLoginPage(
              webviewFactory: factory,
              submitCredentials: submit,
              prepareWebview: () async {});
      await _open(tester, page, operations);
      await _start(tester);
      final reading = Completer<Map<String, String>>();
      browsers.first.onTitle(title, _Reader(cookies, cookieGate: reading));
      browsers.first.finish();
      await tester.pump();
      expect(operations.isBusy(key), isFalse);
      expect(submissions, 0);
      await _start(tester);
      reading.complete(cookies);
      await tester.pump();
      expect(submissions, 0);
      expect(browsers.last.closeRequests, 0);
      browsers.last.finish();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('$key save failure stays on login and releases the source lock',
        (tester) async {
      final operations = AccountOperationController();
      addTearDown(operations.dispose);
      late _Browser browser;
      AccountLoginWebview factory(BuildContext context, String url,
              AccountLoginTitle event, VoidCallback close) =>
          browser = _Browser(event, close);
      Future<void> submit(AccountLoginCandidate candidate) async {
        throw StateError('test storage failure');
      }

      final page = eh
          ? EhLoginPage(webviewFactory: factory, submitCredentials: submit)
          : NhentaiLoginPage(
              webviewFactory: factory,
              submitCredentials: submit,
              prepareWebview: () async {});
      await _open(tester, page, operations);
      await _start(tester);
      browser.onTitle(title, _Reader(cookies));
      await tester.pump();
      browser.finish();
      await tester.pump();
      expect(find.byWidget(page), findsOneWidget);
      expect(find.textContaining('test storage failure'), findsOneWidget);
      expect(operations.isBusy(key), isFalse);
      expect(find.text('登录成功'), findsNothing);
    });
  }

  testWidgets(
      'NH cannot submit an existing app JWT without this round evidence',
      (tester) async {
    final operations = AccountOperationController();
    addTearDown(operations.dispose);
    late _Browser browser;
    var submissions = 0;
    await _open(
        tester,
        NhentaiLoginPage(
          prepareWebview: () async {},
          webviewFactory: (context, url, event, close) =>
              browser = _Browser(event, close),
          submitCredentials: (_) async {
            submissions++;
          },
        ),
        operations);
    await _start(tester);
    browser.finish();
    await tester.pump();
    expect(submissions, 0);
    expect(find.byType(NhentaiLoginPage), findsOneWidget);
    expect(find.textContaining('未检测到本次登录会话'), findsOneWidget);
  });

  testWidgets('NH mobile requires a transition away from login',
      (tester) async {
    final operations = AccountOperationController();
    addTearDown(operations.dispose);
    late _Browser browser;
    await _open(
        tester,
        NhentaiLoginPage(
          prepareWebview: () async {},
          webviewFactory: (context, url, event, close) =>
              browser = _Browser(event, close, mobile: true),
          submitCredentials: (_) async {},
        ),
        operations);
    await _start(tester);
    browser.onTitle('Login', _Reader(_nhCookies));
    expect(browser.closeRequests, 0);
    browser.onTitle('nhentai', _Reader(_nhCookies));
    await tester.pump();
    expect(browser.closeRequests, 1);
    browser.finish();
    await tester.pumpAndSettle();
    expect(find.byType(NhentaiLoginPage), findsNothing);
  });

  testWidgets('EH manual submission uses the same source gate', (tester) async {
    final operations = AccountOperationController();
    addTearDown(operations.dispose);
    final saving = Completer<void>();
    var submissions = 0;
    await _open(tester, EhLoginPage(submitCredentials: (candidate) async {
      submissions++;
      await saving.future;
    }), operations);
    await tester.enterText(find.byType(TextField).at(0), 'test-id');
    await tester.enterText(find.byType(TextField).at(1), 'test-hash');
    await tester.ensureVisible(find.widgetWithText(FilledButton, '登录'));
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pump();
    expect(submissions, 1);
    expect(operations.isBusy('ehentai'), isTrue);
    await expectLater(operations.execute<void>('ehentai', () async {}),
        throwsA(isA<AccountOperationBusyException>()));
    saving.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('disposing login closes its window and rejects late credentials',
      (tester) async {
    final operations = AccountOperationController();
    addTearDown(operations.dispose);
    late _Browser browser;
    final reading = Completer<Map<String, String>>();
    var submissions = 0;
    await _open(
        tester,
        EhLoginPage(
          webviewFactory: (context, url, event, close) =>
              browser = _Browser(event, close),
          submitCredentials: (_) async {
            submissions++;
          },
        ),
        operations);
    await _start(tester);
    browser.onTitle(
        'E-Hentai Forums', _Reader(_ehCookies, cookieGate: reading));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(browser.closed, isTrue);
    reading.complete(_ehCookies);
    await tester.pump();
    expect(submissions, 0);
    expect(operations.isBusy('ehentai'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile late title never pops a different root route',
      (tester) async {
    final operations = AccountOperationController();
    addTearDown(operations.dispose);
    late AccountLoginTitle titleEvent;
    final reading = Completer<Map<String, String>>();
    var submissions = 0;
    await _open(
        tester,
        EhLoginPage(
          webviewFactory: (context, url, event, close) =>
              createRouteAccountLoginWebview(context, url, event, close,
                  pageBuilder: (callback) {
            titleEvent = callback;
            return const Scaffold(body: Text('fake-mobile-browser'));
          }),
          submitCredentials: (_) async {
            submissions++;
          },
        ),
        operations);
    await _start(tester);
    await tester.pump(const Duration(milliseconds: 400));
    titleEvent('E-Hentai Forums', _Reader(_ehCookies, cookieGate: reading));
    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.pop();
    await tester.pump();
    navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('unrelated-route'))));
    reading.complete(_ehCookies);
    await tester.pumpAndSettle();
    expect(submissions, 0);
    expect(find.text('unrelated-route'), findsOneWidget);
    expect(find.byType(EhLoginPage, skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('window creation failure restores the actual login page controls',
      (tester) async {
    final operations = AccountOperationController();
    addTearDown(operations.dispose);
    await _open(
        tester,
        NhentaiLoginPage(
          prepareWebview: () async {},
          webviewFactory: (context, url, event, close) =>
              _Browser(event, close)..openError = StateError('create failed'),
          submitCredentials: (_) async => fail('must not submit'),
        ),
        operations);
    await _start(tester);
    expect(operations.isBusy('nhentai'), isFalse);
    expect(operations.hasActiveWebview, isFalse);
    expect(find.textContaining('create failed'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final finishAnimation in [false, true]) {
    testWidgets(
        'leaving during preparation never opens a window '
        '${finishAnimation ? 'after disposal' : 'during the exit animation'}',
        (tester) async {
      final operations = AccountOperationController();
      addTearDown(operations.dispose);
      final preparing = Completer<void>();
      var windows = 0;
      var submissions = 0;
      await _open(
          tester,
          NhentaiLoginPage(
            prepareWebview: () => preparing.future,
            webviewFactory: (context, url, event, close) {
              windows++;
              return _Browser(event, close);
            },
            submitCredentials: (_) async {
              submissions++;
            },
          ),
          operations);
      final pageState = tester.state(find.byType(NhentaiLoginPage));
      final route = ModalRoute.of(pageState.context)!;
      final navigator = Navigator.of(pageState.context);
      await _start(tester);
      expect(operations.isBusy('nhentai'), isTrue);
      navigator.pop();
      await tester.pump();
      if (finishAnimation) {
        await tester.pumpAndSettle();
      }
      expect(pageState.mounted, !finishAnimation);
      expect(route.isCurrent, isFalse);
      preparing.complete();
      await tester.pump();
      expect(windows, 0);
      expect(submissions, 0);
      expect(operations.isBusy('nhentai'), isFalse);
      expect(operations.hasActiveWebview, isFalse);
      await tester.pumpAndSettle();
      expect(find.byType(NhentaiLoginPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'closing during UA collection leaves credentials and UA unchanged',
      (tester) async {
    final operations = AccountOperationController();
    addTearDown(operations.dispose);
    final readingUa = Completer<String?>();
    final previousUa = appdata.implicitData[3];
    late _Browser browser;
    var submissions = 0;
    await _open(
        tester,
        EhLoginPage(
          webviewFactory: (context, url, event, close) =>
              browser = _Browser(event, close),
          submitCredentials: (_) async {
            submissions++;
          },
        ),
        operations);
    await _start(tester);
    final reader = _Reader(_ehCookies, uaGate: readingUa);
    browser.onTitle('E-Hentai Forums', reader);
    await tester.pump();
    expect(reader.reads, 2);
    browser.finish();
    await tester.pump();
    readingUa.complete('late-ua');
    await tester.pump();
    expect(submissions, 0);
    expect(appdata.implicitData[3], previousUa);
    expect(operations.isBusy('ehentai'), isFalse);
    expect(find.byType(EhLoginPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'disposing during window creation keeps the lock until it settles',
      (tester) async {
    final operations = AccountOperationController();
    addTearDown(operations.dispose);
    final creating = Completer<void>();
    late _Browser browser;
    await _open(
        tester,
        EhLoginPage(
          webviewFactory: (context, url, event, close) =>
              browser = _Browser(event, close)..openGate = creating,
          submitCredentials: (_) async => fail('must not submit'),
        ),
        operations);
    await _start(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(browser.closed, isTrue);
    expect(operations.isBusy('ehentai'), isTrue);
    creating.complete();
    await tester.pump();
    expect(operations.isBusy('ehentai'), isFalse);
    expect(operations.hasActiveWebview, isFalse);
    expect(tester.takeException(), isNull);
  });
}
