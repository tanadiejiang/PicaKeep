import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/ui_mode.dart';
import 'package:picakeep/tools/system_proxy.dart';
import 'package:picakeep/tools/extensions.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:url_launcher/url_launcher_string.dart';

export 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show WebUri, URLRequest;

/// 移植自上游 PicaComic 的 webview 页面。
///
/// 移动端基于 flutter_inappwebview（AppWebview），桌面端基于
/// desktop_webview_window（DesktopWebview）。供 ehentai 登录抓 cookie 使用。
/// 适配点：包名改 picakeep；上游 `proxyHttpOverrides` 不存在，桌面代理改读
/// `appdata.settings[8]`（手动代理，'0'/空走系统代理）。
extension WebviewExtension on InAppWebViewController {
  Future<Map<String, String>?> getCookies(String url) async {
    if (url.contains('https://')) {
      url.replaceAll('https://', '');
    }
    if (url[url.length - 1] == '/') {
      url = url.substring(0, url.length - 1);
    }
    CookieManager cookieManager = CookieManager.instance();
    final cookies = await cookieManager.getCookies(url: WebUri(url));
    Map<String, String> res = {};
    for (var cookie in cookies) {
      res[cookie.name] = cookie.value;
    }
    return res;
  }

  Future<String?> getUA() async {
    var res = await evaluateJavascript(source: 'navigator.userAgent');
    if (res is String) {
      if (res[0] == "'" || res[0] == '"') {
        res = res.substring(1, res.length - 1);
      }
    }
    return res is String ? res : null;
  }
}

/// 把 webview 当前 URL 转成完整字符串；null / 空串视为不可用（返回 null）。
///
/// 修复点：WebUri.path 只返回 URI 的路径分量（https://soutubot.moe/ 的
/// path 是 "/"），拿去打开浏览器或复制都是错的；必须用 toString() 取完整 URL。
String? webviewFullUrl(WebUri? url) {
  final s = url?.toString().trim();
  if (s == null || s.isEmpty) return null;
  return s;
}

class AppWebview extends StatefulWidget {
  const AppWebview(
      {required this.initialUrl,
      this.onTitleChange,
      this.onNavigation,
      this.singlePage = false,
      this.onStarted,
      super.key});

  final String initialUrl;

  final void Function(String title, InAppWebViewController controller)?
      onTitleChange;

  final bool Function(String url)? onNavigation;

  final void Function(InAppWebViewController controller)? onStarted;

  final bool singlePage;

  @override
  State<AppWebview> createState() => _AppWebviewState();
}

class _AppWebviewState extends State<AppWebview> {
  InAppWebViewController? controller;

  String title = 'Webview';

  double _progress = 0;

