/// JM 列表 / 分类 / 推荐响应的**纯 Dart 解析**。
///
/// 从 `jm_network.dart` 抽出来的理由：那个文件依赖 Flutter（`visibleForTesting`）
/// 与 `base.dart`（`appdata`），一旦被测试 import 就会牵连整棵 Flutter 依赖树，
/// 使 `dart test` 无法运行。这里只依赖 `jm_models.dart`（纯 Dart）。
library;

import 'jm_models.dart';

export 'jm_models.dart';

/// JM 条目的最小合法性校验：`id` 必须是**真实有效数字**。
///
/// 列表接口里出现空串或字面量 `"null"` 时，旧代码因为解析不抛异常而把坏条目当
/// 合法条目（`id: "null"`），最终表现为"整页坏响应被当成正常空榜"。
bool isValidJmComicId(Object? raw) {
  final id = raw?.toString().trim() ?? '';
  if (id.isEmpty) return false;
  return int.tryParse(id) != null;
}

/// 列表接口的 author 字段（可能是数组或字符串）→ 单个展示字符串。
String joinJmListField(dynamic v) {
  if (v is List) return v.join(' / ');
  return v?.toString() ?? '';
}

/// 兼容数组 / 单字符串的字符串列表解析。
List<String> parseJmStringList(dynamic v) {
  if (v is List) return v.map((e) => e.toString()).toList();
  if (v is String && v.isNotEmpty) return [v];
  return const [];
}

/// 封面 URL 构造函数。默认返回空串。
///
/// 封面域来自 `settings[86]`（`jm_image.dart` 的 `getJmCoverUrl`），本文件是纯
/// Dart、不读 settings，因此由网络层在调用解析前注入。纯层测试传自己的实现。
typedef JmCoverUrlBuilder = String Function(String id);

String _defaultCoverUrl(String id) => '';

/// 列表接口条目 → [JmComicBrief]。
JmComicBrief parseJmListBriefRaw(
  Map c, {
  bool withDesc = false,
  JmCoverUrlBuilder coverUrlBuilder = _defaultCoverUrl,
}) {
  final id = c['id'].toString();
  return JmComicBrief(
    id: id,
    title: c['name']?.toString() ?? '',
    author: joinJmListField(c['author']),
    tags: parseJmListTags(c),
    coverUrl: coverUrlBuilder(id),
    desc: withDesc ? (c['description']?.toString() ?? '') : '',
  );
}

/// JM 列表接口的分类标签：`category.title` + `category_sub.title`。
///
/// 按「category 在前、category_sub 在后」输出并**去重**。
/// `c['tags']` 仅作兜底，且过滤纯数字项（那里出现的往往是分类 id 而非名称）。
List<String> parseJmListTags(dynamic c) {
  if (c is! Map) return const [];
  final tags = <String>[];
  _addCategoryTitle(tags, c['category']);
  _addCategoryTitle(tags, c['category_sub']);
  if (tags.isEmpty) {
    for (final t in parseJmStringList(c['tags'])) {
      final s = t.trim();
      if (s.isNotEmpty && int.tryParse(s) == null) _addTag(tags, s);
    }
  }
  return tags;
}

void _addCategoryTitle(List<String> out, dynamic v) {
  if (v is! Map) return;
  final title = v['title'];
  if (title is String) _addTag(out, title);
}

void _addTag(List<String> out, String title) {
  final s = title.trim();
  if (s.isEmpty || out.contains(s)) return;
  out.add(s);
}

/// 从列表响应解析条目，同时报告坏项计数。
///
/// - [rawList] 非空但没有任何合法条目 → [parsed] 为空且 [invalid] > 0，
///   调用方据此报 parse，绝不返回"空成功"；
/// - 部分坏项 → 保留合法结果并把坏项计入 [invalid]（不改变消费计数）。
({List<JmComicBrief> parsed, int invalid}) parseJmListItems(
  Iterable<dynamic> rawList, {
  bool withDesc = false,
  JmCoverUrlBuilder coverUrlBuilder = _defaultCoverUrl,
}) {
  final parsed = <JmComicBrief>[];
  var invalid = 0;
  for (final item in rawList) {
    if (item is! Map || !isValidJmComicId(item['id'])) {
      invalid++;
      continue;
    }
    try {
      parsed.add(parseJmListBriefRaw(
        item,
        withDesc: withDesc,
        coverUrlBuilder: coverUrlBuilder,
      ));
    } catch (_) {
      invalid++;
    }
  }
  return (parsed: parsed, invalid: invalid);
}

