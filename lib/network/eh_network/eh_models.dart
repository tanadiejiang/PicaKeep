class Gallery {
  final String title;
  final String? subTitle;
  final String type;
  final String coverPath;
  final Map<String, List<String>> tags;
  final String maxPage;
  final String link;
  final String id;
  
  Gallery({
    required this.title,
    this.subTitle,
    required this.type,
    required this.coverPath,
    required this.tags,
    this.maxPage = '0',
    this.link = '',
    this.id = '',
  });
  
  Map<String, dynamic> toJson() => {'title': title};
  
  dynamic toBrief() => null;
}

class GalleryBrief {}