  /// 取代理地址：手填 settings[8] > 系统代理 > 空（直连）。
  Future<String> _resolveProxy() async {
    var proxy = appdata.settings[8].trim();
    if (proxy.isEmpty || proxy == '0') {
      proxy = (await getSystemProxy())?.trim() ?? '';
    }
    return proxy;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    bool useCustomAppBar = !UiMode.m1(context) && !widget.singlePage;

    final actions = [
      Tooltip(
        message: 'More',
        child: IconButton(
          icon: const Icon(Icons.more_horiz),
          onPressed: () {
            showMenu(
                context: context,
                position: RelativeRect.fromLTRB(
                    MediaQuery.of(context).size.width,
                    0,
                    MediaQuery.of(context).size.width,
                    0),
                items: [
                  PopupMenuItem(
                    child: Text('在浏览器中打开'.tl),
                    onTap: () async {
                      final url = webviewFullUrl(await controller?.getUrl());
                      if (url == null) {
                        _showMessage('页面尚未加载完成，无法获取链接'.tl);
                        return;
                      }
                      try {
                        final ok = await launchUrlString(
                          url,
                          mode: LaunchMode.externalApplication,
                        );
                        if (!ok) {
                          _showMessage('打开浏览器失败'.tl);
                        }
                      } catch (e) {
                        Log.error('AppWebview', '在浏览器中打开失败: $e');
                        _showMessage('打开浏览器失败'.tl);
                      }
                    },
                  ),
                  PopupMenuItem(
                    child: Text('复制链接'.tl),
                    onTap: () async {
                      final url = webviewFullUrl(await controller?.getUrl());
                      if (url == null) {
                        _showMessage('页面尚未加载完成，无法获取链接'.tl);
                        return;
                      }
                      await Clipboard.setData(ClipboardData(text: url));
                      _showMessage('已复制链接'.tl);
                    },
                  ),
                  PopupMenuItem(
                    child: Text('重新加载'.tl),
                    onTap: () {
                      if (controller == null) {
                        _showMessage('Webview 尚未初始化，无法重新加载'.tl);
                        return;
                      }
                      controller!.reload();
                    },
                  ),
                ]);
          },
        ),
      )
    ];

    Widget body = InAppWebView(
      // 不预填 initialUrlRequest，避免 WebView 抢在代理设好之前就开始加载。
      // URL 在 onWebViewCreated 里先设代理再 loadUrl。
      initialSettings: InAppWebViewSettings(
        // 显式设现代 Chrome UA，避免系统 WebView 默认 UA 被 CF 识别为可疑客户端。
        userAgent: 'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36'
            ' (KHTML, like Gecko) Chrome/149.0.7827.201 Mobile Safari/537.36',
        javaScriptEnabled: true,
        domStorageEnabled: true,
        thirdPartyCookiesEnabled: true,
        useHybridComposition: true,
      ),
      // 隐身脚本：在任何页面 JS 执行前注入，覆盖 WebView 暴露给 CF 指纹检测的标识符。
      // navigator.webdriver=true 是 CF Turnstile 识别 WebView/自动化客户端的主要依据。
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source: r'''
            try {
              // 覆盖 webdriver 标识（CF 据此判断是否为自动化 WebView）
              Object.defineProperty(navigator, 'webdriver', {
                get: () => undefined,
                configurable: true,
              });
              // 补充 window.chrome（真实 Chrome 有，裸 WebView 没有）
              if (!window.chrome) {
                window.chrome = { runtime: {}, loadTimes: function(){}, csi: function(){} };
              }
              // 补充 navigator.plugins（真实浏览器有，WebView 通常为空）
              if (navigator.plugins.length === 0) {
                Object.defineProperty(navigator, 'plugins', {
                  get: () => [{ name: 'Chrome PDF Plugin' }],
                  configurable: true,
                });
              }
            } catch(e) {}
          ''',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      onTitleChanged: (c, t) {
        if (mounted) {
          setState(() {
            title = t ?? 'Webview';
          });
        }
        widget.onTitleChange?.call(title, controller!);
      },
      shouldOverrideUrlLoading: (c, r) async {
        var res =
            widget.onNavigation?.call(r.request.url?.toString() ?? '') ?? false;
        if (res) {
          return NavigationActionPolicy.CANCEL;
        } else {
          return NavigationActionPolicy.ALLOW;
        }
      },
      onWebViewCreated: (c) async {
        controller = c;
        widget.onStarted?.call(c);
        // 代理必须在加载 URL 之前设好，否则首屏请求走直连、CF challenge 子请求被墙。
        final proxy = await _resolveProxy();
        if (proxy.isNotEmpty) {
          try {
            await ProxyController.instance().setProxyOverride(
              settings: ProxySettings(
                proxyRules: [ProxyRule(url: proxy)],
              ),
            );
          } catch (e) {
            Log.error('AppWebview', 'setProxyOverride 失败，降级直连: $e');
          }
        }
        // 代理就绪后再加载目标 URL。
        await c.loadUrl(
          urlRequest: URLRequest(url: WebUri(widget.initialUrl)),
        );
      },
      onProgressChanged: (c, p) {
        if (mounted) {
          setState(() {
            _progress = p / 100;
          });
        }
      },
    );

    body = Stack(
      children: [
        Positioned.fill(child: body),
        if (_progress < 1.0)
          const Positioned.fill(
              child: Center(child: CircularProgressIndicator()))
      ],
    );

    if (useCustomAppBar) {
      body = Column(
        children: [
          Appbar(
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: actions,
          ),
          Expanded(child: body)
        ],
      );
    }

    return Scaffold(
        appBar: !useCustomAppBar
            ? AppBar(
                title: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                actions: actions,
              )
            : null,
        body: body);
  }
}

class DesktopWebview {
  static Future<bool> isAvailable() => WebviewWindow.isWebviewAvailable();

  final String initialUrl;

  final void Function(String title, DesktopWebview controller)? onTitleChange;

  final void Function(String url, DesktopWebview webview)? onNavigation;

  final void Function(DesktopWebview controller)? onStarted;

  final void Function()? onClose;

