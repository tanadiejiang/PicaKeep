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

abstract class AiTool {
  const AiTool();

  String get name;
  String get description;
  Map<String, Object?> get parametersSchema;

  Future<AiToolResult> execute(Map<String, dynamic> args);

  Map<String, Object?> toSchema() => {
        'name': name,
        'description': description,
        'parameters': parametersSchema,
      };
}
