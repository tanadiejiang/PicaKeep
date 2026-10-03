import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/ai/ai_capabilities.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/foundation/ai/ai_tool.dart';
import 'package:picakeep/foundation/ai/ai_tool_plugin_store.dart';
import 'package:picakeep/foundation/ai/llm_client.dart';
import 'package:picakeep/foundation/ai/tools/search_by_image_tool.dart';

class _RecordingImageTool extends SearchByImageTool {
  var calls = 0;
  @override
  Future<AiToolResult> executeWithContext(Map<String, dynamic> args, AiToolExecutionContext context) async {
    calls++;
    return const AiToolResult.success({'items': []});
  }
}

Map<String, dynamic> _manifest({String parameter = 'keyword', String version = '1'}) => {
  'schemaVersion': 1, 'id': 'integration_catalog', 'name': '目录查询',
  'version': version, 'kind': 'http_json', 'endpoint': 'https://example.com/catalog',
  'description': '查询目录', 'parameters': {parameter: '查询词'},
  'query': {'q': '{$parameter}'}, 'resultPath': 'items',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory data;
  late AiToolPluginStore store;
  late List<String> settings;
  setUpAll(() async {
    data = await Directory.systemTemp.createTemp('ai-plugin-integration-');
    App.dataPath = data.path;
    store = AiToolPluginStore.instance;
    await store.load();
    AiCapabilities.ensureRegistered();
  });
  tearDownAll(() async => data.delete(recursive: true));
  setUp(() { settings = List.of(appdata.settings); });
  tearDown(() async {
    appdata.settings = settings;
    AiCapabilities.registry.register(const SearchByImageTool());
    await store.remove('integration_catalog');
    await store.setEnabled(builtinImagePluginId, true);
    await store.setMaintenanceEnabled(false);
  });

  AiConversationController controller({bool localOnly = false}) {
    final ctrl = AiConversationController.restoreForTesting({
      'id': 'plugin-integration', 'title': '测试', 'createdAt': '2026-10-03T00:00:00Z',
      'displayMessages': [], 'history': [], 'version': 2, 'persistentLocalOnly': localOnly,
    });
    addTearDown(ctrl.dispose);
    return ctrl;
  }

  test('关闭搜图能力后，来自旧schema的调用也不执行', () async {
    appdata.settings[aiCapabilitySearchByImageSettingIndex] = '0';
    final tool = _RecordingImageTool();
    AiCapabilities.registry.register(tool);
    final ctrl = controller();
    await ctrl.simulateToolCallRoundForTesting(const [
      LlmToolCall(id: 'stale-image', name: 'search_by_image', arguments: {'image_ref': 'old-ref'}),
    ], continueWithLlm: false);
    expect(tool.calls, 0);
    final response = jsonDecode(ctrl.historyForTesting().last.content!);
    expect(response['ok'], isFalse);
  });

  test('仅本地在真实工具循环阻止插件、维护和搜图', () async {
    await store.importManifest(jsonEncode(_manifest()));
    await store.setMaintenanceEnabled(true);
    appdata.settings[aiCapabilitySearchByImageSettingIndex] = '1';
    final tool = _RecordingImageTool();
    AiCapabilities.registry.register(tool);
    final ctrl = controller(localOnly: true);
    await ctrl.simulateToolCallRoundForTesting(const [
      LlmToolCall(id: 'a', name: 'search_by_image', arguments: {'image_ref': 'x'}),
      LlmToolCall(id: 'b', name: 'plugin_integration_catalog', arguments: {'keyword': 'x'}),
      LlmToolCall(id: 'c', name: 'manage_tool_plugin', arguments: {'action': 'list'}),
    ], continueWithLlm: false);
    expect(tool.calls, 0);
    final responses = ctrl.historyForTesting().where((m) => m.role == 'tool').map((m) => jsonDecode(m.content!)).toList();
    expect(responses, hasLength(3));
    expect(responses.every((r) => r['ok'] == false && r['message'].toString().contains('仅本地')), isTrue);
  });

  test('导入更新后schema立即改变，旧参数在执行时按新schema拒绝', () async {
    await store.importManifest(jsonEncode(_manifest()));
    Map schema() => AiCapabilities.registry.toolSchemas().singleWhere((s) => s['name'] == 'plugin_integration_catalog');
    expect((schema()['parameters'] as Map)['required'], ['keyword']);
    await store.importManifest(jsonEncode(_manifest(parameter: 'query', version: '2')));
    expect((schema()['parameters'] as Map)['required'], ['query']);
    final stale = await AiCapabilities.registry.dispatch('plugin_integration_catalog', {'keyword': 'old'});
    expect(stale.ok, isFalse);
    expect(stale.message, contains('query'));
  });

  test('禁用和删除后schema消失且旧工具名无法dispatch', () async {
    await store.importManifest(jsonEncode(_manifest()));
    bool visible() => AiCapabilities.registry.toolSchemas().any((s) => s['name'] == 'plugin_integration_catalog');
    expect(visible(), isTrue);
    await store.setEnabled('integration_catalog', false);
    expect(isAiCapabilityEnabled('plugin_integration_catalog'), isFalse);
    expect(visible(), isFalse);
    expect((await AiCapabilities.registry.dispatch('plugin_integration_catalog', {})).ok, isFalse);
    await store.setEnabled('integration_catalog', true);
    expect(visible(), isTrue);
    await store.remove('integration_catalog');
    expect(visible(), isFalse);
    expect((await AiCapabilities.registry.dispatch('plugin_integration_catalog', {})).ok, isFalse);
  });

  test('维护/搜图插件启停与原有能力开关分别生效', () async {
    expect(isAiCapabilityEnabled('manage_tool_plugin'), isFalse);
    await store.setMaintenanceEnabled(true);
    expect(isAiCapabilityEnabled('manage_tool_plugin'), isTrue);
    appdata.settings[aiCapabilitySearchByImageSettingIndex] = '1';
    expect(isAiCapabilityEnabled('search_by_image'), isTrue);
    await store.setEnabled(builtinImagePluginId, false);
    expect(isAiCapabilityEnabled('search_by_image'), isFalse);
    final result = await const SearchByImageTool().executeWithContext({'image_ref': 'out-of-context'},
        const AiToolExecutionContext(operationId: 'isolated'));
    expect(result.ok, isFalse);
    expect(result.message, contains('附件语境'));
  });

  test('维护能力或插件已关闭时旧schema调用在对话执行层拒绝', () async {
    await store.importManifest(jsonEncode(_manifest()));
    await store.setEnabled('integration_catalog', false);
    await store.setMaintenanceEnabled(false);
    final ctrl = controller();
    await ctrl.simulateToolCallRoundForTesting(const [
      LlmToolCall(id: 'disabled-plugin', name: 'plugin_integration_catalog', arguments: {'keyword': 'x'}),
      LlmToolCall(id: 'disabled-maintenance', name: 'manage_tool_plugin', arguments: {'action': 'list'}),
    ], continueWithLlm: false);
    final responses = ctrl.historyForTesting().where((m) => m.role == 'tool').map((m) => jsonDecode(m.content!)).toList();
    expect(responses, hasLength(2));
    expect(responses.every((r) => r['ok'] == false && r['message'].toString().contains('关闭')), isTrue);
  });
}
