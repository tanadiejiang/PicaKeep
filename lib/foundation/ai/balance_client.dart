import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/network/app_dio.dart';

/// 15轮06号计划：余额查询结果三态。
/// - ok：拿到金额，正常展示；
/// - unsupported：该服务商查不了（或未配置），**静默不显示**，不报错；
/// - error：真错误（key 无效/网络失败），红字展示。
enum AiBalanceStatus { ok, unsupported, error }

class AiBalanceResult {
  const AiBalanceResult.ok(this.amount, this.currency)
      : status = AiBalanceStatus.ok,
        message = null;

  const AiBalanceResult.unsupported([this.message])
      : status = AiBalanceStatus.unsupported,
        amount = null,
        currency = null;

  const AiBalanceResult.error(this.message)
      : status = AiBalanceStatus.error,
        amount = null,
        currency = null;

  final AiBalanceStatus status;
  final double? amount;
  final String? currency; // 'CNY' / 'USD'
  final String? message;

  /// 展示文案：CNY → `¥12.34`，USD → `$12.34`，其他 → `12.34 XXX`。
  String get display {
    if (status != AiBalanceStatus.ok || amount == null) return '';
    final n = amount!.toStringAsFixed(2);
    switch (currency) {
      case 'CNY':
        return '¥$n';
      case 'USD':
        return '\$$n';
      default:
        return currency == null || currency!.isEmpty ? n : '$n $currency';
    }
  }
}

/// 明确查不到余额的域名（连请求都不发，直接 unsupported）：
/// - openai.com：dashboard 端点自 2023 年起只认浏览器 session key，sk- key 一律拒；
///   官方替代 Costs API 需 Admin key 且返回消费额而非余额。
/// - bigmodel.cn（智谱）：用量接口只认 Cookie 且有反爬。
/// - dashscope.aliyuncs.com（百炼/Qwen）：需阿里云 AccessKey 签名，非 API Key。
const _unsupportedBalanceHosts = <String>[
  'api.openai.com',
  'openai.com',
  'open.bigmodel.cn',
  'bigmodel.cn',
  'dashscope.aliyuncs.com',
];

/// 余额查询的 provider 分派种类。
@visibleForTesting
enum AiBalanceProvider { deepseek, kimi, siliconflow, relay, unsupported }

/// 各家私有余额接口客户端（无 OpenAI 标准）。按 provider 分派，
/// 明确不支持者直接短路不发请求；整个类不抛异常，一律折叠成 [AiBalanceResult]
/// （沿用 LlmClient.chat 的“错误装返回值”风格）。
class AiBalanceClient {
  AiBalanceClient._();

