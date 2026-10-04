import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/komiic_network/komiic_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/base_online_comic_page.dart';
import 'package:picakeep/pages/online_comic/local_favorite_actions.dart';
import 'package:picakeep/pages/online_comic/online_comic_page_components.dart';
import 'package:picakeep/pages/online_comic/platform_favorite_panel.dart';
import 'chapter_download_selection.dart';
import 'package:picakeep/pages/online_search/online_search_result_page.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

/// Komiic 详情页（基于 [BaseOnlineComicPage]）。
///
/// Komiic 是**有章节的源**（卷 / 话混合），因此本页与 `JmComicPageV2` 同构：
/// 章节区由 [extractEpisodes] 提供，阅读入口把章节序号透传给通用阅读器。
///
/// 关键决策记录：
/// - [sourceKey] 用小写 `'komiic'`：这是 [ComicSource] 注册的 key（决定
///   `comic_source/komiic.data` 文件名与 `ComicSource.find('komiic')` 取 token），
///   也是搜索/封面请求头等基类能力的查找键。
///   而**下载/历史/收藏侧**项目既有代码统一用大写 `'Komiic'`
///   （`download_model.dart` / `history.dart` / `local_favorites.dart`），
///   两套标识由各自的映射分支负责转换，**不在这里混用**：
///   本页发出去的 `sourceKey` 只服务于基类与搜索，历史/收藏走下面的
///   [HistoryType] 与 [FavoriteType] 显式取值。
/// - 所以 [tag] 取 `'komiic_$comicId'`（基类建议的 `'$sourceKey_$id'` 形态），
///   保证同时打开多本详情页时状态容器不串。
class KomiicComicPageV2 extends BaseOnlineComicPage<KomiicComicInfo> {
  const KomiicComicPageV2(this.comicId, {super.key});

  final String comicId;

  // ==========================================================
  // 强制实现：数据加载
  // ==========================================================

  @override
  Future<Res<KomiicComicInfo>> loadData() async {
    // 网络层内部已串好「本体 + 章节 + 推荐」三段并组装成 KomiicComicInfo，
    // 页面层不再自行发 getChapters，避免重复请求与顺序错位。
    return KomiicNetwork().getComicInfo(comicId);
  }

  @override
  String get tag => 'komiic_$comicId';

  // ==========================================================
  // 强制实现：基础信息
  // ==========================================================

  @override
  String get id => comicId;

  /// 小写：`ComicSource.key` 的注册值，用于搜索跳转与 token 读取。
  @override
  String get sourceKey => 'komiic';

  @override
  String get source => 'Komiic';

  @override
  String? extractTitle(KomiicComicInfo data) => data.title;

  @override
  String? extractCover(KomiicComicInfo data) => data.coverUrl;

  /// 多作者用 `', '` 拼接；无作者时返回空串，基类按"无副标题"处理。
  @override
  String? extractSubTitle(KomiicComicInfo data) => data.authors.join(', ');

  @override
  String? extractDescription(KomiicComicInfo data) => data.description;

  /// Komiic 是**章节制**，模型里根本没有总页数（页数要逐章调 `getImages`
  /// 才能得知，代价是 N 次请求，且详情页展示的总页数语义也不成立），
  /// 所以这里固定返回 null —— 基类会隐藏「N 页」这一行。
  @override
  int? extractPages(KomiicComicInfo data) => null;

  @override
  int? extractViews(KomiicComicInfo data) => data.views;

  @override
  int? extractLikes(KomiicComicInfo data) => data.favoriteCount;

  /// 标签区：作品 ID / 作者 / 标签为主，状态与年份顺带放在同一区域（基类没有
  /// 独立的 状态、年份展示位，信息区只渲染来源、页数、浏览量、评论数）。
  /// 空值一律不放该键，对应行由基类自动隐藏（空数组会渲染成空行）。
  ///
  /// `ID` 放最前（与 Pixiv / JM 同范式）：详情页需要能一眼看到并用于跨设备
  /// 定位作品。这里**只放裸 ID**，不拼 `komiic` 前缀 —— 信息区上方已有源标识行
  /// 显示「Komiic」，再加前缀是冗余。
  @override
  Map<String, List<String>>? extractTags(KomiicComicInfo data) {
    return {
      if (data.id.trim().isNotEmpty) 'ID': [data.id],
      if (data.authors.isNotEmpty) '作者': data.authors,
      if (data.tags.isNotEmpty) '标签': data.tags,
      if (data.status.trim().isNotEmpty) '状态': [data.status],
      if (data.year.trim().isNotEmpty) '年份': [data.year],
    };
  }

