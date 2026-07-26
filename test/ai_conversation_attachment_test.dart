import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_prompt_tags.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/foundation/ai/llm_client.dart';
import 'package:picakeep/foundation/ai/ocr_client.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/pages/ai/ai_chat_page.dart';

/// 15轮03号计划步骤 19：AiConversationController.send() 的附件链路——
/// 视觉直发 / OCR 兜底 / 失败无副作用返回 false / 历史瘦身（决策B）。
void main() {
  setUpAll(() {
    final root =
        Directory.systemTemp.createTempSync('ai_conversation_attachment_');
    App.dataPath = root.path;
    addTearDown(() => root.deleteSync(recursive: true));
  });

  tearDown(() {
    appdata.settings[aiOcrConfigSettingIndex] = '{}';
    appdata.settings[aiModelSupportsVisionSettingIndex] = '0';
  });

  AiConversationController makeController({
    required String id,
    required bool vision,
    List<List<LlmMessage>>? captured,
    AiOcrRequest? ocrRequest,
  }) {
    appdata.settings[aiModelSupportsVisionSettingIndex] = vision ? '1' : '0';
    return AiConversationController.restoreForTesting(
      {
        'id': id,
        'title': 'title',
        'createdAt': '2026-07-26T00:00:00.000Z',
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
      }) async {
        captured?.add(List<LlmMessage>.of(messages));
        return const LlmResponse(content: 'ok');
      },
      ocrRequestForTesting: ocrRequest,
    );
  }

  String usableGenericOcrConfig() => jsonEncode({
        'enabled': true,
        'type': 'generic',
        'baseUrl': 'http://127.0.0.1:1224/api/ocr',
        'imageField': 'base64',
        'resultPath': 'data',
      });

  test('视觉开：图片进 LlmMessage.imagePaths，气泡带 attachmentPaths，返回 true',
      () async {
    final captured = <List<LlmMessage>>[];
    final ctrl = makeController(
      id: 'attach-vision-on',
      vision: true,
      captured: captured,
    );

    final sent = await ctrl.send(
      '看图',
      availablePromptTags: const <AiPromptTag>[],
      persistSelections: false,
      attachmentPaths: const ['attach-vision-on/x.jpg'],
    );

    expect(sent, isTrue);
    final userMessage =
        captured.single.singleWhere((message) => message.role == 'user');
    expect(userMessage.imagePaths, ['attach-vision-on/x.jpg']);
    final userBubble = ctrl.displayMessages
        .lastWhere((message) => message.type == AiChatMessageType.user);
    expect(userBubble.attachmentPaths, ['attach-vision-on/x.jpg']);
  });

  test('空文本+仅图片：桥接语正常入列；控制器级空字符串不再早退', () async {
    final captured = <List<LlmMessage>>[];
    final ctrl = makeController(
      id: 'attach-image-only',
      vision: true,
      captured: captured,
    );

    final sentWithBridge = await ctrl.send(
      aiImageOnlyUserBridge,
      availablePromptTags: const <AiPromptTag>[],
      persistSelections: false,
      attachmentPaths: const ['attach-image-only/x.jpg'],
    );
    expect(sentWithBridge, isTrue);
    expect(
      ctrl.displayMessages
          .where((message) => message.type == AiChatMessageType.user)
          .last
          .text,
      aiImageOnlyUserBridge,
    );

    // 守卫放宽生效：空文本 + 有附件不再早退。
    final sentEmptyText = await ctrl.send(
      '',
      availablePromptTags: const <AiPromptTag>[],
      persistSelections: false,
      attachmentPaths: const ['attach-image-only/y.jpg'],
    );
    expect(sentEmptyText, isTrue);
    expect(captured, hasLength(2));

    // 对照：空文本 + 无附件仍然早退。
    final sentNothing = await ctrl.send(
      '',
      availablePromptTags: const <AiPromptTag>[],
      persistSelections: false,
    );
    expect(sentNothing, isFalse);
    expect(captured, hasLength(2));
  });

  test('瘦身（决策B）：仅最后一条带图 user 保留 imagePaths，更早的降级为稳定占位', () async {
    final ctrl = makeController(id: 'attach-strip', vision: true);

    await ctrl.send(
      '第一张',
      availablePromptTags: const <AiPromptTag>[],
      persistSelections: false,
      attachmentPaths: const ['attach-strip/a.jpg'],
    );
    await ctrl.send(
      '第二张',
      availablePromptTags: const <AiPromptTag>[],
      persistSelections: false,
      attachmentPaths: const ['attach-strip/b.jpg'],
    );

    final request = ctrl.buildRequestMessagesForTesting();
    final imageUsers = request
        .where(
          (message) =>
              message.role == 'user' && message.imagePaths.isNotEmpty,
        )
        .toList();
    expect(imageUsers, hasLength(1));
    expect(imageUsers.single.imagePaths, ['attach-strip/b.jpg']);

    final strippedUser = request.firstWhere(
      (message) =>
          message.role == 'user' && (message.content ?? '').contains('第一张'),
    );
    expect(strippedUser.imagePaths, isEmpty);
    expect(
      strippedUser.content,
      endsWith(LlmMessage.imagePlaceholder(1)),
    );

    // _history 本身不被改写：存档仍保留全部 imagePaths。
    final historyImageUsers = ctrl
        .historyForTesting()
        .where(
          (message) =>
              message.role == 'user' && message.imagePaths.isNotEmpty,
        )
        .toList();
    expect(historyImageUsers, hasLength(2));
  });

  test('视觉关+OCR 钩子成功：user_query 合并识别文字，imagePaths 为空', () async {
    appdata.settings[aiOcrConfigSettingIndex] = usableGenericOcrConfig();
    final captured = <List<LlmMessage>>[];
    final ocrCalls = <String>[];
    final ctrl = makeController(
      id: 'attach-ocr-ok',
      vision: false,
      captured: captured,
      ocrRequest: (absolutePath) async {
        ocrCalls.add(absolutePath);
        return const OcrResponse(text: '这是图中文字');
      },
    );

    final sent = await ctrl.send(
      '看图',
      availablePromptTags: const <AiPromptTag>[],
      persistSelections: false,
      attachmentPaths: const ['attach-ocr-ok/x.jpg'],
    );

    expect(sent, isTrue);
    expect(ocrCalls, hasLength(1));
    final userMessage =
        captured.single.singleWhere((message) => message.role == 'user');
    // OCR 路径模型只看到文字（决策C）：imagePaths 为空。
    expect(userMessage.imagePaths, isEmpty);
    final payload =
        jsonDecode(userMessage.content!) as Map<String, dynamic>;
    final userQuery = payload['user_query'] as String;
    expect(userQuery, contains('[图片1 文字内容]'));
    expect(userQuery, contains('这是图中文字'));
    // 气泡仍显示附件缩略图。
    expect(
      ctrl.displayMessages
          .lastWhere((message) => message.type == AiChatMessageType.user)
          .attachmentPaths,
      ['attach-ocr-ok/x.jpg'],
    );
  });

  test('视觉关+OCR 钩子失败：send 返回 false、error 气泡、history 无副作用', () async {
    appdata.settings[aiOcrConfigSettingIndex] = usableGenericOcrConfig();
    final captured = <List<LlmMessage>>[];
    final ctrl = makeController(
      id: 'attach-ocr-fail',
      vision: false,
      captured: captured,
      ocrRequest: (absolutePath) async =>
          const OcrResponse(error: '服务不可达'),
    );
    final historyLengthBefore = ctrl.historyForTesting().length;

    final sent = await ctrl.send(
      '看图',
      availablePromptTags: const <AiPromptTag>[],
      persistSelections: false,
      attachmentPaths: const ['attach-ocr-fail/x.jpg'],
    );

    expect(sent, isFalse);
    expect(ctrl.displayMessages.last.type, AiChatMessageType.error);
    expect(ctrl.displayMessages.last.text, contains('识别失败'));
    expect(ctrl.historyForTesting().length, historyLengthBefore);
    expect(captured, isEmpty);
    expect(ctrl.isLoading, isFalse);
  });

  test('视觉关+OCR 未配置：send 返回 false，错误文案含「未启用或未配置」', () async {
    appdata.settings[aiOcrConfigSettingIndex] = '{}';
    final captured = <List<LlmMessage>>[];
    final ctrl = makeController(
      id: 'attach-ocr-unset',
      vision: false,
      captured: captured,
      ocrRequest: (absolutePath) async =>
          fail('OCR 未配置时不应发起 OCR 请求'),
    );
    final historyLengthBefore = ctrl.historyForTesting().length;

    final sent = await ctrl.send(
      '看图',
      availablePromptTags: const <AiPromptTag>[],
      persistSelections: false,
      attachmentPaths: const ['attach-ocr-unset/x.jpg'],
    );

    expect(sent, isFalse);
    expect(ctrl.displayMessages.last.type, AiChatMessageType.error);
    expect(ctrl.displayMessages.last.text, contains('未启用或未配置'));
    expect(ctrl.historyForTesting().length, historyLengthBefore);
    expect(captured, isEmpty);
  });

  test('选图上限（验收标准 11 自动化部分）：合并去重、最多 4 张，超限返回 overflow', () {
    final pending = <String>['a.png', 'b.png'];
    // 'b.png' 重复被去重，'c'/'d' 正常并入，恰好到 4 张不算溢出。
    final overflowAtFour = mergePendingAiAttachmentSelection(
      pending,
      ['b.png', 'c.png', 'd.png'],
    );
    expect(overflowAtFour, isFalse);
    expect(pending, ['a.png', 'b.png', 'c.png', 'd.png']);

    // 已满 4 张再选 → 溢出，列表保持 4 张。
    final overflowBeyond =
        mergePendingAiAttachmentSelection(pending, ['e.png']);
    expect(overflowBeyond, isTrue);
    expect(pending, hasLength(4));

    // 一次多选超过 4 张 → 前 4 张保留，其余丢弃并报溢出。
    final fresh = <String>[];
    final overflowBatch = mergePendingAiAttachmentSelection(
      fresh,
      ['1', '2', '3', '4', '5', '6'],
    );
    expect(overflowBatch, isTrue);
    expect(fresh, ['1', '2', '3', '4']);
  });

  // ---------------------------------------------------------------------------
  // 15轮05号计划步骤 18-b/18-c：turn_context 注入与自动展示白名单。
  // ---------------------------------------------------------------------------

  Map<String, dynamic> turnContextOf(List<LlmMessage> messages) {
    final userMessage = messages.lastWhere((message) => message.role == 'user');
    final payload = jsonDecode(userMessage.content!) as Map<String, dynamic>;
    return payload['turn_context'] as Map<String, dynamic>;
  }

  test('手输 #搜图 + 附件：turn_context 含 search_by_image=true 与 attachments ref',
      () async {
    final captured = <List<LlmMessage>>[];
    final ctrl = makeController(
      id: 'sbi-tag-text',
      vision: true,
      captured: captured,
    );

    final sent = await ctrl.send(
      '#搜图 帮我搜',
      availablePromptTags: const <AiPromptTag>[],
      persistSelections: false,
      attachmentPaths: const ['sbi-tag-text/img1.jpg'],
    );

    expect(sent, isTrue);
    final context = turnContextOf(captured.single);
    expect(context['search_by_image'], isTrue);
    expect(context['attachments'], [
      {'ref': 'sbi-tag-text/img1.jpg'},
    ]);
  });

  test('面板 chip 结构化路径：send(searchByImage: true) 同样置位', () async {
    final captured = <List<LlmMessage>>[];
    final ctrl = makeController(
      id: 'sbi-chip',
      vision: true,
      captured: captured,
    );

    final sent = await ctrl.send(
      '帮我搜',
      availablePromptTags: const <AiPromptTag>[],
      persistSelections: false,
      searchByImage: true,
      attachmentPaths: const ['sbi-chip/img1.jpg'],
    );

    expect(sent, isTrue);
    expect(turnContextOf(captured.single)['search_by_image'], isTrue);
  });

  test('无附件+无标签：search_by_image=false、attachments 为空列表（两键恒存在）',
      () async {
    final captured = <List<LlmMessage>>[];
    final ctrl = makeController(
      id: 'sbi-none',
      vision: true,
      captured: captured,
    );

    final sent = await ctrl.send(
      '普通消息',
      availablePromptTags: const <AiPromptTag>[],
      persistSelections: false,
    );

    expect(sent, isTrue);
    final context = turnContextOf(captured.single);
    expect(context.containsKey('search_by_image'), isTrue);
    expect(context['search_by_image'], isFalse);
    expect(context['attachments'], isEmpty);
  });

  test('#搜图 不进长期持久化：下一轮 turn_context 回落 false', () async {
    final captured = <List<LlmMessage>>[];
    final ctrl = makeController(
      id: 'sbi-not-sticky',
      vision: true,
      captured: captured,
    );

    await ctrl.send(
      '#搜图 帮我搜',
      availablePromptTags: const <AiPromptTag>[],
      persistSelections: true, // 即使长期开关开着也不粘
      attachmentPaths: const ['sbi-not-sticky/img1.jpg'],
    );
    await ctrl.send(
      '第二轮普通消息',
      availablePromptTags: const <AiPromptTag>[],
      persistSelections: true,
    );

    expect(captured, hasLength(2));
    expect(turnContextOf(captured.last)['search_by_image'], isFalse);
  });

  test('自动展示白名单纯函数（步骤 18-c）', () {
    expect(shouldAutoDisplayToolResult('search_by_image', true), isTrue);
    expect(shouldAutoDisplayToolResult('search_by_image', false), isFalse);
    expect(shouldAutoDisplayToolResult('display_result_list', true), isTrue);
    expect(shouldAutoDisplayToolResult('search_online', true), isFalse);
    expect(
      autoDisplayResultToolNames,
      containsAll(<String>{'display_result_list', 'search_by_image'}),
    );
  });

  test('#搜本地 范围下 search_by_image 被 scope 过滤（步骤 7-g）', () {
    expect(
      isToolAllowedByScope(
        'search_by_image',
        effectiveLocalOnly: true,
        effectiveOnlineOnly: false,
      ),
      isFalse,
    );
    expect(
      isToolAllowedByScope(
        'search_by_image',
        effectiveLocalOnly: false,
        effectiveOnlineOnly: false,
      ),
      isTrue,
    );
    // 仅在线范围不拦以图搜源（它本来就是在线工具）。
    expect(
      isToolAllowedByScope(
        'search_by_image',
        effectiveLocalOnly: false,
        effectiveOnlineOnly: true,
      ),
      isTrue,
    );
    final blocked = disallowedScopeResult('search_by_image', true, false);
    expect(blocked, isNotNull);
    expect(blocked!.ok, isFalse);
    expect(blocked.message, contains('仅本地'));
  });
}
