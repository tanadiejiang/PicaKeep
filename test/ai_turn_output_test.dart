import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/ai/ai_capabilities.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_conversation_store.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/foundation/ai/ai_tool.dart';
import 'package:picakeep/foundation/ai/llm_client.dart';
import 'package:picakeep/foundation/ai/tools/download_comic_tool.dart';
import 'package:picakeep/foundation/ai/tools/search_by_image_tool.dart';
import 'package:picakeep/foundation/app.dart';

class _FixtureTool extends AiTool {
  _FixtureTool(this.name, this.run);
  @override
  final String name;
  final FutureOr<AiToolResult> Function(Map<String, dynamic>) run;
  @override
  String get description => 'Deterministic local fixture';
  @override
  Map<String, Object?> get parametersSchema => const {'type': 'object'};
  @override
  Future<AiToolResult> execute(Map<String, dynamic> args) async => run(args);
}

const _fallback = '（AI本轮未返回有效内容）';
const _item = {'id': 'fixture-1', 'title': '同一作品', 'source': 'jm'};
LlmToolCall _list(String callId) =>
    LlmToolCall(id: callId, name: 'display_result_list', arguments: const {
      'items': [_item]
    });
const _download = LlmToolCall(
    id: 'download-1',
    name: 'download_comic',
    arguments: {'source': 'jm', 'id': '123', 'title': '示例'});

