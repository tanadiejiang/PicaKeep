import 'package:flutter/material.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'local_favorite_actions.dart';
import 'package:share_plus/share_plus.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/base_online_comic_page.dart';
import 'package:picakeep/pages/online_comic/jm_comments_page_v2.dart';
import 'package:picakeep/pages/online_comic/online_comic_page_components.dart';
import 'package:picakeep/pages/online_search/online_search_result_page.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

/// JM 详情页（基于 BaseOnlineComicPage）
class JmComicPageV2 extends BaseOnlineComicPage<JmComicInfo> {
  const JmComicPageV2(this.comicId, {super.key});

  final String comicId;

  @override
  String get tag => 'jm_v2_$comicId';

  @override
  String get id => comicId;

  @override
  String get sourceKey => 'jm';

  @override
  String get source => 'JM禁漫天堂';

  @override
  Future<Res<JmComicInfo>> loadData() async {
    return JmNetwork().getComicInfo(comicId);
  }

  // === 数据提取 ===

  @override
  String? extractTitle(JmComicInfo data) => data.title;

  @override
  String? extractCover(JmComicInfo data) => data.coverUrl;

  @override
  String? extractSubTitle(JmComicInfo data) => data.author;

  @override
  String? extractDescription(JmComicInfo data) => data.description;

  @override
  int? extractViews(JmComicInfo data) => data.views;

  @override
  int? extractLikes(JmComicInfo data) => data.likes;

  @override
  int? extractComments(JmComicInfo data) => data.comments;

  @override
  Map<String, List<String>>? extractTags(JmComicInfo data) {
    return {
      'ID': ['JM${data.id}'],
      if (data.authors.isNotEmpty) '作者': data.authors,
      if (data.works.isNotEmpty) '作品': data.works,
      if (data.actors.isNotEmpty) '演员': data.actors.take(30).toList(),
      if (data.tags.isNotEmpty) '标签': data.tags.take(30).toList(),
    };
  }

  @override
  List<String>? extractEpisodes(JmComicInfo data) {
    if (data.series.isEmpty) return null;
    return List.generate(
      data.series.length,
      (i) => i < data.epNames.length ? data.epNames[i] : '第${i + 1}章',
    );
  }

  @override
  List<OnlineComicRecommendation>? extractRecommendation(JmComicInfo data) {
    if (data.relatedComics.isEmpty) return null;
    return data.relatedComics
        .map((comic) => OnlineComicRecommendation(
              title: comic.title,
              cover: comic.coverUrl,
            ))
        .toList();
  }

  // === 图片请求头 ===

  @override
  Map<String, String> get imageHeaders => getJmImgHeaders();

  // === 交互行为 ===

