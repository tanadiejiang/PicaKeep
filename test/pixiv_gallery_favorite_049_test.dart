import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/components/pixiv_bookmark_button.dart';
import 'package:picakeep/pages/online_comic/pixiv_detail_shell.dart';

const _output = 'docs/verification/pixiv-ui-050/049-regression/gallery';
const _main = ValueKey('pixiv-detail-page-scroll');
const _head = ValueKey('pixiv-gallery-header');
const _cluster = ValueKey('pixiv-author-header-cluster');
const _panel = ValueKey('pixiv-detail-panel');
const _panelToggle = ValueKey('pixiv-detail-panel-toggle');
const _inline = ValueKey('pixiv-inline-details');
const _favorite = ValueKey('pixiv-detail-favorite');
const _opacity = ValueKey('pixiv-detail-favorite-opacity');
const _scale = ValueKey('pixiv-detail-favorite-scale');
const _hit = ValueKey('pixiv-detail-favorite-hit-test');
const _author = ValueKey('049-body-author');
const _ratios = [1.0, .5, 1.5];
const _descriptionHeight = 160.0;

class _DenyHttp extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('049 gallery fixtures forbid HTTP');
  }
}

class _Fixture extends StatefulWidget {
  const _Fixture({
    super.key,
    required this.providers,
    this.saved = false,
    this.busy = false,
    this.longText = false,
    this.online = true,
    this.ratios = _ratios,
  });
  final List<MemoryImage> providers;
  final bool saved, busy, longText, online;
  final List<double> ratios;
  @override
  State<_Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<_Fixture> {
  late bool saved = widget.saved, busy = widget.busy;
  int taps = 0, longPresses = 0, downloads = 0, imageReads = 0;
  int sequence = 0;
  PixivBookmarkEvent? event;
  final transitions = <bool>[];

  void setBookmark({required bool isSaved, required bool isBusy}) =>
      setState(() {
        saved = isSaved;
        busy = isBusy;
      });

  void begin(bool target) => setState(() {
        busy = true;
        event = PixivBookmarkEvent(
            sequence: ++sequence,
            operationId: 1,
            phase: PixivBookmarkPhase.begin,
            target: target);
      });

  void settle(bool target) => setState(() {
        saved = target;
        busy = false;
        event = PixivBookmarkEvent(
            sequence: ++sequence,
            operationId: 1,
            phase: PixivBookmarkPhase.settle,
            target: target);
      });

  @override
  Widget build(BuildContext context) => PixivDetailShell(
        title: widget.longText
            ? List.filled(5, '049长标题与固定收藏位置').join()
            : '049 离线多图 · 固定悬浮收藏',
        author: widget.longText ? List.filled(4, '离线画师长名字').join() : '离线画师049',
        galleryCollapsible: true,
        images: [
          for (var i = 0; i < widget.ratios.length; i++)
            PixivDetailImage(
                key: '049-page-$i',
                provider: widget.providers[i],
                aspectRatio: widget.ratios[i],
                onRead: () => imageReads++),
        ],
        actionLabel: '下载',
        actionIcon: Icons.download_outlined,
        onAction: () => downloads++,
        isFavorited: saved,
        favoriteBusy: busy,
        onlineBookmarkAnimations: widget.online,
        favoriteIdentity: const ('offline-account-049', '049-work'),
        favoriteEvent: event,
        favoriteLabel: saved ? '取消Pixiv收藏' : '加入Pixiv收藏',
        onFavorite: () => taps++,
        onFavoriteLongPress: () => longPresses++,
        onGalleryExpansionChanged: transitions.add,
        sliversBuilder: (_) => const [
          SliverToBoxAdapter(
              child: SizedBox(
                  height: _descriptionHeight,
                  child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('049 本地图片夹具，未联网、未操作真实账号。')))),
          PixivDetailFavoriteBoundary(),
          SliverToBoxAdapter(
              child: SizedBox(
                  key: _author,
                  height: 180,
                  child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('正文作者区域：保留原边界隐藏规则')))),
          SliverToBoxAdapter(child: SizedBox(height: 1200)),
        ],
      );
}