  DesktopWebview(
      {required this.initialUrl,
      this.onTitleChange,
      this.onNavigation,
      this.onStarted,
      this.onClose,
      @visibleForTesting
      Future<Webview> Function(CreateConfiguration configuration)?
          windowFactory})
      : _windowFactory = windowFactory ?? _createWindow;

  final Future<Webview> Function(CreateConfiguration configuration)
      _windowFactory;

  static Future<Webview> _createWindow(CreateConfiguration configuration) =>
      WebviewWindow.create(configuration: configuration);

  Webview? _webview;
  int _generation = 0;
  Timer? _startedTimer;

  String? _ua;

  String? title;

  void onMessage(String message) {
    final webview = _webview;
    if (webview != null) _onMessage(message, _generation, webview);
  }

  bool _isActive(int generation, Webview webview) =>
      _lifecycle.canAdopt(generation) && identical(_webview, webview);

  void _onMessage(String message, int generation, Webview webview) {
    if (!_isActive(generation, webview) || message.isEmpty) return;
    final dynamic decoded;
    try {
      decoded = jsonDecode(message);
    } on FormatException {
      return;
    }
    if (decoded is! Map || decoded['id'] != 'document_created') return;
    final data = decoded['data'];
    if (data is! Map || data['title'] is! String) return;
    title = data['title'] as String;
    _ua = data['ua'] is String ? data['ua'] as String : null;
    onTitleChange?.call(title!, this);
  }

  String? get userAgent => _ua;

  Timer? timer;

  /// 生命周期判定（代次、关闭请求）。抽成独立小类是为了让"创建中取消、
  /// 旧代次不接管新窗口"这两条语义可以被直接验证，而不必启动真实平台窗口。
  final DesktopWebviewLifecycle _lifecycle = DesktopWebviewLifecycle();

  void _stopTimer() {
    timer?.cancel();
    timer = null;
    _startedTimer?.cancel();
    _startedTimer = null;
  }

  void _finishClose(int generation) {
    if (!_lifecycle.finishClose(generation)) return;
    _webview = null;
    _ua = null;
    title = null;
    _stopTimer();
    onClose?.call();
  }

  void _runTimer(int generation) {
    timer ??= Timer.periodic(const Duration(seconds: 2), (t) async {
      // 已关闭或已换代时不再读取：否则旧窗口的读取异常会抛成无人处理的计时器错误。
      if (!_lifecycle.isCurrent(generation) || _lifecycle.closeRequested) {
        return;
      }
      final webview = _webview;
      if (webview == null) return;
      const js = '''
        function collect() {
          if(document.readyState === 'loading') {
            return '';
          }
          let data = {
            id: "document_created",
            data: {
              title: document.title,
              url: location.href,
              ua: navigator.userAgent
            }
          };
          return data;
        }
        collect();
      ''';
      try {
        final result = await webview.evaluateJavaScript(js);
        if (!_isActive(generation, webview)) return;
        _onMessage(result ?? '', generation, webview);
      } catch (_) {
        // 关闭过程中的读取失败按噪声收束，不再向上抛。
      }
    });
  }

  /// 桌面端手动代理：上游用 proxyHttpOverrides，PicaKeep 改读 settings[8]
  /// （非 '0'/空即手动代理地址，否则 null 走系统代理）。
  String? get _proxyStr {
    final manual = appdata.settings[8].trim();
    if (manual.isNotEmpty && manual != '0') {
      return manual;
    }
    return null;
  }

  /// 创建并挂载窗口。
  ///
  /// 返回表示"窗口已创建并发出 launch 请求"；用户真正**完成**（关闭窗口）由 [onClose]
  /// 表示——两者不是同一个完成信号。创建失败会向调用方抛出，由登录页复位并提示。
  Future<void> open() async {
    final previous = _webview;
    _stopTimer();
    _webview = null;
    _ua = null;
    title = null;
    final generation = _generation = _lifecycle.beginOpen();
    Webview? created;
    try {
      // Retiring an older window must not complete the newly opened generation.
      previous?.close();
      final webview = created = await _windowFactory(CreateConfiguration(
        useWindowPositionAndSize: true,
        userDataFolderWindows: '${App.dataPath}\\webview',
        title: 'webview',
        proxy: _proxyStr,
      ));

      // Subscribe before any cancellation/launch can close the native window.
      unawaited(webview.onClose.then((_) => _finishClose(generation)));
      if (!_lifecycle.canAdopt(generation)) {
        webview.close();
        return;
      }

      _webview = webview;
      webview.addOnWebMessageReceivedCallback(
          (message) => _onMessage(message, generation, webview));
      webview.setOnNavigation((url) {
        if (_isActive(generation, webview)) onNavigation?.call(url, this);
      });
      webview.launch(initialUrl, triggerOnUrlRequestEvent: false);
      _runTimer(generation);
      _startedTimer = Timer(const Duration(milliseconds: 200), () {
        if (_isActive(generation, webview)) onStarted?.call(this);
      });
    } catch (_) {
      if (_lifecycle.isCurrent(generation)) {
        _lifecycle.requestClose();
        _stopTimer();
      }
      if (created == null) {
        // No native window exists to produce onClose for a failed creation.
        _finishClose(generation);
      } else {
        created.close();
      }
      rethrow;
    }
  }

