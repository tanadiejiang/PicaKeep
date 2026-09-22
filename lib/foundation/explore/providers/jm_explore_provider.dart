/// 禁漫（JM）探索适配器。
///
/// 职责边界：把 [ExploreRequest] 翻译成 `JmNetwork` 调用、把响应包成探索契约。
/// **不**持有 Widget / BuildContext；登录态与上下文指纹由注入的闭包实时读取。
library;

import 'dart:convert';

import 'package:picakeep/foundation/explore/explore_error_mapping.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_provider.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/res.dart';

/// JM 探索入口 ID。
class JmExploreEntries {
  static const home = 'jm.home';
  static const latest = 'jm.latest';
  static const ranking = 'jm.ranking';
  static const categories = 'jm.categories';
  static const week = 'jm.week';
  static const topicTags = 'jm.topicTags';
  static const promoteMore = 'jm.promoteMore';
}

/// JM 分类排序选项（与 [JmComicsOrder] 一一对应）。
const List<ExploreOption> jmOrderOptions = <ExploreOption>[
  ExploreOption(id: 'mr', label: '最新'),
  ExploreOption(id: 'mv', label: '总排行'),
  ExploreOption(id: 'mv_m', label: '月排行'),
  ExploreOption(id: 'mv_w', label: '周排行'),
  ExploreOption(id: 'mv_t', label: '日排行'),
  ExploreOption(id: 'mp', label: '最多图片'),
  ExploreOption(id: 'tf', label: '最多喜欢'),
];

/// 榜单选项：只保留四种真实排行。
const List<ExploreOption> jmRankingOptions = <ExploreOption>[
  ExploreOption(id: 'mv', label: '总排行'),
  ExploreOption(id: 'mv_m', label: '月排行'),
  ExploreOption(id: 'mv_w', label: '周排行'),
  ExploreOption(id: 'mv_t', label: '日排行'),
];

const List<ExploreOption> jmWeekTypeOptions = <ExploreOption>[
  ExploreOption(id: 'hanman', label: '韩漫'),
  ExploreOption(id: 'manga', label: '漫画'),
  ExploreOption(id: 'another', label: '其他'),
];

/// 原项目的固定分类目录；展示目录不依赖 `/categories` 的在线响应。
const Map<String, String> jmNativeCategories = <String, String>{
  '最新A漫': '0',
  '同人': 'doujin',
  '單本': 'single',
  '短篇': 'short',
  '其他類': 'another',
  '韓漫': 'hanman',
  '美漫': 'meiman',
  'Cosplay': 'another_cosplay',
  '3D': '3D',
  '禁漫漢化組': '禁漫漢化組',
};

/// 原项目固定主题词分组：目标是**具名搜索**，不与 slug 分类混为一谈。
const Map<String, List<String>> jmTopicTagGroups = <String, List<String>>{
  '主題A漫': <String>[
    '無修正',
    '劇情向',
    '青年漫',
    '校服',
    '純愛',
    '人妻',
    '教師',
    '百合',
    'Yaoi',
    '性轉',
    'NTR',
    '女裝',
    '癡女',
    '全彩',
    '女性向',
    '完結',
    '純愛',
    '禁漫漢化組',
  ],
  '角色扮演': <String>[
    '御姐',
    '熟女',
    '巨乳',
    '貧乳',
    '女性支配',
    '教師',
    '女僕',
    '護士',
    '泳裝',
    '眼鏡',
    '連褲襪',
    '其他制服',
    '兔女郎',
  ],
  '特殊PLAY': <String>[
    '群交',
    '足交',
    '束縛',
    '肛交',
    '阿黑顏',
    '藥物',
    '扶他',
    '調教',
    '野外露出',
    '催眠',
    '自慰',
    '觸手',
    '獸交',
    '亞人',
    '怪物女孩',
    '皮物',
    'ryona',
    '騎大車',
  ],
  '其它': <String>['CG', '重口', '獵奇', '非H', '血腥暴力', '站長推薦'],
};

/// 单页页容量兜底：站点未给总页数时，用"本页原始条数 < 该值"判定末页。
const int jmDefaultPageSize = 80;

class JmExploreProvider implements ExploreProvider {
  JmExploreProvider({
    required this.isLoggedInGetter,
    required this.contextFingerprintGetter,
    JmNetwork? network,
  }) : _network = network ?? JmNetwork();

  final bool Function() isLoggedInGetter;
  final String Function() contextFingerprintGetter;
  final JmNetwork _network;

  @override
  bool get isLoggedIn => isLoggedInGetter();

  @override
  String get contextFingerprint => contextFingerprintGetter();

