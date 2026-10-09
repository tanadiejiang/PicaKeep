import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/pixiv_comments_section.dart';
import 'package:picakeep/pages/online_comic/pixiv_detail_pager.dart';
import 'package:sqlite3/open.dart';
import 'package:picakeep/pages/online_comic/pixiv_online_detail_view.dart';

const _output = 'docs/verification/pixiv-comments-preview-038';
const _frame = Duration(milliseconds: 16);

PixivComment _comment(String id, {bool replies = false, String? text}) =>
    PixivComment(
      id: id,
      userId: 'u$id',
      userName: '用户$id',
      avatarUrl: '',
      comment: text ?? '评论$id：这是一条离线评论。',
      commentDate: '2026-10-08',
      hasReplies: replies,
    );

List<PixivComment> _comments(int count,
        {int start = 1, bool replies = false}) =>
    List.generate(
        count, (index) => _comment('${index + start}', replies: replies));

PixivCommentPage _page(List<PixivComment> comments,
        {bool hasNext = false, int? rawCount}) =>
    PixivCommentPage(
        comments: comments,
        hasNext: hasNext,
        originalCount: rawCount ?? comments.length);

PixivDetailEntry _entry(String id, WidgetBuilder builder) =>
    PixivDetailEntry(key: 'preview-$id', comicId: id, builder: builder);

Widget _host(Widget child,
    {bool? active,
    bool ticker = true,
    double scale = 1,
    double before = 0,
    double after = 400,
    ScrollController? controller}) {
  final scroll = TickerMode(
    enabled: ticker,
    child: CustomScrollView(
      controller: controller,
      cacheExtent: 100000,
      slivers: [
        if (before > 0) SliverToBoxAdapter(child: SizedBox(height: before)),
        child,
        SliverToBoxAdapter(child: SizedBox(height: after)),
      ],
    ),
  );
  return MaterialApp(
    builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!),
    home: Scaffold(
      body: active == null
          ? scroll
          : PixivDetailEntryScope(
              entry: _entry('42', (_) => const SizedBox()),
              isActive: active,
              child: scroll),
    ),
  );
}

void _view(WidgetTester tester, {double width = 375, double height = 5000}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder _roots([String id = '42']) => find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('pixiv-comment-$id-');
    });

Finder _slots([String id = '42']) => find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('pixiv-comments-placeholder-$id-');
    });

Future<void> _frames(WidgetTester tester, [int count = 4]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(_frame);
  }
}

