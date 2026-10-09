import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
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
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';

// Scroll regression for real ExplorePage, complete overview prefixes and the
// lazy final masonry. Six stress cases have three sections; production has two.
// Empty covers and known bookmark state keep this entirely offline.
// Same setup/provider pattern as recommendation_waterfall_test.dart; its helpers
// are library-private, so this standalone test keeps a small equivalent fixture.
const _outputPath = 'docs/verification/pixiv-recommend-scroll-037-after';
const _frame = Duration(milliseconds: 16);
const _scrollKey = Key('explore-recommend-scroll');
const _titles = ['推荐作品', '我的收藏', '关注画师'];

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationCachePath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

final class _SettingsIO extends IOOverrides {
  _SettingsIO(this.settingsPath);
  final String settingsPath;
  @override
  File createFile(String path) =>
      path == settingsPath ? _SettingsFile(path) : super.createFile(path);
}

class _SettingsFile implements File {
  _SettingsFile(this.path);
  @override
  final String path;
  @override
  Future<File> writeAsString(String contents,
          {FileMode mode = FileMode.write,
          Encoding encoding = utf8,
          bool flush = false}) async =>
      this;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected settings fixture I/O');
}

class _Case {
  const _Case(this.name,
      {this.size = const Size(375, 812),
      this.columns = 2,
      this.pane = false,
      this.seed,
      this.compact = false,
      this.productionCounts = false,
      this.textScale = 1,
      this.tagsNatural = false});
  final String name;
  final Size size;
  final int columns;
  final bool pane;
  final int? seed;
  final bool compact;
  final bool productionCounts;
  final double textScale;
  final bool tagsNatural;
  int get count => compact ? 18 : 24;
  List<int> get sectionCounts =>
      productionCounts ? [10, 48] : [count, count, count];
}

class _OverviewProvider implements ExploreProvider {
  _OverviewProvider(this.config) {
    final random = math.Random(config.seed ?? 37);
    sections = List.generate(config.sectionCounts.length, (section) {
      final count = config.sectionCounts[section];
      final items = <BaseComic>[];
      // Two columns have equal item counts and balanced cumulative heights in
      // each four-item block: short/tall/tall/short. Titles/tags vary by block.
      for (var block = 0; items.length < count; block++) {
        final short = config.compact
            ? 360 + random.nextInt(120)
            : config.seed == null
                ? 600 + section * 40
                : 400 + random.nextInt(450);
        final tall = config.compact
            ? 420 + random.nextInt(120)
            : config.seed == null
                ? 1900 - section * 70
                : 1200 + random.nextInt(1000);
        for (final height in [short, tall, tall, short]) {
          if (items.length >= count) break;
          final id = '${section + 1}${items.length.toString().padLeft(3, '0')}';
          final verbose = block.isOdd && !config.compact;
          items.add(PixivComicBrief(
            id: id,
            title: verbose ? '作品$id 很长的标题用于真实双行卡片布局与边界调查' : '作品$id',
            author: verbose ? '作者名字很长但只占一行' : '作者',
            tags: verbose
                ? const ['风景', '测试标签很长很长', '插画', '人物', '光影', '色彩', '其他']
                : const ['短标签'],
            cover: '',
            illustType: pixivIllustTypeIllust,
            pageCount: verbose ? 4 : 1,
            width: 1000,
            height: height,
            bookmarkStateKnown: true,
            isBookmarked: section == 1,
          ));
        }
      }
      return ExploreSection(
          id: config.productionCounts
              ? ['recommended', 'bookmarks'][section]
              : ['recommend', 'myfav', 'following'][section],
          title: _titles[section],
          entryId: config.productionCounts && section == 1
              ? 'pixiv.bookmarks'
              : entryId,
          isSinglePage: config.productionCounts,
          moreEntryId: config.productionCounts && section == 1
              ? 'pixiv.bookmarks'
              : null,
          items: items);
    });
  }
  final _Case config;
  String get entryId =>
      config.productionCounts ? 'pixiv.recommended' : 'pixiv.home';
  late final List<ExploreSection> sections;
  final requests = <ExploreRequest>[];
  int comicRequests = 0, directoryRequests = 0;
  @override
  late final descriptor = ExploreSourceDescriptor(
    sourceKey: 'pixiv',
    name: '测试Pixiv',
    requiresLogin: false,
    entries: [
      ExploreEntry(
          id: entryId, label: '主页', kind: ExploreSectionKind.recommend),
      if (config.productionCounts)
        const ExploreEntry(
            id: 'pixiv.bookmarks',
            label: '我的收藏',
            kind: ExploreSectionKind.recommend,
            availableAsTab: false),
    ],
  );
  @override
  bool get isLoggedIn => true;
  @override
  String get contextFingerprint => 'pixiv-037-fixture-account';
  @override
  Future<ExploreResult<ExploreOverview>> loadOverview(ExploreRequest r) async {
    requests.add(r);
    return ExploreSuccess(ExploreOverview(
        sourceKey: 'pixiv', entryId: r.entryId, sections: sections));
  }

