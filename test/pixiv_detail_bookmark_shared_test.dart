import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/components/pixiv_bookmark_button.dart';
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/pixiv_detail_shell.dart';
import 'package:picakeep/pages/online_comic/pixiv_online_detail_view.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';

const _account = 'account-A';
const _original = PixivComicBrief(
  id: '1',
  title: 'Original entry',
  cover: '',
  author: '',
  tags: [],
  illustType: 0,
  pageCount: 1,
);
const _neighbor = PixivComicBrief(
  id: '2',
  title: 'Neighbor entry',
  cover: '',
  author: '',
  tags: [],
  illustType: 0,
  pageCount: 1,
  bookmarkStateKnown: false,
  canLoadBookmarkState: true,
);

PixivComicInfo _detail({bool bookmarked = false}) => parsePixivComicInfo({
      'illustId': '2',
      'illustTitle': 'Neighbor entry',
      'userId': '42',
      'userName': 'Fixture author',
      'width': 800,
      'height': 400,
      'pageCount': 1,
      'illustType': 0,
      'isBookmarkable': true,
      'bookmarkData': bookmarked ? {'id': '202', 'private': 1} : null,
      // Keep the lazy author/comments loaders outside the test viewport.
      'illustComment': List.filled(80, 'Fixture description.').join('<br>'),
      'urls': <String, String>{},
    });

Widget _page({
  required PixivBookmarkStateStore store,
  required PixivDetailBookmarkWriter write,
  bool bookmarked = false,
  bool active = true,
  bool disableAnimations = false,
}) =>
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: PixivDetailEntryScope(
        entry: PixivDetailEntry(
            key: 'fixture', comicId: '2', builder: (_) => const SizedBox()),
        isActive: active,
        child: PixivOnlineDetailView(
          comicId: '2',
          bookmarkStore: store,
          accountIdentity: () => _account,
          isLoggedIn: () => true,
          loadDetail: () async => Res(_detail(bookmarked: bookmarked)),
          loadPages: (_) async => const Res(<PixivPage>[]),
          writeBookmark: write,
          onRead: (_, __, ___) {},
          onDownload: (_, __) {},
          onDownloadLongPress: (_, __) {},
          onTagTap: (_, __, ___) {},
        ),
      ),
    );

PixivDetailShell _shell(WidgetTester tester) =>
    tester.widget<PixivDetailShell>(find.byType(PixivDetailShell));

