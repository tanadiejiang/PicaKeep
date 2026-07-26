import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_conversation_store.dart';
import 'package:picakeep/foundation/ai/llm_client.dart';
import 'package:picakeep/foundation/app.dart';

/// 15轮03号计划步骤 19：附件字段（AiChatMessage.attachmentPaths /
/// LlmMessage.imagePaths）的序列化往返与旧存档兼容。
void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir =
        Directory.systemTemp.createTempSync('ai_attachment_serialization_');
    App.dataPath = tempDir.path;
  });

  tearDownAll(() {
    tempDir.deleteSync(recursive: true);
  });

  test('AiChatMessage toJson/fromJson 带 attachmentPaths 往返一致', () {
    final msg = AiChatMessage.user(
      '看图',
      attachmentPaths: const ['conv/a.jpg', 'conv/b.png'],
    );
    final json = msg.toJson();
    expect(json['attachmentPaths'], ['conv/a.jpg', 'conv/b.png']);
    final restored = AiChatMessage.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
    );
    expect(restored.attachmentPaths, ['conv/a.jpg', 'conv/b.png']);
    expect(restored.text, '看图');
    expect(restored.type, AiChatMessageType.user);
  });

  test('旧 JSON（无 attachmentPaths 键）→ 空列表不抛异常', () {
    final restored = AiChatMessage.fromJson({
      'type': 'user',
      'text': '旧消息',
      'createdAt': '2026-01-01T00:00:00.000Z',
    });
    expect(restored.attachmentPaths, isEmpty);
    expect(restored.text, '旧消息');
  });

  test('无附件消息 toJson 不写 attachmentPaths 键（与改造前输出逐键相同）', () {
    final json = AiChatMessage.user('纯文本').toJson();
    expect(json.containsKey('attachmentPaths'), isFalse);
  });

  test('LlmMessage toJson/fromJson 带 imagePaths 往返一致；旧 JSON → 空列表', () {
    final msg = LlmMessage.user('hello', imagePaths: const ['conv/a.jpg']);
    final json = msg.toJson();
    expect(json['imagePaths'], ['conv/a.jpg']);
    final restored = LlmMessage.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
    );
    expect(restored.imagePaths, ['conv/a.jpg']);
    expect(restored.content, 'hello');
    expect(restored.role, 'user');

    final legacy = LlmMessage.fromJson({'role': 'user', 'content': '旧'});
    expect(legacy.imagePaths, isEmpty);
  });

  test('无图 LlmMessage toJson 不写 imagePaths 键（与改造前输出逐键相同）', () {
    final json = LlmMessage.user('纯文本').toJson();
    expect(json.containsKey('imagePaths'), isFalse);
    expect(json, {'role': 'user', 'content': '纯文本'});
  });

  test('serializeConversationForTesting 产物含新字段，save→load 一轮字段不丢',
      () async {
    final displayMessages = [
      AiChatMessage.user('看图', attachmentPaths: const ['conv-s/a.jpg']),
    ];
    final history = [
      LlmMessage.user('看图', imagePaths: const ['conv-s/a.jpg']),
    ];
    final json = AiConversationStore.serializeConversationForTesting(
      id: 'conv-s',
      title: 't',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026, 1, 2),
      displayMessages: displayMessages,
      history: history,
    );
    final dm = (json['displayMessages'] as List).first as Map<String, dynamic>;
    expect(dm['attachmentPaths'], ['conv-s/a.jpg']);
    final hm = (json['history'] as List).first as Map<String, dynamic>;
    expect(hm['imagePaths'], ['conv-s/a.jpg']);

    await AiConversationStore.save(
      id: 'conv-s',
      title: 't',
      createdAt: DateTime.utc(2026),
      displayMessages: displayMessages,
      history: history,
    );
    final loaded = await AiConversationStore.loadConversation('conv-s');
    expect(loaded, isNotNull);
    final loadedDm =
        (loaded!['displayMessages'] as List).first as Map<String, dynamic>;
    expect(loadedDm['attachmentPaths'], ['conv-s/a.jpg']);
    final loadedHm =
        (loaded['history'] as List).first as Map<String, dynamic>;
    expect(loadedHm['imagePaths'], ['conv-s/a.jpg']);

    // 反序列化回内存对象后字段仍在（restore 会重建 system prompt，
    // 用户消息位于 history 末尾）。
    final restored = AiConversationController.restoreForTesting(loaded);
    expect(restored.displayMessages.single.attachmentPaths, ['conv-s/a.jpg']);
    expect(restored.historyForTesting().last.imagePaths, ['conv-s/a.jpg']);
  });
}
