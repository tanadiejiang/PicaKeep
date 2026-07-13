import '../ai_sources.dart';
import '../ai_tool.dart';

class DisplayResultListTool extends AiTool {
  const DisplayResultListTool();

  @override
  String get name => 'display_result_list';

  @override
  String get description =>
      '将指定的漫画条目以清单卡片形式展示在对话中，供用户点击查看。'
      '在搜索或筛选后，用此工具将精选结果呈现给用户，而不是用文字逐条罗列。'
      '传入的 items 可以来自本轮任意工具结果的子集，也可以跨多轮工具结果组合。';

  @override
  Map<String, Object?> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'items': {
            'type': 'array',
            'description':
                '要展示的漫画条目列表。每项应包含尽可能多的字段：'
                'id（漫画ID）、title（标题）、author（作者）、'
                'coverUrl（封面URL）、source（来源：picacg/jm/ehentai/nhentai）、'
                'tags（标签数组）、availability（可用性信息，可选）。',
            'items': {
              'type': 'object',
              'properties': {
                'source': {
                  'type': 'string',
                  'enum': [
                    aiSourcePicacg,
                    aiSourceJm,
                    aiSourceEhentai,
                    aiSourceNhentai,
                  ],
                  'description': '来源：picacg / jm / ehentai / nhentai',
                },
              },
            },
          },
          'label': {
            'type': 'string',
            'description': '清单标签（可选），如"原神可莉·非R18G"，会显示在清单标题中。',
          },
        },
        'required': ['items'],
      };

  @override
  Future<AiToolResult> execute(Map<String, dynamic> args) async {
    final items = (args['items'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        [];
    return AiToolResult.success({
      'items': items,
      'count': items.length,
    });
  }
}