  /// 该源的能力声明。**纯声明、无副作用**，故做成静态常量：
  /// 测试可以脱离实例（因而不触发真实网络单例）直接断言。
  static const ExploreSourceDescriptor descriptorOf = ExploreSourceDescriptor(
    sourceKey: 'jm',
    name: '禁漫',
    requiresLogin: true,
    entries: <ExploreEntry>[
      ExploreEntry(
        id: JmExploreEntries.home,
        label: '主页推荐',
        kind: ExploreSectionKind.recommend,
        description: '站点推荐分区概览',
      ),
      ExploreEntry(
        id: JmExploreEntries.latest,
        label: '最新',
        kind: ExploreSectionKind.recommend,
      ),
      ExploreEntry(
        id: JmExploreEntries.ranking,
        label: '榜单',
        kind: ExploreSectionKind.ranking,
        options: jmRankingOptions,
        defaultOptionId: 'mv',
        description: '统一使用 c=0（全站）',
      ),
      ExploreEntry(
        id: JmExploreEntries.categories,
        label: '分类',
        kind: ExploreSectionKind.category,
        options: jmOrderOptions,
        defaultOptionId: 'mr',
      ),
      ExploreEntry(
        id: JmExploreEntries.week,
        label: '每周推荐',
        kind: ExploreSectionKind.recommend,
        directoryAsTab: true,
        options: jmWeekTypeOptions,
        // 原值就是 `jmWeekTypeOptions.first.id`（== 'hanman'）；常量表达式里
        // 不能调用 `first`，故写成等值字面量，让整份描述符保持真 const。
        defaultOptionId: 'hanman',
        description: '编辑推荐，非周榜',
      ),
      ExploreEntry(
        id: JmExploreEntries.topicTags,
        label: '主题标签',
        kind: ExploreSectionKind.category,
        description: '具名搜索，非原生分类',
      ),
      ExploreEntry(
        id: JmExploreEntries.promoteMore,
        label: '推荐更多',
        kind: ExploreSectionKind.recommend,
        supportsRefresh: false,
        // 只能由概览分区的「更多」进入，不是独立页签。
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
    switch (request.entryId) {
      case JmExploreEntries.categories:
        return ExploreSuccess(_nativeDirectory());
      case JmExploreEntries.topicTags:
        return ExploreSuccess(_topicTagDirectory());
      case JmExploreEntries.week:
        final res = await _network.getWeekPeriods();
        if (res.error) return ExploreFailure(exploreErrorFromRes(res));
        return ExploreSuccess(ExploreDirectory(
          sourceKey: 'jm',
          groups: [
            ExploreCategoryGroup(
              id: 'periods',
              title: '每周推荐期号',
              items: [
                for (final period in res.data)
                  ExploreCategoryItem(
                    id: period.id,
                    label: period.time,
                    route:
                        ExploreCategoryTarget(kind: 'week', value: period.id),
                  ),
              ],
            ),
          ],
        ));
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
    if (request.entryId != JmExploreEntries.home) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.unsupported, '该入口不是概览'),
      );
    }
    final res = await _network.getPromoteSections();
    if (res.error) {
      return ExploreFailure(exploreErrorFromRes(res));
    }
    final sections = <ExploreSection>[];
    for (final section in res.data) {
      // 「更多」的入口必须是**描述符里已声明的静态入口**：Registry 会按入口 ID
      // 校验，动态拼出的 `jm.more:<id>` 不在描述符里，会在校验阶段被拒。
      // 具体块 ID 走会话内目标（category）传递，而不是当成持久入口身份。
      final moreId = switch (section.type) {
        'promote' when section.id.isNotEmpty => JmExploreEntries.promoteMore,
        'category_id' when section.slug.isNotEmpty =>
          JmExploreEntries.categories,
        _ => null,
      };
      sections.add(ExploreSection(
        id: section.id.isEmpty ? section.title : section.id,
        title: section.title,
        entryId: JmExploreEntries.home,
        items: List<BaseComic>.from(section.comics),
        moreEntryId: moreId,
        moreTarget: moreId == null
            ? null
            : ExploreCategoryTarget(
                kind: section.type == 'category_id' ? 'native' : 'section',
                value:
                    section.type == 'category_id' ? section.slug : section.id,
              ),
      ));
    }
    return ExploreSuccess(ExploreOverview(
      sourceKey: 'jm',
      entryId: JmExploreEntries.home,
      sections: sections,
    ));
  }

