import 'dart:io';

class DownloadProgress {
  final int current;
  final int total;
  final String path;
  final String url;

  DownloadProgress(this.current, this.total, this.url, this.path);

  bool get finished => current >= total;

  File getFile() => File(path);
}

class DownloadManager {
  static DownloadManager? cache;

  factory DownloadManager() => cache ?? (cache = DownloadManager._create());

  DownloadManager._create();

  List<String> downloading = [];

  Future<void> init() async {}

  void start() {}

  void dispose() {}

  String generateId(String key, String target) => '$key-$target';

  String? get path => null;

  String getDirectory(String id) => '';

  bool isExists(String id) => false;

  bool get isDownloading => downloading.isNotEmpty;

  Future<dynamic> getComicOrNull(String id) async => null;

  Future<int> getEpLength(String id, int ep) async => 0;

  Future<int> getComicLength(String id) async => 0;

  File getImage(String id, int ep, int page) {
    throw UnimplementedError();
  }
}
