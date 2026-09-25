/// Komiic 探索的分类目录与选项映射（**纯 Dart，零 Flutter / 网络依赖**）。
///
/// 单独成文件的理由与 `nhentai_explore_options.dart` 相同：分类 ID 表与
/// "裸稳定 option ID → 站点枚举值"的映射需要被纯层测试独立断言，不能被
/// `komiic_network.dart` 牵连出的 Flutter / dio / comic_source 依赖拖住。
///
/// **分类 ID 必须与站点逐字一致**（02 号调研核实）：ID 是 GraphQL `ID` 标量，
/// 改错任何一个都会静默切到别的分类或返回空列表，没有本地兜底。
library;

/// 一个 Komiic 分类：稳定键（本地用）+ 站点分类 ID + 展示名。
///
/// [key] 与 [id] 分开而不是合成一个字符串：分类结果页的路由值必须是站点 ID，
/// 而目录项 ID 需要一个不会被站点 ID 规则变化影响的本地身份。
class KomiicCategory {
  const KomiicCategory({
    required this.key,
    required this.id,
    required this.label,
  });

  /// 本地稳定键（分类 URL / 目录项 ID 用）。
  final String key;

  /// 站点分类 ID；`'0'` 表示「全部」（网络层据此传空数组）。
  final String id;

  final String label;
}

/// Komiic 全部分类的 ID 表（**顺序即站点原始顺序，勿重排**）。
///
/// 「全部」放在首位且 ID 为 `'0'`：它是默认分类，也是榜单/最新的"无筛选"口径。
const List<KomiicCategory> komiicCategories = <KomiicCategory>[
  KomiicCategory(key: 'all', id: '0', label: '全部'),
  KomiicCategory(key: 'love', id: '1', label: '愛情'),
  KomiicCategory(key: 'harem', id: '2', label: '後宮'),
  KomiicCategory(key: 'god', id: '3', label: '神鬼'),
  KomiicCategory(key: 'campus', id: '4', label: '校園'),
  KomiicCategory(key: 'comedy', id: '5', label: '搞笑'),
  KomiicCategory(key: 'life', id: '6', label: '生活'),
  KomiicCategory(key: 'suspense', id: '7', label: '懸疑'),
  KomiicCategory(key: 'adventure', id: '8', label: '冒險'),
  KomiicCategory(key: 'horror', id: '9', label: '恐怖'),
  KomiicCategory(key: 'workplace', id: '10', label: '職場'),
  KomiicCategory(key: 'fantasy', id: '11', label: '魔幻'),
  KomiicCategory(key: 'magic', id: '12', label: '魔法'),
  KomiicCategory(key: 'fighting', id: '13', label: '格鬥'),
  KomiicCategory(key: 'otaku', id: '14', label: '宅男'),
  KomiicCategory(key: 'inspirational', id: '15', label: '勵志'),
  KomiicCategory(key: 'boysLove', id: '16', label: '耽美'),
  KomiicCategory(key: 'sciFi', id: '17', label: '科幻'),
  KomiicCategory(key: 'girlsLove', id: '18', label: '百合'),
  KomiicCategory(key: 'healing', id: '19', label: '治癒'),
  KomiicCategory(key: 'moe', id: '20', label: '萌系'),
  KomiicCategory(key: 'hotBlooded', id: '21', label: '熱血'),
  KomiicCategory(key: 'sports', id: '22', label: '競技'),
  KomiicCategory(key: 'mystery', id: '23', label: '推理'),
  KomiicCategory(key: 'magazine', id: '24', label: '雜誌'),
  KomiicCategory(key: 'detective', id: '25', label: '偵探'),
  KomiicCategory(key: 'crossdress', id: '26', label: '偽娘'),
  KomiicCategory(key: 'gourmet', id: '27', label: '美食'),
  KomiicCategory(key: 'fourPanel', id: '28', label: '四格'),
  KomiicCategory(key: 'society', id: '31', label: '社會'),
  KomiicCategory(key: 'history', id: '32', label: '歷史'),
  KomiicCategory(key: 'war', id: '33', label: '戰爭'),
  KomiicCategory(key: 'dance', id: '34', label: '舞蹈'),
  KomiicCategory(key: 'martialArts', id: '35', label: '武俠'),
  KomiicCategory(key: 'mecha', id: '36', label: '機戰'),
  KomiicCategory(key: 'music', id: '37', label: '音樂'),
  KomiicCategory(key: 'physicalEducation', id: '40', label: '體育'),
  KomiicCategory(key: 'underworld', id: '42', label: '黑道'),
];

/// 按站点 ID 查分类；未知返回 `null`（不静默回落到「全部」）。
KomiicCategory? komiicCategoryById(String id) {
  final normalized = id.trim();
  for (final category in komiicCategories) {
    if (category.id == normalized) return category;
  }
  return null;
}

/// 按本地键查分类；未知返回 `null`。
KomiicCategory? komiicCategoryByKey(String key) {
  final normalized = key.trim();
  for (final category in komiicCategories) {
    if (category.key == normalized) return category;
  }
  return null;
}

/// 「全部」分类的站点 ID（网络层约定：该值表示不筛分类）。
const String komiicAllCategoryId = '0';

/// Komiic 分类排序的**裸 option ID**（不直接暴露站点枚举，避免 UI 与协议耦合）。
class KomiicOrderOptionIds {
  static const updated = 'updated';
  static const views = 'views';
  static const favorites = 'favorites';

