import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/pages/online_comic/pixiv_detail_pager.dart';
import 'package:picakeep/pages/online_comic/pixiv_detail_shell.dart';

Widget _testShell({
  required VoidCallback onReadFirst,
  required VoidCallback onReadSecond,
  required VoidCallback onFavorite,
  bool favoriteBusy = false,
  bool isFavorited = false,
  bool actionBusy = false,
  bool disableAnimations = false,
  VoidCallback? onAction,
  VoidCallback? onActionLongPress,
  VoidCallback? onFavoriteLongPress,
  List<PixivDetailImage>? images,
  List<Widget>? slivers,
  String title = '测试作品',
}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data:
          MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
      child: child!,
    ),
    home: PixivDetailShell(
      title: title,
      author: '测试作者',
      images: images ??
          <PixivDetailImage>[
            PixivDetailImage(
              key: 'first',
              provider: null,
              aspectRatio: 1,
              onRead: onReadFirst,
            ),
            PixivDetailImage(
              key: 'second',
              provider: null,
              aspectRatio: 1.5,
              onRead: onReadSecond,
            ),
          ],
      actionLabel: '下载',
      actionIcon: Icons.download_outlined,
      actionBusy: actionBusy,
      onAction: onAction,
      onActionLongPress: onActionLongPress,
      onFavorite: onFavorite,
      onFavoriteLongPress: onFavoriteLongPress,
      favoriteBusy: favoriteBusy,
      isFavorited: isFavorited,
      sliversBuilder: (context) =>
          slivers ??
          <Widget>[
            const SliverToBoxAdapter(
              key: ValueKey('pixiv-test-details'),
              child: SizedBox(height: 240, child: Text('作品信息')),
            ),
            const PixivDetailFavoriteBoundary(),
            const SliverToBoxAdapter(
              key: ValueKey('pixiv-test-author'),
              child: SizedBox(height: 240, child: Text('作者卡')),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 900)),
          ],
    ),
  );
}

