import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/sse_chat_parser.dart';

/// 15轮06号计划：SSE 流式解析器守卫测试（纯状态机，不发网络）。
void main() {
  String data(Map<String, Object?> chunk) => 'data: ${jsonEncode(chunk)}';

  Map<String, Object?> deltaChunk(Map<String, Object?> delta,
          {String? finishReason, Map<String, Object?>? usage}) =>
      {
        'id': 'x',
        'choices': [
          {
            'index': 0,
            'delta': delta,
            'finish_reason': finishReason,
          }
        ],
        if (usage != null) 'usage': usage,
      };

  const usageJson = {
    'prompt_tokens': 10,
    'completion_tokens': 5,
    'prompt_cache_hit_tokens': 6,
    'prompt_cache_miss_tokens': 4,
  };

  test('纯 content 流：三段聚合 + usage + finishReason + [DONE]', () {
    final parser = SseChatParser();
    parser.addLine(data(deltaChunk({'role': 'assistant', 'content': ''})));
    parser.addLine(data(deltaChunk({'content': '你好'})));
    parser.addLine(data(deltaChunk({'content': '，世界'})));
    parser.addLine(
        data(deltaChunk(const {}, finishReason: 'stop', usage: usageJson)));
    parser.addLine('data: [DONE]');

    final result = parser.finish();
    expect(result.content, '你好，世界');
    expect(result.usage, isNotNull);
    expect(result.usage!.promptTokens, 10);
    expect(result.usage!.cacheHitTokens, 6);
    expect(result.finishReason, 'stop');
    expect(result.sawDone, isTrue);
    expect(result.hasToolCalls, isFalse);
  });

  test('reasoning→content 切换：回调顺序与聚合值', () {
    final events = <String>[];
    final parser = SseChatParser(
      onReasoningDelta: (d) => events.add('r:$d'),
      onContentDelta: (d) => events.add('c:$d'),
    );
    parser.addLine(data(deltaChunk({'reasoning_content': '先想'})));
    parser.addLine(data(deltaChunk({'reasoning_content': '一下'})));
    parser.addLine(data(deltaChunk({'content': '答案'})));
    parser.addLine('data: [DONE]');

    // 「首个 content 回调」即 UI 判定思考结束的信号，不依赖任何分隔符。
    expect(events, ['r:先想', 'r:一下', 'c:答案']);
    final result = parser.finish();
    expect(result.reasoning, '先想一下');
    expect(result.content, '答案');
  });

  test('reasoning 兜底字段（reasoning）也被识别', () {
    final parser = SseChatParser();
    parser.addLine(data(deltaChunk({'reasoning': 'alt'})));
    expect(parser.finish().reasoning, 'alt');
  });

  test('同一 delta 同时带 content 与 tool_calls：分支不互斥', () {
    final parser = SseChatParser();
    parser.addLine(data(deltaChunk({
      'content': '正在查',
      'tool_calls': [
        {
          'index': 0,
          'id': 'call_1',
          'type': 'function',
          'function': {'name': 'search_online', 'arguments': '{}'},
        }
      ],
    })));
    final result = parser.finish();
    expect(result.content, '正在查');
    expect(result.toolCalls, hasLength(1));
    expect(result.toolCalls.first.name, 'search_online');
  });

  test('tool_calls 分片重组：残缺 arguments 只在 finish 整体 decode', () {
    final parser = SseChatParser();
    parser.addLine(data(deltaChunk({
      'tool_calls': [
        {
          'index': 0,
          'id': 'call_abc',
          'type': 'function',
          'function': {'name': 'get_weather', 'arguments': ''},
        }
      ],
    })));
    parser.addLine(data(deltaChunk({
      'tool_calls': [
        {
          'index': 0,
          'function': {'arguments': '{"loca'},
        }
      ],
    })));
    parser.addLine(data(deltaChunk({
      'tool_calls': [
        {
          'index': 0,
          'function': {'arguments': 'tion": "Hangzhou"}'},
        }
      ],
    })));
    parser.addLine(data(deltaChunk(const {}, finishReason: 'tool_calls')));
    parser.addLine('data: [DONE]');

    final result = parser.finish();
    expect(result.finishReason, 'tool_calls');
    expect(result.toolCalls, hasLength(1));
    final call = result.toolCalls.first;
    expect(call.id, 'call_abc');
    expect(call.name, 'get_weather');
    expect(call.arguments, {'location': 'Hangzhou'});
  });

  test('并行双工具：index 0/1 分片交错到达，finish 按 index 排序', () {
    final parser = SseChatParser();
    parser.addLine(data(deltaChunk({
      'tool_calls': [
        {
          'index': 1,
          'id': 'call_b',
          'function': {'name': 'tool_b', 'arguments': '{"b":'},
        }
      ],
    })));
    parser.addLine(data(deltaChunk({
      'tool_calls': [
        {
          'index': 0,
          'id': 'call_a',
          'function': {'name': 'tool_a', 'arguments': '{"a":1}'},
        }
      ],
    })));
    parser.addLine(data(deltaChunk({
      'tool_calls': [
        {
          'index': 1,
          'function': {'arguments': '2}'},
        }
      ],
    })));

    final result = parser.finish();
    expect(result.toolCalls.map((c) => c.id).toList(), ['call_a', 'call_b']);
    expect(result.toolCalls[0].arguments, {'a': 1});
    expect(result.toolCalls[1].arguments, {'b': 2});
  });

  test('name 跨片追加而非只取首片', () {
    final parser = SseChatParser();
    parser.addLine(data(deltaChunk({
      'tool_calls': [
        {
          'index': 0,
          'id': 'c',
          'function': {'name': 'get_'},
        }
      ],
    })));
    parser.addLine(data(deltaChunk({
      'tool_calls': [
        {
          'index': 0,
          'function': {'name': 'weather', 'arguments': '{}'},
        }
      ],
    })));
    expect(parser.finish().toolCalls.first.name, 'get_weather');
  });

  test('keep-alive 注释行 / 空行 / 无空格 data: 前缀都能正确处理', () {
    final parser = SseChatParser();
    parser.addLine(': keep-alive');
    parser.addLine('');
    parser.addLine('event: message');
    parser.addLine('data:${jsonEncode(deltaChunk({'content': 'ok'}))}');
    parser.addLine(': ping');
    final result = parser.finish();
    expect(result.content, 'ok');
    expect(result.sawDone, isFalse);
  });

  test('include_usage 独立块 choices==[] 不崩且 usage 被记录', () {
    final parser = SseChatParser();
    parser.addLine(data(deltaChunk({'content': 'hi'})));
    parser.addLine(data(const {'choices': [], 'usage': usageJson}));
    parser.addLine('data: [DONE]');
    final result = parser.finish();
    expect(result.content, 'hi');
    expect(result.usage?.completionTokens, 5);
  });

  test('[DONE] 之后 isDone 为 true 且后续行被忽略', () {
    final parser = SseChatParser();
    parser.addLine(data(deltaChunk({'content': 'a'})));
    parser.addLine('data: [DONE]');
    expect(parser.isDone, isTrue);
    parser.addLine(data(deltaChunk({'content': 'b'})));
    expect(parser.finish().content, 'a');
  });

  test('整行坏 JSON 被忽略且不影响后续行', () {
    final parser = SseChatParser();
    parser.addLine('data: {不是 json');
    parser.addLine(data(deltaChunk({'content': 'good'})));
    expect(parser.finish().content, 'good');
  });

  test('DeepSeek 特有 finish_reason 原样保留（不写死枚举）', () {
    final parser = SseChatParser();
    parser.addLine(data(
        deltaChunk(const {}, finishReason: 'insufficient_system_resource')));
    expect(parser.finish().finishReason, 'insufficient_system_resource');
  });

  test('delta 缺失或非 Map 不崩', () {
    final parser = SseChatParser();
    parser.addLine(data(const {
      'choices': [
        {'index': 0, 'finish_reason': null}
      ]
    }));
    parser.addLine(data(const {
      'choices': [
        {'index': 0, 'delta': 'oops'}
      ]
    }));
    expect(parser.finish().content, isEmpty);
  });
}
