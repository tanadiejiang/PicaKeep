import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/ai/ai_capabilities.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/foundation/ai/ai_tool.dart';
import 'package:picakeep/foundation/ai/llm_client.dart';
import 'package:picakeep/foundation/ai/tools/download_comic_tool.dart';

class _RecordingDownloadTool extends DownloadComicTool {
  final calls = <Map<String, dynamic>>[];
  AiToolResult Function(Map<String, dynamic>)? onExecute;

  @override
  Future<AiToolResult> execute(Map<String, dynamic> args) async {
    calls.add(Map.of(args));
    return onExecute?.call(args) ??
        AiToolResult.success({'taskId': args['id']}, '已加入下载队列');
  }
}

const _firstDownload = LlmToolCall(
  id: 'download-1',
  name: 'download_comic',
  arguments: {'source': 'jm', 'id': '123'},
);
const _secondDownload = LlmToolCall(
  id: 'download-2',
  name: 'download_comic',
  arguments: {'source': 'nhentai', 'id': '456'},
);
const _displayList = LlmToolCall(
  id: 'display-1',
  name: 'display_result_list',
  arguments: {
    'items': [
      {'source': 'jm', 'id': '123', 'title': '测试条目'},
    ],
  },
);

void main() {
  late Directory dataDir;
  setUpAll(() {
    dataDir = Directory.systemTemp.createTempSync('ai_confirmation_test_');
    App.dataPath = dataDir.path;
  });
  tearDownAll(() => dataDir.deleteSync(recursive: true));
  late List<String> savedSettings;
  late _RecordingDownloadTool downloader;

  setUp(() {
    savedSettings = List.of(appdata.settings);
    appdata.settings[aiCapabilityDownloadComicSettingIndex] = '1';
    appdata.settings[aiAutoDownloadEnabledSettingIndex] = '1';
    downloader = _RecordingDownloadTool();
    AiCapabilities.registry.register(downloader);
  });

  tearDown(() {
    AiCapabilities.registry.register(const DownloadComicTool());
    appdata.settings = savedSettings;
  });

  AiConversationController controller({AiChatRequestForTesting? chat}) {
    final ctrl = AiConversationController.restoreForTesting({
      'id': 'auto-download-test',
      'title': '测试',
      'createdAt': '2026-09-06T00:00:00.000Z',
      'displayMessages': <dynamic>[],
      'history': <dynamic>[],
      'version': 2,
    }, chatRequestForTesting: chat);
    addTearDown(ctrl.dispose);
    return ctrl;
  }

  void expectPairedResults(AiConversationController ctrl, List<String> ids) {
    final results = ctrl.historyForTesting().where((m) => m.role == 'tool');
    expect(results.map((m) => m.toolCallId), ids);
    for (final id in ids) {
      expect(results.where((m) => m.toolCallId == id), hasLength(1));
    }
  }

  test('自动下载开启：单本直接执行，无待确认项并回填成功结果', () async {
    final ctrl = controller();
    await ctrl.simulateToolCallRoundForTesting([
      _firstDownload,
    ], continueWithLlm: false);

    expect(downloader.calls, [_firstDownload.arguments]);
    expect(ctrl.pendingDownload, isNull);
    expectPairedResults(ctrl, ['download-1']);
    final result = ctrl.historyForTesting().last;
    expect(jsonDecode(result.content!)['ok'], isTrue);
  });

  test('同轮多本和展示工具全部回填后才继续请求模型', () async {
    var rounds = 0;
    final ctrl = controller(
      chat: (messages, {tools, conversationHash, turn, round}) async {
        rounds++;
        expect(tools!.any((tool) => tool['name'] == 'download_comic'), isTrue);
        final systemPrompt =
            messages.firstWhere((m) => m.role == 'system').content!;
        expect(systemPrompt, contains('无需再次询问确认'));
        expect(systemPrompt, isNot(contains('所有下载操作必须告知用户并等待确认')));
        if (rounds == 1) {
          return const LlmResponse(
            toolCalls: [_firstDownload, _displayList, _secondDownload],
          );
        }
        expect(
          messages.where((m) => m.role == 'tool').map((m) => m.toolCallId),
          ['download-1', 'display-1', 'download-2'],
        );
        return const LlmResponse(content: '下载已入队');
      },
    );

    await ctrl.runLlmLoopForTesting();

    expect(rounds, 2);
    expect(downloader.calls.map((args) => args['id']), ['123', '456']);
    expect(ctrl.pendingDownloadQueueLengthForTesting, 0);
    expectPairedResults(ctrl, ['download-1', 'display-1', 'download-2']);
    expect(ctrl.displayMessages.last.text, '下载已入队');
  });

  for (final throwsError in [false, true]) {
    test('首本${throwsError ? '抛异常' : '入队失败'}仍回填失败结果并处理下一本', () async {
      downloader.onExecute = (args) {
        if (args['id'] == '123') {
          if (throwsError) throw StateError('入队失败');
          return const AiToolResult.failure('入队失败');
        }
        return const AiToolResult.success({'taskId': '456'});
      };
      final ctrl = controller();
      await ctrl.simulateToolCallRoundForTesting([
        _firstDownload,
        _secondDownload,
      ], continueWithLlm: false);

      expect(downloader.calls, hasLength(2));
      expect(ctrl.pendingDownload, isNull);
      expectPairedResults(ctrl, ['download-1', 'download-2']);
      final results = ctrl.historyForTesting().where((m) => m.role == 'tool');
      expect(results.map((m) => jsonDecode(m.content!)['ok']), [false, true]);
    });
  }

  for (final setting in [
    aiCapabilityDownloadComicSettingIndex,
    aiAutoDownloadEnabledSettingIndex,
  ]) {
    test('开关 $setting 关闭：总开关控制可见性，下载进入确认队列', () async {
      appdata.settings[setting] = '0';
      final ctrl = controller(
        chat: (messages, {tools, conversationHash, turn, round}) async {
          expect(
            tools!.any((tool) => tool['name'] == 'download_comic'),
            setting == aiAutoDownloadEnabledSettingIndex,
          );
          return const LlmResponse(toolCalls: [_firstDownload]);
        },
      );

      await ctrl.runLlmLoopForTesting();

      expect(downloader.calls, isEmpty);
      expect(ctrl.pendingDownload?.toolCallId, 'download-1');
      expect(ctrl.historyForTesting().where((m) => m.role == 'tool'), isEmpty);
    });
  }

  for (final confirmed in [true, false]) {
    test('自动下载关闭：工具可见，用户${confirmed ? '确认后下载' : '取消不下载'}', () async {
      appdata.settings[aiAutoDownloadEnabledSettingIndex] = '0';
      var rounds = 0;
      final ctrl = controller(
          chat: (messages, {tools, conversationHash, turn, round}) async {
        rounds++;
        expect(tools!.any((tool) => tool['name'] == 'download_comic'), isTrue);
        expect(messages.firstWhere((m) => m.role == 'system').content,
            contains('不代表用户已允许自动下载'));
        if (rounds == 1) return const LlmResponse(toolCalls: [_firstDownload]);
        return const LlmResponse(content: '处理完成');
      });
      await ctrl.runLlmLoopForTesting();
      expect(rounds, 1);
      expect(downloader.calls, isEmpty);
      expect(ctrl.pendingDownload?.toolCallId, 'download-1');
      await ctrl.confirmDownload(confirmed);
      expect(downloader.calls, hasLength(confirmed ? 1 : 0));
      expect(ctrl.pendingDownload, isNull);
      expect(rounds, 2);
      expectPairedResults(ctrl, ['download-1']);
      final result =
          ctrl.historyForTesting().singleWhere((m) => m.role == 'tool');
      expect(jsonDecode(result.content!)['ok'], confirmed);
    });
  }

  test('等待确认期间关闭下载总开关，确认也不能执行', () async {
    appdata.settings[aiAutoDownloadEnabledSettingIndex] = '0';
    final ctrl = controller(
        chat: (messages, {tools, conversationHash, turn, round}) async =>
            const LlmResponse(content: '已停止'));
    await ctrl.simulateToolCallRoundForTesting([_firstDownload],
        continueWithLlm: false);
    appdata.settings[aiCapabilityDownloadComicSettingIndex] = '0';
    await ctrl.confirmDownload(true);
    expect(downloader.calls, isEmpty);
    expect(ctrl.pendingDownload, isNull);
    expectPairedResults(ctrl, ['download-1']);
    final result =
        ctrl.historyForTesting().singleWhere((m) => m.role == 'tool');
    expect(jsonDecode(result.content!)['ok'], isFalse);
  });

  test('首本入队时关闭自动下载，剩余任务转入确认队列', () async {
    downloader.onExecute = (_) {
      appdata.settings[aiAutoDownloadEnabledSettingIndex] = '0';
      return const AiToolResult.success({'taskId': '123'});
    };
    final ctrl = controller();
    await ctrl.simulateToolCallRoundForTesting([
      _firstDownload,
      _secondDownload,
    ], continueWithLlm: false);

    expect(downloader.calls.map((args) => args['id']), ['123']);
    expectPairedResults(ctrl, ['download-1']);
    expect(ctrl.pendingDownload?.toolCallId, 'download-2');
    expect(ctrl.pendingDownloadQueueLengthForTesting, 1);
  });
}