  @override
  void onTagTap(BuildContext context, String tag, String category) {
    final source = ComicSource.find(sourceKey);
    if (source == null) return;

    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => OnlineSearchResultPage(
          source: source,
          keyword: tag,
          option: '',
        ),
      ),
    );
  }

  @override
  Future<void> onRead(BuildContext context, JmComicInfo data,
      {int ep = 1}) async {
    await History.ensureForLocalRead(
      target: data.id,
      type: HistoryType.jmComic,
      title: data.title,
      subtitle: data.author,
      cover: data.coverUrl,
      ep: ep,
    );
    if (!context.mounted) return;
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => ComicReadingPage(
          JmReadingData(info: data),
          1,
          ep,
        ),
      ),
    );
  }

  @override
  Future<void> onDownload(BuildContext context, JmComicInfo data) async {
    final res = await OnlineDownloadManager.instance.enqueueJm(data);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(res.error ? res.errorMessageWithoutNull : '已加入下载队列'),
      ),
    );
  }

  @override
  Future<void> onFavorite(BuildContext context, JmComicInfo data) async {
    if (!await choosePlatformFavorite(context, FavoriteItem(
      target: data.id, name: data.title, coverPath: data.coverUrl,
      author: data.author, type: FavoriteType.jm, tags: data.tags,
    ))) {
      return;
    }
    // 基于当前真实收藏态 toggle（data.isFavourite 是加载时的不可变快照）。
    final adding = !currentFavorite;

    // 取消收藏：直接调用即可。
    if (!adding) {
      final res = await JmNetwork().setFavorite(data.id, add: false);
      if (!context.mounted) return;
      if (res.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: ${res.errorMessageWithoutNull}')),
        );
      } else {
        refreshFavorite(false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已取消收藏')),
        );
      }
      return;
    }

    // 加收藏：先拉收藏夹列表，有则弹选择框（JM 网络收藏支持多收藏夹）。
    final foldersRes = await JmNetwork().getFolders();
    if (!context.mounted) return;

    String? folderId;
    if (!foldersRes.error && foldersRes.data.isNotEmpty) {
      folderId = await showDialog<String>(
        context: context,
        builder: (_) => _JmFolderSelectDialog(folders: foldersRes.data),
      );
      if (folderId == null || !context.mounted) return; // 用户取消
    } else {
      folderId = ''; // 无收藏夹或获取失败 → 默认夹
    }

    final res = await JmNetwork().setFavorite(data.id, add: true);
    if (!context.mounted) return;
    if (!res.error && folderId.isNotEmpty) {
      await JmNetwork().moveFavoriteToFolder(data.id, folderId);
      if (!context.mounted) return;
    }
    if (res.error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('操作失败: ${res.errorMessageWithoutNull}')),
      );
    } else {
      refreshFavorite(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('收藏成功')),
      );
    }
  }

  @override
  Future<bool> loadFavoriteState(JmComicInfo data) async {
    return data.isFavourite;
  }

  @override
  Future<bool> loadLikeState(JmComicInfo data) async {
    return data.isLiked;
  }

  // === 可选功能 ===

  @override
  void Function(BuildContext context, JmComicInfo data)? get onLike =>
      (context, data) async {
        if (currentLiked) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已经点过赞了')),
          );
          return;
        }

        final res = await JmNetwork().likeComic(data.id);
        if (!context.mounted) return;

        if (res.error) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('点赞失败: ${res.errorMessageWithoutNull}')),
          );
        } else {
          refreshLiked(true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('点赞成功')),
          );
        }
      };

  @override
  void Function(BuildContext context, JmComicInfo data)? get onComment =>
      (context, data) {
        Navigator.of(context).push(
          AppPageRoute(
            builder: (_) => JmCommentsPageV2(
              comicId: data.id,
              totalComments: data.comments,
            ),
          ),
        );
      };

  @override
  void Function(BuildContext context, JmComicInfo data)? get onShare =>
      (context, data) {
        Share.share('${data.title}\nhttps://18comic.vip/album/${data.id}');
      };

  @override
  void onRecommendationTap(BuildContext context, JmComicInfo data, int index) {
    if (data.relatedComics.isEmpty || index >= data.relatedComics.length) {
      return;
    }

    final item = data.relatedComics[index];
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => JmComicPageV2(item.id),
      ),
    );
  }

  // ── 相似搜索（jm 无 subTitle，始终用 title）────────────────────────────

  @override
  void Function(BuildContext context, JmComicInfo data)? get onSearchSimilar =>
      (context, data) {
        final source = ComicSource.find(sourceKey);
        if (source == null) return;
        final keyword =
            '"${data.title.replaceAll(RegExp(r'\[.*?\]'), '').replaceAll(RegExp(r'\(.*?\)'), '').trim()}"';
        Navigator.of(context).push(
          AppPageRoute(
            builder: (_) => OnlineSearchResultPage(
              source: source,
              keyword: keyword,
              option: '',
            ),
          ),
        );
      };

  // ── 已下载检测（与下载队列 taskId / 本地库 ID 一致）─────────────────────

  @override
  List<String>? downloadCandidateIds(JmComicInfo data) => ['jm${data.id}'];
}

/// JM 网络收藏夹选择弹窗。返回选中的收藏夹 id（'' = 默认夹），取消返回 null。
class _JmFolderSelectDialog extends StatelessWidget {
  const _JmFolderSelectDialog({required this.folders});

  final List<JmFolder> folders;

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: const Text('选择收藏夹'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(''),
          child: const Text('默认收藏夹'),
        ),
        for (final f in folders)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(f.id),
            child: Text(f.name),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(
            '取消',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