  // ==========================================================
  // 可选重写：章节与推荐
  // ==========================================================

  /// 章节展示名：普通话直接用 `serial`，卷（`type == 'book'`）是
  /// `卷{serial}` —— 这个规则由 [KomiicChapter.displayName] 统一提供，
  /// 页面不再自行拼串，避免与阅读器 `KomiicReadingData` 的展示口径分叉。
  ///
  /// 顺序即阅读器索引：阅读器用 `ep - 1` 反查章节 id，所以这里必须保持
  /// `data.chapters` 的原始顺序（不要排序/去重）。
  /// 空列表返回 null，基类隐藏整个章节区。
  @override
  List<String>? extractEpisodes(KomiicComicInfo data) {
    if (data.chapters.isEmpty) return null;
    return data.chapters.map((chapter) => chapter.displayName).toList();
  }

  @override
  List<OnlineComicRecommendation>? extractRecommendation(
    KomiicComicInfo data,
  ) {
    if (data.recommendations.isEmpty) return null;
    return data.recommendations
        .map(
          (comic) => OnlineComicRecommendation(
            title: comic.title,
            cover: comic.cover,
            subTitle: comic.author.isEmpty ? null : comic.author,
          ),
        )
        .toList();
  }

  /// 章节区说明：卷 / 话混排时说明展示口径，避免把「卷3」当成第 3 话。
  ///
  /// 基类的 [episodesSubtitle] 是**无参 getter**（在 build 里取值时拿不到
  /// `data`），所以这里只能给一句固定口径说明，不拼「共 N 章」——
  /// 为了一个数字去缓存 `extractEpisodes` 的调用结果会让无状态页面
  /// 持有可变状态，不值得。
  @override
  String? get episodesSubtitle => '带「卷」前缀为合订本';

  // ==========================================================
  // 图片请求头
  // ==========================================================

  /// Komiic 的 `/api/image/{kid}` 有防盗链校验，必须带站点 Referer 与 UA。
  /// （章节内图片另有更具体的 Referer，由 `KomiicReadingData.loadImageNetwork`
  /// 单独提供。）
  @override
  Map<String, String> get imageHeaders => const {
        'Referer': 'https://komiic.com/',
        'User-Agent': KomiicNetwork.komiicUA,
      };

  // ==========================================================
  // 交互行为
  // ==========================================================

