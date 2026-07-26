import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/network/app_dio.dart';
import 'package:picakeep/network/cloudflare.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/network/res.dart';

import 'soutubot_models.dart';
import 'soutubot_signature.dart';

export 'soutubot_models.dart';

/// soutubot.moe 以图搜源网络层（第十五轮 05 计划步骤 4）。
///
/// 装配决策（均照抄唯一在产 CF 挂载样板 nhentai_main_network.dart）：
/// - Cookie 挂单例 jar：`passCloudflare` 的 saveCookies 硬编码写
///   `SingleInstanceCookieJar.instance!`（cloudflare.dart），过盾拿到的
///   cf_clearance 只会落单例 jar，用独立 jar 就读不到；soutubot 无账号体系，
///   不涉及 eh 那条「多源账号串库」铁律（那是针对账号 cookie 的）。
/// - `CloudflareException` 一律原样 rethrow：网络层不处理过盾，交工具层
///   触发 `passCloudflare` 弹 Webview。
/// - `validateStatus` 保持 dio 默认（仅 2xx）：403 会走
///   `CloudflareInterceptor.onError` 转 `CloudflareException`，与实测现象
///   （403 + `Cf-Mitigated: challenge`）吻合。
class SoutubotNetwork {
  factory SoutubotNetwork() => _instance ??= SoutubotNetwork._();

  SoutubotNetwork._() {
    dio = logDio(BaseOptions(
      headers: {
        'Accept': 'application/json, text/plain, */*',
        'Origin': baseUrl,
        'Referer': '$baseUrl/',
        'Dnt': '1',
        'X-Requested-With': 'XMLHttpRequest',
      },
      sendTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 60),
    ));
    dio.interceptors.add(CookieManagerSql(SingleInstanceCookieJar.instance!));
    dio.interceptors.add(CloudflareInterceptor());
  }

  static SoutubotNetwork? _instance;

  static const baseUrl = 'https://soutubot.moe';

  /// 内置 Chrome 桌面 UA 兜底（implicitData[3] 默认值即 [webUA]，此处防御空串）。
  static const _fallbackUA = webUA;

  late final Dio dio;

  /// 签名的 uaLen 与实际发送的 User-Agent 必须同源：每次请求把本值显式写入
  /// headers，并用同一字符串的 `.length` 参与签名（Dart `String.length` 与 JS
  /// `navigator.userAgent.length` 同为 UTF-16 计数，UA 是 ASCII，无差异）。
  /// `CloudflareInterceptor.onRequest` 在 cookie 含 cf_clearance 时会把 UA 覆盖
  /// 为 `appdata.implicitData[3]` —— 与本值同源，幂等，不会造成签名/发送不一致。
  String get _effectiveUA {
    final ua = appdata.implicitData[3];
    return ua.isNotEmpty ? ua : _fallbackUA;
  }

  /// CF 质询三重判定：直接异常 / DioException 包裹 / 被字符串化的异常
  /// （`CloudflareException.fromString` 存在的意义就是最后一种场景）。
  static bool _isCloudflare(Object e) =>
      e is CloudflareException ||
      (e is DioException && e.error is CloudflareException) ||
      CloudflareException.fromString(e.toString()) != null;

  /// 上传图片字节，返回相似本子列表。
  ///
  /// 命中 Cloudflare 质询时原样 rethrow [CloudflareException]；其余失败一律
  /// 收敛为带 errorMessage 的 [Res]。
  Future<Res<SoutubotSearchResult>> searchByImage(Uint8List imageBytes) async {
    try {
      final ua = _effectiveUA;
      // 每次搜索现抓 m，不缓存：搜图低频、主页 GET 便宜，
      // 避免站点重新部署后 m 过期导致的隐性 401。
      final homeResponse = await dio.get<String>(
        '$baseUrl/',
        options: Options(
          responseType: ResponseType.plain,
          headers: {'user-agent': ua},
        ),
      );
      final m = extractSoutubotGlobalM(homeResponse.data ?? '');
      if (m == null) {
        return const Res(
          null,
          errorMessage: '无法从 soutubot 主页解析签名参数 m，页面结构可能已变更',
        );
      }
      final unixSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final apiKey = calcSoutubotApiKey(unixSec, ua.length, m);
      final boundary = randomWebKitBoundary();
      final body = buildSoutubotMultipartBody(
        imageBytes: imageBytes,
        boundary: boundary,
      );
      // dio 5.4.1 的 FormData 无自定义 boundary 入口，手拼字节体直接 POST
      // （dio 对 Uint8List data 原样透传并自动补 content-length）。
      final response = await dio.post<dynamic>(
        '$baseUrl/api/search',
        data: body,
        options: Options(
          headers: {
            'user-agent': ua,
            'x-api-key': apiKey,
            'content-type': 'multipart/form-data; boundary=$boundary',
          },
        ),
      );
      final payload = _asJsonMap(response.data);
      if (payload == null) {
        return const Res(null, errorMessage: 'soutubot 返回了无法解析的响应');
      }
      // 失败判定：payload 不含 'data' 键，取 message 组错误信息。
      if (!payload.containsKey('data')) {
        final message = payload['message']?.toString() ?? '未知错误';
        return Res(null, errorMessage: 'soutubot 返回错误：$message');
      }
      return Res(SoutubotSearchResult.fromJson(payload));
    } on DioException catch (e) {
      if (_isCloudflare(e)) rethrow;
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        return Res(
          null,
          errorMessage: 'soutubot 拒绝了请求（HTTP $status），可能是接口签名算法已变更',
        );
      }
      return Res(null, errorMessage: '网络错误：${e.message ?? e.toString()}');
    } catch (e) {
      if (_isCloudflare(e)) rethrow;
      return Res(null, errorMessage: '网络错误：$e');
    }
  }

  static Map<String, Object?>? _asJsonMap(Object? data) {
    if (data is Map) {
      return data.map((key, value) => MapEntry(key.toString(), value));
    }
    if (data is String && data.isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry(key.toString(), value));
        }
      } catch (_) {
        // 落到统一的解析失败返回。
      }
    }
    return null;
  }
}