  Future<String?> evaluateJavascript(String source) async {
    final webview = _webview;
    // 窗口已关闭/尚未创建时返回 null，调用方按"没抓到"处理，不做空断言崩溃。
    final generation = _generation;
    if (webview == null || !_isActive(generation, webview)) return null;
    try {
      final result = await webview.evaluateJavaScript(source);
      return _isActive(generation, webview) ? result : null;
    } catch (_) {
      if (!_isActive(generation, webview)) return null;
      rethrow;
    }
  }

  Future<Map<String, String>> getCookies(String url) async {
    final webview = _webview;
    final generation = _generation;
    if (webview == null || !_isActive(generation, webview)) return {};
    try {
      final allCookies = await webview.getAllCookies();
      if (!_isActive(generation, webview)) return {};
      final result = <String, String>{};
      for (final cookie in allCookies) {
        if (_cookieMatch(url, cookie.domain)) {
          result[_removeCode0(cookie.name)] = _removeCode0(cookie.value);
        }
      }
      return result;
    } catch (_) {
      if (!_isActive(generation, webview)) return {};
      rethrow;
    }
  }

  String _removeCode0(String s) {
    var codeUints = List<int>.from(s.codeUnits);
    codeUints.removeWhere((e) => e == 0);
    return String.fromCharCodes(codeUints);
  }

  bool _cookieMatch(String url, String domain) {
    domain = _removeCode0(domain);
    var host = Uri.parse(url).host;
    var acceptedHost = _getAcceptedDomains(host);
    return acceptedHost.contains(domain.removeAllBlank);
  }

  List<String> _getAcceptedDomains(String host) {
    var acceptedDomains = <String>[host];
    var hostParts = host.split('.');
    for (var i = 0; i < hostParts.length - 1; i++) {
      acceptedDomains.add('.${hostParts.sublist(i).join('.')}');
    }
    return acceptedDomains;
  }

  /// 请求关闭本次窗口（幂等）。
  ///
  /// 创建尚未完成时只登记请求，[open] 在 create 返回后会立即关掉新窗口；
  /// 已挂载时直接关闭。窗口真正关闭仍以 [onClose] 为准。
  Future<void> close() async {
    if (_lifecycle.closeRequested) return;
    _lifecycle.requestClose();
    _stopTimer();
    final webview = _webview;
    _webview = null;
    if (webview == null) return;
    try {
      webview.close();
    } catch (_) {
      // 关闭失败按噪声处理。
    }
  }
}

/// 桌面窗口的生命周期判定：代次与关闭请求。
///
/// 与平台窗口解耦，因此"创建期间取消"与"旧代次不接管新窗口"这两条语义
/// 可以被直接验证，而不必在测试里启动真实窗口。
class DesktopWebviewLifecycle {
  int _generation = 0;
  bool _closeRequested = false;
  bool _closed = false;

  /// 本次窗口是否已被请求关闭（创建期间取消也计入）。
  bool get closeRequested => _closeRequested;

  /// 开始一次创建，返回该次创建所属的代次。
  int beginOpen() {
    _closeRequested = false;
    _closed = false;
    return ++_generation;
  }

  /// 请求关闭当前窗口（幂等）。
  void requestClose() => _closeRequested = true;

  bool finishClose(int generation) {
    if (!isCurrent(generation) || _closed) return false;
    _closed = true;
    _closeRequested = true;
    return true;
  }

  /// 创建完成后能否接管这个窗口：必须是当前代次且期间没有被取消。
  bool canAdopt(int generation) =>
      generation == _generation && !_closeRequested;

  /// 某代次是否仍是当前代次：旧代次的关闭事件、定时器 tick、延迟回调
  /// 都据此判定为过期，不得影响新窗口。
  bool isCurrent(int generation) => generation == _generation;
}
