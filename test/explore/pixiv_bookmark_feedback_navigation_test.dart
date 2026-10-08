import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/foundation/explore/explore_bindings.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_provider.dart';
import 'package:picakeep/foundation/explore/explore_registry.dart';
import 'package:picakeep/foundation/explore/explore_selection_state.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/network/pixiv_network/pixiv_models.dart';
import 'package:picakeep/pages/explore/explore_page.dart';
import 'package:picakeep/pages/explore/explore_route_scope.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationCachePath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

// Only settings persistence is replaced: navigation and feedback are production.
final class _SettingsIO extends IOOverrides {
  @override
  File createFile(String path) => path == '${App.dataPath}/settings'
      ? _SettingsFile(path)
      : super.createFile(path);
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

class _Provider implements ExploreProvider {
  _Provider(this.sourceKey);
  final String sourceKey;
  @override
  String get contextFingerprint => '$sourceKey-offline';
  @override
  bool get isLoggedIn => true;
  @override
  late final ExploreSourceDescriptor descriptor = ExploreSourceDescriptor(
    sourceKey: sourceKey,
    name: '测试$sourceKey',
    requiresLogin: false,
    entries: [
      ExploreEntry(
          id: '$sourceKey.home',
          label: '主页',
          kind: ExploreSectionKind.recommend),
      ExploreEntry(
          id: '$sourceKey.ranking',
          label: '榜单',
          kind: ExploreSectionKind.ranking,
          options: const [
            ExploreOption(id: 'day', label: '日榜'),
            ExploreOption(id: 'week', label: '周榜'),
          ],
          defaultOptionId: 'day'),
    ],
  );
  // Known and unavailable for writing: layout tests never trigger a real query.
  PixivComicBrief comic(ExploreRequest r) => PixivComicBrief(
        id: '123',
        title: '${r.entryId}-${r.options.first ?? "home"}',
        cover: '',
        author: '作者',
        tags: const [],
        illustType: pixivIllustTypeIllust,
        pageCount: 1,
        width: 600,
        height: 900,
      );
  @override
  Future<ExploreResult<ExploreOverview>> loadOverview(ExploreRequest r) async =>
      const ExploreFailure(ExploreError(ExploreErrorCode.unsupported, '分页'));
  @override
  Future<ExploreResult<ExploreComicPage>> loadComics(ExploreRequest r) async =>
      ExploreSuccess(ExploreComicPage(
          sourceKey: sourceKey, entryId: r.entryId, items: [comic(r)]));
  @override
  Future<ExploreResult<ExploreDirectory>> loadDirectory(
          ExploreRequest r) async =>
      const ExploreFailure(ExploreError(ExploreErrorCode.unsupported, '无目录'));
}

Finder get _capsule => find.byKey(const ValueKey('pixiv-bookmark-feedback'));

void main() {
  late Directory temp;
  late List<ComicSource> sources;
  late List<String> settings, keywords;
  final paths = PathProviderPlatform.instance;
  final savedIO = IOOverrides.current;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('pk-feedback-navigation-');
    PathProviderPlatform.instance = _Paths(temp.path);
    await App.init(dataPathOverride: temp.path);
    IOOverrides.global = _SettingsIO();
  });
  tearDownAll(() async {
    HistoryManager().dispose();
    LocalFavoritesManager().dispose();
    IOOverrides.global = savedIO;
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
    PixivBookmarkStateStore.shared.clear();
    final registry = ExploreRegistry();
    ComicSource.sources.clear();
    for (final key in ['pixiv', 'jm']) {
      registry.register(_Provider(key));
      ComicSource.sources.add(ComicSource.named(
          key: key, name: '测试$key', data: {'token': 'offline'}));
    }
    ExploreBindings.debugSetInstance(ExploreBindings.forTesting(registry));
  });
  tearDown(() {
    ExploreBindings.debugSetInstance(null);
    PixivBookmarkStateStore.shared.clear();
    ComicSource.sources
      ..clear()
      ..addAll(sources);
    appdata.settings
      ..clear()
      ..addAll(settings);
    appdata.blockingKeyword = keywords;
  });

  Future<GlobalKey<NavigatorState>> pumpPane(WidgetTester tester,
      {Size size = const Size(375, 812),
      Brightness brightness = Brightness.light,
      double textScale = 1}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final observer = NaviObserver();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: false),
          child: child!),
      home: NaviPane(
        observer: observer,
        paneItems: [
          PaneItemEntry(
              label: '探索',
              icon: Icons.explore_outlined,
              activeIcon: Icons.explore),
          PaneItemEntry(
              label: '收藏',
              icon: Icons.bookmark_outline,
              activeIcon: Icons.bookmark),
        ],
        paneActions: const [],
        pageBuilder: (_) => Navigator(
          key: navigator,
          observers: [observer],
          onGenerateRoute: (_) => AppPageRoute<void>(
            preventRebuild: false,
            isRootRoute: true,
            builder: (_) => ExploreRouteScope(
                observer: observer,
                child: const NaviPaddingWidget(child: ExplorePage())),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '测试pixiv'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('explore-tab-榜单')));
    await tester.pumpAndSettle();
    expect(find.byType(Scaffold), findsNothing);
    expect(tester.takeException(), isNull);
    return navigator;
  }

  PixivBookmarkFeedbackTicket capture(WidgetTester tester) {
    final context = tester.element(find.byType(OnlineRecommendationCard).first);
    return PixivBookmarkFeedbackHost.maybeOf(context)!
        .capture(account: 'offline', workId: '123');
  }

  void expectVisible(WidgetTester tester, String text, Size size) {
    expect(find.textContaining(text), findsOneWidget);
    expect(_capsule, findsOneWidget);
    final rect = tester.getRect(_capsule);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(size.width));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.height, greaterThanOrEqualTo(48));
    expect(rect.width, lessThanOrEqualTo(420));
    // Narrow NaviPane reserves exactly 58 dp for its production bottom bar.
    final content = tester.getRect(find.byType(ExplorePage));
    expect(rect.bottom, lessThanOrEqualTo(content.bottom - 15));
    if (size.width == 375) {
      expect(rect.bottom, lessThanOrEqualTo(size.height - 58 - 15));
    }
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  }

  for (final brightness in Brightness.values) {
    testWidgets(
        'production ranking capsules visible above bottom bar $brightness',
        (tester) async {
      const size = Size(375, 812);
      await pumpPane(tester, brightness: brightness);
      for (final message in [
        const PixivBookmarkFeedbackMessage.added(),
        const PixivBookmarkFeedbackMessage.removed(),
        PixivBookmarkFeedbackMessage.failed('离线失败：收藏权限已失效'),
      ]) {
        expect(capture(tester).show(message), isTrue);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));
        expectVisible(tester, message.text, size);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('long error wraps at double text scale without clipping',
      (tester) async {
    const size = Size(375, 812);
    await pumpPane(tester, textScale: 2);
    final message =
        PixivBookmarkFeedbackMessage.failed('离线服务返回：当前账号没有收藏权限，请重新登录后重试。');
    expect(capture(tester).show(message), isTrue);
    await tester.pumpAndSettle();
    expectVisible(tester, message.text, size);
    final text = tester.widget<Text>(find.text(message.text));
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    expect(tester.getRect(find.text(message.text)).height, greaterThan(56));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [const Size(932, 430), const Size(1280, 800)]) {
    testWidgets('production capsule fits landscape or desktop $size',
        (tester) async {
      await pumpPane(tester, size: size);
      expect(capture(tester).show(const PixivBookmarkFeedbackMessage.added()),
          isTrue);
      await tester.pumpAndSettle();
      expectVisible(tester, '已添加公开收藏', size);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('production waiting queues immediately and settles its heart',
      (tester) async {
    await pumpPane(tester);
    final ticket = capture(tester);
    ticket.startWaiting();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expectVisible(tester, '正在读取收藏状态…', const Size(375, 812));
    expect(ticket.isCurrent, isTrue);
    ticket.updateWaitingTarget(false);
    await tester.pumpAndSettle();
    expectVisible(tester, '正在取消收藏…', const Size(375, 812));
    expect(ticket.finish(const PixivBookmarkFeedbackMessage.removed()), isTrue);
    await tester.pumpAndSettle();
    expectVisible(tester, '已取消收藏', const Size(375, 812));
    expect(find.text('正在取消收藏…'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'older waiting timer and cancellation cannot replace newer result',
      (tester) async {
    await pumpPane(tester);
    final older = capture(tester)..startWaiting(target: true);
    await tester.pump(const Duration(milliseconds: 700));
    final newer = capture(tester)..startWaiting(target: false);
    expect(newer.finish(const PixivBookmarkFeedbackMessage.removed()), isTrue);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    older.cancelWaiting();
    expect(older.finish(const PixivBookmarkFeedbackMessage.added()), isFalse);
    await tester.pumpAndSettle();
    expectVisible(tester, '已取消收藏', const Size(375, 812));
    expect(find.text('正在提交收藏…'), findsNothing);
    expect(find.text('已添加公开收藏'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final change in ['source', 'tab', 'feed-option', 'route']) {
    testWidgets('$change invalidates old production Feed tickets after return',
        (tester) async {
      final navigator = await pumpPane(tester);
      final ticket = capture(tester);
      expect(ticket.show(const PixivBookmarkFeedbackMessage.added()), isTrue);
      await tester.pumpAndSettle();
      expect(_capsule, findsOneWidget);
      switch (change) {
        case 'source':
          await tester.tap(find.widgetWithText(Tab, '测试jm'));
          await tester.pumpAndSettle();
          expect(ticket.isCurrent, isFalse);
          await tester.tap(find.widgetWithText(Tab, '测试pixiv'));
        case 'tab':
          await tester.tap(find.byKey(const ValueKey('explore-tab-推荐')));
          await tester.pumpAndSettle();
          expect(ticket.isCurrent, isFalse);
          await tester.tap(find.byKey(const ValueKey('explore-tab-榜单')));
        case 'feed-option':
          await tester.tap(find.byType(PopupMenuButton<String>));
          await tester.pumpAndSettle();
          // A popup alone must not invalidate the current page's ticket.
          expect(ticket.isCurrent, isTrue);
          await tester
              .tap(find.byKey(const ValueKey('explore-entry-option-week')));
          await tester.pumpAndSettle();
          expect(ticket.isCurrent, isFalse);
          await tester.tap(find.byType(PopupMenuButton<String>));
          await tester.pumpAndSettle();
          await tester
              .tap(find.byKey(const ValueKey('explore-entry-option-day')));
        case 'route':
          navigator.currentState!.push(AppPageRoute<void>(
              builder: (_) =>
                  const Material(child: Center(child: Text('详情替身')))));
          await tester.pumpAndSettle();
          expect(ticket.isCurrent, isFalse);
          expect(ticket.show(PixivBookmarkFeedbackMessage.failed('迟到失败')),
              isFalse);
          navigator.currentState!.pop();
      }
      await tester.pumpAndSettle();
      expect(ticket.isCurrent, isFalse);
      expect(
          ticket.show(const PixivBookmarkFeedbackMessage.removed()), isFalse);
      expect(_capsule, findsNothing);
      expect(find.text('迟到失败'), findsNothing);
      expect(capture(tester).show(const PixivBookmarkFeedbackMessage.removed()),
          isTrue);
      await tester.pumpAndSettle();
      expectVisible(tester, '已取消收藏', const Size(375, 812));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    });
  }
}
