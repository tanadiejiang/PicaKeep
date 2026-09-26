/// 图集页「插画」视图的**纯逻辑层**：设置下标、归一化、数据装配、标签汇总。
///
/// ## 为什么单独成文件
///
/// 图集页本体是 `lib/pages/local_library_page.dart`（2583 行单文件），把它继续当
/// 杂物间会让 diff 失控（24 号计划「风险或注意事项」第一条）。这里只放**不依赖
/// Flutter widget 的纯函数**，因此可以直接单元测试：数据源过滤判据、宽高降级、
/// 标签汇总都在这层，UI 层只负责画。
///
/// ## 视图与档位是「两条正交的轴」
///
/// 「图集 / 插画」是**视图**（[IllustLibraryView]），它叠加在既有的三档
/// （本地图集 / 聚合 / 远程 · 图集，持久化在 `settings[104]`）之上，
/// 而**不是**替换三档。理由（24 号计划决策 3）：
///
/// - `settings[104]` 的语义是"图集页看哪个来源"，`albumOnly` 的语义是"只看图集目录"，
///   把"插画"塞进二者任何一个都会让既有文案与分支变脆；
/// - 两边**各自保留自己那一档**：切到插画再切回来，图集侧的档位必须原样还在。
///
/// 所以插画侧有自己的档位设置项 [illustLibraryTierSettingIndex]，**不复用
/// `settings[104]`**、也不把它扩成四态。
library;

import 'dart:convert';

import 'package:picakeep/foundation/local_library.dart';

/// `settings[]` 下标：图集页当前视图（`'album'` / `'illust'`）。
///
/// 从 **155** 起：`settings[154]` 已被 23 号计划的 `pixivMultiPageZip` 占用，
/// 在它之前插入会让后面所有下标漂移（24 号计划步骤 2 的硬约束）。
const int illustLibraryViewSettingIndex = 155;

/// [illustLibraryViewSettingIndex] 的取值：图集视图（默认，与改动前一致）。
const String illustLibraryViewAlbum = 'album';

/// [illustLibraryViewSettingIndex] 的取值：插画视图。
const String illustLibraryViewIllust = 'illust';

/// 归一化：只认 `'illust'`，其余（含 null / 空串 / 历史脏值）一律落回图集视图。
///
/// 默认取「图集」而不是「插画」，是为了让"没主动切过视图的用户"与改动前
/// **观感一致**——升级后首次打开图集页不应该突然变成另一种内容。
String normalizeIllustLibraryView(String? value) {
  return value == illustLibraryViewIllust
      ? illustLibraryViewIllust
      : illustLibraryViewAlbum;
}

/// 图集页的两个并列视图。与三档来源（`_LocalLibraryView`）**正交**。
enum IllustLibraryView {
  album,
  illust,
}

IllustLibraryView illustLibraryViewFromSetting(String? value) {
  return normalizeIllustLibraryView(value) == illustLibraryViewIllust
      ? IllustLibraryView.illust
      : IllustLibraryView.album;
}

String illustLibraryViewToSetting(IllustLibraryView view) {
  switch (view) {
    case IllustLibraryView.illust:
      return illustLibraryViewIllust;
    case IllustLibraryView.album:
      return illustLibraryViewAlbum;
  }
}

/// `settings[]` 下标：插画瀑布流列数（`'2'` / `'3'`）。
const int illustWaterfallColumnsSettingIndex = 156;

/// 瀑布流列数范围。上限 3 是用户明确要求（"2~3 列"）；下限 2 是因为 1 列
/// 在手机上等于把瀑布流退化成列表，失去意义。
const int illustWaterfallMinColumns = 2;
const int illustWaterfallMaxColumns = 3;

/// 默认列数。
///
/// 取 3 而非 2：既有卡片密度 `settings[44]` 的默认值是 `'0,1.0'`（详细档 +
/// 1.0 倍大小），对应 `SliverGridDelegateWithComics` 在手机上约 3 列的观感
/// （`lib/components/layout.dart`）。默认值要"沿用当前观感"，取 3 更接近。
const int illustWaterfallDefaultColumns = 3;

