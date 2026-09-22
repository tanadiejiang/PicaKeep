/// Picacg 探索适配器。
library;

import 'package:picakeep/foundation/explore/explore_error_mapping.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_provider.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';

/// Picacg 探索入口 ID。
class PicacgExploreEntries {
  static const home = 'picacg.home';
  static const latest = 'picacg.latest';
  static const random = 'picacg.random';
  static const ranking = 'picacg.ranking';
  static const categories = 'picacg.categories';
  static const collections = 'picacg.collections';

  /// 推荐集合分组入口前缀：`picacg.collection:<index>`。
  static const collectionPrefix = 'picacg.collection:';
}

const List<ExploreOption> picacgSortOptions = <ExploreOption>[
  ExploreOption(id: 'dd', label: '新到旧'),
  ExploreOption(id: 'da', label: '旧到新'),
  ExploreOption(id: 'ld', label: '最多喜欢'),
  ExploreOption(id: 'vd', label: '最多指名'),
];

/// 真实榜期：**没有总榜**。
const List<ExploreOption> picacgRankingOptions = <ExploreOption>[
  ExploreOption(id: 'H24', label: '24小时'),
  ExploreOption(id: 'D7', label: '7天'),
  ExploreOption(id: 'D30', label: '30天'),
];

class PicacgExploreProvider implements ExploreProvider {
  PicacgExploreProvider({
    required this.isLoggedInGetter,
    required this.contextFingerprintGetter,
    PicacgNetwork? network,
  }) : _network = network ?? PicacgNetwork();

  final bool Function() isLoggedInGetter;
  final String Function() contextFingerprintGetter;
  final PicacgNetwork _network;

  @override
  bool get isLoggedIn => isLoggedInGetter();

  @override
  String get contextFingerprint => contextFingerprintGetter();

  /// 该源的能力声明。**纯声明、无副作用**，故做成静态常量：
  /// 测试可以脱离实例（因而不触发真实网络单例）直接断言。
  static const ExploreSourceDescriptor descriptorOf = ExploreSourceDescriptor(
    sourceKey: 'picacg',
    name: 'Picacg',
    requiresLogin: true,
    entries: <ExploreEntry>[
      ExploreEntry(
        id: PicacgExploreEntries.home,
        label: '推荐',
        kind: ExploreSectionKind.recommend,
        description: '最新 + 随机换一批',
      ),
      ExploreEntry(
        id: PicacgExploreEntries.latest,
        label: '最新',
        kind: ExploreSectionKind.recommend,
      ),
      ExploreEntry(
        id: PicacgExploreEntries.random,
        label: '随机',
        kind: ExploreSectionKind.recommend,
        singlePage: true,
        description: '单页，刷新即换一批',
      ),
      ExploreEntry(
        id: PicacgExploreEntries.ranking,
        label: '榜单',
        kind: ExploreSectionKind.ranking,
        options: picacgRankingOptions,
        defaultOptionId: 'H24',
        // 单页：`_loadRanking()` 恒不返回 nextToken。必须在这里显式声明，
        // 否则 Registry 会放行续页请求、而适配器只会重取第 1 页，表现为
        // "滚动加载更多却拿到同一页"。
        singlePage: true,
        description: '单页，不再请求下一页',
      ),
      ExploreEntry(
        id: PicacgExploreEntries.categories,
        label: '分类',
        kind: ExploreSectionKind.category,
        options: picacgSortOptions,
        defaultOptionId: 'dd',
      ),
      ExploreEntry(
        id: PicacgExploreEntries.collections,
        label: '推荐集合',
        kind: ExploreSectionKind.recommend,
      ),
      ExploreEntry(
        id: 'picacg.collectionDetail',
        label: '集合内容',
        kind: ExploreSectionKind.recommend,
        singlePage: true,
        supportsRefresh: false,
        // 只能由推荐集合分区的「更多」进入，不是独立页签。
        availableAsTab: false,
      ),
    ],
  );

  @override
  ExploreSourceDescriptor get descriptor => descriptorOf;

