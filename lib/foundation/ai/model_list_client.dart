import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/network/app_dio.dart';

/// 15轮06号计划：模型列表拉取结果。
class ModelListResult {
  const ModelListResult({this.models = const [], this.error});

  final List<String> models;
  final String? error;

  bool get ok => error == null;
}

/// OpenAI 标准 `GET {base}/models` 模型列表客户端
/// （DeepSeek / OpenAI / Ollama(/v1) / one-api·new-api 中转通用）。
/// 内存缓存 + in-flight 去重：同 key 并发（焦点反复进出、箭头连点）只发一次
/// 请求；成功 TTL 10 分钟、失败 TTL 30 秒；不落盘、不占 settings 索引。
/// 换模板/改 Base URL/改 Key 后 key 变化天然失效。
class ModelListClient {
  ModelListClient._();

  static const _successTtl = Duration(minutes: 10);
  static const _failureTtl = Duration(seconds: 30);

  /// key = '<端点>|<apiKey>'；value 持有 Future 本身实现并发去重。
  static final Map<String, _CacheEntry> _cache = {};

  /// 从 Base URL 推导 /models 端点：
  /// - 尾部 `/chat/completions` 剥掉（用户误填完整 chat 端点仍可用）；
  /// - 已以 `/models` 结尾原样用；其余去尾斜杠后拼 `/models`；
  /// - `https://api.deepseek.com` 与 `.../v1` 两种形态都直接可用
  ///   （DeepSeek 文档明确 /models 与 /v1/models 等价）。
  static String modelsEndpoint(String baseUrl) {
    var base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.endsWith('/chat/completions')) {
      base = base
          .substring(0, base.length - '/chat/completions'.length)
          .replaceAll(RegExp(r'/+$'), '');
    }
    if (base.endsWith('/models')) return base;
    return '$base/models';
  }

  /// 解析标准“对象包数组”：{"object":"list","data":[{"id":...},...]}。
  /// 只取 data[].id；DeepSeek 没有 OpenAI 的 created 字段，不做任何其他
  /// 字段假定；非 Map 元素/空 id 跳过；保序去重（尊重服务端顺序）。
  static List<String> parseModels(Object? json) {
    if (json is! Map) return const [];
    final data = json['data'];
    if (data is! List) return const [];
    final result = <String>[];
    for (final item in data) {
      if (item is! Map) continue;
      final id = item['id']?.toString() ?? '';
      if (id.isNotEmpty && !result.contains(id)) result.add(id);
    }
    return result;
  }

  static Future<ModelListResult> fetch({bool force = false}) {
    final template = appdata.settings[aiProviderTemplateSettingIndex];
    var baseUrl = appdata.settings[aiBaseUrlSettingIndex].trim();
    if (baseUrl.isEmpty && template == 'deepseek') {
      baseUrl = 'https://api.deepseek.com'; // 与 LlmClient.chat 同款 fallback
    }
    if (baseUrl.isEmpty) {
      return Future.value(const ModelListResult(error: 'Base URL 未配置'));
    }
    final apiKey = appdata.settings[aiApiKeySettingIndex].trim();
    final endpoint = modelsEndpoint(baseUrl);
    final key = '$endpoint|$apiKey';
    final now = DateTime.now();
    final cached = _cache[key];
    if (!force && cached != null && now.isBefore(cached.expiresAt)) {
      return cached.future;
    }
    final future = _fetchRemote(endpoint, apiKey);
    final entry = _CacheEntry(future: future, expiresAt: now.add(_successTtl));
    _cache[key] = entry;
    future.then((result) {
      if (!result.ok) {
        entry.expiresAt = DateTime.now().add(_failureTtl);
      }
    });
    return future;
  }

  static Future<ModelListResult> _fetchRemote(
      String endpoint, String apiKey) async {
    try {
      final dio = logDio();
      final response = await dio.get<Map<String, dynamic>>(
        endpoint,
        options: Options(
          headers: {
            // Ollama 等本地服务无鉴权：key 为空时不带 Authorization 头。
            if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
          },
          receiveTimeout: const Duration(seconds: 15),
          extra: {'noRetry': true}, // 列表请求失败不自动重发
        ),
      );
      if (response.statusCode != 200) {
        return ModelListResult(
            error: 'HTTP ${response.statusCode}: ${response.statusMessage}');
      }
      final models = parseModels(response.data);
      if (models.isEmpty) {
        return const ModelListResult(error: '响应中没有模型');
      }
      return ModelListResult(models: models);
    } on DioException catch (e) {
      // 错误码语义以 HTTP 状态码为准（401 key 错等），body 仅进网络日志。
      final code = e.response?.statusCode;
      return ModelListResult(
          error: code != null ? 'HTTP $code' : (e.message ?? '网络错误'));
    } catch (e) {
      return ModelListResult(error: '解析失败: $e');
    }
  }

  @visibleForTesting
  static void clearCacheForTesting() => _cache.clear();
}

class _CacheEntry {
  _CacheEntry({required this.future, required this.expiresAt});

  final Future<ModelListResult> future;
  DateTime expiresAt;
}
