import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';
import 'package:test/test.dart';

// Synthetic fixtures of the containers used by the pinned ppixiv source.
// They are not live/cookie-derived responses. The API evidence is documented
// beside parsePixivRecommendedAuthors and getRecommendedAuthors.
Map<String, dynamic> _author(dynamic uid, {bool followed = false}) => {
      'userId': uid,
      'name': 'Artist $uid',
      'image': 'https://i.pximg.net/$uid-avatar-50.jpg',
      'imageBig': 'https://i.pximg.net/$uid-avatar-170.jpg',
      'comment': 'Line one\r\nLine two',
      'isFollowed': followed,
    };

Map<String, dynamic> _work(dynamic id, dynamic uid, {int type = 0}) => {
      'id': id,
      'title': 'Work $id',
      'userId': uid,
      'userName': 'Artist $uid',
      'url': 'https://i.pximg.net/$id.jpg',
      'profileImageUrl': 'https://i.pximg.net/$uid-avatar-50.jpg',
      'illustType': type,
      'width': 200,
      'height': 300,
      'pageCount': 1,
      'isMasked': false,
      'xRestrict': 0,
      'isBookmarkable': true,
      'bookmarkData': null,
    };

Map<String, dynamic> _body({
  List<dynamic> recommendations = const [],
  List<dynamic> users = const [],
  List<dynamic> works = const [],
}) =>
    {
      'recommendUsers': recommendations,
      'users': users,
      'thumbnails': {'illust': works, 'novel': []},
    };

