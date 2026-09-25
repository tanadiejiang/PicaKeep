/// Komiic 探索适配器。
///
/// 语义区分（与站点真实接口一一对应）：
/// - **最近更新** = `recentUpdate` + `orderBy: DATE_UPDATED`（推荐类，非榜单）；
/// - **榜单** = `hotComics` 两档：`MONTH_VIEWS`（月榜）/ `VIEWS`（综合榜）；
/// - **分类** = `comicByCategories`，分类 ID 取站点原始表（见
///   `komiic_explore_categories.dart`）；`categoryId == '0'` 表示「全部」，
///   网络层据此传空数组。
///
/// 分页：探索列表接口（`recentUpdate` / `hotComics` / `comicByCategories`）都接受
/// `pagination`，故本适配器全部支持续页。**例外是搜索** ——
/// `searchComicsAndAuthors` 不接受分页变量，因此本适配器不声明搜索入口，
/// 需要搜索时走项目的在线搜索页（那里已有"仅第一页"的提示）。
///
/// 登录：Komiic **未登录也能浏览**列表 / 榜单 / 分类（站点对匿名请求返回公共
/// 数据），所以描述符 `requiresLogin: false`；登录态只影响收藏这类账号内能力。
///
/// `asc` 一律沿用网络层默认值（`true`），**不显式翻转**：
/// 站点把 `recentUpdate` / `hotComics` 这两个 operation 的排序语义内建在 operation
/// 名里，`asc` 对它们不产生"由新到旧 / 由旧到新"的翻转效果。这一点已由两个独立
/// 参考实现证实 —— Aidoku 的 `zh.komiic` 源码对这两个 operation 固定下发
/// `asc: true`（`comic_list_query`），而对 `comicByCategories` 用 `asc: false`。
/// 网络层 `getComicsByCategory` 走的就是后一条路径，因此分类侧无需适配器干预。
library;

import 'package:picakeep/foundation/explore/explore_error_mapping.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_provider.dart';
import 'package:picakeep/foundation/explore/providers/komiic_explore_categories.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/komiic_network/komiic_network.dart';
import 'package:picakeep/network/res.dart';

export 'package:picakeep/foundation/explore/providers/komiic_explore_categories.dart';

/// Komiic 探索入口 ID。
class KomiicExploreEntries {
  /// 概览：把「最近更新」与「月榜」并成首屏两段。
  static const home = 'komiic.home';

  /// 最近更新（推荐类）。
  static const recent = 'komiic.recent';

  /// 榜单（`hotComics` 两档）。
  static const ranking = 'komiic.ranking';

  /// 分类（原生分类目录 + 排序/状态筛选）。
  static const categories = 'komiic.categories';
}

/// 榜单选项：两档真实排序，**沿用站点口径**（月榜 / 综合榜）。
const List<ExploreOption> komiicRankingOptions = <ExploreOption>[
  ExploreOption(id: KomiicRankingOptionIds.monthViews, label: '月榜'),
  ExploreOption(id: KomiicRankingOptionIds.views, label: '综合榜'),
];

/// 分类入口的**扁平选项表**：排序 × 状态的笛卡尔积，9 项。
///
/// 为什么扁平而不是"排序 + 状态"两个入口：
/// `ExploreRegistry.validate` 只规范化 `ExploreOptions.first` 并把请求重写成
/// `ExploreOptions.single(...)`，一个入口**只有一个**能穿过 Registry 的选项位。
/// 拆成两个入口则无法同时生效，拆成两个 option 则后者被静默丢弃。
///
/// 因此这里把组合编码进单个 ID（`<排序>|<状态>`，见 [KomiicCategoryFilter]），
/// 保证「喜爱数 + 完结」这类真实查询能一次表达清楚。
///
/// 显式展开而不是用 collection-`for`：`descriptorOf` 必须是**真 const**（测试要
/// 脱离实例直接断言），而 `const` 列表不支持 `for` 元素。
const List<ExploreOption> komiicCategoryFilterOptions = <ExploreOption>[
  ExploreOption(id: 'updated|all', label: '更新·全部'),
  ExploreOption(id: 'updated|ongoing', label: '更新·连载中'),
  ExploreOption(id: 'updated|ended', label: '更新·完结'),
  ExploreOption(id: 'views|all', label: '观看数·全部'),
  ExploreOption(id: 'views|ongoing', label: '观看数·连载中'),
  ExploreOption(id: 'views|ended', label: '观看数·完结'),
  ExploreOption(id: 'favorites|all', label: '喜爱数·全部'),
  ExploreOption(id: 'favorites|ongoing', label: '喜爱数·连载中'),
  ExploreOption(id: 'favorites|ended', label: '喜爱数·完结'),
];

