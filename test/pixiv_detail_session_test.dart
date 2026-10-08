import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/pages/online_comic/pixiv_detail_pager.dart';

PixivDetailEntry entry(String id) => PixivDetailEntry(
      key: id,
      comicId: id,
      builder: (_) => const SizedBox.shrink(),
    );

void main() {
  testWidgets('entry activity defaults to true outside a pager',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PixivDetailEntryScope(
        entry: entry('1'),
        child: Builder(
            builder: (context) =>
                Text('active:${PixivDetailEntryScope.isActiveOf(context)}')),
      ),
    ));
    expect(find.text('active:true'), findsOneWidget);
    expect(
        PixivDetailEntryScope.isActiveOf(
            tester.element(find.byType(MaterialApp))),
        isTrue);
  });

  testWidgets('pager only enables current visible entry and its tickers',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    PixivDetailEntry work(String id) => PixivDetailEntry(
        key: id,
        comicId: id,
        builder: (context) => Center(
                child: Text(
              '$id:${PixivDetailEntryScope.isActiveOf(context)}:'
              '${TickerMode.valuesOf(context).enabled}',
            )));
    final session = PixivDetailSession(
      scope: PixivDetailScope.search,
      entries: [work('first'), work('second')],
    );
    await tester.pumpWidget(MaterialApp(
      home: PixivDetailPager(session: session, initialKey: 'first'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('first:true:true'), findsOneWidget);
    final pager =
        tester.widget<PageView>(find.byKey(const Key('pixiv-work-pager')));
    pager.controller!.jumpTo(240);
    await tester.pump();
    await tester.pump();
    expect(find.text('first:false:false'), findsOneWidget);
    expect(find.text('second:true:true'), findsOneWidget);
    pager.controller!.jumpTo(160);
    await tester.pump();
    await tester.pump();
    expect(find.text('first:true:true'), findsOneWidget);
    expect(find.text('second:false:false'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });
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
