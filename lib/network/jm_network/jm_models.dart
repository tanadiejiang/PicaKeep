class JmComicBrief {
  String get coverUrl => '';
  String get id => '';
  String get name => '';
}

class JmComicInfo {
  final String name;
  final String id;
  final Map<int, String> series;
  final List<String> epNames;
  
  JmComicInfo({required this.name, required this.id, required this.series, required this.epNames});
}
