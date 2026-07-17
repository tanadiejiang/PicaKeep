class AiToolResult {
  const AiToolResult({
    required this.ok,
    this.data,
    this.message,
  });

  const AiToolResult.success([this.data, this.message]) : ok = true;

  const AiToolResult.failure(this.message, [this.data]) : ok = false;

  final bool ok;
  final Object? data;
  final String? message;

  Map<String, Object?> toJson() => {
        'ok': ok,
        if (data != null) 'data': data,
        if (message != null) 'message': message,
      };
}

class AiToolExecutionContext {
  const AiToolExecutionContext({required this.operationId});

  final String operationId;
}

abstract class AiTool {
  const AiTool();

  String get name;
  String get description;
  Map<String, Object?> get parametersSchema;

  Future<AiToolResult> execute(Map<String, dynamic> args);

  /// Registry dispatches through this hook so new context-aware tools can use
  /// a stable call identity while existing tools keep their old API.
  Future<AiToolResult> executeWithContext(
    Map<String, dynamic> args,
    AiToolExecutionContext context,
  ) =>
      execute(args);

  Map<String, Object?> toSchema() => {
        'name': name,
        'description': description,
        'parameters': parametersSchema,
      };
}
