import 'package:picakeep/network/base_comic.dart';

/// Komiic 列表项（最新更新 / 热门 / 分类 / 搜索 / 推荐 / 收藏夹共用）。
///
/// 适配点：照搬 PicaKeep 现有 brief 惯例 —— [subTitle] 复用 [author]、
/// [description] 复用 [updateTime]（无更新时间时给空串，绝不抛异常），
/// [enableTagsTranslation] 恒 true（Komiic 的分类名是中文，无需翻译但保持
/// 与 eh/nh 一致的展示口径）。
///
/// **本文件刻意不 import `package:flutter/*`**（含 `@immutable` 标注）：它是
/// `komiic_parsing.dart` 的依赖，一旦这里拖进 `dart:ui`，纯层测试就无法用
/// `dart test` 运行。字段全部 final，不可变语义靠构造时定型保证。
class KomiicComicBrief extends BaseComic {
  const KomiicComicBrief({
    required this.id,
    required this.title,
    required this.cover,
    required this.author,
    required this.tags,
    required this.status,
    required this.year,
    required this.updateTime,
    required this.views,
    required this.favoriteCount,
  });

  @override
  final String id;

  @override
  final String title;

  /// 封面地址，直接取 GraphQL 的 `imageUrl`（Komiic 返回的是完整 CDN URL）。
  @override
  final String cover;

  /// 作者名，取 `authors[0].name`；多作者只展示首位（列表页不占空间）。
  final String author;

  /// 分类名列表，取 `categories[].name`。
  @override
  final List<String> tags;

  /// 连载状态原文（如 `ONGOING`）；不在这里翻译，交给展示层决定。
  final String status;

  /// 年份原文（Komiic 用字符串下发，可能是空串）。
  final String year;

  /// 已格式化为 `yyyy-MM-dd` 的更新时间；解析失败时为空串。
  final String updateTime;

  final int views;

  final int favoriteCount;

  @override
  String get subTitle => author;

  @override
  String get description => updateTime;

  @override
  bool get enableTagsTranslation => true;
}

/// Komiic 漫画详情：`comicByIds` 的单条对象 + 外部拼装的章节与推荐。
///
/// 章节与推荐**不来自同一个请求**（Komiic 的 GraphQL 没有嵌套这两项），
/// 所以由网络层分别取回后注入构造函数，解析层保持无副作用。
class KomiicComicInfo {
  const KomiicComicInfo({
    required this.id,
    required this.title,
    required this.coverUrl,
    required this.authors,
    required this.tags,
    required this.description,
    required this.status,
    required this.year,
    required this.updateTime,
    required this.views,
    required this.monthViews,
    required this.favoriteCount,
    required this.chapters,
    required this.recommendations,
  });

  final String id;
  final String title;
  final String coverUrl;

  /// 作者名列表（详情页展示全部作者，与 brief 只取首位不同）。
  final List<String> authors;

  final List<String> tags;
  final String description;
  final String status;
  final String year;

  /// 已格式化为 `yyyy-MM-dd` 的更新时间；解析失败时为空串。
  final String updateTime;

  final int views;
  final int monthViews;
  final int favoriteCount;

  final List<KomiicChapter> chapters;

  /// 推荐漫画（由 `recommendComicById` + `comicByIds` 拼装）。
  final List<KomiicComicBrief> recommendations;
}

/// Komiic 章节。
///
/// `type == 'book'` 表示"卷"（合订本），其余（通常为 `chapter`）表示普通章节；
/// [displayName] 因此对卷做 `卷{serial}` 前缀，普通章节直接给 serial。
class KomiicChapter {
  const KomiicChapter({
    required this.id,
    required this.serial,
    required this.type,
    this.size,
    required this.dateUpdated,
  });

  final String id;

  /// 章节序号原文（Komiic 用字符串，可能是 `番外` 这类非数字）。
  final String serial;

  /// 章节类型原文；`book` 为卷。
  final String type;

  /// 图片数量 / 体积等由服务端给出的大小；缺失时为 null（不默认成 0，
  /// 避免展示层把"未知"画成"0"）。
  final int? size;

  /// 已格式化为 `yyyy-MM-dd` 的更新时间；解析失败时为空串。
  final String dateUpdated;

  bool get isBook => type == 'book';

  String get displayName => isBook ? '卷$serial' : serial;
}

/// Komiic 收藏夹（`myFolder` 返回）。
class KomiicFolder {
  const KomiicFolder({
    required this.id,
    required this.key,
    required this.name,
    required this.comicCount,
  });

  final String id;

  /// 收藏夹的稳定 key（服务端下发，可能是 null → 空串）。
  final String key;

  final String name;

  final int comicCount;
}