int normalizeIllustWaterfallColumns(String? value) {
  final parsed = int.tryParse(value?.trim() ?? '');
  if (parsed == null) {
    return illustWaterfallDefaultColumns;
  }
  if (parsed < illustWaterfallMinColumns) {
    return illustWaterfallMinColumns;
  }
  if (parsed > illustWaterfallMaxColumns) {
    return illustWaterfallMaxColumns;
  }
  return parsed;
}

/// 把 [illustWaterfallColumnsSettingIndex] 归一化成写回 `settings` 的字符串。
String normalizeIllustWaterfallColumnsSetting(String? value) =>
    normalizeIllustWaterfallColumns(value).toString();

/// `settings[]` 下标：视图切换悬浮按钮的位置（`'right'` / `'left'`）。
const int illustViewSwitcherPositionSettingIndex = 157;

const String illustViewSwitcherRight = 'right';
const String illustViewSwitcherLeft = 'left';

/// 归一化：只认 `'left'`，其余一律靠右。
///
/// 靠右是 Flutter `FloatingActionButton` 的默认位置，也是本页既有
/// `_buildMultiSelectFab` 的位置——保持默认值不变，升级后位置不跳。
String normalizeIllustViewSwitcherPosition(String? value) {
  return value == illustViewSwitcherLeft
      ? illustViewSwitcherLeft
      : illustViewSwitcherRight;
}

bool illustViewSwitcherAlignsLeft(String? value) =>
    normalizeIllustViewSwitcherPosition(value) == illustViewSwitcherLeft;

/// 是否显示视图切换悬浮按钮。
///
/// 抽成纯函数是为了能被直接测试：这条判据同时承担两个易错的约束 ——
/// "只在图集形态的根列表上出现"与"多选态下与多选 FAB 互斥"。
/// 混在页面 `build` 里就只能靠肉眼，而这两个约束一旦失效，症状是
/// "子页面里冒出一个按钮"或"两个 FAB 叠在一起"，都是上真机才发现的类型。
///
/// 参数含义：
/// - [albumOnly]：这一页是否是「图集」形态的根列表；
/// - [isLocalRootPage] / [isRemoteRootPage]：是否是点进某个目录/远程根的子页面；
/// - [selecting]：是否处于多选态；
/// - [operationRunning]：是否有删除一类操作正在跑（此时有全屏遮罩）。
bool shouldShowIllustViewSwitcher({
  required bool albumOnly,
  required bool isLocalRootPage,
  required bool isRemoteRootPage,
  required bool selecting,
  required bool operationRunning,
}) {
  if (!albumOnly) {
    return false;
  }
  if (isLocalRootPage || isRemoteRootPage) {
    return false;
  }
  if (selecting || operationRunning) {
    return false;
  }
  return true;
}

/// 插画条目的 `sourceKey` 判据。
///
/// ⚠️ **不要**换成"按 id 前缀 `pixiv` 猜"。21 号文档的核心教训：靠前缀枚举
/// 会在新源加入时漏判（Pixiv 与 Komiic 就是这么一路落到 `ScannedDownloadedComic`，
/// 于是源标签错、大小显示"未知"、作者不显示）。`sourceKey` 由
/// `CustomDownloadedItem.toJson` 写入，是唯一权威判据
/// （分派顺序见 `download_model.dart:170`）。
const String illustPixivSourceKey = 'pixiv';

/// 宽高缺失时的占位比例（宽 / 高）。
///
/// 取 3:4 —— 竖构图是插画的主流形态，且与既有卡片 `childAspectRatio = 0.72`
/// （`components/layout.dart:23-27`）几乎一致：0.75 vs 0.72，视觉上不会"跳一档"。
///
/// ⚠️ 只在**确实没有宽高**时用（老记录）。**不要**把缺失当成"高度 0"
/// （`download_model.dart:1074-1075` 已说明：`0` 会算出错误高度甚至除零）。
const double illustFallbackAspectRatio = 3 / 4;

/// 一个插画条目的展示数据：条目本体 + 瀑布流要的比例 + 标签。
class IllustLibraryEntry {
  const IllustLibraryEntry({
    required this.item,
    required this.aspectRatio,
    required this.tags,
    required this.width,
    required this.height,
    this.pageCount,
  });

  final LocalLibraryComicItem item;

