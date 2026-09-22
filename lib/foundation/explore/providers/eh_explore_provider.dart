/// E-Hentai / ExHentai 探索适配器。
///
/// 站点口径：主页 / 分类 / 搜索跟随**当前选择站点**（settings[20]）；
/// **榜单固定取自表站** toplist，页面需要向用户说明这一点。
library;

import 'package:picakeep/foundation/explore/explore_error_mapping.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_provider.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/tools/tags_translation.dart';

/// EH 探索入口 ID。
class EhExploreEntries {
  static const home = 'eh.home';
  static const popular = 'eh.popular';
  static const ranking = 'eh.ranking';
  static const categories = 'eh.categories';
  static const tags = 'eh.tags';

  /// 标签搜索入口前缀：`eh.tag:<namespace>:<原始词>`。
  static const tagPrefix = 'eh.tag:';
}

/// 榜单选项：沿用站点真实榜期标签（**不改写「昨天」**）。
const List<ExploreOption> ehRankingOptions = <ExploreOption>[
  ExploreOption(id: 'yesterday', label: '昨天'),
  ExploreOption(id: 'month', label: '本月'),
  ExploreOption(id: 'year', label: '今年'),
  ExploreOption(id: 'all', label: '全部'),
];

/// namespace 标签目录分组（顺序与原项目一致）。
const List<({String namespace, String title})> ehTagNamespaces =
    <({String namespace, String title})>[
  (namespace: 'male', title: '男性'),
  (namespace: 'female', title: '女性'),
  (namespace: 'parody', title: '原作'),
  (namespace: 'character', title: '角色'),
  (namespace: 'mixed', title: '混合'),
  (namespace: 'artist', title: '画师'),
  (namespace: 'group', title: '社团'),
  (namespace: 'cosplayer', title: 'cosplay'),
  (namespace: 'other', title: '其它'),
];

/// 由翻译表取得的 namespace 标签原始键快照。
///
/// [loadTags] 每次调用时现取（不在注册时一次性捕获 Map）：翻译表加载完成后会
/// 替换 Map，首次为空不能永久缓存。
typedef EhTagSnapshotLoader = Map<String, List<String>> Function();

class EhExploreProvider implements ExploreProvider {
  EhExploreProvider({
    required this.isLoggedInGetter,
    required this.contextFingerprintGetter,
    required this.siteBaseUrlGetter,
    EhTagSnapshotLoader? tagSnapshotLoader,
    EhNetwork? network,
  })  : _network = network ?? EhNetwork(),
        _tagSnapshotLoader = tagSnapshotLoader ?? _defaultTagSnapshot;

  final bool Function() isLoggedInGetter;
  final String Function() contextFingerprintGetter;

  /// 当前站点根（表站 / 里站），实时读取，不缓存快照。
  final String Function() siteBaseUrlGetter;

  final EhTagSnapshotLoader _tagSnapshotLoader;
  final EhNetwork _network;

  @override
  bool get isLoggedIn => isLoggedInGetter();

  @override
  String get contextFingerprint => contextFingerprintGetter();

  /// 该源的能力声明。**纯声明、无副作用**，故做成静态常量：
  /// 测试可以脱离实例（因而不触发真实网络单例）直接断言。
  static const ExploreSourceDescriptor descriptorOf = ExploreSourceDescriptor(
    sourceKey: 'ehentai',
    name: 'E-Hentai',
    requiresLogin: true,
    entries: <ExploreEntry>[
      ExploreEntry(
        id: EhExploreEntries.home,
        label: '主页',
        kind: ExploreSectionKind.recommend,
      ),
      ExploreEntry(
        id: EhExploreEntries.popular,
        label: '热门',
        kind: ExploreSectionKind.recommend,
      ),
      ExploreEntry(
        id: EhExploreEntries.ranking,
        label: '榜单',
        kind: ExploreSectionKind.ranking,
        options: ehRankingOptions,
        defaultOptionId: 'yesterday',
        description: '固定来自表站 toplist',
      ),
      ExploreEntry(
        id: EhExploreEntries.categories,
        label: '画廊类型',
        kind: ExploreSectionKind.category,
      ),
      ExploreEntry(
        id: EhExploreEntries.tags,
        label: '标签',
        kind: ExploreSectionKind.category,
        description: '本地标签目录，非远端全量',
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
      case EhExploreEntries.categories:
        return ExploreSuccess(_galleryTypeDirectory());
      case EhExploreEntries.tags:
        return _loadTagDirectory();
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
    return const ExploreFailure(
      ExploreError(ExploreErrorCode.unsupported, 'EH 没有概览入口'),
    );
  }

  @override
  Future<ExploreResult<ExploreComicPage>> loadComics(
    ExploreRequest request,
  ) async {
    switch (request.entryId) {
      case EhExploreEntries.home:
        return _loadList(request, () => _network.getHomeGalleries());
      case EhExploreEntries.popular:
        return _loadList(request, () => _network.getPopularGalleries());
      case EhExploreEntries.ranking:
        return _loadRanking(request);
      default:
        if (request.entryId.startsWith(EhExploreEntries.tagPrefix)) {
          return _loadTagSearch(request);
        }
        return _loadCategory(request);
    }
  }

  ExploreDirectory _galleryTypeDirectory() {
    return ExploreDirectory(
      sourceKey: 'ehentai',
      groups: <ExploreCategoryGroup>[
        ExploreCategoryGroup(
          id: 'galleryType',
          title: '画廊类型',
          items: <ExploreCategoryItem>[
            const ExploreCategoryItem(
              id: 'all',
              label: '全部',
              route: ExploreCategoryTarget(kind: 'galleryType', value: 'all'),
            ),
            for (final category in EhGalleryCategory.values)
              ExploreCategoryItem(
                id: category.name,
                label: category.label,
                route: ExploreCategoryTarget(
                  kind: 'galleryType',
                  value: category.name,
                ),
              ),
          ],
        ),
      ],
    );
  }

  ExploreResult<ExploreDirectory> _loadTagDirectory() {
    final snapshot = _tagSnapshotLoader();
    final groups = <ExploreCategoryGroup>[];
    for (final namespace in ehTagNamespaces) {
      final rawTags = snapshot[namespace.namespace];
      if (rawTags == null || rawTags.isEmpty) continue;
      groups.add(ExploreCategoryGroup(
        id: namespace.namespace,
        title: namespace.title,
        isSearch: true,
        items: <ExploreCategoryItem>[
          for (final raw in rawTags)
            ExploreCategoryItem(
              id: '${namespace.namespace}:$raw',
              // 显示名与请求原始词分离：label 给界面，route.value 才是请求值。
              label: raw,
              groupId: namespace.namespace,
              isSearch: true,
              route: ExploreCategoryTarget(
                kind: 'search',
                value: raw,
                optionId: namespace.namespace,
              ),
            ),
        ],
      ));
    }
    // 翻译表未就绪时 groups 为空：只影响标签分区，其它目录/榜单照常。
    return ExploreSuccess(
      ExploreDirectory(sourceKey: 'ehentai', groups: groups),
    );
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
    final category =
        route.value == 'all' ? null : EhGalleryCategory.tryFromId(route.value);
    if (route.value != 'all' && category == null) {
      return ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '未知画廊类型：${route.value}'),
      );
    }
    final res = await _network.getCategoryGalleries(category);
    return _pageFromGalleries(request, res);
  }

