import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/ai/ai_attachments.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/app_dio.dart';

/// Canonical JSON used by local cache-shape diagnostics.
///
/// Map keys are sorted recursively while list order is preserved. The result
/// is a diagnostic fingerprint only; it is not an authentication primitive.
String aiDiagnosticSha256(Object? value) {
  final digest = sha256.convert(utf8.encode(_canonicalJson(value))).toString();
  return digest.substring(0, 16);
}

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toSet().toList()
      ..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
  }
  if (value is Iterable) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  if (value == null || value is String || value is num || value is bool) {
    return jsonEncode(value);
  }
  return jsonEncode(value.toString());
}

/// LLM 消息（OpenAI 格式）
class LlmMessage {
  final String role; // 'system' | 'user' | 'assistant' | 'tool'
  final String? content;
  final List<LlmToolCall>? toolCalls;
  final String? toolCallId; // tool role 时必填
  final String? name; // tool role 时填工具名

  /// 15轮03号计划（决策A）：该消息附带的图片，存相对附件根的路径
  /// （'{conversationId}/{fileName}'，'/' 分隔），**不存 base64**。
  /// base64 只在发请求时由 [toRequestJson] 现场从本地文件生成，不落存档。
  final List<String> imagePaths;

  const LlmMessage({
    required this.role,
    this.content,
    this.toolCalls,
    this.toolCallId,
    this.name,
    this.imagePaths = const [],
  });

  LlmMessage.system(this.content)
      : role = 'system',
        toolCalls = null,
        toolCallId = null,
        name = null,
        imagePaths = const [];

  LlmMessage.user(this.content, {this.imagePaths = const []})
      : role = 'user',
        toolCalls = null,
        toolCallId = null,
        name = null;

  LlmMessage.assistant({this.content, this.toolCalls})
      : role = 'assistant',
        toolCallId = null,
        name = null,
        imagePaths = const [];