class _Harness {
  const _Harness(this.fixture, this.boundary, this.ratios);
  final GlobalKey<_FixtureState> fixture;
  final GlobalKey boundary;
  final List<double> ratios;
  _FixtureState get state => fixture.currentState!;
}

Future<void> _frames(WidgetTester tester, [int count = 3]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<_Harness> _mount(WidgetTester tester,
    {Size size = const Size(400, 800),
    double textScale = 1,
    bool dark = false,
    bool reduced = false,
    bool saved = false,
    bool busy = false,
    bool online = true,
    EdgeInsets padding = EdgeInsets.zero,
    List<double> ratios = _ratios}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await _fonts(tester);
  final providers = await _images(tester, ratios);
  final fixture = GlobalKey<_FixtureState>();
  final boundary = GlobalKey();
  await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
          fontFamily: 'GalleryCapture049',
          brightness: dark ? Brightness.dark : Brightness.light),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              padding: padding,
              textScaler: TextScaler.linear(textScale),
              disableAnimations: reduced),
          child: child!),
      home: RepaintBoundary(
          key: boundary,
          child: _Fixture(
              key: fixture,
              providers: providers,
              ratios: ratios,
              saved: saved,
              busy: busy,
              online: online,
              longText: textScale > 1))));
  await tester.runAsync(() async {
    final context = tester.element(find.byType(PixivDetailShell));
    for (final provider in providers) {
      await precacheImage(
          ResizeImage.resizeIfNeeded(
              (size.width * 1.2).round(), null, provider),
          context);
    }
  });
  await _frames(tester, 4);
  return _Harness(fixture, boundary, ratios);
}

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(
        of: find.byKey(_main), matching: find.byType(Scrollable)))
    .position;
ScrollController _controller(WidgetTester tester) =>
    tester.widget<CustomScrollView>(find.byKey(_main)).controller!;
Finder _headerCluster() =>
    find.descendant(of: find.byKey(_head), matching: find.byKey(_cluster));

double _galleryEnd(WidgetTester tester, _Harness harness) => harness.ratios
    .fold(0, (end, ratio) => end + tester.view.physicalSize.width / ratio);
double _dockPixels(WidgetTester tester, _Harness harness) =>
    _galleryEnd(tester, harness) -
    _position(tester).viewportDimension +
    tester.getSize(find.byKey(_head)).height;

double _bodyBoundaryPixels(WidgetTester tester, _Harness harness) {
  final positioned = tester.widget<Positioned>(find
      .ancestor(of: find.byKey(_favorite), matching: find.byType(Positioned))
      .first);
  return _galleryEnd(tester, harness) +
      tester.getSize(find.byKey(_head)).height +
      _descriptionHeight -
      _position(tester).viewportDimension +
      positioned.bottom! +
      56 +
      12 +
      60;
}

void _expectVisible(WidgetTester tester, bool visible) {
  expect(tester.widget<AnimatedOpacity>(find.byKey(_opacity)).opacity,
      visible ? 1 : 0);
  expect(
      tester.widget<AnimatedScale>(find.byKey(_scale)).scale, visible ? 1 : 0);
  expect(tester.widget<IgnorePointer>(find.byKey(_hit)).ignoring, !visible);
}

Rect _fixedRect(WidgetTester tester) => tester.getRect(find.byKey(_hit));

bool _hasBookmarkSemantics(WidgetTester tester) {
  var found = false;
  void visit(SemanticsNode node) {
    if (node.label.contains('平台收藏')) found = true;
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.getSemantics(find.byType(PixivDetailShell)));
  return found;
}

void _sameRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, .01));
  expect(actual.top, closeTo(expected.top, .01));
  expect(actual.width, closeTo(expected.width, .01));
  expect(actual.height, closeTo(expected.height, .01));
}

void _expectFixed(WidgetTester tester, Rect expected) {
  _sameRect(_fixedRect(tester), expected);
  expect(expected.size, const Size(56, 56));
  final positioned = tester.widget<Positioned>(find
      .ancestor(of: find.byKey(_favorite), matching: find.byType(Positioned))
      .first);
  expect(positioned.right, 16);
  final media = MediaQuery.of(tester.element(find.byType(PixivDetailShell)));
  final height = _position(tester).viewportDimension;
  final h = find.byKey(_head).evaluate().isEmpty
      ? tester
          .getSize(find.byKey(const ValueKey('pixiv-details-panel-header')))
          .height
      : tester.getSize(find.byKey(_head)).height;
  // The panel header uses the same extent; the outside SafeArea is unchanged.
  expect(
      positioned.bottom,
      closeTo(
          (height * .15).clamp(0, 80) < h + 8
              ? h + 8
              : (height * .15).clamp(0, 80),
          .01));
  expect(expected.right,
      closeTo(tester.view.physicalSize.width - media.padding.right - 16, .01));
}

