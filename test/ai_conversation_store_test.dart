import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_attachments.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_conversation_store.dart';
import 'package:picakeep/foundation/ai/ai_result_item.dart';
import 'package:picakeep/foundation/app.dart';

/// 34号计划：AiConversationStore.renameConversation() 单元测试。
void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('ai_conversation_store_test');
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
    final beforeUpdatedAt = beforeIndex.firstWhere((m) => m.id == id).updatedAt;

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

  test('旧会话中的非规范 resultList toolData 序列化往返后仍可安全读取', () {
    final rawItems = List<Map<String, dynamic>>.generate(
      12,
      (index) => {
        'id': '$index',
        'title': '脱敏标题 $index',
        'source': index < 2 ? 'ehentai' : 'nhentai',
        'availability': '7页，汉化',
      },
    );
    final stored = AiConversationStore.serializeConversationForTesting(
      id: 'legacy-result-list',
      title: '旧会话',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026, 1, 2),
      displayMessages: [
        AiChatMessage(
          type: AiChatMessageType.resultList,
          text: '共 12 条结果',
          toolData: {'items': rawItems},
        ),
      ],
      history: const [],
    );

    final restored = AiConversationController.restoreForTesting(stored);
    final report =
        AiResultItem.decodeToolData(restored.displayMessages.single.toolData);
    expect(report.items, hasLength(12));
    expect(report.items.first.availability['summary'], '7页，汉化');
    expect(restored.displayMessages.single.text, '共 12 条结果');
  });

  // ── 15轮03号计划：附件子目录随会话删除/清理同步移除 ─────────────────────

  Directory attachmentsDirOf(String id) => Directory(
      '${aiAttachmentsRoot()}${Platform.pathSeparator}$id');

  test('delete() 同步删除该会话的附件子目录', () async {
    final id = await createConversation();
    final attachmentsDir = attachmentsDirOf(id);
    attachmentsDir.createSync(recursive: true);
    File('${attachmentsDir.path}${Platform.pathSeparator}x.jpg')
        .writeAsBytesSync(const [1, 2, 3]);

    await AiConversationStore.delete(id);

    expect(await AiConversationStore.loadConversation(id), isNull);
    expect(attachmentsDir.existsSync(), isFalse);
  });

  test('delete() 对没有附件目录的会话仍是安全操作', () async {
    final id = await createConversation();
    expect(attachmentsDirOf(id).existsSync(), isFalse);
    await AiConversationStore.delete(id);
    expect(await AiConversationStore.loadConversation(id), isNull);
  });

  test('清理超量会话（prune）时同步删除被清理会话的附件子目录', () async {
    // victim：createdAt 最老（2000 年），携带附件目录。
    const victimId = 'prune-victim';
    await AiConversationStore.save(
      id: victimId,
      title: 'victim',
      createdAt: DateTime.utc(2000),
      displayMessages: const [],
      history: const [],
    );
    final victimAttachments = attachmentsDirOf(victimId);
    victimAttachments.createSync(recursive: true);
    File('${victimAttachments.path}${Platform.pathSeparator}x.jpg')
        .writeAsBytesSync(const [1, 2, 3]);

    // 填充到 51 个会话：save() 内部的 _pruneIfNeeded 会删掉 createdAt 最老的
    // victim，并应同步删除其附件子目录。
    final baseCount = (await AiConversationStore.loadIndex()).length;
    final toCreate = 51 - baseCount;
    expect(toCreate, greaterThan(0),
        reason: '前置条件：当前会话数应少于 51，测试文件内先前用例不应创建这么多会话');
    for (var i = 0; i < toCreate; i++) {
      await AiConversationStore.save(
        id: 'prune-filler-$i',
        title: 'filler',
        createdAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
        displayMessages: const [],
        history: const [],
      );
    }

    expect(await AiConversationStore.loadConversation(victimId), isNull);
    expect(victimAttachments.existsSync(), isFalse);
    expect((await AiConversationStore.loadIndex()).length, 50);
  });
}
