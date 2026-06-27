import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/network/picacg_network/headers.dart';
import 'package:picakeep/network/picacg_network/models.dart';

void main() {
  test('picacg signature matches migrated algorithm', () {
    final signature = createPicacgSignature(
      'auth/sign-in',
      'nonce',
      '1700000000',
      'POST',
    );
    expect(
      signature,
      '2ceda443204c7bc26bd12fc559c2df4e8e34a771cb4adcb6d7e98ba6267a1636',
    );
  });

  test('picacg comic brief parses common api fields', () {
    final comic = PicacgComicItemBrief.fromApi({
      '_id': 'comic-id',
      'title': 'Title',
      'author': 'Author',
      'likesCount': 12,
      'pagesCount': 34,
      'tags': ['tag'],
      'categories': ['cat'],
      'thumb': {
        'fileServer': 'https://img.example.com',
        'path': 'a/b.jpg',
      },
    });

    expect(comic.id, 'comic-id');
    expect(comic.cover, 'https://img.example.com/static/a/b.jpg');
    expect(comic.tags, ['tag', 'cat']);
    expect(comic.description, contains('12'));
  });

  test('built in source registry includes picacg', () {
    expect(ComicSource.builtIn.map((source) => source.key), contains('picacg'));
    final source =
        ComicSource.builtIn.firstWhere((source) => source.key == 'picacg');
    expect(source.account, isNotNull);
    expect(source.searchPageData, isNotNull);
    expect(source.favoriteData, isNotNull);
  });
}
