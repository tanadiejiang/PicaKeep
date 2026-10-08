import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/network/jm_network/jm_models.dart';
import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/pixiv_author_page_v2.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';
import 'package:picakeep/pages/online_common/online_waterfall_card.dart';

PixivComicBrief _comic(
        {String id = '1',
        bool marked = false,
        bool bookmarkable = true,
        bool stateKnown = true,
        String authorId = '42'}) =>
    PixivComicBrief(
      id: id,
      title: '作品$id',
      cover: '',
      author: '画师',
      tags: const ['猫'],
      illustType: 0,
      pageCount: 3,
      width: 100,
      height: 150,
      authorId: authorId,
      isBookmarked: marked,
      isBookmarkable: bookmarkable,
      bookmarkStateKnown: stateKnown,
      canLoadBookmarkState: !stateKnown,
    );

PixivBookmarkState _info({required bool marked, bool bookmarkable = true}) =>
    PixivBookmarkState(
      isBookmarked: marked,
      isBookmarkable: bookmarkable,
    );

void main() {
  late RecommendationBookmarkController bookmarks;
  late ComicSource source;
  setUp(() {
    bookmarks = RecommendationBookmarkController();
    source = ComicSource.named(
        key: 'pixiv',
        name: 'Pixiv',
        data: {'token': 'fixture', 'userId': '99'});
  });
  tearDown(() => bookmarks.dispose());

  Future<void> pump(
    WidgetTester tester, {
    PixivComicBrief? comic,
    Future<Res<bool>> Function(String, {required bool isAdding})? write,
    Future<Res<PixivBookmarkState>> Function(String)? loadBookmarkState,
    bool Function()? loggedIn,
    String Function()? account,
    Future<void> Function(BuildContext)? manage,
    VoidCallback? accountsChanged,
    VoidCallback? detail,
    ValueChanged<String>? author,
    Future<void> Function()? refresh,
    bool actionsEnabled = true,
    bool isAuthorPage = false,
  }) =>
      tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: PixivBookmarkFeedbackHost(
                  child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: 180,
                        child: OnlineRecommendationCard(
                          source: source,
                          comic: comic ?? _comic(),
                          bookmarks: bookmarks,
                          onAccountsChanged: accountsChanged ?? () {},
                          writeBookmark: write,
                          loadBookmarkState: loadBookmarkState,
                          isLoggedIn: loggedIn,
                          accountIdentity: account,
                          manageAccounts: manage,
                          onOpenDetail: detail,
                          onOpenAuthor: author,
                          onDataRefresh: refresh,
                          actionsEnabled: actionsEnabled,
                          isAuthorPage: isAuthorPage,
                        ),
                      ))))));

  testWidgets(
      'visible unknown state resolves without write UI and survives a new adapter',
      (tester) async {
    final store = PixivBookmarkStateStore();
    addTearDown(store.dispose);
    bookmarks.dispose();
    bookmarks = RecommendationBookmarkController(
        store: store, resolveUnknownStates: true);
    final pending = Completer<Res<PixivBookmarkState>>();
    var reads = 0, writes = 0;
    Future<Res<PixivBookmarkState>> read(String _) {
      reads++;
      return pending.future;
    }

    Future<Res<bool>> write(String _, {required bool isAdding}) async {
      writes++;
      return Res(isAdding);
    }

    await pump(tester,
        comic: _comic(stateKnown: false),
        loadBookmarkState: read,
        write: write,
        loggedIn: () => true);
    await tester.pumpAndSettle();
    var card =
        tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
    expect(reads, 1);
    expect(card.favoriteBusy, isFalse);
    expect(card.favoriteStateKnown, isFalse);
    expect(find.byKey(const Key('waterfall-favorite-progress')), findsNothing);
    pending.complete(Res(_info(marked: true)));
    await tester.pumpAndSettle();
    card = tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
    expect(card.isFavorited, isTrue);
    expect(card.favoriteStateKnown, isTrue);
    expect(writes, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    bookmarks.dispose();
    bookmarks = RecommendationBookmarkController(
        store: store, resolveUnknownStates: true);
    await pump(tester,
        comic: _comic(stateKnown: false),
        loadBookmarkState: read,
        write: write,
        loggedIn: () => true);
    await tester.pumpAndSettle();
    card = tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
    expect(card.isFavorited, isTrue);
    expect(card.favoriteBusy, isFalse);
    expect(reads, 1, reason: '重新进入页面复用已确认状态');
    expect(writes, 0);
  });

  testWidgets('duplicate cards share confirmed state and a single write lock',
      (tester) async {
    final pending = Completer<Res<bool>>();
    final targets = <bool>[];
    var detailCalls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Row(children: [
      for (var i = 0; i < 2; i++)
        SizedBox(
          width: 180,
          child: OnlineRecommendationCard(
            source: source,
            comic: i == 0
                ? _comic()
                : _comic(bookmarkable: false, stateKnown: false),
            bookmarks: bookmarks,
            onAccountsChanged: () {},
            onOpenDetail: () => detailCalls++,
            writeBookmark: (id, {required isAdding}) {
              expect(id, '1');
              targets.add(isAdding);
              return pending.future;
            },
          ),
        ),
    ]))));
    final cards = find.byType(OnlineWaterfallCard);
    expect(
        tester.widget<OnlineWaterfallCard>(cards.first).isFavorited, isFalse);
    tester.widget<OnlineWaterfallCard>(cards.first).onToggleFavorite!();
    tester.widget<OnlineWaterfallCard>(cards.last).onToggleFavorite!();
    await tester.pump();
    expect(targets, [true]);
    for (final element in cards.evaluate()) {
      expect((element.widget as OnlineWaterfallCard).favoriteBusy, isTrue);
    }
    pending.complete(const Res(true));
    await tester.pumpAndSettle();
    for (final element in cards.evaluate()) {
      expect((element.widget as OnlineWaterfallCard).isFavorited, isTrue);
      expect((element.widget as OnlineWaterfallCard).favoriteBusy, isFalse);
    }
    expect(detailCalls, 0);
  });

  test('a new known brief invalidates an older unknown-state read', () async {
    final pendingRead = Completer<Res<PixivBookmarkState>>();
    var writes = 0;
    final pending = bookmarks.toggle(
      account: 'account-99',
      comic: _comic(bookmarkable: false, stateKnown: false),
      readState: (_) => pendingRead.future,
      write: (_, {required isAdding}) async {
        writes++;
        return Res(isAdding);
      },
      isCurrentAccount: () => true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(bookmarks.isBusy('account-99', _comic(stateKnown: false)), isTrue);

    final refreshed = _comic(marked: true, stateKnown: true);
    expect(bookmarks.isBusy('account-99', refreshed), isTrue);
    pendingRead.complete(Res(_info(marked: false)));
    await pending;

    expect(writes, 0);
    expect(bookmarks.isBookmarked('account-99', refreshed), isTrue);
    expect(bookmarks.isBusy('account-99', refreshed), isFalse);
  });

  test('equivalent known updates and unknown briefs retain in-flight writes',
      () async {
    final pendingWrite = Completer<Res<bool>>();
    final comic = _comic(marked: false, stateKnown: true);
    final pending = bookmarks.toggle(
      account: 'account-99',
      comic: comic,
      write: (_, {required isAdding}) {
        expect(isAdding, isTrue);
        return pendingWrite.future;
      },
      isCurrentAccount: () => true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(bookmarks.isBusy('account-99', comic), isTrue);
    expect(
        bookmarks.isBookmarked(
            'account-99', _comic(marked: false, stateKnown: true)),
        isFalse);
    expect(
        bookmarks.isBookmarked('account-99',
            _comic(marked: true, bookmarkable: false, stateKnown: false)),
        isFalse);

    pendingWrite.complete(const Res(true));
    expect((await pending)?.data, isTrue);
    expect(bookmarks.isBookmarked('account-99', comic), isTrue);
  });

  test('an unknown brief cannot downgrade a confirmed bookmark state', () {
    const account = 'account-99';
    final known = _comic(marked: true, stateKnown: true);
    bookmarks.synchronizeConfirmedState(
      account: account,
      comic: known,
      state: _info(marked: true),
    );

    final unknown =
        _comic(marked: false, bookmarkable: false, stateKnown: false);
    expect(bookmarks.isBookmarked(account, unknown), isTrue);
    expect(bookmarks.isStateKnown(account, unknown), isTrue);
    expect(bookmarks.canToggle(account, unknown), isTrue);
  });

  for (final invalidation in ['toggle', 'reset', 'account', 'confirmation']) {
    test('late detail read cannot overwrite newer $invalidation', () async {
      const account = 'account-99';
      final comic = _comic(marked: true);
      bookmarks.synchronizeConfirmedState(
          account: account, comic: comic, state: _info(marked: true));
      final pendingRead = Completer<Res<PixivBookmarkState>>();
      var current = true;
      final refresh = bookmarks.refreshConfirmedState(
          account: account,
          comic: comic,
          readState: (_) => pendingRead.future,
          isCurrentAccount: () => current);
      if (invalidation == 'toggle') {
        await bookmarks.toggle(
            account: account,
            comic: comic,
            write: (_, {required isAdding}) async => Res(isAdding),
            isCurrentAccount: () => true);
      } else if (invalidation == 'reset') {
        bookmarks.reset();
        expect(bookmarks.isBookmarked(account, _comic()), isFalse);
      } else {
        if (invalidation == 'account') current = false;
        bookmarks.synchronizeConfirmedState(
            account: account, comic: comic, state: _info(marked: false));
      }
      pendingRead.complete(Res(_info(marked: true)));
      await refresh;
      expect(bookmarks.isBookmarked(account, _comic()), isFalse);
      expect(bookmarks.isBusy(account, comic), isFalse);
    });
  }

  test('conflicting known update rejects a late write result', () async {
    final pendingWrite = Completer<Res<bool>>();
    final initial = _comic(marked: false, stateKnown: true);
    final pending = bookmarks.toggle(
      account: 'account-99',
      comic: initial,
      write: (_, {required isAdding}) => pendingWrite.future,
      isCurrentAccount: () => true,
    );
    await Future<void>.delayed(Duration.zero);
    final authoritative = _comic(marked: true, stateKnown: true);
    expect(bookmarks.isBookmarked('account-99', authoritative), isFalse);
    pendingWrite.complete(const Res(true));

    expect(await pending, isNull);
    expect(bookmarks.isBookmarked('account-99', authoritative), isTrue);
    expect(bookmarks.isBusy('account-99', authoritative), isFalse);
  });

  testWidgets('two mounted cards can add then remove through one controller',
      (tester) async {
    final recommendation = _comic(marked: false, stateKnown: true);
    final author =
        _comic(marked: false, bookmarkable: false, stateKnown: false);
    final add = Completer<Res<bool>>();
    final remove = Completer<Res<bool>>();
    final writes = <bool>[];
    Future<Res<bool>> write(String _, {required bool isAdding}) {
      writes.add(isAdding);
      return isAdding ? add.future : remove.future;
    }

    Future<void> mount() => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Row(children: [
              for (var index = 0; index < 2; index++)
                SizedBox(
                  width: 180,
                  child: OnlineRecommendationCard(
                    source: source,
                    // The recommendation card keeps an old known false brief;
                    // the author adapter supplies an unknown brief for the
                    // same ID while both remain mounted.
                    comic: index == 0 ? recommendation : author,
                    bookmarks: bookmarks,
                    onAccountsChanged: () {},
                    writeBookmark: write,
                  ),
                ),
            ]),
          ),
        ));

    await mount();
    await tester.pumpAndSettle();
    var cards = find.byType(OnlineWaterfallCard);
    tester.widget<OnlineWaterfallCard>(cards.first).onToggleFavorite!();
    await tester.pump();
    expect(writes, [true]);
    add.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(tester.widget<OnlineWaterfallCard>(cards.first).isFavorited, isTrue);

    // Rebuild both source cards before the second request completes. The
    // stale known=false recommendation brief must not cancel the remove.
    await mount();
    await tester.pump();
    cards = find.byType(OnlineWaterfallCard);
    tester.widget<OnlineWaterfallCard>(cards.last).onToggleFavorite!();
    await tester.pump();
    expect(writes, [true, false]);
    remove.complete(const Res(false));
    await tester.pumpAndSettle();
    expect(writes, [true, false]);
    expect(
        tester.widget<OnlineWaterfallCard>(cards.first).isFavorited, isFalse);
    expect(tester.takeException(), isNull);
  });

  test('a fresh known snapshot invalidates a write after prior confirmation',
      () async {
    const account = 'account-99';
    final old = _comic(marked: false, stateKnown: true);
    bookmarks.synchronizeConfirmedState(
      account: account,
      comic: old,
      state: _info(marked: true),
    );
    final pendingWrite = Completer<Res<bool>>();
    final pending = bookmarks.toggle(
      account: account,
      comic: old,
      write: (_, {required isAdding}) => pendingWrite.future,
      isCurrentAccount: () => true,
    );
    await Future<void>.delayed(Duration.zero);
    final fresh = _comic(marked: false, stateKnown: true);
    expect(bookmarks.isBusy(account, fresh), isTrue);
    pendingWrite.complete(const Res(false));

    expect(await pending, isNull);
    expect(bookmarks.isBookmarked(account, fresh), isFalse);
    expect(bookmarks.isBusy(account, fresh), isFalse);
  });

  testWidgets('author mode hides repeated identity while preserving metadata',
      (tester) async {
    var details = 0, writes = 0;
    await pump(tester,
        isAuthorPage: true,
        detail: () => details++,
        write: (_, {required isAdding}) async {
          writes++;
          return Res(isAdding);
        });
    await tester.pumpAndSettle();
    final card =
        tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
    expect(card.author, isEmpty);
    expect(card.showAuthorAvatar, isFalse);
    expect(card.onAuthorTap, isNull);
    expect(card.pageCount, 3);
    expect(card.tags, ['猫']);
    expect(find.byKey(const Key('waterfall-avatar')), findsNothing);
    expect(find.text('画师'), findsNothing);
    await tester.tap(find.byKey(const Key('waterfall-favorite')));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(details, 0);
    await tester.tap(find.text('作品1'));
    expect(details, 1);
  });

  testWidgets('default author route passes the external bookmark controller',
      (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();
    tester
        .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
        .onAuthorTap!();
    await tester.pumpAndSettle();
    final authorPage =
        tester.widget<PixivAuthorPageV2>(find.byType(PixivAuthorPageV2));
    expect(authorPage.bookmarks, same(bookmarks));
    expect(authorPage.uid, '42');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('heart and author tap never trigger the detail route',
      (tester) async {
    var details = 0, writes = 0;
    final authors = <String>[];
    await pump(tester,
        detail: () => details++,
        author: authors.add,
        write: (_, {required isAdding}) async {
          writes++;
          return Res(isAdding);
        });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('waterfall-favorite')));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(details, 0);
    // The author row owns its tap, independently of the surrounding card.
    await tester.tap(find.text('画师'));
    await tester.pumpAndSettle();
    expect(authors, ['42']);
    expect(details, 0);
    await tester.tap(find.text('作品1'));
    expect(details, 1);
  });

  testWidgets('ranking brief shows metadata and resolves bookmark before write',
      (tester) async {
    final comic = parsePixivRankingItems({
      'contents': [
        {
          'illust_id': 11,
          'title': '榜单作品',
          'url': 'https://i.pximg.net/c/480x960/master1200.jpg',
          'tags': ['标签一'],
          'illust_type': '0',
          'illust_page_count': '7',
          'user_id': 42,
          'user_name': '榜单作者',
          'profile_img': 'https://i.pximg.net/user-profile/a_50.jpg',
          'width': '1389',
          'height': '1736',
        },
      ],
    }).single;
    var stateReads = 0;
    final writes = <bool>[];
    await pump(
      tester,
      comic: comic,
      loadBookmarkState: (id) async {
        expect(id, '11');
        stateReads++;
        return Res(_info(marked: true, bookmarkable: false));
      },
      write: (id, {required isAdding}) async {
        expect(id, '11');
        writes.add(isAdding);
        return Res(isAdding);
      },
    );
    await tester.pumpAndSettle();
    final card =
        tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
    expect(card.authorAvatarUrl, endsWith('_50.jpg'));
    expect(card.onAuthorTap, isNotNull);
    expect((card.width, card.height, card.pageCount), (1389, 1736, 7));
    expect(card.onToggleFavorite, isNotNull,
        reason: '榜单没有收藏字段时仍显示按钮，点按前先查权威状态');
    expect(card.isFavorited, isFalse);

    await tester.tap(find.byKey(const Key('waterfall-favorite')));
    await tester.pumpAndSettle();
    expect(stateReads, 1);
    expect(writes, [false], reason: '查询确认已收藏后，本次切换应按取消收藏执行');
    final updated =
        tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
    expect(updated.isFavorited, isFalse);
    expect(updated.onToggleFavorite, isNull, reason: '取消后该条目不可再添加，心形操作应收起');
  });

  testWidgets('ranking bookmark state read failure never submits a write',
      (tester) async {
    var writes = 0;
    await pump(
      tester,
      comic: _comic(bookmarkable: false, stateKnown: false),
      loggedIn: () => true,
      loadBookmarkState: (_) async => const Res.error('offline'),
      write: (_, {required isAdding}) async {
        writes++;
        return Res(isAdding);
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('waterfall-favorite')));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(find.text('收藏失败：offline'), findsOneWidget);
  });

  testWidgets('ranking bookmark read from a previous account cannot write',
      (tester) async {
    final pending = Completer<Res<PixivBookmarkState>>();
    var account = 'account-1';
    var writes = 0;
    await pump(
      tester,
      comic: _comic(bookmarkable: false, stateKnown: false),
      account: () => account,
      loggedIn: () => true,
      loadBookmarkState: (_) => pending.future,
      write: (_, {required isAdding}) async {
        writes++;
        return Res(isAdding);
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('waterfall-favorite')));
    await tester.pump();
    account = 'account-2';
    pending.complete(Res(_info(marked: false)));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(find.byKey(const Key('waterfall-favorite')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'duplicate unknown ranking cards share one state read and one bookmark write',
      (tester) async {
    final pendingRead = Completer<Res<PixivBookmarkState>>();
    final pendingWrite = Completer<Res<bool>>();
    var reads = 0;
    final writes = <bool>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Row(children: [
      for (var i = 0; i < 2; i++)
        SizedBox(
          width: 180,
          child: OnlineRecommendationCard(
            source: source,
            comic: _comic(bookmarkable: false, stateKnown: false),
            bookmarks: bookmarks,
            onAccountsChanged: () {},
            isLoggedIn: () => true,
            loadBookmarkState: (id) {
              expect(id, '1');
              reads++;
              return pendingRead.future;
            },
            writeBookmark: (id, {required isAdding}) {
              expect(id, '1');
              writes.add(isAdding);
              return pendingWrite.future;
            },
          ),
        ),
    ]))));
    await tester.pumpAndSettle();
    final cards = find.byType(OnlineWaterfallCard);
    tester.widget<OnlineWaterfallCard>(cards.first).onToggleFavorite!();
    tester.widget<OnlineWaterfallCard>(cards.last).onToggleFavorite!();
    await tester.pump();
    expect(reads, 1);
    expect(writes, isEmpty);
    for (final card in tester.widgetList<OnlineWaterfallCard>(cards)) {
      expect(card.favoriteBusy, isTrue);
    }

    await tester.runAsync(() async {
      pendingRead.complete(Res(_info(marked: false)));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(writes, [true]);
    for (final card in tester.widgetList<OnlineWaterfallCard>(cards)) {
      expect(card.favoriteBusy, isTrue);
      card.onToggleFavorite!();
    }
    expect(writes, [true]);

    pendingWrite.complete(const Res(true));
    await tester.pumpAndSettle();
    for (final card in tester.widgetList<OnlineWaterfallCard>(cards)) {
      expect(card.isFavorited, isTrue);
      expect(card.favoriteBusy, isFalse);
    }
    expect(reads, 1);
    expect(writes, [true]);
    expect(tester.takeException(), isNull);
  });

  for (final change in [
    'refresh',
    'disable actions',
    'replace comic',
    'dispose'
  ]) {
    testWidgets('pending ranking state read cannot write after $change',
        (tester) async {
      final pendingRead = Completer<Res<PixivBookmarkState>>();
      final unknown = _comic(bookmarkable: false, stateKnown: false);
      var reads = 0, writes = 0;
      Future<Res<PixivBookmarkState>> read(String id) {
        expect(id, '1');
        reads++;
        return pendingRead.future;
      }

      Future<Res<bool>> write(String _, {required bool isAdding}) async {
        writes++;
        return Res(isAdding);
      }

      await pump(tester,
          comic: unknown,
          loggedIn: () => true,
          loadBookmarkState: read,
          write: write);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('waterfall-favorite')));
      await tester.pump();
      expect(reads, 1);
      expect(writes, 0);
      expect(
          tester
              .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
              .favoriteBusy,
          isTrue);

      switch (change) {
        case 'refresh':
          bookmarks.reset();
          await tester.pump();
        case 'disable actions':
          await pump(tester,
              comic: unknown,
              loggedIn: () => true,
              loadBookmarkState: read,
              write: write,
              actionsEnabled: false);
        case 'replace comic':
          await pump(tester,
              comic: _comic(id: '2', bookmarkable: false, stateKnown: false),
              loggedIn: () => true,
              loadBookmarkState: read,
              write: write);
        case 'dispose':
          await tester.pumpWidget(const SizedBox());
      }
      pendingRead.complete(Res(_info(marked: false)));
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(reads, 1);
      expect(find.byType(SnackBar), findsNothing);
      if (change == 'replace comic') {
        final card = tester
            .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
        expect(card.title, '作品2');
        expect(card.isFavorited, isFalse);
        expect(card.favoriteBusy, isFalse);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('throwing ranking state read releases busy state for retry',
      (tester) async {
    var reads = 0;
    final writes = <bool>[];
    await pump(tester,
        comic: _comic(bookmarkable: false, stateKnown: false),
        loggedIn: () => true,
        loadBookmarkState: (_) async {
          reads++;
          if (reads == 1) throw StateError('offline');
          return Res(_info(marked: false));
        },
        write: (_, {required isAdding}) async {
          writes.add(isAdding);
          return Res(isAdding);
        });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('waterfall-favorite')));
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(writes, isEmpty);
    expect(
        tester
            .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
            .favoriteBusy,
        isFalse);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('waterfall-favorite')));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(writes, [true]);
    final card =
        tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
    expect(card.favoriteBusy, isFalse);
    expect(card.isFavorited, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resolved ranking state is reused for consecutive add and cancel',
      (tester) async {
    var reads = 0;
    final writes = <bool>[];
    await pump(tester,
        comic: _comic(bookmarkable: false, stateKnown: false),
        loggedIn: () => true,
        loadBookmarkState: (_) async {
          reads++;
          return Res(_info(marked: false));
        },
        write: (_, {required isAdding}) async {
          writes.add(isAdding);
          return Res(isAdding);
        });
    await tester.pumpAndSettle();
    for (final marked in [true, false, true]) {
      await tester.tap(find.byKey(const Key('waterfall-favorite')));
      await tester.pumpAndSettle();
      final card =
          tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
      expect(card.isFavorited, marked);
      expect(card.favoriteBusy, isFalse);
      expect(reads, 1);
    }
    expect(writes, [true, false, true]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ranking favorite shows progress and submits once on one tap',
      (tester) async {
    final pendingRead = Completer<Res<PixivBookmarkState>>();
    final pendingWrite = Completer<Res<bool>>();
    final writes = <bool>[];
    await pump(
      tester,
      comic: _comic(bookmarkable: false, stateKnown: false),
      loggedIn: () => true,
      loadBookmarkState: (_) => pendingRead.future,
      write: (_, {required isAdding}) {
        writes.add(isAdding);
        return pendingWrite.future;
      },
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('waterfall-favorite')));
    await tester.pump();
    expect(find.text('正在读取收藏状态…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.text('正在读取收藏状态…'), findsOneWidget);
    await tester.tap(find.byKey(const Key('waterfall-favorite')));
    expect(writes, isEmpty, reason: '收藏态读取期间不提前提交或重复提交');

    pendingRead.complete(Res(_info(marked: false)));
    await tester.pump();
    await tester.pump();
    expect(writes, [true], reason: '同一次点击完成状态读取与添加');
    expect(find.text('正在提交收藏…'), findsOneWidget);

    pendingWrite.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
            .isFavorited,
        isTrue);
    expect(find.byKey(const Key('waterfall-favorite-progress')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed unfollow preserves marked state and latest feedback',
      (tester) async {
    var attempts = 0;
    await pump(tester, comic: _comic(), write: (_, {required isAdding}) async {
      attempts++;
      return attempts == 1 ? Res(isAdding) : const Res.error('写入失败');
    });
    await tester.pumpAndSettle();
    tester
        .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
        .onToggleFavorite!();
    await tester.pumpAndSettle();
    tester
        .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
        .onToggleFavorite!();
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
            .isFavorited,
        isTrue);
    expect(find.textContaining('收藏失败：写入失败'), findsOneWidget);
  });

  testWidgets('login returns to refreshed data without automatically writing',
      (tester) async {
    var loggedIn = false, opens = 0, refreshed = 0, writes = 0;
    final login = Completer<void>();
    await pump(tester,
        loggedIn: () => loggedIn,
        manage: (_) {
          opens++;
          return login.future;
        },
        accountsChanged: () => refreshed++,
        write: (_, {required isAdding}) async {
          writes++;
          return Res(isAdding);
        });
    await tester.pumpAndSettle();
    final button = tester
        .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
        .onToggleFavorite!;
    button();
    button();
    await tester.pump();
    expect(opens, 1);
    expect(writes, 0);
    loggedIn = true;
    login.complete();
    await tester.pumpAndSettle();
    expect(refreshed, 1);
    expect(writes, 0);
  });

  testWidgets('changed account and refresh discard stale write results',
      (tester) async {
    var account = 'account-1';
    final pending = Completer<Res<bool>>();
    await pump(tester,
        account: () => account,
        write: (_, {required isAdding}) => pending.future);
    await tester.pumpAndSettle();
    tester
        .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
        .onToggleFavorite!();
    await tester.pump();
    account = 'account-2';
    bookmarks.reset();
    await tester.pump();
    pending.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
            .isFavorited,
        isFalse);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets(
      'refresh holds pending locks until they finish and uses new brief',
      (tester) async {
    final pending = Completer<Res<bool>>();
    var writes = 0;
    Future<Res<bool>> write(String _, {required bool isAdding}) {
      writes++;
      return pending.future;
    }

    await pump(tester, write: write);
    await tester.pumpAndSettle();
    tester
        .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
        .onToggleFavorite!();
    await tester.pump();
    bookmarks.reset();
    await pump(tester, comic: _comic(marked: true), write: write);
    tester
        .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
        .onToggleFavorite!();
    expect(writes, 1);
    pending.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
            .isFavorited,
        isTrue);
  });

  testWidgets('reused and disposed cards do not announce old operations',
      (tester) async {
    final old = Completer<Res<bool>>();
    await pump(tester, write: (_, {required isAdding}) => old.future);
    await tester.pumpAndSettle();
    tester
        .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
        .onToggleFavorite!();
    await tester.pump();
    await pump(tester, comic: _comic(id: '2'));
    old.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
            .isFavorited,
        isFalse);
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'refresh keeps confirmed hearts disabled until fresh data arrives',
      (tester) async {
    var writes = 0;
    Future<Res<bool>> write(String _, {required bool isAdding}) async {
      writes++;
      return Res(isAdding);
    }

    await pump(tester, write: write);
    await tester.pumpAndSettle();
    tester
        .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
        .onToggleFavorite!();
    await tester.pumpAndSettle();
    bookmarks.reset(preserveConfirmed: true);
    await pump(tester, write: write, actionsEnabled: false);
    await tester.pumpAndSettle();
    var card =
        tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
    expect(card.isFavorited, isTrue);
    expect(card.favoriteBusy, isFalse);
    expect(card.favoriteEnabled, isFalse);
    card.onToggleFavorite!();
    expect(writes, 1);
    bookmarks.reset();
    await pump(tester, comic: _comic(marked: false), write: write);
    await tester.pumpAndSettle();
    card = tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
    expect(card.isFavorited, isFalse);
    expect(card.favoriteBusy, isFalse);
  });

  testWidgets('missing capability hides heart; other sources stay conservative',
      (tester) async {
    await pump(tester, comic: _comic(bookmarkable: false, authorId: ''));
    await tester.pumpAndSettle();
    var card =
        tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
    expect(card.onToggleFavorite, isNull);
    expect(card.onAuthorTap, isNull);
    source = ComicSource.named(key: 'jm', name: 'JM');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
      width: 180,
      child: OnlineRecommendationCard(
          source: source,
          comic: const JmComicBrief(
              id: '2', title: 'JM作品', author: '作者', tags: [], coverUrl: ''),
          bookmarks: bookmarks,
          onAccountsChanged: () {}),
    ))));
    await tester.pumpAndSettle();
    card = tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
    expect(card.onToggleFavorite, isNull);
    expect(card.showAuthorAvatar, isTrue);
    expect(card.author, '作者');
    expect(card.width, isNull);
    expect(card.aspectRatio, 3 / 4);
  });

  for (final returned in [true, false, null]) {
    testWidgets(
        'detail return reads authority after a cross-frame feed refresh: $returned',
        (tester) async {
      source = ComicSource.named(
          key: 'pixiv',
          name: 'Pixiv',
          comicPageBuilder: (_) =>
              Scaffold(appBar: AppBar(), body: const Text('实际详情')));
      const account = 'account-99';
      var comic = _comic(stateKnown: false);
      bookmarks.synchronizeConfirmedState(
          account: account, comic: comic, state: _info(marked: true));
      final refreshDone = Completer<void>();
      var enabled = true;
      var reads = 0;
      late StateSetter rebuild;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return SizedBox(
            width: 180,
            child: OnlineRecommendationCard(
              source: source,
              comic: comic,
              bookmarks: bookmarks,
              accountIdentity: () => account,
              isLoggedIn: () => true,
              onAccountsChanged: () {},
              actionsEnabled: enabled,
              onDataRefresh: () {
                bookmarks.reset(preserveConfirmed: true);
                rebuild(() => enabled = false);
                return refreshDone.future;
              },
              loadBookmarkState: (_) async {
                reads++;
                return returned == null
                    ? const Res.error('offline')
                    : Res(_info(marked: returned));
              },
            ));
      }))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('作品1'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      var card =
          tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
      expect(card.favoriteBusy, isFalse);
      expect(card.favoriteEnabled, isFalse);
      expect(card.isFavorited, isTrue);
      expect(reads, 0);

      bookmarks.reset(preserveConfirmed: true);
      rebuild(() {
        comic = _comic(stateKnown: false);
        enabled = true;
      });
      refreshDone.complete();
      await tester.pumpAndSettle();
      card =
          tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
      expect(reads, 1, reason: '刷新暂时禁用动作不能取消详情返回的权威读态');
      expect(card.isFavorited, returned ?? true,
          reason: '明确取消必须更新；读取失败保留此前确认状态');
      expect(card.favoriteStateKnown, isTrue);
      expect(card.favoriteBusy, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  for (final invalidation in ['account', 'comic', 'dispose']) {
    testWidgets('late detail response ignores changed $invalidation',
        (tester) async {
      source = ComicSource.named(
          key: 'pixiv',
          name: 'Pixiv',
          comicPageBuilder: (_) =>
              Scaffold(appBar: AppBar(), body: const Text('实际详情')));
      var account = 'account-99';
      final pendingRead = Completer<Res<PixivBookmarkState>>();
      var reads = 0;
      await pump(tester,
          account: () => account,
          loggedIn: () => true,
          loadBookmarkState: (_) {
            reads++;
            return pendingRead.future;
          });
      await tester.pumpAndSettle();
      await tester.tap(find.text('作品1'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(reads, 1);
      if (invalidation == 'account') {
        account = 'account-100';
      } else if (invalidation == 'comic') {
        await pump(tester,
            comic: _comic(id: '2'),
            account: () => account,
            loggedIn: () => true);
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      pendingRead.complete(Res(_info(marked: true)));
      await tester.pumpAndSettle();
      expect(bookmarks.isBookmarked('account-99', _comic()), isFalse);
      expect(bookmarks.isBookmarked(account, _comic(id: '2')), isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('registered detail routing refreshes after returning',
      (tester) async {
    var refreshes = 0, stateReads = 0;
    source = ComicSource.named(
        key: 'pixiv',
        name: 'Pixiv',
        comicPageBuilder: (_) =>
            Scaffold(appBar: AppBar(), body: const Text('实际详情')));
    await pump(
      tester,
      comic: _comic(bookmarkable: false, stateKnown: false),
      loggedIn: () => true,
      loadBookmarkState: (_) async {
        stateReads++;
        return Res(_info(marked: true, bookmarkable: false));
      },
      refresh: () async {
        refreshes++;
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('作品1'));
    await tester.pumpAndSettle();
    expect(find.text('实际详情'), findsOneWidget);
    expect(refreshes, 0);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(refreshes, 1);
    expect(find.text('作品1'), findsOneWidget);
    expect(stateReads, 1);
    expect(
        tester
            .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
            .isFavorited,
        isTrue,
        reason: '榜单刷新不返回 bookmarkData，详情返回后必须保留账号确认态');
  });
}
