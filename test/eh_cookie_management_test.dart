import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/pages/accounts/account_operation_scope.dart';
import 'package:picakeep/pages/accounts/eh_cookie_management_view.dart';
import 'package:sqlite3/open.dart';

/// A11–A13：EH cookies 管理区的复制与双域 igneous 改写语义。
///
/// 写入语义用临时 CookieJarSql 验证；复制用真实组件 + mock 剪贴板通道验证。

class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

/// 可在指定次序注入写入失败的 jar：用于验证"第二域失败 → 快照恢复"与"恢复也失败"。
///
/// 播种阶段不受影响：只有显式 [failFrom] 之后的写入才计数。
class _FailingJar extends CookieJarSql {
  _FailingJar(super.path);

  bool _armed = false;
  bool _forever = false;
  int _failFrom = 0;
  int _counted = 0;

  /// 从下一次写入起计数：第 [failFromWrite] 次（1 起算）抛错。
  /// [forever] 为 true 时此后每次写入都失败（连补偿恢复也失败）。
  void failFrom({required int failFromWrite, bool forever = false}) {
    _armed = true;
    _forever = forever;
    _failFrom = failFromWrite;
    _counted = 0;
  }

  @override
  void saveFromResponse(Uri uri, List<Cookie> cookies) {
    if (_armed) {
      _counted++;
      if (_counted >= _failFrom) {
        if (!_forever) {
          _armed = false;
        }
        throw StateError('simulated write failure #$_counted');
      }
    }
    super.saveFromResponse(uri, cookies);
  }
}