  /// 把 Base URL 规整成 origin：去尾斜杠、去 `/chat/completions`、去 `/v1`。
  @visibleForTesting
  static String normalizeOrigin(String baseUrl) {
    var base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.endsWith('/chat/completions')) {
      base = base.substring(0, base.length - '/chat/completions'.length);
      base = base.replaceAll(RegExp(r'/+$'), '');
    }
    if (base.endsWith('/v1')) {
      base = base.substring(0, base.length - '/v1'.length);
      base = base.replaceAll(RegExp(r'/+$'), '');
    }
    return base;
  }

  /// 判定走哪家私有接口。域名优先，域名认不出时用模板名兜底。
  @visibleForTesting
  static AiBalanceProvider resolveProvider(String baseUrl, String template) {
    final lower = normalizeOrigin(baseUrl).toLowerCase();
    if (lower.isEmpty) return AiBalanceProvider.unsupported;
    final host = Uri.tryParse(lower)?.host ?? lower;
    for (final blocked in _unsupportedBalanceHosts) {
      if (host == blocked || host.endsWith('.$blocked')) {
        return AiBalanceProvider.unsupported;
      }
    }
    if (host.contains('deepseek') || template == 'deepseek') {
      return AiBalanceProvider.deepseek;
    }
    if (host.contains('moonshot') || host.contains('kimi')) {
      return AiBalanceProvider.kimi;
    }
    if (host.contains('siliconflow')) return AiBalanceProvider.siliconflow;
    return AiBalanceProvider.relay;
  }

  /// 各 provider 的余额端点（DeepSeek 的 `/user/balance` **没有 /v1 前缀**，
  /// 这点与模型列表接口不同）。
  @visibleForTesting
  static String balanceEndpoint(AiBalanceProvider provider, String baseUrl) {
    final origin = normalizeOrigin(baseUrl);
    switch (provider) {
      case AiBalanceProvider.deepseek:
        return '$origin/user/balance';
      case AiBalanceProvider.kimi:
        return '$origin/v1/users/me/balance';
      case AiBalanceProvider.siliconflow:
        return '$origin/v1/user/info';
      case AiBalanceProvider.relay:
        return '$origin/dashboard/billing/subscription';
      case AiBalanceProvider.unsupported:
        return '';
    }
  }

  /// 金额字段各家类型不一（DeepSeek/SiliconFlow 是字符串 `"110.00"`，
  /// Kimi 是数字 `49.58894`），统一用 num.tryParse 解析。
  @visibleForTesting
  static double? parseAmount(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return num.tryParse(value.toString().trim())?.toDouble();
  }

  /// 解析 DeepSeek `/user/balance`：`balance_infos` 是**按币种分项的数组**
  /// （可能同时有 CNY 与 USD 两项），取 `[0]`；`is_available` 为 false 时
  /// 仍照常展示金额（余额为 0 也是有效信息）。
  @visibleForTesting
  static AiBalanceResult parseDeepseek(Object? json) {
    if (json is! Map) return const AiBalanceResult.unsupported('响应不是 JSON 对象');
    final infos = json['balance_infos'];
    if (infos is! List || infos.isEmpty) {
      return const AiBalanceResult.unsupported('响应缺少 balance_infos');
    }
    final first = infos.first;
    if (first is! Map) {
      return const AiBalanceResult.unsupported('balance_infos 格式异常');
    }
    final amount = parseAmount(first['total_balance']);
    if (amount == null) {
      return const AiBalanceResult.unsupported('响应缺少 total_balance');
    }
    final currency = first['currency']?.toString();
    return AiBalanceResult.ok(amount, currency);
  }

  /// 解析 Kimi(Moonshot) `/v1/users/me/balance`：`data.available_balance`（数字）。
  @visibleForTesting
  static AiBalanceResult parseKimi(Object? json) {
    final data = (json is Map) ? json['data'] : null;
    if (data is! Map) return const AiBalanceResult.unsupported('响应缺少 data');
    final amount = parseAmount(data['available_balance']);
    if (amount == null) {
      return const AiBalanceResult.unsupported('响应缺少 available_balance');
    }
    return AiBalanceResult.ok(amount, 'CNY');
  }

  /// 解析 SiliconFlow `/v1/user/info`：`data.totalBalance`（字符串）。
  @visibleForTesting
  static AiBalanceResult parseSiliconFlow(Object? json) {
    final data = (json is Map) ? json['data'] : null;
    if (data is! Map) return const AiBalanceResult.unsupported('响应缺少 data');
    final amount = parseAmount(data['totalBalance']);
    if (amount == null) {
      return const AiBalanceResult.unsupported('响应缺少 totalBalance');
    }
    return AiBalanceResult.ok(amount, 'CNY');
  }

  /// 解析中转站（one-api / new-api）两连击：
  /// subscription.hard_limit_usd（美元总额度） - usage.total_usage / 100
  /// （**total_usage 单位是美分**）。
  @visibleForTesting
  static AiBalanceResult parseRelay(Object? subscription, Object? usage) {
    final limit = (subscription is Map)
        ? parseAmount(subscription['hard_limit_usd'])
        : null;
    if (limit == null) {
      return const AiBalanceResult.unsupported('响应缺少 hard_limit_usd');
    }
    final usedCents = (usage is Map) ? parseAmount(usage['total_usage']) : null;
    if (usedCents == null) {
      return const AiBalanceResult.unsupported('响应缺少 total_usage');
    }
    return AiBalanceResult.ok(limit - usedCents / 100, 'USD');
  }

  /// HTTP 状态码 + 响应体 → 失败分类。
  /// 判定顺序：401/403（其中含 `session key` 字样归 unsupported）→ 404/405
  /// → 其他非 200。返回 null 表示“状态码正常，继续解析响应体”。
  @visibleForTesting
  static AiBalanceResult? classifyFailure(int? statusCode, Object? body) {
    if (statusCode == 200) return null;
    if (statusCode == 401 || statusCode == 403) {
      final text = body == null ? '' : _stringifyBody(body).toLowerCase();
      if (text.contains('session key')) {
        // OpenAI dashboard 端点对 sk- key 就是这个表现：接口不支持该 key
        // 类型，而非 key 本身错误。
        return const AiBalanceResult.unsupported('该接口不支持此类型密钥');
      }
      return const AiBalanceResult.error('密钥无效或无权限');
    }
    if (statusCode == 404 || statusCode == 405) {
      return const AiBalanceResult.unsupported('该服务不提供余额接口');
    }
    return const AiBalanceResult.error('查询失败');
  }

  static String _stringifyBody(Object body) {
    if (body is String) return body;
    try {
      return jsonEncode(body);
    } catch (_) {
      return body.toString();
    }
  }

  /// 把响应体统一成 Map；返回 null 表示不是 JSON 对象（HTML 登录页 /
  /// Cloudflare 页等 → 调用方按 unsupported 处理）。
  @visibleForTesting
  static Map<String, dynamic>? asJsonMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.map((k, v) => MapEntry(k.toString(), v));
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) {
          return decoded.map((k, v) => MapEntry(k.toString(), v));
        }
      } catch (_) {/* HTML/纯文本 → 非 JSON */}
    }
    return null;
  }

  /// 查询当前配置 provider 的余额。永不抛异常。
  static Future<AiBalanceResult> fetch() async {
    final template = appdata.settings[aiProviderTemplateSettingIndex];
    var baseUrl = appdata.settings[aiBaseUrlSettingIndex].trim();
    if (baseUrl.isEmpty && template == 'deepseek') {
      baseUrl = 'https://api.deepseek.com';
    }
    final apiKey = appdata.settings[aiApiKeySettingIndex].trim();
    if (baseUrl.isEmpty || apiKey.isEmpty) {
      return const AiBalanceResult.unsupported('未配置 Base URL 或 API Key');
    }
    final provider = resolveProvider(baseUrl, template);
    if (provider == AiBalanceProvider.unsupported) {
      // 明确不支持：连请求都不发。
      return const AiBalanceResult.unsupported('该服务不提供余额接口');
    }
    try {
      final dio = logDio();
      if (provider == AiBalanceProvider.relay) {
        return await _fetchRelay(dio, normalizeOrigin(baseUrl), apiKey);
      }
      final response =
          await _get(dio, balanceEndpoint(provider, baseUrl), apiKey);
      final failure = classifyFailure(response.statusCode, response.data);
      if (failure != null) return failure;
      final json = asJsonMap(response.data);
      if (json == null) return const AiBalanceResult.unsupported('响应不是 JSON');
      switch (provider) {
        case AiBalanceProvider.deepseek:
          return parseDeepseek(json);
        case AiBalanceProvider.kimi:
          return parseKimi(json);
        case AiBalanceProvider.siliconflow:
          return parseSiliconFlow(json);
        case AiBalanceProvider.relay:
        case AiBalanceProvider.unsupported:
          return const AiBalanceResult.unsupported();
      }
    } on DioException catch (e) {
      final failure = classifyFailure(e.response?.statusCode, e.response?.data);
      if (failure != null) return failure;
      return const AiBalanceResult.error('查询失败');
    } catch (_) {
      return const AiBalanceResult.error('查询失败');
    }
  }

  /// 中转站兜底：subscription + usage 两连击，任一失败即降级 unsupported
  /// （不报错）。部分部署把接口挂在 `/v1/dashboard/...`，404 时再试一次。
  static Future<AiBalanceResult> _fetchRelay(
      Dio dio, String origin, String apiKey) async {
    for (final prefix in const ['', '/v1']) {
      final subscription = await _get(
          dio, '$origin$prefix/dashboard/billing/subscription', apiKey);
      if (subscription.statusCode == 404 || subscription.statusCode == 405) {
        continue; // 试下一种路径形态
      }
      final failure =
          classifyFailure(subscription.statusCode, subscription.data);
      if (failure != null) return failure;
      final today = DateTime.now();
      final end = '${today.year.toString().padLeft(4, '0')}-'
          '${today.month.toString().padLeft(2, '0')}-'
          '${today.day.toString().padLeft(2, '0')}';
      final usage = await _get(
        dio,
        '$origin$prefix/dashboard/billing/usage'
        '?start_date=2024-01-01&end_date=$end',
        apiKey,
      );
      if (usage.statusCode != 200) {
        return const AiBalanceResult.unsupported('用量接口不可用');
      }
      final subscriptionJson = asJsonMap(subscription.data);
      final usageJson = asJsonMap(usage.data);
      if (subscriptionJson == null || usageJson == null) {
        return const AiBalanceResult.unsupported('响应不是 JSON');
      }
      return parseRelay(subscriptionJson, usageJson);
    }
    return const AiBalanceResult.unsupported('该服务不提供余额接口');
  }

  static Future<Response<dynamic>> _get(Dio dio, String url, String apiKey) {
    return dio.get<dynamic>(
      url,
      options: Options(
        headers: {'Authorization': 'Bearer $apiKey'},
        receiveTimeout: const Duration(seconds: 10),
        extra: {'noRetry': true},
        // 自己按状态码分流，别让 dio 抛。
        validateStatus: (_) => true,
      ),
    );
  }
}
