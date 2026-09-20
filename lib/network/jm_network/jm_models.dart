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
  final String id;   // FID
  final String name;
}
