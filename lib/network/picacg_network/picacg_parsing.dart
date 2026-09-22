/// Picacg 探索相关响应的**纯 Dart 解析**辅助。
///
/// 与 `picacg_network.dart` 分开：后者依赖 Flutter（`visibleForTesting`）与
/// `comic_source/built_in/picacg.dart`，解析留在里面会让纯层测试无法用
/// `dart test` 运行。本文件只依赖纯模型。
library;

import 'picacg_brief_models.dart';

export 'picacg_brief_models.dart';

/// Picacg 排序取值（分类 / 搜索共用）。
const List<String> picacgSorts = <String>['dd', 'da', 'ld', 'vd'];

/// Picacg 榜单真实榜期。**没有总榜**，不得虚构。
const List<String> picacgLeaderboardPeriods = <String>['H24', 'D7', 'D30'];

/// `data.categories[]` 解析；保留原始 title / thumb / isWeb。
List<PicacgCategoryItem> parsePicacgCategories(Object? data) {
  if (data is! Map) {
    throw const FormatException('Picacg categories: data 不是对象');
  }
  final raw = data['categories'];
  if (raw is! List) {
    throw const FormatException('Picacg categories: 缺少 categories 数组');
  }
  final result = <PicacgCategoryItem>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final title = item['title']?.toString().trim() ?? '';
    if (title.isEmpty) continue;
    result.add(PicacgCategoryItem(
      title: title,
      thumb: item['thumb']?.toString() ?? '',
      isWeb: item['isWeb'] == true,
    ));
  }
  return result;
}

/// `data.collections[]` 解析：**支持 0 / 1 / 多组**，保留标题。
List<PicacgCollection> parsePicacgCollections(Object? data) {
  if (data is! Map) {
    throw const FormatException('Picacg collections: data 不是对象');
  }
  final raw = data['collections'];
  if (raw is! List) {
    throw const FormatException('Picacg collections: 缺少 collections 数组');
  }
  final result = <PicacgCollection>[];
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    if (item is! Map) continue;
    final comicsRaw = item['comics'];
    final comics = comicsRaw is List
        ? parsePicacgComicDocs(comicsRaw).parsed
        : const <PicacgComicItemBrief>[];
    final id =
        item['_id']?.toString().trim() ?? item['id']?.toString().trim() ?? '';
    final title = item['title']?.toString().trim() ?? '';
    if (comics.isEmpty && title.isEmpty && id.isEmpty) continue;
    result.add(PicacgCollection(
      title: title.isEmpty ? '推荐' : title,
      id: id.isEmpty ? 'collection-$i' : id,
      comics: comics,
    ));
  }
  return result;
}

/// Picacg 条目数组解析，附带坏项计数。
///
/// `fromApi` 对缺 `_id` 的条目会返回空 id（**不抛异常**），旧实现因此把"整页
/// 坏响应"过滤成空列表、伪装成空成功。这里显式计数，让调用方能区分
/// "空数组 = 正常无结果"与"非空但全坏 = parse 失败"。
({List<PicacgComicItemBrief> parsed, int invalid}) parsePicacgComicDocs(
  Iterable<dynamic> docs,
) {
  final parsed = <PicacgComicItemBrief>[];
  var invalid = 0;
  for (final doc in docs) {
    if (doc is! Map) {
      invalid++;
      continue;
    }
    try {
      final comic = PicacgComicItemBrief.fromApi(doc);
      if (comic.id.isEmpty) {
        invalid++;
        continue;
      }
      parsed.add(comic);
    } catch (_) {
      invalid++;
    }
  }
  return (parsed: parsed, invalid: invalid);
}
