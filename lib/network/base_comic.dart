abstract class BaseComic {
  const BaseComic();

  String get title;

  String get subTitle;

  String get cover;

  String get id;

  List<String> get tags;

  String get description;

  bool get enableTagsTranslation => false;
}

class CustomComic extends BaseComic {
  const CustomComic(
    this.title,
    this.subTitle,
    this.cover,
    this.id,
    this.tags,
    this.description,
    this.sourceKey,
  );

  CustomComic.fromJson(Map json, this.sourceKey)
      : title = json['title']?.toString() ?? '',
        subTitle = json['subTitle']?.toString() ?? '',
        cover = json['cover']?.toString() ?? '',
        id = json['id']?.toString() ?? '',
        tags = List<String>.from(json['tags'] ?? const <String>[]),
        description = json['description']?.toString() ?? '';

  @override
  final String title;

  @override
  final String subTitle;

  @override
  final String cover;

  @override
  final String id;

  @override
  final List<String> tags;

  @override
  final String description;

  final String sourceKey;
}
