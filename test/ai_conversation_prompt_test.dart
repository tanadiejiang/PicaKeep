import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_conversation_store.dart';
import 'package:picakeep/foundation/ai/ai_prompt_tags.dart';
import 'package:picakeep/foundation/ai/llm_client.dart';

void main() {
  test('AiChatMessage 标签快照向后兼容并可往返', () {
    final old = AiChatMessage.fromJson({
      'type': 'user',
      'text': '旧消息',
      'createdAt': '2026-07-10T00:00:00.000Z',
    });
    expect(old.promptTagNames, isEmpty);

    final message = AiChatMessage.user(
      '#搜jm 测试',
      promptTagNames: const ['搜jm', '#搜角色'],
    );
    final restored = AiChatMessage.fromJson(message.toJson());
    expect(restored.promptTagNames, const ['搜jm', '搜角色']);
  });

  test('version 2 保存长期快照并按固定顺序保存来源', () {
    final json = AiConversationStore.serializeConversationForTesting(
      id: 'id',
      title: 'title',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026, 1, 2),
      displayMessages: [
        AiChatMessage.user('#搜jm', promptTagNames: const ['搜jm']),
      ],
      history: [LlmMessage.user('继续处理')],
      persistentPromptTags: const [
        AiPromptTag(name: '搜角色', prompt: '旧'),
        AiPromptTag(name: '搜角色', prompt: '新'),
      ],
      persistentAllowedSearchSources: const {'nhentai', 'picacg'},
    );

    expect(json['version'], 2);
    expect(json['persistentPromptTags'], [
      {'name': '搜角色', 'prompt': '新'},
    ]);
    expect(json['persistentAllowedSearchSources'], ['picacg', 'nhentai']);
    expect(
      (json['displayMessages'] as List).single['promptTagNames'],
      ['搜jm'],
    );
    expect(json.containsKey('persistentLocalOnly'), isFalse);
  });

  test('version 2 保存 persistentLocalOnly，仅显式为 true 时才写入该键', () {
    final jsonWithLocalOnly =
        AiConversationStore.serializeConversationForTesting(
      id: 'id',
      title: 'title',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026, 1, 2),
      displayMessages: const [],
      history: const [],
      persistentLocalOnly: true,
    );
    expect(jsonWithLocalOnly['persistentLocalOnly'], true);

    final jsonWithoutLocalOnly =
        AiConversationStore.serializeConversationForTesting(
      id: 'id',
      title: 'title',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026, 1, 2),
      displayMessages: const [],
      history: const [],
      persistentLocalOnly: null,
    );
    expect(jsonWithoutLocalOnly.containsKey('persistentLocalOnly'), isFalse);
  });

  test('缺失 persistentLocalOnly 字段时默认 false，version 2 可正常恢复 true', () {
    final base = <String, dynamic>{
      'id': 'id',
      'title': 'title',
      'createdAt': '2026-07-10T00:00:00.000Z',
      'displayMessages': <dynamic>[],
      'history': <dynamic>[],
    };

    final missingField = AiConversationController.restoreForTesting({
      ...base,
      'version': 2,
    });
    expect(missingField.effectiveLocalOnly, isFalse);

    final withLocalOnly = AiConversationController.restoreForTesting({
      ...base,
      'version': 2,
      'persistentLocalOnly': true,
    });
    expect(withLocalOnly.effectiveLocalOnly, isTrue);
  });

  test('version 1 忽略新增元数据，version 2 恢复长期状态', () {
    final base = <String, dynamic>{
      'id': 'id',
      'title': 'title',
      'createdAt': '2026-07-10T00:00:00.000Z',
      'displayMessages': <dynamic>[],
      'history': <dynamic>[],
      'persistentPromptTags': [
        {'name': '搜角色', 'prompt': '策略'},
      ],
      'persistentAllowedSearchSources': ['jm'],
    };

    final old = AiConversationController.restoreForTesting({
      ...base,
      'version': 1,
    });
    expect(old.persistentPromptTags, isEmpty);
    expect(old.persistentAllowedSearchSources, isNull);

    final current = AiConversationController.restoreForTesting({
      ...base,
      'version': 2,
    });
    expect(current.persistentPromptTags.single.prompt, '策略');
    expect(current.persistentAllowedSearchSources, {'jm'});
    final request = current.buildRequestMessagesForTesting();
    expect(request.first.content, contains('结果明显少于用户期望'));
    expect(request[1].content, contains('#搜角色：策略'));
  });

  test('schema 收窄深复制且不污染原 schema', () {
    final original = <String, Object?>{
      'name': 'search_online',
      'parameters': <String, Object?>{
        'properties': <String, Object?>{
          'source': <String, Object?>{
            'enum': <String>['picacg', 'jm', 'ehentai', 'nhentai'],
          },
        },
      },
    };
    final constrained = constrainAiToolSchemasBySources(
      [original],
      const {'jm', 'picacg'},
    );
    final source = (((constrained.single['parameters'] as Map)['properties']
        as Map)['source'] as Map);
    expect(source['enum'], ['picacg', 'jm']);
    final originalSource = (((original['parameters'] as Map)['properties']
        as Map)['source'] as Map);
    expect(originalSource['enum'], ['picacg', 'jm', 'ehentai', 'nhentai']);
  });

  test('dispatch 前硬拦截返回 failure，无限制与已选来源通过', () {
    final rejected = disallowedSearchSourceResult(
      'search_online',
      {'source': 'nhentai'},
      const {'jm'},
    );
    expect(rejected?.ok, isFalse);
    expect(rejected?.message, contains('当前会话/本轮仅允许：jm'));
    expect(
      disallowedSearchSourceResult(
        'search_online',
        {'source': 'JM'},
        const {'jm'},
      ),
      isNull,
    );
    expect(
      disallowedSearchSourceResult(
        'search_online',
        {'source': 'nhentai'},
        null,
      ),
      isNull,
    );
  });

  group('#搜本地 / 仅在线有效范围', () {
    AiConversationController buildCtrl({
      bool? persistentLocalOnly,
      List<String>? persistentAllowedSearchSources,
    }) {
      return AiConversationController.restoreForTesting({
        'id': 'id',
        'title': 'title',
        'createdAt': '2026-07-10T00:00:00.000Z',
        'displayMessages': <dynamic>[],
        'history': <dynamic>[],
        'version': 2,
        if (persistentLocalOnly != null)
          'persistentLocalOnly': persistentLocalOnly,
        if (persistentAllowedSearchSources != null)
          'persistentAllowedSearchSources': persistentAllowedSearchSources,
      });
    }

    test('无本地限定、无来源限制时 effectiveLocalOnly/effectiveOnlineOnly 均为 false', () {
      final ctrl = buildCtrl();
      expect(ctrl.effectiveLocalOnly, isFalse);
      expect(ctrl.effectiveOnlineOnly, isFalse);
    });

    test('长期仅本地时 effectiveLocalOnly=true，即使已选来源 effectiveOnlineOnly 仍为 false',
        () {
      final ctrl = buildCtrl(
        persistentLocalOnly: true,
        persistentAllowedSearchSources: ['jm'],
      );
      expect(ctrl.effectiveLocalOnly, isTrue);
      expect(ctrl.effectiveOnlineOnly, isFalse);
    });

    test('仅有长期来源限制、无本地限定时 effectiveOnlineOnly=true', () {
      final ctrl = buildCtrl(persistentAllowedSearchSources: ['jm', 'picacg']);
      expect(ctrl.effectiveLocalOnly, isFalse);
      expect(ctrl.effectiveOnlineOnly, isTrue);
    });

    test('isToolAllowedByScope：仅本地时拦截 search_online，放行本地库工具', () {
      expect(
        isToolAllowedByScope('search_online',
            effectiveLocalOnly: true, effectiveOnlineOnly: false),
        isFalse,
      );
      expect(
        isToolAllowedByScope('query_local_library',
            effectiveLocalOnly: true, effectiveOnlineOnly: false),
        isTrue,
      );
      expect(
        isToolAllowedByScope('get_download_status',
            effectiveLocalOnly: true, effectiveOnlineOnly: false),
        isTrue,
      );
    });

    test('isToolAllowedByScope：仅在线时拦截全部本地库工具，放行 search_online', () {
      for (final name in localLibraryToolNames) {
        expect(
          isToolAllowedByScope(name,
              effectiveLocalOnly: false, effectiveOnlineOnly: true),
          isFalse,
          reason: '$name 应被仅在线范围拦截',
        );
      }
      expect(
        isToolAllowedByScope('search_online',
            effectiveLocalOnly: false, effectiveOnlineOnly: true),
        isTrue,
      );
      expect(
        isToolAllowedByScope('get_download_status',
            effectiveLocalOnly: false, effectiveOnlineOnly: true),
        isTrue,
      );
    });

    test('isToolAllowedByScope：都不限制时全部放行', () {
      expect(
        isToolAllowedByScope('search_online',
            effectiveLocalOnly: false, effectiveOnlineOnly: false),
        isTrue,
      );
      for (final name in localLibraryToolNames) {
        expect(
          isToolAllowedByScope(name,
              effectiveLocalOnly: false, effectiveOnlineOnly: false),
          isTrue,
        );
      }
    });

    test('disallowedScopeResult 三种状态下的通过/拒绝与 isToolAllowedByScope 一致', () {
      // 仅本地：search_online 被拒绝
      final blockedOnline = disallowedScopeResult('search_online', true, false);
      expect(blockedOnline?.ok, isFalse);
      expect(blockedOnline?.message, contains('仅本地'));

      // 仅本地：本地库工具通过
      expect(disallowedScopeResult('query_local_library', true, false), isNull);

      // 仅在线：本地库工具被拒绝
      final blockedLocal = disallowedScopeResult('search_local', false, true);
      expect(blockedLocal?.ok, isFalse);
      expect(blockedLocal?.message, contains('仅在线'));

      // 仅在线：search_online 通过
      expect(disallowedScopeResult('search_online', false, true), isNull);

      // 都不限制：任何工具通过
      expect(disallowedScopeResult('search_online', false, false), isNull);
      expect(
        disallowedScopeResult('query_local_library', false, false),
        isNull,
      );
    });

    test('_getEnabledToolSchemas 在仅本地时剔除 search_online', () {
      final ctrl = buildCtrl(persistentLocalOnly: true);
      final request = ctrl.buildRequestMessagesForTesting();
      expect(request.last.role, 'system');
      expect(request.last.content, contains('不得调用在线搜索'));
      expect(request.last.content, contains('不需要询问用户是否联网'));
    });

    test('_buildRequestMessages 在仅在线（已选来源）时合并为单条 system 指令', () {
      final ctrl = buildCtrl(persistentAllowedSearchSources: ['jm']);
      final request = ctrl.buildRequestMessagesForTesting();
      final scopeMessages =
          request.where((m) => m.content?.contains('本轮范围限定') ?? false).toList();
      // 只应有一条范围相关 system 消息，不与来源限制消息重复啰嗦
      expect(scopeMessages.length, 1);
      expect(scopeMessages.single.content, contains('不需要先查本地库'));
      expect(scopeMessages.single.content, contains('#搜jm'));
    });

    test('47号：单一来源时不附加"分别调用"提示，措辞与旧版一致', () {
      final ctrl = buildCtrl(persistentAllowedSearchSources: ['jm']);
      final request = ctrl.buildRequestMessagesForTesting();
      final scopeMessages =
          request.where((m) => m.content?.contains('本轮范围限定') ?? false).toList();
      expect(scopeMessages.length, 1);
      expect(scopeMessages.single.content, isNot(contains('分别调用')));
    });

    test('47号：多来源（≥2个）时附加"分别调用 search_online"的说明，不再暗示需询问用户', () {
      final ctrl =
          buildCtrl(persistentAllowedSearchSources: ['jm', 'picacg']);
      final request = ctrl.buildRequestMessagesForTesting();
      final scopeMessages =
          request.where((m) => m.content?.contains('本轮范围限定') ?? false).toList();
      expect(scopeMessages.length, 1);
      final content = scopeMessages.single.content!;
      expect(content, contains('#搜jm'));
      expect(content, contains('#搜pica'));
      expect(content, contains('分别调用一次 search_online'));
      expect(content, contains('不需要询问用户具体选哪一个'));
      expect(content, contains('取得各来源结果后自行合并'));
    });

    test('同时选中仅本地与来源标签时，system 指令以仅本地措辞为准', () {
      final ctrl = buildCtrl(
        persistentLocalOnly: true,
        persistentAllowedSearchSources: ['jm'],
      );
      final request = ctrl.buildRequestMessagesForTesting();
      final scopeMessages =
          request.where((m) => m.content?.contains('本轮范围限定') ?? false).toList();
      expect(scopeMessages.length, 1);
      expect(scopeMessages.single.content, contains('仅查本地设备库'));
    });
  });
}
