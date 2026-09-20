import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/accounts/account_mode_controller.dart';
import 'package:picakeep/pages/accounts/accounts_page.dart';
import 'package:picakeep/pages/accounts/login_page.dart';
import 'package:picakeep/tools/translations.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

typedef _ModeSelector = SegmentedButton<AccountStorageMode>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  late File modeFile;
  late String originalLanguage;
  late List<ComicSource> originalSources;
  final originalPaths = PathProviderPlatform.instance;
  final mode = AccountModeController.instance;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_acct_i18n_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
    modeFile = File('${App.dataPath}/account_mode.json');
    await loadTranslations();
  });

  setUp(() async {
    originalLanguage = appdata.settings[50];
    originalSources = List<ComicSource>.of(ComicSource.sources);
    ComicSource.sources.clear();
    if (await Directory(modeFile.path).exists()) {
      await Directory(modeFile.path).delete(recursive: true);
    }
    await modeFile.parent.create(recursive: true);
    await modeFile.writeAsString('{"mode":"local","fixture":"preserve"}\n');
    await mode.load();
  });

  tearDown(() {
    appdata.settings[50] = originalLanguage;
    ComicSource.sources
      ..clear()
      ..addAll(originalSources);
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    await workspace.delete(recursive: true);
  });

  ComicSource source({required String key, bool loggedIn = false}) {
    return ComicSource.named(
      key: key,
      name: key == 'alpha' ? 'Alpha' : 'Beta',
      data: <String, dynamic>{if (loggedIn) 'token': 'fixture-token'},
      account: AccountConfig(
        login: (_, __) async => const Res(true),
        registerWebsite: 'https://example.test/register',
        infoItems: () async => const Res(<AccountInfoItem>[
          AccountInfoItem(title: '用户名', value: 'fixture-user'),
        ]),
        reLogin: () async => const Res(true),
      ),
    );
  }

  Future<void> waitForModeReady(WidgetTester tester) async {
    // File I/O uses the real event loop; wait for the actual UI completion.
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (tester
              .widget<_ModeSelector>(find.byType(_ModeSelector))
              .onSelectionChanged !=
          null) {
        return;
      }
    }
    fail('The account mode operation did not finish.');
  }

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: page));
    if (page is AccountsPage) await waitForModeReady(tester);
    await tester.pumpAndSettle();
  }

  const cases = [
    (
      language: 'en',
      accounts: 'Accounts',
      local: 'Local',
      loggedIn: 'Logged in',
      loggedOut: 'Login required',
      login: 'Log In',
      relogin: 'Re-login',
      logout: 'Log Out',
      username: 'Username',
      password: 'Password',
      loginTitle: 'Log in to Alpha',
      continueLabel: 'Continue',
      register: 'Register',
      validation: 'Enter your username and password',
      nasNotice: 'NAS account management is not available yet',
      saveError: 'Save failed: ',
    ),
    (
      language: 'tw',
      accounts: '帳號管理',
      local: '本機',
      loggedIn: '已登入',
      loggedOut: '未登入',
      login: '登入',
      relogin: '重新登入',
      logout: '退出登入',
      username: '使用者名稱',
      password: '密碼',
      loginTitle: '登入 Alpha',
      continueLabel: '繼續',
      register: '註冊',
      validation: '請輸入使用者名稱和密碼',
      nasNotice: 'NAS 帳號管理尚未接入',
      saveError: '儲存失敗：',
    ),
  ];

  for (final labels in cases) {
    group(labels.language, () {
      setUp(() => appdata.settings[50] = labels.language);

      testWidgets('account overview renders translated account actions',
          (tester) async {
        ComicSource.sources.addAll([
          source(key: 'alpha', loggedIn: true),
          source(key: 'beta'),
        ]);

        await pumpPage(tester, const AccountsPage());

        for (final text in [
          labels.accounts,
          labels.local,
          labels.loggedIn,
          labels.loggedOut,
          labels.login,
          labels.relogin,
          labels.logout,
          labels.username,
          'fixture-user',
        ]) {
          expect(find.text(text), findsOneWidget, reason: text);
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('login form and empty submission use translated labels',
          (tester) async {
        await pumpPage(tester, LoginPage(source: source(key: 'alpha')));

        expect(find.text(labels.loginTitle), findsOneWidget);
        expect(find.text(labels.username), findsOneWidget);
        expect(find.text(labels.password), findsOneWidget);
        expect(find.text(labels.register), findsOneWidget);
        await tester.tap(find.text(labels.continueLabel));
        await tester.pump();

        expect(find.text(labels.validation), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('NAS remains a placeholder and preserves the mode file',
          (tester) async {
        final before = (await tester.runAsync(modeFile.readAsBytes))!;
        await pumpPage(tester, const AccountsPage());

        await tester.tap(find.text('NAS'));
        await tester.pumpAndSettle();

        expect(find.text(labels.nasNotice), findsOneWidget);
        expect(mode.mode, AccountStorageMode.local);
        expect(
          tester.widget<_ModeSelector>(find.byType(_ModeSelector)).selected,
          {AccountStorageMode.local},
        );
        final after = await tester.runAsync(modeFile.readAsBytes);
        expect(after, orderedEquals(before));
        expect(tester.takeException(), isNull);
      });

      testWidgets('failed local save is visible and preserves the active mode',
          (tester) async {
        await pumpPage(tester, const AccountsPage());
        await tester.runAsync(() async {
          await modeFile.delete();
          await Directory(modeFile.path).create();
        });
        final before = mode.mode;

        // Local is already selected. Invoke the widget's public selection
        // callback to cover its save/error path without changing production UI.
        tester
            .widget<_ModeSelector>(find.byType(_ModeSelector))
            .onSelectionChanged!({AccountStorageMode.local});
        await waitForModeReady(tester);
        await tester.pumpAndSettle();

        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                (widget.data?.startsWith(labels.saveError) ?? false),
          ),
          findsOneWidget,
        );
        expect(mode.mode, before);
        expect(
          tester.widget<_ModeSelector>(find.byType(_ModeSelector)).selected,
          {before},
        );
        expect(tester.takeException(), isNull);
      });
    });
  }

  test('failed persistence cannot publish a different in-memory mode',
      () async {
    await modeFile.delete();
    await Directory(modeFile.path).create();

    await expectLater(
      mode.save(AccountStorageMode.nas),
      throwsA(isA<FileSystemException>()),
    );

    expect(mode.mode, AccountStorageMode.local);
  });
}
