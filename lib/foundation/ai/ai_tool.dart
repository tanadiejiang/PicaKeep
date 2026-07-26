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
  const AiToolExecutionContext({
    required this.operationId,
    this.resolveAttachmentPath,
  });

  final String operationId;

  /// 会话附件解析：把 turn_context.attachments 里的 ref 解析为本地文件绝对路径。
  /// 只有 AiConversationController 的工具循环会注入；null 表示当前执行环境
  /// 没有附件语境（如调试页直连调用）。
  ///
  /// 15轮05号计划核心安全设计：模型不该拿到绝对路径——工具参数只收 ref
  /// （附件相对路径），ref→绝对路径的白名单解析由 controller 持有：只有
  /// 「用户明确发过的附件」里的 ref 才会被解析，模型编造的任意路径一律
  /// 解析失败，杜绝借工具读任意本地文件。
  final String? Function(String ref)? resolveAttachmentPath;
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
