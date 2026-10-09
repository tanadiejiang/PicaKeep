import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/pixiv_detail_feeds.dart';
import 'package:picakeep/network/pixiv_network/pixiv_models.dart';
import 'package:picakeep/network/res.dart';

PixivComicBrief work(String id, {String author = '42'}) => PixivComicBrief(
      id: id,
      title: '作品$id',
      cover: '',
      author: '作者$author',
      authorId: author,
      tags: const [],
      illustType: pixivIllustTypeIllust,
      pageCount: 1,
    );

void main() {
  test('author preview fills five, keeps seed order and fetches only the gap',
      () async {
    var idsReads = 0;
    final batches = <List<String>>[];
    final preview = PixivAuthorPreviewController(
      workId: '1',
      authorId: '42',
      seed: [
        work('2'),
        work('1'),
        work('2'),
        work('3'),
        work('99', author: '7')
      ],
      ownerIsCurrent: () => true,
      loadIds: (_) async {
        idsReads++;
        return const Res(['1', '9', '8', '7', '6', '3', '2']);
      },
      loadWorks: (_, ids) async {
        batches.add(ids);
        return Res([work('99'), ...ids.reversed.map(work)]);
      },
    );
    addTearDown(preview.dispose);
    await preview.load();
    await preview.load();
    expect(preview.items.map((e) => e.id), ['2', '3', '9', '8', '7']);
    expect(batches, [
      ['9', '8', '7']
    ]);
    expect(idsReads, 1);
    expect(preview.hasMore, isFalse);
  });

  test('five embedded works require no profile reads', () async {
    final preview = PixivAuthorPreviewController(
      workId: '1',
      authorId: '42',
      seed: List.generate(8, (i) => work('${i + 2}')),
      ownerIsCurrent: () => true,
      loadIds: (_) async => throw StateError('unnecessary profile request'),
      loadWorks: (_, __) async => throw StateError('unnecessary hydration'),
    );
    addTearDown(preview.dispose);
    await preview.load();
    expect(preview.items, hasLength(5));
    expect(preview.error, isNull);
  });

  test('author filters consume candidates, with bounded automatic batches',
      () async {
    var idsReads = 0;
    final batches = <List<String>>[];
    final preview = PixivAuthorPreviewController(
      workId: '1',
      authorId: '42',
      seed: [work('2'), work('3')],
      ownerIsCurrent: () => true,
      loadIds: (_) async {
        idsReads++;
        return const Res(['1', '2', '3', '9', '8', '7', '6', '5', '4']);
      },
      loadWorks: (_, ids) async {
        batches.add(ids);
        if (ids.first == '9') return Res([work('9'), work('8', author: '7')]);
        if (ids.first == '4') return Res([work('4')]);
        return const Res([]);
      },
    );
    addTearDown(preview.dispose);
    await preview.load();
    expect(batches, [
      ['9', '8', '7'],
      ['6', '5']
    ]);
    expect(preview.items.map((e) => e.id), ['2', '3', '9']);
    expect(preview.hasMore, isTrue);
    await preview.load();
    expect(batches.last, ['4']);
    expect(idsReads, 1);
    expect(preview.hasMore, isFalse);
  });

  test('author batch failure keeps existing preview and retries same IDs',
      () async {
    var fail = true;
    var idsReads = 0;
    final batches = <List<String>>[];
    final preview = PixivAuthorPreviewController(
      workId: '1',
      authorId: '42',
      seed: [work('2')],
      ownerIsCurrent: () => true,
      loadIds: (_) async {
        idsReads++;
        return const Res(['3', '4']);
      },
      loadWorks: (_, ids) async {
        batches.add(ids);
        if (fail) return const Res.error('读取失败');
        return Res(ids.map(work).toList());
      },
    );
    addTearDown(preview.dispose);
    await preview.load();
    expect(preview.error, '读取失败');
    expect(preview.items.single.id, '2');
    fail = false;
    await preview.load();
    expect(batches, [
      ['3', '4'],
      ['3', '4']
    ]);
    expect(idsReads, 1);
    expect(preview.items.map((e) => e.id), ['2', '3', '4']);
    expect(preview.error, isNull);
  });

  test('recommendation queue keeps server order and allows other authors',
      () async {
    final batches = <List<String>>[];
    final feed = PixivWorkRecommendationsController(
      workId: '1',
      ownerIsCurrent: () => true,
      loadInitial: (_) async => Res(PixivRecommendationsPage(
          items: [work('20', author: '7'), work('30', author: '8')],
          nextIds: const ['30', '1', '40', '40', '50', 'invalid'])),
      loadWorks: (ids) async {
        batches.add(ids);
        return Res([work('50', author: '9'), work('999'), work('40')]);
      },
    );
    addTearDown(feed.dispose);
    await feed.load();
    await feed.loadMore();
    expect(batches, [
      ['40', '50']
    ]);
    expect(feed.items.map((e) => e.id), ['20', '30', '40', '50']);
    expect(feed.hasMore, isFalse);
    expect(feed.continuationPosition, 2);
  });

  test('empty filtered recommendation batch advances without automatic loop',
      () async {
    var reads = 0;
    final feed = PixivWorkRecommendationsController(
      workId: '1',
      ownerIsCurrent: () => true,
      accepts: (item) => item.id == '28',
      batchSize: 18,
      loadInitial: (_) async => Res(PixivRecommendationsPage(
          items: const [], nextIds: List.generate(19, (i) => '${i + 10}'))),
      loadWorks: (ids) async {
        reads++;
        return Res(ids.map(work).toList());
      },
    );
    addTearDown(feed.dispose);
    await feed.load();
    await feed.loadMore();
    expect(reads, 1);
    expect(feed.items, isEmpty);
    expect(feed.lastAddedCount, 0);
    expect(feed.continuationPosition, 18);
    expect(feed.hasMore, isTrue);
    await feed.loadMore();
    expect(feed.items.single.id, '28');
    expect(feed.hasMore, isFalse);
  });

  test(
      'failed recommendation batch retries original slice and serializes reads',
      () async {
    final pending = Completer<Res<List<PixivComicBrief>>>();
    final batches = <List<String>>[];
    var fail = true;
    final feed = PixivWorkRecommendationsController(
      workId: '1',
      ownerIsCurrent: () => true,
      loadInitial: (_) async =>
          const Res(PixivRecommendationsPage(items: [], nextIds: ['2', '3'])),
      loadWorks: (ids) {
        batches.add(ids);
        return fail
            ? pending.future
            : Future.value(Res(ids.map(work).toList()));
      },
    );
    addTearDown(feed.dispose);
    await feed.load();
    final first = feed.loadMore();
    final second = feed.loadMore();
    expect(batches, [
      ['2', '3']
    ]);
    pending.complete(const Res.error('网络失败'));
    await Future.wait([first, second]);
    expect(feed.error, '网络失败');
    expect(feed.continuationPosition, 0);
    fail = false;
    await feed.loadMore();
    expect(batches, [
      ['2', '3'],
      ['2', '3']
    ]);
    expect(feed.items.map((e) => e.id), ['2', '3']);
  });

  test('configured author ten fetches at most five IDs per read', () async {
    final batches = <List<String>>[];
    final preview = PixivAuthorPreviewController(
      workId: '1',
      authorId: '42',
      previewCount: 10,
      seed: [work('2'), work('3')],
      ownerIsCurrent: () => true,
      loadIds: (_) async => Res(List.generate(15, (i) => '${i + 10}')),
      loadWorks: (_, ids) async {
        batches.add(ids);
        return Res(ids.map(work).toList());
      },
    );
    addTearDown(preview.dispose);
    await preview.load();
    expect(batches.map((ids) => ids.length), [5, 3]);
    expect(preview.items, hasLength(10));
    expect(preview.hasMore, isFalse);
  });

  test('configured recommendation batches preserve over-return in local cache',
      () async {
    var reads = 0;
    final feed = PixivWorkRecommendationsController(
      workId: '1',
      batchSize: 3,
      ownerIsCurrent: () => true,
      loadInitial: (_) async => Res(PixivRecommendationsPage(
          items: List.generate(9, (i) => work('${i + 10}')),
          nextIds: const [])),
      loadWorks: (_) async {
        reads++;
        return const Res([]);
      },
    );
    addTearDown(feed.dispose);
    await feed.load();
    expect(feed.items, hasLength(3));
    expect(feed.hasMore, isTrue);
    await feed.loadMore();
    expect(feed.items, hasLength(6));
    await feed.loadMore();
    expect(feed.items, hasLength(9));
    expect(feed.hasMore, isFalse);
    expect(reads, 0);
  });

  test('replaced account or disposed feed ignores late data and errors',
      () async {
    var current = true;
    final pending = Completer<Res<PixivRecommendationsPage>>();
    final feed = PixivWorkRecommendationsController(
      workId: '1',
      ownerIsCurrent: () => current,
      loadInitial: (_) => pending.future,
      loadWorks: (_) async => const Res([]),
    );
    var notifications = 0;
    feed.addListener(() => notifications++);
    final request = feed.load();
    current = false;
    pending.complete(
        Res(PixivRecommendationsPage(items: [work('2')], nextIds: const [])));
    await request;
    expect(feed.items, isEmpty);
    expect(feed.initialized, isFalse);
    expect(notifications, 1);
    feed.dispose();
    await feed.loadMore();
    expect(feed.error, isNull);
  });
}