  @override
  Future<ExploreResult<ExploreComicPage>> loadComics(
    ExploreRequest request,
  ) async {
    switch (request.entryId) {
      case JmExploreEntries.home:
        // 概览入口自身不接受续页：首屏分区由 loadOverview 提供。
        return const ExploreFailure(
          ExploreError(ExploreErrorCode.unsupported, '请使用推荐概览接口'),
        );
      case JmExploreEntries.latest:
        return _loadLatest(request);
      case JmExploreEntries.ranking:
        return _loadRanking(request);
      case JmExploreEntries.week:
        return _loadWeek(request);
      case JmExploreEntries.promoteMore:
        return _loadPromoteMore(request);
      default:
        return _loadCategory(request);
    }
  }

  // ── 各入口实现 ────────────────────────────────────────────────────────────

  ExploreDirectory _nativeDirectory() => ExploreDirectory(
        sourceKey: 'jm',
        groups: <ExploreCategoryGroup>[
          ExploreCategoryGroup(
            id: 'native',
            title: '成人A漫',
            items: <ExploreCategoryItem>[
              for (final category in jmNativeCategories.entries)
                ExploreCategoryItem(
                  id: 'native:${category.value}',
                  label: category.key,
                  route: ExploreCategoryTarget(
                      kind: 'native', value: category.value),
                ),
            ],
          ),
        ],
      );

