import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/network/jm_network/jm_models.dart';
import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';
import 'package:picakeep/network/res.dart';
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
  }) =>
      tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(
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
        ),
      ))));

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
            comic: _comic(),
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
    expect(find.text('操作失败：offline'), findsOneWidget);
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
    expect(
        find.byKey(const Key('waterfall-favorite-progress')), findsOneWidget);
    await tester.tap(find.byKey(const Key('waterfall-favorite')));
    expect(writes, isEmpty, reason: '收藏态读取期间不提前提交或重复提交');

    pendingRead.complete(Res(_info(marked: false)));
    await tester.pump();
    await tester.pump();
    expect(writes, [true], reason: '同一次点击完成状态读取与添加');
    expect(
        find.byKey(const Key('waterfall-favorite-progress')), findsOneWidget);

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
    expect(find.text('操作失败：写入失败'), findsOneWidget);
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
    expect(card.favoriteBusy, isTrue);
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
