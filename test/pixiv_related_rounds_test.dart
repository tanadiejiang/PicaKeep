import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/pixiv_detail_feeds.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/network/pixiv_network/pixiv_models.dart';
import 'package:picakeep/network/res.dart';

PixivComicBrief _work(String id) => PixivComicBrief(
    id: id,
    title: '作品$id',
    cover: '',
    author: '作者42',
    authorId: '42',
    tags: const [],
    illustType: 0,
    pageCount: 1);
List<PixivComicBrief> _works(int start, int count) =>
    List.generate(count, (index) => _work('${start + index}'));

void main() {
  test('default shows the full response and never reads next IDs on its own',
      () async {
    var initialReads = 0;
    var detailReads = 0;
    final feed = PixivWorkRecommendationsController(
      workId: '1',
      ownerIsCurrent: () => true,
      loadInitial: (_) async {
        initialReads++;
        return Res(PixivRecommendationsPage(
            items: _works(10, 7), nextIds: const ['30', '31']));
      },
      loadWorks: (_) async {
        detailReads++;
        return const Res([]);
      },
    );
    addTearDown(feed.dispose);
    await feed.load();
    await feed.load();
    expect(feed.batchSize, isNull);
    expect(feed.usesPixivCount, isTrue);
    expect(feed.items, hasLength(7));
    expect(initialReads, 1);
    expect(detailReads, 0);
    expect(feed.hasMore, isTrue);
    expect(feed.completedRounds, 1);
  });

  test('next explicit round follows server window and candidate order',
      () async {
    final batches = <List<String>>[];
    var initialReads = 0;
    final feed = PixivWorkRecommendationsController(
      workId: '1',
      ownerIsCurrent: () => true,
      loadInitial: (_) async {
        initialReads++;
        return Res(PixivRecommendationsPage(
            items: _works(10, 7),
            nextIds: List.generate(9, (i) => '${i + 30}')));
      },
      loadWorks: (ids) async {
        batches.add(ids);
        return Res(ids.reversed.map(_work).toList());
      },
    );
    addTearDown(feed.dispose);
    await feed.load();
    await feed.loadNextRound();
    expect(batches.single, List.generate(7, (i) => '${i + 30}'));
    expect(feed.items.map((work) => work.id), [
      ...List.generate(7, (i) => '${i + 10}'),
      ...List.generate(7, (i) => '${i + 30}')
    ]);
    expect(feed.lastAddedCount, 7);
    expect(initialReads, 1);
    await feed.loadNextRound();
    expect(batches.last, ['37', '38']);
    expect(feed.hasMore, isFalse);
    expect(feed.canLoadNextRound, isTrue);
    expect(feed.continuationPosition, 9);
    await feed.loadMore();
    expect(initialReads, 1,
        reason: 'snapshot continuation never restarts init');
  });

  test(
      'responses above transport window remain full and hydrate bounded slices',
      () async {
    final batches = <List<String>>[];
    final feed = PixivWorkRecommendationsController(
      workId: '1',
      ownerIsCurrent: () => true,
      loadInitial: (_) async => Res(PixivRecommendationsPage(
          items: _works(10, 23),
          nextIds: List.generate(23, (i) => '${i + 100}'))),
      loadWorks: (ids) async {
        batches.add(ids);
        return Res(ids.map(_work).toList());
      },
    );
    addTearDown(feed.dispose);
    await feed.load();
    expect(feed.items, hasLength(23));
    expect(batches, isEmpty);
    await feed.loadNextRound();
    expect(batches.map((ids) => ids.length), [18, 5]);
    expect(feed.items, hasLength(46));
    expect(feed.completedRounds, 2);
    expect(feed.lastAddedCount, 23);
    expect(feed.continuationPosition, 23);
  });

  test('manual count still reveals cached over-return without network reads',
      () async {
    var initialReads = 0;
    var detailsReads = 0;
    final feed = PixivWorkRecommendationsController(
      workId: '1',
      batchSize: 3,
      ownerIsCurrent: () => true,
      loadInitial: (_) async {
        initialReads++;
        return Res(
            PixivRecommendationsPage(items: _works(10, 9), nextIds: const []));
      },
      loadWorks: (_) async {
        detailsReads++;
        return const Res([]);
      },
    );
    addTearDown(feed.dispose);
    await feed.load();
    expect(feed.items, hasLength(3));
    await feed.loadNextRound();
    expect(feed.items, hasLength(6));
    await feed.loadNextRound();
    expect(feed.items, hasLength(9));
    expect(initialReads, 1);
    expect(detailsReads, 0);
    expect(feed.completedRounds, 3);
  });

  test(
      'queue exhaustion allows only explicit fresh init with global deduplication',
      () async {
    var reads = 0;
    final feed = PixivWorkRecommendationsController(
      workId: '1',
      ownerIsCurrent: () => true,
      loadInitial: (_) async {
        reads++;
        return Res(PixivRecommendationsPage(
            items: reads == 1
                ? _works(10, 7)
                : [
                    _work('1'),
                    _work('10'),
                    _work('20'),
                    _work('20'),
                    _work('21')
                  ],
            nextIds: const []));
      },
      loadWorks: (_) async => throw StateError('no known queue'),
    );
    addTearDown(feed.dispose);
    await feed.load();
    expect(feed.hasMore, isFalse);
    await feed.load();
    await feed.loadMore();
    expect(reads, 1);
    await feed.loadNextRound();
    expect(reads, 2);
    expect(feed.items.map((work) => work.id),
        [...List.generate(7, (i) => '${i + 10}'), '20', '21']);
    expect(feed.lastAddedCount, 2);
    expect(feed.completedRounds, 2);
  });

  test('repeated identical rounds report zero additions with no automatic loop',
      () async {
    var reads = 0;
    final feed = PixivWorkRecommendationsController(
      workId: '1',
      ownerIsCurrent: () => true,
      loadInitial: (_) async {
        reads++;
        return Res(
            PixivRecommendationsPage(items: _works(10, 7), nextIds: const []));
      },
      loadWorks: (_) async => const Res([]),
    );
    addTearDown(feed.dispose);
    await feed.load();
    await feed.loadNextRound();
    expect(reads, 2);
    expect(feed.items, hasLength(7));
    expect(feed.lastAddedCount, 0);
    expect(feed.error, isNull);
    expect(feed.hasMore, isFalse);
    expect(feed.canLoadNextRound, isTrue);
    await Future<void>.value();
    expect(reads, 2);
  });

  test('failed fresh round preserves previous items and busy reads serialize',
      () async {
    final pending = Completer<Res<PixivRecommendationsPage>>();
    var reads = 0;
    var retry = false;
    final feed = PixivWorkRecommendationsController(
      workId: '1',
      ownerIsCurrent: () => true,
      loadInitial: (_) async {
        reads++;
        if (reads == 1) {
          return Res(PixivRecommendationsPage(
              items: _works(10, 7), nextIds: const []));
        }
        if (retry) {
          return Res(PixivRecommendationsPage(
              items: _works(20, 2), nextIds: const []));
        }
        return pending.future;
      },
      loadWorks: (_) async => const Res([]),
    );
    addTearDown(feed.dispose);
    await feed.load();
    final first = feed.loadNextRound();
    final second = feed.loadNextRound();
    expect(reads, 2);
    pending.complete(const Res.error('下一轮失败'));
    await Future.wait([first, second]);
    expect(feed.error, '下一轮失败');
    expect(feed.items, hasLength(7));
    expect(feed.completedRounds, 1);
    expect(feed.busy, isFalse);
    retry = true;
    await feed.loadNextRound();
    expect(feed.items, hasLength(9));
    expect(feed.error, isNull);
  });

  test(
      'a later transport failure commits no partial round and retry keeps order',
      () async {
    var fail = true;
    final batches = <List<String>>[];
    final feed = PixivWorkRecommendationsController(
      workId: '1',
      ownerIsCurrent: () => true,
      loadInitial: (_) async => Res(PixivRecommendationsPage(
          items: _works(10, 23),
          nextIds: List.generate(23, (i) => '${i + 100}'))),
      loadWorks: (ids) async {
        batches.add(ids);
        if (ids.length == 5 && fail) return const Res.error('后段失败');
        return Res(ids.reversed.map(_work).toList());
      },
    );
    addTearDown(feed.dispose);
    await feed.load();
    await feed.loadNextRound();
    expect(feed.items, hasLength(23));
    expect(feed.continuationPosition, 0);
    expect(feed.completedRounds, 1);
    expect(feed.error, '后段失败');
    fail = false;
    await feed.loadNextRound();
    expect(batches.map((ids) => ids.length), [18, 5, 18, 5]);
    expect(feed.items.skip(23).map((work) => work.id),
        List.generate(23, (i) => '${i + 100}'));
    expect(feed.continuationPosition, 23);
    expect(feed.error, isNull);
  });

  test(
      'owner invalidation after a transport read prevents further reads and commit',
      () async {
    var current = true;
    var reads = 0;
    final pending = Completer<Res<List<PixivComicBrief>>>();
    final feed = PixivWorkRecommendationsController(
      workId: '1',
      ownerIsCurrent: () => current,
      loadInitial: (_) async => Res(PixivRecommendationsPage(
          items: _works(10, 23),
          nextIds: List.generate(23, (i) => '${i + 100}'))),
      loadWorks: (_) {
        reads++;
        return pending.future;
      },
    );
    addTearDown(feed.dispose);
    await feed.load();
    final request = feed.loadNextRound();
    current = false;
    pending.complete(Res(_works(100, 18)));
    await request;
    expect(reads, 1);
    expect(feed.items, hasLength(23));
    expect(feed.continuationPosition, 0);
    expect(feed.busy, isFalse);
  });

  test('a detail snapshot does not generate new rounds by reaching its end',
      () async {
    var reads = 0;
    final feed = PixivWorkRecommendationsController(
      workId: '1',
      ownerIsCurrent: () => true,
      loadInitial: (_) async {
        reads++;
        return Res(
            PixivRecommendationsPage(items: _works(10, 7), nextIds: const []));
      },
      loadWorks: (_) async => const Res([]),
    );
    addTearDown(feed.dispose);
    await feed.load();
    final session = PixivDetailSession(
      scope: PixivDetailScope.related,
      entries: const [],
      hasMore: feed.hasMore,
      loadMore: () async {
        await feed.loadMore();
        return const PixivDetailBatch([], hasMore: false);
      },
    );
    addTearDown(session.dispose);
    await session.requestMore();
    expect(session.hasMore, isFalse);
    expect(reads, 1);
    expect(feed.canLoadNextRound, isTrue);
  });
}
