class HitomiFile {
  final String hash;
  
  HitomiFile({required this.hash});
  
  Map<String, dynamic> toMap() => {'hash': hash};
}

class HitomiComic {
  final String title;
  final String target;
  final List<HitomiFile> files;
  
  HitomiComic({required this.title, required this.target, required this.files});
}
