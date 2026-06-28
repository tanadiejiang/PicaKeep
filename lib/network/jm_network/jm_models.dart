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

  /// key = sort 顺序(1-based)，value = chapter id
  final Map<int, String> series;

  /// chapter display names，顺序与 series keys 对应
  final List<String> epNames;

  final bool isFavourite;
  final bool isLiked;
  final String coverUrl;

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