  LlmMessage.tool({
    required this.toolCallId,
    required this.name,
    required this.content,
  })  : role = 'tool',
        toolCalls = null,
        imagePaths = const [];

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'role': role};
    if (content != null) json['content'] = content;
    if (toolCalls != null && toolCalls!.isNotEmpty) {
      json['tool_calls'] = toolCalls!.map((tc) => tc.toJson()).toList();
    }
    if (toolCallId != null) json['tool_call_id'] = toolCallId;
    if (name != null) json['name'] = name;
    if (imagePaths.isNotEmpty) json['imagePaths'] = imagePaths;
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
      // 旧存档没有该字段，缺省为空列表，天然兼容（不升 format version，
      // 注释先例：ai_conversation.dart:170）。
      imagePaths:
          (json['imagePaths'] as List?)?.map((e) => e.toString()).toList() ??
              const [],
    );
  }

  /// 发请求用的序列化出口。与 [toJson]（存档出口）分离：
  /// imagePaths 为空时输出与 toJson 完全一致；非空时把 content 展开成
  /// OpenAI parts 数组，base64 现场从本地文件读取，不落存档。
  Future<Map<String, dynamic>> toRequestJson() async {
    if (imagePaths.isEmpty) return toJson();
    final parts = <Map<String, dynamic>>[
      {'type': 'text', 'text': content ?? ''},
    ];
    for (final relative in imagePaths) {
      final file = File(resolveAiAttachmentPath(relative));
      if (!await file.exists()) {
        // 附件被清理/目录被改动时降级为占位文本，不抛异常不中断请求。
        parts.add({'type': 'text', 'text': '[图片文件缺失，无法提供该图片数据]'});
        continue;
      }
      final bytes = await file.readAsBytes();
      final mime = detectAiImageType(bytes).mime;
      parts.add({
        'type': 'image_url',
        'image_url': {'url': 'data:$mime;base64,${base64Encode(bytes)}'},
      });
    }
    return <String, dynamic>{'role': role, 'content': parts};
  }

  /// 历史瘦身占位（决策B）：同样输入必须产出同样字符串（稳定性是接口契约，
  /// 破坏会破坏 DeepSeek 前缀缓存，见计划「风险」）。
  static String imagePlaceholder(int count) =>
      '\n[本条消息此前附带 $count 张图片，图片数据不再重复发送，其内容已在上文对话中体现]';

  /// 返回“图片降级为占位文本”的副本：content 追加占位、imagePaths 清空。
  /// 无图消息返回自身（零开销）。
  LlmMessage stripImagesToPlaceholder() {
    if (imagePaths.isEmpty) return this;
    return LlmMessage(
      role: role,
      content: '${content ?? ''}${imagePlaceholder(imagePaths.length)}',
      toolCalls: toolCalls,
      toolCallId: toolCallId,
      name: name,
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

/// 单次请求的 token 用量，含 DeepSeek 等 provider 的前缀缓存命中拆分。
/// `cacheHitTokens`/`cacheMissTokens` 来自响应 `usage.prompt_cache_hit_tokens`/
/// `prompt_cache_miss_tokens`；非 DeepSeek 或不支持该字段的 provider 下二者为 null。
class LlmUsage {
  final int promptTokens;
  final int completionTokens;
  final int? cacheHitTokens;
  final int? cacheMissTokens;

  const LlmUsage({
    required this.promptTokens,
    required this.completionTokens,
    this.cacheHitTokens,
    this.cacheMissTokens,
  });

  bool get hasCacheInfo => cacheHitTokens != null && cacheMissTokens != null;

  /// 命中率（0~100），无缓存字段或 prompt 为 0 时返回 null。
  double? get cacheHitRatePercent {
    if (!hasCacheInfo || promptTokens <= 0) return null;
    return cacheHitTokens! / promptTokens * 100;
  }

  factory LlmUsage.fromJson(Map<String, dynamic> json) {
    return LlmUsage(
      promptTokens: (json['prompt_tokens'] as num?)?.toInt() ?? 0,
      completionTokens: (json['completion_tokens'] as num?)?.toInt() ?? 0,
      cacheHitTokens: (json['prompt_cache_hit_tokens'] as num?)?.toInt(),
      cacheMissTokens: (json['prompt_cache_miss_tokens'] as num?)?.toInt(),
    );
  }
}

/// LLM 响应
class LlmResponse {
  final String? content;
  final List<LlmToolCall>? toolCalls;
  final String? error;
  final LlmUsage? usage;

  const LlmResponse({this.content, this.toolCalls, this.error, this.usage});

  bool get hasToolCalls => toolCalls != null && toolCalls!.isNotEmpty;
  bool get hasError => error != null;
}

/// LLM HTTP 客户端（OpenAI 兼容 API）
class LlmClient {
  LlmClient._();

  /// DeepSeek 模板下 Base URL 留空时的官方默认地址。
  static const _deepseekDefaultBaseUrl = 'https://api.deepseek.com';

  /// 发送聊天请求
  static Future<LlmResponse> chat(
    List<LlmMessage> messages, {
    List<Map<String, Object?>>? tools,
    String? conversationHash,
    int? turn,
    int? round,
  }) async {
    final template = appdata.settings[aiProviderTemplateSettingIndex];
    var baseUrl = appdata.settings[aiBaseUrlSettingIndex].trim();
    if (baseUrl.isEmpty && template == 'deepseek') {
      baseUrl = _deepseekDefaultBaseUrl;
    }
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

    // 构建请求体（15轮03号计划：改用 toRequestJson，带图消息展开为 parts；
    // 存档路径仍走 toJson，见 ai_conversation_store.dart）
    final requestMessages = <Map<String, dynamic>>[];
    for (final m in messages) {
      requestMessages.add(await m.toRequestJson());
    }
    final requestBody = <String, dynamic>{
      'model': modelId,
      'messages': requestMessages,
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

      final usageJson = data['usage'] as Map<String, dynamic>?;
      final usage = usageJson == null ? null : LlmUsage.fromJson(usageJson);
      if (usage != null) {
        _logUsage(
          modelId,
          usage,
          messages,
          tools: tools,
          conversationHash: conversationHash,
          turn: turn,
          round: round,
        );
      }

      if (toolCallsJson != null && toolCallsJson.isNotEmpty) {
        final toolCalls = toolCallsJson
            .whereType<Map<String, dynamic>>()
            .map((tc) => LlmToolCall.fromJson(tc))
            .toList();
        return LlmResponse(toolCalls: toolCalls, usage: usage);
      }

      return LlmResponse(content: content ?? '', usage: usage);
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

  /// 记录本次请求的 token 用量到日志（LogManager -> 设置/日志页可查看/导出）。
  /// 无 `hasCacheInfo` 时说明该 provider 未返回缓存拆分字段，仍记录基础用量供参考。
  ///
  /// 同时记录“开头连续 system 前缀”的指纹（条数/字符数/hash）用于诊断缓存击穿：
  /// - 连续几条请求 sysHash 不变但命中率仍很低 → DeepSeek 前缀缓存 TTL 过期（不可避免）；
  /// - sysHash 每次都变 → 动态 system 前缀变动击穿缓存（可通过调整 _buildRequestMessages() 修复）。
  static void _logUsage(
    String modelId,
    LlmUsage usage,
    List<LlmMessage> messages, {
    List<Map<String, Object?>>? tools,
    String? conversationHash,
    int? turn,
    int? round,
  }) {
    final buffer = StringBuffer(
      'model=$modelId prompt=${usage.promptTokens} '
      'completion=${usage.completionTokens}',
    );
    final rate = usage.cacheHitRatePercent?.toStringAsFixed(1) ?? '-';
    buffer.write(
      ' cacheHit=${usage.cacheHitTokens ?? '-'}'
      ' cacheMiss=${usage.cacheMissTokens ?? '-'}'
      ' hitRate=${rate == '-' ? '-' : '$rate%'}',
    );
    final messageJson = messages.map((message) => message.toJson()).toList();
    buffer
      ..write(' shapeV=2')
      ..write(' conversation=${conversationHash ?? '-'}')
      ..write(' turn=${turn ?? '-'} round=${round ?? '-'}')
      ..write(' messageCount=${messages.length}')
      ..write(' messagesHash=${aiDiagnosticSha256(messageJson)}')
      ..write(' toolCount=${tools?.length ?? 0}')
      ..write(' toolsHash=${aiDiagnosticSha256(tools ?? const [])}')
      ..write(' ${_systemPrefixFingerprint(messages)}');
    LogManager.addLog(LogLevel.info, 'AiUsage', buffer.toString());
  }

  /// 计算请求开头“连续 system 消息”块的指纹。
  /// DeepSeek 前缀缓存逐字节从头匹配，这段 system 前缀一旦变动就会击穿缓存。
  static String _systemPrefixFingerprint(List<LlmMessage> messages) {
    var count = 0;
    final buffer = StringBuffer();
    for (final m in messages) {
      if (m.role != 'system') break;
      count++;
      buffer
        ..write(m.content ?? '')
        ..write(' ');
    }
    final chars = buffer.length;
    final hash = aiDiagnosticSha256(buffer.toString());
    return 'msgs=${messages.length} sysMsgs=$count sysChars=$chars '
        'sysHash=$hash';
  }
}
