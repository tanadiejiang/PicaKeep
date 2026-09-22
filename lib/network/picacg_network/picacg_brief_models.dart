/// Picacg 的**纯 Dart** 列表模型：条目 brief、分类目录项、推荐集合。
///
/// 与 `models.dart` 分开：后者还定义 `PicacgComicItem`（详情对象），它引用
/// `foundation/history.dart` → `state_controller.dart`（Flutter）。
/// 解析测试只需要这些轻量模型。
library;

import 'package:picakeep/network/base_comic.dart';

/// 拼 Picacg 图片 URL（thumb / avatar 共用）。
String picacgImageUrl(Map? media) {
  if (media == null) {
    return '';
  }
  final server = media['fileServer']?.toString() ?? '';
  final path = media['path']?.toString() ?? '';
  if (server.isEmpty || path.isEmpty) {
    return '';
  }
  final base = server.endsWith('/') ? '${server}static/' : '$server/static/';
  return '$base$path';
}

int picacgIntValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

List<String> picacgStringList(Object? value) {
  if (value is List) {
    return value.map((e) => e.toString()).toList(growable: false);
  }
  return const <String>[];
}

class PicacgComicItemBrief extends BaseComic {
  const PicacgComicItemBrief({
    required this.id,
    required this.title,
    required this.author,
    required this.likes,
    required this.path,
    required this.tags,
    this.pages,
  });

  /// 空占位（内部构造用；不会出现在列表结果里）。
  static const PicacgComicItemBrief empty = PicacgComicItemBrief(
    id: '',
    title: '',
    author: '',
    likes: 0,
    path: '',
    tags: <String>[],
  );

  factory PicacgComicItemBrief.fromApi(Map json) {
    final tags = <String>[
      ...picacgStringList(json['tags']),
      ...picacgStringList(json['categories']),
    ];
    return PicacgComicItemBrief(
      id: json['_id']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Unknown',
      author: json['author']?.toString() ?? 'Unknown',
      likes: picacgIntValue(json['likesCount'] ?? json['totalLikes']),
      path: picacgImageUrl(json['thumb'] as Map?),
      tags: tags,
      pages: picacgIntValue(json['pagesCount']),
    );
  }

  @override
  final String id;

  @override
  final String title;

  final String author;
  final int likes;
  final String path;

  @override
  final List<String> tags;

  final int? pages;

  @override
  String get cover => path;

  @override
  String get description {
    final pageText = pages == null || pages == 0 ? '' : ' · $pages 页';
    return '$likes 喜欢$pageText';
  }

  @override
  String get subTitle => author;
}

/// Picacg 分类目录项。
class PicacgCategoryItem {
  const PicacgCategoryItem({
    required this.title,
    required this.thumb,
    required this.isWeb,
  });

  /// 服务器原始分类名：**请求 `c=` 时必须用它**。
  final String title;
  final String thumb;
  final bool isWeb;

  @override
  String toString() => 'PicacgCategoryItem($title)';
}

/// Picacg 推荐集合（一个真实分组）。
class PicacgCollection {
  const PicacgCollection({
    required this.title,
    required this.id,
    required this.comics,
  });

  final String title;

  /// 站点稳定 ID；缺失时由适配器用会话内 sectionId 替代，不把索引当持久身份。
  final String id;
  final List<PicacgComicItemBrief> comics;

  @override
  String toString() => 'PicacgCollection($title, ${comics.length})';
}
