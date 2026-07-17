import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';

import '../ai_sources.dart';
import '../ai_tool.dart';

class SearchOnlineTool extends AiTool {
  const SearchOnlineTool();

  @override
  String get name => 'search_online';

  @override
  String get description => '搜索在线漫画源，返回候选漫画的基础信息。';

  @override
  Map<String, Object?> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'source': {
            'type': 'string',
            'enum': [
              aiSourcePicacg,
              aiSourceJm,
              aiSourceEhentai,
              aiSourceNhentai
            ],
            'description': '在线源：picacg / jm / ehentai / nhentai',
          },
          'keyword': {'type': 'string', 'description': '搜索关键词'},
          'page': {'type': 'integer', 'description': '页码，默认1'},
        },
        'required': ['source', 'keyword'],
      };

  @override
  Future<AiToolResult> execute(Map<String, dynamic> args) async {
    final source = normalizeAiSource(args['source']);
    final keyword = args['keyword']?.toString().trim() ?? '';
    final page = _intArg(args['page']) ?? 1;
    if (source == null) return const AiToolResult.failure('unsupported source');
    if (keyword.isEmpty) {
      return const AiToolResult.failure('keyword is required');
    }
    if (page <= 0) return const AiToolResult.failure('page must be >= 1');

    switch (source) {
      case aiSourcePicacg:
        final res = await PicacgNetwork().search(keyword, 'dd', page);
        if (res.error) return AiToolResult.failure(res.errorMessageWithoutNull);
        return AiToolResult.success({
          'source': source,
          'page': page,
          'items': res.data
              .map((comic) => _baseComicJson(comic, source: source))
              .toList(),
          'note': 'picacg 搜索结果含 pages 字段，映射为 pageCount。',
        });
      case aiSourceJm:
        final res = await JmNetwork().search(keyword, 'mr', page);
        if (res.error) return AiToolResult.failure(res.errorMessageWithoutNull);
        return AiToolResult.success({
          'source': source,
          'page': page,
          'maxPage': res.subData,
          'items': res.data
              .map((comic) => _baseComicJson(comic, source: source))
              .toList(),
          'note': 'jm 搜索结果不含 pageCount。',
        });
      case aiSourceEhentai:
        if (page != 1) {
          return const AiToolResult.failure(
              'ehentai 搜索使用 next 游标；AI地基本轮仅支持第一页');
        }
        final res = await EhNetwork().search(keyword);
        if (res.error) return AiToolResult.failure(res.errorMessageWithoutNull);
        final galleries = res.data;
        return AiToolResult.success({
          'source': source,
          'page': page,
          'hasNext': galleries.next != null,
          'items': galleries.galleries.map(_ehBriefJson).toList(),
          'note': 'ehentai 搜索结果含 pages 字段，映射为 pageCount；翻页为 next 游标，本工具暂不暴露。',
        });
      case aiSourceNhentai:
        final res = await NhentaiNetwork().search(keyword, page);
        if (res.error) return AiToolResult.failure(res.errorMessageWithoutNull);
        return AiToolResult.success({
          'source': source,
          'page': page,
          'maxPage': res.subData,
          'items': res.data
              .map((comic) => _baseComicJson(comic, source: source))
              .toList(),
          'note': 'nhentai 搜索结果不含 pageCount/author。',
        });
    }
    return const AiToolResult.failure('unsupported source');
  }

  Map<String, Object?> _baseComicJson(
    BaseComic comic, {
    required String source,
  }) =>
      {
        'id': comic.id,
        'title': comic.title,
        'author': resolveSourceAuthors(
          source: source,
          flatTags: comic.tags,
          fallbackAuthor: comic.subTitle,
        ).join(', '),
        'coverUrl': comic.cover,
        'tags': comic.tags,
        if (comic is PicacgComicItemBrief && comic.pages != null)
          'pageCount': comic.pages,
      };

  Map<String, Object?> _ehBriefJson(EhGalleryBrief comic) => {
        'id': comic.id,
        'title': comic.title,
        'author': resolveSourceAuthors(
          source: aiSourceEhentai,
          flatTags: comic.tags,
        ).join(', '),
        'coverUrl': comic.cover,
        'tags': comic.tags,
        if (comic.pages != null) 'pageCount': comic.pages,
      };

  int? _intArg(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}
