import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/foundation/explore/explore_bindings.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_provider.dart';
import 'package:picakeep/foundation/explore/explore_registry.dart';
import 'package:picakeep/foundation/explore/explore_selection_state.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/pixiv_network/pixiv_models.dart';
import 'package:picakeep/pages/explore/explore_page.dart';
import 'package:picakeep/pages/explore/explore_route_scope.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';
import 'package:picakeep/pages/online_common/online_waterfall_card.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationCachePath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

BaseComic _comic(String id,
    {bool blocked = false,
    String sourceKey = 'pixiv',
    String titlePrefix = ''}) {
  final title = '${blocked ? "屏蔽词 " : ""}$titlePrefix' '作品$id';
  if (sourceKey == 'pixiv') {
    return PixivComicBrief(
      id: id,
      title: title,
      author: '作者',
      tags: const ['标签'],
      cover: '',
      illustType: pixivIllustTypeIllust,
      pageCount: 1,
      width: 600,
      height: 900,
    );
  }
  return CustomComic(title, '作者', '', id, const ['标签'], '', sourceKey);
}

const _listSourceKeys = [
  'jm',
  'picacg',
  'ehentai',
  'nhentai',
  'komiic',
  'unknown',
];

const _pixivRankingOptions = [
  ExploreOption(id: 'day', label: '日榜'),
  ExploreOption(id: 'week', label: '周榜'),
];

class _Provider implements ExploreProvider {
  _Provider({
    this.sourceKey = 'pixiv',
    this.titlePrefix = '',
    this.rankingOptions = const [],
  }) {
    descriptor = ExploreSourceDescriptor(
      sourceKey: sourceKey,
      name: sourceKey == 'pixiv' ? '测试Pixiv' : '测试$sourceKey',
      requiresLogin: false,
      entries: [
        ExploreEntry(
            id: recommendId, label: '主页', kind: ExploreSectionKind.recommend),
        ExploreEntry(
          id: rankingId,
          label: '榜单',
          kind: ExploreSectionKind.ranking,
          options: rankingOptions,
          defaultOptionId:
              rankingOptions.isEmpty ? null : rankingOptions.first.id,
        )
      ],
    );
    sections = [
      ExploreSection(
          id: 's',
          title: '推荐区',
          entryId: recommendId,
          items: List.generate(12, (i) => comic('$i')))
    ];
    first = [comic('0'), comic('1')];
    next = [comic('2')];
  }

  final String sourceKey;
  final String titlePrefix;
  final List<ExploreOption> rankingOptions;
  String get recommendId => '$sourceKey.home';
  String get rankingId => '$sourceKey.ranking';
  BaseComic comic(String id) =>
      _comic(id, sourceKey: sourceKey, titlePrefix: titlePrefix);
  bool paged = false;
  int overviews = 0, lists = 0;
  Completer<ExploreResult<ExploreOverview>>? pendingOverview;
  Completer<ExploreResult<ExploreComicPage>>? pendingComics;
  Completer<ExploreResult<ExploreComicPage>>? pendingContinuation;
  final overviewRequests = <ExploreRequest>[];
  final requests = <ExploreRequest>[];
  late List<ExploreSection> sections;
  late List<BaseComic> first;
  late List<BaseComic> next;
  final rankingFirst = <String, List<BaseComic>>{};
  final rankingNext = <String, List<BaseComic>>{};
  @override
  late final ExploreSourceDescriptor descriptor;
  @override
  bool get isLoggedIn => true;
  @override
  String get contextFingerprint => '$sourceKey-fixture-account';
  @override
  Future<ExploreResult<ExploreOverview>> loadOverview(ExploreRequest r) async {
    overviews++;
    overviewRequests.add(r);
    if (!paged && pendingOverview != null) return pendingOverview!.future;
    return paged
        ? const ExploreFailure(ExploreError(ExploreErrorCode.unsupported, '分页'))
        : ExploreSuccess(ExploreOverview(
            sourceKey: sourceKey, entryId: r.entryId, sections: sections));
  }

