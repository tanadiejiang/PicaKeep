import 'dart:async';
import 'dart:io' as io;

import 'package:dio/dio.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/pages/online_comic/webview.dart';
import 'package:picakeep/tools/translations.dart';

/// Cloudflare 挑战异常（移植自上游 PicaComic）。
///
/// 当请求命中 Cloudflare 5 秒盾（`cf-mitigated: challenge`）时，
/// [CloudflareInterceptor] 把 403 响应转换成本异常抛出，上层可据此调
/// [passCloudflare] 弹 Webview 过盾。
class CloudflareException implements DioException {
  final String url;

  const CloudflareException(this.url);

  @override
  String toString() {
    return "CloudflareException: $url";
  }

  static CloudflareException? fromString(String message) {
    var match = RegExp(r"CloudflareException: (.+)").firstMatch(message);
    if (match == null) return null;
    return CloudflareException(match.group(1)!);
  }

  @override
  DioException copyWith(
      {RequestOptions? requestOptions,
      Response<dynamic>? response,
      DioExceptionType? type,
      Object? error,
      StackTrace? stackTrace,
      String? message}) {
    return this;
  }

  @override
  Object? get error => this;

  @override
  String? get message => toString();

  @override
  RequestOptions get requestOptions => RequestOptions();

  @override
  Response? get response => null;

  @override
  StackTrace get stackTrace => StackTrace.empty;

  @override
  DioExceptionType get type => DioExceptionType.badResponse;
}

/// 请求拦截器：识别 Cloudflare 挑战页（403 + `cf-mitigated: challenge`），
/// 转成 [CloudflareException]；并在带 `cf_clearance` 的请求上回填登录时抓到的 UA。
class CloudflareInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.headers['cookie'].toString().contains('cf_clearance')) {
      options.headers['user-agent'] = appdata.implicitData[3];
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode == 403) {
      handler.next(_check(err.response!) ?? err);
    } else {
      handler.next(err);
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (response.statusCode == 403) {
      var err = _check(response);
      if (err != null) {
        handler.reject(err);
        return;
      }
    }
    handler.next(response);
  }

  CloudflareException? _check(Response response) {
    if (response.headers['cf-mitigated']?.firstOrNull == "challenge") {
      return CloudflareException(response.requestOptions.uri.toString());
    }
    return null;
  }
}

