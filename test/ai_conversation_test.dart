import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_conversation_store.dart';
import 'package:picakeep/foundation/ai/ai_prompt_tags.dart';
import 'package:picakeep/foundation/ai/llm_client.dart';
import 'package:picakeep/foundation/app.dart';

/// 34号计划：会话侧栏重命名功能——标记为自定义标题后，继续发消息触发
/// `_save()`，标题不会被 `_deriveTitle()` 自动派生逻辑覆盖回"取首条消息
/// 前15字符"的回归测试（本计划最关键的回归验证点）。
void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('ai_conversation_test');
    App.dataPath = tempDir.path;
  });

  tearDownAll(() {
    tempDir.deleteSync(recursive: true);
  });

  test('restoreForTesting 从 titleIsCustom:true 的数据恢复出 _titleIsCustom=true', () {
    final ctrl = AiConversationController.restoreForTesting({
      'id': 'id-custom',
      'title': '自定义标题',
      'createdAt': '2026-07-10T00:00:00.000Z',
      'displayMessages': <dynamic>[],
      'history': <dynamic>[],
      'version': 2,
      'titleIsCustom': true,
    });
    expect(ctrl.titleIsCustomForTesting, isTrue);
  });

  test('脚本化 LLM 回合会看到 retryable 工具失败并按修正参数重试', () async {
    var callCount = 0;
    var sawRetryableFailure = false;
    final ctrl = AiConversationController.restoreForTesting(
      {
        'id': 'id-scripted-display-list-retry',
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
      }) async {
        callCount++;
        if (callCount == 1) {
          return const LlmResponse(
            toolCalls: [
              LlmToolCall(
                id: 'script-invalid',
                name: 'display_result_list',
                arguments: {
                  'items': [
                    {'id': 'missing-title'},
                  ],
                },
              ),
            ],
          );
        }
        if (callCount == 2) {
          sawRetryableFailure = messages.any(
            (message) =>
                message.role == 'tool' &&
                message.content?.contains('"retryable":true') == true,
          );
          return const LlmResponse(
            toolCalls: [
              LlmToolCall(
                id: 'script-fixed',
                name: 'display_result_list',
                arguments: {
                  'items': [
                    {
                      'id': 'fixed-id',
                      'title': '修正结果',
                      'source': 'nhentai',
                      'availability': '7页，汉化',
                    },
                  ],
                },
              ),
            ],
          );
        }
        return const LlmResponse(content: '清单已展示');
      },
    );

    await ctrl.runLlmLoopForTesting();

    expect(callCount, 3);
    expect(sawRetryableFailure, isTrue);
    expect(
      ctrl.displayMessages
          .where((message) => message.type == AiChatMessageType.resultList),
      hasLength(1),
    );
    expect(
      ctrl.historyForTesting().where((message) => message.role == 'tool'),
      hasLength(2),
    );
  });

  test('restoreForTesting 缺失 titleIsCustom 字段时默认 false（旧数据兼容）', () {
    final ctrl = AiConversationController.restoreForTesting({
      'id': 'id-default',
      'title': '旧标题',
      'createdAt': '2026-07-10T00:00:00.000Z',
      'displayMessages': <dynamic>[],
      'history': <dynamic>[],
      'version': 2,
    });
    expect(ctrl.titleIsCustomForTesting, isFalse);
  });

  test('applyExternalRename 同步内存标题并置位 _titleIsCustom，不重复触发保存', () {
    final ctrl = AiConversationController.restoreForTesting({
      'id': 'id-external',
      'title': '旧标题',
      'createdAt': '2026-07-10T00:00:00.000Z',
      'displayMessages': <dynamic>[],
      'history': <dynamic>[],
      'version': 2,
    });

    var notifyCount = 0;
    ctrl.addListener(() => notifyCount++);
    ctrl.applyExternalRename('重命名后的标题');

    expect(ctrl.titleIsCustomForTesting, isTrue);
    expect(notifyCount, 1);
  });

  test(
      '关键回归：_titleIsCustom=true 时 _save() 不会用 _deriveTitle() 覆盖标题，'
      '=false 时仍按原逻辑派生标题', () async {
    // 场景A：标记为自定义标题后继续"发消息"（模拟 send() 内部会做的
    // displayMessages.add + _save()），标题必须保持自定义值不被覆盖。
    final customCtrl = AiConversationController.restoreForTesting({
      'id': 'id-regression-custom',
      'title': '用户手动重命名的标题',
      'createdAt': '2026-07-10T00:00:00.000Z',
      'displayMessages': <dynamic>[],
      'history': <dynamic>[],
      'version': 2,
      'titleIsCustom': true,
    });
    // 模拟继续对话新增的第一条用户消息——若 _deriveTitle() 被误触发，
    // 标题会变成这条消息的前15字符，而不是保持自定义标题。
    customCtrl.displayMessages
        .add(AiChatMessage.user('这是继续对话新增的用户消息，用于验证标题不会被派生逻辑覆盖'));
    await customCtrl.saveForTesting();

    final customData =
        await AiConversationStore.loadConversation('id-regression-custom');
    expect(customData!['title'], '用户手动重命名的标题');
    expect(customData['titleIsCustom'], true);

    // 场景B（对照组）：未标记自定义标题时，_save() 仍应按原有逻辑用
    // _deriveTitle() 派生标题——确保本次改动没有影响未手动命名会话的既有行为。
    final autoCtrl = AiConversationController.restoreForTesting({
      'id': 'id-regression-auto',
      'title': '新会话',
      'createdAt': '2026-07-10T00:00:00.000Z',
      'displayMessages': <dynamic>[],
      'history': <dynamic>[],
      'version': 2,
    });
    autoCtrl.displayMessages.add(AiChatMessage.user('自动派生标题的第一条用户消息内容很长很长'));
    await autoCtrl.saveForTesting();

    final autoData =
        await AiConversationStore.loadConversation('id-regression-auto');
    expect(autoData!['title'], '自动派生标题的第一条用户消息内容很长很长'.substring(0, 15));
    expect(autoData.containsKey('titleIsCustom'), isFalse);
  });

  test(
      '47号：仅通过 allowedSearchSources 参数选中多个来源（不在正文打字），'
      'promptTagNames 包含这些来源的可读标签名，临时模式下生效', () async {
    final ctrl = AiConversationController.restoreForTesting({
      'id': 'id-scope-source-tags',
      'title': '新会话',
      'createdAt': '2026-07-10T00:00:00.000Z',
      'displayMessages': <dynamic>[],
      'history': <dynamic>[],
      'version': 2,
    });

    await ctrl.send(
      '帮我搜一下',
      availablePromptTags: const [],
      persistSelections: false,
      allowedSearchSources: const {'jm', 'picacg'},
    );

    final userMessage = ctrl.displayMessages.first;
    expect(userMessage.promptTagNames, containsAll(['搜jm', '搜pica']));
  });

  test('47号：localOnly:true 且不在正文打字时，promptTagNames 包含 aiLocalOnlyScopeTagName',
      () async {
    final ctrl = AiConversationController.restoreForTesting({
      'id': 'id-scope-local-only-tag',
      'title': '新会话',
      'createdAt': '2026-07-10T00:00:00.000Z',
      'displayMessages': <dynamic>[],
      'history': <dynamic>[],
      'version': 2,
    });

    await ctrl.send(
      '帮我搜一下',
      availablePromptTags: const [],
      persistSelections: false,
      localOnly: true,
    );

    final userMessage = ctrl.displayMessages.first;
    expect(userMessage.promptTagNames, contains(aiLocalOnlyScopeTagName));
  });

  test(
      '47号：长期模式（persistSelections:true）下来源/本地限定标签同样折入 '
      'promptTagNames，不因长期/临时而有差异', () async {
    final ctrl = AiConversationController.restoreForTesting({
      'id': 'id-scope-persist-tags',
      'title': '新会话',
      'createdAt': '2026-07-10T00:00:00.000Z',
      'displayMessages': <dynamic>[],
      'history': <dynamic>[],
      'version': 2,
    });

    await ctrl.send(
      '帮我搜一下',
      availablePromptTags: const [],
      persistSelections: true,
      allowedSearchSources: const {'jm'},
      localOnly: true,
    );

    final userMessage = ctrl.displayMessages.first;
    expect(userMessage.promptTagNames,
        containsAll(['搜jm', aiLocalOnlyScopeTagName]));
  });

  test(
      '05号：长期生效（来源+本地限定）但本轮未手动选中时，promptTagNames 仍应'
      '回显长期生效的标签（气泡展示与实际生效范围保持一致）', () async {
    final ctrl = AiConversationController.restoreForTesting({
      'id': 'id-scope-persistent-no-turn-override',
      'title': '新会话',
      'createdAt': '2026-07-10T00:00:00.000Z',
      'displayMessages': <dynamic>[],
      'history': <dynamic>[],
      'version': 2,
      'persistentAllowedSearchSources': ['jm'],
      'persistentLocalOnly': true,
    });

    await ctrl.send(
      '帮我搜一下',
      availablePromptTags: const [],
      persistSelections: false,
    );

    final userMessage = ctrl.displayMessages.first;
    expect(userMessage.promptTagNames,
        containsAll(['搜jm', aiLocalOnlyScopeTagName]));
  });

  test(
      '05号：长期生效来源为 jm，但本轮手动选中不同来源 eh 时，气泡应按本轮'
      '实际生效范围展示 搜eh，不应同时展示矛盾的 搜jm', () async {
    final ctrl = AiConversationController.restoreForTesting({
      'id': 'id-scope-persistent-turn-override',
      'title': '新会话',
      'createdAt': '2026-07-10T00:00:00.000Z',
      'displayMessages': <dynamic>[],
      'history': <dynamic>[],
      'version': 2,
      'persistentAllowedSearchSources': ['jm'],
    });

    await ctrl.send(
      '帮我搜一下',
      availablePromptTags: const [],
      persistSelections: false,
      allowedSearchSources: const {'ehentai'},
    );

    final userMessage = ctrl.displayMessages.first;
    expect(userMessage.promptTagNames, contains('搜eh'));
    expect(userMessage.promptTagNames, isNot(contains('搜jm')));
  });

  test(
      '05号：无长期生效状态且本轮未手动选中来源/本地限定时，气泡不回显任何'
      '范围类标签（保持47号计划前的原有行为不受影响）', () async {
    final ctrl = AiConversationController.restoreForTesting({
      'id': 'id-scope-no-persistent-no-turn',
      'title': '新会话',
      'createdAt': '2026-07-10T00:00:00.000Z',
      'displayMessages': <dynamic>[],
      'history': <dynamic>[],
      'version': 2,
    });

    await ctrl.send(
      '帮我搜一下',
      availablePromptTags: const [],
      persistSelections: false,
    );

    final userMessage = ctrl.displayMessages.first;
    expect(userMessage.promptTagNames, isEmpty);
  });

  test('重命名一个未打开的历史会话：直接操作 AiConversationStore，不依赖任何 controller 实例', () async {
    const id = 'history-conv-untouched';
    await AiConversationStore.save(
      id: id,
      title: '历史会话原标题',
      createdAt: DateTime.utc(2026, 1, 1),
      displayMessages: [AiChatMessage.user('历史消息')],
      history: const [],
    );

    await AiConversationStore.renameConversation(id, '手动重命名的标题');

    final reloaded = await AiConversationController.create(loadId: id);
    expect(reloaded.titleIsCustomForTesting, isTrue);
    expect(reloaded.conversationId, id);

    // 重新加载后继续对话触发 _save()，标题依然不被覆盖。
    reloaded.displayMessages.add(AiChatMessage.user('重新打开后继续对话的新消息'));
    await reloaded.saveForTesting();
    final data = await AiConversationStore.loadConversation(id);
    expect(data!['title'], '手动重命名的标题');
  });

  group('46号：一轮回复内多个 download_comic 工具调用不再产生孤儿 tool_call', () {
    test(
        '一轮回复同时返回2个 download_comic：入队顺序正确，且都确认后 _history 中'
        '每个 tool_call_id 恰好有一条对应的 tool 消息，不遗漏也不重复', () async {
      final ctrl = AiConversationController.restoreForTesting({
        'id': 'id-multi-download-confirm',
        'title': '新会话',
        'createdAt': '2026-07-10T00:00:00.000Z',
        'displayMessages': <dynamic>[],
        'history': <dynamic>[],
        'version': 2,
      });

      final toolCalls = [
        const LlmToolCall(
          id: 'call-1',
          name: 'download_comic',
          arguments: {
            'source': 'picacg',
            'id': '111',
            'title': '漫画一',
          },
        ),
        const LlmToolCall(
          id: 'call-2',
          name: 'download_comic',
          arguments: {
            'source': 'jm',
            'id': '222',
            'title': '漫画二',
          },
        ),
      ];

      // 直接调用 simulateToolCallRoundForTesting 模拟 _runLoop 遍历到这批
      // tool_calls 之后的处理逻辑，绕开真实 LLM 网络请求（不影响验证控制流
      // 本身的正确性）。
      await ctrl.simulateToolCallRoundForTesting(toolCalls);

      // 两个下载都应入队，且顺序与出现顺序一致（先 call-1 后 call-2）。
      expect(ctrl.pendingDownloadQueueLengthForTesting, 2);
      expect(ctrl.pendingDownload?.toolCallId, 'call-1');
      expect(ctrl.pendingDownload?.comicId, '111');

      // 确认第一个下载：队列里还剩第二个，不应触发续跑（因为还有未回复的 tool_call）。
      await ctrl.confirmDownload(false);
      expect(ctrl.pendingDownloadQueueLengthForTesting, 1);
      expect(ctrl.pendingDownload?.toolCallId, 'call-2');

      // 确认第二个（也是最后一个）下载：队列清空。
      // confirmDownload 会在队列清空后尝试续跑 _runLoop()（真实网络请求），
      // 因未配置 AI Provider，_runLoop 会以 LlmClient.chat 返回的 “Base URL
      // 未配置” 错误结束当前轮次，不影响本测试要验证的核心不变式。
      await ctrl.confirmDownload(true);
      expect(ctrl.pendingDownloadQueueLengthForTesting, 0);

      // 核心不变式校验：_history 中每一条 assistant tool_calls 消息的每一个
      // tool_call_id，最终都必须有且仅有一条对应的 tool 角色回复消息。
      final history = ctrl.historyForTesting();
      final expectedToolCallIds = <String>{};
      for (final message in history) {
        if (message.role == 'assistant' && message.toolCalls != null) {
          for (final tc in message.toolCalls!) {
            expectedToolCallIds.add(tc.id);
          }
        }
      }
      final actualToolMessageIds = history
          .where((message) => message.role == 'tool')
          .map((message) => message.toolCallId)
          .whereType<String>()
          .toList();

      expect(expectedToolCallIds, {'call-1', 'call-2'});
      // 不遗漏：每个预期 id 都出现过。
      expect(actualToolMessageIds.toSet(), expectedToolCallIds);
      // 不重复：tool 消息数量与去重后的 id 集合大小一致。
      expect(actualToolMessageIds.length, expectedToolCallIds.length);
    });

    test('一轮回复只有1个 download_comic 时行为不受影响：入队1个，确认后队列清空', () async {
      final ctrl = AiConversationController.restoreForTesting({
        'id': 'id-single-download-confirm',
        'title': '新会话',
        'createdAt': '2026-07-10T00:00:00.000Z',
        'displayMessages': <dynamic>[],
        'history': <dynamic>[],
        'version': 2,
      });

      final toolCalls = [
        const LlmToolCall(
          id: 'call-only',
          name: 'download_comic',
          arguments: {'source': 'picacg', 'id': '333', 'title': '漫画三'},
        ),
      ];

      await ctrl.simulateToolCallRoundForTesting(toolCalls);
      expect(ctrl.pendingDownloadQueueLengthForTesting, 1);

      await ctrl.confirmDownload(true);
      expect(ctrl.pendingDownloadQueueLengthForTesting, 0);

      final history = ctrl.historyForTesting();
      final toolMessages =
          history.where((message) => message.role == 'tool').toList();
      expect(toolMessages.length, 1);
      expect(toolMessages.single.toolCallId, 'call-only');
    });

    test('一轮回复没有 download_comic 时行为不受影响：直接续跑（非等待确认状态）', () async {
      final ctrl = AiConversationController.restoreForTesting({
        'id': 'id-no-download-confirm',
        'title': '新会话',
        'createdAt': '2026-07-10T00:00:00.000Z',
        'displayMessages': <dynamic>[],
        'history': <dynamic>[],
        'version': 2,
      });

      final toolCalls = [
        const LlmToolCall(
          id: 'call-search',
          name: 'search_local',
          arguments: {'query': '测试'},
        ),
      ];

      await ctrl.simulateToolCallRoundForTesting(toolCalls);
      expect(ctrl.pendingDownloadQueueLengthForTesting, 0);

      final history = ctrl.historyForTesting();
      final toolMessages =
          history.where((message) => message.role == 'tool').toList();
      expect(toolMessages.length, 1);
      expect(toolMessages.single.toolCallId, 'call-search');
    });
  });

  group('02号：空/空白 content 不再产生空文本气泡', () {
    test('content 为 null 且无工具调用：不产生空文本气泡，改为轻量提示气泡', () {
      final ctrl = AiConversationController.restoreForTesting({
        'id': 'id-empty-content-null',
        'title': '新会话',
        'createdAt': '2026-07-10T00:00:00.000Z',
        'displayMessages': <dynamic>[],
        'history': <dynamic>[],
        'version': 2,
      });

      ctrl.simulateFinalTextResponseForTesting(null);

      final assistantMessages = ctrl.displayMessages
          .where((m) => m.type == AiChatMessageType.assistant)
          .toList();
      expect(assistantMessages.length, 1);
      expect(assistantMessages.single.text, isNotEmpty);
      expect(assistantMessages.single.text, isNot(''));

      // 不应写入空 assistant 消息到 _history（避免污染后续请求历史）。
      final history = ctrl.historyForTesting();
      expect(
        history.where((m) => m.role == 'assistant').toList(),
        isEmpty,
      );
    });

    test('content 为空字符串且无工具调用：不产生空文本气泡，改为轻量提示气泡', () {
      final ctrl = AiConversationController.restoreForTesting({
        'id': 'id-empty-content-empty-string',
        'title': '新会话',
        'createdAt': '2026-07-10T00:00:00.000Z',
        'displayMessages': <dynamic>[],
        'history': <dynamic>[],
        'version': 2,
      });

      ctrl.simulateFinalTextResponseForTesting('');

      final assistantMessages = ctrl.displayMessages
          .where((m) => m.type == AiChatMessageType.assistant)
          .toList();
      expect(assistantMessages.length, 1);
      expect(assistantMessages.single.text, isNotEmpty);

      final history = ctrl.historyForTesting();
      expect(
        history.where((m) => m.role == 'assistant').toList(),
        isEmpty,
      );
    });

    test('content 为纯空白字符串且无工具调用：不产生空文本气泡，改为轻量提示气泡', () {
      final ctrl = AiConversationController.restoreForTesting({
        'id': 'id-empty-content-whitespace',
        'title': '新会话',
        'createdAt': '2026-07-10T00:00:00.000Z',
        'displayMessages': <dynamic>[],
        'history': <dynamic>[],
        'version': 2,
      });

      ctrl.simulateFinalTextResponseForTesting('   ');

      final assistantMessages = ctrl.displayMessages
          .where((m) => m.type == AiChatMessageType.assistant)
          .toList();
      expect(assistantMessages.length, 1);
      expect(assistantMessages.single.text, isNotEmpty);

      final history = ctrl.historyForTesting();
      expect(
        history.where((m) => m.role == 'assistant').toList(),
        isEmpty,
      );
    });

    test('content 有实际内容且无工具调用：气泡内容与原文一致（回归保护）', () {
      final ctrl = AiConversationController.restoreForTesting({
        'id': 'id-normal-content',
        'title': '新会话',
        'createdAt': '2026-07-10T00:00:00.000Z',
        'displayMessages': <dynamic>[],
        'history': <dynamic>[],
        'version': 2,
      });

      ctrl.simulateFinalTextResponseForTesting('正常内容');

      final assistantMessages = ctrl.displayMessages
          .where((m) => m.type == AiChatMessageType.assistant)
          .toList();
      expect(assistantMessages.length, 1);
      expect(assistantMessages.single.text, '正常内容');

      // 有实际内容时应正常写入 _history，供后续请求带上下文。
      final history = ctrl.historyForTesting();
      final assistantHistory =
          history.where((m) => m.role == 'assistant').toList();
      expect(assistantHistory.length, 1);
      expect(assistantHistory.single.content, '正常内容');
    });

    test('content 为空但存在待展示的工具结果（清单卡）时：不追加轻量提示气泡，只展示清单卡', () async {
      final ctrl = AiConversationController.restoreForTesting({
        'id': 'id-empty-content-with-pending-items',
        'title': '新会话',
        'createdAt': '2026-07-10T00:00:00.000Z',
        'displayMessages': <dynamic>[],
        'history': <dynamic>[],
        'version': 2,
      });

      // 先模拟一次 display_result_list 工具调用，返回非空清单项，产生待展示
      // 清单卡（_pendingDisplayItems 非空）。
      await ctrl.simulateToolCallRoundForTesting([
        const LlmToolCall(
          id: 'call-display-list',
          name: 'display_result_list',
          arguments: {
            'items': [
              {'id': 'result-1', 'title': '结果一'},
            ],
          },
        ),
      ]);

      ctrl.simulateFinalTextResponseForTesting('');

      final assistantMessages = ctrl.displayMessages
          .where((m) => m.type == AiChatMessageType.assistant)
          .toList();
      // 存在非空待展示清单项时，不应追加轻量提示气泡（避免与清单卡同时出现
      // 造成冗余提示）。
      expect(assistantMessages, isEmpty);

      final resultListMessages = ctrl.displayMessages
          .where((m) => m.type == AiChatMessageType.resultList)
          .toList();
      expect(resultListMessages.length, 1);
    });

    test('清单工具失败交回模型后，修正调用只生成一次清单且不保留脏数据', () async {
      final ctrl = AiConversationController.restoreForTesting({
        'id': 'id-display-list-retry',
        'title': '新会话',
        'createdAt': '2026-07-10T00:00:00.000Z',
        'displayMessages': <dynamic>[],
        'history': <dynamic>[],
        'version': 2,
      });

      await ctrl.simulateToolCallRoundForTesting(
        [
          const LlmToolCall(
            id: 'call-invalid-list',
            name: 'display_result_list',
            arguments: {
              'items': [
                {'id': 'only-id'},
              ],
            },
          ),
        ],
        continueWithLlm: false,
      );
      expect(
        ctrl.displayMessages
            .where((message) => message.type == AiChatMessageType.resultList),
        isEmpty,
      );
      final firstFailure = ctrl.displayMessages.firstWhere(
          (message) => message.type == AiChatMessageType.toolResult);
      expect(firstFailure.text, contains('校验失败'));
      expect((firstFailure.toolData as Map)['retryable'], isTrue);

      await ctrl.simulateToolCallRoundForTesting(
        [
          const LlmToolCall(
            id: 'call-fixed-list',
            name: 'display_result_list',
            arguments: {
              'items': [
                {
                  'id': 'fixed-id',
                  'title': '修正后的结果',
                  'source': 'nhentai',
                  'availability': '7页，汉化',
                },
              ],
            },
          ),
        ],
        continueWithLlm: false,
      );
      ctrl.simulateFinalTextResponseForTesting(null);

      final resultLists = ctrl.displayMessages
          .where((message) => message.type == AiChatMessageType.resultList)
          .toList();
      expect(resultLists, hasLength(1));
      expect(
        (resultLists.single.toolData as Map)['items'],
        hasLength(1),
      );
      expect(
        ctrl.historyForTesting().where((message) => message.role == 'tool'),
        hasLength(2),
      );
    });
  });
}