/// `/categories` 动态目录解析。
///
/// 保留主 / 子分类的 name、slug、CID 与层级顺序。子分类 slug 缺失时保留空串
/// （调用方不得把它归零成 `0`）；`categories` 字段缺失 / 类型错时抛异常。
List<JmCategory> parseJmCategories(Map raw) {
  final rawCategories = raw['categories'];
  if (rawCategories is! List) {
    throw const FormatException('JM categories: 缺少 categories 数组');
  }
  final result = <JmCategory>[];
  for (final item in rawCategories) {
    if (item is! Map) continue;
    final subs = <JmSubCategory>[];
    final rawSubs = item['sub_categories'];
    if (rawSubs is List) {
      for (final sub in rawSubs) {
        if (sub is! Map) continue;
        final name = sub['name']?.toString().trim() ?? '';
        final slug = sub['slug']?.toString().trim() ?? '';
        if (name.isEmpty && slug.isEmpty) continue;
        subs.add(JmSubCategory(
          cid: sub['CID']?.toString() ?? sub['id']?.toString() ?? '',
          name: name,
          slug: slug,
        ));
      }
    }
    final name = item['name']?.toString().trim() ?? '';
    final slug = item['slug']?.toString().trim() ?? '';
    if (name.isEmpty && slug.isEmpty && subs.isEmpty) continue;
    result.add(JmCategory(name: name, slug: slug, subCategories: subs));
  }
  return result;
}

/// `/promote?page=0` 概览解析：保留每块的 title / type / id / slug 与条目。
List<JmPromoteSection> parseJmPromoteSections(
  dynamic raw, {
  JmCoverUrlBuilder coverUrlBuilder = _defaultCoverUrl,
}) {
  if (raw is! List) {
    throw const FormatException('JM promote: 顶层不是数组');
  }
  final sections = <JmPromoteSection>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final title = item['title']?.toString().trim() ?? '';
    final type = item['type']?.toString().trim() ?? '';
    final id = item['id']?.toString().trim() ?? '';
    final slug = item['slug']?.toString().trim() ?? '';
    final content = item['content'];
    final parsed = content is List
        ? parseJmListItems(content, coverUrlBuilder: coverUrlBuilder).parsed
        : <JmComicBrief>[];
    if (title.isEmpty && parsed.isEmpty) continue;
    sections.add(JmPromoteSection(
      title: title,
      type: type,
      id: type == 'category_id' ? slug : id,
      slug: slug,
      comics: parsed,
    ));
  }
  return sections;
}

/// `/promote_list` 分页解析。
///
/// 关键点：`total` 是**原始记录数**，`loaded` 必须按响应里实际消费的原始条目
/// 计数（含坏项）推进；用"本页解析成功数"作分母会把末页总页数放大。
JmPromoteList parseJmPromoteList(
  String id,
  Map raw, {
  required int page,
  JmCoverUrlBuilder coverUrlBuilder = _defaultCoverUrl,
}) {
  final rawList = raw['list'];
  if (rawList is! List) {
    throw const FormatException('JM promote_list: 缺少 list 数组');
  }
  final total = _parseInt(raw['total']);
  final result = parseJmListItems(rawList, coverUrlBuilder: coverUrlBuilder);
  if (rawList.isNotEmpty && result.parsed.isEmpty) {
    throw const FormatException('JM promote_list: 非空响应全部解析失败');
  }
  var loaded = rawList.length;
  if (total > 0 && loaded > total) loaded = total;
  return JmPromoteList(
    id: id,
    comics: result.parsed,
    total: total,
    loaded: loaded,
    page: page,
  );
}

/// `/week` 期号列表解析。
List<JmWeekPeriod> parseJmWeekPeriods(Map raw) {
  final rawCategories = raw['categories'];
  if (rawCategories is! List) {
    throw const FormatException('JM week: 缺少 categories 数组');
  }
  final periods = <JmWeekPeriod>[];
  for (final item in rawCategories) {
    if (item is! Map) continue;
    final id = item['id']?.toString().trim() ?? '';
    if (id.isEmpty) continue;
    periods.add(JmWeekPeriod(
      id: id,
      time: item['time']?.toString().trim() ?? id,
    ));
  }
  return periods;
}

/// 每周推荐内容解析（单页，无续页）。
List<JmComicBrief> parseJmWeekComics(
  Map raw, {
  JmCoverUrlBuilder coverUrlBuilder = _defaultCoverUrl,
}) {
  final rawList = raw['list'] ?? raw['content'];
  if (rawList is! List) {
    throw const FormatException('JM week/filter: 缺少 list 数组');
  }
  final result = parseJmListItems(
    rawList,
    withDesc: true,
    coverUrlBuilder: coverUrlBuilder,
  );
  if (rawList.isNotEmpty && result.parsed.isEmpty) {
    throw const FormatException('JM week/filter: 非空响应全部解析失败');
  }
  return result.parsed;
}

/// 分类结果 / 收藏 / 最新共用的页数推算。
///
/// **分母必须是原始记录数**（[rawCount]），不是"本次解析成功数"：末页短页时
/// 用解析成功数会把总页数放大。
int jmPageCount({
  required int total,
  required int rawCount,
  required int page,
}) {
  if (total <= 0 || rawCount <= 0) return page;
  return (total / rawCount).ceil();
}

int _parseInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? 0;
}