  Future<ExploreResult<ExploreComicPage>> _loadTagSearch(
    ExploreRequest request,
  ) async {
    final route = request.category;
    final raw = route?.value.trim() ?? '';
    if (raw.isEmpty) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '缺少标签'),
      );
    }
    final namespace = route?.optionId ?? '';
    final keyword = buildEhTagQuery(namespace: namespace, raw: raw);
    final res = await _network.searchTag(keyword);
    return _pageFromGalleries(request, res);
  }

  Future<ExploreResult<ExploreComicPage>> _loadRanking(
    ExploreRequest request,
  ) async {
    final periodId = request.options.first ?? ehRankingOptions.first.id;
    final period = EhToplistPeriod.tryFromId(periodId);
    if (period == null) {
      return ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '未知榜期：$periodId'),
      );
    }
    // 首页 p=0；续页用站点自身分页 DOM 解析出的 next 链接（而不是页码推算），
    // 避免站点改页容量/导航结构后我们算错页。
    final cursor = request.continuation;
    if (cursor != null && cursor.isNotEmpty) {
      final res = await _network.getGalleries(cursor, leaderboard: true);
      return _pageFromGalleries(request, res);
    }
    final res = await _network.getToplist(period, page: 0);
    return _pageFromGalleries(request, res);
  }

  Future<ExploreResult<ExploreComicPage>> _loadList(
    ExploreRequest request,
    Future<Res<Galleries>> Function() loader,
  ) async {
    if (request.continuation == null) {
      final res = await loader();
      return _pageFromGalleries(request, res);
    }
    // EH 的续页游标就是站点给的 next 链接本身（Registry 负责把它包成
    // 绑定会话/源/入口/选项/分类的 opaque 句柄）。
    final url = request.continuation!;
    final res = await _network.getGalleries(url);
    return _pageFromGalleries(request, res);
  }

  ExploreResult<ExploreComicPage> _pageFromGalleries(
    ExploreRequest request,
    Res<Galleries> res,
  ) {
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    final data = res.data;
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'ehentai',
      entryId: request.entryId,
      items: List<BaseComic>.from(data.galleries),
      nextToken: data.next,
    ));
  }
}

/// 组装 EH 标签查询词。
///
/// - [namespace] 为空时只发原词（角色桶与原项目一致走普通 search）；
/// - 含空格 / 标点 / 引号的多词标签用双引号精确匹配，并去掉内部引号。
String buildEhTagQuery({required String namespace, required String raw}) {
  final tag = raw.trim();
  final needsQuotes = RegExp(r'[\s.,\[\]()&|]').hasMatch(tag);
  final cleaned = tag.replaceAll('"', '').trim();
  // `$` 是 EH 的"精确匹配"后缀，多词/带标点时必须加。
  final value = needsQuotes ? '"$cleaned"\$' : cleaned;
  return namespace.isEmpty ? value : '$namespace:$value';
}

Map<String, List<String>> _defaultTagSnapshot() {
  return <String, List<String>>{
    for (final namespace in ehTagNamespaces)
      namespace.namespace: _tagsOfNamespace(namespace.namespace),
  };
}

/// 从共享翻译表取某个 namespace 的原始键快照。
///
/// 本项目只有一份 `tagTranslations`（namespace → {原文: 译文}），没有原项目那种
/// 按桶拆开的 `maleTags` / `artistTags` 表，因此这里按 namespace 现取。
/// 表未加载时返回空列表：该分区显示为空并可重试，其它分区照常。
List<String> _tagsOfNamespace(String namespace) {
  try {
    final table = tagTranslations[namespace];
    if (table == null || table.isEmpty) return const <String>[];
    return table.keys.toList(growable: false);
  } catch (_) {
    return const <String>[];
  }
}