  @override
  Future<ExploreResult<ExploreDirectory>> loadDirectory(
    ExploreRequest request,
  ) async {
    if (request.entryId != PicacgExploreEntries.categories) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.unsupported, '该入口没有分类目录'),
      );
    }
    final res = await _network.getCategories();
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    // 过滤外部网页类；分类展示可翻译，但 `c` 始终传服务器原始 title。
    final items = <ExploreCategoryItem>[
      for (final category in res.data)
        if (!category.isWeb)
          ExploreCategoryItem(
            id: 'cat:${category.title}',
            label: category.title,
            route: ExploreCategoryTarget(
              kind: 'native',
              value: category.title,
              optionId: picacgSortOptions.first.id,
            ),
          ),
    ];
    return ExploreSuccess(ExploreDirectory(
      sourceKey: 'picacg',
      groups: <ExploreCategoryGroup>[
        ExploreCategoryGroup(id: 'categories', title: '分类', items: items),
      ],
    ));
  }

  @override
  Future<ExploreResult<ExploreOverview>> loadOverview(
    ExploreRequest request,
  ) async {
    switch (request.entryId) {
      case PicacgExploreEntries.home:
        return _loadHomeOverview();
      case PicacgExploreEntries.collections:
        return _loadCollectionsOverview();
      default:
        return const ExploreFailure(
          ExploreError(ExploreErrorCode.unsupported, '该入口不是概览'),
        );
    }
  }

  Future<ExploreResult<ExploreOverview>> _loadHomeOverview() async {
    // 两个分区的错误互相隔离：单个失败不抹掉另一个成功分区。
    final results = await Future.wait(<Future<Object>>[
      _network.getLatest(1),
      _network.getRandomComics(),
    ]);
    final latestRes = results[0] as dynamic;
    final randomRes = results[1] as dynamic;

    ExploreSection section(
      String id,
      String title,
      String entryId,
      dynamic res,
      bool singlePage,
    ) {
      final error = res.error == true ? exploreErrorFromRes(res) : null;
      final items = res.error == true
          ? const <BaseComic>[]
          : List<BaseComic>.from(res.dataOrNull ?? const []);
      return ExploreSection(
        id: id,
        title: title,
        entryId: entryId,
        items: items,
        error: error,
        isSinglePage: singlePage,
        moreEntryId: singlePage ? null : entryId,
      );
    }

    return ExploreSuccess(ExploreOverview(
      sourceKey: 'picacg',
      entryId: PicacgExploreEntries.home,
      sections: <ExploreSection>[
        section('latest', '最新', PicacgExploreEntries.latest, latestRes, false),
        section('random', '随机', PicacgExploreEntries.random, randomRes, true),
      ],
    ));
  }

  @override
  Future<ExploreResult<ExploreComicPage>> loadComics(
    ExploreRequest request,
  ) async {
    switch (request.entryId) {
      case PicacgExploreEntries.home:
        return const ExploreFailure(
          ExploreError(ExploreErrorCode.unsupported, '请使用推荐概览接口'),
        );
      case PicacgExploreEntries.latest:
        return _loadLatest(request);
      case PicacgExploreEntries.random:
        return _loadRandom(request);
      case PicacgExploreEntries.ranking:
        return _loadRanking(request);
      case PicacgExploreEntries.collections:
        // 推荐集合是"多组概览"：由 loadOverview 返回按组分区。
        return const ExploreFailure(
          ExploreError(ExploreErrorCode.unsupported, '请使用推荐集合概览接口'),
        );
      case 'picacg.collectionDetail':
        return _loadCollectionDetail(request);
      default:
        return _loadCategory(request);
    }
  }

  Future<ExploreResult<ExploreComicPage>> _loadLatest(
    ExploreRequest request,
  ) async {
    final page = _pageOf(request);
    final res = await _network.getLatest(page);
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    final totalPages = _intOrNull(res.subData);
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'picacg',
      entryId: request.entryId,
      items: List<BaseComic>.from(res.data),
      nextToken: totalPages != null && page < totalPages ? '${page + 1}' : null,
      totalPages: totalPages,
    ));
  }

  Future<ExploreResult<ExploreComicPage>> _loadRandom(
    ExploreRequest request,
  ) async {
    final res = await _network.getRandomComics();
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    // 随机是单页：刷新替换当前批次，不建立假分页。
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'picacg',
      entryId: request.entryId,
      items: List<BaseComic>.from(res.data),
      nextToken: null,
    ));
  }

  Future<ExploreResult<ExploreComicPage>> _loadRanking(
    ExploreRequest request,
  ) async {
    final period = request.options.first ?? picacgRankingOptions.first.id;
    if (!picacgLeaderboardPeriods.contains(period)) {
      return ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '未知榜期：$period'),
      );
    }
    final res = await _network.getLeaderboard(period);
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'picacg',
      entryId: request.entryId,
      items: List<BaseComic>.from(res.data),
      optionId: period,
      // 单页：滚动不再请求下一页。
      nextToken: null,
    ));
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
    final sortId =
        request.options.first ?? route.optionId ?? picacgSortOptions.first.id;
    if (!picacgSorts.contains(sortId)) {
      return ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '未知排序：$sortId'),
      );
    }
    final page = _pageOf(request);
    final res = await _network.getCategoryComics(route.value, sortId, page);
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    final totalPages = _intOrNull(res.subData);
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'picacg',
      entryId: request.entryId,
      items: List<BaseComic>.from(res.data),
      optionId: sortId,
      categoryId: request.categoryId,
      nextToken: totalPages != null && page < totalPages ? '${page + 1}' : null,
      totalPages: totalPages,
    ));
  }

  Future<ExploreResult<ExploreOverview>> _loadCollectionsOverview() async {
    final initialContext = contextFingerprint;
    final res = await _network.getCollections();
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    if (initialContext != contextFingerprint) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '账号已变化，请刷新推荐集合'),
      );
    }
    return ExploreSuccess(ExploreOverview(
      sourceKey: 'picacg',
      entryId: PicacgExploreEntries.collections,
      sections: <ExploreSection>[
        for (final collection in res.data)
          ExploreSection(
            id: collection.id,
            title: collection.title,
            // 组内单页：点「更多」进入集合详情页展示整组。
            entryId: 'picacg.collectionDetail',
            items: List<BaseComic>.from(collection.comics),
            isSinglePage: true,
            moreEntryId: 'picacg.collectionDetail',
            moreTarget: ExploreCategoryTarget(
              kind: 'collectionSnapshot',
              value: collection.id,
              snapshotItems: List<BaseComic>.unmodifiable(collection.comics),
              contextKey: initialContext.hashCode.toString(),
            ),
          ),
      ],
    ));
  }

  Future<ExploreResult<ExploreComicPage>> _loadCollectionDetail(
    ExploreRequest request,
  ) async {
    final target = request.category;
    if (target?.kind != 'collectionSnapshot' ||
        target?.snapshotItems == null ||
        target?.contextKey != contextFingerprint.hashCode.toString()) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '推荐集合已失效'),
      );
    }
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'picacg',
      entryId: request.entryId,
      items: target!.snapshotItems!,
      categoryId: target.value,
      nextToken: null,
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
