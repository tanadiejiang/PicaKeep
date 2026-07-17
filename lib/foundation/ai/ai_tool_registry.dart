import 'ai_tool.dart';
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

  List<Map<String, Object?>> toolSchemas() =>
      _tools.values.map((tool) => tool.toSchema()).toList(growable: false);

  Future<AiToolResult> dispatch(
    String name,
    Map args, {
    AiToolExecutionContext? context,
  }) async {
    final tool = _tools[name];
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
