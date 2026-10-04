/// All chapter indexes are zero based. Network and directory numbers are index + 1.
enum ChapterDownloadStatus {
  available,
  downloaded,
  queued,
  downloading,
  paused,
  failed,
}

/// Null selects every chapter; explicit empty or out-of-range input is rejected.
List<int> normalizeChapterIndexes(List<int>? indexes, int chapterCount) {
  if (chapterCount <= 0) throw const FormatException('没有可下载章节');
  final result = indexes == null
      ? List<int>.generate(chapterCount, (index) => index)
      : indexes.toSet().toList()
    ..sort();
  if (result.isEmpty) throw const FormatException('请选择至少一章');
  if (result.any((index) => index < 0 || index >= chapterCount)) {
    throw const FormatException('章节选择超出范围，请刷新后重试');
  }
  return result;
}