  @override
  Future<ExploreResult<ExploreComicPage>> loadComics(ExploreRequest r) async {
    lists++;
    requests.add(r);
    if (r.continuation == null && pendingComics != null) {
      return pendingComics!.future;
    }
    if (r.continuation != null && pendingContinuation != null) {
      return pendingContinuation!.future;
    }
    final optionId = r.options.first;
    final isRanking = r.entryId == rankingId;
    return ExploreSuccess(ExploreComicPage(
        sourceKey: sourceKey,
        entryId: r.entryId,
        items: isRanking
            ? (r.continuation == null
                ? rankingFirst[optionId] ?? first
                : rankingNext[optionId] ?? next)
            : r.continuation == null
                ? first
                : next,
        nextToken: r.continuation != null
            ? null
            : r.entryId == recommendId
                ? 'next'
                : isRanking && rankingOptions.isNotEmpty
                    ? 'rank-$optionId-next'
                    : null));
  }

  @override
  Future<ExploreResult<ExploreDirectory>> loadDirectory(
          ExploreRequest r) async =>
      const ExploreFailure(ExploreError(ExploreErrorCode.unsupported, '无目录'));
}

void _bindProviders(Iterable<_Provider> providers) {
  final registry = ExploreRegistry();
  ComicSource.sources.clear();
  for (final provider in providers) {
    registry.register(provider);
    ComicSource.sources.add(ComicSource.named(
        key: provider.sourceKey,
        name: provider.descriptor.name,
        data: {'token': 'fixture'}));
  }
  ExploreBindings.debugSetInstance(ExploreBindings.forTesting(registry));
}

