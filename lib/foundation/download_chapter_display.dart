/// A chapter cursor is a source index, while a selected queue has its own order.
/// Keep that distinction in the display without renumbering persisted chapters.
({int? position, int total}) downloadChapterPosition({
  required int currentEp,
  required int totalEps,
  required List<int>? chapterIndexes,
}) {
  if (chapterIndexes == null) {
    return (
      position: currentEp > 0 && currentEp <= totalEps ? currentEp : null,
      total: totalEps < 0 ? 0 : totalEps,
    );
  }
  final requested = chapterIndexes
      .where((index) => index >= 0 && index < totalEps)
      .toSet()
      .toList()
    ..sort();
  final index = requested.indexOf(currentEp - 1);
  return (position: index < 0 ? null : index + 1, total: requested.length);
}
