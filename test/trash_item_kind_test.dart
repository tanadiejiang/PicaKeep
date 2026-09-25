import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/trash.dart';

void main() {
  group('trashItemIsAlbumForSource · 回收站两档的来源判据', () {
    // 这组用例守的是一个**与库内分档刻意分离**的判据：
    // 回收站里 Pixiv 归「图集」档，但 `LocalLibraryComicItem.isAlbum`（库内分档）
    // 保持不动 —— 两者合并会让 Pixiv 在本地库页/计数上变成"半个图集"。
    test('Pixiv 归图集档', () {
      expect(trashItemIsAlbumForSource('Pixiv'), isTrue);
    });

    test('大小写无关', () {
      expect(trashItemIsAlbumForSource('pixiv'), isTrue);
      expect(trashItemIsAlbumForSource('PIXIV'), isTrue);
    });

    test('首尾空白不影响判定', () {
      expect(trashItemIsAlbumForSource('  Pixiv  '), isTrue);
    });

    test('Komiic 保持漫画档（它下的是漫画）', () {
      expect(trashItemIsAlbumForSource('Komiic'), isFalse);
      expect(trashItemIsAlbumForSource('komiic'), isFalse);
    });

    test('其它来源保持漫画档', () {
      for (final label in <String>['哔咔', '禁漫', 'E-Hentai', 'NHentai', '本地扫描']) {
        expect(trashItemIsAlbumForSource(label), isFalse, reason: label);
      }
    });

    test('空来源不归图集档', () {
      expect(trashItemIsAlbumForSource(''), isFalse);
      expect(trashItemIsAlbumForSource('   '), isFalse);
    });
  });
}
