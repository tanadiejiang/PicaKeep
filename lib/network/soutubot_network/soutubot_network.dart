import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

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
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
    ));
    dio.interceptors.add(CookieManagerSql(SingleInstanceCookieJar.instance!));
    dio.interceptors.add(CloudflareInterceptor());
  }

  @visibleForTesting
  SoutubotNetwork.forTesting(Dio client, {String userAgent = webUA})
      : _testUA = userAgent {
    dio = client;
  }

  String? _testUA;

  static SoutubotNetwork? _instance;

  static const baseUrl = 'https://soutubot.moe';

  /// 内置 Chrome 桌面 UA 兜底（implicitData[3] 默认值即 [webUA]，此处防御空串）。
  static const _fallbackUA = webUA;

  late final Dio dio;

  /// 使用人工过盾时保存的 UA，使 cf_clearance 和请求身份一致。
  /// `CloudflareInterceptor.onRequest` 在 cookie 含 cf_clearance 时会把 UA 覆盖
  /// 为 `appdata.implicitData[3]`；新版搜图无需旧签名算法。
  String get _effectiveUA {
    if (_testUA != null) return _testUA!;
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
  Future<Res<SoutubotSearchResult>> searchByImage(Uint8List imageBytes,
      {Map<String, Object?>? adapter}) async {
    final cancellation = CancelToken();
    final deadline = Timer(const Duration(seconds: 90),
        () => cancellation.cancel('Soutubot request deadline exceeded'));
    try {
      if (imageBytes.isEmpty || imageBytes.length > 10 * 1024 * 1024) {
        return const Res.error('图片不能为空或超过 10MB',
            errorCode: ResErrorCode.invalidArgument);
      }
      if (detectSoutubotImageType(imageBytes) == null) {
        return const Res.error('无法识别图片格式，请使用 PNG、JPEG、WebP、GIF 或 BMP 图片',
            errorCode: ResErrorCode.invalidArgument);
      }
      final endpoint = Uri.tryParse(
          adapter?['endpoint']?.toString() ?? '$baseUrl/api/search');
      if (endpoint == null ||
          endpoint.scheme != 'https' ||
          endpoint.host != 'soutubot.moe' ||
          endpoint.port != 443 ||
          endpoint.userInfo.isNotEmpty ||
          endpoint.hasFragment) {
        return const Res.error('搜图适配器目标必须是 https://soutubot.moe',
            errorCode: ResErrorCode.invalidArgument);
      }
      final ua = _effectiveUA;
      // 2026-10公开前端直接 POST multipart，不再获取 GLOBAL.m 或计算旧签名。
      final boundary = randomWebKitBoundary();
      final rawFields = adapter?['fields'] ??
          const {'factor': '1.2', 'metadata_mode': 'display'};
      if (rawFields is! Map ||
          rawFields.length > 16 ||
          rawFields.entries.any((entry) =>
              entry.key is! String ||
              entry.value is! String ||
              (entry.value as String).length > 1024)) {
        return const Res.error('搜图适配器表单字段无效',
            errorCode: ResErrorCode.invalidArgument);
      }
      final body = buildSoutubotMultipartBody(
        imageBytes: imageBytes,
        boundary: boundary,
        fileField: adapter?['fileField']?.toString() ?? 'file',
        fields: Map<String, String>.from(rawFields),
      );
      // dio 5.4.1 的 FormData 无自定义 boundary 入口，手拼字节体直接 POST
      // （dio 对 Uint8List data 原样透传并自动补 content-length）。
      final response = await dio.post<ResponseBody>(
        endpoint.toString(),
        data: body,
        cancelToken: cancellation,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          receiveDataWhenStatusError: false,
          sendTimeout: const Duration(seconds: 60),
          receiveTimeout: const Duration(seconds: 60),
          headers: {
            'user-agent': ua,
            'Accept': 'application/json',
            'content-type': 'multipart/form-data; boundary=$boundary',
          },
        ),
      );
      final bytes = BytesBuilder(copy: false);
      final stream = response.data?.stream;
      if (stream == null) {
        throw const FormatException('Empty soutubot response');
      }
      await for (final chunk in stream.timeout(const Duration(seconds: 60))) {
        if (bytes.length + chunk.length > 8 * 1024 * 1024) {
          throw const FormatException('soutubot response exceeds 8MB');
        }
        bytes.add(chunk);
      }
      final payload = _asJsonMap(utf8.decode(bytes.takeBytes()));
      if (payload == null) {
        return const Res(null,
            errorMessage: 'soutubot 返回了无法解析的响应', errorCode: ResErrorCode.parse);
      }
      final rawResponse = adapter?['response'];
      return Res(SoutubotSearchResult.fromJson(payload,
          response: rawResponse is Map
              ? Map<String, Object?>.from(rawResponse)
              : null));
    } on DioException catch (e) {
      if (_isCloudflare(e)) rethrow;
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        return Res(
          null,
          errorMessage: 'soutubot 拒绝了请求（HTTP $status），请检查站点访问权限',
          errorCode: ResErrorCode.accessDenied,
          statusCode: status,
        );
      }
      if (status == 429) {
        return const Res.error('soutubot 请求过于频繁，请稍后重试（HTTP 429）',
            errorCode: ResErrorCode.network, statusCode: 429);
      }
      if (status == 413) {
        return const Res.error('soutubot 拒绝了过大的图片（HTTP 413）',
            errorCode: ResErrorCode.invalidArgument, statusCode: 413);
      }
      if (status == 415) {
        return const Res.error(
            'soutubot 不支持当前图片格式（HTTP 415），请转换为 PNG 或 JPEG 后重试',
            errorCode: ResErrorCode.invalidArgument,
            statusCode: 415);
      }
      if (status == 400 || status == 422) {
        return Res.error('soutubot 不接受当前图片或请求参数（HTTP $status）',
            errorCode: ResErrorCode.invalidArgument, statusCode: status);
      }
      if (status != null && status >= 300 && status < 400) {
        return Res.error('soutubot 接口发生重定向，请更新适配器后重试',
            errorCode: ResErrorCode.unsupported, statusCode: status);
      }
      return Res(null,
          errorMessage: status == null
              ? 'soutubot 网络连接失败或超时，请稍后重试'
              : 'soutubot 服务异常（HTTP $status）',
          errorCode: ResErrorCode.network,
          statusCode: status);
    } on FormatException {
      return const Res.error('soutubot 响应结构与当前适配器不匹配，请诊断或更新适配器',
          errorCode: ResErrorCode.parse);
    } catch (e) {
      if (_isCloudflare(e)) rethrow;
      return const Res.error('soutubot 网络请求失败，请稍后重试',
          errorCode: ResErrorCode.network);
    } finally {
      deadline.cancel();
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