void main() {
  late Directory temp;
  late List<ComicSource> sources;
  late List<String> settings, keywords;
  final paths = PathProviderPlatform.instance;
  late _Provider provider;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('pk-recommend-waterfall-');
    PathProviderPlatform.instance = _Paths(temp.path);
    await App.init(dataPathOverride: temp.path);
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = paths;
    await temp.delete(recursive: true);
  });
  setUp(() {
    sources = List.of(ComicSource.sources);
    settings = List.of(appdata.settings);
    keywords = List.of(appdata.blockingKeyword);
    appdata.blockingKeyword = [];
    appdata.settings[83] = '0';
    appdata.settings[illustWaterfallColumnsSettingIndex] = '2';
    appdata.settings[comicTileDisplayConfigSettingIndex] = '';
    appdata.settings[exploreSelectionSettingIndex] = '{}';
    provider = _Provider();
    _bindProviders([provider]);
  });
  tearDown(() {
    ExploreBindings.debugSetInstance(null);
    ComicSource.sources
      ..clear()
      ..addAll(sources);
    appdata.settings
      ..clear()
      ..addAll(settings);
    appdata.blockingKeyword = keywords;
  });

  Future<void> selectSource(WidgetTester tester, _Provider source) async {
    final tab = find.widgetWithText(Tab, source.descriptor.name);
    await tester.ensureVisible(tab);
    await tester.tap(tab);
    await tester.pumpAndSettle();
  }

  Future<void> selectRankingOption(
      WidgetTester tester, ExploreOption option) async {
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('explore-entry-option-${option.id}')));
    await tester.pumpAndSettle();
  }

  /// 「推荐 / 榜单 / 分类」已从 `ChoiceChip` 换成自绘胶囊（与右侧入口同一套），
  /// 按 `explore-tab-<文案>` 定位 —— **只改"怎么定位控件"**，断言语义未动。
  ///
  /// ⚠️ 顶栏是**滚动驱动**的浮层：内容停在中间时它已经缩小淡出并忽略指针，
  /// 所以定位它之前要先让内容回顶（真机里这一步由用户自己滚回顶部完成）；
  /// 点完再把各列表的滚动位置**原样还原** —— 多个用例要断言"切页签后各自的
  /// 滚动位置被保留"，那是**产品**行为，不该被测试的定位动作改掉。
  Future<void> selectTab(WidgetTester tester, String label) async {
    final target = find.byKey(ValueKey('explore-tab-$label'));
    final saved = <ScrollController, double>{};
    for (final element in find.byType(Scrollable).evaluate()) {
      final controller = (element.widget as Scrollable).controller;
      if (controller != null && controller.hasClients) {
        saved[controller] = controller.offset;
      }
    }
    for (final controller in saved.keys) {
      controller.jumpTo(0);
    }
    await tester.pumpAndSettle();
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
    for (final entry in saved.entries) {
      if (entry.key.hasClients && entry.key.offset != entry.value) {
        entry.key.jumpTo(entry.value);
      }
    }
    await tester.pumpAndSettle();
  }

  Future<void> pump(WidgetTester tester, {_Provider? initialSource}) async {
    tester.view.physicalSize = const Size(430, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final observer = NaviObserver();
    await tester.pumpWidget(MaterialApp(
        navigatorObservers: [observer],
        home: ExploreRouteScope(
            observer: observer, child: const Scaffold(body: ExplorePage()))));
    await tester.pumpAndSettle();
    if (initialSource != null) await selectSource(tester, initialSource);
    await selectTab(tester, '推荐');
    await tester.pumpAndSettle();
  }

  ScrollController listScroll(WidgetTester tester) {
    expect(find.byType(ListView), findsOneWidget);
    return tester.widget<ListView>(find.byType(ListView)).controller!;
  }

  void expectListLayout(WidgetTester tester, String sourceKey) {
    expect(find.byType(OnlineComicListItem), findsWidgets);
    expect(find.byType(SliverMasonryGrid), findsNothing);
    expect(find.byType(OnlineRecommendationCard), findsNothing);
    expect(find.byType(OnlineWaterfallCard), findsNothing);
    expect(find.byKey(const Key('explore-recommend-scroll')), findsNothing);
    for (final item in tester
        .widgetList<OnlineComicListItem>(find.byType(OnlineComicListItem))) {
      expect(item.source.key, sourceKey);
    }
    expect(tester.takeException(), isNull);
  }

  testWidgets(
      'overview sections stay isolated and blocked hiding creates no holes',
      (tester) async {
    provider.sections = [
      ExploreSection(
          id: 's',
          title: '成功区',
          entryId: 'pixiv.home',
          items: [_comic('0', blocked: true), _comic('1'), _comic('2')]),
      const ExploreSection(
          id: 'bad',
          title: '失败区',
          entryId: 'pixiv.home',
          error: ExploreError(ExploreErrorCode.network, '分区错误')),
    ];
    appdata.blockingKeyword = ['屏蔽词'];
    appdata.settings[83] = '1';
    await pump(tester);
    expect(find.byType(OnlineRecommendationCard), findsNWidgets(2));
    for (final card in tester.widgetList<OnlineRecommendationCard>(
        find.byType(OnlineRecommendationCard))) {
      expect(card.source.key, 'pixiv');
      expect(card.comic, isA<PixivComicBrief>());
    }
    expect(find.text('屏蔽词 作品0'), findsNothing);
    final masonry =
        tester.widget<SliverMasonryGrid>(find.byType(SliverMasonryGrid));
    expect(masonry.delegate.estimatedChildCount, 2);
    await tester.drag(find.byKey(const Key('explore-recommend-scroll')),
        const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(find.text('失败区'), findsOneWidget);
    expect(find.text('分区错误'), findsOneWidget);
    appdata.settings[83] = '0';
    App.notifyDisplaySettingsChanged();
    await tester.pumpAndSettle();
    expect(find.text('已屏蔽：屏蔽词'), findsOneWidget);
    expect(provider.overviews, 1);
  });

  testWidgets(
      'paged recommendation and Pixiv ranking retain waterfall continuation',
      (tester) async {
    provider.paged = true;
    await pump(tester);
    expect(find.byType(SliverMasonryGrid), findsOneWidget);
    expect(find.byType(OnlineRecommendationCard), findsNWidgets(2));
    await tester.tap(find.widgetWithText(OutlinedButton, '加载更多'));
    await tester.pumpAndSettle();
    expect(provider.requests.last.continuation, 'next');
    expect(find.text('作品2'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    final reads = provider.lists;
    await selectTab(tester, '榜单');
    await tester.pumpAndSettle();
    expect(find.byType(SliverMasonryGrid), findsOneWidget);
    expect(find.byType(OnlineComicListItem), findsNothing);
    expect(find.byType(OnlineRecommendationCard), findsNWidgets(2));
    expect(provider.requests.last.entryId, provider.rankingId);
    await selectTab(tester, '推荐');
    await tester.pumpAndSettle();
    expect(provider.lists, reads + 1);
    expect(find.text('作品2'), findsOneWidget);
  });

  testWidgets(
      'Pixiv ranking options, continuation and recommendation switches keep isolated caches',
      (tester) async {
    provider = _Provider(rankingOptions: _pixivRankingOptions)..paged = true;
    provider.first = List.generate(12, (i) => provider.comic('home-$i'));
    provider.rankingFirst['day'] =
        List.generate(4, (i) => provider.comic('day-$i'));
    provider.rankingNext['day'] = [provider.comic('day-next')];
    provider.rankingFirst['week'] = [
      provider.comic('week-0'),
      provider.comic('week-1'),
    ];
    _bindProviders([provider]);
    await pump(tester);

    final recommendationScroll = tester
        .widget<CustomScrollView>(
            find.byKey(const Key('explore-recommend-scroll')))
        .controller!;
    recommendationScroll.jumpTo(100);
    await tester.pumpAndSettle();
    final recommendationOffset = recommendationScroll.offset;
    final recommendationRequestCount = provider.requests.length;

    await selectTab(tester, '榜单');
    await tester.pumpAndSettle();
    expect(find.byType(SliverMasonryGrid), findsOneWidget);
    expect(find.byType(OnlineComicListItem), findsNothing);
    expect(find.text('作品day-0'), findsOneWidget);
    final rankingScroll = tester
        .widget<CustomScrollView>(
            find.byKey(const Key('explore-recommend-scroll')))
        .controller!;
    expect(rankingScroll, isNot(same(recommendationScroll)));
    final firstPageRequest = provider.requests.last;
    expect(provider.requests.length, recommendationRequestCount + 1);
    expect(firstPageRequest.entryId, provider.rankingId);
    expect(firstPageRequest.sourceKey, 'pixiv');
    expect(firstPageRequest.options.first, 'day');
    expect(firstPageRequest.continuation, isNull);
    expect(find.text('加载更多'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('作品day-next'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    final continuationRequest = provider.requests.last;
    expect(continuationRequest.entryId, provider.rankingId);
    expect(continuationRequest.options.first, 'day');
    expect(continuationRequest.continuation, 'rank-day-next');
    expect(continuationRequest.sessionId, firstPageRequest.sessionId);
    final rankingOffset = rankingScroll.offset;
    final readsAfterContinuation = provider.requests.length;

    await selectTab(tester, '推荐');
    await tester.pumpAndSettle();
    expect(find.byType(SliverMasonryGrid), findsOneWidget);
    expect(find.text('作品home-0'), findsOneWidget);
    expect(
        tester
            .widget<CustomScrollView>(
                find.byKey(const Key('explore-recommend-scroll')))
            .controller,
        same(recommendationScroll));
    expect(recommendationScroll.offset, closeTo(recommendationOffset, .01));
    expect(provider.requests.length, readsAfterContinuation);

    await selectTab(tester, '榜单');
    await tester.pumpAndSettle();
    expect(find.text('作品day-next'), findsOneWidget);
    expect(
        tester
            .widget<CustomScrollView>(
                find.byKey(const Key('explore-recommend-scroll')))
            .controller,
        same(rankingScroll));
    expect(rankingScroll.offset, closeTo(rankingOffset, .01));
    expect(provider.requests.length, readsAfterContinuation);

    await selectRankingOption(tester, _pixivRankingOptions[1]);
    expect(find.text('作品week-0'), findsOneWidget);
    expect(find.text('作品day-0'), findsNothing);
    final weekRequest = provider.requests.last;
    expect(weekRequest.entryId, provider.rankingId);
    expect(weekRequest.options.first, 'week');
    expect(weekRequest.continuation, isNull);
    expect(weekRequest.sessionId, isNot(firstPageRequest.sessionId));
    expect(provider.requests.length, readsAfterContinuation + 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Pixiv ranking display changes update columns and tags without network reload',
      (tester) async {
    provider = _Provider(rankingOptions: _pixivRankingOptions);
    provider.rankingFirst['day'] =
        List.generate(12, (i) => provider.comic('day-$i'));
    _bindProviders([provider]);
    await pump(tester);
    await selectTab(tester, '榜单');
    await tester.pumpAndSettle();

    final scroll = tester
        .widget<CustomScrollView>(
            find.byKey(const Key('explore-recommend-scroll')))
        .controller;
    final reads = (provider.overviews, provider.lists);
    final requests = List<ExploreRequest>.of(provider.requests);
    expect(
        tester
            .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard).first)
            .tagConfig
            .showTags,
        isTrue);

    appdata.settings[illustWaterfallColumnsSettingIndex] = '3';
    appdata.settings[comicTileDisplayConfigSettingIndex] =
        '{"waterfall":{"recommend":{"showTags":false,"tagRows":1}}}';
    App.notifyDisplaySettingsChanged();
    await tester.pumpAndSettle();

    final masonry =
        tester.widget<SliverMasonryGrid>(find.byType(SliverMasonryGrid));
    final layout =
        masonry.gridDelegate as SliverSimpleGridDelegateWithFixedCrossAxisCount;
    expect(layout.crossAxisCount, 3);
    expect(
        tester
            .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard).first)
            .tagConfig
            .showTags,
        isFalse);
    expect(
        tester
            .widget<CustomScrollView>(
                find.byKey(const Key('explore-recommend-scroll')))
            .controller,
        same(scroll));
    expect((provider.overviews, provider.lists), reads);
    expect(provider.requests, requests);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Pixiv ranking detail return restores deep scroll and loaded pages in a fresh session',
      (tester) async {
    provider = _Provider(rankingOptions: _pixivRankingOptions)..paged = true;
    provider.rankingFirst['day'] =
        List.generate(6, (i) => provider.comic('day-$i'));
    provider.rankingNext['day'] =
        List.generate(58, (i) => provider.comic('day-${i + 6}'));
    _bindProviders([provider]);
    ComicSource.sources[0] = ComicSource.named(
        key: 'pixiv',
        name: '测试Pixiv',
        data: {'token': 'fixture'},
        comicPageBuilder: (_) =>
            Scaffold(appBar: AppBar(), body: const Text('榜单详情')));
    await pump(tester);
    await selectTab(tester, '榜单');
    await tester.pumpAndSettle();

    final scroll = tester
        .widget<CustomScrollView>(
            find.byKey(const Key('explore-recommend-scroll')))
        .controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(provider.requests.where((r) => r.entryId == provider.rankingId),
        hasLength(2));
    scroll.jumpTo(4000);
    await tester.pumpAndSettle();
    final offset = scroll.offset;
    final oldSession = provider.requests
        .lastWhere((r) => r.entryId == provider.rankingId)
        .sessionId;
    final visibleTitle = find
        .descendant(
          of: find.byType(OnlineRecommendationCard),
          matching: find.byWidgetPredicate((widget) =>
              widget is Text && (widget.data?.startsWith('作品day-') ?? false)),
        )
        .hitTestable()
        .first;
    await tester.tap(visibleTitle);
    await tester.pumpAndSettle();
    expect(find.text('榜单详情'), findsOneWidget);

    provider.pendingComics = Completer<ExploreResult<ExploreComicPage>>();
    provider.pendingContinuation = Completer<ExploreResult<ExploreComicPage>>();
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('explore-recommend-scroll')), findsOneWidget);
    expect(scroll.offset, closeTo(offset, .01));
    final rankingRequests = provider.requests
        .where((r) => r.entryId == provider.rankingId)
        .toList();
    expect(rankingRequests, hasLength(3));
    expect(rankingRequests.last.options.first, 'day');
    expect(rankingRequests.last.continuation, isNull);
    expect(rankingRequests.last.sessionId, isNot(oldSession));

    provider.pendingComics!.complete(ExploreSuccess(ExploreComicPage(
        sourceKey: 'pixiv',
        entryId: provider.rankingId,
        items: provider.rankingFirst['day']!,
        nextToken: 'fresh-rank-next')));
    await tester.pump();
    final restoredContinuation = provider.requests.last;
    expect(restoredContinuation.entryId, provider.rankingId);
    expect(restoredContinuation.options.first, 'day');
    expect(restoredContinuation.continuation, 'fresh-rank-next');
    expect(restoredContinuation.sessionId, rankingRequests.last.sessionId);
    expect(scroll.offset, closeTo(offset, .01));
    provider.pendingContinuation!.complete(ExploreSuccess(ExploreComicPage(
        sourceKey: 'pixiv',
        entryId: provider.rankingId,
        items: provider.rankingNext['day']!)));
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(offset, .01));
    expect(provider.requests.last.sessionId, rankingRequests.last.sessionId);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('作品day-63'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'display changes update columns and tags without requesting again',
      (tester) async {
    await pump(tester);
    final scroll = tester
        .widget<CustomScrollView>(
            find.byKey(const Key('explore-recommend-scroll')))
        .controller;
    expect(
        tester
            .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard).first)
            .tagConfig
            .showTags,
        isTrue);
    final reads = provider.overviews;
    appdata.settings[illustWaterfallColumnsSettingIndex] = '3';
    appdata.settings[comicTileDisplayConfigSettingIndex] =
        '{"waterfall":{"recommend":{"showTags":false,"tagRows":1}}}';
    App.notifyDisplaySettingsChanged();
    await tester.pumpAndSettle();
    final masonry =
        tester.widget<SliverMasonryGrid>(find.byType(SliverMasonryGrid));
    final layout =
        masonry.gridDelegate as SliverSimpleGridDelegateWithFixedCrossAxisCount;
    expect(layout.crossAxisCount, 3);
    expect(
        tester
            .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard).first)
            .tagConfig
            .showTags,
        isFalse);
    expect(provider.overviews, reads);
    expect(
        tester
            .widget<CustomScrollView>(
                find.byKey(const Key('explore-recommend-scroll')))
            .controller,
        same(scroll));
    expect(tester.takeException(), isNull);
  });

  for (final paged in [false, true]) {
    testWidgets(
        '${paged ? 'paged' : 'overview'} detail return refresh keeps deep scroll with the real route observer',
        (tester) async {
      provider.paged = paged;
      provider.first = List.generate(64, (i) => _comic('$i'));
      provider.sections = [
        ExploreSection(
            id: 's',
            title: '推荐区',
            entryId: 'pixiv.home',
            items: List.generate(64, (i) => _comic('$i')))
      ];
      ComicSource.sources[0] = ComicSource.named(
          key: 'pixiv',
          name: '测试Pixiv',
          data: {'token': 'fixture'},
          comicPageBuilder: (_) =>
              Scaffold(appBar: AppBar(), body: const Text('实际详情')));
      await pump(tester);
      final scroll = tester
          .widget<CustomScrollView>(
              find.byKey(const Key('explore-recommend-scroll')))
          .controller!;
      scroll.jumpTo(1200);
      await tester.pumpAndSettle();
      final offset = scroll.offset;
      final visibleTitle = find
          .descendant(
            of: find.byType(OnlineRecommendationCard),
            matching: find.byWidgetPredicate((widget) =>
                widget is Text && (widget.data?.startsWith('作品') ?? false)),
          )
          .hitTestable()
          .first;
      await tester.tap(visibleTitle);
      await tester.pumpAndSettle();
      expect(find.text('实际详情'), findsOneWidget);
      provider.pendingOverview = Completer<ExploreResult<ExploreOverview>>();
      provider.pendingComics = Completer<ExploreResult<ExploreComicPage>>();
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('explore-recommend-scroll')), findsOneWidget);
      expect(scroll.offset, closeTo(offset, .01));
      // The observer performs a context check; the card performs exactly one
      // authoritative feed refresh for bookmark changes made in the detail.
      expect(provider.overviews, 2);
      if (paged) {
        expect(provider.lists, 2);
        provider.pendingComics!.complete(ExploreSuccess(ExploreComicPage(
            sourceKey: 'pixiv',
            entryId: 'pixiv.home',
            items: provider.first,
            nextToken: 'next')));
      } else {
        provider.pendingOverview!.complete(ExploreSuccess(ExploreOverview(
            sourceKey: 'pixiv',
            entryId: 'pixiv.home',
            sections: provider.sections)));
      }
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(offset, .01));
      expect(provider.overviews, 2);
      expect(tester.takeException(), isNull);
    });
  }

  for (final fail in [false, true]) {
    testWidgets(
        'two loaded pages ${fail ? 'keep old content on refresh failure' : 'restore with a fresh session'} at a deep offset',
        (tester) async {
      provider.paged = true;
      provider.first = List.generate(6, (i) => _comic('$i'));
      provider.next = List.generate(58, (i) => _comic('${i + 6}'));
      ComicSource.sources[0] = ComicSource.named(
          key: 'pixiv',
          name: '测试Pixiv',
          data: {'token': 'fixture'},
          comicPageBuilder: (_) =>
              Scaffold(appBar: AppBar(), body: const Text('实际详情')));
      await pump(tester);
      final scroll = tester
          .widget<CustomScrollView>(
              find.byKey(const Key('explore-recommend-scroll')))
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(provider.lists, 2);
      final oldSession = provider.requests.first.sessionId;
      scroll.jumpTo(4000);
      await tester.pumpAndSettle();
      final offset = scroll.offset;
      final visibleTitle = find
          .descendant(
            of: find.byType(OnlineRecommendationCard),
            matching: find.byWidgetPredicate((widget) =>
                widget is Text && (widget.data?.startsWith('作品') ?? false)),
          )
          .hitTestable()
          .first;
      await tester.tap(visibleTitle);
      await tester.pumpAndSettle();
      provider.pendingComics = Completer<ExploreResult<ExploreComicPage>>();
      provider.pendingContinuation =
          Completer<ExploreResult<ExploreComicPage>>();
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(scroll.offset, closeTo(offset, .01));
      expect(provider.lists, 3);
      provider.pendingComics!.complete(ExploreSuccess(ExploreComicPage(
          sourceKey: 'pixiv',
          entryId: 'pixiv.home',
          items: provider.first,
          nextToken: 'fresh-next')));
      await tester.pump();
      expect(provider.lists, 4);
      expect(provider.requests.last.continuation, 'fresh-next');
      expect(provider.requests.last.sessionId, isNot(oldSession));
      expect(scroll.offset, closeTo(offset, .01));
      provider.pendingContinuation!.complete(fail
          ? const ExploreFailure(
              ExploreError(ExploreErrorCode.network, '第二页暂时不可用'))
          : ExploreSuccess(ExploreComicPage(
              sourceKey: 'pixiv',
              entryId: 'pixiv.home',
              items: provider.next)));
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(offset, .01));
      expect(provider.lists, 4);
      if (fail) expect(find.text('刷新失败：第二页暂时不可用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final sourceKey in _listSourceKeys) {
    for (final paged in [false, true]) {
      testWidgets(
          '$sourceKey ${paged ? 'paged' : 'overview'} recommendations and ranking keep the list layout through display changes',
          (tester) async {
        provider = _Provider(sourceKey: sourceKey)..paged = paged;
        provider.sections = [
          ExploreSection(
              id: 's',
              title: '推荐区',
              entryId: provider.recommendId,
              items: provider.first)
        ];
        _bindProviders([provider]);
        await pump(tester);
        expectListLayout(tester, sourceKey);
        expect(find.byType(OnlineComicListItem), findsNWidgets(2));
        final scroll = listScroll(tester);
        final overviewReads = provider.overviews;
        final listReads = provider.lists;

        appdata.settings[illustWaterfallColumnsSettingIndex] = '3';
        appdata.settings[comicTileDisplayConfigSettingIndex] =
            '{"waterfall":{"recommend":{"showTags":false,"tagRows":1}}}';
        App.notifyDisplaySettingsChanged();
        await tester.pumpAndSettle();
        expectListLayout(tester, sourceKey);
        expect(listScroll(tester), same(scroll));
        expect(provider.overviews, overviewReads);
        expect(provider.lists, listReads);

        await selectTab(tester, '榜单');
        await tester.pumpAndSettle();
        expectListLayout(tester, sourceKey);
        expect(find.byType(OnlineComicListItem), findsNWidgets(2));
        expect(provider.requests.last.entryId, provider.rankingId);

        await selectTab(tester, '推荐');
        await tester.pumpAndSettle();
        expectListLayout(tester, sourceKey);
        expect(listScroll(tester), same(scroll));
        expect(provider.overviews, overviewReads);
        expect(provider.lists, listReads + 1);
        expect(
            provider.overviewRequests.every((r) =>
                r.sourceKey == sourceKey && r.entryId == provider.recommendId),
            isTrue);
        expect(
            provider.requests.every((r) => r.sourceKey == sourceKey), isTrue);
      });
    }
  }

  for (final paged in [false, true]) {
    testWidgets(
        '${paged ? 'paged' : 'overview'} source switches isolate Pixiv waterfall, list caches, scroll and requests',
        (tester) async {
      provider = _Provider(titlePrefix: 'pixiv-')..paged = paged;
      final listProviders = [
        for (final key in _listSourceKeys)
          _Provider(sourceKey: key, titlePrefix: '$key-')..paged = paged
      ];
      final providers = [provider, ...listProviders];
      for (final source in providers) {
        source.first = List.generate(64, (i) => source.comic('$i'));
        source.sections = [
          ExploreSection(
              id: 's',
              title: '推荐区',
              entryId: source.recommendId,
              items: source.first)
        ];
      }
      _bindProviders(providers);
      await pump(tester, initialSource: provider);
      final pixivScroll = tester
          .widget<CustomScrollView>(
              find.byKey(const Key('explore-recommend-scroll')))
          .controller!;
      pixivScroll.jumpTo(900);
      await tester.pumpAndSettle();
      final pixivOffset = pixivScroll.offset;
      final pixivReads = (provider.overviews, provider.lists);
      final listScrolls = <ScrollController>[];

      void expectPixivCache() {
        expect(find.byType(SliverMasonryGrid), findsOneWidget);
        expect(find.byType(OnlineComicListItem), findsNothing);
        for (final card in tester.widgetList<OnlineRecommendationCard>(
            find.byType(OnlineRecommendationCard))) {
          expect(card.source.key, 'pixiv');
          expect(card.comic, isA<PixivComicBrief>());
          expect(card.comic.title, startsWith('pixiv-作品'));
        }
        expect(
            tester
                .widget<CustomScrollView>(
                    find.byKey(const Key('explore-recommend-scroll')))
                .controller,
            same(pixivScroll));
        expect(pixivScroll.offset, closeTo(pixivOffset, .01));
        expect((provider.overviews, provider.lists), pixivReads);
      }

      for (var i = 0; i < listProviders.length; i++) {
        final source = listProviders[i];
        await selectSource(tester, source);
        expectListLayout(tester, source.sourceKey);
        final scroll = listScroll(tester);
        expect(scroll, isNot(same(pixivScroll)));
        expect(listScrolls, isNot(contains(same(scroll))));
        listScrolls.add(scroll);
        scroll.jumpTo(300.0 + i * 100);
        await tester.pumpAndSettle();
        final offset = scroll.offset;
        final reads = (source.overviews, source.lists);
        // Replacing the provider's future response must not replace a visited
        // source's cached list when the user changes tabs.
        source.first = [source.comic('fresh')];
        source.sections = [
          ExploreSection(
              id: 'fresh',
              title: '新响应',
              entryId: source.recommendId,
              items: source.first)
        ];

        await selectSource(tester, provider);
        expectPixivCache();
        expect((source.overviews, source.lists), reads);
        await selectSource(tester, source);
        expectListLayout(tester, source.sourceKey);
        expect(listScroll(tester), same(scroll));
        expect(scroll.offset, closeTo(offset, .01));
        expect((source.overviews, source.lists), reads);
        for (final item in tester.widgetList<OnlineComicListItem>(
            find.byType(OnlineComicListItem))) {
          expect(item.comic.title, startsWith('${source.sourceKey}-作品'));
          expect(item.comic.id, isNot('fresh'));
        }
        expect(find.text('新响应'), findsNothing);
        await selectSource(tester, provider);
        expectPixivCache();
      }

      for (final source in providers) {
        expect(source.overviews, 1);
        expect(source.lists, paged ? 1 : 0);
        expect(
            source.overviewRequests.every((r) =>
                r.sourceKey == source.sourceKey &&
                r.entryId == source.recommendId),
            isTrue);
        expect(
            source.requests.every((r) =>
                r.sourceKey == source.sourceKey &&
                r.entryId == source.recommendId &&
                r.continuation == null),
            isTrue);
        if (paged) {
          expect(source.requests.single.sessionId,
              source.overviewRequests.single.sessionId);
        }
      }
      expect(
          providers
              .map((source) => source.overviewRequests.single.sessionId)
              .toSet(),
          hasLength(providers.length));
      expect(tester.takeException(), isNull);
    });
  }
}
