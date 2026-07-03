import 'ai_tool.dart';

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

  List<Map<String, Object?>> toolSchemas() =>
      _tools.values.map((tool) => tool.toSchema()).toList(growable: false);

  Future<AiToolResult> dispatch(String name, Map args) async {
    final tool = _tools[name];
    if (tool == null) {
      return AiToolResult.failure('Unknown AI tool: $name');
    }
    try {
      return await tool.execute(
        args.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (e) {
      return AiToolResult.failure('AI tool $name failed: $e');
    }
  }
}
