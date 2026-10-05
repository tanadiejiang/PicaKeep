import 'dart:convert';
import 'dart:io';

import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';
import 'package:test/test.dart';

Map<String, dynamic> _fixture(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map)
        .map((key, value) => MapEntry(key.toString(), value));

Map<String, dynamic> _work(String id,
        {Object? mask = false, Object? restrict = 0}) =>
    {
      'id': id,
      'title': 'Work $id',
      'url': 'https://i.pximg.net/$id.jpg',
      'userId': '42',
      'userName': 'Artist',
      'width': 100,
      'height': 200,
      'isMasked': mask,
      'xRestrict': restrict,
      'bookmarkData': null,
      'isBookmarkable': true,
    };

void main() {
  group('embedded detail works', () {
    test('archived 78 slots produce exactly 12 other works without hydration',
        () {
      final root =
          _fixture('Z-plan/新需求-主线-第十九轮/005-附件-Pixiv响应实测/illust_150378023.json');
      final body = Map<String, dynamic>.from(root['body'] as Map);
      final raw = body['userIllusts'] as Map;
      final info = parsePixivComicInfo(body);
      expect(raw, hasLength(78));
      expect(raw.values.whereType<Map>(), hasLength(13));
      expect(info.relatedWorks, hasLength(12));
      expect(
          info.relatedWorks.map((work) => work.id), isNot(contains(info.id)));
      final expectedOrder =
          raw.values.whereType<Map>().map((work) => work['id']);
      expect(info.relatedWorks.map((work) => work.id),
          expectedOrder.where((id) => id != info.id));
      expect(info.relatedWorks.every((work) => work.authorId == '1960050'),
          isTrue);
      expect(() => info.relatedWorks.clear(), throwsUnsupportedError);
      expect(info.regularUrl, contains('150378023_p0'));
      expect(info.isBookmarkable, isTrue);
      expect(info.bookmarkPrivate, isNull);
    });

    test(
        'objects retain order and skip masked, restricted, invalid and duplicate IDs',
        () {
      final result = parsePixivRelatedWorks({
        'userIllusts': {
          'null': null,
          'current': _work('42'),
          'first': _work('9'),
          'masked': _work('10', mask: true),
          'maskedUnknown': _work('11', mask: 'broken'),
          'restricted': _work('12', restrict: 1),
          'restrictionUnknown': _work('13', restrict: null),
          'fractionalRestriction': _work('14', restrict: 0.5),
          'invalid': _work('bad'),
          'zero': _work('0'),
          'duplicate': _work('9'),
          'last': _work('3'),
          'scalar': 'not an object',
        }
      }, currentId: '42');
      expect(result.map((work) => work.id), ['9', '3']);
      expect(result.first.isBookmarkable, isTrue);
      expect(result.first.width, 100);
      expect(parsePixivRelatedWorks({}, currentId: '42'), isEmpty);
      expect(parsePixivRelatedWorks({'userIllusts': []}, currentId: '42'),
          isEmpty);
    });
  });

  group('detail capability and visibility', () {
    test(
        'missing top-level capability can use only the available same-ID object',
        () {
      final body = <String, dynamic>{
        'id': '42',
        'userIllusts': {'42': _work('42'), '3': _work('3')},
      };
      expect(parsePixivComicInfo(body).isBookmarkable, isTrue);
      body['isBookmarkable'] = false;
      expect(parsePixivComicInfo(body).isBookmarkable, isFalse);
      body['isBookmarkable'] = 'broken';
      expect(parsePixivComicInfo(body).isBookmarkable, isNull);
      body.remove('isBookmarkable');
      for (final wrong in [
        null,
        _work('3'),
        _work('42', mask: true),
        _work('42', restrict: 1)
      ]) {
        body['userIllusts'] = {'42': wrong, '3': _work('3')};
        expect(parsePixivComicInfo(body).isBookmarkable, isNull);
      }
    });

    test('only explicit boolean and valid 0/1 establish nullable fields', () {
      for (final pair in <(Object, bool)>[
        (true, true),
        (false, false),
        (1, true),
        (0, false),
        ('1', true),
        ('0', false),
        ('true', true),
        ('false', false),
      ]) {
        final info = parsePixivComicInfo({
          'id': 42,
          'userId': 99,
          'isBookmarkable': pair.$1,
          'bookmarkData': {'id': 300, 'private': pair.$1},
        });
        expect(info.isBookmarkable, pair.$2);
        expect(info.bookmarkPrivate, pair.$2);
        expect(info.authorId, '99');
        expect(info.id, '42');
      }
      for (final bad in [null, 2, -1, 0.5, '', 'yes', {}, []]) {
        final info = parsePixivComicInfo({
          'id': '42',
          'isBookmarkable': bad,
          'bookmarkData': {'id': '300', 'private': bad},
        });
        expect(info.isBookmarkable, isNull, reason: '$bad');
        expect(info.bookmarkPrivate, isNull, reason: '$bad');
        expect(info.isBookmarked, isTrue);
      }
      expect(parsePixivComicInfo({'id': '42'}).isBookmarkable, isNull);
    });

    test(
        'copy changes bookmark only and can clear nullable identity and privacy',
        () {
      final original = parsePixivComicInfo({
        'id': '42',
        'title': 'Original',
        'bookmarkData': {'id': '300', 'private': true},
        'isBookmarkable': false,
        'urls': {'original': 'original.jpg', 'regular': 'regular.jpg'},
        'profileImageUrl': 'avatar.jpg',
        'commentCount': 48,
        'userIllusts': {'3': _work('3')},
      });
      final preserved = original.copyWith(isBookmarked: false);
      expect(preserved.bookmarkId, '300');
      expect(preserved.bookmarkPrivate, isTrue);
      expect(preserved.isBookmarkable, isFalse);
      expect(preserved.relatedWorks, same(original.relatedWorks));
      expect(preserved.title, 'Original');
      expect(preserved.regularUrl, 'regular.jpg');
      expect(preserved.coverUrl, 'original.jpg');
      expect(preserved.authorAvatar, 'avatar.jpg');
      expect(preserved.commentCount, 48);
      final cleared = original.copyWith(
          isBookmarked: false,
          bookmarkId: null,
          bookmarkPrivate: null,
          isBookmarkable: null);
      expect(cleared.bookmarkId, isNull);
      expect(cleared.bookmarkPrivate, isNull);
      expect(cleared.isBookmarkable, isNull);
      expect(original.bookmarkPrivate, isTrue);
    });
  });

  group('image page slots', () {
    test('invalid second slot never renumbers the third image', () {
      final pages = parsePixivPages([
        {
          'urls': {'regular': 'first.jpg'},
          'width': 100,
          'height': 200
        },
        null,
        'broken',
        {
          'urls': {'original': 'fourth.jpg'},
          'width': 300,
          'height': 150
        },
      ]);
      expect(pages, hasLength(4));
      expect(pages[0].regular, 'first.jpg');
      expect(pages[1].original, isEmpty);
      expect(pages[2].original, isEmpty);
      expect(pages[3].original, 'fourth.jpg');
      expect((pages[3].width, pages[3].height), (300, 150));
    });
  });

  group('read-only comments', () {
    test('actual roots retain 6 text comments, 14 stickers, and raw count 20',
        () {
      final root = _fixture(
          'docs/verification/pixiv-detail-013/comments-roots-150378023.json');
      final page = parsePixivComments(root['body']);
      expect(page.originalCount, 20);
      expect(page.comments, hasLength(20));
      expect(page.hasNext, isTrue);
      expect(page.comments.where((comment) => comment.comment.isNotEmpty),
          hasLength(6));
      expect(page.comments.where((comment) => comment.stampId != null),
          hasLength(14));
      expect(page.comments.first.stampUrl,
          'https://s.pximg.net/common/images/stamp/generated-stamps/303_s.jpg');
      expect(
          page.comments.any((comment) => comment.comment.contains('(heart)')),
          isTrue);
      expect(page.comments.first.hasReplies, isFalse);
      expect(() => page.comments.clear(), throwsUnsupportedError);
    });

    test(
        'actual first-level reply tolerates absent flags and null recipient name',
        () {
      final root = _fixture(
          'docs/verification/pixiv-detail-013/comments-replies-235308916.json');
      final page = parsePixivComments(root['body']);
      final reply = page.comments.single;
      expect(page.originalCount, 1);
      expect(page.hasNext, isFalse);
      expect(reply.id, '235320186');
      expect(reply.rootId, '235308916');
      expect(reply.parentId, '235308916');
      expect(reply.replyToUserId, '6064850');
      expect(reply.replyToUserName, isNull);
      expect(reply.isDeletedUser, isNull);
      expect(reply.hasReplies, isNull);
      expect(reply.stampId, 304);
    });

    test('filtered and duplicate rows still count toward roots offset', () {
      final page = parsePixivComments({
        'comments': [
          null,
          {'id': '10', 'comment': '<script>alert(1)</script>(heart)'},
          {'id': 'bad'},
          {'id': '10', 'comment': 'duplicate'},
          {'id': 11, 'stampId': '../303', 'stampLink': 'https://evil.invalid'},
          {'id': '12', 'stampId': -1},
          {'id': '13', 'stampId': 303.5},
        ],
        'hasNext': true,
      });
      expect(page.originalCount, 7);
      expect(
          page.comments.map((comment) => comment.id), ['10', '11', '12', '13']);
      expect(page.comments.first.comment, '<script>alert(1)</script>(heart)');
      expect(page.comments.skip(1).every((comment) => comment.stampUrl == null),
          isTrue);
      expect(pixivCommentStampUrl(0), isNull);
      expect(pixivCommentStampUrl(-1), isNull);
      expect(
          parsePixivComments({'comments': [], 'hasNext': true})
              .isEmptyPageWithMore,
          isTrue);
    });

    test('shape changes fail explicitly instead of pretending no comments', () {
      for (final body in [
        null,
        [],
        {},
        {'comments': [], 'hasNext': 2}
      ]) {
        expect(() => parsePixivComments(body), throwsFormatException);
      }
      final empty = parsePixivComments({'comments': [], 'hasNext': false});
      expect(empty.hasNext, isFalse);
      expect(empty.originalCount, 0);
    });
  });
}
