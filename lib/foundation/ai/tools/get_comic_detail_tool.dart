import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/eh_network/get_gallery_id.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';

import '../ai_sources.dart';
import '../ai_tool.dart';

/// 四源通用的只读漫画详情查询工具。
///
/// 与 [download_comic_tool] 共用"按源+ID 查详情"的四源 switch，但本工具只读，
/// 不调用任何 `OnlineDownloadManager.instance.enqueueXxx`，不入队、不触发下载。
class GetComicDetailTool extends AiTool {
  const GetComicDetailTool();

  @override
  String get name => 'get_comic_detail';

  @override
  String get description =>
      '按源和漫画ID获取完整详情（封面/作者/标签/简介等），仅查看不下载，不会加入下载队列。';

  @override
  Map<String, Object?> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'source': {
            'type': 'string',
            'enum': [aiSourcePicacg, aiSourceJm, aiSourceEhentai, aiSourceNhentai],
          },
          'id': {'type': 'string', 'description': '漫画/画廊ID或ehentai完整链接'},
        },
        'required': ['source', 'id'],
      };

  @override
  Future<AiToolResult> execute(Map<String, dynamic> args) async {
    final source = normalizeAiSource(args['source']);
    final id = args['id']?.toString().trim() ?? '';
    if (source == null) return const AiToolResult.failure('unsupported source');
    if (id.isEmpty) return const AiToolResult.failure('id is required');

    switch (source) {
      case aiSourcePicacg:
        final res = await PicacgNetwork().getComicInfo(id);
        if (res.error) return AiToolResult.failure(res.errorMessageWithoutNull);
        return AiToolResult.success(_picacgJson(res.data));
      case aiSourceJm:
        final normalizedId =
            id.replaceFirst(RegExp(r'^jm', caseSensitive: false), '');
        final res = await JmNetwork().getComicInfo(normalizedId);
        if (res.error) return AiToolResult.failure(res.errorMessageWithoutNull);
        return AiToolResult.success(_jmJson(res.data));
      case aiSourceEhentai:
        final res = await EhNetwork().getGalleryInfo(id);
        if (res.error) return AiToolResult.failure(res.errorMessageWithoutNull);
        return AiToolResult.success(_ehJson(res.data));
      case aiSourceNhentai:
        final normalizedId = id
            .replaceFirst(RegExp(r'^nhentai', caseSensitive: false), '')
            .replaceFirst(RegExp(r'^nh', caseSensitive: false), '');
        final res = await NhentaiNetwork().getComicInfo(normalizedId);
        if (res.error) return AiToolResult.failure(res.errorMessageWithoutNull);
        return AiToolResult.success(_nhentaiJson(res.data));
    }
    return const AiToolResult.failure('unsupported source');
  }

  Map<String, Object?> _picacgJson(PicacgComicItem comic) => {
        'source': aiSourcePicacg,
        'id': comic.id,
        'title': comic.title,
        'author': comic.author,
        'coverUrl': comic.path,
        'tags': comic.tags,
        'description': comic.detailDescription,
        'pageCount': comic.pagesCount,
        'chapterCount': comic.epsCount,
        'updateTime': comic.updatedAt,
        'likeCount': comic.likes,
      };

  Map<String, Object?> _jmJson(JmComicInfo comic) => {
        'source': aiSourceJm,
        'id': comic.id,
        'title': comic.title,
        'author': comic.author,
        'coverUrl': comic.coverUrl,
        'tags': comic.tags,
        'description': comic.description,
        'chapterCount': comic.series.length,
        'likeCount': comic.likes,
        'views': comic.views,
        'comments': comic.comments,
      };

  Map<String, Object?> _ehJson(Gallery gallery) => {
        'source': aiSourceEhentai,
        'id': getGalleryId(gallery.link),
        'title': gallery.title,
        'author': gallery.uploader,
        'coverUrl': gallery.coverPath,
        'tags': flattenEhTags(gallery.tags),
        'pageCount': int.tryParse(gallery.maxPage),
        'updateTime': gallery.time,
        'stars': gallery.stars,
      };

  Map<String, Object?> _nhentaiJson(NhentaiComic comic) => {
        'source': aiSourceNhentai,
        'id': comic.id,
        'title': comic.title,
        'coverUrl': comic.cover,
        'tags': flattenEhTags(comic.tags),
        'pageCount': comic.thumbnails.length,
      };
}

/// 把 namespace 分桶的 tags 拍平成 `namespace:tag` 列表。
///
/// 与 `Gallery._generateTags()`（`eh_models.dart`）保持同一约定，
/// nhentai 的 `Map<String, List<String>>` tags 结构与 eh 相同，复用此函数。
List<String> flattenEhTags(Map<String, List<String>> tags) {
  final res = <String>[];
  tags.forEach((namespace, values) {
    for (final value in values) {
      res.add('$namespace:$value');
    }
  });
  return res;
}