/// 弹 Webview 过 Cloudflare 盾：登录后抓 `cf_clearance` cookie + UA 持久化，
/// 完成后回调 [onFinished]。桌面端走 [DesktopWebview]，移动端走 [AppWebview]。
void passCloudflare(CloudflareException e, void Function() onFinished) async {
  var url = e.url;
  var uri = Uri.parse(url);

  void saveCookies(Map<String, String> cookies) {
    var domain = uri.host;
    var splits = domain.split('.');
    if (splits.length > 1) {
      domain = ".${splits[splits.length - 2]}.${splits[splits.length - 1]}";
    }
    SingleInstanceCookieJar.instance!.saveFromResponse(
      uri,
      List<io.Cookie>.generate(cookies.length, (index) {
        var cookie = io.Cookie(
            cookies.keys.elementAt(index), cookies.values.elementAt(index));
        cookie.domain = domain;
        return cookie;
      }),
    );
  }

  if (App.isDesktop && (await DesktopWebview.isAvailable())) {
    // 基线快照：App cookie jar 里当前在用的 cf_clearance（很可能正是已失效的那份）。
    // 桌面 WebView2 用独立磁盘 profile（App.dataPath\webview）且从不清理，
    // getCookies 读的是整个 profile 而非当前页，旧 cf_clearance 一直可读；
    // 故判据必须是「拿到一份不同于基线的 clearance」，而非「存在 clearance」。
    final baseClearance = SingleInstanceCookieJar.instance!
        .loadForRequest(uri)
        .where((c) => c.name == 'cf_clearance')
        .firstOrNull
        ?.value;
    // 可重入守卫：桌面端 onTitleChange 是 2 秒 Timer.periodic 轮询、
    // fire-and-forget 调用（webview.dart:346-371），多次 tick 的 async 回调可能重叠。
    bool closed = false;
    bool finished = false;
    bool reading = false;
    void finishOnce() {
      closed = true;
      if (finished) return;
      finished = true;
      onFinished();
    }

    var webview = DesktopWebview(
      initialUrl: url,
      onTitleChange: (title, controller) async {
        if (closed || reading) return;
        reading = true;
        try {
          var res = await controller.evaluateJavascript(
              "document.head.innerHTML.includes('#challenge-success-text')");
          if (closed || res != 'false') return;
          final ua = controller.userAgent;
          final cookiesMap = await controller.getCookies(url);
          if (closed) return;
          // Keep the existing challenge predicate: clearance must differ from baseline.
          final clearance = cookiesMap['cf_clearance'];
          if (clearance == null || clearance == baseClearance) return;
          closed = true;
          if (ua != null) {
            appdata.implicitData[3] = ua;
            appdata.writeImplicitData();
          }
          saveCookies(cookiesMap);
          await controller.close();
        } catch (_) {
          if (closed) finishOnce();
        } finally {
          reading = false;
        }
      },
      // 用户手动点窗口 X 关闭（未过盾）时的降级路径：给出完成信号，
      // 让调用方立即返回 CF 失败消息，而非空等 180 秒超时。
      onClose: finishOnce,
    );
    // open 现在返回 Future：创建失败必须给出完成信号，
    // 否则调用方会一直等到它自己的超时（原本 async void 会静默吞掉异常）。
    unawaited(
      webview.open().catchError((Object error) {
        finishOnce();
      }),
    );
  } else if (App.isMobile) {
    // 进入 Webview 时的 cf_clearance 快照（onStarted 中只读取、不落盘）。
    // 关窗判据以「cf_clearance 相对快照发生变化」为准，与质询页标题的
    // 语言/平台差异解耦：系统 WebView 里残留的旧 cf_clearance 不会触发关窗。
    String? baseClearance;
    // 可重入守卫：onTitleChange 内有多个 await（getUA / getCookies），相邻两次
    // 标题变化可能双双穿过判据；而 App.globalBack 只看 Navigator.canPop、不校验
    // 路由身份，第二次 pop 会把 webview 下层的页面（如 AI 会话页）一起弹掉。
    bool closed = false;
    await App.globalTo(
      () => AppWebview(
        initialUrl: url,
        singlePage: true,
        onTitleChange: (title, controller) async {
          // CF 质询页标题固定为 "Just a moment..."；
          // 标题变为其他值说明质询已通过、页面已跳转。
          if (title == 'Just a moment...' || title.trim().isEmpty) return;
          var ua = await controller.getUA();
          if (ua != null) {
            appdata.implicitData[3] = ua;
            appdata.writeImplicitData();
          }
          var cookiesMap = await controller.getCookies(url) ?? {};
          // 真正的判据：cf_clearance 必须存在且不同于进入时的快照，
          // 否则说明读到的是残留旧值（尚未过盾），继续等待。
          final clearance = cookiesMap['cf_clearance'];
          if (clearance == null || clearance == baseClearance) return;
          if (closed) return;
          closed = true;
          saveCookies(cookiesMap);
          App.globalBack();
          onFinished();
        },
        onStarted: (controller) async {
          // 只更新 UA；不在 URL 加载前提前读取 cookies，
          // 防止 WebView 持久化的旧 cf_clearance 写入 App cookie jar。
          var ua = await controller.getUA();
          if (ua != null) {
            appdata.implicitData[3] = ua;
            appdata.writeImplicitData();
          }
          // 只读快照，不调 saveCookies：记录进入时已存在的旧 cf_clearance。
          baseClearance =
              (await controller.getCookies(url) ?? {})['cf_clearance'];
        },
      ),
    );
    // App.globalTo 是 Navigator.push，返回的 Future 在路由 pop 之后才完成，
    // 所以这里执行时 webview 已关闭。此处的 onFinished 覆盖「用户手动按返回
    // 退出、未过盾」的降级路径：不给完成信号，调用方只能空等 180 秒超时。
    // 过盾成功路径已在 onTitleChange 里调过一次，故 onFinished 可能被调用两次，
    // 调用方必须幂等（现有唯一调用方 search_by_image_tool.dart 用
    // Completer + `if (!completer.isCompleted)` 防护）。
    onFinished();
  } else {
    showToast(message: "当前设备不支持".tl);
  }
}
