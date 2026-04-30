import 'dart:async';

class ImageManager {
  static void clearTasks() {}
  bool get isDownloading => false;
  static bool get haveTask => false;
  
  static Future<void> addTask({
    required String downloadId,
    required int index,
    required int total,
    required String url,
    required String referer,
    required String filePath,
  }) async {}
  
  Stream<String> getImage(
    String url,
    String path,
    String fileName,
  ) async* {
    yield path;
  }
}