Future<void> _tap(WidgetTester tester, Finder finder,
    {bool settle = true}) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 300,
        scrollable: find
            .byWidgetPredicate((widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down)
            .first,
        maxScrolls: 80);
  }
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await _frames(tester);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final count in [0, 1, 4, 5, 20]) {
    testWidgets('preview renders min(4, $count), caches oversize response',
        (tester) async {
      _view(tester);
      final requests = <(int, int)>[];
      await tester.pumpWidget(_host(PixivCommentsSection(
        illustId: '42',
        previewLimit: 4,
        loadRoots: (_, offset, limit) async {
          requests.add((offset, limit));
          return Res(_page(_comments(count)));
        },
      )));
      await tester.pumpAndSettle();
      expect(requests, [(0, 4)]);
      expect(_roots(), findsNWidgets(count.clamp(0, 4)));
      expect(_slots(), findsNothing);
      expect(find.text('暂无评论'), count == 0 ? findsOneWidget : findsNothing);
      if (count <= 4) {
        expect(find.text('展开更多评论'), findsNothing);
      } else {
        expect(find.text('展开更多评论'), findsOneWidget);
        expect(find.text('用户5'), findsNothing);
        await _tap(tester, find.text('展开更多评论'));
        expect(_roots(), findsNWidgets(count));
        expect(requests, [(0, 4)]);
        await _tap(tester, find.text('收起评论'));
        expect(_roots(), findsNWidgets(4));
        await _tap(tester, find.text('展开更多评论'));
        expect(_roots(), findsNWidgets(count));
        expect(requests, [(0, 4)]);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'expand requests one page, raw counts survive invalid rows and dedup',
      (tester) async {
    _view(tester);
    final requests = <(int, int)>[];
    final pages = [
      parsePixivComments({
        'hasNext': true,
        'comments': [
          {'id': '1', 'userName': '用户1', 'comment': 'first'},
          {'id': '1', 'userName': 'duplicate'},
          'invalid',
          {'id': 0},
          for (var id = 2; id <= 4; id++)
            {'id': '$id', 'userName': '用户$id', 'comment': 'valid$id'},
        ],
      }),
      parsePixivComments({
        'hasNext': true,
        'comments': [
          {'id': '4', 'userName': 'duplicate'},
          {'id': '5', 'userName': '用户5', 'comment': 'next'},
          {'id': null},
        ],
      }),
      parsePixivComments({'hasNext': true, 'comments': []}),
    ];
    await tester.pumpWidget(_host(PixivCommentsSection(
      illustId: '42',
      previewLimit: 4,
      loadRoots: (_, offset, limit) async {
        requests.add((offset, limit));
        return Res(pages.removeAt(0));
      },
    )));
    await tester.pumpAndSettle();
    expect(requests, [(0, 4)]);
    expect(_roots(), findsNWidgets(4));
    await _tap(tester, find.text('展开更多评论'));
    expect(requests, [(0, 4), (7, 20)]);
    expect(_roots(), findsNWidgets(5));
    expect(find.text('duplicate'), findsNothing);
    await _frames(tester, 8);
    expect(requests.length, 2);
    await _tap(tester, find.text('加载更多评论'));
    expect(requests, [(0, 4), (7, 20), (10, 20)]);
    expect(find.text('加载更多评论'), findsNothing);
    expect(find.text('收起评论'), findsOneWidget);
  });

  testWidgets('busy expansion can collapse; returning page only warms cache',
      (tester) async {
    _view(tester);
    final pending = Completer<Res<PixivCommentPage>>();
    final requests = <(int, int)>[];
    await tester.pumpWidget(_host(PixivCommentsSection(
      illustId: '42',
      previewLimit: 4,
      loadRoots: (_, offset, limit) async {
        requests.add((offset, limit));
        return requests.length == 1
            ? Res(_page(_comments(4), hasNext: true))
            : await pending.future;
      },
    )));
    await tester.pumpAndSettle();
    final expand = tester.widget<TextButton>(find.ancestor(
        of: find.text('展开更多评论'), matching: find.byType(TextButton)));
    expand.onPressed!();
    expand.onPressed!();
    await _frames(tester);
    expect(requests, [(0, 4), (4, 20)]);
    final more = tester.widget<TextButton>(find.ancestor(
        of: find.text('加载更多评论'), matching: find.byType(TextButton)));
    expect(more.onPressed, isNull);
    await _tap(tester, find.text('收起评论'), settle: false);
    pending.complete(Res(_page(_comments(20, start: 5), hasNext: true)));
    await tester.pumpAndSettle();
    expect(_roots(), findsNWidgets(4));
    expect(find.text('用户5'), findsNothing);
    await _tap(tester, find.text('展开更多评论'));
    expect(_roots(), findsNWidgets(24));
    expect(requests, [(0, 4), (4, 20)]);
    await _frames(tester, 8);
    expect(requests.length, 2);
  });

  testWidgets(
      'reply rows belong to selected roots and total collapse hides caches',
      (tester) async {
    _view(tester, height: 5000);
    final roots = <(int, int)>[];
    final replies = <(String, int)>[];
    await tester.pumpWidget(_host(PixivCommentsSection(
      illustId: '42',
      previewLimit: 4,
      loadRoots: (_, offset, limit) async {
        roots.add((offset, limit));
        return Res(
            _page(_comments(5, replies: true), hasNext: true, rawCount: 8));
      },
      loadReplies: (id, page) async {
        replies.add((id, page));
        return Res(_page(_comments(id == '1' ? 20 : 1, start: 101),
            hasNext: id == '1', rawCount: 23));
      },
    )));
    await tester.pumpAndSettle();
    expect(replies, isEmpty);
    await _tap(tester, find.text('查看回复').first);
    expect(replies, [('1', 1)]);
    expect(_roots(), findsNWidgets(4));
    expect(find.text('用户101'), findsOneWidget);
    expect(find.text('用户120'), findsOneWidget);
    await _tap(tester, find.text('展开更多评论'));
    final fifth = find.byKey(const ValueKey('pixiv-comment-42-5'));
    await _tap(tester, find.descendant(of: fifth, matching: find.text('查看回复')));
    expect(replies, [('1', 1), ('5', 1)]);
    expect(find.text('用户101'), findsNWidgets(2));
    await _tap(tester, find.text('收起评论'));
    expect(_roots(), findsNWidgets(4));
    expect(find.text('用户101'), findsNothing);
    expect(find.text('加载更多'), findsNothing);
    await _tap(tester, find.text('展开更多评论'));
    expect(find.text('用户101'), findsNothing);
    await _tap(tester, find.descendant(of: fifth, matching: find.text('查看回复')));
    expect(find.text('用户101'), findsOneWidget);
    expect(replies, [('1', 1), ('5', 1)]);
    await _tap(tester, find.text('加载更多评论'));
    expect(roots, [(0, 4), (8, 20)]);
  });

  testWidgets(
      'pending reply is hidden after total collapse and reused on demand',
      (tester) async {
    _view(tester);
    final pending = Completer<Res<PixivCommentPage>>();
    var calls = 0;
    await tester.pumpWidget(_host(PixivCommentsSection(
      illustId: '42',
      previewLimit: 4,
      loadRoots: (_, __, ___) async => Res(_page(_comments(5, replies: true))),
      loadReplies: (_, __) {
        calls++;
        return pending.future;
      },
    )));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('展开更多评论'));
    await _tap(tester, find.text('查看回复').first, settle: false);
    await _tap(tester, find.text('收起评论'), settle: false);
    pending.complete(Res(_page([_comment('reply')])));
    await tester.pumpAndSettle();
    expect(find.text('用户reply'), findsNothing);
    await _tap(tester, find.text('查看回复').first);
    expect(find.text('用户reply'), findsOneWidget);
    expect(calls, 1);
  });

  testWidgets('inactive EntryScope and TickerMode suppress visible auto loads',
      (tester) async {
    _view(tester);
    final pending = Completer<Res<PixivCommentPage>>();
    var calls = 0;
    Widget section() => PixivCommentsSection(
          illustId: '42',
          previewLimit: 4,
          loadRoots: (_, __, ___) {
            calls++;
            return pending.future;
          },
        );
    await tester.pumpWidget(_host(section(), active: false));
    await _frames(tester);
    expect(calls, 0);
    expect(_slots(), findsNWidgets(4));
    await tester.pumpWidget(_host(section(), active: true, ticker: false));
    await _frames(tester);
    expect(calls, 0);
    await tester.pumpWidget(_host(section(), active: true));
    await _frames(tester);
    expect(calls, 1);
    await tester.pumpWidget(_host(section(), active: false));
    pending.complete(Res(_page(_comments(20), hasNext: true)));
    await tester.pumpAndSettle();
    expect(_roots(), findsNWidgets(4));
    expect(_slots(), findsNothing);
    expect(calls, 1);
    await tester.pumpWidget(_host(section(), active: true));
    await tester.pumpAndSettle();
    expect(_roots(), findsNWidgets(4));
    await _tap(tester, find.text('展开更多评论'));
    expect(_roots(), findsNWidgets(20));
    expect(calls, 1);
  });

  testWidgets(
      'expanded request completing off-page cannot expand inactive layout',
      (tester) async {
    _view(tester);
    final pending = Completer<Res<PixivCommentPage>>();
    var calls = 0;
    Widget section() => PixivCommentsSection(
          illustId: '42',
          previewLimit: 4,
          loadRoots: (_, __, ___) async {
            calls++;
            return calls == 1
                ? Res(_page(_comments(4), hasNext: true))
                : await pending.future;
          },
        );
    await tester.pumpWidget(_host(section(), active: true));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('展开更多评论'), settle: false);
    await tester.pumpWidget(_host(section(), active: false));
    pending.complete(Res(_page(_comments(20, start: 5), hasNext: true)));
    await tester.pumpAndSettle();
    expect(_roots(), findsNWidgets(4));
    expect(calls, 2);
    await tester.pumpWidget(_host(section(), active: true));
    await tester.pumpAndSettle();
    expect(_roots(), findsNWidgets(24));
    expect(calls, 2);
  });

  testWidgets('sliver outside viewport does not request even in cache extent',
      (tester) async {
    _view(tester, height: 900);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var calls = 0;
    await tester.pumpWidget(_host(
        PixivCommentsSection(
          illustId: '42',
          previewLimit: 4,
          loadRoots: (_, __, ___) async {
            calls++;
            return Res(_page(_comments(1)));
          },
        ),
        before: 2000,
        controller: controller));
    await _frames(tester);
    expect(calls, 0);
    controller.jumpTo(1500);
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('null limit preserves local explicit load and original limit20',
      (tester) async {
    _view(tester);
    final requests = <(int, int)>[];
    await tester.pumpWidget(_host(PixivCommentsSection(
      illustId: '42',
      autoLoad: false,
      loadRoots: (_, offset, limit) async {
        requests.add((offset, limit));
        return Res(_page(_comments(20), hasNext: true));
      },
    )));
    await _frames(tester);
    expect(requests, isEmpty);
    expect(_slots(), findsNothing);
    await _tap(tester, find.text('点击加载在线评论'));
    expect(requests, [(0, 20)]);
    expect(_roots(), findsNWidgets(20));
    expect(find.text('展开更多评论'), findsNothing);
    expect(find.text('收起评论'), findsNothing);
    expect(find.text('加载更多评论'), findsOneWidget);
  });

  testWidgets('four finite placeholder slots adapt to text scale and width',
      (tester) async {
    _view(tester, height: 1600);
    final pending = Completer<Res<PixivCommentPage>>();
    Widget section() => PixivCommentsSection(
        illustId: '42',
        previewLimit: 4,
        loadRoots: (_, __, ___) => pending.future);
    await tester.pumpWidget(_host(section()));
    await _frames(tester);
    expect(_slots(), findsNWidgets(4));
    final normal = tester.getSize(_slots().first).height;
    expect(normal, inExclusiveRange(64, 220));
    await tester.pumpWidget(_host(section(), scale: 2));
    await _frames(tester);
    final large = tester.getSize(_slots().first).height;
    expect(large, greaterThan(normal));
    tester.view.physicalSize = const Size(210, 1600);
    await _frames(tester);
    final narrow = tester.getSize(_slots().first).height;
    expect(narrow, greaterThan(large));
    expect(narrow, lessThan(360));
    expect(_slots(), findsNWidgets(4));
    expect(tester.takeException(), isNull);
    pending.complete(Res(_page(_comments(1))));
    await tester.pumpAndSettle();
    expect(_slots(), findsNothing);
    expect(_roots(), findsOneWidget);
  });

  testWidgets(
      'first and append errors stay compact and retry the same raw offset',
      (tester) async {
    _view(tester);
    final requests = <(int, int)>[];
    await tester.pumpWidget(_host(PixivCommentsSection(
      illustId: '42',
      previewLimit: 4,
      loadRoots: (_, offset, limit) async {
        requests.add((offset, limit));
        return switch (requests.length) {
          1 => const Res.error('首次离线错误'),
          2 => Res(_page(_comments(4), hasNext: true, rawCount: 6)),
          3 => const Res.error('追加离线错误'),
          _ => Res(_page(_comments(1, start: 5))),
        };
      },
    )));
    await tester.pumpAndSettle();
    expect(_slots(), findsNothing);
    expect(find.text('首次离线错误'), findsOneWidget);
    await _tap(tester, find.byTooltip('重试'));
    expect(requests, [(0, 4), (0, 4)]);
    await _tap(tester, find.text('展开更多评论'));
    expect(find.text('追加离线错误'), findsOneWidget);
    expect(_roots(), findsNWidgets(4));
    await _tap(tester, find.byTooltip('重试'));
    expect(requests, [(0, 4), (0, 4), (6, 20), (6, 20)]);
    expect(_roots(), findsNWidgets(5));
  });

  testWidgets('identity generation discards old roots and resets preview state',
      (tester) async {
    _view(tester);
    final pending = Completer<Res<PixivCommentPage>>();
    final requests = <(String, int, int)>[];
    Widget section(String id) => PixivCommentsSection(
          illustId: id,
          previewLimit: 4,
          loadRoots: (work, offset, limit) {
            requests.add((work, offset, limit));
            return work == 'old'
                ? pending.future
                : Future.value(Res(_page(_comments(5, start: 201))));
          },
        );
    await tester.pumpWidget(_host(section('old')));
    await _frames(tester);
    await tester.pumpWidget(_host(section('new')));
    await tester.pumpAndSettle();
    pending.complete(Res(_page(_comments(20), hasNext: true)));
    await tester.pumpAndSettle();
    expect(requests, [('old', 0, 4), ('new', 0, 4)]);
    expect(_roots('new'), findsNWidgets(4));
    expect(find.text('用户1'), findsNothing);
    expect(find.text('用户205'), findsNothing);
    expect(find.text('展开更多评论'), findsOneWidget);
  });

  testWidgets('old replies are discarded when work identity changes',
      (tester) async {
    _view(tester);
    final pending = Completer<Res<PixivCommentPage>>();
    Widget section(String id) => PixivCommentsSection(
          illustId: id,
          previewLimit: 4,
          loadRoots: (_, __, ___) async =>
              Res(_page([_comment(id, replies: true)])),
          loadReplies: (_, __) => pending.future,
        );
    await tester.pumpWidget(_host(section('old')));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('查看回复'), settle: false);
    await tester.pumpWidget(_host(section('new')));
    await tester.pumpAndSettle();
    pending.complete(Res(_page([_comment('old-reply')])));
    await tester.pumpAndSettle();
    expect(find.text('用户old-reply'), findsNothing);
    expect(find.text('用户new'), findsOneWidget);
    expect(find.text('查看回复'), findsOneWidget);
  });

  testWidgets('collapse reveals this comment header without page top reset',
      (tester) async {
    _view(tester, height: 900);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(
        PixivCommentsSection(
          illustId: '42',
          previewLimit: 4,
          loadRoots: (_, __, ___) async => Res(_page(_comments(20))),
        ),
        before: 1200,
        after: 1200,
        controller: controller));
    controller.jumpTo(1200);
    await tester.pumpAndSettle();
    await _tap(tester, find.text('展开更多评论'));
    await _tap(tester, find.text('收起评论'));
    expect(controller.offset, greaterThan(1100));
    final header =
        tester.getRect(find.byKey(const ValueKey('pixiv-comments-header-42')));
    expect(header.top, inInclusiveRange(0, 100));
    expect(_roots(), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('long caption remains complete and stamp keeps its 64dp slot',
      (tester) async {
    _view(tester);
    final denied = _DenyNetwork();
    final original = HttpOverrides.current;
    HttpOverrides.global = denied;
    addTearDown(() => HttpOverrides.global = original);
    final text = List.filled(12, '完整长评论内容，不应被预览条数截断。').join('\n');
    final stamp = PixivComment(
        id: '1',
        userId: '1',
        userName: '长评论用户',
        avatarUrl: '',
        comment: text,
        commentDate: '2026-10-08',
        stampId: 21);
    await tester.pumpWidget(_host(PixivCommentsSection(
        illustId: '42',
        previewLimit: 4,
        loadRoots: (_, __, ___) async =>
            Res(_page([stamp, ..._comments(4, start: 2)])))));
    await tester.pumpAndSettle();
    expect(find.text(text), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.width, 64);
    expect(image.height, 64);
    expect(_roots(), findsNWidgets(4));
    expect(find.text('用户5'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reply errors retry same page and raw empty duplicate page stops',
      (tester) async {
    _view(tester);
    final pages = <int>[];
    await tester.pumpWidget(_host(PixivCommentsSection(
        illustId: '42',
        previewLimit: 4,
        loadRoots: (_, __, ___) async =>
            Res(_page([_comment('1', replies: true)])),
        loadReplies: (_, page) async {
          pages.add(page);
          return switch (pages.length) {
            1 => const Res.error('回复离线错误'),
            2 => Res(_page([_comment('reply')], hasNext: true, rawCount: 5)),
            _ => Res(_page([_comment('reply')], hasNext: true, rawCount: 0)),
          };
        })));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('查看回复'));
    expect(find.text('回复离线错误'), findsOneWidget);
    await _tap(tester, find.byTooltip('重试'));
    expect(pages, [1, 1]);
    expect(find.text('用户reply'), findsOneWidget);
    await _tap(tester, find.text('加载更多'));
    expect(pages, [1, 1, 2]);
    expect(find.text('用户reply'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
  });

  _integrationTests();
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

class _DenyNetwork extends HttpOverrides {
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    calls++;
    throw StateError('038 fixtures must not create a real HTTP client');
  }
}

PixivComicInfo _info(String id) => PixivComicInfo(
    id: id,
    title: '四条评论预览 · 作品$id',
    author: '离线画师',
    authorId: '42',
    coverUrl: '',
    tags: const ['离线夹具'],
    description: '评论区位于作者之后，相关推荐之前。',
    pageCount: 1,
    illustType: pixivIllustTypeIllust,
    likeCount: 12,
    viewCount: 34,
    width: 800,
    height: 400,
    isOriginal: true,
    createDate: '2026-10-08T10:00:00+08:00',
    uploadDate: '2026-10-08T10:00:00+08:00',
    userId: '42',
    isBookmarked: false,
    isBookmarkable: true);

Future<void> _loadCaptureFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final font in [
      ('CommentsCapture038', 'C:/Windows/Fonts/msyh.ttc'),
      (
        'MaterialIcons',
        'build/unit_test_assets/fonts/MaterialIcons-Regular.otf'
      ),
    ]) {
      final bytes = await File(font.$2).readAsBytes();
      await (FontLoader(font.$1)
            ..addFont(Future.value(ByteData.sublistView(bytes))))
          .load();
    }
  });
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name,
    Map<String, Object?> geometry) async {
  await tester.pump();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    image.dispose();
    final directory = Directory(_output);
    await directory.create(recursive: true);
    await File('$_output/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    await File('$_output/$name.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert({
      'offline': true,
      'renderer': 'Flutter test RenderRepaintBoundary.toImage',
      'font': 'C:/Windows/Fonts/msyh.ttc',
      'materialIcons': 'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
      ...geometry,
    }));
  });
}

void _integrationTests() {
  group('real online detail and pager offline fixtures', () {
    late Directory workspace;
    late List<ComicSource> previousSources;
    late _DenyNetwork network;
    final paths = PathProviderPlatform.instance;
    final originalHttp = HttpOverrides.current;

    setUpAll(() async {
      open.overrideFor(
          OperatingSystem.windows,
          () => DynamicLibrary.open(
              '${Directory.current.path}/windows/sqlite3.dll'));
      workspace = await Directory.systemTemp.createTemp('pixiv_comments_038_');
      PathProviderPlatform.instance = _Paths(workspace.path);
      await App.init(dataPathOverride: '${workspace.path}/data');
    });
    tearDownAll(() async {
      PixivNetwork().cookieJar.dispose();
      PathProviderPlatform.instance = paths;
      HttpOverrides.global = originalHttp;
      await workspace.delete(recursive: true);
    });
    setUp(() {
      network = _DenyNetwork();
      HttpOverrides.global = network;
      previousSources = List.of(ComicSource.sources);
      ComicSource.sources
        ..clear()
        ..add(ComicSource.named(key: 'pixiv', name: 'Pixiv', data: {}));
      PixivBookmarkStateStore.shared.clear();
    });
    tearDown(() {
      ComicSource.sources
        ..clear()
        ..addAll(previousSources);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets(
          'capture real detail preview and four loading slots scale$scale',
          (tester) async {
        _view(tester, height: 1000);
        await _loadCaptureFonts(tester);
        final captureKey = GlobalKey();
        final pending = Completer<Res<PixivCommentPage>>();
        final requests = <(String, int, int)>[];
        final session = PixivDetailSession(
          scope: PixivDetailScope.related,
          entries: [
            _entry(
                '42',
                (_) => _online('42', (id, offset, limit) {
                      requests.add((id, offset, limit));
                      return pending.future;
                    })),
            _entry(
                '43',
                (_) => _online('43', (id, offset, limit) {
                      requests.add((id, offset, limit));
                      return Future.value(
                          Res(_page(_comments(20, start: 301))));
                    })),
          ],
        );
        addTearDown(session.dispose);
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'CommentsCapture038'),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: RepaintBoundary(
            key: captureKey,
            child: PixivDetailPager(session: session, initialKey: 'preview-42'),
          ),
        ));
        await _frames(tester, 8);
        final page =
            find.byKey(const ValueKey('pixiv-detail-page-scroll')).first;
        final scrollable =
            find.descendant(of: page, matching: find.byType(Scrollable));
        final position =
            tester.state<ScrollableState>(scrollable.first).position;
        for (var step = 0; step < 20 && requests.isEmpty; step++) {
          position.jumpTo(
              (position.pixels + 160).clamp(0, position.maxScrollExtent));
          await _frames(tester);
        }
        expect(requests, [('42', 0, 4)]);
        final header = find.byKey(const ValueKey('pixiv-comments-header-42'));
        position.jumpTo(position.pixels + tester.getTopLeft(header).dy - 24);
        await _frames(tester);
        expect(_slots(), findsNWidgets(4));
        final slotHeights = [
          for (final element in _slots().evaluate())
            (element.findRenderObject() as RenderBox).size.height,
        ];
        expect(slotHeights.length, 4);
        expect(slotHeights.every((height) => height.isFinite && height < 360),
            isTrue);
        final prefix = scale == 1 ? '375-normal' : '375-large-text';
        await _capture(tester, captureKey, '$prefix-loading', {
          'width': 375,
          'height': 1000,
          'textScale': scale,
          'placeholderCount': slotHeights.length,
          'slotHeights': slotHeights,
          'totalPlaceholderHeight':
              slotHeights.fold<double>(0.0, (a, b) => a + b),
          'requests': requests
              .map((r) => {'id': r.$1, 'offset': r.$2, 'limit': r.$3})
              .toList(),
          'pixels': position.pixels,
        });
        pending.complete(Res(_page(_comments(20), hasNext: true)));
        await tester.pumpAndSettle();
        expect(_roots(), findsNWidgets(4));
        expect(_slots(), findsNothing);
        expect(find.text('用户5'), findsNothing);
        final samePosition =
            tester.state<ScrollableState>(scrollable.first).position;
        expect(identical(position, samePosition), isTrue);
        await _capture(tester, captureKey, '$prefix-collapsed', {
          'width': 375,
          'height': 1000,
          'textScale': scale,
          'visibleRoots': 4,
          'placeholderCount': 0,
          'pixels': position.pixels,
          'sameScrollPosition': true,
        });
        await _tap(tester, find.text('展开更多评论'));
        expect(requests, [('42', 0, 4)]);
        await _tap(tester, find.text('收起评论'));
        expect(position.pixels, greaterThan(0));
        expect(tester.getTopLeft(header).dy, inInclusiveRange(0, 900));
        await _capture(tester, captureKey, '$prefix-recollapsed', {
          'width': 375,
          'height': 1000,
          'textScale': scale,
          'visibleRoots': 4,
          'pixels': position.pixels,
          'headerTop': tester.getTopLeft(header).dy,
          'sameScrollPosition': identical(position,
              tester.state<ScrollableState>(scrollable.first).position),
        });
        final pager = tester
            .widget<PageView>(find.byKey(const Key('pixiv-work-pager')))
            .controller!;
        pager.jumpTo(130);
        await _frames(tester, 8);
        final neighbour = find.byWidgetPredicate((widget) =>
            widget is PixivCommentsSection && widget.illustId == '43');
        expect(neighbour, findsOneWidget);
        expect(PixivDetailEntryScope.isActiveOf(tester.element(neighbour)),
            isFalse);
        expect(TickerMode.valuesOf(tester.element(neighbour)).enabled, isFalse);
        expect(requests, [('42', 0, 4)]);
        pager.jumpToPage(0);
        await tester.pumpAndSettle();
        expect(requests, [('42', 0, 4)]);
        expect(_roots(), findsNWidgets(4));
        pager.jumpToPage(1);
        await tester.pumpAndSettle();
        final neighbourPage = find.descendant(
            of: find.byKey(const ValueKey('preview-43')),
            matching: find.byKey(const ValueKey('pixiv-detail-page-scroll')));
        final neighbourScrollable = find
            .descendant(of: neighbourPage, matching: find.byType(Scrollable))
            .first;
        final neighbourPosition =
            tester.state<ScrollableState>(neighbourScrollable).position;
        for (var step = 0;
            step < 20 && !requests.any((r) => r.$1 == '43');
            step++) {
          neighbourPosition.jumpTo((neighbourPosition.pixels + 160)
              .clamp(0, neighbourPosition.maxScrollExtent));
          await _frames(tester);
        }
        final neighbourHeader =
            find.byKey(const ValueKey('pixiv-comments-header-43'));
        neighbourPosition.jumpTo(neighbourPosition.pixels +
            tester.getTopLeft(neighbourHeader).dy -
            24);
        await tester.pumpAndSettle();
        expect(requests.where((r) => r.$1 == '43').toList(), [('43', 0, 4)]);
        expect(_roots('43'), findsNWidgets(4));
        pager.jumpToPage(0);
        await tester.pumpAndSettle();
        final returnedPage = find.descendant(
            of: find.byKey(const ValueKey('preview-42')),
            matching: find.byKey(const ValueKey('pixiv-detail-page-scroll')));
        final returnedScrollable = find
            .descendant(of: returnedPage, matching: find.byType(Scrollable))
            .first;
        final returnedPosition =
            tester.state<ScrollableState>(returnedScrollable).position;
        final returnedHeader =
            find.byKey(const ValueKey('pixiv-comments-header-42'));
        await tester.ensureVisible(returnedHeader);
        await tester.pumpAndSettle();
        expect(_roots(), findsNWidgets(4));
        expect(requests.every((r) => r.$2 == 0 && r.$3 == 4), isTrue);
        await tester.runAsync(() => File('$_output/$prefix-pager.json')
                .writeAsString(const JsonEncoder.withIndent('  ').convert({
              'partialNeighbourActive': false,
              'partialNeighbourTickerEnabled': false,
              'currentRootLimit': 4,
              'neighbourRootLimit': 4,
              'returnedRootLimit': 4,
              'samePositionAfterFullVisit':
                  identical(position, returnedPosition),
              'requests': requests
                  .map((r) => {'id': r.$1, 'offset': r.$2, 'limit': r.$3})
                  .toList(),
              'httpClientsCreated': network.calls,
            })));
        expect(network.calls, 0);
        expect(tester.takeException(), isNull);
      });
    }
  });
}

Widget _online(String id, PixivCommentRootsLoader roots) =>
    PixivOnlineDetailView(
      comicId: id,
      loadDetail: () async => Res(_info(id)),
      loadPages: (_) async => const Res(<PixivPage>[]),
      loadAuthor: (_) async => const Res(PixivAuthor(
          id: '42', name: '离线画师', avatar: '', comment: '', following: 0)),
      loadAuthorWorkIds: (_) async => const Res(<String>[]),
      loadAuthorPreviewWorks: (_, __) async => const Res(<PixivComicBrief>[]),
      loadRecommendations: (_) async =>
          const Res(PixivRecommendationsPage(items: [], nextIds: [])),
      loadRecommendationWorks: (_) async => const Res(<PixivComicBrief>[]),
      loadCommentRoots: roots,
      loadCommentReplies: (_, __) async => Res(_page([])),
      writeBookmark: (_, {required isAdding, required isPrivate}) async =>
          Res(isAdding),
      onRead: (_, __, ___) {},
      onDownload: (_, __) {},
      onDownloadLongPress: (_, __) {},
      onTagTap: (_, __, ___) {},
      accountIdentity: () => 'offline-038',
      isLoggedIn: () => true,
    );
