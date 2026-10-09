import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/pixiv_bookmark_button.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/network/pixiv_network/pixiv_models.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/pixiv_follow_recommendations_sheet.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';

const _output = 'docs/verification/pixiv-follow-discovery-040';
const _font = 'FollowDiscovery040';
const _account = 'offline-account-A';

class _DenyHttp extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('040 sheet fixtures forbid all HTTP');
  }
}

PixivComicBrief _work(String id, String uid,
        {bool known = true, bool marked = false, bool canAdd = true}) =>
    PixivComicBrief(
      id: id,
      title: '作品$id・离线横向预览',
      cover: '',
      author: '作者$uid',
      authorId: uid,
      authorAvatar: '',
      tags: const [],
      illustType: 0,
      pageCount: id.endsWith('1') ? 3 : 1,
      width: 600,
      height: 900,
      isBookmarked: marked,
      isBookmarkable: canAdd,
      bookmarkStateKnown: known,
      canLoadBookmarkState: !known,
    );

List<PixivRecommendedAuthor> _authors({
  int count = 2,
  bool longNames = false,
  bool emptyFirst = false,
  bool duplicateWork = false,
  bool unknownFirst = false,
}) =>
    List.generate(count, (index) {
      final uid = '${50 + index}';
      return PixivRecommendedAuthor(
        author: PixivAuthor(
          id: uid,
          name: longNames ? '画师$uid・雲と花々／非常长的Unicode作者名字' : '画师$uid・雲と花々',
          avatar: '',
          comment: '',
          following: 0,
          isFollowed: index == 1,
        ),
        works: emptyFirst && index == 0
            ? const []
            : [
                for (var work = 0; work < 3; work++)
                  _work(
                      duplicateWork && work == 0 ? '100' : '${index + 1}0$work',
                      uid,
                      known: !(unknownFirst && work == 0 && index == 0)),
              ],
      );
    });

class _Harness {
  _Harness({List<PixivRecommendedAuthor>? data}) {
    authors = data ?? _authors();
    load = (id) async => Res(authors);
  }

  final revision = ValueNotifier<int>(0);
  final navigator = GlobalKey<NavigatorState>();
  final capture = GlobalKey();
  final store = PixivBookmarkStateStore();
  late final bookmarks = RecommendationBookmarkController(store: store);
  final source = ComicSource.named(key: 'pixiv', name: 'Pixiv');
  late List<PixivRecommendedAuthor> authors;
  late Future<Res<List<PixivRecommendedAuthor>>> Function(String) load;
  Future<Res<bool>> Function(String, {required bool isFollowing}) follow =
      (_, {required isFollowing}) async => Res(isFollowing);
  Future<Res<bool>> Function(String, {required bool isAdding}) bookmark =
      (_, {required isAdding}) async => Res(isAdding);
  final loads = <String>[];
  final followWrites = <(String, bool)>[];
  final bookmarkWrites = <(String, bool)>[];
  final opened = <(String, List<String>)>[];
  String account = _account;
  bool ownerCurrent = true;
  bool loggedIn = true;
  int accountsChanged = 0;
  Future<void>? route;

  void rebuild() => revision.value++;

  PixivFollowRecommendationsSheet sheet() => PixivFollowRecommendationsSheet(
        seedAuthorId: '42',
        source: source,
        bookmarks: bookmarks,
        load: (id) {
          loads.add(id);
          return load(id);
        },
        writeFollow: (id, {required isFollowing}) {
          followWrites.add((id, isFollowing));
          return follow(id, isFollowing: isFollowing);
        },
        writeBookmark: (id, {required isAdding}) {
          bookmarkWrites.add((id, isAdding));
          return bookmark(id, isAdding: isAdding);
        },
        ownerIsCurrent: () => ownerCurrent,
        accountIdentity: () => account,
        isLoggedIn: () => loggedIn,
        onAccountsChanged: () async => accountsChanged++,
        onOpenWork: (work, scope) =>
            opened.add((work.id, scope.map((item) => item.id).toList())),
      );

