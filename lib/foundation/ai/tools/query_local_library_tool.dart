import 'package:picakeep/foundation/ai/local_library_ai_query.dart';

import '../ai_tool.dart';

class QueryLocalLibraryTool extends AiTool {
  const QueryLocalLibraryTool();

  @override
  String get name => 'query_local_library';

  @override
  String get description => '查询本地库、收藏夹和阅读历史，返回统一的本地实体结构与可用动作。';

  @override
  Map<String, Object?> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': '标题、作者、标签、id、链接或自然语言片段',
          },
          'scope': {
            'type': 'string',
            'enum': [
              '全部',
              '库',
              '收藏',
              '历史',
              'all',
              'library',
              'favorites',
              'history'
            ],
            'description': '查询范围，默认全部',
          },
          'limit': {
            'type': 'integer',
            'description': '最多返回结果数，默认不主动截断',
          },
          'includePaths': {
            'type': 'boolean',
            'description': '是否返回完整路径，默认 true',
          },
        },
        'required': ['query'],
      };

  @override
  Future<AiToolResult> execute(Map<String, dynamic> args) async {
    final query = args['query']?.toString().trim() ?? '';
    if (query.isEmpty) return const AiToolResult.failure('query is required');
    final scope = parseAiLocalQueryScope(args['scope']);
    if (scope == null) return const AiToolResult.failure('unsupported scope');
    final limit = _parsePositiveInt(args['limit']);
    final includePaths = args['includePaths'] is bool
        ? args['includePaths'] as bool
        : args['includePaths']?.toString().toLowerCase() == 'false'
            ? false
            : true;

    final result = await const AiLocalLibraryQueryCore().query(
      query: query,
      scope: scope,
      limit: limit,
      includePaths: includePaths,
    );
    return AiToolResult.success({
      'query': query,
      'scope': scope.name,
      'items': result.items,
      'warnings': result.warnings,
    });
  }

  int? _parsePositiveInt(Object? value) {
    if (value == null) return null;
    final parsed = value is int ? value : int.tryParse(value.toString());
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }
}