/// 分类入口的默认筛选：更新 + 全部。
const String komiicDefaultCategoryFilter = 'updated|all';

class KomiicExploreProvider implements ExploreProvider {
  KomiicExploreProvider({
    required this.isLoggedInGetter,
    required this.contextFingerprintGetter,
    KomiicNetwork? network,
  }) : _network = network ?? KomiicNetwork();

  final bool Function() isLoggedInGetter;
  final String Function() contextFingerprintGetter;
  final KomiicNetwork _network;

  @override
  bool get isLoggedIn => isLoggedInGetter();

  @override
  String get contextFingerprint => contextFingerprintGetter();

  /// 该源的能力声明。**纯声明、无副作用**，故做成静态常量：
  /// 测试可以脱离实例（因而不触发真实网络单例）直接断言。
  static const ExploreSourceDescriptor descriptorOf = ExploreSourceDescriptor(
    sourceKey: 'komiic',
    name: 'Komiic',
    // 站点未登录也能浏览列表 / 榜单 / 分类；登录只影响收藏等账号内能力。
    requiresLogin: false,
    entries: <ExploreEntry>[
      ExploreEntry(
        id: KomiicExploreEntries.home,
        label: '推荐',
        kind: ExploreSectionKind.recommend,
        description: '最近更新 + 月榜概览',
      ),
      ExploreEntry(
        id: KomiicExploreEntries.recent,
        label: '最近更新',
        kind: ExploreSectionKind.recommend,
        description: '按更新日期倒序',
      ),
      ExploreEntry(
        id: KomiicExploreEntries.ranking,
        label: '榜单',
        kind: ExploreSectionKind.ranking,
        options: komiicRankingOptions,
        // 常量表达式里不能调 `first`，故写等值字面量，让整份描述符保持真 const。
        defaultOptionId: KomiicRankingOptionIds.monthViews,
        description: '热门榜：月榜 / 综合榜',
      ),
      ExploreEntry(
        id: KomiicExploreEntries.categories,
        label: '分类',
        kind: ExploreSectionKind.category,
        options: komiicCategoryFilterOptions,
        defaultOptionId: komiicDefaultCategoryFilter,
        description: '站点原生分类，可换排序与连载状态',
      ),
    ],
  );

  @override
  ExploreSourceDescriptor get descriptor => descriptorOf;

