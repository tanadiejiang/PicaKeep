import 'package:picakeep/foundation/ai/local_library_ai_query.dart';

import '../ai_tool.dart';

class ResolveLocalItemsTool extends AiTool {
  const ResolveLocalItemsTool();

  @override
  String get name => 'resolve_local_items';

  @override
  String get description => '宽松解析标题、链接、source id 或混合清单，并逐项执行本地查重。';

  @override
  Map<String, Object?> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'text': {
            'type': 'string',
            'description': '用户输入的标题/链接/id/混合清单',
          },
          'items': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '可选，已拆分的输入项列表',
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
            'description': '本地查重范围，默认全部',
          },
          'includePaths': {
            'type': 'boolean',
            'description': '是否返回完整路径，默认 true',
          },
        },
      };

  @override
  Future<AiToolResult> execute(Map<String, dynamic> args) async {
    final text = args['text']?.toString();
    final rawItems = args['items'];
    final items = rawItems is List
        ? rawItems
            .map((e) => e.toString())
            .where((e) => e.trim().isNotEmpty)
            .toList()
        : null;
    if ((text == null || text.trim().isEmpty) &&
        (items == null || items.isEmpty)) {
      return const AiToolResult.failure('text or items is required');
    }
    final scope = parseAiLocalQueryScope(args['scope']);
    if (scope == null) return const AiToolResult.failure('unsupported scope');
    final includePaths = args['includePaths'] is bool
        ? args['includePaths'] as bool
        : args['includePaths']?.toString().toLowerCase() == 'false'
            ? false
            : true;

    final result = await const AiLocalLibraryQueryCore().resolve(
      text: text,
      items: items,
      scope: scope,
      includePaths: includePaths,
    );
    return AiToolResult.success({
      'inputs': result.inputs,
      'summary': result.summary,
      'warnings': const <String>[],
    });
  }
}