void main() {
  test('joins multiple UIDs in recommendation and embedded illustration order',
      () {
    final result = parsePixivRecommendedAuthors(_body(
      recommendations: [
        {
          'userId': '50',
          'illustIds': ['9', '100', '3']
        },
        {
          'userId': 60,
          'illustIds': [20, '7']
        },
      ],
      users: [_author(60, followed: true), _author('50')],
      works: [
        _work('100', '50', type: 1),
        _work('7', '60', type: 2),
        _work('9', '50'),
        _work('20', 60),
        _work('3', '50'),
      ],
    ));
    expect(result.map((item) => item.author.id), ['50', '60']);
    expect(result.first.works.map((work) => work.id), ['9', '100', '3']);
    expect(result.last.works.map((work) => work.id), ['20', '7']);
    expect(result.first.author.name, 'Artist 50');
    expect(result.first.author.avatar, 'https://i.pximg.net/50-avatar-170.jpg');
    expect(result.first.author.comment, 'Line one\nLine two');
    expect(result.first.author.isFollowed, isFalse);
    expect(result.last.author.isFollowed, isTrue);
    expect(result.last.works.first.authorId, '60');
    expect(result.first.works[1].illustType, 1);
    expect(result.last.works.last.illustType, 2);
    expect(() => result.clear(), throwsUnsupportedError);
    expect(() => result.first.works.clear(), throwsUnsupportedError);
  });

  test('deduplicates UID and work links and excludes the seed author', () {
    final result = parsePixivRecommendedAuthors(
        _body(
          recommendations: [
            {
              'userId': '42',
              'illustIds': ['42']
            },
            {
              'userId': '50',
              'illustIds': ['9', '9', 100]
            },
            {
              'userId': 50,
              'illustIds': ['3']
            },
            {
              'userId': '60',
              'illustIds': ['7']
            },
          ],
          users: [
            _author('42'),
            _author('50'),
            {..._author(50), 'name': 'Duplicate metadata'},
            _author('60'),
          ],
          works: [
            _work('42', '42'),
            _work('9', '50'),
            {..._work(9, '50'), 'title': 'Duplicate image'},
            _work(100, '50'),
            _work('3', '50'),
            _work('7', '60'),
          ],
        ),
        seedAuthorId: ' 42 ');
    expect(result.map((item) => item.author.id), ['50', '60']);
    expect(result.first.author.name, 'Artist 50');
    expect(result.first.works.map((work) => work.id), ['9', '100']);
    expect(result.first.works.first.title, 'Work 9');
  });

  test(
      'bounds oversized server data to five authors and three works per author',
      () {
    final result = parsePixivRecommendedAuthors(_body(
      recommendations: [
        for (var uid = 1; uid <= 8; uid++)
          {
            'userId': uid,
            'illustIds': [
              for (var index = 0; index < 6; index++) uid * 10 + index
            ]
          },
      ],
      users: [for (var uid = 1; uid <= 8; uid++) _author(uid)],
      works: [
        for (var uid = 8; uid >= 1; uid--)
          for (var index = 5; index >= 0; index--) _work(uid * 10 + index, uid),
      ],
    ));
    expect(result.map((item) => item.author.id), ['1', '2', '3', '4', '5']);
    expect(result.every((item) => item.works.length == 3), isTrue);
    expect(result.first.works.map((work) => work.id), ['10', '11', '12']);
    final smaller = parsePixivRecommendedAuthors(
        _body(
          recommendations: [
            {
              'userId': '50',
              'illustIds': ['9', '100', '3']
            },
            {'userId': '60', 'illustIds': []},
          ],
          users: [_author('50'), _author('60')],
          works: [_work('100', '50'), _work('3', '50'), _work('9', '50')],
        ),
        limit: 1,
        workLimit: 2);
    expect(smaller, hasLength(1));
    expect(smaller.single.works.map((work) => work.id), ['9', '100']);
  });

  test('applies raw mask/restriction/ad filtering before counting safe slots',
      () {
    final result = parsePixivRecommendedAuthors(_body(
      recommendations: [
        {
          'userId': '50',
          'illustIds': [for (var id = 1; id <= 13; id++) id]
        },
      ],
      users: [_author('50')],
      works: [
        {..._work(1, '50'), 'isMasked': true},
        {..._work(2, '50'), 'isMasked': 'broken'},
        {..._work(3, '50'), 'xRestrict': 1},
        {..._work(4, '50'), 'xRestrict': 2},
        {..._work(5, '50'), 'xRestrict': null},
        {..._work(6, '50'), 'xRestrict': 0.5},
        {..._work(7, '50'), 'isAdContainer': true},
        {..._work(8, '50'), 'isAdContainer': 'broken'},
        {..._work(9, '50'), 'xRestrict': '1'},
        {..._work(10, '50'), 'isMasked': 'false', 'xRestrict': '0'},
        {..._work(11, '50'), 'isAdContainer': false},
        _work(12, '50'),
        _work(13, '50'),
      ],
    ));
    expect(result.single.works.map((work) => work.id), ['10', '11', '12']);
  });

  test('does not replace an unavailable first thumbnail with its duplicate',
      () {
    final result = parsePixivRecommendedAuthors(_body(
      recommendations: [
        {
          'userId': '50',
          'illustIds': ['9']
        },
      ],
      users: [_author('50')],
      works: [
        {..._work('9', '50'), 'isMasked': true},
        _work('9', '50'),
      ],
    ));
    expect(result.single.works, isEmpty);
  });

  test(
      'keeps explicit capability false and unknown bookmarks for on-demand reads',
      () {
    final missingState = _work('9', '50')..remove('bookmarkData');
    final result = parsePixivRecommendedAuthors(_body(
      recommendations: [
        {
          'userId': '50',
          'illustIds': ['9', '100', '3']
        },
      ],
      users: [_author('50')],
      works: [
        missingState,
        {
          ..._work('100', '50'),
          'isBookmarkable': false,
          'bookmarkData': {'id': '900', 'private': true}
        },
        {..._work('3', '50'), 'isBookmarkable': false},
      ],
    ));
    final works = result.single.works;
    expect(works, hasLength(3));
    expect(works.first.bookmarkStateKnown, isFalse);
    expect(works.first.canLoadBookmarkState, isTrue);
    expect(works.first.isBookmarked, isFalse);
    expect(works[1].bookmarkStateKnown, isTrue);
    expect(works[1].isBookmarked, isTrue);
    expect(works[1].isBookmarkable, isFalse);
    expect(works[1].canLoadBookmarkState, isFalse);
    expect(works.last.bookmarkStateKnown, isTrue);
    expect(works.last.isBookmarked, isFalse);
    expect(works.last.isBookmarkable, isFalse);
  });

  test(
      'does not use novel IDs, unsolicited works or another author\'s thumbnail',
      () {
    final body = _body(
      recommendations: [
        {
          'userId': '50',
          'illustIds': ['9', '100'],
          'novelIds': ['20']
        },
      ],
      users: [_author('50')],
      works: [_work('100', '60'), _work('9', '50'), _work('3', '50')],
    );
    (body['thumbnails'] as Map)['novel'] = [_work('20', '50')];
    final result = parsePixivRecommendedAuthors(body);
    expect(result.single.works.map((work) => work.id), ['9']);
  });

  test('missing metadata and invalid IDs do not trigger fabricated records',
      () {
    final result = parsePixivRecommendedAuthors(_body(
      recommendations: [
        null,
        'bad row',
        {'userId': 'bad', 'illustIds': []},
        {'userId': '0', 'illustIds': []},
        {
          'userId': '60',
          'illustIds': ['7']
        },
        {
          'userId': '50',
          'illustIds': ['0', '-1', 'bad', null, '9', '100']
        },
      ],
      users: [null, _author('bad'), _author('0'), _author('50')],
      works: [null, _work('0', '50'), _work('-1', '50'), _work('9', '50')],
    ));
    expect(result.single.author.id, '50');
    expect(result.single.works.single.id, '9');
  });

  test('requires all three known containers; legal empty is distinct', () {
    for (final body in [
      null,
      [],
      {},
      {'recommendUsers': []},
      {..._body(), 'recommendUsers': {}},
      {..._body(), 'users': {}},
      {..._body(), 'thumbnails': []},
      {..._body(), 'thumbnails': {}},
      {
        ..._body(),
        'thumbnails': {'illust': null}
      },
      {
        ..._body(),
        'thumbnails': {'illust': {}}
      },
      {
        'recommendedUsers': [],
        'users': [],
        'thumbnails': {'illust': []}
      },
    ]) {
      expect(() => parsePixivRecommendedAuthors(body), throwsFormatException);
    }
    expect(parsePixivRecommendedAuthors(_body()), isEmpty);
    final allFiltered = parsePixivRecommendedAuthors(_body(
      recommendations: [
        {
          'userId': '50',
          'illustIds': ['9']
        }
      ],
      users: [_author('50')],
      works: [
        {..._work('9', '50'), 'xRestrict': 1}
      ],
    ));
    expect(allFiltered.single.works, isEmpty);
  });

  test('wrong per-author illustration link shape is a parse error', () {
    for (final links in [null, {}, '9']) {
      expect(
          () => parsePixivRecommendedAuthors(_body(
                recommendations: [
                  {'userId': '50', 'illustIds': links}
                ],
                users: [_author('50')],
              )),
          throwsFormatException);
    }
    expect(
        () => parsePixivRecommendedAuthors(_body(
              recommendations: [
                {'userId': '50', 'recentIllustIds': []}
              ],
              users: [_author('50')],
            )),
        throwsFormatException);
  });

  test('parser cannot loosen the client author or work bounds', () {
    for (final limit in [-1, 0, 6]) {
      expect(() => parsePixivRecommendedAuthors(_body(), limit: limit),
          throwsFormatException);
    }
    for (final workLimit in [-1, 0, 4]) {
      expect(() => parsePixivRecommendedAuthors(_body(), workLimit: workLimit),
          throwsFormatException);
    }
  });
}