void _mobileView(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 5; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('pixiv_shared_detail_');
    await App.init(
      dataPathOverride: '${workspace.path}/data',
      cachePathOverride: '${workspace.path}/cache',
    );
  });
  tearDownAll(() async {
    await workspace.delete(recursive: true);
  });

  testWidgets(
      'detail bookmark publishes neighbor ID to other and rebuilt feeds',
      (tester) async {
    _mobileView(tester);
    final store = PixivBookmarkStateStore();
    final feed = RecommendationBookmarkController(store: store);
    final pending = Completer<Res<bool>>();
    final writes = <String>[];
    store.confirm(_account, '1',
        const PixivBookmarkState(isBookmarked: false, isBookmarkable: true));
    expect(feed.isBookmarked(_account, _original), isFalse);
    expect(feed.isBookmarked(_account, _neighbor), isFalse);
    await tester.pumpWidget(_page(
      store: store,
      write: (id, {required isAdding, required isPrivate}) {
        writes.add(id);
        expect(isAdding, isTrue);
        expect(isPrivate, isFalse);
        return pending.future;
      },
    ));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-favorite')));
    await _frames(tester);
    expect(writes, ['2']);
    expect(_shell(tester).favoriteBusy, isTrue);
    expect(feed.isBookmarked(_account, _neighbor), isFalse);
    pending.complete(const Res(true));
    await _frames(tester);
    expect(_shell(tester).isFavorited, isTrue);
    expect(_shell(tester).favoriteBusy, isFalse);
    expect(store.stateFor(_account, '2')?.isBookmarked, isTrue);
    expect(store.stateFor(_account, '2')?.bookmarkPrivate, isFalse);
    expect(feed.isBookmarked(_account, _neighbor), isTrue);
    expect(feed.isBookmarked(_account, _original), isFalse);

    final rebuiltFeed = RecommendationBookmarkController(store: store);
    expect(rebuiltFeed.isBookmarked(_account, _neighbor), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_page(
      store: store,
      write: (_, {required isAdding, required isPrivate}) async =>
          Res(isAdding),
    ));
    await _frames(tester);
    expect(_shell(tester).isFavorited, isTrue,
        reason:
            'A reopened route retains the successful write despite old data');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    rebuiltFeed.dispose();
    feed.dispose();
    store.dispose();
  });

  testWidgets('failed detail write preserves confirmed shared state',
      (tester) async {
    _mobileView(tester);
    final store = PixivBookmarkStateStore();
    final feed = RecommendationBookmarkController(store: store);
    store.confirm(_account, '2',
        const PixivBookmarkState(isBookmarked: false, isBookmarkable: true));
    final revision = store.revisionFor(_account, '2');
    await tester.pumpWidget(_page(
      store: store,
      write: (id, {required isAdding, required isPrivate}) async {
        expect(id, '2');
        expect(isAdding, isTrue);
        return const Res.error('offline failure');
      },
    ));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-favorite')));
    await _frames(tester);
    expect(_shell(tester).isFavorited, isFalse);
    expect(_shell(tester).favoriteBusy, isFalse);
    expect(store.stateFor(_account, '2')?.isBookmarked, isFalse);
    expect(store.revisionFor(_account, '2'), revision);
    expect(feed.isBookmarked(_account, _neighbor), isFalse);
    expect(find.text('收藏失败：offline failure'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    feed.dispose();
    store.dispose();
  });

  testWidgets('inactive entry settles shared state without late feedback',
      (tester) async {
    _mobileView(tester);
    final store = PixivBookmarkStateStore();
    final pending = Completer<Res<bool>>();
    Future<Res<bool>> write(String id,
            {required bool isAdding, required bool isPrivate}) =>
        pending.future;
    await tester.pumpWidget(_page(store: store, write: write));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-favorite')));
    await _frames(tester);
    await tester.pumpWidget(_page(store: store, write: write, active: false));
    await _frames(tester);
    expect(_shell(tester).favoriteActive, isFalse);
    pending.complete(const Res(true));
    await _frames(tester);
    expect(store.stateFor(_account, '2')?.isBookmarked, isTrue);
    expect(_shell(tester).isFavorited, isTrue);
    expect(_shell(tester).favoriteBusy, isFalse);
    expect(_shell(tester).favoriteEvent, isNull);
    expect(find.byKey(const ValueKey('pixiv-bookmark-feedback')), findsNothing);
    await tester.pumpWidget(_page(store: store, write: write));
    await _frames(tester);
    expect(_shell(tester).favoriteActive, isTrue);
    expect(_shell(tester).favoriteEvent, isNull);
    expect(find.text('已添加公开收藏'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  testWidgets('leaving and returning before completion expires the old ticket',
      (tester) async {
    _mobileView(tester);
    final store = PixivBookmarkStateStore();
    final pending = Completer<Res<bool>>();
    Future<Res<bool>> write(String id,
            {required bool isAdding, required bool isPrivate}) =>
        pending.future;
    await tester.pumpWidget(_page(store: store, write: write));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-favorite')));
    await tester.pump();
    final originalEpoch = _shell(tester).favoriteVisualEpoch as int;
    await tester.pump(const Duration(milliseconds: 350));
    expect(
        tester
            .widget<Icon>(
                find.byKey(const ValueKey('pixiv-bookmark-main-icon')))
            .icon,
        Icons.favorite);
    await tester.pumpWidget(_page(store: store, write: write, active: false));
    await _frames(tester);
    await tester.pumpWidget(_page(store: store, write: write));
    await _frames(tester);
    expect(
        _shell(tester).favoriteVisualEpoch as int, greaterThan(originalEpoch));
    expect(_shell(tester).favoriteBusy, isTrue);
    expect(_shell(tester).isFavorited, isFalse);
    expect(
        tester
            .widget<Icon>(
                find.byKey(const ValueKey('pixiv-bookmark-main-icon')))
            .icon,
        Icons.favorite_border);
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.text('正在提交收藏…'), findsNothing);
    pending.complete(const Res(true));
    await _frames(tester);
    expect(store.stateFor(_account, '2')?.isBookmarked, isTrue);
    expect(_shell(tester).favoriteEvent, isNull);
    expect(find.text('已添加公开收藏'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  testWidgets('pushed route suppresses feedback but keeps shared confirmation',
      (tester) async {
    _mobileView(tester);
    final store = PixivBookmarkStateStore();
    final pending = Completer<Res<bool>>();
    await tester.pumpWidget(_page(
      store: store,
      write: (_, {required isAdding, required isPrivate}) => pending.future,
    ));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-favorite')));
    final navigator =
        Navigator.of(tester.element(find.byType(PixivDetailShell)));
    unawaited(navigator.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('another work route')),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    pending.complete(const Res(true));
    await _frames(tester);
    expect(store.stateFor(_account, '2')?.isBookmarked, isTrue);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(_shell(tester).isFavorited, isTrue);
    expect(_shell(tester).favoriteEvent, isNull);
    expect(find.text('已添加公开收藏'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  testWidgets('route return clears pending visuals while writer still settles',
      (tester) async {
    _mobileView(tester);
    final store = PixivBookmarkStateStore();
    final pending = Completer<Res<bool>>();
    var writes = 0;
    await tester.pumpWidget(_page(
      store: store,
      write: (_, {required isAdding, required isPrivate}) {
        writes++;
        return pending.future;
      },
    ));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-favorite')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final originalEpoch = _shell(tester).favoriteVisualEpoch as int;
    final navigator =
        Navigator.of(tester.element(find.byType(PixivDetailShell)));
    unawaited(navigator.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('route before confirmation')),
    )));
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(
        _shell(tester).favoriteVisualEpoch as int, greaterThan(originalEpoch));
    expect(_shell(tester).favoriteBusy, isTrue);
    expect(_shell(tester).isFavorited, isFalse);
    expect(
        tester
            .widget<Icon>(
                find.byKey(const ValueKey('pixiv-bookmark-main-icon')))
            .icon,
        Icons.favorite_border);
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.text('正在提交收藏…'), findsNothing);
    pending.complete(const Res(true));
    await _frames(tester);
    expect(writes, 1);
    expect(store.stateFor(_account, '2')?.isBookmarked, isTrue);
    expect(_shell(tester).isFavorited, isTrue);
    expect(_shell(tester).favoriteBusy, isFalse);
    expect(_shell(tester).favoriteEvent, isNull);
    expect(find.text('已添加公开收藏'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  for (final delay in [0, 700, 2500]) {
    testWidgets('detail add starts once with ${delay}ms confirmation',
        (tester) async {
      _mobileView(tester);
      final store = PixivBookmarkStateStore();
      final pending = Completer<Res<bool>>();
      var writes = 0;
      await tester.pumpWidget(_page(
        store: store,
        write: (_, {required isAdding, required isPrivate}) {
          writes++;
          expect(isAdding, isTrue);
          return delay == 0 ? Future.value(const Res(true)) : pending.future;
        },
      ));
      await _frames(tester);
      await tester.tap(find.byKey(const ValueKey('pixiv-detail-favorite')));
      await tester.pump();
      final event = _shell(tester).favoriteEvent!;
      final begin = delay == 0 ? event.begin! : event;
      expect(begin.phase, PixivBookmarkPhase.begin);
      expect(begin.target, isTrue);
      expect(begin.operationId, 1);
      expect(_shell(tester).isFavorited, delay == 0);
      expect(store.stateFor(_account, '2')?.isBookmarked,
          delay == 0 ? true : null);
      await tester.pump(const Duration(milliseconds: 50));
      final scale = tester.widget<Transform>(
          find.byKey(const ValueKey('pixiv-bookmark-main-scale')));
      expect(scale.transform.storage[0], lessThan(1),
          reason: 'Even an immediate Future retains the accepted first motion');
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const ValueKey('pixiv-bookmark-ring')), findsNothing);
      expect(
          tester
              .widget<Icon>(
                  find.byKey(const ValueKey('pixiv-bookmark-main-icon')))
              .icon,
          Icons.favorite);
      if (delay != 0) {
        expect(_shell(tester).favoriteBusy, isTrue);
        expect(_shell(tester).isFavorited, isFalse);
        expect(find.text('已添加公开收藏'), findsNothing);
        expect(find.text('正在提交收藏…'), findsOneWidget);
        await tester.pump(Duration(milliseconds: delay - 300));
        pending.complete(const Res(true));
        await tester.pump();
        await tester.pump();
      }
      final settled = _shell(tester).favoriteEvent!;
      expect(settled.phase, PixivBookmarkPhase.settle);
      expect(settled.success, isTrue);
      expect(settled.operationId, begin.operationId);
      expect(settled.sequence, greaterThan(begin.sequence));
      expect(_shell(tester).favoriteBusy, isFalse);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('正在提交收藏…'), findsNothing);
      expect(find.text('已添加公开收藏'), findsOneWidget);
      expect(find.byKey(const ValueKey('pixiv-bookmark-ring')), findsNothing);
      expect(
          tester
              .widget<Transform>(
                  find.byKey(const ValueKey('pixiv-bookmark-main-scale')))
              .transform
              .storage[0],
          1,
          reason: 'A completed first motion is not restarted by success');
      expect(writes, 1);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      store.dispose();
    });
  }

  testWidgets('fast cancellation retains the full 500ms falling heart',
      (tester) async {
    _mobileView(tester);
    final store = PixivBookmarkStateStore();
    await tester.pumpWidget(_page(
      store: store,
      bookmarked: true,
      write: (_, {required isAdding, required isPrivate}) async {
        expect(isAdding, isFalse);
        return const Res(false);
      },
    ));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-favorite')));
    await tester.pump();
    expect(_shell(tester).favoriteEvent?.phase, PixivBookmarkPhase.settle);
    expect(_shell(tester).favoriteEvent?.begin?.target, isFalse);
    expect(_shell(tester).isFavorited, isFalse);
    expect(
        find.byKey(const ValueKey('pixiv-bookmark-fall-icon')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    final fall = tester.widget<Transform>(
        find.byKey(const ValueKey('pixiv-bookmark-fall-translation')));
    expect(fall.transform.storage[13], closeTo(14, .01));
    expect(
        find.byKey(const ValueKey('pixiv-bookmark-fall-icon')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 249));
    expect(
        find.byKey(const ValueKey('pixiv-bookmark-fall-icon')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(
        find.byKey(const ValueKey('pixiv-bookmark-fall-icon')), findsNothing);
    expect(find.text('已取消收藏'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  testWidgets('failure restores the newest authority received while busy',
      (tester) async {
    _mobileView(tester);
    final store = PixivBookmarkStateStore();
    final pending = Completer<Res<bool>>();
    var writes = 0;
    await tester.pumpWidget(_page(
      store: store,
      write: (_, {required isAdding, required isPrivate}) {
        writes++;
        return pending.future;
      },
    ));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-favorite')));
    await tester.pump();
    store.confirm(_account, '2',
        const PixivBookmarkState(isBookmarked: true, isBookmarkable: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_shell(tester).isFavorited, isFalse,
        reason: 'The existing busy listener does not consume shared updates');
    final revision = store.revisionFor(_account, '2');
    pending.complete(const Res.error('latest authority fixture'));
    await tester.pump();
    await tester.pump();
    expect(_shell(tester).isFavorited, isTrue);
    expect(_shell(tester).favoriteEvent?.success, isFalse);
    await tester.pump(const Duration(milliseconds: 140));
    expect(
        tester
            .widget<Icon>(
                find.byKey(const ValueKey('pixiv-bookmark-main-icon')))
            .icon,
        Icons.favorite);
    expect(store.revisionFor(_account, '2'), revision);
    expect(writes, 1);
    expect(find.text('收藏失败：latest authority fixture'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  testWidgets('private detail starts immediately and replaces delayed waiting',
      (tester) async {
    _mobileView(tester);
    final store = PixivBookmarkStateStore();
    final pending = Completer<Res<bool>>();
    await tester.pumpWidget(_page(
      store: store,
      write: (_, {required isAdding, required isPrivate}) {
        expect(isAdding, isTrue);
        expect(isPrivate, isTrue);
        return pending.future;
      },
    ));
    await _frames(tester);
    await tester.longPress(find.byKey(const ValueKey('pixiv-detail-favorite')));
    await tester.pump();
    expect(_shell(tester).favoriteEvent?.phase, PixivBookmarkPhase.begin);
    expect(_shell(tester).isFavorited, isFalse);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('正在提交收藏…'), findsOneWidget);
    pending.complete(const Res(true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(store.stateFor(_account, '2')?.bookmarkPrivate, isTrue);
    expect(find.text('正在提交收藏…'), findsNothing);
    expect(find.text('已添加私密收藏'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2500));
    expect(find.text('已添加私密收藏'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  for (final reduced in [false, true]) {
    testWidgets('actual write emits one selection haptic with reduced=$reduced',
        (tester) async {
      _mobileView(tester);
      final store = PixivBookmarkStateStore();
      final pending = Completer<Res<bool>>();
      final haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      var writes = 0;
      await tester.pumpWidget(_page(
        store: store,
        disableAnimations: reduced,
        write: (_, {required isAdding, required isPrivate}) {
          writes++;
          return pending.future;
        },
      ));
      await _frames(tester);
      final favorite = find.byKey(const ValueKey('pixiv-detail-favorite'));
      expect(tester.getSize(favorite), const Size(56, 56));
      expect(_shell(tester).onlineBookmarkAnimations, isTrue);
      await tester.tap(favorite);
      await _frames(tester);
      await tester.tap(favorite, warnIfMissed: false);
      await _frames(tester);
      expect(writes, 1);
      expect(
          haptics, reduced ? isEmpty : ['HapticFeedbackType.selectionClick']);
      pending.complete(const Res(true));
      await _frames(tester);
      expect(_shell(tester).favoriteEvent?.phase, PixivBookmarkPhase.settle);
      expect(_shell(tester).favoriteEvent?.success, isTrue);
      expect(find.text('已添加公开收藏'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(haptics.length, reduced ? 0 : 1);
      final capsule =
          tester.getRect(find.byKey(const ValueKey('pixiv-bookmark-feedback')));
      final heart = tester.getRect(favorite);
      expect(capsule.bottom, lessThanOrEqualTo(heart.top));
      expect(capsule.left, greaterThanOrEqualTo(16));
      expect(capsule.right, lessThanOrEqualTo(384));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      store.dispose();
    });
  }

  testWidgets('passive confirmation is static and thrown writer shows failure',
      (tester) async {
    _mobileView(tester);
    final store = PixivBookmarkStateStore();
    await tester.pumpWidget(_page(
      store: store,
      write: (_, {required isAdding, required isPrivate}) async {
        throw StateError('fixture transport failed');
      },
    ));
    await _frames(tester);
    store.confirm(_account, '2',
        const PixivBookmarkState(isBookmarked: true, isBookmarkable: true));
    await _frames(tester);
    expect(_shell(tester).isFavorited, isTrue);
    expect(_shell(tester).favoriteEvent, isNull);
    expect(find.byType(PixivBookmarkFeedbackHost), findsOneWidget);
    expect(find.byKey(const ValueKey('pixiv-bookmark-feedback')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-favorite')));
    await _frames(tester);
    expect(_shell(tester).favoriteBusy, isFalse);
    expect(_shell(tester).isFavorited, isTrue);
    expect(_shell(tester).favoriteEvent?.phase, PixivBookmarkPhase.settle);
    expect(_shell(tester).favoriteEvent?.success, isFalse);
    expect(store.stateFor(_account, '2')?.isBookmarked, isTrue);
    expect(
        find.text('收藏失败：Bad state: fixture transport failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  testWidgets('detail cancellation updates all feeds and clears privacy',
      (tester) async {
    _mobileView(tester);
    final store = PixivBookmarkStateStore();
    final feed = RecommendationBookmarkController(store: store);
    store.confirm(
        _account,
        '2',
        const PixivBookmarkState(
            isBookmarked: true, isBookmarkable: true, bookmarkPrivate: true));
    expect(feed.isBookmarked(_account, _neighbor), isTrue);
    await tester.pumpWidget(_page(
      store: store,
      bookmarked: true,
      write: (id, {required isAdding, required isPrivate}) async {
        expect(id, '2');
        expect(isAdding, isFalse);
        return const Res(false);
      },
    ));
    await _frames(tester);
    expect(_shell(tester).isFavorited, isTrue);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-favorite')));
    await _frames(tester);
    expect(_shell(tester).isFavorited, isFalse);
    expect(store.stateFor(_account, '2')?.isBookmarked, isFalse);
    expect(store.stateFor(_account, '2')?.bookmarkPrivate, isNull);
    expect(feed.isBookmarked(_account, _neighbor), isFalse);
    final rebuiltFeed = RecommendationBookmarkController(store: store);
    expect(rebuiltFeed.isBookmarked(_account, _neighbor), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    rebuiltFeed.dispose();
    feed.dispose();
    store.dispose();
  });
}
