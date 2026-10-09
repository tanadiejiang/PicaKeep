import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';
import 'package:test/test.dart';

Map<String, dynamic> _work(String id, {String authorId = '42', int type = 0}) =>
    {
      'id': id,
      'title': 'Work $id',
      'url': 'https://i.pximg.net/$id.jpg',
      'userId': authorId,
      'userName': 'Artist $authorId',
      'illustType': type,
      'width': 100,
      'height': 200,
      'pageCount': 1,
      'isMasked': false,
      'xRestrict': 0,
      'isBookmarkable': true,
      'bookmarkData': null,
    };

void main() {
  test('init retains cross-author server order, manga, and continuation order',
      () {
    final page = parsePixivWorkRecommendations({
      'illusts': [
        _work('42'),
        _work('9', authorId: '50'),
        _work('100', authorId: '60', type: 1),
        _work('9'),
        {'isAdContainer': true},
      ],
      'nextIds': ['42', '9', '100', '20', '3', '20', 7, null, 'bad', '0'],
    }, sourceId: '42');
    expect(page.items.map((work) => work.id), ['9', '100']);
    expect(page.items.map((work) => work.authorId), ['50', '60']);
    expect(page.items.last.illustType, 1);
    expect(page.nextIds, ['20', '3', '7']);
    expect(() => page.items.clear(), throwsUnsupportedError);
    expect(() => page.nextIds.clear(), throwsUnsupportedError);
  });

  test('all valid init IDs are consumed even when unavailable or advertising',
      () {
    final page = parsePixivWorkRecommendations({
      'illusts': [
        {..._work('10'), 'isMasked': true},
        {..._work('11'), 'isMasked': 'broken'},
        {..._work('12'), 'xRestrict': 1},
        {..._work('13'), 'xRestrict': null},
        {..._work('14'), 'isAdContainer': true},
        {..._work('15'), 'isAdContainer': 'broken'},
        _work('-1'),
        _work('0'),
        _work('bad'),
        'not an object',
      ],
      'nextIds': ['10', '11', '12', '13', '14', '15', '16'],
    }, sourceId: '42');
    expect(page.items, isEmpty);
    expect(page.nextIds, ['16']);
  });

  test('init requires both arrays and a body object; valid empty is allowed',
      () {
    for (final body in [
      null,
      [],
      {},
      {'illusts': []},
      {'illusts': {}, 'nextIds': []},
      {'illusts': [], 'nextIds': null},
    ]) {
      expect(() => parsePixivWorkRecommendations(body, sourceId: '42'),
          throwsFormatException);
    }
    final empty = parsePixivWorkRecommendations({'illusts': [], 'nextIds': []},
        sourceId: '42');
    expect(empty.items, isEmpty);
    expect(empty.nextIds, isEmpty);
  });

  test(
      'batch keeps requested recommendation ranking and rejects unsolicited IDs',
      () {
    final works = parsePixivRecommendationWorks({
      'illusts': [
        _work('100'),
        _work('7'),
        _work('9', authorId: '50'),
        {..._work('9'), 'title': 'Duplicate'},
      ],
    }, requestedIds: [
      '9',
      '100',
      '9'
    ]);
    expect(works.map((work) => work.id), ['9', '100']);
    expect(works.first.title, 'Work 9');
    expect(works.first.authorId, '50');
  });

  test(
      'missing bookmark state remains unknown and supports on-demand resolution',
      () {
    final missing = _work('9')..remove('bookmarkData');
    final works = parsePixivRecommendationWorks({
      'illusts': [
        missing,
        {..._work('10'), 'isBookmarkable': false}
      ],
    }, requestedIds: [
      '9',
      '10'
    ]);
    expect(works.first.bookmarkStateKnown, isFalse);
    expect(works.first.canLoadBookmarkState, isTrue);
    expect(works.last.bookmarkStateKnown, isTrue);
    expect(works.last.isBookmarkable, isFalse);
    expect(works, hasLength(2));
  });

  test(
      'safe rules run before brief conversion and no cover is still a valid card',
      () {
    final noCover = _work('9')..remove('url');
    final works = parsePixivRecommendationWorks({
      'illusts': [
        {..._work('10'), 'isMasked': 1},
        {..._work('11'), 'xRestrict': '1'},
        {..._work('12'), 'xRestrict': 0.5},
        {..._work('13'), 'isAdContainer': true},
        noCover,
      ],
    }, requestedIds: [
      '9',
      '10',
      '11',
      '12',
      '13'
    ]);
    expect(works.single.id, '9');
    expect(works.single.cover, isEmpty);
    expect(() => works.clear(), throwsUnsupportedError);
  });

  test('batch requires illusts array but does not require continuation fields',
      () {
    for (final body in [
      null,
      [],
      {},
      {'illusts': {}},
      {'illusts': null}
    ]) {
      expect(() => parsePixivRecommendationWorks(body, requestedIds: ['9']),
          throwsFormatException);
    }
    expect(parsePixivRecommendationWorks({'illusts': []}, requestedIds: ['9']),
        isEmpty);
  });

  test(
      'author preview follows requested order, includes manga and validates author',
      () {
    final unknownAuthor = _work('3')..remove('userId');
    for (final rows in [
      {
        '100': _work('100', type: 1),
        '9': _work('9'),
        '7': _work('7', authorId: '43'),
        '3': unknownAuthor,
        'outside': _work('20'),
      },
      [
        _work('100', type: 1),
        _work('9'),
        _work('7', authorId: '43'),
        unknownAuthor,
        _work('20'),
      ],
    ]) {
      final works = parsePixivAuthorPreviewWorks({'works': rows},
          uid: '42', requestedIds: ['9', '3', '100', '7']);
      expect(works.map((work) => work.id), ['9', '3', '100']);
      expect(works.last.illustType, 1);
    }
  });

  test(
      'author preview treats valid fully filtered batches as empty, shapes as errors',
      () {
    for (final body in [
      null,
      [],
      {},
      {'works': null},
      {'works': 'bad'}
    ]) {
      expect(
          () => parsePixivAuthorPreviewWorks(body,
              uid: '42', requestedIds: ['9']),
          throwsFormatException);
    }
    expect(
        parsePixivAuthorPreviewWorks(
            {
              'works': {
                '9': {..._work('9'), 'isMasked': true}
              },
            },
            uid: '42',
            requestedIds: ['9']),
        isEmpty);
    expect(
        parsePixivAuthorPreviewWorks({'works': []},
            uid: '42', requestedIds: ['9']),
        isEmpty);
  });

  test('embedded author works retain their existing order and skip null slots',
      () {
    final embedded = parsePixivRelatedWorks({
      'userIllusts': {'100': null, '9': _work('9'), '3': _work('3')},
    }, currentId: '42');
    expect(embedded.map((work) => work.id), ['9', '3']);
    expect(
        parsePixivUserWorks({
          'works': {'3': _work('3'), '9': _work('9')},
        }).map((work) => work.id),
        ['9', '3']);
  });
}
