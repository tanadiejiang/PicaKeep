import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/pixiv_bookmark_button.dart';
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/network/pixiv_network/pixiv_models.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';
import 'package:picakeep/pages/online_common/online_waterfall_card.dart';

PixivComicBrief _comic(
        {String id = '101',
        bool known = true,
        bool marked = false,
        bool capable = true,
        bool canRead = false}) =>
    PixivComicBrief(
        id: id,
        title: '作品$id',
        cover: '',
        author: '作者',
        tags: const ['标签'],
        pageCount: 3,
        width: 600,
        height: 900,
        illustType: 0,
        authorId: '42',
        isBookmarked: marked,
        bookmarkStateKnown: known,
        isBookmarkable: capable,
        canLoadBookmarkState: canRead);

void main() {
  late ComicSource source;
  late RecommendationBookmarkController controller;
  late PixivBookmarkStateStore store;
  setUp(() {
    source = ComicSource.named(
        key: 'pixiv',
        name: 'Pixiv',
        data: {'token': 'fixture', 'userId': 'fixture-user'});
    store = PixivBookmarkStateStore();
    controller = RecommendationBookmarkController(
        store: store, resolveUnknownStates: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  tearDown(() {
    controller.dispose();
    store.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  final heart = find.byKey(const ValueKey('compact-preview-bookmark'));
  Future<void> pump(
    WidgetTester tester, {
    PixivComicBrief? comic,
    Future<Res<bool>> Function(String, {required bool isAdding})? write,
    Future<Res<PixivBookmarkState>> Function(String)? read,
    VoidCallback? detail,
    bool enabled = true,
    bool active = true,
    String Function()? account,
    bool Function()? loggedIn,
    bool Function()? ownerIsCurrent,
  }) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: PixivBookmarkFeedbackHost(
        active: active,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 120,
            height: 120,
            child: OnlineRecommendationCard(
              source: source,
              comic: comic ?? _comic(),
              bookmarks: controller,
              compactPreview: true,
              onAccountsChanged: () {},
              writeBookmark: write,
              loadBookmarkState: read,
              onOpenDetail: detail ?? () {},
              accountIdentity: account ?? () => 'fixture-account',
              isLoggedIn: loggedIn ?? () => true,
              actionsEnabled: enabled,
              ownerIsCurrent: ownerIsCurrent,
              feedbackCurrent: active,
            ),
          ),
        ),
      ),
    )));
    await tester.pump();
  }

  testWidgets(
      'compact tile keeps fixed geometry and separate heart/detail taps',
      (tester) async {
    var writes = 0, opens = 0;
    await pump(tester,
        detail: () => opens++,
        write: (id, {required isAdding}) async {
          writes++;
          return Res(isAdding);
        });
    expect(find.byType(OnlineWaterfallCard), findsNothing);
    expect(find.text('作品101'), findsNothing);
    expect(find.text('作者'), findsNothing);
    expect(find.text('标签'), findsNothing);
    expect(find.text('3'), findsOneWidget);
    expect(tester.getSize(find.byType(OnlineRecommendationCard)),
        const Size(120, 120));
    expect(tester.getSize(heart), const Size(48, 48));
    await tester.tapAt(
        tester.getTopLeft(find.byType(OnlineRecommendationCard)) +
            const Offset(16, 16));
    await tester.pump();
    expect(opens, 1);
    expect(writes, 0);
    await tester.tap(heart);
    await tester.pumpAndSettle();
    expect(opens, 1);
    expect(writes, 1);
    expect(tester.widget<PixivBookmarkButton>(heart).isBookmarked, isTrue);
    expect(store.stateFor('fixture-account', '101')?.isBookmarked, isTrue);
    expect(tester.getSize(find.byType(OnlineRecommendationCard)),
        const Size(120, 120));
  });

  testWidgets('failed preview write rolls back and double tap sends one write',
      (tester) async {
    var writes = 0;
    final pending = Completer<Res<bool>>();
    await pump(tester, write: (id, {required isAdding}) {
      writes++;
      return pending.future;
    });
    await tester.tap(heart);
    await tester.pump();
    await tester.tap(heart);
    await tester.pump();
    expect(writes, 1);
    expect(tester.widget<PixivBookmarkButton>(heart).busy, isTrue);
    pending.complete(const Res.error('fixture failure'));
    await tester.pumpAndSettle();
    final button = tester.widget<PixivBookmarkButton>(heart);
    expect(button.busy, isFalse);
    expect(button.isBookmarked, isFalse);
    expect(store.stateFor('fixture-account', '101')?.isBookmarked, isNot(true));
  });

  testWidgets(
      'unknown preview skips startup lookup and confirms only on heart tap',
      (tester) async {
    var reads = 0, writes = 0;
    final pending = Completer<Res<PixivBookmarkState>>();
    final comic = _comic(known: false, capable: false, canRead: true);
    await pump(tester, comic: comic, read: (_) {
      reads++;
      return pending.future;
    }, write: (id, {required isAdding}) async {
      writes++;
      expect(isAdding, isTrue);
      return Res(isAdding);
    });
    await tester.pumpAndSettle();
    expect(reads, 0);
    expect(writes, 0);
    expect(heart, findsOneWidget);
    expect(tester.widget<PixivBookmarkButton>(heart).stateKnown, isFalse);
    await tester.tap(heart);
    await tester.pump();
    expect(reads, 1);
    expect(writes, 0);
    pending.complete(const Res(
        PixivBookmarkState(isBookmarked: false, isBookmarkable: true)));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(tester.widget<PixivBookmarkButton>(heart).stateKnown, isTrue);
    expect(tester.widget<PixivBookmarkButton>(heart).isBookmarked, isTrue);
  });

  testWidgets('resolved missing capability does not send a preview write',
      (tester) async {
    var reads = 0, writes = 0;
    await pump(
      tester,
      comic: _comic(known: false, capable: false, canRead: true),
      read: (_) async {
        reads++;
        return const Res(
            PixivBookmarkState(isBookmarked: false, isBookmarkable: false));
      },
      write: (id, {required isAdding}) async {
        writes++;
        return Res(isAdding);
      },
    );
    expect(reads, 0);
    await tester.tap(heart);
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(writes, 0);
    expect(heart, findsNothing);
  });

  testWidgets(
      'inactive and disabled preview targets cannot perform network work',
      (tester) async {
    var reads = 0, writes = 0, opens = 0;
    final comic = _comic(known: false, capable: false, canRead: true);
    Future<Res<PixivBookmarkState>> read(String _) async {
      reads++;
      return const Res(
          PixivBookmarkState(isBookmarked: false, isBookmarkable: true));
    }

    Future<Res<bool>> write(String _, {required bool isAdding}) async {
      writes++;
      return Res(isAdding);
    }

    await pump(tester, comic: comic, active: false, read: read, write: write);
    await tester.tap(heart);
    await tester.pumpAndSettle();
    expect(reads, 0);
    expect(writes, 0);
    await pump(tester,
        comic: comic,
        enabled: false,
        read: read,
        write: write,
        detail: () => opens++);
    await tester.tap(heart);
    await tester.tapAt(
        tester.getTopLeft(find.byType(OnlineRecommendationCard)) +
            const Offset(16, 16));
    await tester.pumpAndSettle();
    expect(reads, 0);
    expect(writes, 0);
    expect(opens, 0);
  });

  testWidgets(
      'account changes discard pending preview confirmation before write',
      (tester) async {
    var account = 'A';
    var writes = 0;
    final pending = Completer<Res<PixivBookmarkState>>();
    await pump(
      tester,
      comic: _comic(known: false, capable: false, canRead: true),
      account: () => account,
      read: (_) => pending.future,
      write: (id, {required isAdding}) async {
        writes++;
        return Res(isAdding);
      },
    );
    await tester.tap(heart);
    await tester.pump();
    account = 'B';
    pending.complete(const Res(
        PixivBookmarkState(isBookmarked: false, isBookmarkable: true)));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(store.stateFor('B', '101'), isNull);
    expect(tester.widget<PixivBookmarkButton>(heart).isBookmarked, isFalse);
  });

  testWidgets('stale owner callbacks are blocked before a rebuild',
      (tester) async {
    var current = true, account = 'A';
    var reads = 0, writes = 0, opens = 0;
    await pump(
      tester,
      comic: _comic(known: false, capable: false, canRead: true),
      account: () => account,
      ownerIsCurrent: () => current,
      detail: () => opens++,
      read: (_) async {
        reads++;
        return const Res(
            PixivBookmarkState(isBookmarked: false, isBookmarkable: true));
      },
      write: (_, {required isAdding}) async {
        writes++;
        return Res(isAdding);
      },
    );
    final oldButton = tester.widget<PixivBookmarkButton>(heart);
    final oldImage = tester
        .widget<InkWell>(find.byKey(const ValueKey('compact-preview-detail')));
    expect(oldButton.enabled, isTrue);
    expect(oldImage.onTap, isNotNull);
    // Deliberately do not pump/rebuild after invalidating the bound owner.
    current = false;
    account = 'B';
    oldButton.onPressed!();
    oldImage.onTap!();
    expect(reads, 0);
    expect(writes, 0);
    expect(opens, 0);
    await tester.pumpAndSettle();
    expect(store.stateFor('B', '101'), isNull);
  });

  testWidgets('owner invalidation cancels a pending read before writing',
      (tester) async {
    var current = true, writes = 0;
    final pending = Completer<Res<PixivBookmarkState>>();
    await pump(
      tester,
      comic: _comic(known: false, capable: false, canRead: true),
      ownerIsCurrent: () => current,
      read: (_) => pending.future,
      write: (_, {required isAdding}) async {
        writes++;
        return Res(isAdding);
      },
    );
    await tester.tap(heart);
    await tester.pump();
    current = false;
    pending.complete(const Res(
        PixivBookmarkState(isBookmarked: false, isBookmarkable: true)));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(tester.widget<PixivBookmarkButton>(heart).busy, isFalse);
    expect(store.stateFor('fixture-account', '101'), isNull);
  });

  testWidgets('preview follows confirmations from a separate shared controller',
      (tester) async {
    final other = RecommendationBookmarkController(store: store);
    addTearDown(other.dispose);
    final comic = _comic();
    await pump(tester, comic: comic);
    await other.toggle(
      account: 'fixture-account',
      comic: comic,
      write: (_, {required isAdding}) async => Res(isAdding),
      isCurrentAccount: () => true,
    );
    await tester.pumpAndSettle();
    expect(tester.widget<PixivBookmarkButton>(heart).isBookmarked, isTrue);
  });
}
