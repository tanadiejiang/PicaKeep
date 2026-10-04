import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';
import 'package:test/test.dart';

// Field shape from the archived visitor discovery response (2026-10-04).
Map<String, dynamic> _visitor() => {
      'id': '150413246',
      'title': '负け火花',
      'userId': '22300147',
      'userName': 'よしなお',
      'profileImageUrl': 'https://i.pximg.net/user-profile/avatar_50.jpg',
      'url': 'https://i.pximg.net/c/360x360_70/image_square1200.jpg',
      'width': 2313,
      'height': 3541,
      'pageCount': 2,
      'tags': ['漫画', '崩壊:スターレイル'],
      'bookmarkData': null,
      'isBookmarkable': true,
    };

void main() {
  test('discovery visitor fields preserve avatar, author, tags and proportions',
      () {
    final item = parsePixivDiscoveryItems({
      'illusts': [_visitor()]
    }).single;
    expect(item.authorId, '22300147');
    expect(item.authorAvatar, endsWith('_50.jpg'));
    expect(item.isBookmarked, isFalse);
    expect(item.isBookmarkable, isTrue);
    expect(item.bookmarkStateKnown, isTrue);
    expect(item.canLoadBookmarkState, isFalse);
    expect(item.tags, ['漫画', '崩壊:スターレイル']);
    expect((item.width, item.height, item.pageCount), (2313, 3541, 2));
    expect(pixivProportionalThumbUrl(item.cover), contains('_master1200.jpg'));
  });

  test('logged-in search and user works share metadata and confirmed copy', () {
    final raw = _visitor()..['bookmarkData'] = {'id': '9876', 'private': false};
    final search = parsePixivSearchItems({
      'illustManga': {
        'data': [raw]
      }
    }).single;
    final works = parsePixivUserWorks({
      'works': {'150413246': raw}
    }).single;
    expect(search.isBookmarked, isTrue);
    expect(works.isBookmarked, isTrue);
    expect(works.authorId, search.authorId);
    final changed = search.copyWith(isBookmarked: false);
    expect(changed.isBookmarked, isFalse);
    expect(search.isBookmarked, isTrue);
    expect(changed.authorAvatar, search.authorAvatar);
    expect(changed.authorId, search.authorId);
    expect(changed.isBookmarkable, isTrue);
    expect(changed.tags, same(search.tags));
    expect((changed.id, changed.width, changed.height, changed.cover),
        (search.id, search.width, search.height, search.cover));
  });

  test('missing capability and malformed bookmark are conservative', () {
    final raw = _visitor()
      ..remove('isBookmarkable')
      ..remove('profileImageUrl')
      ..remove('userId')
      ..['bookmarkData'] = 'unexpected';
    final item = parsePixivDiscoveryItems({
      'illusts': [raw]
    }).single;
    expect(item.authorId, isEmpty);
    expect(item.authorAvatar, isEmpty);
    expect(item.isBookmarkable, isFalse);
    expect(item.isBookmarked, isFalse);
    expect(item.bookmarkStateKnown, isFalse);
    expect(item.canLoadBookmarkState, isTrue);
    raw['isBookmarkable'] = false;
    expect(
        parsePixivBookmarkItems({
          'works': [raw]
        }).single.isBookmarkable,
        isFalse);
  });

  test(
      'missing or malformed bookmark state stays unknown even when adding is disabled',
      () {
    for (final bookmarkable in [true, false]) {
      final raw = _visitor()
        ..remove('bookmarkData')
        ..['isBookmarkable'] = bookmarkable;
      final item = parsePixivDiscoveryItems({
        'illusts': [raw]
      }).single;
      expect(item.isBookmarked, isFalse);
      expect(item.bookmarkStateKnown, isFalse);
      expect(item.canLoadBookmarkState, isTrue);
    }
  });
}
