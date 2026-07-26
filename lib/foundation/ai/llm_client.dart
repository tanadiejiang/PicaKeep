import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/ai/ai_attachments.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/foundation/ai/sse_chat_parser.dart';
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

  /// 15轮06号计划：思考链（DeepSeek reasoning_content）。存档永远保留；
  /// 是否随请求回传由 _buildRequestMessages() 的剥离规则决定（决策B），
  /// 本类的 toJson/toRequestJson 只负责“有就序列化”。
  final String? reasoningContent;

  const LlmMessage({
    required this.role,
    this.content,
    this.toolCalls,
    this.toolCallId,
    this.name,
    this.imagePaths = const [],
    this.reasoningContent,
  });

  LlmMessage.system(this.content)
      : role = 'system',
        toolCalls = null,
        toolCallId = null,
        name = null,
        imagePaths = const [],
        reasoningContent = null;

  LlmMessage.user(this.content, {this.imagePaths = const []})
      : role = 'user',
        toolCalls = null,
        toolCallId = null,
        name = null,
        reasoningContent = null;

  LlmMessage.assistant({this.content, this.toolCalls, this.reasoningContent})
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
        imagePaths = const [],
        reasoningContent = null;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'role': role};
    if (content != null) json['content'] = content;
    if (toolCalls != null && toolCalls!.isNotEmpty) {
      json['tool_calls'] = toolCalls!.map((tc) => tc.toJson()).toList();
    }
    if (toolCallId != null) json['tool_call_id'] = toolCallId;
    if (name != null) json['name'] = name;
    if (reasoningContent != null && reasoningContent!.isNotEmpty) {
      json['reasoning_content'] = reasoningContent;
    }
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
      // 15轮06号计划：旧存档无该字段 → null，缺省兼容不升 version。
      reasoningContent: json['reasoning_content']?.toString(),
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
      // 15轮06号计划：带图轮的历史瘦身不得顺带丢 reasoning。
      reasoningContent: reasoningContent,
    );
  }

  /// 返回“剥掉思考链”的副本；本来就没有时返回自身（零开销）。
  /// 只允许 _buildRequestMessages() 调用（决策B：发送侧唯一剥离点）。
  LlmMessage stripReasoning() {
    if (reasoningContent == null || reasoningContent!.isEmpty) return this;
    return LlmMessage(
      role: role,
      content: content,
      toolCalls: toolCalls,
      toolCallId: toolCallId,
      name: name,
      imagePaths: imagePaths,
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

  /// 15轮06号计划：本轮思考链聚合终值。
  final String? reasoningContent;
  final List<LlmToolCall>? toolCalls;
  final String? error;
  final LlmUsage? usage;

  const LlmResponse({
    this.content,
    this.reasoningContent,
    this.toolCalls,
    this.error,
    this.usage,
  });

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
    void Function(String delta)? onReasoningDelta,
    void Function(String delta)? onContentDelta,
    CancelToken? cancelToken,
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

    // 15轮06号计划：思考开关（设置146）。开 = 不发任何 thinking 字段（服务端
    // 默认；OpenAI 官方对未知顶层字段报 400，绝不多发）；关 = 显式 disabled。
    if (appdata.settings[aiThinkingEnabledSettingIndex] != '1') {
      requestBody['thinking'] = {'type': 'disabled'};
    }
    final wantStream = onReasoningDelta != null || onContentDelta != null;
    if (wantStream) {
      requestBody['stream'] = true;
      // 只有 stream=true 时可设；[DONE] 前多发一个带 usage 的空 choices 块。
      requestBody['stream_options'] = {'include_usage': true};
    }

    // endpoint 推导是纯字符串拼接，无异常风险，出 try 供流式分支复用。
    final endpoint = baseUrl.endsWith('/chat/completions')
        ? baseUrl
        : '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';

    if (wantStream) {
      return _chatStreaming(
        dio,
        endpoint,
        requestBody,
        apiKey,
        modelId: modelId,
        messages: messages,
        tools: tools,
        conversationHash: conversationHash,
        turn: turn,
        round: round,
        onReasoningDelta: onReasoningDelta,
        onContentDelta: onContentDelta,
        cancelToken: cancelToken,
      );
    }

    // 发送请求
    try {
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
      // 15轮06号计划：reasoning_content 主 + reasoning 兜底。
      final reasoningContent =
          (message['reasoning_content'] ?? message['reasoning'])?.toString();
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
        // 决策B：工具轮的 content/reasoning 都要保留。
        return LlmResponse(
          content: content,
          reasoningContent: reasoningContent,
          toolCalls: toolCalls,
          usage: usage,
        );
      }

      return LlmResponse(
        content: content ?? '',
        reasoningContent: reasoningContent,
        usage: usage,
      );
    } on DioException catch (e) {
      return LlmResponse(error: e.message ?? 'Network error: $e');
    } catch (e) {
      return LlmResponse(error: '未知错误: $e');
    }
  }

  /// 15轮06号计划：SSE 流式聊天请求。错误一律折叠成 [LlmResponse.error]
  /// 不抛异常——与非流式路径的契约一致。
  static Future<LlmResponse> _chatStreaming(
    Dio dio,
    String endpoint,
    Map<String, dynamic> requestBody,
    String apiKey, {
    required String modelId,
    required List<LlmMessage> messages,
    List<Map<String, Object?>>? tools,
    String? conversationHash,
    int? turn,
    int? round,
    void Function(String delta)? onReasoningDelta,
    void Function(String delta)? onContentDelta,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await dio.post<ResponseBody>(
        endpoint,
        data: requestBody,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
          },
          // 坑①：MyLogInterceptor.onRequest 会把 null receiveTimeout 补成
          // 30s（app_dio.dart:32）。流式下它只约束首包/头部到达，思考期可能
          // 长静默，显式给大值。
          receiveTimeout: const Duration(seconds: 120),
          // 坑②：RetryHttpClientAdapter 非 4xx 失败自动重试会重复发整个
          // POST（app_dio.dart:176-206），流式请求必须逃生。
          extra: {'noRetry': true},
          // 坑④前置：非 200 时 dio 默认抛异常且 body 是 ResponseBody 对象
          // 取不到 provider 报错文本，全部放行自己处理。
          validateStatus: (_) => true,
        ),
      );
      final body = response.data;
      if (body == null) return const LlmResponse(error: '响应为空');
      if (response.statusCode != 200) {
        // 坑④：4xx/5xx 的 Content-Type 是 application/json，自己 drain
        // 错误流解出报错文本（错误码语义以 HTTP 状态码为准，body 仅展示）。
        final detail = await _drainErrorBody(body);
        return LlmResponse(error: 'HTTP ${response.statusCode}: $detail');
      }
      final parser = SseChatParser(
        onReasoningDelta: onReasoningDelta,
        onContentDelta: onContentDelta,
      );
      // 字节流 → streaming utf8.decoder（防多字节字符跨包被拆）→ LineSplitter
      // 逐行缓冲（跨包残片自动留存、兼容 \r\n）。绝不按”一次 onData = 一个
      // 事件”解析。
      // 坑③：CancelToken 只挂在 POST 请求上，不挂在 stream.timeout 的 onTimeout
      // 回调里——不触发”与 receiveTimeout 定时器竞态导致 Bad state”的场景
      // （第十四轮计划10 实测的竞态是把 cancel 混入 timeout sink 操作序列造成的，
      // 本实现两者路径独立）。用户主动取消会让 dio 抛 DioExceptionType.cancel，
      // 在 catch 里折叠为 error:null；流内静默段 receiveTimeout 无效，stream.timeout 兜底。
      final lines = utf8.decoder
          .bind(body.stream)
          .transform(const LineSplitter())
          .timeout(
        const Duration(seconds: 120),
        onTimeout: (sink) {
          sink.addError(TimeoutException('SSE 流 120 秒无数据'));
          sink.close();
        },
      );
      await for (final line in lines) {
        if (cancelToken?.isCancelled ?? false) break; // 用户主动停止
        parser.addLine(line);
        if (parser.isDone) break; // [DONE] 后正常收口；break 会取消订阅
      }
      final result = parser.finish();
      if (result.usage != null) {
        _logUsage(
          modelId,
          result.usage!,
          messages,
          tools: tools,
          conversationHash: conversationHash,
          turn: turn,
          round: round,
        );
      }
      if (result.hasToolCalls) {
        return LlmResponse(
          content: result.content.isEmpty ? null : result.content,
          reasoningContent: result.reasoning.isEmpty ? null : result.reasoning,
          toolCalls: result.toolCalls,
          usage: result.usage,
        );
      }
      return LlmResponse(
        content: result.content,
        reasoningContent: result.reasoning.isEmpty ? null : result.reasoning,
        usage: result.usage,
      );
    } on DioException catch (e) {
      // 用户主动取消：视为正常收口，不向上报错（_runLoop 会走空响应路径收尾）。
      if (e.type == DioExceptionType.cancel) {
        return const LlmResponse();
      }
      return LlmResponse(error: e.message ?? 'Network error: $e');
    } on TimeoutException catch (e) {
      return LlmResponse(error: '流式响应超时：${e.message}');
    } catch (e) {
      return LlmResponse(error: '未知错误: $e');
    }
  }

  /// 读完非 200 的错误响应体并尽量解出 provider 的 error.message。
  static Future<String> _drainErrorBody(ResponseBody body) async {
    try {
      final bytes = <int>[];
      await body.stream
          .timeout(const Duration(seconds: 5),
              onTimeout: (sink) => sink.close())
          .forEach(bytes.addAll);
      var text = utf8.decode(bytes, allowMalformed: true).trim();
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map && decoded['error'] is Map) {
          final message = (decoded['error'] as Map)['message']?.toString();
          if (message != null && message.isNotEmpty) text = message;
        }
      } catch (_) {/* body 不是 JSON 时保留原文 */}
      if (text.length > 300) text = '${text.substring(0, 300)}…';
      return text.isEmpty ? '(无响应体)' : text;
    } catch (_) {
      return '(读取错误响应失败)';
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
