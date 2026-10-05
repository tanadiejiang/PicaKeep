import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/network/pixiv_network/pixiv_models.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/pixiv_comments_section.dart';

PixivComment _comment(String id,
        {bool replies = false, String text = 'hello'}) =>
    PixivComment(
      id: id,
      userId: 'u$id',
      userName: 'user$id',
      avatarUrl: '',
      comment: text,
      commentDate: '2026-10-04',
      hasReplies: replies,
    );

PixivCommentPage _page(List<PixivComment> comments,
        {bool hasNext = false, int? rawCount}) =>
    PixivCommentPage(
      comments: comments,
      hasNext: hasNext,
      originalCount: rawCount ?? comments.length,
    );

Widget _host(Widget child) => MaterialApp(
      home: CustomScrollView(slivers: [child]),
    );

void main() {
  testWidgets('auto load starts only after the sliver is visible',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(_host(PixivCommentsSection(
      illustId: '42',
      loadRoots: (_, __, ___) async {
        calls++;
        return Res(_page([_comment('1')]));
      },
    )));
    await tester.pump();
    await tester.pump();
    expect(calls, 1);
    expect(find.text('user1'), findsOneWidget);
  });

  testWidgets('local mode waits for explicit tap and retry preserves error',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(_host(PixivCommentsSection(
      illustId: '42',
      autoLoad: false,
      loadRoots: (_, __, ___) async {
        calls++;
        return calls == 1
            ? const Res.error('offline')
            : Res(_page([_comment('1')]));
      },
    )));
    expect(find.text('点击加载在线评论'), findsOneWidget);
    await tester.tap(find.text('点击加载在线评论'));
    await tester.pumpAndSettle();
    expect(find.text('offline'), findsOneWidget);
    await tester.tap(find.byTooltip('重试'));
    await tester.pumpAndSettle();
    expect(find.text('user1'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets(
      'roots advance by raw count, deduplicate, and stop empty hasNext page',
      (tester) async {
    final offsets = <int>[];
    final pages = <PixivCommentPage>[
      _page([_comment('1')], hasNext: true, rawCount: 4),
      _page([_comment('1')], hasNext: true, rawCount: 0),
    ];
    await tester.pumpWidget(_host(PixivCommentsSection(
      illustId: '42',
      loadRoots: (_, offset, __) async {
        offsets.add(offset);
        return Res(pages.removeAt(0));
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('加载更多评论'), findsOneWidget);
    await tester.tap(find.text('加载更多评论'));
    await tester.pumpAndSettle();
    expect(offsets, [0, 4]);
    expect(find.text('user1'), findsOneWidget);
    expect(find.text('加载更多评论'), findsNothing);
  });

  testWidgets(
      'replies load on demand, page, retry, collapse and stamp fallback',
      (tester) async {
    final replyPages = <PixivCommentPage>[
      _page([_comment('r1', text: '', replies: false)], hasNext: true),
      _page([_comment('r2')]),
    ];
    final requestedPages = <int>[];
    await tester.pumpWidget(_host(PixivCommentsSection(
      illustId: '42',
      loadRoots: (_, __, ___) async =>
          Res(_page([_comment('root', replies: true)])),
      loadReplies: (id, page) async {
        expect(id, 'root');
        requestedPages.add(page);
        return Res(replyPages.removeAt(0));
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('查看回复'), findsOneWidget);
    await tester.tap(find.text('查看回复'));
    await tester.pumpAndSettle();
    expect(find.text('userr1'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(requestedPages, [1, 2]);
    expect(find.text('userr2'), findsOneWidget);
    await tester.tap(find.text('收起回复'));
    await tester.pumpAndSettle();
    expect(find.text('userr1'), findsNothing);
  });

  testWidgets('late response after item identity changes is ignored',
      (tester) async {
    final pending = Completer<Res<PixivCommentPage>>();
    await tester.pumpWidget(_host(PixivCommentsSection(
      illustId: 'old',
      loadRoots: (_, __, ___) => pending.future,
    )));
    await tester.pump();
    await tester.pumpWidget(_host(PixivCommentsSection(
      illustId: 'new',
      loadRoots: (_, __, ___) async => Res(_page([_comment('new')])),
    )));
    pending.complete(Res(_page([_comment('old')])));
    await tester.pumpAndSettle();
    expect(find.text('userold'), findsNothing);
    expect(find.text('usernew'), findsOneWidget);
  });
}
