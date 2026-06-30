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
    var webview = DesktopWebview(
      initialUrl: url,
      onTitleChange: (title, controller) async {
        var res = await controller.evaluateJavascript(
            "document.head.innerHTML.includes('#challenge-success-text')");
        if (res == 'false') {
          var ua = controller.userAgent;
          if (ua != null) {
            appdata.implicitData[3] = ua;
            appdata.writeImplicitData();
          }
          var cookiesMap = await controller.getCookies(url);
          if (cookiesMap['cf_clearance'] == null) {
            return;
          }
          saveCookies(cookiesMap);
          controller.close();
          onFinished();
        }
      },
    );
    webview.open();
  } else if (App.isMobile) {
    await App.globalTo(
      () => AppWebview(
        initialUrl: url,
        singlePage: true,
        onTitleChange: (title, controller) async {
          var res = await controller.evaluateJavascript(
              source:
                  "document.head.innerHTML.includes('#challenge-success-text')");
          if (res == false) {
            var ua = await controller.getUA();
            if (ua != null) {
              appdata.implicitData[3] = ua;
              appdata.writeImplicitData();
            }
            var cookiesMap = await controller.getCookies(url) ?? {};
            if (cookiesMap['cf_clearance'] == null) {
              return;
            }
            saveCookies(cookiesMap);
            App.globalBack();
          }
        },
        onStarted: (controller) async {
          var ua = await controller.getUA();
          if (ua != null) {
            appdata.implicitData[3] = ua;
            appdata.writeImplicitData();
          }
          var cookiesMap = await controller.getCookies(url) ?? {};
          saveCookies(cookiesMap);
        },
      ),
    );
    onFinished();
  } else {
    showToast(message: "当前设备不支持".tl);
  }
}
