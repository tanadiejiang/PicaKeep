/// Pixiv 探索适配器（第十八轮新增）。
///
/// 提供三个入口：
/// - **推荐**：Pixiv 首页插画推荐（`/ajax/illust/recommended-nologin` 走游客版，
///   未登录也能看）；
/// - **我的收藏**：当前账号的书签列表（`/ajax/user/{uid}/illusts/bookmarks`），
///   **必须登录**才有 `userId`；
/// - **排行榜**：`ranking.php?format=json`，多档榜期。
///
/// ## 与其它源的两点差异
///
/// 1. **「我的收藏」是登录后才有意义的入口**。其它源的收藏另在「收藏」主页面，
///    这里再放一份是因为用户明确要求"探索页能增加 Pixiv 的我的收藏页"——
///    用处是**在探索语境下直接翻收藏**，不必切到收藏页。
///    未登录时该入口不发请求，直接返回明确的 `loginRequired`。
/// 2. **排行榜固定 `mode` 不含 R-18 档**：`daily_r18`/`weekly_r18` 等需要里站
///    登录态且属高风控内容，本源自用场景只提供安全档，避免选了必然空结果。
library;

import 'package:picakeep/foundation/explore/explore_error_mapping.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_provider.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';

/// Pixiv 探索入口 ID。
class PixivExploreEntries {
  static const recommended = 'pixiv.recommended';
  static const bookmarks = 'pixiv.bookmarks';
  static const ranking = 'pixiv.ranking';
}

/// 排行榜选项。`id` 直接进 `ranking.php` 的 `mode` 参数。
///
/// 不含 `*_r18` 档（需登录且高风险），也不含 `content` 维度——首版固定
/// `content=illust`，把"插画/漫画"的细分留给后续按需扩展。
const List<ExploreOption> pixivRankingOptions = <ExploreOption>[
  ExploreOption(id: 'daily', label: '今日'),
  ExploreOption(id: 'weekly', label: '本周'),
  ExploreOption(id: 'monthly', label: '本月'),
  ExploreOption(id: 'rookie', label: '新人'),
  ExploreOption(id: 'original', label: '原创'),
  ExploreOption(id: 'male', label: '男性向'),
  ExploreOption(id: 'female', label: '女性向'),
];

class PixivExploreProvider implements ExploreProvider {
  PixivExploreProvider({
    required this.isLoggedInGetter,
    required this.contextFingerprintGetter,
    PixivNetwork? network,
  }) : _network = network ?? PixivNetwork();

  final bool Function() isLoggedInGetter;
  final String Function() contextFingerprintGetter;
  final PixivNetwork _network;

  @override
  bool get isLoggedIn => isLoggedInGetter();

  @override
  String get contextFingerprint => contextFingerprintGetter();

  /// 该源的能力声明。**纯声明、无副作用**，测试可脱离实例直接断言。
  ///
  /// `requiresLogin: false` —— Pixiv 的推荐与排行榜游客可见，只有「我的收藏」
  /// 需要登录；若整体标成需要登录，未登录用户会被擋在探索页外，
  /// 连游客能看的内容也拿不到。
  static const ExploreSourceDescriptor descriptorOf = ExploreSourceDescriptor(
    sourceKey: 'pixiv',
    name: 'Pixiv',
    requiresLogin: false,
    entries: <ExploreEntry>[
      ExploreEntry(
        id: PixivExploreEntries.recommended,
        label: '推荐',
        kind: ExploreSectionKind.recommend,
        description: 'Pixiv 首页插画推荐（游客可见）',
      ),
      ExploreEntry(
        id: PixivExploreEntries.bookmarks,
        label: '我的收藏',
        kind: ExploreSectionKind.recommend,
        description: '当前账号的书签列表（需登录）',
      ),
      ExploreEntry(
        id: PixivExploreEntries.ranking,
        label: '排行榜',
        kind: ExploreSectionKind.ranking,
        options: pixivRankingOptions,
        defaultOptionId: 'daily',
        description: 'ranking.php 官方榜单（不含 R-18 档）',
      ),
    ],
  );

  @override
  ExploreSourceDescriptor get descriptor => descriptorOf;

  /// Pixiv 无原生分类目录：三个入口都是列表型，没有"分类下钻"这一层。
  @override
  Future<ExploreResult<ExploreDirectory>> loadDirectory(
    ExploreRequest request,
  ) async {
    return const ExploreFailure(
      ExploreError(ExploreErrorCode.unsupported, 'Pixiv 探索没有分类目录'),
    );
  }