  Future<void> mount(WidgetTester tester,
      {double scale = 1,
      Brightness brightness = Brightness.light,
      double width = 375,
      double height = 1000}) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _loadFonts(tester);
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      theme: ThemeData(
          useMaterial3: true,
          fontFamily: _font,
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0071CE), brightness: brightness)),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: RepaintBoundary(key: capture, child: child!),
      ),
      home: Scaffold(
        appBar: AppBar(title: const Text('作品详情')),
        body: Builder(builder: (context) {
          return Center(
            child: FilledButton(
              key: const ValueKey('open-discovery'),
              onPressed: () {
                route = showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  useSafeArea: true,
                  builder: (_) => ValueListenableBuilder<int>(
                      valueListenable: revision,
                      builder: (_, __, ___) => sheet()),
                );
              },
              child: const Text('打开已确认关注的作者推荐'),
            ),
          );
        }),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open-discovery')));
    await _frames(tester, 30);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _frames(tester);
  }

  void dispose() {
    bookmarks.dispose();
    store.dispose();
    revision.dispose();
  }
}

bool _fontsLoaded = false;
Future<void> _loadFonts(WidgetTester tester) async {
  if (_fontsLoaded) return;
  await tester.runAsync(() async {
    for (final font in [
      (_font, 'C:/Windows/Fonts/msyh.ttc'),
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
  _fontsLoaded = true;
}

Future<void> _frames(WidgetTester tester, [int count = 5]) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Finder _author(String id) => find.byKey(ValueKey('pixiv-follow-author-$id'));
Finder _follow(String id) =>
    find.byKey(ValueKey('pixiv-follow-author-button-$id'));
Finder _tile(String id) => find.byKey(ValueKey('pixiv-follow-work-$id'));
Finder _heart(String id) =>
    find.descendant(of: _tile(id), matching: find.byType(PixivBookmarkButton));
Finder _detail(String id) => find.descendant(
    of: _tile(id),
    matching: find.byKey(const ValueKey('compact-preview-detail')));
String _followLabel(WidgetTester tester, String id) =>
    (tester.widget<FilledButton>(_follow(id)).child as Text).data!;

ScrollableState _outer(WidgetTester tester) =>
    tester.state<ScrollableState>(find
        .descendant(
            of: find.byKey(const ValueKey('pixiv-follow-authors-scroll')),
            matching: find.byType(Scrollable))
        .first);
ScrollableState _inner(WidgetTester tester, String uid) =>
    tester.state<ScrollableState>(find
        .descendant(of: _author(uid), matching: find.byType(Scrollable))
        .first);

Map<String, double> _rect(Rect rect) => {
      'left': rect.left,
      'top': rect.top,
      'width': rect.width,
      'height': rect.height,
    };

Future<void> _capture(WidgetTester tester, _Harness harness, String name,
    Map<String, Object?> metadata) async {
  await tester.pump();
  final boundary = harness.capture.currentContext!.findRenderObject()!
      as RenderRepaintBoundary;
  final sheet = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('pixiv-follow-recommendations-sheet')));
  await tester.runAsync(() async {
    final output = Directory(_output);
    await output.create(recursive: true);
    for (final entry in [('viewport', boundary), ('panel', sheet)]) {
      final image = await entry.$2.toImage(pixelRatio: 2);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File('$_output/$name-${entry.$1}.png')
          .writeAsBytes(bytes.buffer.asUint8List());
      final pixelSize = {'width': image.width, 'height': image.height};
      image.dispose();
      await File('$_output/$name-${entry.$1}.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert({
        'offline': true,
        'renderer': 'Flutter test RenderRepaintBoundary.toImage',
        'captureRegion': entry.$1,
        'capturePixelRatio': 2,
        'pixelSize': pixelSize,
        'font': 'C:/Windows/Fonts/msyh.ttc',
        'fontFamily': _font,
        'materialIcons':
            'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
        'images': 'Production missing-cover/avatar placeholders; no HTTP',
        'logicalViewport': {'width': 375, 'height': 1000},
        'loads': harness.loads,
        'followWrites': harness.followWrites
            .map((value) => {'uid': value.$1, 'target': value.$2})
            .toList(),
        'bookmarkWrites': harness.bookmarkWrites
            .map((value) => {'id': value.$1, 'target': value.$2})
            .toList(),
        ...metadata,
      }));
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _DenyHttp deny;
  late HttpOverrides? previousHttp;
  late _Harness harness;
  setUp(() {
    previousHttp = HttpOverrides.current;
    deny = _DenyHttp();
    HttpOverrides.global = deny;
    expect(HttpOverrides.current, same(deny));
    harness = _Harness();
  });
  tearDown(() {
    harness.dispose();
    HttpOverrides.global = previousHttp;
    expect(deny.attempts, 0,
        reason: 'All sheet IO must remain injected/offline');
  });

  testWidgets('independent recommendation load has its own error and retry',
      (tester) async {
    harness.load = (_) async => harness.loads.length == 1
        ? const Res.error('离线读取失败')
        : Res(harness.authors);
    await harness.mount(tester);
    expect(harness.loads, ['42']);
    expect(find.text('已关注'), findsOneWidget);
    expect(find.text('推荐暂时没能加载：离线读取失败'), findsOneWidget);
    expect(harness.followWrites, isEmpty);
    await tester.tap(find.text('重试推荐'));
    await _frames(tester);
    expect(harness.loads, ['42', '42']);
    expect(_author('50'), findsOneWidget);
    expect(harness.followWrites, isEmpty);
    expect(tester.takeException(), isNull);
    await harness.unmount(tester);
  });

  testWidgets('thrown load shows retry without clearing the confirmed follow',
      (tester) async {
    harness.load = (_) async => throw StateError('离线异常');
    await harness.mount(tester);
    expect(find.text('推荐暂时没能加载：离线异常'), findsOneWidget);
    expect(find.text('已关注'), findsOneWidget);
    expect(harness.followWrites, isEmpty);
    await harness.unmount(tester);
  });

  testWidgets('legal empty response shows explicit empty state',
      (tester) async {
    harness.load = (_) async => const Res([]);
    await harness.mount(tester);
    expect(find.text('暂无更多作者推荐'), findsOneWidget);
    expect(find.text('重试推荐'), findsNothing);
    expect(find.byType(OnlineRecommendationCard), findsNothing);
    expect(harness.loads, ['42']);
    await harness.unmount(tester);
  });

  testWidgets(
      'author with no safe embedded works uses placeholder without hydration',
      (tester) async {
    harness.authors = _authors(emptyFirst: true);
    await harness.mount(tester);
    expect(find.text('暂无可显示作品'), findsOneWidget);
    expect(_follow('50'), findsOneWidget);
    expect(harness.loads, ['42']);
    expect(_tile('100'), findsNothing);
    expect(tester.takeException(), isNull);
    await harness.unmount(tester);
  });

  testWidgets('close pending load ignores both late data and error safely',
      (tester) async {
    for (final fail in [false, true]) {
      final pending = Completer<Res<List<PixivRecommendedAuthor>>>();
      harness.load = (_) => pending.future;
      await harness.mount(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byTooltip('关闭作者推荐'));
      await _frames(tester, 30);
      pending.complete(
          fail ? const Res.error('late error') : Res(harness.authors));
      await _frames(tester);
      expect(find.byType(PixivFollowRecommendationsSheet), findsNothing);
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    }
  });

  for (final change in ['owner', 'account']) {
    testWidgets('pending load ignores $change replacement while mounted',
        (tester) async {
      final pending = Completer<Res<List<PixivRecommendedAuthor>>>();
      harness.load = (_) => pending.future;
      await harness.mount(tester);
      if (change == 'owner') {
        harness.ownerCurrent = false;
      } else {
        harness.account = 'offline-account-B';
      }
      harness.rebuild();
      await _frames(tester);
      pending.complete(Res(harness.authors));
      await _frames(tester);
      expect(_author('50'), findsNothing);
      expect(harness.loads, ['42']);
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    });
  }

  testWidgets(
      'header drags authors and overflowing thumbnails use their inner scroll',
      (tester) async {
    harness.authors = _authors(count: 5);
    for (final width in [375.0, 320.0]) {
      await harness.mount(tester, width: width);
      final outer = _outer(tester).position;
      final inner = _inner(tester, '50').position;
      expect(outer.pixels, 0);
      final first = tester.getRect(_tile('100'));
      await tester.dragFrom(
          first.center - const Offset(0, 30), const Offset(-70, 0));
      await _frames(tester, 30);
      if (inner.maxScrollExtent > 0) {
        // The narrow fixture makes the same three works actually overflow.
        expect(inner.pixels, greaterThan(0));
        expect(outer.pixels, 0);
      } else {
        // All three previews fit at 375dp; dragging them can move the authors.
        expect(inner.pixels, 0);
        expect(outer.pixels, greaterThan(0));
      }
      outer.jumpTo(0);
      await _frames(tester);
      final avatar = find.descendant(
          of: _author('50'), matching: find.byType(CircleAvatar));
      await tester.dragFrom(tester.getCenter(avatar), const Offset(-310, 0));
      await _frames(tester, 30);
      expect(outer.pixels, greaterThan(200));
      expect(_author('51'), findsOneWidget);
      expect(harness.opened, isEmpty);
      expect(harness.followWrites, isEmpty);
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    }
  });

  testWidgets(
      'follow and unfollow use explicit targets with per-author busy lock',
      (tester) async {
    final pending = Completer<Res<bool>>();
    harness.follow = (_, {required isFollowing}) => pending.future;
    await harness.mount(tester);
    expect(_followLabel(tester, '50'), '关注');
    await tester.tap(_follow('50'));
    await _frames(tester);
    expect(_followLabel(tester, '50'), '处理中');
    expect(tester.widget<FilledButton>(_follow('50')).onPressed, isNull);
    await tester.tap(_follow('50'));
    expect(harness.followWrites, [('50', true)]);
    pending.complete(const Res(true));
    await _frames(tester);
    expect(_followLabel(tester, '50'), '已关注');
    harness.follow = (_, {required isFollowing}) async => Res(isFollowing);
    await tester.tap(_follow('50'));
    await _frames(tester);
    expect(harness.followWrites, [('50', true), ('50', false)]);
    expect(_followLabel(tester, '50'), '关注');
    expect(harness.loads, ['42'],
        reason: 'Follow inside panel does not restart discovery');
    await harness.unmount(tester);
  });

  testWidgets('follow failure is inline and retry keeps the same target',
      (tester) async {
    harness.follow =
        (_, {required isFollowing}) async => const Res.error('关注离线失败');
    await harness.mount(tester);
    await tester.tap(_follow('50'));
    await _frames(tester);
    expect(find.text('关注离线失败'), findsOneWidget);
    expect(_followLabel(tester, '50'), '关注');
    harness.follow = (_, {required isFollowing}) async => Res(isFollowing);
    await tester.tap(_follow('50'));
    await _frames(tester);
    expect(harness.followWrites, [('50', true), ('50', true)]);
    expect(find.text('关注离线失败'), findsNothing);
    expect(_followLabel(tester, '50'), '已关注');
    await harness.unmount(tester);
  });

  testWidgets(
      'unfollow failure preserves followed state and thrown writer clears busy',
      (tester) async {
    harness.authors = [harness.authors[1]];
    harness.follow =
        (_, {required isFollowing}) async => const Res.error('取消关注失败');
    await harness.mount(tester);
    await tester.tap(_follow('51'));
    await _frames(tester);
    expect(_followLabel(tester, '51'), '已关注');
    expect(find.text('取消关注失败'), findsOneWidget);
    harness.follow =
        (_, {required isFollowing}) async => throw StateError('offline');
    await tester.tap(_follow('51'));
    await _frames(tester);
    expect(_followLabel(tester, '51'), '已关注');
    expect(find.text('关注失败，请重试'), findsOneWidget);
    expect(harness.followWrites, [('51', false), ('51', false)]);
    expect(tester.widget<FilledButton>(_follow('51')).onPressed, isNotNull);
    await harness.unmount(tester);
  });

  for (final change in ['owner', 'account', 'close']) {
    testWidgets('late follow completion is ignored after $change change',
        (tester) async {
      final pending = Completer<Res<bool>>();
      harness.follow = (_, {required isFollowing}) => pending.future;
      await harness.mount(tester);
      await tester.tap(_follow('50'));
      await _frames(tester);
      if (change == 'close') {
        await tester.tap(find.byTooltip('关闭作者推荐'));
        await _frames(tester, 30);
      } else {
        if (change == 'owner') {
          harness.ownerCurrent = false;
        } else {
          harness.account = 'offline-account-B';
        }
        harness.rebuild();
        await _frames(tester);
      }
      pending.complete(const Res(true));
      await _frames(tester);
      expect(harness.followWrites, [('50', true)]);
      if (change != 'close') {
        expect(_followLabel(tester, '50'), isNot('已关注'));
        expect(tester.widget<FilledButton>(_follow('50')).onPressed, isNull);
      }
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    });
  }

  testWidgets('old mounted account disables follow, hearts and detail actions',
      (tester) async {
    await harness.mount(tester);
    harness.account = 'offline-account-B';
    harness.rebuild();
    await _frames(tester);
    expect(tester.widget<FilledButton>(_follow('50')).onPressed, isNull);
    expect(tester.widget<PixivBookmarkButton>(_heart('100')).enabled, isFalse);
    expect(tester.widget<InkWell>(_detail('100')).onTap, isNull);
    await tester.tap(_follow('50'));
    await tester.tap(_heart('100'));
    await tester.tap(_detail('100'));
    await _frames(tester);
    expect(harness.followWrites, isEmpty);
    expect(harness.bookmarkWrites, isEmpty);
    expect(harness.opened, isEmpty);
    await harness.unmount(tester);
  });

  testWidgets('old account cannot act before the next sheet rebuild',
      (tester) async {
    await harness.mount(tester);
    // Account callbacks can change before Flutter paints the invalidated sheet.
    // Every action must reject that stale owner at invocation time as well.
    harness.account = 'offline-account-B';
    await tester.tap(_follow('50'));
    await tester.tapAt(tester.getTopLeft(_tile('100')) + const Offset(35, 35));
    await tester.tap(_heart('100'));
    await _frames(tester, 35);
    expect(harness.followWrites, isEmpty);
    expect(harness.bookmarkWrites, isEmpty);
    expect(harness.opened, isEmpty);
    await harness.unmount(tester);
  });

  testWidgets(
      'compact heart isolates its tap from image and opens only author work scope',
      (tester) async {
    await harness.mount(tester);
    expect(tester.getSize(_heart('100')), const Size(48, 48));
    await tester.tap(_heart('100'));
    await _frames(tester, 35);
    expect(harness.bookmarkWrites, [('100', true)]);
    expect(harness.opened, isEmpty);
    expect(harness.store.stateFor(_account, '100')?.isBookmarked, isTrue);
    await tester.tapAt(tester.getTopLeft(_tile('100')) + const Offset(35, 35));
    await _frames(tester);
    expect(harness.opened, hasLength(1));
    expect(harness.opened.single.$1, '100');
    expect(harness.opened.single.$2, ['100', '101', '102']);
    expect(harness.bookmarkWrites, [('100', true)]);
    expect(tester.takeException(), isNull);
    await harness.unmount(tester);
  });

  testWidgets(
      'shared controller locks duplicate hearts and confirms both cards',
      (tester) async {
    harness.authors = _authors(duplicateWork: true);
    final pending = Completer<Res<bool>>();
    harness.bookmark = (_, {required isAdding}) => pending.future;
    await harness.mount(tester);
    final first = harness.authors.first.works.first;
    await tester.tap(_heart('100').first);
    await _frames(tester);
    expect(harness.bookmarks.isBusy(_account, first), isTrue);
    _outer(tester).position.jumpTo(327);
    await _frames(tester);
    final peer = find.descendant(of: _author('51'), matching: _heart('100'));
    expect(peer, findsOneWidget);
    expect(tester.widget<PixivBookmarkButton>(peer).busy, isTrue);
    await tester.tap(peer);
    expect(harness.bookmarkWrites, [('100', true)]);
    pending.complete(const Res(true));
    await _frames(tester, 35);
    expect(tester.widget<PixivBookmarkButton>(peer).isBookmarked, isTrue);
    expect(harness.store.stateFor(_account, '100')?.isBookmarked, isTrue);
    expect(harness.bookmarkWrites, [('100', true)]);
    expect(harness.opened, isEmpty);
    await harness.unmount(tester);
  });

  testWidgets(
      'external confirmation updates compact heart without recommendation reload',
      (tester) async {
    await harness.mount(tester);
    harness.store.confirm(_account, '100',
        const PixivBookmarkState(isBookmarked: true, isBookmarkable: false));
    await _frames(tester);
    expect(
        tester.widget<PixivBookmarkButton>(_heart('100')).isBookmarked, isTrue);
    expect(harness.loads, ['42']);
    await tester.tap(_heart('100'));
    await _frames(tester, 35);
    expect(harness.bookmarkWrites, [('100', false)]);
    expect(harness.store.stateFor(_account, '100')?.isBookmarked, isFalse);
    await harness.unmount(tester);
  });

  testWidgets(
      'unknown preview does not prefetch any state or hydrate author library',
      (tester) async {
    harness.authors = _authors(unknownFirst: true);
    await harness.mount(tester);
    expect(
        tester.widget<PixivBookmarkButton>(_heart('100')).stateKnown, isFalse);
    expect(harness.loads, ['42']);
    expect(harness.bookmarkWrites, isEmpty);
    expect(deny.attempts, 0);
    // Resolve through the injected shared authority before tapping. The sheet
    // does not expose a state-read callback; actual on-tap network resolution
    // belongs to the separate compact-card tests, not this all-HTTP-denied host.
    harness.store.confirm(_account, '100',
        const PixivBookmarkState(isBookmarked: true, isBookmarkable: true));
    await _frames(tester);
    expect(
        tester.widget<PixivBookmarkButton>(_heart('100')).stateKnown, isTrue);
    await tester.tap(_heart('100'));
    await _frames(tester, 35);
    expect(harness.bookmarkWrites, [('100', false)]);
    await harness.unmount(tester);
  });

  testWidgets('bookmark failure preserves state and never opens image detail',
      (tester) async {
    harness.bookmark =
        (_, {required isAdding}) async => const Res.error('收藏离线拒绝');
    await harness.mount(tester);
    await tester.tap(_heart('100'));
    await _frames(tester, 35);
    expect(tester.widget<PixivBookmarkButton>(_heart('100')).isBookmarked,
        isFalse);
    expect(find.text('收藏失败：收藏离线拒绝'), findsOneWidget);
    expect(harness.opened, isEmpty);
    await harness.unmount(tester);
  });

  testWidgets('pending bookmark becomes inert after account replacement',
      (tester) async {
    final pending = Completer<Res<bool>>();
    harness.bookmark = (_, {required isAdding}) => pending.future;
    await harness.mount(tester);
    await tester.tap(_heart('100'));
    await _frames(tester);
    harness.account = 'offline-account-B';
    harness.rebuild();
    await _frames(tester);
    pending.complete(const Res(true));
    await _frames(tester, 35);
    expect(harness.store.stateFor(_account, '100'), isNull);
    expect(find.text('已添加公开收藏'), findsNothing);
    expect(harness.opened, isEmpty);
    expect(tester.takeException(), isNull);
    await harness.unmount(tester);
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          'real engine capture ${brightness.name} scale$scale at 375x1000',
          (tester) async {
        harness.authors = _authors(count: 5, longNames: true);
        await harness.mount(tester, brightness: brightness, scale: scale);
        final sheet = tester.getRect(
            find.byKey(const ValueKey('pixiv-follow-recommendations-sheet')));
        final card = tester.getRect(_author('50'));
        final button = tester.getRect(_follow('50'));
        final tile = tester.getRect(_tile('100'));
        final heart = tester.getRect(_heart('100'));
        final authorText =
            tester.widget<Text>(find.text(harness.authors.first.author.name));
        final errors = <String>[];
        Object? error;
        while ((error = tester.takeException()) != null) {
          errors.add(error.toString());
        }
        await _capture(
            tester, harness, '375-${brightness.name}-scale${scale.toInt()}', {
          'brightness': brightness.name,
          'textScale': scale,
          'reducedMotion': true,
          'authorCount': harness.authors.length,
          'worksPerAuthor': 3,
          'sheetRect': _rect(sheet),
          'firstAuthorCardRect': _rect(card),
          'firstFollowButtonRect': _rect(button),
          'firstWorkRect': _rect(tile),
          'firstHeartRect': _rect(heart),
          'frameworkErrors': errors,
          'httpAttempts': deny.attempts,
        });
        expect(authorText.maxLines, 2);
        expect(authorText.overflow, TextOverflow.ellipsis);
        expect(sheet.width, 375);
        expect(sheet.height, inInclusiveRange(330, 480));
        expect(card.width, inInclusiveRange(260, 380));
        expect(tile.height, greaterThan(48));
        expect(button.height, greaterThanOrEqualTo(44));
        expect(heart.size, const Size(48, 48));
        expect(harness.loads, ['42']);
        expect(errors, isEmpty,
            reason:
                'Production modal must fit real CJK font at requested scale');
        await harness.unmount(tester);
      });
    }
  }
}
