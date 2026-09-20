import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/pages/online_comic/webview.dart';

const _documentMessage =
    '{"id":"document_created","data":{"title":"Login complete","ua":"test-ua"}}';

class _Window extends Fake implements Webview {
  final closed = Completer<void>();
  OnWebMessageReceivedCallback? messageCallback;
  void Function(String)? navigationCallback;
  Future<String?> Function(String)? evaluate;
  Future<List<Never>> Function()? cookies;
  Object? launchError;
  int launches = 0;
  int closeRequests = 0;
  int reads = 0;
  String? launchedUrl;
  bool? triggerNavigation;

  @override
  Future<void> get onClose => closed.future;

  @override
  void addOnWebMessageReceivedCallback(OnWebMessageReceivedCallback callback) {
    messageCallback = callback;
  }

  @override
  void setOnNavigation(void Function(String)? onNavigation) {
    navigationCallback = onNavigation;
  }

  @override
  void launch(String url, {bool triggerOnUrlRequestEvent = true}) {
    launches++;
    launchedUrl = url;
    triggerNavigation = triggerOnUrlRequestEvent;
    if (launchError != null) throw launchError!;
  }

  @override
  void close() => closeRequests++;

  void nativeClose() {
    if (!closed.isCompleted) closed.complete();
  }

  @override
  Future<String?> evaluateJavaScript(String source) {
    reads++;
    return evaluate?.call(source) ?? Future<String?>.value(null);
  }