  static const all = <String>[updated, views, favorites];
}

/// 裸 option ID → 站点 `orderBy` 枚举值。未知返回 `null`（不静默回落）。
const Map<String, String> komiicOrderByParam = <String, String>{
  KomiicOrderOptionIds.updated: 'DATE_UPDATED',
  KomiicOrderOptionIds.views: 'VIEWS',
  KomiicOrderOptionIds.favorites: 'FAVORITE_COUNT',
};

/// 裸 option ID → `orderBy`；未知返回 `null`。
String? komiicOrderByForOptionId(String optionId) =>
    komiicOrderByParam[optionId.trim()];

/// Komiic 状态的**裸 option ID**。空串是站点的"全部"口径，故单独取名。
class KomiicStatusOptionIds {
  static const all = 'all';
  static const ongoing = 'ongoing';
  static const ended = 'ended';

  static const allIds = <String>[all, ongoing, ended];
}

/// 裸 option ID → 站点 `status` 枚举值；`all` 对应空串。
///
/// 注意值可能是空串，所以不能用"取到 null 即未知"判断未知：改用
/// [komiicHasStatusOptionId]，否则「全部」会被误判成非法选项。
const Map<String, String> komiicStatusParam = <String, String>{
  KomiicStatusOptionIds.all: '',
  KomiicStatusOptionIds.ongoing: 'ONGOING',
  KomiicStatusOptionIds.ended: 'END',
};

/// 该裸 ID 是否是已知状态选项。
bool komiicHasStatusOptionId(String optionId) =>
    komiicStatusParam.containsKey(optionId.trim());

/// 裸 ID → 站点 `status`；未知返回 `null`。
String? komiicStatusForOptionId(String optionId) {
  final normalized = optionId.trim();
  if (!komiicHasStatusOptionId(normalized)) return null;
  return komiicStatusParam[normalized];
}

/// 分类筛选的**复合 option ID**：`<排序>|<状态>`（例如 `views|ongoing`）。
///
/// 为什么是复合而不是两个选项位：`ExploreRegistry.validate` 只规范化
/// `ExploreOptions.first`，并把请求重写成 `ExploreOptions.single(optionId)`。
/// 也就是说一个入口**只有一个**能穿过 Registry 的选项位，拆成"排序 + 状态"
/// 两个 option 会让后者被静默丢弃（或被判成未知选项）。
///
/// 用 `|` 而不是 `+` / `-`：`ORDER_KEYS` / `STATUS_KEYS` 里都是小写字母，
/// 分隔符不会与枚举值冲突，解析也不需要转义。
class KomiicCategoryFilter {
  const KomiicCategoryFilter._();

  static const String separator = '|';

  /// 组装复合 ID；两段都必须是已知裸 ID。
  static String encode({required String orderId, required String statusId}) =>
      '${orderId.trim()}$separator${statusId.trim()}';

  /// 拆解复合 ID。任一段未知即返回 `null`（**不**静默回落默认值：
  /// 回落会把用户明确的"完结 + 喜爱数"变成"全部 + 更新"，是错误的数据）。
  static KomiicCategoryFilterValues? decode(String optionId) {
    final raw = optionId.trim();
    if (raw.isEmpty) return null;
    final parts = raw.split(separator);
    if (parts.length != 2) return null;
    final orderBy = komiicOrderByForOptionId(parts[0]);
    final status = komiicStatusForOptionId(parts[1]);
    if (orderBy == null || status == null) return null;
    return KomiicCategoryFilterValues(
      optionId: raw,
      orderId: parts[0].trim(),
      orderBy: orderBy,
      statusId: parts[1].trim(),
      status: status,
    );
  }
}

/// [KomiicCategoryFilter.decode] 的结果。
class KomiicCategoryFilterValues {
  const KomiicCategoryFilterValues({
    required this.optionId,
    required this.orderId,
    required this.orderBy,
    required this.statusId,
    required this.status,
  });

  /// 原始复合 ID。
  final String optionId;

  final String orderId;

  /// 站点 `orderBy` 枚举值。
  final String orderBy;

  final String statusId;

  /// 站点 `status` 枚举值；`''` 表示全部。
  final String status;
}

/// 榜单档位：Komiic `hotComics` 只有两档真实排序。
class KomiicRankingOptionIds {
  /// 月榜（`MONTH_VIEWS`）。
  static const monthViews = 'monthViews';

  /// 综合榜（`VIEWS`）。
  static const views = 'views';

  static const all = <String>[monthViews, views];
}

/// 裸榜期 ID → `hotComics` 的 `orderBy`。
///
/// 两档都走 `hotComics` operation：档位差异**只**体现在 `orderBy` 上，
/// 不是两个不同接口。
const Map<String, String> komiicRankingOrderBy = <String, String>{
  KomiicRankingOptionIds.monthViews: 'MONTH_VIEWS',
  KomiicRankingOptionIds.views: 'VIEWS',
};

/// 裸榜期 ID → `orderBy`；未知返回 `null`。
String? komiicRankingOrderByForOptionId(String optionId) =>
    komiicRankingOrderBy[optionId.trim()];

/// `hotComics` / `recentUpdate` 的 operationName 常量。
class KomiicOperations {
  static const recentUpdate = 'recentUpdate';
  static const hotComics = 'hotComics';
}