class _RouteObserver extends NavigatorObserver {
  int dialogPushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is DialogRoute) dialogPushes++;
  }
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
    workspace = await Directory.systemTemp.createTemp('picakeep_eh_cookie_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
  });

  tearDownAll(() async {
    EhNetwork().cookieJar.dispose();
    PathProviderPlatform.instance = originalPaths;
    try {
      if (await workspace.exists()) {
        await workspace.delete(recursive: true);
      }
    } catch (_) {}
  });

  Cookie seed(String host, String name, String value) => Cookie(name, value)
    ..domain = host
    ..path = '/';

  CookieJarSql openJar(String fileName) =>
      CookieJarSql('${workspace.path}${Platform.pathSeparator}$fileName');

  String valueOf(CookieJarSql jar, String site, String name) {
    var value = '';
    for (final cookie in jar.loadForRequest(Uri.parse(site))) {
      if (cookie.name == name) value = cookie.value;
    }
    return value;
  }

  bool hasCookie(CookieJarSql jar, String site, String name) =>
      jar.loadForRequest(Uri.parse(site)).any((cookie) => cookie.name == name);

  void seedIdentity(CookieJarSql jar) {
    for (final site in kEhCookieSites) {
      final host = Uri.parse(site).host;
      jar.saveFromResponse(Uri.parse(site), <Cookie>[
        seed(host, 'ipb_member_id', 'member-$host'),
        seed(host, 'ipb_pass_hash', 'hash-$host'),
        seed(host, 'igneous', 'old-$host'),
        seed(host, 'nw', '1'),
      ]);
    }
  }

  group('A12 igneous 双域改写', () {
    test('修改后两域各生效一份，其它身份与偏好 Cookie 保留', () async {
      final jar = openJar('a12a.db');
      seedIdentity(jar);

      await applyEhIgneousValue(jar, '  new-igneous  ');

      expect(valueOf(jar, kEhCookieSites[0], 'igneous'), 'new-igneous');
      expect(valueOf(jar, kEhCookieSites[1], 'igneous'), 'new-igneous');
      for (final site in kEhCookieSites) {
        expect(valueOf(jar, site, 'ipb_member_id'), startsWith('member-'));
        expect(valueOf(jar, site, 'ipb_pass_hash'), startsWith('hash-'));
        expect(valueOf(jar, site, 'nw'), '1');
      }
      jar.dispose();
    });

    test('空值移除两域 igneous，且不影响其它 Cookie', () async {
      final jar = openJar('a12b.db');
      seedIdentity(jar);

      await applyEhIgneousValue(jar, '   ');

      for (final site in kEhCookieSites) {
        expect(hasCookie(jar, site, 'igneous'), isFalse);
        expect(hasCookie(jar, site, 'ipb_member_id'), isTrue);
        expect(hasCookie(jar, site, 'ipb_pass_hash'), isTrue);
      }
      jar.dispose();
    });

    test('非法值被拒绝且不写库', () async {
      final jar = openJar('a12c.db');
      seedIdentity(jar);

      await expectLater(
        applyEhIgneousValue(jar, 'bad;value'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        applyEhIgneousValue(jar, 'bad value'),
        throwsA(isA<FormatException>()),
      );

      for (final site in kEhCookieSites) {
        expect(valueOf(jar, site, 'igneous'), startsWith('old-'));
      }
      jar.dispose();
    });

    test('相同值重复写入是幂等的', () async {
      final jar = openJar('a12d.db');
      seedIdentity(jar);

      await applyEhIgneousValue(jar, 'same');
      await applyEhIgneousValue(jar, 'same');

      for (final site in kEhCookieSites) {
        expect(valueOf(jar, site, 'igneous'), 'same');
      }
      jar.dispose();
    });
  });

  group('A13 写入失败与恢复', () {
    test('第二域失败恢复只触碰 igneous，完整保留 host/点域身份记录', () async {
      final jar = _FailingJar('${workspace.path}/duplicate-identities.db');
      addTearDown(jar.dispose);
      final uris = kEhCookieSites.map(Uri.parse).toList();
      for (final uri in uris) {
        jar.saveFromResponse(uri, <Cookie>[
          seed(uri.host, 'ipb_member_id', 'host-member'),
          seed('.${uri.host}', 'ipb_member_id', 'dot-member'),
          seed(uri.host, 'ipb_pass_hash', 'host-hash')..httpOnly = true,
          seed('.${uri.host}', 'ipb_pass_hash', 'dot-hash')..secure = true,
          seed(uri.host, 'igneous', 'host-igneous'),
          seed('.${uri.host}', 'igneous', 'dot-igneous'),
          seed(uri.host, 'nw', '1'),
        ]);
      }
      List<String> snapshot() {
        final rows = <String>[
          for (final uri in uris)
            for (final cookie in jar.loadForRequest(uri))
              jsonEncode([
                cookie.name,
                cookie.value,
                cookie.domain,
                cookie.path,
                cookie.expires?.millisecondsSinceEpoch,
                cookie.secure,
                cookie.httpOnly,
              ]),
        ]..sort();
        return rows;
      }

      final before = snapshot();
      jar.failFrom(failFromWrite: 2);
      await expectLater(
        applyEhIgneousValue(jar, 'changed'),
        throwsA(isA<StateError>()),
      );
      expect(snapshot(), before);
    });

    test('第二域写入失败时按快照恢复，不残留半写状态', () async {
      final jar = _FailingJar(
        '${workspace.path}${Platform.pathSeparator}a13a.db',
      );
      seedIdentity(jar);
      // 播种完成后再武装：第一次写入（第一域）成功，第二次（第二域）失败。
      jar.failFrom(failFromWrite: 2);

      await expectLater(
        applyEhIgneousValue(jar, 'should-not-persist'),
        throwsA(isA<StateError>()),
      );

      // 恢复后两域都回到旧值，其它 Cookie 仍在
      for (final site in kEhCookieSites) {
        expect(valueOf(jar, site, 'igneous'), startsWith('old-'));
        expect(hasCookie(jar, site, 'ipb_member_id'), isTrue);
      }
      jar.dispose();
    });

    test('恢复也失败时抛出明确错误，不谎报成功', () async {
      final jar = _FailingJar(
        '${workspace.path}${Platform.pathSeparator}a13b.db',
      );
      seedIdentity(jar);
      jar.failFrom(failFromWrite: 2, forever: true);

      await expectLater(
        applyEhIgneousValue(jar, 'value'),
        throwsA(isA<StateError>()),
      );
      jar.dispose();
    });
  });

  group('A11 cookies 折叠区与复制', () {
    testWidgets('默认折叠，展开后可复制完整值', (tester) async {
      final jar = EhNetwork().cookieJar;
      for (final site in kEhCookieSites) {
        final host = Uri.parse(site).host;
        jar.saveFromResponse(Uri.parse(site), <Cookie>[
          seed(host, 'ipb_member_id', 'member-id-value'),
          seed(host, 'ipb_pass_hash', 'pass-hash-value'),
          seed(host, 'igneous', 'igneous-value'),
        ]);
      }

      final clipboardCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardCalls.add(call);
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: EhCookieManagementView()),
        ),
      );
      await tester.pump();

      // 默认折叠：三项都不展示
      expect(find.text('cookies'), findsOneWidget);
      expect(find.text('ipb_member_id'), findsNothing);

      await tester.tap(find.text('cookies'));
      await tester.pump();

      expect(find.text('ipb_member_id'), findsOneWidget);
      expect(find.text('ipb_pass_hash'), findsOneWidget);
      expect(find.text('igneous'), findsOneWidget);
      // 只有 igneous 可编辑
      expect(find.byTooltip('编辑 igneous'), findsOneWidget);

      await tester.tap(find.text('ipb_member_id'));
      await tester.pump();

      expect(clipboardCalls, hasLength(1));
      final arguments = clipboardCalls.single.arguments as Map;
      expect(arguments['text'], 'member-id-value');
      expect(find.text('已复制'), findsOneWidget);
    });

    testWidgets('A11 复制失败时提示错误，不假装成功', (tester) async {
      final site = kEhCookieSites.first;
      EhNetwork().cookieJar.saveFromResponse(Uri.parse(site), <Cookie>[
        seed(Uri.parse(site).host, 'ipb_member_id', 'copy-me'),
      ]);

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'clipboard-unavailable');
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: EhCookieManagementView())),
      );
      await tester.pump();
      await tester.tap(find.text('cookies'));
      await tester.pump();
      await tester.tap(find.text('ipb_member_id'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('复制失败'), findsOneWidget);
      expect(find.text('已复制'), findsNothing);
    });

    testWidgets('A11 超长值完整展示并可复制原始值', (tester) async {
      final longValue = 'v' * 240;
      final site = kEhCookieSites.first;
      EhNetwork().cookieJar.saveFromResponse(Uri.parse(site), <Cookie>[
        seed(Uri.parse(site).host, 'ipb_pass_hash', longValue),
      ]);

      final clipboardCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') clipboardCalls.add(call);
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: EhCookieManagementView())),
      );
      await tester.pump();
      await tester.tap(find.text('cookies'));
      await tester.pump();

      // 不截断：完整长值能在界面上找到
      expect(find.text(longValue), findsOneWidget);

      await tester.tap(find.text('ipb_pass_hash'));
      await tester.pump();
      final arguments = clipboardCalls.single.arguments as Map;
      expect(arguments['text'], longValue);
    });
  });

  group('A12/A13 编辑交互', () {
    Future<void> openEditor(
      WidgetTester tester,
      CookieJarSql jar, {
      AccountOperationController? operations,
      NavigatorObserver? rootObserver,
      NavigatorObserver? innerObserver,
    }) async {
      Widget child = Navigator(
        observers: [if (innerObserver != null) innerObserver],
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: EhCookieManagementView(cookieJar: jar),
          ),
        ),
      );
      if (operations != null) {
        child = AccountOperationScope(controller: operations, child: child);
      }
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [if (rootObserver != null) rootObserver],
        home: child,
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('cookies'));
      await tester.pump();
      await tester.tap(find.byTooltip('编辑 igneous'));
      await tester.pumpAndSettle();
    }

    testWidgets('非法输入保留弹窗，成功保存后才关闭内层对话框', (tester) async {
      final jar = openJar('dialog-validation.db');
      addTearDown(jar.dispose);
      seedIdentity(jar);
      final rootObserver = _RouteObserver();
      final innerObserver = _RouteObserver();
      await openEditor(tester, jar,
          rootObserver: rootObserver, innerObserver: innerObserver);
      expect(rootObserver.dialogPushes, 0);
      expect(innerObserver.dialogPushes, 1);

      await tester.enterText(find.byType(TextField), 'bad;value');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('igneous 包含无效字符'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'bad;value');
      expect(valueOf(jar, kEhCookieSites.first, 'igneous'), startsWith('old-'));

      await tester.enterText(find.byType(TextField), 'valid-value');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('已保存'), findsOneWidget);
      for (final site in kEhCookieSites) {
        expect(valueOf(jar, site, 'igneous'), 'valid-value');
      }
    });

    testWidgets('写失败保留输入与弹窗，重试后双域保存成功', (tester) async {
      final jar = _FailingJar('${workspace.path}/dialog-retry.db');
      addTearDown(jar.dispose);
      seedIdentity(jar);
      await openEditor(tester, jar);
      jar.failFrom(failFromWrite: 2);
      await tester.enterText(find.byType(TextField), 'retry-value');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(find.text('已保存'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'retry-value');

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(valueOf(jar, kEhCookieSites.first, 'igneous'), 'retry-value');
    });

    testWidgets('编辑途中同源有操作时不能把其完成误报为保存成功', (tester) async {
      final jar = openJar('dialog-busy.db');
      addTearDown(jar.dispose);
      seedIdentity(jar);
      final operations = AccountOperationController();
      addTearDown(operations.dispose);
      await openEditor(tester, jar, operations: operations);
      final gate = Completer<void>();
      final running = operations.execute<void>(
        'ehentai',
        () => gate.future,
        operation: 'loadInfo',
      );
      await tester.enterText(find.byType(TextField), 'not-saved');
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(find.text('账号操作正在进行，请稍候'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('已保存'), findsNothing);
      expect(valueOf(jar, kEhCookieSites.first, 'igneous'), startsWith('old-'));
      gate.complete();
      await running;
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });

    testWidgets('取消和相同值均不写入 Cookie', (tester) async {
      final jar = _FailingJar('${workspace.path}/dialog-no-write.db');
      addTearDown(jar.dispose);
      seedIdentity(jar);
      await openEditor(tester, jar);
      jar.failFrom(failFromWrite: 1, forever: true);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('已保存'), findsNothing);

      await tester.tap(find.byTooltip('编辑 igneous'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'not-saved');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsNothing);
      expect(valueOf(jar, kEhCookieSites.first, 'igneous'), startsWith('old-'));
    });
  });

  group('A13 恢复后的完整属性', () {
    test('恢复后目标项的值与 path/expires/secure/httpOnly 逐项一致', () async {
      final jar = _FailingJar(
        '${workspace.path}${Platform.pathSeparator}a13c.db',
      );
      final site = kEhCookieSites.first;
      final host = Uri.parse(site).host;
      final expires = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch + 86400000,
      );

      jar.saveFromResponse(Uri.parse(site), <Cookie>[
        Cookie('igneous', 'original-value')
          ..domain = host
          ..path = '/'
          ..expires = expires
          ..secure = true
          ..httpOnly = true,
      ]);
      // 第一次写入就失败：直接走补偿恢复
      jar.failFrom(failFromWrite: 1);

      await expectLater(
        applyEhIgneousValue(jar, 'changed-value'),
        throwsA(isA<StateError>()),
      );

      final restored = jar
          .loadForRequest(Uri.parse(site))
          .firstWhere((cookie) => cookie.name == 'igneous');
      expect(restored.value, 'original-value');
      expect(restored.path, '/');
      expect(restored.secure, isTrue);
      expect(restored.httpOnly, isTrue);
      expect(
        restored.expires?.millisecondsSinceEpoch,
        expires.millisecondsSinceEpoch,
      );
      jar.dispose();
    });

    test('原本没有 igneous 时，失败恢复后仍然没有', () async {
      final jar = _FailingJar(
        '${workspace.path}${Platform.pathSeparator}a13d.db',
      );
      final site = kEhCookieSites.first;

      jar.saveFromResponse(Uri.parse(site), <Cookie>[
        seed(Uri.parse(site).host, 'ipb_member_id', 'identity'),
      ]);
      jar.failFrom(failFromWrite: 1);

      await expectLater(
        applyEhIgneousValue(jar, 'new-value'),
        throwsA(isA<StateError>()),
      );

      final cookies = jar.loadForRequest(Uri.parse(site));
      expect(
        cookies.any((cookie) => cookie.name == 'igneous'),
        isFalse,
        reason: '恢复空快照不能凭写入凭空造出一份 igneous',
      );
      expect(
        cookies.any((cookie) => cookie.name == 'ipb_member_id'),
        isTrue,
      );
      jar.dispose();
    });
  });
}
