import 'ai_tool.dart';
import 'ai_tool_plugin_store.dart';
import 'ai_tool_plugin_runtime.dart';
import 'package:uuid/uuid.dart';

class AiToolRegistry {
  AiToolRegistry._();

  static final AiToolRegistry instance = AiToolRegistry._();

  final Map<String, AiTool> _tools = <String, AiTool>{};

  void register(AiTool tool) {
    _tools[tool.name] = tool;
  }

  void registerAll(Iterable<AiTool> tools) {
    for (final tool in tools) {
      register(tool);
    }
  }

  List<Map<String, Object?>> toolSchemas() => [
        ..._tools.values.map((tool) => tool.toSchema()),
        const AiManageToolPluginTool().toSchema(),
        for (final record in AiToolPluginStore.loadedRecords)
          if (record.plugin.kind == 'http_json' && record.enabled)
            AiHttpJsonPluginTool(record.plugin).toSchema(),
      ];

  Future<AiToolResult> dispatch(
    String name,
    Map args, {
    AiToolExecutionContext? context,
  }) async {
    AiTool? tool = _tools[name];
    if (tool == null &&
        (name == 'manage_tool_plugin' || name.startsWith('plugin_'))) {
      await AiToolPluginStore.instance.load();
      final record = AiToolPluginStore.instance.records
          .where((r) =>
              r.plugin.kind == 'http_json' &&
              r.plugin.toolName == name &&
              r.enabled)
          .firstOrNull;
      tool = name == 'manage_tool_plugin'
          ? const AiManageToolPluginTool()
          : record == null
              ? null
              : AiHttpJsonPluginTool(record.plugin);
    }
    if (tool == null) {
      return AiToolResult.failure('Unknown AI tool: $name');
    }
    try {
      final executionContext = context ??
          AiToolExecutionContext(
            operationId: 'ai-direct-${const Uuid().v4()}',
          );
      return await tool.executeWithContext(
        args.map((key, value) => MapEntry(key.toString(), value)),
        executionContext,
      );
    } catch (e) {
      return AiToolResult.failure('AI tool $name failed: $e');
    }
  }
}