  @override
  Future<ExploreResult<ExploreDirectory>> loadDirectory(
    ExploreRequest request,
  ) async {
    if (request.entryId != KomiicExploreEntries.categories) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.unsupported, '该入口没有分类目录'),
      );
    }
    // 目录不需要联网：分类 ID 表是站点固定枚举，本地即可展示。
    return ExploreSuccess(ExploreDirectory(
      sourceKey: 'komiic',
      groups: <ExploreCategoryGroup>[
        ExploreCategoryGroup(
          id: 'categories',
          title: '分类',
          items: <ExploreCategoryItem>[
            for (final category in komiicCategories)
              ExploreCategoryItem(
                id: 'category:${category.key}',
                label: category.label,
                // 路由值是**站点 ID**，不是本地 key：网络层只认站点 ID。
                route: ExploreCategoryTarget(
                  kind: 'native',
                  value: category.id,
                  optionId: komiicDefaultCategoryFilter,
                ),
              ),
          ],
        ),
      ],
    ));
  }

  @override
  Future<ExploreResult<ExploreOverview>> loadOverview(
    ExploreRequest request,
  ) async {
    if (request.entryId != KomiicExploreEntries.home) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.unsupported, '该入口不是概览'),
      );
    }
    // 两个分区并发取，错误互相隔离：一个失败不抹掉另一个成功分区。
    final results = await Future.wait(<Future<Object>>[
      _network.getComicList(
        operationName: KomiicOperations.recentUpdate,
        page: 1,
      ),
      _network.getComicList(
        operationName: KomiicOperations.hotComics,
        page: 1,
        // 概览的榜单段固定月榜；走同一张映射表，避免与榜单入口漂移成不同档位。
        orderBy: komiicRankingOrderByForOptionId(
          KomiicRankingOptionIds.monthViews,
        )!,
      ),
    ]);
    final recentRes = results[0] as Res<List<KomiicComicBrief>>;
    final rankingRes = results[1] as Res<List<KomiicComicBrief>>;

    ExploreSection section({
      required String id,
      required String title,
      required Res<List<KomiicComicBrief>> res,
      required String moreEntryId,
    }) {
      return ExploreSection(
        id: id,
        title: title,
        entryId: KomiicExploreEntries.home,
        items: res.error ? const <BaseComic>[] : List<BaseComic>.from(res.data),
        error: res.error ? exploreErrorFromRes(res) : null,
        moreEntryId: moreEntryId,
      );
    }

    return ExploreSuccess(ExploreOverview(
      sourceKey: 'komiic',
      entryId: KomiicExploreEntries.home,
      sections: <ExploreSection>[
        section(
          id: 'recent',
          title: '最近更新',
          res: recentRes,
          moreEntryId: KomiicExploreEntries.recent,
        ),
        section(
          id: KomiicRankingOptionIds.monthViews,
          title: '月榜',
          res: rankingRes,
          moreEntryId: KomiicExploreEntries.ranking,
        ),
      ],
    ));
  }

  @override
  Future<ExploreResult<ExploreComicPage>> loadComics(
    ExploreRequest request,
  ) async {
    switch (request.entryId) {
      case KomiicExploreEntries.home:
        // 概览入口自身不接受续页：首屏分区由 loadOverview 提供。
        return const ExploreFailure(
          ExploreError(ExploreErrorCode.unsupported, '请使用推荐概览接口'),
        );
      case KomiicExploreEntries.recent:
        return _loadRecent(request);
      case KomiicExploreEntries.ranking:
        return _loadRanking(request);
      default:
        return _loadCategory(request);
    }
  }

  // ── 各入口实现 ────────────────────────────────────────────────────────────

  Future<ExploreResult<ExploreComicPage>> _loadRecent(
    ExploreRequest request,
  ) async {
    final page = _pageOf(request);
    final res = await _network.getComicList(
      operationName: KomiicOperations.recentUpdate,
      page: page,
      orderBy: 'DATE_UPDATED',
    );
    return _pageFromList(request, res, page);
  }

  Future<ExploreResult<ExploreComicPage>> _loadRanking(
    ExploreRequest request,
  ) async {
    final optionId = request.options.first ?? KomiicRankingOptionIds.monthViews;
    final orderBy = komiicRankingOrderByForOptionId(optionId);
    if (orderBy == null) {
      return ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '未知榜期：$optionId'),
      );
    }
    final page = _pageOf(request);
    final res = await _network.getComicList(
      operationName: KomiicOperations.hotComics,
      page: page,
      orderBy: orderBy,
    );
    return _pageFromList(request, res, page, optionId: optionId);
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
    // 路由值是站点分类 ID；'0'（全部）也在表内，因此无需特判。
    final category = komiicCategoryById(route.value);
    if (category == null) {
      return ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '未知分类：${route.value}'),
      );
    }
    // 筛选来源优先级：请求选项 > 分类目标携带的 optionId > 默认值。
    final rawFilter =
        request.options.first ?? route.optionId ?? komiicDefaultCategoryFilter;
    final filter = KomiicCategoryFilter.decode(rawFilter);
    if (filter == null) {
      return ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '未知筛选：$rawFilter'),
      );
    }
    final page = _pageOf(request);
    final res = await _network.getComicsByCategory(
      categoryId: category.id,
      page: page,
      orderBy: filter.orderBy,
      status: filter.status,
    );
    return _pageFromList(request, res, page, optionId: filter.optionId);
  }

  /// 列表响应 → 探索漫画页。
  ///
  /// 判停协议见 [KomiicNetwork.getComicList]：网络层把 `subData` 设为
  /// **不满一页时的当前页数**，满页时不传。因此：
  /// - `subData == null` → 本页满页（后面可能还有）→ 发下一页码；
  /// - `subData != null` → 站点已明确到底 → 不发续页。
  ///
  /// 这与"本页条数 == 页容量就继续猜"不同：后者在恰好整除时会多发一次空请求，
  /// 并在站点把总数藏起来时永远停不下来。
  ExploreResult<ExploreComicPage> _pageFromList(
    ExploreRequest request,
    Res<List<KomiicComicBrief>> res,
    int page, {
    String? optionId,
  }) {
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    final lastPage = res.subData != null;
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'komiic',
      entryId: request.entryId,
      items: List<BaseComic>.from(res.data),
      optionId: optionId,
      categoryId: request.categoryId,
      nextToken: lastPage ? null : '${page + 1}',
      totalPages: lastPage ? page : null,
    ));
  }

  int _pageOf(ExploreRequest request) {
    final cursor = request.continuation;
    if (cursor == null || cursor.isEmpty) return 1;
    final parsed = int.tryParse(cursor);
    return parsed == null || parsed < 1 ? 1 : parsed;
  }
}