  /// 宽 / 高，恒为正有限数（缺失时已降级为 [illustFallbackAspectRatio]）。
  final double aspectRatio;

  final List<String> tags;

  /// 原图宽高；缺失为 null（供 UI 决定是否显示尺寸信息）。
  final int? width;
  final int? height;

  /// 作品图片张数；给不出时为 null（卡片不渲染「页数」那一项）。
  ///
  /// 不进 [buildIllustEntries]：扫描链路里的 `episodeFiles` 只在"目录被真正列过"
  /// 时才有值（真机三条 Pixiv 记录里两条为空），所以页数只能与宽高一起在
  /// **运行时补齐**（见 `foundation/illust_cover_size.dart`）。
  final int? pageCount;

  String get id => item.id;

  /// db 里的原始 id（Pixiv 是 `pixiv<作品号>`）。
  ///
  /// 与 [id]（扫描期生成的 `local_download::<source>::<原始id>` 复合 id）区分开：
  /// 判断"这是哪个作品"要用这个，判断"列表里的唯一项"才用 [id]。
  String get originalId => item.originalId;

  /// 宽高齐全 = 比例是**真实**的（不是 [illustFallbackAspectRatio] 兜底）。
  bool get hasRealSize => width != null && height != null;

  /// 是否还等着运行时读封面头来补比例。
  ///
  /// 缺任一维就要补：只缺一个时也没法算比例（[illustAspectRatioForSize] 要求两者）。
  bool get needsSizeResolution => !hasRealSize;

  /// 用运行时解析到的值产出一条新条目。
  ///
  /// **宽高只增不减**：db 里的宽高是权威值（下载时从详情响应取的作品级原图尺寸），
  /// 运行时的封面读数只用来**补空缺**。反过来（用封面读数覆盖 db 值）会让新下载的
  /// 记录也退化成"封面重算的比例"，白白浪费已经准确的数据。
  ///
  /// 传入的宽高非正 / 非有限时按"没补到"处理，不会把条目改坏。
  IllustLibraryEntry withResolvedInfo({
    int? width,
    int? height,
    int? pageCount,
  }) {
    final nextWidth = this.width ?? _positiveOrNull(width);
    final nextHeight = this.height ?? _positiveOrNull(height);
    final nextPageCount = this.pageCount ?? _positiveOrNull(pageCount);
    if (nextWidth == this.width &&
        nextHeight == this.height &&
        nextPageCount == this.pageCount) {
      return this;
    }
    return IllustLibraryEntry(
      item: item,
      aspectRatio: illustAspectRatioForSize(nextWidth, nextHeight),
      tags: tags,
      width: nextWidth,
      height: nextHeight,
      pageCount: nextPageCount,
    );
  }
}

int? _positiveOrNull(int? value) {
  if (value == null || value <= 0) {
    return null;
  }
  return value;
}

/// 标签及其出现次数。
class IllustTagSummary {
  const IllustTagSummary({required this.tag, required this.count});

  final String tag;
  final int count;

  @override
  String toString() => 'IllustTagSummary($tag x$count)';
}

/// 从一组插画条目里挑出 Pixiv 项。
///
/// 判据是 `json` 列里的 `sourceKey == 'pixiv'`（[illustPixivSourceKey]）。
List<IllustLibraryEntry> buildIllustEntries(
  Iterable<LocalLibraryComicItem> items,
) {
  final entries = <IllustLibraryEntry>[];
  for (final item in items) {
    final data = decodeIllustSourceRow(item);
    if (data == null) {
      continue;
    }
    if (data['sourceKey']?.toString().trim() != illustPixivSourceKey) {
      continue;
    }
    final width = _positiveInt(data['width']);
    final height = _positiveInt(data['height']);
    entries.add(
      IllustLibraryEntry(
        item: item,
        aspectRatio: illustAspectRatioForSize(width, height),
        tags: illustTagsForEntry(item, data),
        width: width,
        height: height,
      ),
    );
  }
  return entries;
}

/// 解析 `download.db` 的 `json` 列文本。
///
/// 解析失败（空串 / 老式行 / 坏 JSON）返回 null —— 调用方据此跳过该条，
/// **不要**按 id 前缀去猜它是不是 Pixiv。
Map<String, dynamic>? decodeIllustSourceRow(LocalLibraryComicItem item) {
  final raw = item.sourceRowJson?.trim() ?? '';
  if (raw.isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
  } catch (_) {}
  return null;
}

