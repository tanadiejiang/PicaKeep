import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/eh_network/get_gallery_id.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';

import '../ai_sources.dart';
import '../ai_tool.dart';

class DownloadComicTool extends AiTool {
  const DownloadComicTool();

  @override
  String get name => 'download_comic';

  @override
  String get description => '按源和漫画ID获取详情并加入在线下载队列。一次一本，直接入队。';

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
        final enqueue = await OnlineDownloadManager.instance.enqueuePicacg(res.data);
        if (enqueue.error) {
          return AiToolResult.failure(enqueue.errorMessageWithoutNull);
        }
        return AiToolResult.success({
          'taskId': res.data.id,
          'title': res.data.title,
        }, '已加入下载队列');
      case aiSourceJm:
        final normalizedId = id.replaceFirst(RegExp(r'^jm', caseSensitive: false), '');
        final res = await JmNetwork().getComicInfo(normalizedId);
        if (res.error) return AiToolResult.failure(res.errorMessageWithoutNull);
        final enqueue = await OnlineDownloadManager.instance.enqueueJm(res.data);
        if (enqueue.error) {
          return AiToolResult.failure(enqueue.errorMessageWithoutNull);
        }
        return AiToolResult.success({
          'taskId': 'jm${res.data.id}',
          'title': res.data.title,
        }, '已加入下载队列');
      case aiSourceEhentai:
        final res = await EhNetwork().getGalleryInfo(id);
        if (res.error) return AiToolResult.failure(res.errorMessageWithoutNull);
        final enqueue = await OnlineDownloadManager.instance.enqueueEhentai(res.data);
        if (enqueue.error) {
          return AiToolResult.failure(enqueue.errorMessageWithoutNull);
        }
        return AiToolResult.success({
          'taskId': getGalleryId(res.data.link),
          'title': res.data.title,
        }, '已加入下载队列');
      case aiSourceNhentai:
        final normalizedId = id
            .replaceFirst(RegExp(r'^nhentai', caseSensitive: false), '')
            .replaceFirst(RegExp(r'^nh', caseSensitive: false), '');
        final res = await NhentaiNetwork().getComicInfo(normalizedId);
        if (res.error) return AiToolResult.failure(res.errorMessageWithoutNull);
        final enqueue = await OnlineDownloadManager.instance.enqueueNhentai(res.data);
        if (enqueue.error) {
          return AiToolResult.failure(enqueue.errorMessageWithoutNull);
        }
        return AiToolResult.success({
          'taskId': 'nhentai${res.data.id}',
          'title': res.data.title,
        }, '已加入下载队列');
    }
    return const AiToolResult.failure('unsupported source');
  }
}