  @override
  Future<List<Never>> getAllCookies() =>
      cookies?.call() ?? Future<List<Never>>.value(const []);
}

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
  final PathProviderPlatform originalPaths = PathProviderPlatform.instance;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_webview_');
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
      // 清理失败不影响断言。
    }
  });

  test('A20 创建失败向调用方抛出，不留半挂载句柄', () async {
    var completions = 0;
    final failure = StateError('injected create failure');
    final webview = DesktopWebview(
      initialUrl: 'https://example.test/login',
      windowFactory: (_) => Future<Webview>.error(failure),
      onClose: () => completions++,
    );
    await expectLater(webview.open(), throwsA(same(failure)));
    await webview.close();
    expect(completions, 1);

    // 失败后不应对后续读取留下可用的半挂载状态
    expect(await webview.evaluateJavascript('1'), isNull);
    expect(await webview.getCookies('https://example.test'), isEmpty);
  });

  test('A20 close 幂等：未创建过或重复调用都不抛', () async {
    final webview = DesktopWebview(initialUrl: 'https://example.test/login');

    await webview.close();
    await webview.close();

    expect(await webview.evaluateJavascript('1'), isNull);
  });

  test('A20 未创建窗口时读取接口安全返回，不做空断言崩溃', () async {
    final webview = DesktopWebview(initialUrl: 'https://example.test/login');

    expect(await webview.evaluateJavascript('document.title'), isNull);
    expect(await webview.getCookies('https://example.test'), isEmpty);
    expect(webview.userAgent, isNull);
  });

  testWidgets(
      'A20 wrapper wires native callbacks and close only requests closure',
      (tester) async {
    final window = _Window();
    CreateConfiguration? configuration;
    var closes = 0;
    var starts = 0;
    final titles = <String>[];
    final navigation = <String>[];
    final wrapper = DesktopWebview(
      initialUrl: 'https://example.test/login',
      windowFactory: (value) async {
        configuration = value;
        return window;
      },
      onStarted: (_) => starts++,
      onClose: () => closes++,
      onTitleChange: (title, _) => titles.add(title),
      onNavigation: (url, _) => navigation.add(url),
    );
    await wrapper.open();
    expect(configuration, isNotNull);
    expect(window.launchedUrl, 'https://example.test/login');
    expect(window.triggerNavigation, isFalse);
    window.messageCallback!(_documentMessage);
    window.navigationCallback!('https://example.test/done');
    expect(titles, ['Login complete']);
    expect(navigation, ['https://example.test/done']);
    expect(wrapper.userAgent, 'test-ua');
    await tester.pump(const Duration(milliseconds: 200));
    expect(starts, 1);

    await wrapper.close();
    await wrapper.close();
    expect(window.closeRequests, 1);
    expect(closes, 0, reason: 'A close request is not a native close event.');
    window.messageCallback!(_documentMessage);
    window.navigationCallback!('https://example.test/late');
    expect(titles, hasLength(1));
    expect(navigation, hasLength(1));

    window.nativeClose();
    await tester.pump();
    expect(closes, 1);
    expect(wrapper.timer, isNull);
    expect(wrapper.userAgent, isNull);
  });

  testWidgets('A20 native close suppresses delayed start and all late events',
      (tester) async {
    final window = _Window();
    var closes = 0;
    var callbacks = 0;
    final wrapper = DesktopWebview(
      initialUrl: 'https://example.test/login',
      windowFactory: (_) async => window,
      onStarted: (_) => callbacks++,
      onTitleChange: (_, __) => callbacks++,
      onNavigation: (_, __) => callbacks++,
      onClose: () => closes++,
    );
    await wrapper.open();
    window.nativeClose();
    await tester.pump();
    window.messageCallback!(_documentMessage);
    window.navigationCallback!('https://example.test/late');
    wrapper.onMessage(_documentMessage);
    await tester.pump(const Duration(seconds: 4));
    await wrapper.close();
    window.nativeClose();
    await tester.pump();

    expect(closes, 1);
    expect(callbacks, 0);
    expect(window.reads, 0);
    expect(window.closeRequests, 0);
    expect(wrapper.timer, isNull);
  });

  for (final failReading in [false, true]) {
    testWidgets(
        'A20 polling result after native close is ignored ($failReading)',
        (tester) async {
      final pending = Completer<String?>();
      final window = _Window()..evaluate = (_) => pending.future;
      var titles = 0;
      var closes = 0;
      final wrapper = DesktopWebview(
        initialUrl: 'https://example.test/login',
        windowFactory: (_) async => window,
        onTitleChange: (_, __) => titles++,
        onClose: () => closes++,
      );
      await wrapper.open();
      await tester.pump(const Duration(seconds: 2));
      expect(window.reads, 1);
      window.nativeClose();
      await tester.pump();
      if (failReading) {
        pending.completeError(StateError('native window destroyed'));
      } else {
        pending.complete(_documentMessage);
      }
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(closes, 1);
      expect(titles, 0);
      expect(window.reads, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('A20 in-flight public reads ignore destruction errors',
      (tester) async {
    final script = Completer<String?>();
    final cookies = Completer<List<Never>>();
    final window = _Window();
    window.evaluate = (_) => script.future;
    window.cookies = () => cookies.future;
    final wrapper = DesktopWebview(
      initialUrl: 'https://example.test/login',
      windowFactory: (_) async => window,
    );
    await wrapper.open();
    final scriptResult = wrapper.evaluateJavascript('document.title');
    final cookieResult = wrapper.getCookies('https://example.test');
    window.nativeClose();
    await tester.pump();
    script.completeError(StateError('script window closed'));
    cookies.completeError(StateError('cookie window closed'));
    expect(await scriptResult, isNull);
    expect(await cookieResult, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A20 cancellation during create still receives native completion',
      (tester) async {
    final created = Completer<Webview>();
    final window = _Window();
    var closes = 0;
    var starts = 0;
    final wrapper = DesktopWebview(
      initialUrl: 'https://example.test/login',
      windowFactory: (_) => created.future,
      onClose: () => closes++,
      onStarted: (_) => starts++,
    );
    final opening = wrapper.open();
    await wrapper.close();
    await wrapper.close();
    expect(closes, 0);
    created.complete(window);
    await opening;
    expect(window.closeRequests, 1);
    expect(window.launches, 0);
    expect(window.messageCallback, isNull);
    expect(closes, 0);
    window.nativeClose();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(closes, 1);
    expect(starts, 0);
    expect(wrapper.timer, isNull);
  });

  testWidgets('A20 creation failure after cancellation completes once',
      (tester) async {
    final created = Completer<Webview>();
    var closes = 0;
    final wrapper = DesktopWebview(
      initialUrl: 'https://example.test/login',
      windowFactory: (_) => created.future,
      onClose: () => closes++,
    );
    final expected = expectLater(wrapper.open(), throwsStateError);
    await wrapper.close();
    created.completeError(StateError('creation failed after cancel'));
    await expected;
    await wrapper.close();
    expect(closes, 1);
    expect(wrapper.timer, isNull);
  });

  testWidgets('A20 replaced window events cannot mutate the current generation',
      (tester) async {
    final first = _Window();
    final second = _Window();
    var creations = 0;
    var closes = 0;
    var starts = 0;
    final titles = <String>[];
    final navigation = <String>[];
    final wrapper = DesktopWebview(
      initialUrl: 'https://example.test/login',
      windowFactory: (_) async => ++creations == 1 ? first : second,
      onClose: () => closes++,
      onStarted: (_) => starts++,
      onTitleChange: (title, _) => titles.add(title),
      onNavigation: (url, _) => navigation.add(url),
    );
    await wrapper.open();
    await wrapper.open();
    expect(first.closeRequests, 1);
    first.nativeClose();
    await tester.pump();
    first.messageCallback!(_documentMessage);
    first.navigationCallback!('https://example.test/old');
    second.messageCallback!(jsonEncode({
      'id': 'document_created',
      'data': {'title': 'Current window', 'ua': 'current-ua'},
    }));
    await tester.pump(const Duration(milliseconds: 200));
    expect(titles, ['Current window']);
    expect(navigation, isEmpty);
    expect(wrapper.userAgent, 'current-ua');
    expect(starts, 1);
    expect(closes, 0);
    second.nativeClose();
    await tester.pump();
    expect(closes, 1);
  });

  testWidgets('A20 superseded create closes its own late native window',
      (tester) async {
    final firstCreate = Completer<Webview>();
    final first = _Window();
    final second = _Window();
    var creations = 0;
    var closes = 0;
    final wrapper = DesktopWebview(
      initialUrl: 'https://example.test/login',
      windowFactory: (_) =>
          ++creations == 1 ? firstCreate.future : Future<Webview>.value(second),
      onClose: () => closes++,
    );
    final olderOpen = wrapper.open();
    await wrapper.open();
    firstCreate.complete(first);
    await olderOpen;
    expect(first.launches, 0);
    expect(first.closeRequests, 1);
    first.nativeClose();
    await tester.pump();
    expect(closes, 0);
    expect(second.launches, 1);
    second.nativeClose();
    await tester.pump();
    expect(closes, 1);
  });

  testWidgets('A20 launch failure closes the created window before completion',
      (tester) async {
    final window = _Window()..launchError = StateError('launch failed');
    var closes = 0;
    final wrapper = DesktopWebview(
      initialUrl: 'https://example.test/login',
      windowFactory: (_) async => window,
      onClose: () => closes++,
    );
    await expectLater(wrapper.open(), throwsStateError);
    expect(window.closeRequests, 1);
    expect(closes, 0);
    expect(wrapper.timer, isNull);
    window.nativeClose();
    await tester.pump();
    expect(closes, 1);
  });

  group('A20 生命周期判定（代次与取消）', () {
    test('创建期间取消后不得接管该窗口', () {
      final lifecycle = DesktopWebviewLifecycle();
      final generation = lifecycle.beginOpen();
      expect(lifecycle.canAdopt(generation), isTrue);

      // 用户/上层在 create 还没返回时点了取消
      lifecycle.requestClose();

      expect(lifecycle.closeRequested, isTrue);
      expect(
        lifecycle.canAdopt(generation),
        isFalse,
        reason: '创建中取消必须导致这个窗口被立即关闭，而不是 launch 成一个孤立窗口',
      );
    });

    test('旧代次不能接管新窗口', () {
      final lifecycle = DesktopWebviewLifecycle();
      final first = lifecycle.beginOpen();
      final second = lifecycle.beginOpen();

      expect(lifecycle.isCurrent(first), isFalse);
      expect(
        lifecycle.canAdopt(first),
        isFalse,
        reason: '旧代次 create 晚返回时不能接管新窗口',
      );
      expect(lifecycle.isCurrent(second), isTrue);
      expect(lifecycle.canAdopt(second), isTrue);
    });

    test('上一轮的关闭事件不影响新一轮', () {
      final lifecycle = DesktopWebviewLifecycle();
      final first = lifecycle.beginOpen();
      lifecycle.requestClose();
      final second = lifecycle.beginOpen();

      // 第一轮的 onClose 迟到：不得清掉新一轮的窗口状态
      expect(lifecycle.isCurrent(first), isFalse);
      expect(lifecycle.isCurrent(second), isTrue);
      expect(lifecycle.closeRequested, isFalse);
      expect(lifecycle.canAdopt(second), isTrue);
    });

    test('新一轮 beginOpen 会清掉上一轮的关闭请求', () {
      final lifecycle = DesktopWebviewLifecycle();
      lifecycle.beginOpen();
      lifecycle.requestClose();

      final next = lifecycle.beginOpen();

      expect(lifecycle.closeRequested, isFalse);
      expect(lifecycle.canAdopt(next), isTrue);
    });
  });
}