Future<TestGesture> _enterEarlyHandoff(
    WidgetTester tester, _Harness harness) async {
  final position = _position(tester);
  final dock = _dockPixels(tester, harness);
  position.jumpTo(dock - 50);
  await _frames(tester);
  final gesture = await tester.startGesture(Offset(
      tester.view.physicalSize.width * .3,
      tester.view.physicalSize.height * .4));
  await gesture.moveBy(const Offset(0, -20));
  await _frames(tester, 2);
  for (var i = 0;
      i < 20 && find.byKey(_inline, skipOffstage: false).evaluate().isEmpty;
      i++) {
    await gesture.moveBy(const Offset(0, -4),
        timeStamp: Duration(milliseconds: 80 + i * 32));
    await _frames(tester, 2);
  }
  expect(find.byKey(_inline, skipOffstage: false), findsOneWidget);
  expect(harness.state.transitions.last, true);
  expect(position.pixels, greaterThanOrEqualTo(dock - 24.01));
  expect(position.pixels, lessThan(dock));
  final media = MediaQuery.of(tester.element(find.byType(PixivDetailShell)));
  expect(tester.getRect(find.byKey(_head)).bottom,
      closeTo(media.padding.top + position.viewportDimension, .01));
  _expectVisible(tester, true);
  return gesture;
}

Future<void> _release(WidgetTester tester, TestGesture gesture) async {
  await _frames(tester, 10);
  await gesture.up(timeStamp: const Duration(seconds: 2));
  await _frames(tester, 16);
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(_headerCluster());
  await tester.pump();
  await _frames(tester, 18);
  expect(find.byKey(_panel), findsOneWidget);
}

