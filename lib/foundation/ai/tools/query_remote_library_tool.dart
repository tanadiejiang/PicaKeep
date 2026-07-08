import 'package:picakeep/foundation/remote_library_data_source.dart';

import '../ai_tool.dart';

class QueryRemoteLibraryTool extends AiTool {
  const QueryRemoteLibraryTool();

  @override
  String get name => 'query_remote_library';

  @override
  String get description => '查询远程库中的已下载漫画快照，支持关键词过滤标题/作者/标签';

  @override
  Map<String, Object?> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'keyword': {
            'type': 'string',
            'description': '关键词，匹配标题/作者/标签，为空时返回全部',
          },
          'limit': {
            'type': 'integer',
            'description': '最多返回条数，默认20，最大100',
          },
        },
        'required': [],
      };

  @override
  Future<AiToolResult> execute(Map<String, dynamic> args) async {
    try {
      final keyword = args['keyword']?.toString().trim();
      final rawLimit = args['limit'];
      int limit = 20;
      if (rawLimit != null) {
        final parsed =
            rawLimit is int ? rawLimit : int.tryParse(rawLimit.toString());
        if (parsed != null && parsed > 0) {
          limit = parsed.clamp(1, 100);
        }
      }

      final items =
          await const RemoteLibraryDataSource().fetchManagedDownloadItems();

      var filtered = items;
      if (keyword != null && keyword.isNotEmpty) {
        final kw = keyword.toLowerCase();
        filtered = items
            .where((item) =>
                item.title.toLowerCase().contains(kw) ||
                item.subtitle.toLowerCase().contains(kw) ||
                item.metadataTags.any((tag) => tag.toLowerCase().contains(kw)))
            .toList();
      }

      final truncated = filtered.take(limit).toList();

      return AiToolResult.success({
        'source': 'remote',
        'total': filtered.length,
        'items': truncated
            .map((item) => {
                  'id': item.remoteId,
                  'title': item.title,
                  'author': item.subtitle,
                  'tags': item.metadataTags,
                  'coverUrl': item.coverUrl,
                  'source': item.sourceDisplayName,
                  'availability': {'remoteDownloaded': true},
                })
            .toList(),
        'note': '来自远程库快照，数据为缓存，可能非实时',
      });
    } catch (e) {
      return AiToolResult.failure('远程库查询失败: $e');
    }
  }
}