  @override
  void onTagTap(BuildContext context, String tag, String category) {
    // **`ID` 分类例外：点击 = 复制，不跳搜索**。Komiic 的作品 ID 是纯标识符，
    // 当关键词去搜只会得到无关结果；用户点它的真实意图是"复制 ID 去别处用"。
    // 与 Pixiv 详情页对 `ID` 行的处理同一口径。
    if (category == 'ID') {
      final keyword = tag.trim();
      if (keyword.isEmpty) return;
      // 复制先于反馈：await 完成后再提示，避免"提示了却没复制上"。
      unawaited(
        Clipboard.setData(ClipboardData(text: keyword)).then((_) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已复制 ID'),
              duration: Duration(seconds: 1),
            ),
          );
        }),
      );
      return;
    }

    // Komiic 搜索接口只有一个 keyword（无命名空间/排序选项），
    // 因此作者与分类标签都直接当关键词搜，不拼 `category:tag`。
    final source = ComicSource.find(sourceKey);
    if (source == null) return;

    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => OnlineSearchResultPage(
          source: source,
          keyword: tag,
          option: source.searchPageData?.defaultOption ?? '',
        ),
      ),
    );
  }

  @override
  Future<void> onRead(
    BuildContext context,
    KomiicComicInfo data, {
    int ep = 1,
  }) async {
    // 历史 type 取 `'Komiic'.hashCode`：`read_history_helper.dart` 的
    // `_historyTypeForDownload` 对 `DownloadType.komiic` 正是走
    // `HistoryType(c.sourceKey.hashCode)`（sourceKey 为大写 `'Komiic'`），
    // 用 `HistoryType.other` 会让历史行与下载条目对不上、
    // 「已下载」检测静默失效。
    await History.ensureForLocalRead(
      target: data.id,
      type: HistoryType('Komiic'.hashCode),
      title: data.title,
      subtitle: data.authors.join(', '),
      cover: data.coverUrl,
      ep: ep,
    );
    if (!context.mounted) return;
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => ComicReadingPage(
          KomiicReadingData(comic: data),
          1,
          ep,
        ),
      ),
    );
  }

  /// 下载：Komiic 是**章节制**，按章逐页下载（见 `_runKomiicTask`），
  /// 每章写到独立数字目录，落库为 `CustomDownloadedItem`（sourceKey 大写
  /// `'Komiic'`，与历史/收藏侧的既有约定一致）。
  @override
  Future<void> onDownload(BuildContext context, KomiicComicInfo data) async {
    if (data.chapters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该作品没有可下载的章节')),
      );
      return;
    }
    if (supportsChapterDownloads(data)) {
      final added = await showOnlineChapterDownloadSelection(context,
          title: data.title,
          chapterNames: extractEpisodes(data)!,
          sourceKey: sourceKey,
          candidateIds: downloadCandidateIds(data)!,
          onSubmit: (indexes) => OnlineDownloadManager.instance
              .enqueueKomiic(data, chapterIndexes: indexes));
      if (added && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已加入下载队列')));
      }
      return;
    }
    final res = await OnlineDownloadManager.instance
        .enqueueKomiic(data, chapterIndexes: [0]);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            res.error ? '加入下载队列失败：${res.errorMessageWithoutNull}' : '已加入下载队列'),
      ),
    );
  }

  @override
  bool supportsChapterDownloads(KomiicComicInfo data) =>
      data.chapters.length > 1;

  // ── 已下载检测（与下载队列 taskId / 本地库 ID 一致）─────────────────────

  @override
  List<String>? downloadCandidateIds(KomiicComicInfo data) =>
      <String>['komiic${data.id}'];

  /// 收藏：Komiic 是**多收藏夹**模式，无「默认夹」，`addOrDelFavorite`
  /// 必须显式给 folderId，所以统一走 [showPlatformFavoritePanel]（与 JM 同构，
  /// 复用「网络 / 本地」双页签、单选夹 + 打勾、提交结果回传的那套交互）。
  ///
  /// 与 JM 的差异：
  /// - JM 用 toggle 端点 + 单独的「移入收藏夹」接口，因此可以先整体收藏再换夹；
  ///   Komiic 的接口本身就是「把这本书加进某个夹 / 从某个夹移除」，
  ///   所以提交时直接把用户选中的 folderId 传下去，不需要二次移动。
  /// - Komiic 没有默认夹，`folderId` 为空即视为用户没选夹 → 直接判失败，
  ///   不能像 JM 那样用空串表达默认夹（否则会发一个 folderId="" 的坏请求）。
  @override
  Future<void> onFavorite(
    BuildContext context,
    KomiicComicInfo data,
  ) async {
    final network = KomiicNetwork();
    final localItem = FavoriteItem(
      target: data.id,
      name: data.title,
      coverPath: data.coverUrl,
      author: data.authors.join(', '),
      type: FavoriteType.komiic,
      tags: data.tags,
    );
    final wasFavorite = currentFavorite;

    if (!network.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录 Komiic 后再收藏')),
      );
      return;
    }

    // 打开面板前先查这本书已在哪些夹，用于回传"当前已收藏"给面板，
    // 让已收藏时底部按钮直接是「取消收藏」。查询失败按未收藏处理，不阻断面板。
    final currentRes = await network.getComicFolders(data.id);
    if (!context.mounted) return;
    final currentFolderIds =
        currentRes.error ? const <String>[] : currentRes.data;

    final result = await showPlatformFavoritePanel(
      context,
      sourceTitle: 'Komiic',
      localItem: localItem,
      // 面板的「取消收藏」语义是"整体取消"，因此只要落在任一夹即为已收藏；
      // 但 `wasFavorite` 是页面初值（可能过期），与刚查到的最新状态取或。
      isFavorite: wasFavorite || currentFolderIds.isNotEmpty,
      canFavorite: true,
      foldersLoader: () async {
        final res = await network.getFolders();
        if (res.error) {
          return const <FavoriteFolderOption>[];
        }
        // Komiic 无默认夹：这里**不**像 JM 那样额外拼一个空 id 的「默认收藏夹」，
        // 空 id 在服务端是非法 folderId。
        return [
          for (final folder in res.data)
            FavoriteFolderOption(id: folder.id, name: folder.name),
        ];
      },
      foldersErrorText: '收藏夹加载失败',
      onSubmitPlatform: ({String? folderId, required bool favorite}) async {
        if (!favorite) {
          // 取消：这本书可能同时在多个夹里，逐夹移除才算真正取消网络收藏。
          // 只要有一本夹移除失败就报失败，绝不谎报成功。
          if (currentFolderIds.isEmpty) {
            return const PlatformFavoriteSubmitResult.ok();
          }
          for (final id in currentFolderIds) {
            final res = await network.addOrDelFavorite(
              comicId: data.id,
              folderId: id,
              isAdding: false,
            );
            if (res.error) {
              return PlatformFavoriteSubmitResult.failed(
                '取消收藏失败: ${res.errorMessageWithoutNull}',
              );
            }
          }
          return const PlatformFavoriteSubmitResult.ok();
        }

        // 收藏：必须选夹；未选夹时面板本不会进入这里（无变化则不可提交），
        // 这里再兜一层，避免发出 folderId 为空的坏请求。
        if (folderId == null || folderId.isEmpty) {
          return const PlatformFavoriteSubmitResult.failed('请先选择收藏夹');
        }
        final res = await network.addOrDelFavorite(
          comicId: data.id,
          folderId: folderId,
          isAdding: true,
        );
        if (res.error) {
          return PlatformFavoriteSubmitResult.failed(
            '收藏失败: ${res.errorMessageWithoutNull}',
          );
        }
        return const PlatformFavoriteSubmitResult.ok();
      },
    );

    if (!context.mounted || result == null) return;
    switch (result.action) {
      case PlatformFavoriteAction.platformSubmitted:
        // 平台态已确定（面板只在提交成功后才回传目标态），直接刷图标。
        final nowFavorite = result.favoriteTarget ?? wasFavorite;
        refreshFavorite(nowFavorite);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(nowFavorite ? '收藏成功' : '已取消收藏')),
        );
      case PlatformFavoriteAction.localSubmitted:
        final localResult = result.localResult;
        if (localResult != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(localFavoriteSingleMessage(localResult))),
          );
        }
        // 本地收藏不影响平台态，但图标语义是「平台 OR 本地」，重算一次。
        refreshFavorite(wasFavorite || isLocallyFavorited(localItem));
    }
  }

  /// 长按收藏按钮「取消网络收藏」：从该书所在的**所有**夹移除。
  ///
  /// 返回 `true` 而不是 `null` —— 请求成功即"平台收藏已确定没了"，
  /// 基类据此直接熄灭图标；返回 null 会去重读 [loadFavoriteState]，
  /// 而那个接口是实时查询，虽然本例能拿到正确值，但没有必要多一轮请求。
  @override
  Future<bool?> performCancelPlatformFavorite(KomiicComicInfo data) async {
    final network = KomiicNetwork();
    if (!network.isLoggedIn) return false;
    final foldersRes = await network.getComicFolders(data.id);
    if (foldersRes.error) return false;
    final folderIds = foldersRes.data;
    if (folderIds.isEmpty) return true;
    for (final id in folderIds) {
      final res = await network.addOrDelFavorite(
        comicId: data.id,
        folderId: id,
        isAdding: false,
      );
      if (res.error) return false;
    }
    return true;
  }

  /// 收藏态：落在任一收藏夹即为已收藏。
  ///
  /// 未登录直接返回 false（不报错）——未登录时 `comicInAccountFolders` 会
  /// 以鉴权错误返回，那不是"页面出错"，只是"没收藏"。
  @override
  Future<bool> loadFavoriteState(KomiicComicInfo data) async {
    final network = KomiicNetwork();
    if (!network.isLoggedIn) return false;
    final res = await network.getComicFolders(data.id);
    if (res.error) return false;
    return res.data.isNotEmpty;
  }

  // ==========================================================
  // 可选交互
  // ==========================================================

  // onLike / onComment 均保持基类默认 null：Komiic 无点赞与评论接口，
  // 基类据此自动隐藏「喜欢」与「评论」按钮（不必在本子类里显式重写）。

  @override
  void onRecommendationTap(
    BuildContext context,
    KomiicComicInfo data,
    int index,
  ) {
    if (index < 0 || index >= data.recommendations.length) return;
    final item = data.recommendations[index];
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => KomiicComicPageV2(item.id),
      ),
    );
  }

  /// 相似搜索：Komiic 搜索只吃单个关键词，标题里的括号番号等内容会干扰命中，
  /// 因此剥掉 `[...]` / `(...)` 后再加引号做短语搜索。
  @override
  void Function(BuildContext context, KomiicComicInfo data)?
      get onSearchSimilar => (context, data) {
            final source = ComicSource.find(sourceKey);
            if (source == null) return;
            final cleaned = data.title
                .replaceAll(RegExp(r'\[.*?\]'), '')
                .replaceAll(RegExp(r'\(.*?\)'), '')
                .trim();
            final keyword = cleaned.isEmpty ? data.title : '"$cleaned"';
            Navigator.of(context).push(
              AppPageRoute(
                builder: (_) => OnlineSearchResultPage(
                  source: source,
                  keyword: keyword,
                  option: source.searchPageData?.defaultOption ?? '',
                ),
              ),
            );
          };
}
