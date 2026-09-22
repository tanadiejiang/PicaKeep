import 'package:picakeep/network/base_comic.dart';

class JmComicBrief extends BaseComic {
  const JmComicBrief({
    required this.id,
    required this.title,
    required this.author,
    required this.tags,
    required this.coverUrl,
    this.desc = '',
  });

  @override
  final String id;
  @override
  final String title;
  final String author;
  @override
  final List<String> tags;
  final String coverUrl;
  final String desc;

  @override
  String get cover => coverUrl;
  @override
  String get subTitle => author;
  @override
  String get description => desc;
}

class JmComicInfo {
  const JmComicInfo({
    required this.id,
    required this.title,
    required this.authors,
    required this.description,
    required this.likes,
    required this.views,
    required this.comments,
    required this.tags,
    required this.works,
    required this.actors,
    required this.series,
    required this.epNames,
    required this.isFavourite,
    required this.isLiked,
    required this.coverUrl,
    required this.relatedComics,
    this.categoryTags = const [],
  });

  final String id;
  final String title;
  final List<String> authors;
  final String description;
  final int likes;
  final int views;
  final int comments;
  final List<String> tags;
  final List<String> works;
  final List<String> actors;

  /// 列表口径的分类标签（`category` + `category_sub`，与 [JmComicBrief.tags] 同源）。
  ///
  /// 详情响应的 `tags` 是**全量标签**（可达数十条），与本项目列表卡片的口径不同；
  /// 分类标签单独保真出来，供"更新卡片信息"这类需要列表口径的链路使用。
  /// 接口未返回 category 时为空列表 —— 调用方据此判定"本次没拿到"，保留原值。
  final List<String> categoryTags;

  /// key = sort 顺序(1-based)，value = chapter id
  final Map<int, String> series;

  /// chapter display names，顺序与 series keys 对应
  final List<String> epNames;

  final bool isFavourite;
  final bool isLiked;
  final String coverUrl;

  /// 相关推荐漫画列表
  final List<JmComicBrief> relatedComics;

  String get author => authors.join(' / ');

  /// chapter ids in order (1-based key order)
  List<String> get chapterIds {
    final entries = series.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries.map((e) => e.value).toList();
  }
}

class JmComment {
  const JmComment({
    required this.id,
    required this.username,
    required this.content,
    required this.timeAgo,
    this.avatar = '',
    this.replies = const [],
  });

  final String id;
  final String username;
  final String content;
  final String timeAgo;
  final String avatar;
  final List<JmComment> replies;
}

class JmFolder {
  const JmFolder({required this.id, required this.name});
  final String id; // FID
  final String name;
}

/// `/categories` 的子分类。
class JmSubCategory {
  const JmSubCategory({
    required this.cid,
    required this.name,
    required this.slug,
  });

  /// 站点 CID；与 slug 并存，slug 才是 `/categories/filter?c=` 的取值。
  final String cid;
  final String name;

  /// 请求用的稳定 slug。**允许为空**（缺失时调用方不得归零成 `0`）。
  final String slug;

  @override
  String toString() => 'JmSubCategory($name, $slug)';
}

/// `/categories` 的一级分类。
class JmCategory {
  const JmCategory({
    required this.name,
    required this.slug,
    required this.subCategories,
  });

  final String name;
  final String slug;
  final List<JmSubCategory> subCategories;

  @override
  String toString() => 'JmCategory($name, ${subCategories.length} sub)';
}

/// 分类结果的排序。值直接进 `/categories/filter?o=`。
enum JmComicsOrder {
  latest('mr', '最新'),
  totalRanking('mv', '总排行'),
  monthRanking('mv_m', '月排行'),
  weekRanking('mv_w', '周排行'),
  dayRanking('mv_t', '日排行'),
  maxPictures('mp', '最多图片'),
  maxLikes('tf', '最多喜欢');

  const JmComicsOrder(this.value, this.label);

  final String value;
  final String label;

  /// 严格解析：未知值返回 `null`（不静默回落到"最新"）。
  static JmComicsOrder? tryFromValue(String value) {
    for (final order in JmComicsOrder.values) {
      if (order.value == value) return order;
    }
    return null;
  }

  static JmComicsOrder fromValue(String value) =>
      tryFromValue(value) ?? (throw ArgumentError('Unknown JM order: $value'));

  @override
  String toString() => value;
}

/// `/promote?page=0` 概览里的一块。
class JmPromoteSection {
  const JmPromoteSection({
    required this.title,
    required this.type,
    required this.id,
    required this.slug,
    required this.comics,
  });

  final String title;

  /// 站点给的块类型：`promote` / `category_id` / 其它未知值。
  final String type;

  /// 站点给的块 ID（promote 用；category_id 块为 slug）。
  final String id;

  /// category_id 块的分类 slug。
  final String slug;

  final List<JmComicBrief> comics;

  /// 该块是否有可靠的「更多」目标。
  ///
  /// - `promote` → `/promote_list?id=<id>`；
  /// - `category_id` → 分类 slug；
  /// - 未知 type → 没有可靠目标，UI 不给"更多"入口。
  bool get hasMoreTarget => type == 'promote' || type == 'category_id';

  @override
  String toString() => 'JmPromoteSection($title, $type, ${comics.length})';
}

/// `/promote_list` 的一页。
class JmPromoteList {
  const JmPromoteList({
    required this.id,
    required this.comics,
    required this.total,
    required this.loaded,
    required this.page,
  });

  final String id;
  final List<JmComicBrief> comics;

  /// 站点声明的总数（**原始记录数**，不是本页解析成功数）。
  final int total;

  /// 本页消费的原始记录数（含坏项）；Provider 在续页游标中累计。
  final int loaded;

  /// 当前页序号（从 0 起）。
  final int page;

  bool get hasMore => total > 0 && loaded < total;

  @override
  String toString() => 'JmPromoteList($id, loaded=$loaded/$total)';
}

/// `/week` 返回的推荐期号。
class JmWeekPeriod {
  const JmWeekPeriod({
    required this.id,
    required this.time,
  });

  final String id;

  /// 站点给的期号标题（例如时间范围），原样展示。
  final String time;

  @override
  String toString() => 'JmWeekPeriod($id, $time)';
}

/// 每周推荐的内容类型。每次请求**只传一个**值。
enum JmWeekType {
  hanman('hanman', '韩漫'),
  manga('manga', '漫画'),
  another('another', '其他');

  const JmWeekType(this.value, this.label);

  final String value;
  final String label;

  static JmWeekType? tryFromValue(String value) {
    for (final type in JmWeekType.values) {
      if (type.value == value) return type;
    }
    return null;
  }
}
