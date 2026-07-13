import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_conversation_store.dart';
import 'package:picakeep/foundation/app.dart';

/// 34号计划：AiConversationStore.renameConversation() 单元测试。
void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir =
        Directory.systemTemp.createTempSync('ai_conversation_store_test');
    App.dataPath = tempDir.path;
  });

  tearDownAll(() {
    tempDir.deleteSync(recursive: true);
  });

  Future<String> createConversation({String title = '原标题'}) async {
    final id = 'conv-${DateTime.now().microsecondsSinceEpoch}';
    await AiConversationStore.save(
      id: id,
      title: title,
      createdAt: DateTime.utc(2026, 1, 1),
      displayMessages: [AiChatMessage.user('第一条消息')],
      history: const [],
    );
    return id;
  }

  test('renameConversation 更新会话文件与索引文件的 title，并标记 titleIsCustom', () async {
    final id = await createConversation();

    await AiConversationStore.renameConversation(id, '新标题');

    final data = await AiConversationStore.loadConversation(id);
    expect(data, isNotNull);
    expect(data!['title'], '新标题');
    expect(data['titleIsCustom'], true);

    final index = await AiConversationStore.loadIndex();
    final meta = index.firstWhere((m) => m.id == id);
    expect(meta.title, '新标题');
  });

  test('renameConversation 前后 trim 空白，且全空白标题时不做任何改动', () async {
    final id = await createConversation();

    await AiConversationStore.renameConversation(id, '  带空格的标题  ');
    final data = await AiConversationStore.loadConversation(id);
    expect(data!['title'], '带空格的标题');

    await AiConversationStore.renameConversation(id, '   ');
    final unchanged = await AiConversationStore.loadConversation(id);
    expect(unchanged!['title'], '带空格的标题');
  });

  test('renameConversation 保持 updatedAt 不变（重命名不算更新对话内容）', () async {
    final id = await createConversation();
    final beforeIndex = await AiConversationStore.loadIndex();
    final beforeUpdatedAt =
        beforeIndex.firstWhere((m) => m.id == id).updatedAt;

    await AiConversationStore.renameConversation(id, '新标题2');

    final afterIndex = await AiConversationStore.loadIndex();
    final afterUpdatedAt = afterIndex.firstWhere((m) => m.id == id).updatedAt;
    expect(afterUpdatedAt, beforeUpdatedAt);
  });

  test('renameConversation 对不存在的会话 id 是安全的空操作', () async {
    await AiConversationStore.renameConversation('not-a-real-id', '新标题');
    final data = await AiConversationStore.loadConversation('not-a-real-id');
    expect(data, isNull);
  });

  test('renameConversation 只改 title/titleIsCustom，不影响 displayMessages/history',
      () async {
    final id = await createConversation();
    final before = await AiConversationStore.loadConversation(id);

    await AiConversationStore.renameConversation(id, '新标题3');

    final after = await AiConversationStore.loadConversation(id);
    expect(after!['displayMessages'], before!['displayMessages']);
    expect(after['history'], before['history']);
    expect(after['createdAt'], before['createdAt']);
  });

  test('save() 传入 titleIsCustom:true 时会话文件写入该标志', () async {
    final id = 'conv-custom-${DateTime.now().microsecondsSinceEpoch}';
    await AiConversationStore.save(
      id: id,
      title: '自定义标题',
      createdAt: DateTime.utc(2026, 1, 1),
      displayMessages: const [],
      history: const [],
      titleIsCustom: true,
    );
    final data = await AiConversationStore.loadConversation(id);
    expect(data!['titleIsCustom'], true);
  });

  test('serializeConversationForTesting 默认 titleIsCustom 为 false 时不写入该键', () {
    final json = AiConversationStore.serializeConversationForTesting(
      id: 'id',
      title: 'title',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026, 1, 2),
      displayMessages: const [],
      history: const [],
    );
    expect(json.containsKey('titleIsCustom'), isFalse);
  });

  test('renameConversation 原地修改 loadConversation 返回的 Map 后写回是安全的', () async {
    final id = await createConversation();
    await AiConversationStore.renameConversation(id, '安全性验证标题');
    final dir = '${tempDir.path}${Platform.pathSeparator}ai_conversations';
    final file = File('$dir${Platform.pathSeparator}$id.json');
    final onDisk = jsonDecode(await file.readAsString()) as Map;
    expect(onDisk['title'], '安全性验证标题');
    expect(onDisk['titleIsCustom'], true);
  });
}
