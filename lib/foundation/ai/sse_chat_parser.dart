import 'dart:convert';

import 'package:picakeep/foundation/ai/llm_client.dart';

/// 15轮06号计划：OpenAI 兼容 SSE 流式 chat 响应解析器（纯状态机，不做 IO）。
///
/// 用法：外层把字节流经 streaming `utf8.decoder` + `LineSplitter` 变成行流后
/// 逐行喂 [addLine]，流自然结束或 [isDone] 为 true 后调 [finish] 取聚合终值。
///
/// 解析铁律（来源：DeepSeek/OpenAI 官方文档 + SSE 标准工程实践）：
/// - `data: [DONE]` 是字面量不是 JSON，不能喂 jsonDecode；
/// - 以 `:` 开头的行是 SSE 注释/keep-alive（DeepSeek 思考期长静默时会发），忽略；
/// - `choices` 可能是空数组（include_usage 的独立 usage 块），不能假设
///   choices[0] 存在——这是真实崩溃高发点；
/// - tool_calls 的 function.arguments 是跨 chunk 增量拼接的 JSON 字符串片段，
///   中途永远可能残缺，绝不能边收边 jsonDecode，只在 [finish] 里整体 decode；
/// - name 用追加而非只取首片（个别兼容实现把 name 拖到后续 chunk）；
/// - finish_reason 不写死枚举（DeepSeek 特有 insufficient_system_resource）；
/// - 同一 delta 可能同时携带 content 与 tool_calls，分支不互斥；
/// - chunk 内 JSON 键顺序不保证，只按键名取值；取值全判空。
class SseChatParser {
  SseChatParser({this.onReasoningDelta, this.onContentDelta});

  final void Function(String delta)? onReasoningDelta;
  final void Function(String delta)? onContentDelta;

  final StringBuffer _content = StringBuffer();
  final StringBuffer _reasoning = StringBuffer();

  /// key = delta.tool_calls[].index（归属标识，并行多工具分片可交错到达）。
  final Map<int, _SseToolCallBuffer> _toolBuffers = {};

  LlmUsage? usage;
  String? finishReason;
  bool _done = false;

  bool get isDone => _done;
  String get contentSoFar => _content.toString();
  String get reasoningSoFar => _reasoning.toString();

  /// 喂入一行（不含行尾符；LineSplitter 自带跨包残片缓冲、兼容 \r\n）。
  void addLine(String line) {
    if (_done) return;
    if (line.isEmpty) return; // SSE 事件分隔空行
    if (line.startsWith(':')) return; // 注释/keep-alive 行
    if (!line.startsWith('data:')) return; // event:/id: 等其他字段忽略
    var payload = line.substring(5);
    if (payload.startsWith(' ')) payload = payload.substring(1); // 兼容无空格
    if (payload.trim() == '[DONE]') {
      _done = true;
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return; // 单行坏 JSON 忽略，不让整条流失败
    }
    if (decoded is! Map<String, dynamic>) return;

    // 凡遇 usage != null 的 chunk 就记录，两种投递形态都兼容：
    // DeepSeek 挂在 finish_reason 的最后内容 chunk 上 / OpenAI include_usage
    // 在 [DONE] 前发 choices 为空数组的独立块。
    final usageJson = decoded['usage'];
    if (usageJson is Map<String, dynamic>) {
      usage = LlmUsage.fromJson(usageJson);
    }

    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return; // usage 块 choices == []
    final choice = choices.first;
    if (choice is! Map) return;

    final reason = choice['finish_reason'];
    if (reason is String && reason.isNotEmpty) finishReason = reason;

    final delta = choice['delta'];
    if (delta is! Map) return; // delta 可能缺失/为 {}

    // reasoning_content 主（DeepSeek/Qwen/GLM/Kimi）+ reasoning 兜底
    // （OpenRouter/Groq 形态，推断未验证）。
    final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
    if (reasoning is String && reasoning.isNotEmpty) {
      _reasoning.write(reasoning);
      onReasoningDelta?.call(reasoning);
    }

    final content = delta['content'];
    if (content is String && content.isNotEmpty) {
      _content.write(content);
      onContentDelta?.call(content);
    }

    final toolCalls = delta['tool_calls'];
    if (toolCalls is List) {
      for (final raw in toolCalls) {
        if (raw is! Map) continue;
        final index = (raw['index'] as num?)?.toInt() ?? 0;
        final buffer = _toolBuffers.putIfAbsent(index, _SseToolCallBuffer.new);
        final id = raw['id'];
        if (id is String && id.isNotEmpty) buffer.id = id; // 覆盖写
        final func = raw['function'];
        if (func is Map) {
          final name = func['name'];
          if (name is String && name.isNotEmpty) buffer.name.write(name);
          final args = func['arguments'];
          if (args is String && args.isNotEmpty) buffer.arguments.write(args);
        }
      }
    }
  }

  /// 聚合终值。arguments 到这里才整体 decode——复用 [LlmToolCall.fromJson]
  /// 的宽容解析（坏 JSON → 空 map），与非流式路径行为一致。
  SseChatResult finish() {
    final indices = _toolBuffers.keys.toList()..sort();
    final toolCalls = <LlmToolCall>[
      for (final i in indices)
        LlmToolCall.fromJson({
          'id': _toolBuffers[i]!.id,
          'function': {
            'name': _toolBuffers[i]!.name.toString(),
            'arguments': _toolBuffers[i]!.arguments.toString(),
          },
        }),
    ];
    return SseChatResult(
      content: _content.toString(),
      reasoning: _reasoning.toString(),
      toolCalls: toolCalls,
      usage: usage,
      finishReason: finishReason,
      sawDone: _done,
    );
  }
}

/// [SseChatParser.finish] 的聚合结果。
class SseChatResult {
  const SseChatResult({
    required this.content,
    required this.reasoning,
    required this.toolCalls,
    required this.usage,
    required this.finishReason,
    required this.sawDone,
  });

  final String content;
  final String reasoning;
  final List<LlmToolCall> toolCalls;
  final LlmUsage? usage;
  final String? finishReason;
  final bool sawDone;

  bool get hasToolCalls => toolCalls.isNotEmpty;
}

class _SseToolCallBuffer {
  String id = '';
  final StringBuffer name = StringBuffer();
  final StringBuffer arguments = StringBuffer();
}