void _mobileView(WidgetTester tester, {double height = 800}) {
  tester.view.physicalSize = Size(400, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder get _page => find.byKey(const ValueKey('pixiv-detail-page-scroll'));
Finder _image(String key) => find.byKey(ValueKey('pixiv-image-$key'));
Finder _aspectRatio(String key) =>
    find.descendant(of: _image(key), matching: find.byType(AspectRatio));

ScrollPosition _scrollPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
        find.descendant(of: _page, matching: find.byType(Scrollable)))
    .position;

Future<void> _loadMaterialIconsForScreenshot() async {
  for (final path in [
    'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
    'build/flutter_assets/fonts/MaterialIcons-Regular.otf',
  ]) {
    try {
      final bytes = await File(path).readAsBytes();
      await (FontLoader('MaterialIcons')
            ..addFont(Future.value(ByteData.sublistView(bytes))))
          .load();
      return;
    } catch (_) {
      // The test binding can already have the Material icon font registered.
    }
  }
}

Future<String?> _loadBodyFontForScreenshot() async {
  final windows = Platform.environment['WINDIR'];
  if (windows == null) return null;
  for (final name in ['msyh.ttc', 'simhei.ttf']) {
    try {
      final bytes = await File('$windows/Fonts/$name').readAsBytes();
      await (FontLoader('PixivFixtureBody')
            ..addFont(Future.value(ByteData.sublistView(bytes))))
          .load();
      return 'PixivFixtureBody';
    } catch (_) {
      // Screenshot text uses the default font where these fonts are unavailable.
    }
  }
  return null;
}

void main() {
  testWidgets('one scroll page lays images before ordinary detail content',
      (tester) async {
    _mobileView(tester, height: 1400);
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(_testShell(
      onReadFirst: () {},
      onReadSecond: () {},
      onFavorite: () {},
    ));
    await tester.pumpAndSettle();

    expect(_page, findsOneWidget);
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(find.byType(ListView), findsNothing);
    expect(find.descendant(of: _page, matching: find.byType(Scrollable)),
        findsOneWidget);

    final first = tester.getRect(_aspectRatio('first'));
    final second = tester.getRect(_aspectRatio('second'));
    final title = tester.getRect(find.text('测试作品'));
    final details = tester.getRect(find.text('作品信息'));
    expect(first.top, closeTo(24, .01));
    expect(first.height, closeTo(400, .01));
    expect(second.top, closeTo(first.bottom, .01));
    expect(second.height, closeTo(400 / 1.5, .01));
    expect(title.top, greaterThanOrEqualTo(second.bottom));
    expect(details.top, greaterThan(title.top));
    expect(find.byTooltip('下载'), findsOneWidget);

    final titleTop = title.top;
    _scrollPosition(tester).jumpTo(40);
    await tester.pump();
    expect(tester.getTopLeft(find.text('测试作品')).dy, closeTo(titleTop - 40, .1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a held vertical drag continues through the image and details',
      (tester) async {
    _mobileView(tester);
    await tester.pumpWidget(_testShell(
      onReadFirst: () {},
      onReadSecond: () {},
      onFavorite: () {},
    ));
    await tester.pumpAndSettle();
    final position = _scrollPosition(tester);
    final gesture = await tester.startGesture(const Offset(180, 300));
    await gesture.moveBy(const Offset(0, -420));
    await tester.pump(const Duration(milliseconds: 16));
    final firstOffset = position.pixels;
    expect(firstOffset, greaterThan(100));
    await gesture.moveBy(const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 16));
    expect(position.pixels, greaterThan(firstOffset + 200));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final ratio in [2.0, .5]) {
    testWidgets('image ratio $ratio keeps natural size below the safe top',
        (tester) async {
      _mobileView(tester);
      tester.view.padding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.resetPadding);
      await tester.pumpWidget(_testShell(
        onReadFirst: () {},
        onReadSecond: () {},
        onFavorite: () {},
        images: [
          PixivDetailImage(
              key: 'aligned',
              provider: null,
              aspectRatio: ratio,
              onRead: () {}),
        ],
      ));
      await tester.pumpAndSettle();
      final image = tester.getRect(_aspectRatio('aligned'));
      expect(image.top, closeTo(24, .01));
      expect(image.left, closeTo(0, .01));
      expect(image.width, closeTo(400, .01));
      expect(image.height, closeTo(400 / ratio, .01));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'multi-image scrolling updates the counter and taps read that page',
      (tester) async {
    _mobileView(tester);
    var firstReads = 0;
    var secondReads = 0;
    await tester.pumpWidget(_testShell(
      onReadFirst: () => firstReads++,
      onReadSecond: () => secondReads++,
      onFavorite: () {},
    ));
    await tester.pumpAndSettle();

    expect(find.text('1 / 2'), findsOneWidget);
    _scrollPosition(tester).jumpTo(410);
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.tap(_image('second'));
    await tester.pump();
    expect(firstReads, 0);
    expect(secondReads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('toolbar and favorite stay anchored while the page scrolls',
      (tester) async {
    _mobileView(tester);
    await tester.pumpWidget(_testShell(
      onReadFirst: () {},
      onReadSecond: () {},
      onFavorite: () {},
    ));
    await tester.pumpAndSettle();

    final back = find.byTooltip('返回');
    final counter = find.byKey(const ValueKey('pixiv-image-counter'));
    final favorite = find.byKey(const ValueKey('pixiv-detail-favorite'));
    final backTop = tester.getTopLeft(back).dy;
    final counterTop = tester.getTopLeft(counter).dy;
    final favoriteRect = tester.getRect(favorite);
    _scrollPosition(tester).jumpTo(50);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(back).dy, closeTo(backTop, .1));
    expect(tester.getTopLeft(counter).dy, closeTo(counterTop, .1));
    expect(tester.getRect(favorite), favoriteRect);
  });

  testWidgets('width changes update the image counter without a new drag',
      (tester) async {
    _mobileView(tester);
    await tester.pumpWidget(_testShell(
      onReadFirst: () {},
      onReadSecond: () {},
      onFavorite: () {},
    ));
    await tester.pumpAndSettle();
    _scrollPosition(tester).jumpTo(410);
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    tester.view.physicalSize = const Size(800, 800);
    await tester.pumpAndSettle();
    expect(_scrollPosition(tester).pixels, closeTo(410, .1));
    expect(find.text('1 / 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('favorite busy state stays visible, translucent, and disabled',
      (tester) async {
    _mobileView(tester);
    var favoriteCalls = 0;
    var actionCalls = 0;
    await tester.pumpWidget(_testShell(
      favoriteBusy: true,
      onReadFirst: () {},
      onReadSecond: () {},
      onFavorite: () => favoriteCalls++,
      onAction: () => actionCalls++,
    ));
    await tester.pumpAndSettle();
    final favorite = find.byKey(const ValueKey('pixiv-detail-favorite'));
    final icon = tester.widget<Icon>(
        find.descendant(of: favorite, matching: find.byIcon(Icons.favorite)));
    expect(icon.color?.a, closeTo(.5, .02));
    expect(
        tester
            .widget<AnimatedOpacity>(
                find.byKey(const ValueKey('pixiv-detail-favorite-opacity')))
            .opacity,
        1);
    expect(
        tester
            .widget<AbsorbPointer>(find.descendant(
                of: find
                    .byKey(const ValueKey('pixiv-detail-favorite-hit-test')),
                matching: find.byType(AbsorbPointer)))
            .absorbing,
        isTrue);
    expect(
        tester
            .getRect(find.byTooltip('下载'))
            .contains(tester.getCenter(favorite)),
        isTrue);
    await tester.tap(favorite, warnIfMissed: false);
    await tester.pump();
    expect(favoriteCalls, 0);
    expect(actionCalls, 0);
  });

  testWidgets('favorite hides at the author boundary and returns above it',
      (tester) async {
    _mobileView(tester);
    await tester.pumpWidget(_testShell(
      onReadFirst: () {},
      onReadSecond: () {},
      onFavorite: () {},
    ));
    await tester.pumpAndSettle();
    final position = _scrollPosition(tester);
    final scale = find.byKey(const ValueKey('pixiv-detail-favorite-scale'));
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(scale).scale, 0);
    expect(tester.widget<AnimatedScale>(scale).alignment, Alignment.center);
    expect(
        tester
            .widget<IgnorePointer>(
                find.byKey(const ValueKey('pixiv-detail-favorite-hit-test')))
            .ignoring,
        isTrue);
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(scale).scale, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one pointer keeps scrolling while favorite hides and returns',
      (tester) async {
    _mobileView(tester);
    await tester.pumpWidget(_testShell(
      onReadFirst: () {},
      onReadSecond: () {},
      onFavorite: () {},
    ));
    await tester.pumpAndSettle();
    final position = _scrollPosition(tester);
    final scale = find.byKey(const ValueKey('pixiv-detail-favorite-scale'));
    position.jumpTo(250);
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(scale).scale, 1);
    final gesture = await tester.startGesture(const Offset(180, 650));
    await gesture.moveBy(const Offset(0, -300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final hiddenOffset = position.pixels;
    expect(tester.widget<AnimatedScale>(scale).scale, 0);
    await gesture.moveBy(const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 16));
    expect(position.pixels, greaterThan(hiddenOffset + 170));
    await gesture.moveBy(const Offset(0, 600));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final returnedOffset = position.pixels;
    expect(returnedOffset, lessThan(200));
    expect(tester.widget<AnimatedScale>(scale).scale, 1);
    await gesture.moveBy(const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 16));
    expect(position.pixels, greaterThan(returnedOffset + 370));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('busy favorite remains visible after the author boundary',
      (tester) async {
    _mobileView(tester);
    await tester.pumpWidget(_testShell(
      favoriteBusy: true,
      onReadFirst: () {},
      onReadSecond: () {},
      onFavorite: () {},
    ));
    await tester.pumpAndSettle();
    _scrollPosition(tester).jumpTo(_scrollPosition(tester).maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<AnimatedScale>(
                find.byKey(const ValueKey('pixiv-detail-favorite-scale')))
            .scale,
        1);
    expect(
        tester
            .widget<AbsorbPointer>(find.descendant(
                of: find
                    .byKey(const ValueKey('pixiv-detail-favorite-hit-test')),
                matching: find.byType(AbsorbPointer)))
            .absorbing,
        isTrue);
  });

  testWidgets('reduced motion heart visibility changes without an animation',
      (tester) async {
    _mobileView(tester);
    await tester.pumpWidget(_testShell(
      disableAnimations: true,
      onReadFirst: () {},
      onReadSecond: () {},
      onFavorite: () {},
    ));
    await tester.pumpAndSettle();
    _scrollPosition(tester).jumpTo(_scrollPosition(tester).maxScrollExtent);
    await tester.pump();
    await tester.pump();
    final scale = tester.widget<AnimatedScale>(
        find.byKey(const ValueKey('pixiv-detail-favorite-scale')));
    final opacity = tester.widget<AnimatedOpacity>(
        find.byKey(const ValueKey('pixiv-detail-favorite-opacity')));
    expect(scale.duration, Duration.zero);
    expect(scale.scale, 0);
    expect(scale.alignment, Alignment.center);
    expect(opacity.duration, Duration.zero);
    expect(opacity.opacity, 0);
    expect(tester.takeException(), isNull);
  });

  for (final saved in [false, true]) {
    testWidgets('settled favorite restores actual saved state $saved',
        (tester) async {
      _mobileView(tester);
      var favorites = 0;
      await tester.pumpWidget(_testShell(
        favoriteBusy: true,
        isFavorited: !saved,
        onReadFirst: () {},
        onReadSecond: () {},
        onFavorite: () => favorites++,
      ));
      await tester.pumpAndSettle();
      final favorite = find.byKey(const ValueKey('pixiv-detail-favorite'));
      await tester.tap(favorite, warnIfMissed: false);
      expect(favorites, 0);
      await tester.pumpWidget(_testShell(
        isFavorited: saved,
        onReadFirst: () {},
        onReadSecond: () {},
        onFavorite: () => favorites++,
      ));
      await tester.pumpAndSettle();
      final icon = tester.widget<Icon>(find.descendant(
          of: favorite,
          matching:
              find.byIcon(saved ? Icons.favorite : Icons.favorite_border)));
      expect(icon.color?.a, greaterThan(.5));
      await tester.tap(favorite);
      await tester.pump();
      expect(favorites, 1);
    });
  }

  testWidgets('reading and action taps and long press keep their commands',
      (tester) async {
    _mobileView(tester);
    var reads = 0;
    var actions = 0;
    var longActions = 0;
    await tester.pumpWidget(_testShell(
      onReadFirst: () => reads++,
      onReadSecond: () {},
      onFavorite: () {},
      onAction: () => actions++,
      onActionLongPress: () => longActions++,
    ));
    await tester.pumpAndSettle();
    await tester.tap(_image('first'));
    await tester.pump();
    expect(reads, 1);
    _scrollPosition(tester).jumpTo(410);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下载'));
    await tester.pump();
    await tester.longPress(find.byTooltip('下载'));
    await tester.pumpAndSettle();
    expect(actions, 1);
    expect(longActions, 1);
    await tester.pumpWidget(_testShell(
      actionBusy: true,
      onReadFirst: () => reads++,
      onReadSecond: () {},
      onFavorite: () {},
      onAction: () => actions++,
      onActionLongPress: () => longActions++,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下载'));
    await tester.longPress(find.byTooltip('下载'));
    await tester.pumpAndSettle();
    expect(actions, 1);
    expect(longActions, 1);
  });

  testWidgets('outer detail pager still accepts horizontal work swipes',
      (tester) async {
    _mobileView(tester);
    var firstReads = 0;
    var secondReads = 0;
    Widget work(String id) => _testShell(
          title: '作品$id',
          onReadFirst: () => firstReads++,
          onReadSecond: () => secondReads++,
          onFavorite: () {},
        );
    final session = PixivDetailSession(
      scope: PixivDetailScope.search,
      entries: [
        PixivDetailEntry(key: 'a', comicId: '1', builder: (_) => work('1')),
        PixivDetailEntry(key: 'b', comicId: '2', builder: (_) => work('2')),
      ],
    );
    await tester.pumpWidget(
        MaterialApp(home: PixivDetailPager(session: session, initialKey: 'a')));
    await tester.pumpAndSettle();
    await tester.drag(_image('first'), const Offset(-350, 0));
    await tester.pumpAndSettle();
    final pager =
        tester.widget<PageView>(find.byKey(const Key('pixiv-work-pager')));
    expect(pager.controller!.page, closeTo(1, .001));
    expect(firstReads + secondReads, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });

  for (final delta in [const Offset(0, -230), const Offset(-35, -230)]) {
    testWidgets('vertical dominant work gesture $delta stays in current work',
        (tester) async {
      _mobileView(tester);
      var reads = 0;
      Widget work() => (_testShell(
            onReadFirst: () => reads++,
            onReadSecond: () => reads++,
            onFavorite: () {},
          ) as MaterialApp)
              .home!;
      final session = PixivDetailSession(
        scope: PixivDetailScope.search,
        entries: [
          PixivDetailEntry(key: 'a', comicId: '1', builder: (_) => work()),
          PixivDetailEntry(key: 'b', comicId: '2', builder: (_) => work()),
        ],
      );
      await tester.pumpWidget(MaterialApp(
          home: PixivDetailPager(session: session, initialKey: 'a')));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(180, 300), delta);
      await tester.pumpAndSettle();
      final pager =
          tester.widget<PageView>(find.byKey(const Key('pixiv-work-pager')));
      expect(pager.controller!.page, closeTo(0, .001));
      final page = find.byKey(const ValueKey('pixiv-detail-page-scroll')).first;
      final position = tester
          .state<ScrollableState>(
              find.descendant(of: page, matching: find.byType(Scrollable)))
          .position;
      expect(position.pixels, greaterThan(100));
      expect(reads, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    });
  }

  testWidgets('next-image toolbar advances the main scroll and cycles back',
      (tester) async {
    _mobileView(tester);
    await tester.pumpWidget(_testShell(
      onReadFirst: () {},
      onReadSecond: () {},
      onFavorite: () {},
    ));
    await tester.pumpAndSettle();
    final next = find.byTooltip('下一张图片');
    final position = _scrollPosition(tester);
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(400, .1));
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(0, .1));
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.byType(CustomScrollView), findsOneWidget);
  });

  testWidgets('narrow short viewport and large font keep controls in bounds',
      (tester) async {
    _mobileView(tester);
    tester.view.physicalSize = const Size(280, 300);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
    addTearDown(tester.view.resetPadding);
    final fixture = _testShell(
      title: '长标题与更多文字用于窄屏详情布局测试',
      onReadFirst: () {},
      onReadSecond: () {},
      onFavorite: () {},
    ) as MaterialApp;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.8)),
        child: child!,
      ),
      home: fixture.home,
    ));
    await tester.pumpAndSettle();
    final position = _scrollPosition(tester);
    position.jumpTo(320);
    await tester.pumpAndSettle();
    final favorite =
        tester.getRect(find.byKey(const ValueKey('pixiv-detail-favorite')));
    expect(favorite.right, lessThanOrEqualTo(280));
    expect(favorite.left, greaterThanOrEqualTo(0));
    expect(favorite.top, greaterThanOrEqualTo(24));
    expect(favorite.bottom, lessThanOrEqualTo(284));
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('viewport trigger remains lazy and fires once after entry',
      (tester) async {
    _mobileView(tester);
    var visibleCalls = 0;
    await tester.pumpWidget(_testShell(
      onReadFirst: () {},
      onReadSecond: () {},
      onFavorite: () {},
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 1000)),
        PixivDetailViewportTrigger(onVisible: () => visibleCalls++),
        const SliverToBoxAdapter(child: SizedBox(height: 1000)),
      ],
    ));
    await tester.pumpAndSettle();
    expect(visibleCalls, 0);
    final position = _scrollPosition(tester);
    position.jumpTo(1100);
    await tester.pumpAndSettle();
    expect(visibleCalls, 1);
    position.jumpTo(0);
    await tester.pumpAndSettle();
    position.jumpTo(1200);
    await tester.pumpAndSettle();
    expect(visibleCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'viewport trigger does not invoke a queued callback after dispose',
      (tester) async {
    _mobileView(tester);
    var visibleCalls = 0;
    await tester.pumpWidget(_testShell(
      onReadFirst: () {},
      onReadSecond: () {},
      onFavorite: () {},
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 200)),
        PixivDetailViewportTrigger(onVisible: () => visibleCalls++),
        const SliverToBoxAdapter(child: SizedBox(height: 1000)),
      ],
    ));
    await tester.pumpAndSettle();
    expect(visibleCalls, 0);
    final trigger =
        find.byType(PixivDetailViewportTrigger, skipOffstage: false);
    final context = tester.element(trigger);
    final layout = tester.widget<SliverLayoutBuilder>(find.descendant(
        of: trigger,
        matching: find.byType(SliverLayoutBuilder, skipOffstage: false),
        skipOffstage: false));
    // Queue the same deferred visibility callback that layout schedules, then
    // replace the page before its frame completes.
    layout.builder(
        context,
        const SliverConstraints(
          axisDirection: AxisDirection.down,
          growthDirection: GrowthDirection.forward,
          userScrollDirection: ScrollDirection.idle,
          scrollOffset: 0,
          precedingScrollExtent: 0,
          overlap: 0,
          remainingPaintExtent: 800,
          crossAxisExtent: 400,
          crossAxisDirection: AxisDirection.right,
          viewportMainAxisExtent: 800,
          remainingCacheExtent: 800,
          cacheOrigin: 0,
        ));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(visibleCalls, 0);
    expect(tester.takeException(), isNull);
  });

  const artwork = 'Z-plan/新需求-主线-第十九轮/'
      '006-附件-推荐页瀑布流预览/cover1_snowbird.png';
  testWidgets('decoded portrait artwork starts at the safe top edge',
      (tester) async {
    final bytes = await tester.runAsync(() => File(artwork).readAsBytes());
    expect(bytes, isNotNull);
    final provider = MemoryImage(bytes!);
    final ratio = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final value = frame.image.width / frame.image.height;
      frame.image.dispose();
      codec.dispose();
      return value;
    });
    _mobileView(tester);
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(_testShell(
      onReadFirst: () {},
      onReadSecond: () {},
      onFavorite: () {},
      images: [
        PixivDetailImage(
            key: 'decoded',
            provider: provider,
            aspectRatio: ratio!,
            onRead: () {}),
      ],
    ));
    await tester.pumpAndSettle();
    await tester.runAsync(
        () => precacheImage(provider, tester.element(_image('decoded'))));
    await tester.pumpAndSettle();
    final image =
        find.descendant(of: _image('decoded'), matching: find.byType(Image));
    expect(tester.getRect(image).top, closeTo(24, .01));
    expect(tester.getRect(image).left, closeTo(0, .01));
    expect(tester.takeException(), isNull);
  }, skip: !File(artwork).existsSync());

  testWidgets(
      'captures continuous initial information and author portrait views',
      (tester) async {
    _mobileView(tester);
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.resetPadding);
    final oldShadows = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = oldShadows);
    final bodyFont = await tester.runAsync(_loadBodyFontForScreenshot);
    final bytes = await tester.runAsync(() => File(artwork).readAsBytes());
    expect(bytes, isNotNull);
    final provider = MemoryImage(bytes!);
    final ratio = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final value = frame.image.width / frame.image.height;
      frame.image.dispose();
      codec.dispose();
      return value;
    });
    final boundaryKey = GlobalKey();
    final fixture = _testShell(
      onReadFirst: () {},
      onReadSecond: () {},
      onFavorite: () {},
      onAction: () {},
      isFavorited: true,
      images: [
        PixivDetailImage(
            key: 'portrait',
            provider: provider,
            aspectRatio: ratio!,
            onRead: () {}),
      ],
      slivers: [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(spacing: 16, runSpacing: 8, children: [
                  Text('2026-10-02 15:31'),
                  Text('361 阅读'),
                  Text('23 喜欢'),
                ]),
                SizedBox(height: 16),
                Wrap(spacing: 24, runSpacing: 12, children: [
                  Text('#插画'),
                  Text('#作品'),
                  Text('#测试标签'),
                ]),
                SizedBox(height: 40),
                Text('作品说明'),
                SizedBox(height: 24),
              ],
            ),
          ),
        ),
        const PixivDetailFavoriteBoundary(),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              Row(children: [
                CircleAvatar(backgroundImage: provider),
                const SizedBox(width: 12),
                const Expanded(child: Text('测试作者')),
                FilledButton(onPressed: () {}, child: const Text('加关注')),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                for (var index = 0; index < 3; index++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: Image(image: provider, fit: BoxFit.cover),
                      ),
                    ),
                  ),
              ]),
              const SizedBox(height: 12),
              TextButton(onPressed: () {}, child: const Text('查看个人简介')),
            ]),
          ),
        ),
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('评论', style: TextStyle(fontSize: 20)),
              SizedBox(height: 24),
              Center(child: Text('暂无评论')),
              SizedBox(height: 300),
            ]),
          ),
        ),
      ],
    ) as MaterialApp;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: bodyFont),
      home: RepaintBoundary(key: boundaryKey, child: fixture.home!),
    ));
    await tester.runAsync(_loadMaterialIconsForScreenshot);
    await tester.runAsync(() => precacheImage(provider, tester.element(_page)));
    final portrait = tester.widget<Image>(
        find.descendant(of: _image('portrait'), matching: find.byType(Image)));
    await tester
        .runAsync(() => precacheImage(portrait.image, tester.element(_page)));
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      final boundary = boundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      if (name == 'initial') {
        final pixels = (await image.toByteData())!.buffer.asUint8List();
        final sample = (40 * image.width + 40) * 4;
        expect(pixels[sample + 3], 255);
        expect(pixels[sample] + pixels[sample + 1] + pixels[sample + 2],
            lessThan(700),
            reason: 'Portrait pixels start directly below the status area.');
      }
      final imageData =
          (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final target = File('build/verification/pixiv-detail-025/$name.png');
      await target.parent.create(recursive: true);
      await target.writeAsBytes(imageData.buffer.asUint8List());
      image.dispose();
    }

    await tester.runAsync(() => capture('initial'));
    _scrollPosition(tester).jumpTo((400 / ratio - 350).clamp(0, 10000));
    await tester.pumpAndSettle();
    await tester.runAsync(() => capture('information'));
    _scrollPosition(tester).jumpTo(400 / ratio + 120);
    await tester.pumpAndSettle();
    await tester.runAsync(() => capture('author'));
    debugDisableShadows = oldShadows;
    expect(tester.takeException(), isNull);
  }, skip: !File(artwork).existsSync());
}