/// 宽高 → 展示比例。任一缺失/非正数时降级为 [illustFallbackAspectRatio]。
///
/// 恒返回**正有限数**，调用方可以安全地拿它做除法算高度。
double illustAspectRatioForSize(int? width, int? height) {
  if (width == null || height == null) {
    return illustFallbackAspectRatio;
  }
  if (width <= 0 || height <= 0) {
    return illustFallbackAspectRatio;
  }
  final ratio = width / height;
  if (!ratio.isFinite || ratio <= 0) {
    return illustFallbackAspectRatio;
  }
  // 极端长条（例如 1x20000）会让单张卡片高得离谱，夹到 1:5 ~ 5:1。
  const minRatio = 1 / 5;
  const maxRatio = 5.0;
  if (ratio < minRatio) {
    return minRatio;
  }
  if (ratio > maxRatio) {
    return maxRatio;
  }
  return ratio;
}

/// 条目标签：优先用扫描链路已经解析好的 `item.tags`，为空时再从 `json` 兜底。
///
/// `LocalLibraryComicItem.tags` 的填充点见 `local_library_scan.dart:324` / `:541`
/// （走 `_metadataTagsForDownloadedRow`：先行的 `tags` 列，再 `json`，
/// 最后才是 `fallback.tags`）。这里的兜底覆盖"扫描路径没走到"的情况。
List<String> illustTagsForEntry(
  LocalLibraryComicItem item,
  Map<String, dynamic> data,
) {
  if (item.tags.isNotEmpty) {
    return item.tags;
  }
  final raw = data['tags'];
  if (raw is List) {
    return raw
        .map((entry) => entry.toString().trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }
  return const <String>[];
}

/// 汇总标签：去重 + 统计出现次数。
///
/// 排序：**出现次数降序，次数相同按标签名升序**。次数优先是因为筛选条越常用
/// 的标签越该靠前；名字升序只是为了结果稳定（否则 Map 迭代顺序会让同样的数据
/// 每次渲染出不同顺序，测试也就没法断言）。
List<IllustTagSummary> summarizeIllustTags(
  Iterable<IllustLibraryEntry> entries,
) {
  final counts = <String, int>{};
  for (final entry in entries) {
    // 同一条目内重复标签只算一次：`PixivComicInfo.tags` 已做过去重
    // （`pixiv_models.dart:114-115`），但老记录 / 别的写入路径不保证。
    for (final tag in entry.tags.toSet()) {
      final trimmed = tag.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      counts[trimmed] = (counts[trimmed] ?? 0) + 1;
    }
  }
  final summaries = counts.entries
      .map((entry) => IllustTagSummary(tag: entry.key, count: entry.value))
      .toList();
  summaries.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    if (byCount != 0) {
      return byCount;
    }
    return a.tag.compareTo(b.tag);
  });
  return summaries;
}

/// 按选中的标签过滤。
///
/// ## 单选还是多选
///
/// 计划步骤 6.2 把这条留给实现决定（"若用户未明确，默认单选"）。
/// 这里选**多选 + AND 语义**，理由：
///
/// - Pixiv 的标签本身就是"多个并列的主题词"，单选筛不出"オリジナル 且 女の子"
///   这种最常见的组合；
/// - AND（而不是 OR）是因为用户点第二个标签时的意图通常是"再收窄一点"，
///   而 OR 会让每多点一个标签结果**变多**，与"筛选"的直觉相反。
///
/// 空集合表示未筛选（返回全量）。
List<IllustLibraryEntry> filterIllustEntriesByTags(
  Iterable<IllustLibraryEntry> entries,
  Set<String> selectedTags,
) {
  if (selectedTags.isEmpty) {
    return List<IllustLibraryEntry>.from(entries, growable: false);
  }
  return entries.where((entry) {
    for (final tag in selectedTags) {
      if (!entry.tags.contains(tag)) {
        return false;
      }
    }
    return true;
  }).toList(growable: false);
}

int? _positiveInt(Object? raw) {
  final value = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
  if (value == null || value <= 0) {
    return null;
  }
  return value;
}
