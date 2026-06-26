part of 'local_library.dart';

extension LocalLibraryCover on LocalLibraryManager {
  String coverPathForDisplay(String path) {
    return path;
  }

  /// 解析一个本地目录（source 子项）的预览封面路径，供外层 source 卡片拼贴使用。
  /// 走特权通道（root/shizuku 下也能读外部存储）：先找命名封面，再取首张内容图，
  /// 都没有则递归取第一张图。返回 null 表示该目录下无可用图片。
  Future<String?> resolveChildCoverPath(String dirPath) async {
    final normalized = dirPath.trim();
    if (normalized.isEmpty) {
      return null;
    }
    final namedCover = await _resolveNamedCoverPath(normalized);
    if (namedCover != null && namedCover.isNotEmpty) {
      return namedCover;
    }
    final contentImages = await _sortedContentImagesForPath(normalized);
    if (contentImages.isNotEmpty) {
      return contentImages.first;
    }
    final recursive = await _sortedRecursiveContentImagesForPath(normalized);
    if (recursive.isNotEmpty) {
      return recursive.first;
    }
    return null;
  }
}