  /// 概览：把「推荐」与「我的收藏」拼成一个双分区主页。
  ///
  /// 两个分区**独立成败**：收藏分区未登录或失败时只让该分区带错误，
  /// 推荐分区照常展示——不因为收藏拿不到就把整页变成错误页。
  @override
  Future<ExploreResult<ExploreOverview>> loadOverview(
    ExploreRequest request,
  ) async {
    if (request.entryId != PixivExploreEntries.recommended) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.unsupported, '该入口不是概览'),
      );
    }

    final recommendedRes = await _network.getRecommended();
    final bookmarkRes = isLoggedIn ? await _network.getBookmarks(1) : null;

    final sections = <ExploreSection>[
      ExploreSection(
        id: 'recommended',
        title: '推荐',
        entryId: PixivExploreEntries.recommended,
        items: recommendedRes.error
            ? const <BaseComic>[]
            : List<BaseComic>.from(recommendedRes.data),
        error:
            recommendedRes.error ? exploreErrorFromRes(recommendedRes) : null,
        // 推荐是单页内容块，不建立续页（首页推荐接口的游标语义不稳定）。
        isSinglePage: true,
        moreEntryId: null,
      ),
      ExploreSection(
        id: 'bookmarks',
        title: '我的收藏',
        entryId: PixivExploreEntries.bookmarks,
        items: (bookmarkRes == null || bookmarkRes.error)
            ? const <BaseComic>[]
            : List<BaseComic>.from(bookmarkRes.data),
        error: bookmarkRes == null
            // 未登录不算"错误"，但要让分区说明为什么空。
            ? const ExploreError(
                ExploreErrorCode.loginRequired,
                '登录后可在此查看 Pixiv 收藏',
              )
            : (bookmarkRes.error ? exploreErrorFromRes(bookmarkRes) : null),
        isSinglePage: true,
        // 「更多」把用户带到收藏入口的完整列表。
        moreEntryId: PixivExploreEntries.bookmarks,
      ),
    ];

    // 两个分区都失败才算整体失败；否则至少有一块能看。
    if (sections.every((section) => section.error != null)) {
      return ExploreFailure(sections.first.error!);
    }

    return ExploreSuccess(ExploreOverview(
      sourceKey: 'pixiv',
      entryId: PixivExploreEntries.recommended,
      sections: sections,
    ));
  }

  @override
  Future<ExploreResult<ExploreComicPage>> loadComics(
    ExploreRequest request,
  ) async {
    switch (request.entryId) {
      case PixivExploreEntries.recommended:
        return _loadRecommended(request);
      case PixivExploreEntries.bookmarks:
        return _loadBookmarks(request);
      case PixivExploreEntries.ranking:
        return _loadRanking(request);
      default:
        return const ExploreFailure(
          ExploreError(ExploreErrorCode.unsupported, '未知入口'),
        );
    }
  }

  Future<ExploreResult<ExploreComicPage>> _loadRecommended(
    ExploreRequest request,
  ) async {
    final res = await _network.getRecommended();
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'pixiv',
      entryId: request.entryId,
      items: List<BaseComic>.from(res.data),
      // 推荐不建续页：该接口没有可靠的页码/游标契约，
      // 伪造分页会让用户以为"还有更多"却永远翻不到新内容。
      nextToken: null,
    ));
  }

  Future<ExploreResult<ExploreComicPage>> _loadBookmarks(
    ExploreRequest request,
  ) async {
    // 未登录直接给 loginRequired，不发必失败的网络请求。
    // 依据：`getBookmarks` 需要 `userId`，未登录时它必然返回 loginRequired，
    // 提前拦截能省一次往返，也避免把"未登录"误显示成"网络错误"。
    if (!isLoggedIn) {
      return const ExploreFailure(
        ExploreError(
          ExploreErrorCode.loginRequired,
          '登录后可在此查看 Pixiv 收藏',
        ),
      );
    }
    final page = _pageOf(request);
    final res = await _network.getBookmarks(page);
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'pixiv',
      entryId: request.entryId,
      items: List<BaseComic>.from(res.data),
      // 注意：`getBookmarks` 放在 subData 里的是**书签总数**（body.total），
      // 不是页数。这里换算成页数再判停；算不出就退回"满页即还有下一页"。
      nextToken: _bookmarkNextToken(res, page),
      totalPages: null,
    ));
  }

  /// 收藏列表的续页判断。
  ///
  /// `Res.subData` 是书签**总数**（`body.total`），需除以每页条数换算页数。
  /// 直接拿它当页数会让"共 200 条收藏、每页 48 条"被当成 200 页，
  /// 用户会一直翻到空白页。算不出总数时退回保守判停。
  String? _bookmarkNextToken(Res<List<PixivComicBrief>> res, int page) {
    const pageSize = PixivNetwork.bookmarkPageSize;
    final total = _intOrNull(res.subData);
    if (total != null) {
      final totalPages = (total + pageSize - 1) ~/ pageSize;
      return page < totalPages ? '${page + 1}' : null;
    }
    return res.data.length >= pageSize ? '${page + 1}' : null;
  }

  Future<ExploreResult<ExploreComicPage>> _loadRanking(
    ExploreRequest request,
  ) async {
    final optionId = request.options.first ?? pixivRankingOptions.first.id;
    // 白名单校验：未知 mode 直接报错，不回落默认档。
    // 回落会让用户选了"新人"却拿到"今日"的结果，且界面无任何提示。
    final known = pixivRankingOptions.any((option) => option.id == optionId);
    if (!known) {
      return ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '未知榜期：$optionId'),
      );
    }
    final page = _pageOf(request);
    final res = await _network.getRanking(mode: optionId, page: page);
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'pixiv',
      entryId: request.entryId,
      items: List<BaseComic>.from(res.data),
      optionId: optionId,
      // ranking.php 每页固定 50 条，故"满页 → 还有下一页"是可靠判停。
      nextToken: res.data.length >= PixivNetwork.rankingPageSize
          ? '${page + 1}'
          : null,
    ));
  }

  int _pageOf(ExploreRequest request) {
    final cursor = request.continuation;
    if (cursor == null || cursor.isEmpty) return 1;
    final parsed = int.tryParse(cursor);
    return parsed == null || parsed < 1 ? 1 : parsed;
  }

  static int? _intOrNull(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }
}
