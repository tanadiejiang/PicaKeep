import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/pixiv_author_page_v2.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/pages/online_common/online_waterfall_card.dart';

const _work = PixivComicBrief(
  id: '123',
  title: '作品',
  cover: '',
  author: '画师',
  tags: ['猫', '风景'],
  authorId: '42',
  illustType: 0,
  pageCount: 3,
  width: 100,
  height: 150,
  bookmarkStateKnown: false,
  isBookmarkable: false,
  canLoadBookmarkState: true,
);

const _author = PixivAuthor(
  id: '42',
  name: '画师',
  avatar: '',
  comment: '',
  following: 0,
);

void main() {
  late List<ComicSource> previousSources;
  late String previousSettings;
  late ComicSource source;
  setUp(() {
    PixivBookmarkStateStore.shared.clear();
    previousSources = List.of(ComicSource.sources);
    previousSettings = appdata.settings[comicTileDisplayConfigSettingIndex];
    source = ComicSource.named(
      key: 'pixiv',
      name: 'Pixiv',
      data: {'userId': '99', 'token': 'fixture'},
      comicPageBuilder: (_) =>
          Scaffold(appBar: AppBar(), body: const Text('详情')),
    );
    ComicSource.sources
      ..clear()
      ..add(source);
    appdata.settings[comicTileDisplayConfigSettingIndex] = '{}';
  });
  tearDown(() {
    ComicSource.sources
      ..clear()
      ..addAll(previousSources);
    appdata.settings[comicTileDisplayConfigSettingIndex] = previousSettings;
  });

  PixivAuthorPageV2 page({
    RecommendationBookmarkController? bookmarks,
    Future<Res<PixivBookmarkState>> Function(String)? read,
    Future<Res<bool>> Function(String, {required bool isAdding})? write,
    bool Function()? loggedIn,
    String Function()? account,
    Future<void> Function(BuildContext)? accounts,
    Future<Res<List<PixivComicBrief>>> Function(String, int)? works,
  }) =>
      PixivAuthorPageV2(
        '42',
        bookmarks: bookmarks,
        loadAuthor: (_) async => const Res(_author),
        loadWorks: works ?? (_, __) async => const Res([_work], subData: 1),
        isLoggedIn: loggedIn ?? () => true,
        accountIdentity: account,
        manageAccounts: accounts,
        loadBookmarkState: read ??
            (_) async => const Res(
                PixivBookmarkState(isBookmarked: false, isBookmarkable: true)),
        writeBookmark: write ?? (_, {required isAdding}) async => Res(isAdding),
      );

  OnlineWaterfallCard card(WidgetTester tester) =>
      tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard).last);

  testWidgets('author adapter preserves session and fresh default tags',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: page()));
    await tester.pumpAndSettle();
    final adapter = tester.widget<OnlineRecommendationCard>(
        find.byType(OnlineRecommendationCard));
    expect(adapter.isAuthorPage, isTrue);
    expect(adapter.onOpenDetail, isNull);
    final session = adapter.detailSessionBuilder!();
    expect(session.scope, PixivDetailScope.author);
    expect(session.entries.map((entry) => entry.comicId), ['123']);
    session.dispose();
    expect(
        card(tester).tagConfig, WaterfallTagDisplayConfig.pixivAuthorDefaults);
    expect(card(tester).pageCount, 3);
    expect(card(tester).showAuthorAvatar, isFalse);
    expect(card(tester).author, isEmpty);
    expect(find.byKey(const Key('waterfall-avatar')), findsNothing);
  });

  testWidgets('author and recommendation share confirmed state and ownership',
      (tester) async {
    final bookmarks = RecommendationBookmarkController();
    addTearDown(bookmarks.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Row(children: [
        SizedBox(
          width: 170,
          child: Scaffold(
            body: OnlineRecommendationCard(
              source: source,
              comic: _work.copyWith(
                  bookmarkStateKnown: true, isBookmarkable: true),
              bookmarks: bookmarks,
              onAccountsChanged: () {},
            ),
          ),
        ),
        Expanded(child: page(bookmarks: bookmarks)),
      ]),
    ));
    await tester.pumpAndSettle();
    card(tester).onToggleFavorite!();
    await tester.pumpAndSettle();
    for (final value in tester
        .widgetList<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))) {
      expect(value.isFavorited, isTrue);
      expect(value.favoriteBusy, isFalse);
    }
    await tester.pumpWidget(const SizedBox());
    void listener() {}
    expect(() => bookmarks.addListener(listener), returnsNormally,
        reason: '作者页不能dispose外部controller');
    bookmarks.removeListener(listener);
  });

  testWidgets('author detail return reads and synchronizes platform bookmark',
      (tester) async {
    var reads = 0;
    await tester.pumpWidget(MaterialApp(
      home: page(read: (_) async {
        reads++;
        return const Res(
            PixivBookmarkState(isBookmarked: true, isBookmarkable: true));
      }),
    ));
    await tester.pumpAndSettle();
    card(tester).onTap();
    await tester.pumpAndSettle();
    expect(find.text('详情'), findsOneWidget);
    expect(reads, 1, reason: '可见的未知作品先读取收藏态');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(reads, 2, reason: '详情返回仍读取最新权威状态');
    expect(card(tester).isFavorited, isTrue);
  });

  testWidgets('author login refreshes works and never submits original action',
      (tester) async {
    var loggedIn = false, loads = 0, writes = 0, opens = 0;
    await tester.pumpWidget(MaterialApp(
      home: page(
        loggedIn: () => loggedIn,
        accounts: (_) async {
          opens++;
          loggedIn = true;
        },
        works: (_, __) async {
          loads++;
          return const Res([_work], subData: 1);
        },
        write: (_, {required isAdding}) async {
          writes++;
          return Res(isAdding);
        },
      ),
    ));
    await tester.pumpAndSettle();
    card(tester).onToggleFavorite!();
    await tester.pumpAndSettle();
    expect(opens, 1);
    expect(loads, 2);
    expect(writes, 0);
    expect(card(tester).favoriteBusy, isFalse);
  });

  for (final change in ['refresh', 'dispose', 'account']) {
    testWidgets('pending author state read cannot write after $change',
        (tester) async {
      final pending = Completer<Res<PixivBookmarkState>>();
      var writes = 0;
      var account = 'a';
      await tester.pumpWidget(MaterialApp(
        home: page(
          account: () => account,
          read: (_) => pending.future,
          write: (_, {required isAdding}) async {
            writes++;
            return Res(isAdding);
          },
        ),
      ));
      await tester.pumpAndSettle();
      card(tester).onToggleFavorite!();
      await tester.pump();
      expect(card(tester).favoriteBusy, isTrue);
      switch (change) {
        case 'refresh':
          await tester.tap(find.byTooltip('刷新作者页'));
          await tester.pump();
        case 'dispose':
          await tester.pumpWidget(const SizedBox());
        case 'account':
          account = 'b';
      }
      pending.complete(const Res(
          PixivBookmarkState(isBookmarked: false, isBookmarkable: true)));
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(tester.takeException(), isNull);
    });
  }
}
