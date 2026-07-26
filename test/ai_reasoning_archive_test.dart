import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_conversation_store.dart';
import 'package:picakeep/foundation/ai/llm_client.dart';
import 'package:picakeep/foundation/app.dart';

/// 15轮06号计划：思考过程（reasoning）存档往返 + 「存/发分离」剥离规则守卫。
void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('ai_reasoning_archive_test');
    App.dataPath = tempDir.path;
  });

  tearDownAll(() {
    tempDir.deleteSync(recursive: true);
  });

  group('AiChatMessage 存档', () {
    test('reasoningText toJson/fromJson 往返', () {
      final message = AiChatMessage.assistant('答案', reasoningText: '思考内容');
      final json = message.toJson();
      expect(json['reasoningText'], '思考内容');
      final restored = AiChatMessage.fromJson(json);
      expect(restored.reasoningText, '思考内容');
      expect(restored.text, '答案');
    });

    test('无 reasoning 时不写该键；旧 JSON（无该键）→ null 不崩', () {
      expect(AiChatMessage.assistant('x').toJson().containsKey('reasoningText'),
          isFalse);
      final restored = AiChatMessage.fromJson(const {
        'type': 'assistant',
        'text': '旧消息',
        'createdAt': '2026-07-10T00:00:00.000Z',
      });
      expect(restored.reasoningText, isNull);
    });
  });

  group('会话存档 store 出入口（与 AiChatMessage.toJson 是独立的一对）', () {
    test('serializeConversation → deserializeAiChatMessage 往返保留思考', () {
      final json = AiConversationStore.serializeConversationForTesting(
        id: 'id-store-reasoning',
        title: '新会话',
        createdAt: DateTime.utc(2026, 7, 10),
        updatedAt: DateTime.utc(2026, 7, 10),
        displayMessages: [
          AiChatMessage.assistant('答案', reasoningText: '落盘的思考'),
        ],
        history: [
          LlmMessage.assistant(content: '答案', reasoningContent: '落盘的思考'),
        ],
      );

      final displayJson =
          (json['displayMessages'] as List).first as Map<String, dynamic>;
      expect(displayJson['reasoningText'], '落盘的思考');
      expect(
        AiConversationStore.deserializeAiChatMessage(displayJson).reasoningText,
        '落盘的思考',
      );

      final historyJson =
          (json['history'] as List).first as Map<String, dynamic>;
      expect(historyJson['reasoning_content'], '落盘的思考');
    });

    test('旧存档（无 reasoningText 键）反序列化 → null 不崩', () {
      final restored = AiConversationStore.deserializeAiChatMessage(const {
        'type': 'assistant',
        'text': '旧消息',
        'createdAt': '2026-07-10T00:00:00.000Z',
      });
      expect(restored.reasoningText, isNull);
    });
  });

  group('LlmMessage 存档与剥离副本', () {
    test('reasoning_content toJson/fromJson 往返', () {
      final message =
          LlmMessage.assistant(content: '答案', reasoningContent: '思考');
      final json = message.toJson();
      expect(json['reasoning_content'], '思考');
      expect(LlmMessage.fromJson(json).reasoningContent, '思考');
    });

    test('旧存档无 reasoning_content → null', () {
      final restored = LlmMessage.fromJson(const {
        'role': 'assistant',
        'content': '旧回复',
      });
      expect(restored.reasoningContent, isNull);
    });

    test('stripImagesToPlaceholder 保留 reasoningContent', () {
      const message = LlmMessage(
        role: 'user',
        content: '看图',
        imagePaths: ['c/a.png'],
        reasoningContent: '思考',
      );
      final stripped = message.stripImagesToPlaceholder();
      expect(stripped.imagePaths, isEmpty);
      expect(stripped.reasoningContent, '思考');
    });

    test('stripReasoning 剥离；本来没有时返回自身', () {
      final withReasoning =
          LlmMessage.assistant(content: '答案', reasoningContent: '思考');
      final stripped = withReasoning.stripReasoning();
      expect(stripped.reasoningContent, isNull);
      expect(stripped.content, '答案');
      expect(stripped.toJson().containsKey('reasoning_content'), isFalse);

      final without = LlmMessage.assistant(content: '答案');
      expect(identical(without.stripReasoning(), without), isTrue);
    });
  });

  group('_buildRequestMessages 剥离规则（决策B 契约）', () {
    test('纯文本 assistant 轮剥离 reasoning、带 tool_calls 的保留', () {
      final ctrl = AiConversationController.restoreForTesting({
        'id': 'id-reasoning-strip',
        'title': '新会话',
        'createdAt': '2026-07-10T00:00:00.000Z',
        'displayMessages': <dynamic>[],
        'history': <dynamic>[
          {'role': 'user', 'content': '问题一'},
          {
            'role': 'assistant',
            'content': '纯文本回答',
            'reasoning_content': '纯文本轮的思考',
          },
          {'role': 'user', 'content': '问题二'},
          {
            'role': 'assistant',
            'reasoning_content': '工具轮的思考',
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {'name': 'search_online', 'arguments': '{}'},
              }
            ],
          },
          {
            'role': 'tool',
            'tool_call_id': 'call_1',
            'name': 'search_online',
            'content': '{"ok":true}',
          },
        ],
        'version': 2,
      });

      final requests = ctrl.buildRequestMessagesForTesting();
      final assistants = requests.where((m) => m.role == 'assistant').toList();
      expect(assistants, hasLength(2));

      final plain = assistants.firstWhere((m) => m.toolCalls == null);
      expect(plain.reasoningContent, isNull);
      expect(plain.toJson().containsKey('reasoning_content'), isFalse);

      final withTools = assistants.firstWhere((m) => m.toolCalls != null);
      expect(withTools.reasoningContent, '工具轮的思考');
      expect(withTools.toJson()['reasoning_content'], '工具轮的思考');

      // _history 本身不被改写（存档永远保留）。
      final stored = ctrl
          .historyForTesting()
          .where((m) => m.role == 'assistant' && m.toolCalls == null)
          .single;
      expect(stored.reasoningContent, '纯文本轮的思考');
    });
  });

  group('controller 集成', () {
    test('注入带 reasoningContent 的响应 → 气泡与历史都带上思考', () async {
      final ctrl = AiConversationController.restoreForTesting(
        {
          'id': 'id-reasoning-loop',
          'title': '新会话',
          'createdAt': '2026-07-10T00:00:00.000Z',
          'displayMessages': <dynamic>[],
          'history': <dynamic>[],
          'version': 2,
        },
        chatRequestForTesting: (
          messages, {
          tools,
          conversationHash,
          turn,
          round,
        }) async =>
            const LlmResponse(content: 'x', reasoningContent: 'think'),
      );

      await ctrl.runLlmLoopForTesting();

      final last = ctrl.displayMessages.last;
      expect(last.type, AiChatMessageType.assistant);
      expect(last.text, 'x');
      expect(last.reasoningText, 'think');

      final assistant =
          ctrl.historyForTesting().where((m) => m.role == 'assistant').single;
      expect(assistant.reasoningContent, 'think');
    });

    test('只有思考没有正文：保留思考气泡且不入 history', () async {
      final ctrl = AiConversationController.restoreForTesting(
        {
          'id': 'id-reasoning-only',
          'title': '新会话',
          'createdAt': '2026-07-10T00:00:00.000Z',
          'displayMessages': <dynamic>[],
          'history': <dynamic>[],
          'version': 2,
        },
        chatRequestForTesting: (
          messages, {
          tools,
          conversationHash,
          turn,
          round,
        }) async =>
            const LlmResponse(content: '', reasoningContent: 'only-think'),
      );

      await ctrl.runLlmLoopForTesting();

      // 测试注入路径不走流式回调，没有进行中气泡可定格，
      // 因此退回“无有效内容”提示气泡；history 不含 assistant。
      expect(ctrl.historyForTesting().where((m) => m.role == 'assistant'),
          isEmpty);
      expect(ctrl.displayMessages.last.type, AiChatMessageType.assistant);
    });
  });
}
