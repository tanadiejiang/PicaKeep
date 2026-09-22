/// Nhentai 探索的纯映射与查询组装。
///
/// **不放**在 `nhentai_main_network.dart` 里：那个文件依赖 Flutter（`dart:ui` 系
/// 的 DOM/UI 类型），一旦被纯 Dart 测试 import 就会牵连整棵 Flutter 依赖树，
/// 使 `dart test` 无法运行。这里只保留不依赖 Flutter 的常量与纯函数。
library;

/// 探索使用的**裸稳定 option ID**。
class NhentaiSortOptionIds {
  static const recent = 'recent';
  static const popularToday = 'popular-today';
  static const popularWeek = 'popular-week';
  static const popularMonth = 'popular-month';
  static const popularAll = 'popular';

  static const all = <String>[
    recent,
    popularToday,
    popularWeek,
    popularMonth,
    popularAll,
  ];
}

/// 裸稳定 option ID → v2 API 的 `sort` 查询参数值。
///
/// 集中一处映射，避免把裸值直接喂给只认旧 `&sort=` 前缀的兼容解析器
/// （那会静默把"今日热门"降级成"最新"）。
const Map<String, String> nhentaiSortOptionIdToParam = <String, String>{
  NhentaiSortOptionIds.recent: 'date',
  NhentaiSortOptionIds.popularToday: 'popular-today',
  NhentaiSortOptionIds.popularWeek: 'popular-week',
  NhentaiSortOptionIds.popularMonth: 'popular-month',
  NhentaiSortOptionIds.popularAll: 'popular',
};

/// 裸稳定 option ID → v2 sort 参数；未知返回 `null`（不静默回落）。
String? nhentaiSortParamForOptionId(String optionId) =>
    nhentaiSortOptionIdToParam[optionId.trim()];

/// 该 option ID 是否属于四档热门榜单（不含"最新"）。
bool isNhentaiRankingOptionId(String optionId) {
  final normalized = optionId.trim();
  return normalized != NhentaiSortOptionIds.recent &&
      nhentaiSortOptionIdToParam.containsKey(normalized);
}

/// NH 语言分类。**只允许这三种**，分别生成单个 `language:<tag>` 查询。
class NhentaiLanguageIds {
  static const chinese = 'chinese';
  static const japanese = 'japanese';
  static const english = 'english';

  static const all = <String>[chinese, japanese, english];
}

/// 把本地标签组装成 NH 查询词。
///
/// 规则：
/// - 单词 → 原样；
/// - 多词 / 含空格 / 含点号 → 双引号精确匹配，内部引号去掉
///   （NH 不支持转义引号）；
/// - 空词 → `null`（调用方报 invalidArgument）。
///
/// 返回的是**原始词**（英文 / 日文原名），调用方不得传中文翻译。
String? buildNhentaiTagQuery(String rawTag) {
  final tag = rawTag.trim();
  if (tag.isEmpty) return null;
  final cleaned = tag.replaceAll('"', '').trim();
  if (cleaned.isEmpty) return null;
  if (cleaned.contains(' ') || cleaned.contains('-') || cleaned.contains('.')) {
    return '"$cleaned"';
  }
  return cleaned;
}
