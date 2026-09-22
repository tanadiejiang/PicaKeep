/// Nhentai 探索适配器。
///
/// 语义区分（重要）：
/// - 首页 **Popular 是推荐块**，不是榜期；
/// - 四档热门走 v2 search 的排序参数，是榜单；
/// - 随机是单本、无分页。
library;

import 'package:picakeep/foundation/explore/explore_error_mapping.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_provider.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/network/nhentai_network/tags.dart';
import 'package:picakeep/network/res.dart';

/// NH 探索入口 ID。
class NhentaiExploreEntries {
  static const home = 'nh.home';
  static const latest = 'nh.latest';
  static const ranking = 'nh.ranking';
  static const languages = 'nh.languages';
  static const tags = 'nh.tags';
  static const random = 'nh.random';

  /// 标签搜索入口前缀：`nh.tag:<原始词>`。
  static const tagPrefix = 'nh.tag:';
}

const List<ExploreOption> nhentaiSortOptions = <ExploreOption>[
  ExploreOption(id: 'recent', label: '最新'),
  ExploreOption(id: 'popular-today', label: '今日热门'),
  ExploreOption(id: 'popular-week', label: '本周热门'),
  ExploreOption(id: 'popular-month', label: '本月热门'),
  ExploreOption(id: 'popular', label: '全部热门'),
];

/// 榜单选项：四档热门（**不含"最新"**）。
const List<ExploreOption> nhentaiRankingOptions = <ExploreOption>[
  ExploreOption(id: 'popular-today', label: '今日'),
  ExploreOption(id: 'popular-week', label: '本周'),
  ExploreOption(id: 'popular-month', label: '本月'),
  ExploreOption(id: 'popular', label: '全部'),
];

class NhentaiExploreProvider implements ExploreProvider {
  NhentaiExploreProvider({
    required this.isLoggedInGetter,
    required this.contextFingerprintGetter,
    NhentaiNetwork? network,
  }) : _network = network ?? NhentaiNetwork();

  final bool Function() isLoggedInGetter;
  final String Function() contextFingerprintGetter;
  final NhentaiNetwork _network;

  @override
  bool get isLoggedIn => isLoggedInGetter();

  @override
  String get contextFingerprint => contextFingerprintGetter();

  /// 该源的能力声明。**纯声明、无副作用**，故做成静态常量：
  /// 测试可以脱离实例（因而不触发真实网络单例）直接断言。
  static const ExploreSourceDescriptor descriptorOf = ExploreSourceDescriptor(
    sourceKey: 'nhentai',
    name: 'Nhentai',
    requiresLogin: true,
    entries: <ExploreEntry>[
      ExploreEntry(
        id: NhentaiExploreEntries.home,
        label: '主页',
        kind: ExploreSectionKind.recommend,
        description: 'Popular 推荐块 + 最新',
      ),
      ExploreEntry(
        id: NhentaiExploreEntries.latest,
        label: '最新',
        kind: ExploreSectionKind.recommend,
      ),
      ExploreEntry(
        id: NhentaiExploreEntries.ranking,
        label: '榜单',
        kind: ExploreSectionKind.ranking,
        options: nhentaiRankingOptions,
        defaultOptionId: 'popular-today',
        description: 'v2 热门排序',
      ),
      ExploreEntry(
        id: NhentaiExploreEntries.languages,
        label: '语言',
        kind: ExploreSectionKind.category,
      ),
      ExploreEntry(
        id: NhentaiExploreEntries.tags,
        label: '标签',
        kind: ExploreSectionKind.category,
        description: '本地标签目录，具名搜索',
      ),
      ExploreEntry(
        id: NhentaiExploreEntries.random,
        label: '随机',
        kind: ExploreSectionKind.recommend,
        singlePage: true,
      ),
    ],
  );

  @override
  ExploreSourceDescriptor get descriptor => descriptorOf;

  @override
  Future<ExploreResult<ExploreDirectory>> loadDirectory(
    ExploreRequest request,
  ) async {
    switch (request.entryId) {
      case NhentaiExploreEntries.languages:
        return ExploreSuccess(ExploreDirectory(
          sourceKey: 'nhentai',
          groups: <ExploreCategoryGroup>[
            ExploreCategoryGroup(
              id: 'languages',
              title: '语言',
              items: <ExploreCategoryItem>[
                for (final language in NhentaiLanguage.values)
                  ExploreCategoryItem(
                    id: language.name,
                    label: language.label,
                    route: ExploreCategoryTarget(
                      kind: 'language',
                      value: language.tag,
                    ),
                  ),
              ],
            ),
          ],
        ));
      case NhentaiExploreEntries.tags:
        return ExploreSuccess(_loadTagDirectory());
      default:
        return const ExploreFailure(
          ExploreError(ExploreErrorCode.unsupported, '该入口没有分类目录'),
        );
    }
  }

