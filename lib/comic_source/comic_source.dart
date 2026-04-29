library comic_source;

import 'dart:async';

import 'package:picakeep/network/res.dart';

class ComicSource {
  static final List<ComicSource> sources = [];
  
  final String key;
  final String name;
  final int intKey;

  Future<Res<List<String>>> Function(String, String?)? loadComicPages;
  
  ComicSource({required this.key, required this.name, this.intKey = 0, this.loadComicPages});
  
  static ComicSource? find(String key) {
    try {
      return sources.firstWhere((s) => s.key == key);
    } catch (_) {
      return null;
    }
  }
}