void main() {
  late Directory data;
  late List<String> settings;
  var id = 0;
  setUpAll(() {
    data = Directory.systemTemp.createTempSync('pk49_turn_output_');
    App.dataPath = data.path;
  });
  tearDownAll(() => data.deleteSync(recursive: true));
  setUp(() {
    settings = List.of(appdata.settings);
    appdata.settings[aiMaxToolRoundsSettingIndex] = '10';
    appdata.settings[aiCapabilityDownloadComicSettingIndex] = '1';
    appdata.settings[aiAutoDownloadEnabledSettingIndex] = '0';
  });
  tearDown(() {
    appdata.settings = settings;
    AiCapabilities.registry.register(const SearchByImageTool());
    AiCapabilities.registry.register(const DownloadComicTool());
  });

  AiConversationController controller(
      {AiChatRequestForTesting? chat,
      List<Map<String, dynamic>> display = const [],
      List<Map<String, dynamic>> history = const []}) {
    final ctrl = AiConversationController.restoreForTesting({
      'id': 'output-${id++}',
      'version': 2,
      'title': '测试',
      'displayMessages': display,
      'history': history,
    },
        chatRequestForTesting: chat ??
            (messages, {tools, conversationHash, turn, round}) async =>
                const LlmResponse());
    addTearDown(ctrl.dispose);
    return ctrl;
  }

  Future<bool> send(AiConversationController c, [String text = '查找作品']) =>
      c.send(text, availablePromptTags: const [], persistSelections: false);
  List<AiChatMessage> lists(AiConversationController c) => c.displayMessages
      .where((m) => m.type == AiChatMessageType.resultList)
      .toList();
  Iterable<AiChatMessage> fallbacks(AiConversationController c) =>
      c.displayMessages.where((m) => m.text == _fallback);
  void paired(AiConversationController c) {
    // Count call instances, not globally unique IDs. Empty/reused IDs here are
    // malformed-model fixtures, not a promise that providers accept such IDs.
    final outstanding = <String, int>{};
    for (final message in c.historyForTesting()) {
      for (final call in message.toolCalls ?? const <LlmToolCall>[]) {
        outstanding.update(call.id, (n) => n + 1, ifAbsent: () => 1);
      }
      if (message.role == 'tool') {
        final key = message.toolCallId!;
        expect(outstanding[key] ?? 0, greaterThan(0));
        outstanding[key] = outstanding[key]! - 1;
      }
    }
    expect(outstanding.values, everyElement(0));
  }

  for (final finalText in <String?>[null, '', ' \n\t ']) {
    test('A01 immediate list then final $finalText has no fallback', () async {
      final c = controller();
      await c.simulateToolCallRoundForTesting([_list('list')],
          continueWithLlm: false);
      expect(lists(c), hasLength(1),
          reason: 'card must precede final response');
      c.simulateFinalTextResponseForTesting(finalText);
      c.simulateFinalTextResponseForTesting(finalText);
      expect(lists(c), hasLength(1));
      expect(fallbacks(c), isEmpty);
      paired(c);
    });
  }

  test('A02 A03 identical items stay independent within and across tool rounds',
      () async {
    var calls = 0;
    late AiConversationController c;
    c = controller(
        chat: (messages, {tools, conversationHash, turn, round}) async {
      calls++;
      if (calls == 1) {
        return LlmResponse(toolCalls: [_list('one'), _list('two')]);
      }
      if (calls == 2) {
        expect(lists(c), hasLength(2));
        return LlmResponse(toolCalls: [_list('three')]);
      }
      expect(lists(c), hasLength(3));
      return const LlmResponse(content: '');
    });
    await send(c);
    expect(lists(c), hasLength(3));
    expect(lists(c).map((m) => (m.toolData as Map)['items']),
        everyElement(hasLength(1)));
    expect(fallbacks(c), isEmpty);
    paired(c);
  });

  for (final callId in ['reused', '']) {
    test('A05 distinct calls with ID "$callId" each produce a card and result',
        () async {
      final c = controller();
      await c.simulateToolCallRoundForTesting([_list(callId), _list(callId)],
          continueWithLlm: false);
      await c.simulateToolCallRoundForTesting([_list(callId)],
          continueWithLlm: false);
      c.simulateFinalTextResponseForTesting(null);
      expect(lists(c), hasLength(3));
      expect(
          c.historyForTesting().where((m) => m.role == 'tool'), hasLength(3));
      expect(fallbacks(c), isEmpty);
      paired(c);
    });
  }

  test('A06 validation failure can retry with same ID and then finish empty',
      () async {
    var calls = 0;
    final c = controller(
        chat: (messages, {tools, conversationHash, turn, round}) async {
      calls++;
      if (calls == 1) {
        return const LlmResponse(toolCalls: [
          LlmToolCall(id: 'retry', name: 'display_result_list', arguments: {
            'items': [
              {'id': 'bad'}
            ]
          })
        ]);
      }
      if (calls == 2) {
        expect(jsonDecode(messages.last.content!)['data']['retryable'], isTrue);
        return LlmResponse(toolCalls: [_list('retry')]);
      }
      return const LlmResponse(content: '  ');
    });
    await send(c);
    expect(lists(c), hasLength(1));
    expect(fallbacks(c), isEmpty);
    final results = c.historyForTesting().where((m) => m.role == 'tool');
    expect(results.map((m) => jsonDecode(m.content!)['ok']), [false, true]);
    paired(c);
  });

  for (final tool in ['display_result_list', 'search_by_image']) {
    test('A07 $tool keeps explicit zero-result feedback without fallback',
        () async {
      if (tool == 'search_by_image') {
        // 此用例验证已授权工具的空结果反馈；关闭能力由插件接线回归单独验证。
        appdata.settings[aiCapabilitySearchByImageSettingIndex] = '1';
        AiCapabilities.registry.register(_FixtureTool(tool,
            (_) => const AiToolResult.success({'items': []}, '未找到任何相似结果。')));
      }
      final c = controller();
      await c.simulateToolCallRoundForTesting([
        LlmToolCall(id: 'zero', name: tool, arguments: const {'items': []})
      ], continueWithLlm: false);
      c.simulateFinalTextResponseForTesting('');
      expect(lists(c), isEmpty);
      expect(fallbacks(c), isEmpty);
      expect(
          c.displayMessages
              .singleWhere((m) => m.type == AiChatMessageType.toolResult)
              .text,
          contains(tool == 'display_result_list' ? '没有可展示' : '未找到任何'));
      paired(c);
    });
  }

  test('A08 concrete failure and retryable data remain visible', () async {
    AiCapabilities.registry.register(_FixtureTool(
        'plan49_failure',
        (_) => const AiToolResult.failure(
            '目标文件无法读取，请检查权限。', {'retryable': true})));
    final c = controller();
    await c.simulateToolCallRoundForTesting(
        [const LlmToolCall(id: 'fail', name: 'plan49_failure', arguments: {})],
        continueWithLlm: false);
    c.simulateFinalTextResponseForTesting(null);
    expect(fallbacks(c), isEmpty);
    final result = c.displayMessages
        .singleWhere((m) => m.type == AiChatMessageType.toolResult);
    expect(result.text, contains('检查权限'));
    expect((result.toolData as Map)['retryable'], isTrue);
    paired(c);
  });

  for (final generic in <String?>[null, '工具执行成功', '查询完成。']) {
    test('A09 generic status "$generic" and raw items still need one fallback',
        () async {
      AiCapabilities.registry.register(_FixtureTool(
          'plan49_status',
          (_) => AiToolResult.success(const {
                'items': [_item]
              }, generic)));
      final c = controller();
      await c.simulateToolCallRoundForTesting([
        const LlmToolCall(id: 'status', name: 'plan49_status', arguments: {})
      ], continueWithLlm: false);
      c.simulateFinalTextResponseForTesting('');
      c.simulateFinalTextResponseForTesting(null);
      expect(lists(c), isEmpty);
      expect(fallbacks(c), hasLength(1));
      expect(c.historyForTesting().any((m) => m.content == _fallback), isFalse);
      paired(c);
    });
  }

  test(
      'A04 A09 fully empty final response is displayed only once, never stored',
      () {
    final c = controller();
    c.simulateFinalTextResponseForTesting(null);
    c.simulateFinalTextResponseForTesting('');
    c.simulateFinalTextResponseForTesting('   ');
    expect(fallbacks(c), hasLength(1));
    expect(c.historyForTesting().where((m) => m.role == 'assistant'), isEmpty);
  });

  test(
      'A10 new user turn and restored history never inherit earlier output state',
      () async {
    var calls = 0;
    final c = controller(
        chat: (messages, {tools, conversationHash, turn, round}) async {
      if (++calls == 1) return LlmResponse(toolCalls: [_list('first')]);
      return const LlmResponse();
    });
    await send(c, '第一轮');
    expect(fallbacks(c), isEmpty);
    await send(c, '第二轮');
    expect(fallbacks(c), hasLength(1));
    expect(lists(c), hasLength(1));
    final stored =
        await AiConversationStore.loadConversation(c.conversationId!);
    expect(stored, isNotNull);
    expect(stored!.containsKey('turnOutput'), isFalse);
    final reopened = controller(
        display:
            (stored['displayMessages'] as List).cast<Map<String, dynamic>>(),
        history: (stored['history'] as List).cast<Map<String, dynamic>>());
    await send(reopened, '恢复后的新问题');
    expect(fallbacks(reopened), hasLength(2));
    expect(lists(reopened), hasLength(1));
    paired(reopened);
  });

  test('A11 list and untrimmed text both survive, repeated final is ignored',
      () async {
    final c = controller();
    await c.simulateToolCallRoundForTesting([_list('list')],
        continueWithLlm: false);
    const text = '  清单已经列出。\n';
    c.simulateFinalTextResponseForTesting(text);
    c.simulateFinalTextResponseForTesting(text);
    expect(lists(c), hasLength(1));
    expect(
        c.displayMessages
            .where((m) => m.type == AiChatMessageType.assistant)
            .single
            .text,
        text);
    expect(c.historyForTesting().last.content, text);
    paired(c);
  });

  test('A12 real controller stream sealing retains reasoning display only',
      () async {
    late AiConversationController c;
    c = controller(
        chat: (messages, {tools, conversationHash, turn, round}) async {
      final sink = c.captureStreamSinkForTesting();
      sink(reasoning: '正在');
      sink(reasoning: '思考');
      expect(c.streamingMessage?.reasoningText, '正在思考');
      return const LlmResponse(content: ' ', reasoningContent: '正在思考');
    });
    await send(c);
    expect(c.streamingMessage, isNull);
    expect(c.isLoading, isFalse);
    expect(fallbacks(c), isEmpty);
    final assistant = c.displayMessages
        .singleWhere((m) => m.type == AiChatMessageType.assistant);
    expect(assistant.reasoningText, '正在思考');
    expect(assistant.text.trim(), isEmpty);
    expect(c.historyForTesting().where((m) => m.role == 'assistant'), isEmpty);
  });

  test(
      'A12 prior tool-round stream output survives blank final and stale deltas',
      () async {
    AiCapabilities.registry.register(
        _FixtureTool('plan49_status', (_) => const AiToolResult.success()));
    var calls = 0;
    late AiConversationController c;
    late void Function({String? reasoning, String? content}) oldSink;
    c = controller(
        chat: (messages, {tools, conversationHash, turn, round}) async {
      if (++calls == 1) {
        oldSink = c.captureStreamSinkForTesting();
        oldSink(reasoning: '之前的思考', content: '已开始核对');
        return const LlmResponse(
            content: '已开始核对',
            reasoningContent: '之前的思考',
            toolCalls: [
              LlmToolCall(id: 'status', name: 'plan49_status', arguments: {})
            ]);
      }
      oldSink(content: '迟到内容');
      return const LlmResponse();
    });
    await send(c);
    expect(fallbacks(c), isEmpty);
    expect(
        c.displayMessages
            .where((m) => m.type == AiChatMessageType.assistant)
            .single
            .text,
        '已开始核对');
    oldSink(content: '结束后迟到');
    expect(c.streamingMessage, isNull);
    expect(
        c
            .historyForTesting()
            .firstWhere((m) => m.toolCalls != null)
            .reasoningContent,
        '之前的思考');
    paired(c);
  });

  for (final throwsError in [false, true]) {
    test(
        'A13 ${throwsError ? 'exception' : 'error response'} seals stream without fallback',
        () async {
      late AiConversationController c;
      c = controller(
          chat: (messages, {tools, conversationHash, turn, round}) async {
        c.captureStreamSinkForTesting()(content: '未完成的正文');
        if (throwsError) throw StateError('fixture failure');
        return const LlmResponse(error: 'fixture failure');
      });
      await send(c);
      c.simulateFinalTextResponseForTesting(null);
      expect(c.displayMessages.where((m) => m.type == AiChatMessageType.error),
          hasLength(1));
      expect(fallbacks(c), isEmpty);
      expect(c.streamingMessage, isNull);
      expect(c.isLoading, isFalse);
      expect(
          c.historyForTesting().where((m) => m.role == 'assistant'), isEmpty);
    });
  }

  for (final streamed in [false, true]) {
    test(
        'A13 stop ${streamed ? 'after partial stream' : 'before any delta'} ignores late tool response',
        () async {
      final entered = Completer<void>(), response = Completer<LlmResponse>();
      late AiConversationController c;
      late void Function({String? reasoning, String? content}) sink;
      c = controller(chat: (messages, {tools, conversationHash, turn, round}) {
        sink = c.captureStreamSinkForTesting();
        if (streamed) sink(reasoning: '一半思考', content: '一半正文');
        entered.complete();
        return response.future;
      });
      final request = send(c);
      await entered.future;
      c.stopGeneration();
      sink(content: '停止后内容');
      response.complete(LlmResponse(toolCalls: [_list('late')]));
      await request;
      expect(lists(c), isEmpty);
      expect(fallbacks(c), isEmpty);
      expect(c.streamingMessage, isNull);
      expect(c.isLoading, isFalse);
      expect(
          c
              .historyForTesting()
              .where((m) => m.role != 'system' && m.role != 'user'),
          isEmpty);
      expect(
          c.displayMessages
              .where((m) => m.type == AiChatMessageType.assistant)
              .length,
          streamed ? 1 : 0);
    });
  }

  test(
      'A13 max tool rounds retains terminal feedback without duplicate closing',
      () async {
    appdata.settings[aiMaxToolRoundsSettingIndex] = '2';
    final c = controller(
        chat: (messages, {tools, conversationHash, turn, round}) async =>
            LlmResponse(toolCalls: [_list('round-$round')]));
    await send(c);
    c.simulateFinalTextResponseForTesting('');
    expect(lists(c), hasLength(2));
    expect(c.displayMessages.where((m) => m.text.contains('已达到最大工具调用次数')),
        hasLength(1));
    expect(fallbacks(c), isEmpty);
    expect(c.isLoading, isFalse);
    paired(c);
  });

  test(
      'A13 old LLM response and deltas cannot corrupt a new active conversation',
      () async {
    final entered = Completer<void>(),
        old = Completer<LlmResponse>(),
        next = Completer<LlmResponse>();
    var calls = 0;
    late AiConversationController c;
    late void Function({String? reasoning, String? content}) oldSink;
    c = controller(chat: (messages, {tools, conversationHash, turn, round}) {
      if (++calls == 1) {
        oldSink = c.captureStreamSinkForTesting();
        oldSink(content: '旧正文');
        entered.complete();
        return old.future;
      }
      return next.future;
    });
    final previous = send(c, '旧问题');
    await entered.future;
    c.clear();
    final current = send(c, '新问题');
    oldSink(content: '迟到旧正文');
    old.complete(LlmResponse(toolCalls: [_list('old')]));
    await previous;
    expect(c.isLoading, isTrue);
    expect(c.streamingMessage, isNull);
    expect(lists(c), isEmpty);
    expect(c.historyForTesting().where((m) => m.role == 'user').single.content,
        contains('新问题'));
    next.complete(const LlmResponse());
    await current;
    expect(fallbacks(c), hasLength(1));
    expect(c.displayMessages.any((m) => m.text.contains('旧')), isFalse);
    paired(c);
  });

  test('A13 delayed tool execution after clear never appends to the new turn',
      () async {
    final entered = Completer<void>(), toolResult = Completer<AiToolResult>();
    AiCapabilities.registry.register(_FixtureTool('plan49_delayed', (_) {
      entered.complete();
      return toolResult.future;
    }));
    var calls = 0;
    final c = controller(
        chat: (messages, {tools, conversationHash, turn, round}) async {
      if (++calls == 1) {
        return const LlmResponse(toolCalls: [
          LlmToolCall(id: 'old', name: 'plan49_delayed', arguments: {})
        ]);
      }
      return const LlmResponse();
    });
    final old = send(c);
    await entered.future;
    c.clear();
    await send(c, '新问题');
    toolResult.complete(const AiToolResult.success(null, '旧操作已完成'));
    await old;
    expect(
        c.displayMessages.where((m) => m.type == AiChatMessageType.toolResult),
        isEmpty);
    expect(fallbacks(c), hasLength(1));
    paired(c);
  });

  test('A14 list then download confirmation keeps turn output and pairs once',
      () async {
    final downloaded = Completer<AiToolResult>();
    var executions = 0, calls = 0;
    AiCapabilities.registry.register(_FixtureTool('download_comic', (_) {
      executions++;
      return downloaded.future;
    }));
    final c = controller(
        chat: (messages, {tools, conversationHash, turn, round}) async {
      if (++calls == 1) {
        return LlmResponse(toolCalls: [_list('list'), _download]);
      }
      expect(messages.where((m) => m.role == 'tool'), hasLength(2));
      return const LlmResponse();
    });
    await send(c);
    expect(lists(c), hasLength(1));
    expect(c.pendingDownload, isNotNull);
    final confirm = c.confirmDownload(true);
    await c.confirmDownload(true); // Duplicate click while dispatch is pending.
    expect(executions, 1);
    downloaded.complete(const AiToolResult.success({'taskId': 'fixture'}));
    await confirm;
    expect(c.pendingDownload, isNull);
    expect(c.isLoading, isFalse);
    expect(lists(c), hasLength(1));
    expect(fallbacks(c), isEmpty);
    paired(c);
  });

  test('A14 old download confirmation cannot finish or append into new turn',
      () async {
    final downloaded = Completer<AiToolResult>();
    AiCapabilities.registry
        .register(_FixtureTool('download_comic', (_) => downloaded.future));
    var calls = 0;
    final c = controller(
        chat: (messages, {tools, conversationHash, turn, round}) async {
      if (++calls == 1) return const LlmResponse(toolCalls: [_download]);
      return const LlmResponse();
    });
    await send(c);
    final confirm = c.confirmDownload(true);
    c.clear();
    await send(c, '新问题');
    downloaded.complete(const AiToolResult.success(null, '旧任务已入队'));
    await confirm;
    expect(
        c.displayMessages.where((m) => m.type == AiChatMessageType.toolResult),
        isEmpty);
    expect(fallbacks(c), hasLength(1));
    paired(c);
  });

  test('A15 image-search whitelist produces immediate independent cards',
      () async {
    appdata.settings[aiCapabilitySearchByImageSettingIndex] = '1';
    AiCapabilities.registry.register(_FixtureTool(
        'search_by_image',
        (_) => const AiToolResult.success({
              'items': [_item]
            })));
    final c = controller();
    await c.simulateToolCallRoundForTesting([
      const LlmToolCall(id: 'image', name: 'search_by_image', arguments: {})
    ], continueWithLlm: false);
    expect(lists(c), hasLength(1));
    await c.simulateToolCallRoundForTesting([_list('manual')],
        continueWithLlm: false);
    expect(lists(c), hasLength(2));
    c.simulateFinalTextResponseForTesting('');
    expect(fallbacks(c), isEmpty);
    paired(c);
  });
}
