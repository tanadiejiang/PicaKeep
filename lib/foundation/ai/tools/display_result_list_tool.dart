import '../ai_sources.dart';
import '../ai_tool.dart';
import '../ai_result_item.dart';

class DisplayResultListTool extends AiTool {
  const DisplayResultListTool();

  @override
  String get name => 'display_result_list';

  @override
  String get description => '将指定的漫画条目以清单卡片形式展示在对话中，供用户点击查看。'
      '在搜索或筛选后，用此工具将精选结果呈现给用户，而不是用文字逐条罗列。'
      '传入的 items 可以来自本轮任意工具结果的子集，也可以跨多轮工具结果组合。'
      '若收到 retryable 校验失败，必须按错误字段重新生成完整 items 后再次调用；'
      '若返回零结果，不得重试或编造条目；工具成功前不得向用户声称清单已展示。';

  @override
  Map<String, Object?> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'items': {
            'type': 'array',
            'description': '要展示的漫画条目列表。每项应包含尽可能多的字段：'
                'id（漫画ID）、title（标题）、author（作者）、'
                'coverUrl（封面URL）、source（来源：picacg/jm/ehentai/nhentai）、'
                'tags（标签数组）、availability（可用性信息，可选）。',
            'items': {
              'type': 'object',
              'properties': {
                'id': {
                  'type': 'string',
                  'description': '必填，漫画唯一标识；URL 或数字 ID 均可。',
                },
                'title': {
                  'type': 'string',
                  'description': '必填，可展示的漫画标题。',
                },
                'author': {
                  'type': 'string',
                },
                'coverUrl': {
                  'type': 'string',
                },
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
                'tags': {
                  'type': 'array',
                  'items': {'type': 'string'},
                },
                'availability': {
                  'type': 'object',
                  'properties': {
                    'remoteDownloaded': {'type': 'boolean'},
                    'localDownloaded': {'type': 'boolean'},
                    'favorited': {'type': 'boolean'},
                    'summary': {'type': 'string'},
                    'states': {
                      'type': 'array',
                      'items': {'type': 'string'},
                    },
                  },
                },
              },
              'required': ['id', 'title'],
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
    final report = AiResultItem.decodeToolData(args);
    if (!report.isValid) {
      final issues = <Map<String, dynamic>>[
        if (report.topLevelIssue != null) report.topLevelIssue!.toJson(),
        ...report.issues.map((issue) => issue.toJson()),
      ];
      return AiToolResult.failure(
        '清单参数校验失败，请按字段错误重新生成完整 items 后重试。',
        {
          'code': 'invalid_result_list_items',
          'retryable': true,
          'issues': issues,
        },
      );
    }

    final normalizedItems =
        report.items.map((item) => item.toJson()).toList(growable: false);
    final normalizedCount = report.normalizedFields.values.fold<int>(
      0,
      (sum, count) => sum + count,
    );
    if (normalizedItems.isEmpty) {
      return AiToolResult.success(
        {
          'items': const <Map<String, dynamic>>[],
          'count': 0,
          'inputCount': report.inputCount,
          'retryable': false,
          'noItems': true,
        },
        '没有可展示的清单结果。',
      );
    }

    return AiToolResult.success(
      {
        'items': normalizedItems,
        'count': normalizedItems.length,
        'inputCount': report.inputCount,
        'normalizedCount': normalizedCount,
        if (report.normalizedFields.isNotEmpty)
          'normalizedFields': report.normalizedFields,
        'retryable': false,
      },
      normalizedCount > 0 ? '清单数据已自动规范化，无需重复调用。' : null,
    );
  }
}
