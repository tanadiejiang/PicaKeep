import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_chapter_display.dart';

void main() {
  test('continuous selection uses selected count, not source total', () {
    expect(
      downloadChapterPosition(
        currentEp: 2,
        totalEps: 44,
        chapterIndexes: List.generate(12, (index) => index),
      ),
      (position: 2, total: 12),
    );
  });

  test('sparse selection maps source cursor without renumbering chapters', () {
    expect(
      downloadChapterPosition(
        currentEp: 4,
        totalEps: 44,
        chapterIndexes: [1, 3],
      ),
      (position: 2, total: 2),
    );
  });

  test('old whole-book queue retains source chapter position and total', () {
    expect(
      downloadChapterPosition(
        currentEp: 12,
        totalEps: 44,
        chapterIndexes: null,
      ),
      (position: 12, total: 44),
    );
  });

  test('invalid or pending cursor is unknown instead of a false position', () {
    for (final cursor in [0, 3, 50]) {
      expect(
        downloadChapterPosition(
          currentEp: cursor,
          totalEps: 44,
          chapterIndexes: [3, 1, 3, -1, 44],
        ),
        (position: null, total: 2),
      );
    }
    expect(
      downloadChapterPosition(
        currentEp: 0,
        totalEps: 0,
        chapterIndexes: null,
      ),
      (position: null, total: 0),
    );
  });
}
