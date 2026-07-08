import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/network/app_dio.dart';

/// LLM 消息（OpenAI 格式）
class LlmMessage {
  final String role; // 'system' | 'user' | 'assistant' | 'tool'
  final String? content;
  final List<LlmToolCall>? toolCalls;
  final String? toolCallId; // tool role 时必填
  final String? name; // tool role 时填工具名

  const LlmMessage({
    required this.role,
    this.content,
    this.toolCalls,
    this.toolCallId,
    this.name,
  });

  LlmMessage.system(this.content)
      : role = 'system',
        toolCalls = null,
        toolCallId = null,
        name = null;

  LlmMessage.user(this.content)
      : role = 'user',
        toolCalls = null,
        toolCallId = null,
        name = null;

  LlmMessage.assistant({this.content, this.toolCalls})
      : role = 'assistant',
        toolCallId = null,
        name = null;

  LlmMessage.tool({
    required this.toolCallId,
    required this.name,
    required this.content,
  })  : role = 'tool',
        toolCalls = null;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'role': role};
    if (content != null) json['content'] = content;
    if (toolCalls != null && toolCalls!.isNotEmpty) {
      json['tool_calls'] =
          toolCalls!.map((tc) => tc.toJson()).toList();
    }
    if (toolCallId != null) json['tool_call_id'] = toolCallId;
    if (name != null) json['name'] = name;
    return json;
  }

  factory LlmMessage.fromJson(Map<String, dynamic> json) {
    final toolCallsJson = json['tool_calls'] as List<dynamic>?;
    final toolCalls = toolCallsJson
        ?.whereType<Map<String, dynamic>>()
        .map((tc) => LlmToolCall.fromJson(tc))
        .toList();
    return LlmMessage(
      role: json['role']?.toString() ?? 'user',
      content: json['content']?.toString(),
      toolCalls: toolCalls,
      toolCallId: json['tool_call_id']?.toString(),
      name: json['name']?.toString(),
    );
  }
}

/// LLM 工具调用
class LlmToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  const LlmToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  factory LlmToolCall.fromJson(Map<String, dynamic> json) {
    final funcData = json['function'] as Map<String, dynamic>? ?? {};
    final argsStr = funcData['arguments']?.toString() ?? '{}';
    Map<String, dynamic> parsedArgs;
    try {
      final decoded = jsonDecode(argsStr);
      if (decoded is Map) {
        parsedArgs = decoded.map((k, v) => MapEntry(k.toString(), v));
      } else {
        parsedArgs = {};
      }
    } catch (_) {
      parsedArgs = {};
    }

    return LlmToolCall(
      id: json['id']?.toString() ?? '',
      name: funcData['name']?.toString() ?? '',
      arguments: parsedArgs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'function',
        'function': {
          'name': name,
          'arguments': jsonEncode(arguments),
        },
      };
}

/// LLM 响应
class LlmResponse {
  final String? content;
  final List<LlmToolCall>? toolCalls;
  final String? error;

  const LlmResponse({this.content, this.toolCalls, this.error});

  bool get hasToolCalls => toolCalls != null && toolCalls!.isNotEmpty;
  bool get hasError => error != null;
}

/// LLM HTTP 客户端（OpenAI 兼容 API）
class LlmClient {
  LlmClient._();

  /// 发送聊天请求
  static Future<LlmResponse> chat(
    List<LlmMessage> messages, {
    List<Map<String, Object?>>? tools,
  }) async {
    final baseUrl = appdata.settings[aiBaseUrlSettingIndex].trim();
    final apiKey = appdata.settings[aiApiKeySettingIndex].trim();
    final modelId = appdata.settings[aiModelIdSettingIndex].trim();

    if (baseUrl.isEmpty) {
      return const LlmResponse(error: 'Base URL 未配置，请在设置中填写');
    }
    if (apiKey.isEmpty) {
      return const LlmResponse(error: 'API Key 未配置，请在设置中填写');
    }
    if (modelId.isEmpty) {
      return const LlmResponse(error: 'Model ID 未配置，请在设置中填写');
    }

    final dio = logDio();

    // 构建请求体
    final requestBody = <String, dynamic>{
      'model': modelId,
      'messages': messages.map((m) => m.toJson()).toList(),
    };

    // 添加 tools
    if (tools != null && tools.isNotEmpty) {
      requestBody['tools'] = tools
          .map((schema) => {
                'type': 'function',
                'function': schema,
              })
          .toList();
      requestBody['tool_choice'] = 'auto';
    }

    // 解析模型参数（可选）
    final paramsStr = appdata.settings[aiModelParamsSettingIndex].trim();
    if (paramsStr.isNotEmpty) {
      try {
        final params = jsonDecode(paramsStr) as Map<String, dynamic>?;
        if (params != null) {
          // 白名单：只支持常见参数
          for (final key in ['temperature', 'top_p', 'max_tokens']) {
            if (params.containsKey(key)) {
              requestBody[key] = params[key];
            }
          }
        }
      } catch (_) {
        // 参数格式错误，忽略
      }
    }

    // 发送请求
    try {
      final endpoint = baseUrl.endsWith('/chat/completions')
          ? baseUrl
          : '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';

      final response = await dio.post<Map<String, dynamic>>(
        endpoint,
        data: requestBody,
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          receiveTimeout: const Duration(seconds: 60),
        ),
      );

      if (response.statusCode != 200) {
        return LlmResponse(
            error: 'HTTP ${response.statusCode}: ${response.statusMessage}');
      }

      final data = response.data;
      if (data == null) {
        return const LlmResponse(error: '响应为空');
      }

      final choices = data['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) {
        return const LlmResponse(error: '响应格式错误：缺少 choices');
      }

      final message = choices[0]['message'] as Map<String, dynamic>?;
      if (message == null) {
        return const LlmResponse(error: '响应格式错误：缺少 message');
      }

      // 解析 content 或 tool_calls
      final content = message['content']?.toString();
      final toolCallsJson = message['tool_calls'] as List<dynamic>?;

      if (toolCallsJson != null && toolCallsJson.isNotEmpty) {
        final toolCalls = toolCallsJson
            .whereType<Map<String, dynamic>>()
            .map((tc) => LlmToolCall.fromJson(tc))
            .toList();
        return LlmResponse(toolCalls: toolCalls);
      }

      return LlmResponse(content: content ?? '');
    } on DioException catch (e) {
      return LlmResponse(error: e.message ?? 'Network error: $e');
    } catch (e) {
      return LlmResponse(error: '未知错误: $e');
    }
  }

  /// 将 registry.toolSchemas() 包装成 OpenAI tools 格式
  static List<Map<String, Object?>> wrapToolSchemas(
      List<Map<String, Object?>> schemas) {
    return schemas;
  }
}