  @override
  Future<ExploreResult<ExploreComicPage>> loadComics(ExploreRequest r) async {
    comicRequests++;
    return const ExploreFailure(
        ExploreError(ExploreErrorCode.unsupported, 'overview-only fixture'));
  }

  @override
  Future<ExploreResult<ExploreDirectory>> loadDirectory(
      ExploreRequest r) async {
    directoryRequests++;
    return const ExploreFailure(
        ExploreError(ExploreErrorCode.unsupported, 'overview-only fixture'));
  }
}

Map<String, Object?> _metrics(ScrollMetrics m) => {
      'pixels': m.pixels,
      'min': m.minScrollExtent,
      'max': m.maxScrollExtent,
      'viewport': m.viewportDimension,
      'before': m.extentBefore,
      'inside': m.extentInside,
      'after': m.extentAfter,
      'outOfRange': m.outOfRange,
    };

double? _finite(double? value) =>
    value != null && value.isFinite ? value : null;

class _Trace {
  _Trace(this.config, this.provider);
  final _Case config;
  final _OverviewProvider provider;
  final frames = <Map<String, Object?>>[];
  final events = <Map<String, Object?>>[];
  final boundaries = <Map<String, Object?>>[];
  final errors = <Map<String, Object?>>[];
  final anomalies = <Map<String, Object?>>[];
  List<int> deepVisibleFinalCardIndices = [];
  String phase = 'initial';
  int frame = 0, order = 0;
  double pendingNotificationDelta = 0;
  double? lastPixels;
  ScrollController? controller;

  void attach(ScrollController value) {
    controller = value;
    value.addListener(() {
      if (!value.hasClients) return;
      events.add({
        'order': order++,
        'frame': frame,
        'phase': phase,
        'event': 'controller',
        ..._metrics(value.position),
      });
    });
  }