  @override
  Future<ExploreResult<ExploreOverview>> loadOverview(
    ExploreRequest request,
  ) async {
    if (request.entryId != NhentaiExploreEntries.home) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.unsupported, '该入口不是概览'),
      );
    }
    final res = await _network.getHomePageData(1);
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    final data = res.data;
    return ExploreSuccess(ExploreOverview(
      sourceKey: 'nhentai',
      entryId: NhentaiExploreEntries.home,
      sections: <ExploreSection>[
        ExploreSection(
          id: 'popular',
          title: 'Popular',
          entryId: NhentaiExploreEntries.home,
          items: List<BaseComic>.from(data.popular),
          error: data.popularError == null
              ? null
              : exploreErrorFromRes(data.popularError!),
          // Popular 是**推荐块**，只在主页第一页出现，不随 latest 续页追加。
          isSinglePage: true,
          moreEntryId: null,
        ),
        ExploreSection(
          id: 'latest',
          title: '最新',
          entryId: NhentaiExploreEntries.latest,
          items: List<BaseComic>.from(data.latest),
          error: data.latestError == null
              ? null
              : exploreErrorFromRes(data.latestError!),
          moreEntryId: NhentaiExploreEntries.latest,
        ),
      ],
    ));
  }

  @override
  Future<ExploreResult<ExploreComicPage>> loadComics(
    ExploreRequest request,
  ) async {
    switch (request.entryId) {
      case NhentaiExploreEntries.home:
        return const ExploreFailure(
          ExploreError(ExploreErrorCode.unsupported, '请使用主页概览接口'),
        );
      case NhentaiExploreEntries.latest:
        return _loadLatest(request);
      case NhentaiExploreEntries.ranking:
        return _loadRanking(request);
      case NhentaiExploreEntries.random:
        return _loadRandom(request);
      default:
        if (request.entryId.startsWith(NhentaiExploreEntries.tagPrefix)) {
          return _loadTagSearch(request);
        }
        return _loadCategory(request);
    }
  }

  ExploreDirectory _loadTagDirectory() {
    final items = <ExploreCategoryItem>[];
    for (final entry in nhentaiTags.entries) {
      final raw = entry.value.trim();
      if (raw.isEmpty) continue;
      items.add(ExploreCategoryItem(
        id: 'tag:${entry.key}',
        // 先显示原名：译名加载失败不能把目录变成空。
        label: raw,
        isSearch: true,
        route: ExploreCategoryTarget(kind: 'search', value: raw),
      ));
    }
    return ExploreDirectory(
      sourceKey: 'nhentai',
      groups: <ExploreCategoryGroup>[
        ExploreCategoryGroup(
          id: 'tags',
          title: '标签（本地目录）',
          isSearch: true,
          items: items,
        ),
      ],
    );
  }

  Future<ExploreResult<ExploreComicPage>> _loadLatest(
    ExploreRequest request,
  ) async {
    final page = _pageOf(request);
    final res = await _network.getLatest(page);
    return _pageFromSearch(request, res, optionId: 'recent');
  }

  Future<ExploreResult<ExploreComicPage>> _loadRanking(
    ExploreRequest request,
  ) async {
    final optionId = request.options.first ?? nhentaiRankingOptions.first.id;
    final sort = nhentaiSortFromOptionId(optionId);
    if (sort == null || sort == NhentaiSort.recent) {
      return ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '未知榜期：$optionId'),
      );
    }
    final res = await _network.getPopularRanking(sort, _pageOf(request));
    return _pageFromSearch(request, res, optionId: optionId);
  }

  Future<ExploreResult<ExploreComicPage>> _loadCategory(
    ExploreRequest request,
  ) async {
    final route = request.category;
    if (route == null || route.value.trim().isEmpty) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '缺少分类目标'),
      );
    }
    final page = _pageOf(request);
    if (route.kind == 'language') {
      final language = NhentaiLanguage.tryFromId(route.value);
      if (language == null) {
        return ExploreFailure(
          ExploreError(ExploreErrorCode.invalidArgument, '未知语言：${route.value}'),
        );
      }
      final res = await _network.getLanguageComics(language, page);
      return _pageFromSearch(request, res);
    }
    // 具名搜索：发送原始词，不发送中文翻译。
    final res = await _network.searchTag(route.value, page);
    return _pageFromSearch(request, res);
  }

  Future<ExploreResult<ExploreComicPage>> _loadTagSearch(
    ExploreRequest request,
  ) async {
    final raw = request.category?.value.trim() ?? '';
    if (raw.isEmpty) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '缺少标签'),
      );
    }
    final res = await _network.searchTag(raw, _pageOf(request));
    return _pageFromSearch(request, res);
  }

  Future<ExploreResult<ExploreComicPage>> _loadRandom(
    ExploreRequest request,
  ) async {
    final res = await _network.getRandomComic();
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'nhentai',
      entryId: request.entryId,
      items: <BaseComic>[res.data],
      // 随机是单本，不建立假分页。
      nextToken: null,
    ));
  }

  ExploreResult<ExploreComicPage> _pageFromSearch(
    ExploreRequest request,
    Res<List<NhentaiComicBrief>> res, {
    String? optionId,
  }) {
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    final page = _pageOf(request);
    final totalPages = _intOrNull(res.subData);
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'nhentai',
      entryId: request.entryId,
      items: List<BaseComic>.from(res.data),
      optionId: optionId,
      categoryId: request.categoryId,
      nextToken: totalPages != null && page < totalPages ? '${page + 1}' : null,
      totalPages: totalPages,
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