Future<void> _close(WidgetTester tester) async {
  await tester.tap(find.byKey(_panelToggle));
  await tester.pump();
  await _frames(tester, 14);
  expect(find.byKey(_panel), findsNothing);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousHttp = HttpOverrides.current;
  late _DenyHttp deny;
  setUp(() {
    deny = _DenyHttp();
    HttpOverrides.global = deny;
  });
  tearDown(() {
    expect(deny.attempts, 0);
    HttpOverrides.global = previousHttp;
  });

  testWidgets('049 top, middle page and parked details keep fixed online heart',
      (tester) async {
    final harness = await _mount(tester);
    final position = _position(tester);
    final controller = _controller(tester);
    final rect = _fixedRect(tester);
    _expectVisible(tester, true);
    _expectFixed(tester, rect);
    await _capture(tester, harness, deny, 'top', {'sameMainPosition': true});
    position.jumpTo(430);
    await _frames(tester, 16);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('pixiv-image-counter')))
            .data,
        '2 / 3');
    _expectVisible(tester, true);
    _expectFixed(tester, rect);
    await _capture(tester, harness, deny, 'middle-page', {});
    // Opening then closing creates the unique details tree in its zero-height
    // parked host. Its SliverLayoutBuilder can report a reached author boundary.
    final pixels = position.pixels;
    await _open(tester);
    _expectVisible(tester, true);
    await _close(tester);
    expect(find.byKey(const ValueKey('pixiv-detail-parked-scroll')),
        findsOneWidget);
    expect(position.pixels, closeTo(pixels, .01));
    expect(_position(tester), same(position));
    expect(_controller(tester), same(controller));
    _expectVisible(tester, true);
    _expectFixed(tester, rect);
    await tester.tap(find.byKey(_favorite));
    await tester.longPress(find.byKey(_favorite));
    await _frames(tester);
    expect(harness.state.taps, 1);
    expect(harness.state.longPresses, 1);
    expect(harness.state.downloads + harness.state.imageReads, 0);
    await _capture(tester, harness, deny, 'parked-after-panel', {
      'sameMainPosition': identical(position, _position(tester)),
      'restoredPixels': pixels,
      'tapCount': harness.state.taps,
      'longPressCount': harness.state.longPresses,
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '049 programmatic undock retains download hit and old overlap rule',
      (tester) async {
    final harness = await _mount(tester);
    final position = _position(tester);
    final rect = _fixedRect(tester);
    final headerHeight = tester.getSize(find.byKey(_head)).height;
    final target = _dockPixels(tester, harness) + headerHeight;
    position.jumpTo(target);
    await _frames(tester, 16);
    expect(harness.state.transitions, isEmpty);
    expect(find.byKey(_inline, skipOffstage: false), findsNothing);
    expect(
        find.byKey(const ValueKey('pixiv-detail-parked-scroll')), findsNothing);
    final download = find
        .descendant(
            of: find.descendant(
                of: find.byKey(_head), matching: find.byTooltip('下载')),
            matching: find.byType(InkWell))
        .first;
    final downloadRect = tester.getRect(download);
    expect(downloadRect.height, greaterThanOrEqualTo(48));
    expect(downloadRect.overlaps(rect), true);
    expect(rect.contains(downloadRect.center), true);
    _expectVisible(tester, false);
    _expectFixed(tester, rect);
    await tester.tap(download);
    await _frames(tester);
    expect(harness.state.downloads, 1);
    expect(harness.state.taps + harness.state.longPresses, 0);
    expect(harness.state.transitions, isEmpty);
    expect(position.pixels, closeTo(target, .01));
    expect(_position(tester), same(position));
    await _capture(tester, harness, deny, 'programmatic-undock-download', {
      'downloadRect': _rect(downloadRect),
      'downloadCount': harness.state.downloads,
      'sameMainPosition': identical(position, _position(tester)),
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('049 short gallery at top stays reachable without a details tail',
      (tester) async {
    final harness = await _mount(tester, ratios: const [4, 4, 4]);
    final position = _position(tester);
    final rect = _fixedRect(tester);
    final headerHeight = tester.getSize(find.byKey(_head)).height;
    expect(_galleryEnd(tester, harness),
        lessThan(position.viewportDimension - headerHeight));
    expect(position.pixels, 0);
    expect(position.maxScrollExtent, 0);
    expect(find.byKey(_inline, skipOffstage: false), findsNothing);
    expect(
        find.byKey(const ValueKey('pixiv-detail-parked-scroll')), findsNothing);
    expect(harness.state.transitions, isEmpty);
    _expectVisible(tester, true);
    _expectFixed(tester, rect);
    await tester.tap(find.byKey(_favorite));
    await tester.longPress(find.byKey(_favorite));
    await _frames(tester);
    expect(harness.state.taps, 1);
    expect(harness.state.longPresses, 1);
    expect(harness.state.downloads + harness.state.imageReads, 0);
    await _capture(tester, harness, deny, 'short-gallery-top', {
      'noRemoteTail': true,
      'sameMainPosition': identical(position, _position(tester)),
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('049 short undocked top keeps overlap protection for download',
      (tester) async {
    final harness =
        await _mount(tester, ratios: const [20 / 11, 20 / 11, 20 / 11]);
    await _frames(tester, 16);
    final position = _position(tester);
    final rect = _fixedRect(tester);
    final headerHeight = tester.getSize(find.byKey(_head)).height;
    expect(_galleryEnd(tester, harness), closeTo(660, .01));
    expect(position.pixels, 0);
    expect(tester.getRect(find.byKey(_head)).top,
        lessThan(position.viewportDimension - headerHeight));
    expect(harness.state.transitions, isEmpty);
    expect(find.byKey(_inline, skipOffstage: false), findsNothing);
    final download = find
        .descendant(
            of: find.descendant(
                of: find.byKey(_head), matching: find.byTooltip('下载')),
            matching: find.byType(InkWell))
        .first;
    final downloadRect = tester.getRect(download);
    expect(downloadRect.height, greaterThanOrEqualTo(48));
    expect(downloadRect.overlaps(rect), true);
    expect(rect.contains(downloadRect.center), true);
    _expectVisible(tester, false);
    _expectFixed(tester, rect);
    await tester.tap(download);
    await _frames(tester);
    expect(harness.state.downloads, 1);
    expect(harness.state.taps + harness.state.longPresses, 0);
    expect(harness.state.transitions, isEmpty);
    expect(position.pixels, 0);
    expect(_position(tester), same(position));
    await _capture(
        tester, harness, deny, 'short-gallery-top-overlap-download', {
      'downloadRect': _rect(downloadRect),
      'downloadCount': harness.state.downloads,
      'sameMainPosition': identical(position, _position(tester)),
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('049 early handoff stays visible until dock actually leaves',
      (tester) async {
    final harness = await _mount(tester);
    final position = _position(tester);
    final rect = _fixedRect(tester);
    final gesture = await _enterEarlyHandoff(tester, harness);
    await _capture(tester, harness, deny, 'early-handoff-docked', {
      'handoffPreparedWhileDocked': true,
      'dockPixels': _dockPixels(tester, harness),
    });
    await _release(tester, gesture);
    _expectFixed(tester, rect);
    // Inline is already mounted, but the header has not left its dock yet.
    position.jumpTo(_dockPixels(tester, harness));
    await _frames(tester, 16);
    _expectVisible(tester, true);
    _expectFixed(tester, rect);
    await _capture(tester, harness, deny, 'exact-dock-edge', {});
    position.jumpTo(_bodyBoundaryPixels(tester, harness));
    await _frames(tester, 16);
    _expectVisible(tester, false);
    _expectFixed(tester, rect);
    expect(tester.getRect(find.byKey(_author)).top, lessThan(rect.top - 12));
    await _capture(tester, harness, deny, 'inline-author-hidden', {});
    // Return while inline is still mounted: the stale author boundary must not
    // suppress a geometrically docked gallery. Then real reverse input parks it.
    position.jumpTo(_dockPixels(tester, harness) - 8);
    await _frames(tester, 16);
    expect(find.byKey(_inline, skipOffstage: false), findsOneWidget);
    _expectVisible(tester, true);
    _expectFixed(tester, rect);
    final reverse = await tester.startGesture(const Offset(110, 350));
    await reverse.moveBy(const Offset(0, 20));
    await _frames(tester, 2);
    await reverse.moveBy(const Offset(0, 130),
        timeStamp: const Duration(milliseconds: 64));
    await _frames(tester, 4);
    expect(position.pixels + position.viewportDimension,
        lessThanOrEqualTo(_galleryEnd(tester, harness)));
    expect(harness.state.transitions.last, false);
    await _release(tester, reverse);
    expect(find.byKey(_inline, skipOffstage: false), findsNothing);
    _expectVisible(tester, true);
    _expectFixed(tester, rect);
    expect(_position(tester), same(position));
    await _capture(tester, harness, deny, 'reverse-gallery', {});
    expect(tester.takeException(), isNull);
  });

  for (final origin in ['gallery', 'inline']) {
    testWidgets(
        '049 panel closes to exact $origin mode and favorite visibility',
        (tester) async {
      final harness = await _mount(tester);
      final position = _position(tester);
      final controller = _controller(tester);
      final rect = _fixedRect(tester);
      if (origin == 'inline') {
        final gesture = await _enterEarlyHandoff(tester, harness);
        await _release(tester, gesture);
        position.jumpTo(_dockPixels(tester, harness) + 130);
        await _frames(tester, 16);
        _expectVisible(tester, false);
      } else {
        position.jumpTo(350);
        await _frames(tester);
        _expectVisible(tester, true);
      }
      final pixels = position.pixels;
      await _open(tester);
      _expectVisible(tester, true);
      _sameRect(_fixedRect(tester), rect);
      expect(position.pixels, closeTo(pixels, .01));
      await _capture(tester, harness, deny, 'panel-$origin', {});
      await _close(tester);
      expect(position.pixels, closeTo(pixels, .01));
      expect(_position(tester), same(position));
      expect(_controller(tester), same(controller));
      expect(find.byKey(_inline, skipOffstage: false),
          origin == 'inline' ? findsOneWidget : findsNothing);
      _expectVisible(tester, origin == 'gallery');
      _sameRect(_fixedRect(tester), rect);
      await _capture(tester, harness, deny, 'panel-restored-$origin', {
        'restoredMode': origin,
        'restoredPixels': pixels,
        'sameMainPosition': identical(position, _position(tester)),
      });
      expect(tester.takeException(), isNull);
    });
  }

  for (final saved in [false, true]) {
    testWidgets('049 saved=$saved busy online heart keeps action and semantics',
        (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final harness = await _mount(tester, saved: saved, busy: true);
        final rect = _fixedRect(tester);
        _expectVisible(tester, true);
        final button =
            tester.widget<PixivBookmarkButton>(find.byKey(_favorite));
        expect(button.size, 56);
        expect(button.iconSize, 28);
        expect(button.isBookmarked, saved);
        expect(button.busy, true);
        expect(button.circularBackground, true);
        expect(button.activeColor, const Color(0xE6E0245E));
        await tester.tap(find.byKey(_favorite), warnIfMissed: false);
        await tester.longPress(find.byKey(_favorite), warnIfMissed: false);
        expect(harness.state.taps + harness.state.longPresses, 0);
        final busySemantics = tester.getSemantics(find.byKey(_favorite));
        expect(
            busySemantics.getSemanticsData().hasAction(ui.SemanticsAction.tap),
            false);
        harness.state.setBookmark(isSaved: saved, isBusy: false);
        await _frames(tester, 16);
        _expectVisible(tester, true);
        expect(
            find.bySemanticsLabel(saved ? '取消平台收藏' : '加入平台收藏'), findsOneWidget);
        final data =
            tester.getSemantics(find.byKey(_favorite)).getSemanticsData();
        expect(data.hasAction(ui.SemanticsAction.tap), true);
        expect(data.hasAction(ui.SemanticsAction.longPress), true);
        await tester.tap(find.byKey(_favorite));
        await tester.longPress(find.byKey(_favorite));
        await _frames(tester);
        expect(harness.state.taps, 1);
        expect(harness.state.longPresses, 1);
        expect(harness.state.imageReads + harness.state.downloads, 0);
        _sameRect(_fixedRect(tester), rect);
        await _capture(tester, harness, deny, 'saved-$saved', {});
        final gesture = await _enterEarlyHandoff(tester, harness);
        await _release(tester, gesture);
        _position(tester).jumpTo(_bodyBoundaryPixels(tester, harness));
        await _frames(tester, 16);
        _expectVisible(tester, false);
        expect(_hasBookmarkSemantics(tester), false);
        harness.state.setBookmark(isSaved: saved, isBusy: true);
        await _frames(tester, 16);
        _expectVisible(tester, true);
        await tester.tap(find.byKey(_favorite), warnIfMissed: false);
        expect(harness.state.taps, 1);
        harness.state.setBookmark(isSaved: saved, isBusy: false);
        await _frames(tester, 16);
        _expectVisible(tester, false);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  for (final spec in [
    (
      name: 'safe-area',
      size: const Size(400, 900),
      scale: 1.0,
      padding: const EdgeInsets.only(top: 24, bottom: 34),
      dark: false
    ),
    (
      name: 'narrow-large',
      size: const Size(240, 850),
      scale: 2.0,
      padding: const EdgeInsets.only(top: 24, bottom: 34),
      dark: true
    ),
    (
      name: 'landscape',
      size: const Size(812, 375),
      scale: 1.0,
      padding: const EdgeInsets.only(top: 12, bottom: 16),
      dark: false
    ),
  ]) {
    testWidgets('049 ${spec.name} retains fixed safe reachable gallery heart',
        (tester) async {
      final harness = await _mount(tester,
          size: spec.size,
          textScale: spec.scale,
          padding: spec.padding,
          dark: spec.dark);
      final position = _position(tester);
      final rect = _fixedRect(tester);
      _expectVisible(tester, true);
      _expectFixed(tester, rect);
      expect(rect.top, greaterThanOrEqualTo(spec.padding.top));
      expect(rect.bottom,
          lessThanOrEqualTo(spec.size.height - spec.padding.bottom));
      final gesture = await _enterEarlyHandoff(tester, harness);
      await _release(tester, gesture);
      _expectVisible(tester, true);
      _expectFixed(tester, rect);
      await tester.tap(find.byKey(_favorite));
      await tester.longPress(find.byKey(_favorite));
      await _frames(tester);
      expect(harness.state.taps, 1);
      expect(harness.state.longPresses, 1);
      expect(_position(tester), same(position));
      await _capture(tester, harness, deny, spec.name, {
        'textScale': spec.scale,
        'sameMainPosition': true,
      });
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('049 reduced motion preserves gallery and body endpoint policy',
      (tester) async {
    final harness = await _mount(tester, reduced: true);
    final position = _position(tester);
    final rect = _fixedRect(tester);
    final gesture = await _enterEarlyHandoff(tester, harness);
    await _release(tester, gesture);
    position.jumpTo(_bodyBoundaryPixels(tester, harness));
    await _frames(tester);
    _expectVisible(tester, false);
    expect(tester.widget<AnimatedOpacity>(find.byKey(_opacity)).duration,
        Duration.zero);
    expect(tester.widget<AnimatedScale>(find.byKey(_scale)).duration,
        Duration.zero);
    position.jumpTo(_dockPixels(tester, harness) - 8);
    await _frames(tester);
    _expectVisible(tester, true);
    _sameRect(_fixedRect(tester), rect);
    await tester.tap(_headerCluster());
    await _frames(tester);
    expect(find.byKey(_panel), findsOneWidget);
    _expectVisible(tester, true);
    await tester.tap(find.byKey(_panelToggle));
    await _frames(tester);
    expect(find.byKey(_panel), findsNothing);
    _expectVisible(tester, true);
    await _capture(tester, harness, deny, 'reduced-motion', {});
    expect(tester.takeException(), isNull);
  });

  testWidgets('049 silent correctBy restores docked heart without handoff',
      (tester) async {
    final harness = await _mount(tester);
    final position = _position(tester);
    final controller = _controller(tester);
    final rect = _fixedRect(tester);
    final gesture = await _enterEarlyHandoff(tester, harness);
    await _release(tester, gesture);
    position.jumpTo(_bodyBoundaryPixels(tester, harness));
    await _frames(tester, 16);
    _expectVisible(tester, false);
    final transitionCount = harness.state.transitions.length;
    var normalNotifications = 0;
    void notified() => normalNotifications++;
    controller.addListener(notified);
    final target = _dockPixels(tester, harness) - 8;
    position.correctBy(target - position.pixels);
    tester
        .renderObject<RenderViewport>(find.descendant(
            of: find.byKey(_main), matching: find.byType(Viewport)))
        .markNeedsLayout();
    await _frames(tester, 4);
    controller.removeListener(notified);
    expect(normalNotifications, 0);
    expect(position.pixels, closeTo(target, .01));
    expect(_position(tester), same(position));
    expect(harness.state.transitions.length, transitionCount);
    expect(find.byKey(_inline, skipOffstage: false), findsOneWidget);
    _expectVisible(tester, true);
    await _frames(tester, 16);
    _sameRect(_fixedRect(tester), rect);
    await _capture(tester, harness, deny, 'silent-correctBy', {
      'normalControllerNotifications': normalNotifications,
      'sameMainPosition': identical(position, _position(tester)),
      'noUserHandoff': harness.state.transitions.length == transitionCount,
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('049 gallery keeps existing online feedback event animation',
      (tester) async {
    final harness = await _mount(tester);
    final rect = _fixedRect(tester);
    harness.state.begin(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    _expectVisible(tester, true);
    expect(find.byKey(const ValueKey('pixiv-bookmark-ring-alpha')),
        findsOneWidget);
    _sameRect(_fixedRect(tester), rect);
    harness.state.settle(true);
    await _frames(tester, 24);
    expect(
        tester.widget<PixivBookmarkButton>(find.byKey(_favorite)).isBookmarked,
        true);
    _expectVisible(tester, true);
    _sameRect(_fixedRect(tester), rect);
    await _capture(tester, harness, deny, 'feedback-settled', {});
    expect(tester.takeException(), isNull);
  });

  testWidgets('049 static shell heart retains real tap and long-press targets',
      (tester) async {
    final harness = await _mount(tester, online: false);
    final rect = _fixedRect(tester);
    _position(tester).jumpTo(430);
    await _frames(tester, 16);
    _expectVisible(tester, true);
    await tester.tap(find.byKey(_favorite));
    await tester.longPress(find.byKey(_favorite));
    await _frames(tester);
    expect(harness.state.taps, 1);
    expect(harness.state.longPresses, 1);
    expect(harness.state.imageReads + harness.state.downloads, 0);
    _sameRect(_fixedRect(tester), rect);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _fonts(WidgetTester tester) => tester.runAsync(() async {
      for (final font in [
        ('GalleryCapture049', 'C:/Windows/Fonts/msyh.ttc'),
        (
          'MaterialIcons',
          'build/unit_test_assets/fonts/MaterialIcons-Regular.otf'
        ),
      ]) {
        final file = File(font.$2);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        await (FontLoader(font.$1)
              ..addFont(Future.value(ByteData.sublistView(bytes))))
            .load();
      }
    });

Future<List<MemoryImage>> _images(
    WidgetTester tester, List<double> ratios) async {
  final providers = <MemoryImage>[];
  await tester.runAsync(() async {
    for (final (index, ratio) in ratios.indexed) {
      const width = 360;
      final height = (width / ratio).round();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
          Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          Paint()
            ..color = [
              Colors.indigo.shade100,
              Colors.teal.shade100,
              Colors.amber.shade100
            ][index]);
      for (var y = 60.0; y < height; y += 80) {
        canvas.drawRect(Rect.fromLTWH(0, y, width.toDouble(), 12),
            Paint()..color = Colors.white54);
      }
      final text = TextPainter(
          text: TextSpan(
              text: '049 离线图片 ${index + 1}',
              style: const TextStyle(
                  fontFamily: 'GalleryCapture049',
                  fontSize: 24,
                  color: Colors.black87)),
          textDirection: TextDirection.ltr)
        ..layout();
      text.paint(canvas, const Offset(20, 16));
      text.dispose();
      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      providers
          .add(MemoryImage(Uint8List.fromList(bytes.buffer.asUint8List())));
      image.dispose();
      picture.dispose();
    }
  });
  return providers;
}

Map<String, double> _rect(Rect rect) => {
      'x': rect.left,
      'y': rect.top,
      'width': rect.width,
      'height': rect.height,
    };

Future<void> _capture(WidgetTester tester, _Harness harness, _DenyHttp deny,
    String name, Map<String, Object?> extra) async {
  await tester.pump();
  final boundary = harness.boundary.currentContext!.findRenderObject()!
      as RenderRepaintBoundary;
  final metadata = <String, Object?>{
    'offline': true,
    'notRealDeviceVerification': true,
    'renderer': 'Flutter RenderRepaintBoundary.toImage',
    'images': 'local MemoryImage: square, portrait and landscape; no HTTP',
    'httpAttempts': deny.attempts,
    'width': boundary.size.width,
    'height': boundary.size.height,
    'favoriteRect': _rect(_fixedRect(tester)),
    'favoriteArtworkRect': _rect(tester.getRect(find.byKey(_favorite))),
    'headerRect': find.byKey(_head).evaluate().isEmpty
        ? null
        : _rect(tester.getRect(find.byKey(_head))),
    'panelRect': find.byKey(_panel).evaluate().isEmpty
        ? null
        : _rect(tester.getRect(find.byKey(_panel))),
    'pixels': _position(tester).pixels,
    'viewportExtent': _position(tester).viewportDimension,
    'galleryEnd': _galleryEnd(tester, harness),
    'inlineMounted':
        find.byKey(_inline, skipOffstage: false).evaluate().isNotEmpty,
    'parkedMounted': find
        .byKey(const ValueKey('pixiv-detail-parked-scroll'))
        .evaluate()
        .isNotEmpty,
    'opacity': tester.widget<AnimatedOpacity>(find.byKey(_opacity)).opacity,
    'scale': tester.widget<AnimatedScale>(find.byKey(_scale)).scale,
    'ignoring': tester.widget<IgnorePointer>(find.byKey(_hit)).ignoring,
    'bookmarked': harness.state.saved,
    'busy': harness.state.busy,
    'transitions': List<bool>.of(harness.state.transitions),
    ...extra,
  };
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    image.dispose();
    await Directory(_output).create(recursive: true);
    await File('$_output/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    await File('$_output/$name.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(metadata));
  });
}
