import 'ai_sources.dart';

class AiResultItem {
  final String id;
  final String title;
  final String author;
  final String coverUrl;
  final String source;
  final List<String> tags;
  final Map<String, dynamic> availability;

  const AiResultItem({
    required this.id,
    required this.title,
    required this.author,
    required this.coverUrl,
    required this.source,
    required this.tags,
    required this.availability,
  });

  factory AiResultItem.fromJson(Map<String, dynamic> json) {
    return AiResultItem(
      id: (json['id'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      author: (json['author'] as String?) ?? '',
      coverUrl: (json['coverUrl'] as String?) ?? '',
      source: normalizeAiSource(json['source']) ?? '',
      tags: (json['tags'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      availability:
          (json['availability'] as Map<String, dynamic>?) ?? const {},
    );
  }

  static List<AiResultItem> fromToolData(Object? toolData) {
    if (toolData == null) return const [];
    if (toolData is! Map<String, dynamic>) return const [];
    final items = toolData['items'];
    if (items == null) return const [];
    if (items is! List) return const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(AiResultItem.fromJson)
        .toList();
  }
}
