import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';

PixivDetailEntry entry(String id) => PixivDetailEntry(
      key: id,
      comicId: id,
      builder: (_) => const SizedBox.shrink(),
    );

void main() {
  test('deduplicates batches and serializes continuation', () async {
    var calls = 0;
    final session = PixivDetailSession(
      scope: PixivDetailScope.search,
      entries: [entry('1')],
      hasMore: true,
      loadMore: () async {
        calls++;
        await Future<void>.delayed(Duration.zero);
        return PixivDetailBatch([entry('1'), entry('2')], hasMore: false);
      },
    );
    await Future.wait([session.requestMore(), session.requestMore()]);
    expect(calls, 1);
    expect(session.entries.map((e) => e.key), ['1', '2']);
    expect(session.hasMore, isFalse);
    session.dispose();
  });

  test('platform favorite mutation stops stale offset continuation', () async {
    final session = PixivDetailSession(
      scope: PixivDetailScope.platformFavorites,
      entries: [entry('1')],
      hasMore: true,
      loadMore: () async => const PixivDetailBatch([], hasMore: true),
    );
    session.invalidatePagination();
    expect(session.hasMore, isFalse);
    expect(session.error, contains('收藏已更新'));
    session.dispose();
  });

  test('owner invalidation prevents appending a different query', () async {
    var current = true;
    final session = PixivDetailSession(
      scope: PixivDetailScope.author,
      entries: [entry('1')],
      hasMore: true,
      ownerIsCurrent: () => current,
      loadMore: () async {
        current = false;
        return PixivDetailBatch([entry('2')], hasMore: false);
      },
    );
    await session.requestMore();
    expect(session.entries.map((e) => e.key), ['1']);
    expect(session.error, contains('入口已变化'));
    session.dispose();
  });
}
