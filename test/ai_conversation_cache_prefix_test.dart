import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_prompt_tags.dart';
import 'package:picakeep/foundation/ai/llm_client.dart';
import 'package:picakeep/foundation/app.dart';

void main() {
  setUpAll(() async {
    final root = await Directory.systemTemp.createTemp('picakeep_cache_test_');
    App.dataPath = root.path;
    addTearDown(() => root.delete(recursive: true));
  });

  test('canonical cache fingerprints sort maps recursively and preserve lists',
      () {
    final first = aiDiagnosticSha256({
      'b': [
        {'z': 2, 'a': 1},
        'same',
      ],
      'a': 'value',
    });
    final reordered = aiDiagnosticSha256({
      'a': 'value',
      'b': [
        {'a': 1, 'z': 2},
        'same',
      ],
    });

    expect(first, reordered);
    expect(
        aiDiagnosticSha256({
          'items': [1, 2]
        }),
        isNot(aiDiagnosticSha256({
          'items': [2, 1]
        })));
  });

  test(
      'dynamic context is appended to the user message and old requests stay prefixes',
      () async {
    final captured = <List<LlmMessage>>[];
    final metadata = <Map<String, Object?>>[];
    final ctrl = AiConversationController.restoreForTesting(
      {
        'id': 'cache-prefix-test',
        'title': 'title',
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
        captured.add(List<LlmMessage>.of(messages));
        metadata.add({
          'conversationHash': conversationHash,
          'turn': turn,
          'round': round,
        });
        return const LlmResponse(content: 'ok');
      },
    );

    await ctrl.send(
      '#搜jm first line\nwith "quotes"',
      availablePromptTags: const [
        AiPromptTag(name: '搜角色', prompt: '角色策略'),
      ],
      selectedPromptTags: const [
        AiPromptTag(name: '搜角色', prompt: '角色策略'),
      ],
      allowedSearchSources: const {'jm'},
      persistSelections: false,
    );
    await ctrl.send(
      '#搜pica second',
      availablePromptTags: const [],
      allowedSearchSources: const {'picacg'},
      persistSelections: false,
    );

    expect(captured, hasLength(2));
    expect(metadata[0]['conversationHash'],
        aiDiagnosticSha256('cache-prefix-test'));
    expect(metadata[0]['turn'], 1);
    expect(metadata[0]['round'], 1);
    expect(metadata[1]['turn'], 2);
    expect(metadata[1]['round'], 1);
    final firstRequest =
        captured[0].map((message) => message.toJson()).toList();
    final secondRequest =
        captured[1].map((message) => message.toJson()).toList();
    expect(secondRequest.sublist(0, firstRequest.length), firstRequest);

    final firstUser = jsonDecode(captured[0]
        .singleWhere(
          (message) => message.role == 'user',
        )
        .content!) as Map<String, dynamic>;
    expect(firstUser['turn_context'], isA<Map<String, dynamic>>());
    expect(firstUser['user_query'], contains('first line'));
    expect(firstUser['user_query'], contains('"quotes"'));
    expect(
      (firstUser['turn_context'] as Map<String, dynamic>)['online_sources'],
      ['jm'],
    );
    expect(ctrl.displayMessages.first.text, contains('first line'));
  });

  test('missing cache fields and zero prompt tokens are safe', () {
    expect(LlmUsage.fromJson({}).cacheHitRatePercent, isNull);
    expect(
      const LlmUsage(
        promptTokens: 0,
        completionTokens: 1,
        cacheHitTokens: 0,
        cacheMissTokens: 0,
      ).cacheHitRatePercent,
      isNull,
    );
  });

  test('restoring old history preserves plain user content', () {
    final ctrl = AiConversationController.restoreForTesting(
      {
        'id': 'old-history-test',
        'title': 'title',
        'createdAt': '2026-07-10T00:00:00.000Z',
        'displayMessages': <dynamic>[],
        'history': [
          {'role': 'user', 'content': '旧格式用户消息'},
        ],
        'version': 1,
      },
    );

    final request = ctrl.buildRequestMessagesForTesting();
    expect(request.map((message) => message.content), contains('旧格式用户消息'));
  });
}