  bool onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical || n.depth != 0) return false;
    final delta = n is ScrollUpdateNotification ? n.scrollDelta : null;
    pendingNotificationDelta += delta ?? 0;
    events.add({
      'order': order++,
      'frame': frame,
      'phase': phase,
      'event': n.runtimeType.toString(),
      'scrollDelta': delta,
      'drag': n is ScrollUpdateNotification && n.dragDetails != null,
      ..._metrics(n.metrics),
    });
    return false;
  }

  bool onMetrics(ScrollMetricsNotification n) {
    if (n.metrics.axis == Axis.vertical && n.depth == 0) {
      events.add({
        'order': order++,
        'frame': frame,
        'phase': phase,
        'event': 'metrics',
        ..._metrics(n.metrics),
      });
    }
    return false;
  }

  Map<String, Object?> toolbar(WidgetTester tester) {
    final toolbar = find.byKey(const ValueKey('explore-toolbar'));
    if (toolbar.evaluate().isEmpty) return {};
    final ancestors =
        find.ancestor(of: toolbar, matching: find.byType(Opacity));
    final transforms =
        find.ancestor(of: toolbar, matching: find.byType(Transform));
    final floating = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_FloatingExploreLayout');
    final padding = find.descendant(
        of: floating,
        matching: find.byWidgetPredicate((w) =>
            w is Padding &&
            w.padding is EdgeInsets &&
            (w.padding as EdgeInsets).left == 0 &&
            (w.padding as EdgeInsets).right == 0 &&
            (w.padding as EdgeInsets).bottom == 0));
    final candidates = padding.evaluate().where((e) {
      var ownsScroll = false;
      void visit(Element child) {
        if (child.widget.key == _scrollKey) ownsScroll = true;
        child.visitChildren(visit);
      }

      e.visitChildren(visit);
      return ownsScroll;
    }).toList();
    final element = toolbar.evaluate().single;
    final render = element.findRenderObject();
    return {
      'opacity': ancestors.evaluate().isEmpty
          ? null
          : tester.widget<Opacity>(ancestors.first).opacity,
      'scale': transforms.evaluate().isEmpty
          ? null
          : tester.widget<Transform>(transforms.first).transform.entry(0, 0),
      'outerPaddingTop': candidates.isEmpty
          ? null
          : ((candidates.first.widget as Padding).padding as EdgeInsets).top,
      'measuredDock':
          render is RenderBox && render.hasSize ? render.size.height : null,
    };
  }

  List<Map<String, Object?>> grids(WidgetTester tester) => [
        for (final element
            in find.byType(SliverMasonryGrid, skipOffstage: false).evaluate())
          if (element.findRenderObject()
              case final RenderSliverMasonryGrid grid)
            if (grid.geometry != null)
              {
                'scrollOffset': _finite(grid.constraints.scrollOffset),
                'cacheOrigin': _finite(grid.constraints.cacheOrigin),
                'remainingCache':
                    _finite(grid.constraints.remainingCacheExtent),
                'remainingPaint':
                    _finite(grid.constraints.remainingPaintExtent),
                'scrollExtent': _finite(grid.geometry?.scrollExtent),
                'paintExtent': _finite(grid.geometry?.paintExtent),
                'correction': _finite(grid.geometry?.scrollOffsetCorrection),
                'firstIndex': grid.firstChild == null
                    ? null
                    : grid.indexOf(grid.firstChild!),
                'lastIndex': grid.lastChild == null
                    ? null
                    : grid.indexOf(grid.lastChild!),
                'children': [
                  for (RenderBox? child = grid.firstChild;
                      child != null;
                      child = grid.childAfter(child))
                    {
                      'index': grid.indexOf(child),
                      'column':
                          (child.parentData as SliverMasonryGridParentData)
                              .crossAxisIndex,
                      'offset': _finite(grid.childScrollOffset(child)),
                      'height': child.hasSize ? child.size.height : null,
                    }
                ],
              }
      ];

  void sample(WidgetTester tester, {double? fingerDy}) {
    final scroll = controller;
    if (scroll == null || !scroll.hasClients) return;
    final pixels = scroll.position.pixels;
    final delta = lastPixels == null ? 0.0 : pixels - lastPixels!;
    final residual =
        lastPixels == null ? 0.0 : delta - pendingNotificationDelta;
    final row = <String, Object?>{
      'order': order++,
      'frame': frame++,
      'phase': phase,
      ..._metrics(scroll.position),
      'previousPixels': lastPixels,
      'frameDelta': delta,
      'notificationDelta': pendingNotificationDelta,
      'unnotifiedResidual': residual,
      'fingerDy': fingerDy,
      'boundaryMotion': scroll.position.outOfRange ||
          (lastPixels != null &&
              (lastPixels! < scroll.position.minScrollExtent ||
                  lastPixels! > scroll.position.maxScrollExtent)),
      'toolbar': toolbar(tester),
      'grids': grids(tester),
      'completeBoxes': [
        for (final element
            in find.byType(StaggeredGrid, skipOffstage: false).evaluate())
          if (element.findRenderObject() case final RenderBox box)
            {
              'childCount': (element.widget as StaggeredGrid).children.length,
              'height': box.hasSize ? box.size.height : null,
              'width': box.hasSize ? box.size.width : null,
            }
      ],
      'builtCardsPerSection': [
        for (final section in provider.sections)
          find
              .byType(OnlineRecommendationCard, skipOffstage: false)
              .evaluate()
              .where((e) => section.items.any((comic) =>
                  comic.id == (e.widget as OnlineRecommendationCard).comic.id))
              .length,
      ],
      'overviewRequests': provider.requests.length,
      'fingerprint': provider.contextFingerprint,
    };
    frames.add(row);
    if (lastPixels != null &&
        !phase.startsWith('position-') &&
        !phase.startsWith('reset-') &&
        ((phase.contains('down') &&
                row['boundaryMotion'] == false &&
                delta < -2) ||
            residual.abs() > 2)) {
      anomalies.add(row);
    }
    lastPixels = pixels;
    pendingNotificationDelta = 0;
  }

  Future<void> pump(WidgetTester tester, {double? fingerDy}) async {
    await tester.pump(_frame);
    sample(tester, fingerDy: fingerDy);
    Object? exception;
    while ((exception = tester.takeException()) != null) {
      errors.add({
        'frame': frame,
        'phase': phase,
        'error': exception.toString(),
      });
    }
  }

  Map<String, Object?>? header(WidgetTester tester, int section) {
    final finder = find.text(_titles[section], skipOffstage: false);
    if (finder.evaluate().isEmpty) return null;
    final render = finder.evaluate().single.findRenderObject();
    if (render is! RenderBox || !render.hasSize) return null;
    final rect = tester.getRect(finder);
    final viewport = tester.getRect(find.byKey(_scrollKey));
    final pixels = controller!.position.pixels;
    return {
      'section': section,
      'title': _titles[section],
      'frame': frame,
      'pixels': pixels,
      'globalTop': rect.top,
      'globalBottom': rect.bottom,
      'viewportTop': viewport.top,
      'contentTop': pixels + rect.top - viewport.top,
      'contentBottom': pixels + rect.bottom - viewport.top,
    };
  }

  Future<void> save() async {
    final directory = Directory(_outputPath)..createSync(recursive: true);
    final summary = {
      'case': config.name,
      'viewport': {'width': config.size.width, 'height': config.size.height},
      'columns': config.columns,
      'naviPane': config.pane,
      'seed': config.seed,
      'tagsNatural': config.tagsNatural,
      'textScale': config.textScale,
      'defaultCacheExtent': 250,
      'fixtureItemsPerSection': config.sectionCounts,
      'overviewRequests': provider.requests.length,
      'comicRequests': provider.comicRequests,
      'directoryRequests': provider.directoryRequests,
      'frameCount': frames.length,
      'expectedKnownBugSignature': false,
      'initialBuiltCardsPerSection': frames.first['builtCardsPerSection'],
      'completeBoxes': frames.first['completeBoxes'],
      'maxNaturalPixels': frames
          .where((f) => !(f['phase'] as String).startsWith('position-'))
          .map((f) => f['pixels'] as double)
          .fold(0.0, math.max),
      'deepVisibleFinalCardIndices': deepVisibleFinalCardIndices,
      'observedKnownBugSignature': anomalies.any((f) =>
          (f['phase'] as String).contains('down') &&
          (f['frameDelta'] as double) < -100 &&
          (f['unnotifiedResidual'] as double) < -100),
      'anomalyCount': anomalies.length,
      'layoutErrors': errors.length,
      'minDownwardFrameDelta': frames
          .where((f) =>
              (f['phase'] as String).contains('down') &&
              f['boundaryMotion'] == false)
          .map((f) => f['frameDelta'] as double)
          .fold(0.0, math.min),
      'largestNegativeResidual': frames
          .where((f) =>
              !(f['phase'] as String).startsWith('position-') &&
              !(f['phase'] as String).startsWith('reset-'))
          .map((f) => f['unnotifiedResidual'] as double)
          .fold(0.0, math.min),
      'boundaries': boundaries,
      'errors': errors,
      'anomalies': anomalies,
    };
    final data = {
      'summary': summary,
      'fixture': [
        for (final section in provider.sections)
          {
            'id': section.id,
            'title': section.title,
            'items': [
              for (final item in section.items.cast<PixivComicBrief>())
                {
                  'id': item.id,
                  'width': item.width,
                  'height': item.height,
                  'title': item.title,
                  'tags': item.tags,
                  'cover': item.cover,
                }
            ],
          }
      ],
      'frames': frames,
      'events': events,
    };
    File('${directory.path}/${config.name}.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
    File('${directory.path}/${config.name}.summary.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(summary));
    // Kept short enough for the expanded flutter test reporter.
    // ignore: avoid_print
    print('037 ${config.name}: frames=${frames.length}, '
        'anomalies=${anomalies.length}, errors=${errors.length}, '
        'minDown=${summary['minDownwardFrameDelta']}, '
        'minResidual=${summary['largestNegativeResidual']}, '
        'overview=${provider.requests.length}');
  }
}

void main() {
  final oldPaths = PathProviderPlatform.instance;
  final oldOverrides = IOOverrides.current;
  late Directory appDirectory;
  late List<ComicSource> savedSources;
  late List<String> savedSettings, savedKeywords;
  setUpAll(() async {
    // TEMP/TMP is set by the documented runner. Keep fixture data in the
    // workspace explicitly even when someone runs this file without the runner.
    final base = Directory('.dart_tool/037-temp')..createSync(recursive: true);
    appDirectory = base.createTempSync('explore-fixture-');
    PathProviderPlatform.instance = _Paths(appDirectory.absolute.path);
    await App.init(dataPathOverride: appDirectory.absolute.path);
    IOOverrides.global = _SettingsIO('${App.dataPath}/settings');
  });
  tearDownAll(() {
    HistoryManager().dispose();
    LocalFavoritesManager().dispose();
    IOOverrides.global = oldOverrides;
    PathProviderPlatform.instance = oldPaths;
    // Preserve isolated fixture data: investigation never deletes user data.
  });
  setUp(() {
    savedSources = List.of(ComicSource.sources);
    savedSettings = List.of(appdata.settings);
    savedKeywords = List.of(appdata.blockingKeyword);
    PixivBookmarkStateStore.shared.clear();
    appdata.blockingKeyword = [];
    appdata.settings[83] = '0';
    appdata.settings[exploreSelectionSettingIndex] = '{}';
  });
  tearDown(() {
    ExploreBindings.debugSetInstance(null);
    ComicSource.sources
      ..clear()
      ..addAll(savedSources);
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    appdata.blockingKeyword = savedKeywords;
  });

  const cases = [
    _Case('mobile-2col-balanced'),
    _Case('mobile-2col-pane', pane: true),
    _Case('mobile-2col-seeded', seed: 37037, tagsNatural: true),
    _Case('mobile-3col', columns: 3),
    _Case('mobile-2col-compact', compact: true),
    _Case('mobile-production-10-48', productionCounts: true),
    _Case('mobile-production-large-text',
        productionCounts: true, textScale: 1.5),
    _Case('large-2col-pane', size: Size(1200, 900), pane: true),
  ];
  for (final config in cases) {
    testWidgets('037 ${config.name} records real overview boundary scroll',
        (tester) async {
      tester.view.physicalSize = config.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      appdata.settings[illustWaterfallColumnsSettingIndex] =
          '${config.columns}';
      appdata.settings[comicTileDisplayConfigSettingIndex] = config.tagsNatural
          ? '{"waterfall":{"recommend":{"showTags":true,"tagRows":0}}}'
          : '';
      final provider = _OverviewProvider(config);
      final registry = ExploreRegistry()..register(provider);
      ComicSource.sources
        ..clear()
        ..add(ComicSource.named(
            key: 'pixiv', name: '测试Pixiv', data: {'token': 'fixture'}));
      ExploreBindings.debugSetInstance(ExploreBindings.forTesting(registry));
      final trace = _Trace(config, provider);
      final observer = NaviObserver();
      final page = ExploreRouteScope(
          observer: observer, child: const Scaffold(body: ExplorePage()));
      final body = config.pane
          ? NaviPane(
              paneItems: [
                  PaneItemEntry(
                      label: '探索',
                      icon: Icons.explore_outlined,
                      activeIcon: Icons.explore)
                ],
              paneActions: const [],
              pageBuilder: (_) => page,
              observer: observer)
          : page;
      await tester.pumpWidget(MaterialApp(
          navigatorObservers: [observer],
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(config.textScale)),
              child: child!),
          home: NotificationListener<ScrollMetricsNotification>(
              onNotification: trace.onMetrics,
              child: NotificationListener<ScrollNotification>(
                  onNotification: trace.onScroll, child: body))));
      await tester.pumpAndSettle();
      expect(
          find.byType(SliverMasonryGrid, skipOffstage: false), findsOneWidget);
      expect(find.byType(StaggeredGrid, skipOffstage: false),
          findsNWidgets(config.sectionCounts.length - 1));
      final completeCards = tester
          .widgetList<StaggeredGrid>(
              find.byType(StaggeredGrid, skipOffstage: false))
          .fold(0, (sum, grid) => sum + grid.children.length);
      expect(
          completeCards,
          config.sectionCounts
              .take(config.sectionCounts.length - 1)
              .fold(0, (sum, count) => sum + count));
      final feedScrollables = find.descendant(
          of: find.byKey(_scrollKey), matching: find.byType(Scrollable));
      expect(
          tester.widgetList<Scrollable>(feedScrollables).where(
              (w) => axisDirectionToAxis(w.axisDirection) == Axis.vertical),
          hasLength(1),
          reason: 'The feed has one vertical scroll, no nested grid');
      final scroll =
          tester.widget<CustomScrollView>(find.byKey(_scrollKey)).controller!;
      trace.attach(scroll);
      trace.pendingNotificationDelta = 0;
      trace.sample(tester);
      if (config.productionCounts) {
        expect(trace.frames.first['builtCardsPerSection'], [10, 1],
            reason: 'Ten recommendation cards complete; bookmarks remain lazy');
      }
      addTearDown(() async {
        await trace.save();
      });

      Future<void> drag(String phase, double distance,
          {double step = 12}) async {
        trace.phase = phase;
        final rect = tester.getRect(find.byKey(_scrollKey));
        final start = Offset(
            rect.center.dx, distance < 0 ? rect.bottom - 70 : rect.top + 85);
        final gesture = await tester.createGesture();
        await gesture.down(start, timeStamp: _frame * trace.frame);
        await trace.pump(tester);
        var remaining = distance.abs();
        var point = start;
        while (remaining > 0) {
          final amount = math.min(step, remaining) * distance.sign;
          point += Offset(0, amount);
          await gesture.moveTo(point, timeStamp: _frame * trace.frame);
          await trace.pump(tester, fingerDy: amount);
          remaining -= amount.abs();
        }
        await gesture.up(timeStamp: _frame * trace.frame);
        // Finite pumping preserves every frame and never hides a nonsettling
        // animation behind pumpAndSettle's timeout.
        for (var i = 0; i < 24; i++) {
          await trace.pump(tester);
        }
      }

      Future<void> position(double pixels, String phase) async {
        trace.phase = 'position-$phase';
        scroll.jumpTo(pixels.clamp(0.0, scroll.position.maxScrollExtent));
        for (var i = 0; i < 3; i++) {
          await trace.pump(tester);
        }
      }

      Future<void> fling(String phase, double speed) async {
        trace.phase = phase;
        final rect = tester.getRect(find.byKey(_scrollKey));
        final distance = math.min(430.0, rect.height - 160);
        // Timed pointer moves reproduce a fling and expose before/after frames,
        // unlike tester.fling, which emits the whole gesture before the trace.
        final start = Offset(rect.center.dx, rect.bottom - 65);
        final gesture = await tester.createGesture();
        await gesture.down(start, timeStamp: _frame * trace.frame);
        await trace.pump(tester);
        var point = start;
        var remaining = distance;
        final step = speed * .016;
        while (remaining > 0) {
          final dy = -math.min(step, remaining);
          point += Offset(0, dy);
          await gesture.moveTo(point, timeStamp: _frame * trace.frame);
          await trace.pump(tester, fingerDy: dy);
          remaining += dy;
        }
        await gesture.up(timeStamp: _frame * trace.frame);
        for (var i = 0; i < 120; i++) {
          await trace.pump(tester);
        }
      }

      // Header coordinates are measured from laid out production widgets. No
      // item-count/average-height formula guesses the section boundary.
      Map<String, Object?>? measured;
      for (var attempt = 0; attempt < 32; attempt++) {
        final candidate = trace.header(tester, 1);
        final rect = tester.getRect(find.byKey(_scrollKey));
        if (candidate != null &&
            (candidate['globalTop'] as double) < rect.bottom + 250 &&
            (candidate['globalTop'] as double) > rect.top - 200) {
          measured = candidate;
          break;
        }
        await drag('calibrate-down', -math.min(300.0, rect.height - 180),
            step: 15);
      }
      expect(measured, isNotNull,
          reason: 'Must measure myfav header from real laid out rect');
      trace.boundaries.add(measured!);
      final boundary = measured['contentTop'] as double;
      final viewportHeight = scroll.position.viewportDimension;
      final entry = boundary - viewportHeight + 130;
      final initialSession = provider.requests.single.sessionId;
      final identity = provider.contextFingerprint;

      await position(entry - 200, 'slow-start');
      await drag('slow-down-cross-second-grid', -450, step: 10);
      if (trace.header(tester, 1) case final value?) {
        trace.boundaries.add(value);
      }
      if (config.productionCounts) {
        await position(boundary - 120, 'slow-cache-start');
        await drag('slow-down-through-cache-boundary', -560, step: 10);
      }
      await position(entry - 180, 'fast-start');
      await fling('fast-down-cross-second-grid', 6500);
      await drag('reverse-up', 340, step: 20);
      await fling('repeat-fast-down', 10000);
      await position(boundary + 180, 'inside-second-grid');
      await drag('reverse-up-boundary', 460, step: 20);
      await fling('repeat-fast-down-after-reverse', 12000);
      List<int> visibleFinalCards() {
        final viewport = tester.getRect(find.byKey(_scrollKey));
        final finalItems = provider.sections.last.items;
        return [
          for (final element
              in find.byType(OnlineRecommendationCard).evaluate())
            if (element.findRenderObject() case final RenderBox box)
              if (box.hasSize &&
                  (box.localToGlobal(Offset.zero) & box.size)
                      .overlaps(viewport))
                for (var index = 0; index < finalItems.length; index++)
                  if ((element.widget as OnlineRecommendationCard).comic.id ==
                      finalItems[index].id)
                    index,
        ];
      }

      for (var round = 0; round < 12; round++) {
        await fling('deep-natural-down-$round', 6500);
        if (round >= 2 &&
            visibleFinalCards()
                .any((index) => index >= config.sectionCounts.last ~/ 2)) {
          break;
        }
      }
      final naturalFrames = trace.frames
          .where((f) => !(f['phase'] as String).startsWith('position-'));
      expect(
          naturalFrames
              .any((f) => (f['pixels'] as double) > boundary + viewportHeight),
          isTrue,
          reason:
              'Natural scrolling must continue deep past the second header');
      trace.deepVisibleFinalCardIndices = visibleFinalCards();
      expect(
          trace.deepVisibleFinalCardIndices
              .any((index) => index >= config.sectionCounts.last ~/ 2),
          isTrue,
          reason: 'Natural flings must show a latter-half final-section card '
              'inside the real viewport, beyond cache-only construction');
      if (trace.header(tester, 2) case final value?) {
        trace.boundaries.add(value);
      }
      expect(provider.requests, hasLength(1));
      expect(provider.requests.single.entryId, provider.entryId);
      expect(provider.requests.single.sessionId, initialSession);
      expect(provider.contextFingerprint, identity);
      expect(provider.comicRequests, 0);
      expect(provider.directoryRequests, 0);
      expect(ComicSource.sources.single.data['token'], 'fixture');
      expect(
          trace.frames.where((f) =>
              (f['phase'] as String).contains('down') &&
              !(f['phase'] as String).startsWith('position-') &&
              f['boundaryMotion'] == false &&
              ((f['frameDelta'] as double) < -2 ||
                  (f['unnotifiedResidual'] as double) < -2)),
          isEmpty,
          reason: 'Downward gestures and ballistics must cross complete '
              'overview prefixes without a silent backwards correction');
      expect(trace.errors, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