  ExploreDirectory _topicTagDirectory() {
    return ExploreDirectory(
      sourceKey: 'jm',
      groups: <ExploreCategoryGroup>[
        for (final entry in jmTopicTagGroups.entries)
          ExploreCategoryGroup(
            id: entry.key,
            title: entry.key,
            isSearch: true,
            items: <ExploreCategoryItem>[
              for (final tag in entry.value)
                ExploreCategoryItem(
                  id: 'tag:$tag',
                  label: tag,
                  isSearch: true,
                  route: ExploreCategoryTarget(kind: 'search', value: tag),
                ),
            ],
          ),
      ],
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
    final orderId = request.options.first ??
        request.category?.optionId ??
        jmOrderOptions.first.id;
    final order = JmComicsOrder.tryFromValue(orderId);
    if (order == null) {
      return ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '未知排序：$orderId'),
      );
    }
    // 具名搜索：走搜索接口，**不写用户搜索历史**（搜索历史由手工搜索维护）。
    if (route.kind == 'search') {
      final res =
          await _network.search(route.value, order.value, _pageOf(request));
      if (res.error) return ExploreFailure(exploreErrorFromRes(res));
      return ExploreSuccess(ExploreComicPage(
        sourceKey: 'jm',
        entryId: request.entryId,
        items: List<BaseComic>.from(res.data),
        optionId: orderId,
        categoryId: request.categoryId,
        nextToken: _nextPageCursor(res, _pageOf(request)),
      ));
    }
    // 原生分类：c=<原始 slug>。
    final slug = route.value.trim() == '' ? '0' : route.value.trim();
    return _loadNativePage(request, slug, order);
  }

  Future<ExploreResult<ExploreComicPage>> _loadRanking(
    ExploreRequest request,
  ) async {
    final orderId = request.options.first ?? 'mv';
    final order = JmComicsOrder.tryFromValue(orderId);
    if (order == null || !jmRankingOptions.any((o) => o.id == orderId)) {
      return ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '未知榜期：$orderId'),
      );
    }
    // 榜单固定 c=0（全站），不走空搜索试探。
    return _loadNativePage(request, '0', order);
  }

  Future<ExploreResult<ExploreComicPage>> _loadNativePage(
    ExploreRequest request,
    String slug,
    JmComicsOrder order,
  ) async {
    var page = 1;
    var loaded = 0;
    String? previousIds;
    final cursor = request.continuation;
    if (cursor != null) {
      try {
        final decoded = jsonDecode(cursor) as Map;
        page = decoded['page'] as int;
        loaded = decoded['loaded'] as int;
        previousIds = decoded['ids'] as String?;
        if (page < 1 || loaded < 0) throw const FormatException();
      } catch (_) {
        return const ExploreFailure(
          ExploreError(ExploreErrorCode.invalidArgument, '分类分页游标无效'),
        );
      }
    }
    final res = await _network.getCategoryComics(slug, order, page);
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    final ids = res.data.map((comic) => comic.id).join(',');
    if (ids.isNotEmpty && ids == previousIds) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.parse, '分类接口重复返回上一页，请刷新'),
      );
    }
    final metadata = res.subData;
    final rawCount = metadata is Map
        ? _intOrNull(metadata['rawCount']) ?? res.data.length
        : res.data.length;
    final total = metadata is Map ? _intOrNull(metadata['total']) : null;
    final consumed = loaded + rawCount;
    final hasMore =
        rawCount > 0 && (total == null || total <= 0 || consumed < total);
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'jm',
      entryId: request.entryId,
      items: List<BaseComic>.from(res.data),
      optionId: order.value,
      categoryId: request.categoryId,
      nextToken: hasMore
          ? jsonEncode({'page': page + 1, 'loaded': consumed, 'ids': ids})
          : null,
    ));
  }

  Future<ExploreResult<ExploreComicPage>> _loadLatest(
    ExploreRequest request,
  ) async {
    final page = _pageOf(request);
    final res = await _network.getLatest(page);
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    // 该接口没有总数：`subData == 1` 表示站点明确给了空页 → 终止；
    // 否则用"本页是否有内容"作为可继续信号。
    final emptyPage = res.subData == 1;
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'jm',
      entryId: request.entryId,
      items: List<BaseComic>.from(res.data),
      nextToken: emptyPage ? null : '${page + 1}',
    ));
  }

  Future<ExploreResult<ExploreComicPage>> _loadWeek(
    ExploreRequest request,
  ) async {
    final typeId = request.options.first ?? jmWeekTypeOptions.first.id;
    final type = JmWeekType.tryFromValue(typeId);
    if (type == null) {
      return ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '未知推荐类型：$typeId'),
      );
    }
    final periodId = request.category?.value.trim() ?? '';
    final periodsRes = await _network.getWeekPeriods();
    if (periodsRes.error) {
      return ExploreFailure(exploreErrorFromRes(periodsRes));
    }
    if (periodsRes.data.isEmpty) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.parse, '每周推荐期号为空'),
      );
    }
    final matching = periodsRes.data.where((p) => p.id == periodId);
    if (periodId.isNotEmpty && matching.isEmpty) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '推荐期号已失效，请刷新目录'),
      );
    }
    final period = periodId.isEmpty ? periodsRes.data.first : matching.first;
    final res = await _network.getWeekComics(period.id, type);
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'jm',
      entryId: request.entryId,
      items: List<BaseComic>.from(res.data),
      optionId: typeId,
      categoryId: period.id,
      // 每周推荐内容单页。
      nextToken: null,
    ));
  }

  Future<ExploreResult<ExploreComicPage>> _loadPromoteMore(
    ExploreRequest request,
  ) async {
    // 推荐块 ID 是**会话内目标**（来自概览分区），不是持久入口身份：
    // 父页面没带上目标就明确报错，不去猜一个块，也不把索引当 ID。
    final id = request.category?.value.trim() ?? '';
    if (id.isEmpty) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '缺少推荐块 ID'),
      );
    }
    var page = 0;
    var loaded = 0;
    String? previousIds;
    final cursor = request.continuation;
    if (cursor != null) {
      try {
        final decoded = jsonDecode(cursor) as Map;
        page = decoded['page'] as int;
        loaded = decoded['loaded'] as int;
        previousIds = decoded['ids'] as String?;
        if (page < 0 || loaded < 0) throw const FormatException();
      } catch (_) {
        return const ExploreFailure(
          ExploreError(ExploreErrorCode.invalidArgument, '推荐分页游标无效'),
        );
      }
    }
    final res = await _network.getPromoteList(id, page);
    if (res.error) return ExploreFailure(exploreErrorFromRes(res));
    final list = res.data;
    final ids = list.comics.map((comic) => comic.id).join(',');
    if (ids.isNotEmpty && ids == previousIds) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.parse, '推荐接口重复返回上一页，请刷新'),
      );
    }
    final consumed = loaded + list.loaded;
    final hasMore =
        list.loaded > 0 && (list.total <= 0 || consumed < list.total);
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'jm',
      entryId: request.entryId,
      items: List<BaseComic>.from(list.comics),
      categoryId: id,
      nextToken: hasMore
          ? jsonEncode({'page': page + 1, 'loaded': consumed, 'ids': ids})
          : null,
    ));
  }

  // ── 工具 ──────────────────────────────────────────────────────────────────

  int _pageOf(ExploreRequest request) {
    final cursor = request.continuation;
    if (cursor == null || cursor.isEmpty) return 1;
    final parsed = int.tryParse(cursor);
    return parsed == null || parsed < 1 ? 1 : parsed;
  }

  /// 续页游标：只有站点给了总页数且当前页未到末页时才继续。
  ///
  /// 用 `totalPages` 判定**不放大末页**：分母在 JM 网络层已按原始记录数计算。
  String? _nextPageCursor(Res<Object?> res, int page) {
    final total = _intOrNull(res.subData);
    if (total == null) return null;
    return page < total ? '${page + 1}' : null;
  }

  static int? _intOrNull(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }
}
