import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/network/pixiv_network/pixiv_models.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/pixiv_comments_section.dart';
import 'package:picakeep/pages/online_comic/pixiv_detail_shell.dart';

const _output = 'docs/verification/pixiv-ui-050/049-regression/handoff';
const _inlineKey = ValueKey('pixiv-inline-details');
const _mainScrollKey = ValueKey('pixiv-detail-page-scroll');
const _panelKey = ValueKey('pixiv-detail-panel');
const _panelScrollKey = ValueKey('pixiv-detail-panel-scroll');
const _headerKey = ValueKey('pixiv-gallery-header');

class _Probe {
  int builds = 0, authorReads = 0, roots = 0, recommendations = 0;
  int favorites = 0, actions = 0, longActions = 0;
  final readImages = <int>[];
  final transitions = <bool>[];
}

List<PixivDetailImage> _pages(String id, _Probe probe,
        {List<double> ratios = const [1, .5, 1.5],
        List<ImageProvider<Object>>? providers}) =>
    [
      for (var index = 0; index < ratios.length; index++)
        PixivDetailImage(
            key: '$id-$index',
            provider: providers?[index],
            aspectRatio: ratios[index],
            onRead: () => probe.readImages.add(index)),
    ];

class _Fixture extends StatefulWidget {
  const _Fixture(
      {required this.probe,
      this.id = '42',
      this.ratios = const [1, .5, 1.5],
      this.providers,
      this.favoriteBusy = false,
      this.actionBusy = false,
      this.loading = false});
  final _Probe probe;
  final String id;
  final bool favoriteBusy, actionBusy, loading;
  final List<double> ratios;
  final List<ImageProvider<Object>>? providers;
  @override
  State<_Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<_Fixture> {
  bool available = true;
  @override
  void didUpdateWidget(covariant _Fixture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) available = true;
  }

  @override
  Widget build(BuildContext context) => PixivDetailShell(
        title: '离线多页作品 ${widget.id} · 先看图再看详情',
        author: '离线画师名字',
        galleryCollapsible: true,
        imagesLoading: widget.loading,
        images: _pages(widget.id, widget.probe,
            ratios: widget.ratios, providers: widget.providers),
        onGalleryExpansionChanged: (value) {
          setState(() => available = value);
          widget.probe.transitions.add(value);
        },
        actionLabel: '下载',
        actionIcon: Icons.download_outlined,
        onAction: () => widget.probe.actions++,
        onActionLongPress: () => widget.probe.longActions++,
        actionBusy: widget.actionBusy,
        onFavorite: () => widget.probe.favorites++,
        favoriteBusy: widget.favoriteBusy,
        sliversBuilder: (context) {
          widget.probe.builds++;
          return [
            SliverToBoxAdapter(
                key: ValueKey('details-${widget.id}'),
                child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('作品信息与标签\n图片始终保持自然比例。详情只在末页手势后衔接，或主动展开。'))),
            const PixivDetailFavoriteBoundary(),
            PixivDetailViewportTrigger(
                key: ValueKey('author-${widget.id}'),
                onVisible: () => widget.probe.authorReads++),
            PixivCommentsSection(
                key: ValueKey('comments-${widget.id}'),
                illustId: widget.id,
                previewLimit: 4,
                loadRoots: (_, offset, limit) async {
                  expectSync(offset, 0);
                  expectSync(limit, 4);
                  widget.probe.roots++;
                  return Res(PixivCommentPage(comments: [
                    for (var index = 1; index <= 4; index++)
                      PixivComment(
                          id: '$index',
                          userId: '$index',
                          userName: '用户$index',
                          avatarUrl: '',
                          comment: '评论$index：离线验证详情面板。',
                          commentDate: '2026-10-09'),
                  ], hasNext: false, originalCount: 4));
                }),
            if (available) ...[
              const SliverToBoxAdapter(child: SizedBox(height: 800)),
              PixivDetailViewportTrigger(
                  key: ValueKey('recommend-${widget.id}'),
                  onVisible: () => widget.probe.recommendations++),
              const SliverToBoxAdapter(
                  key: ValueKey('recommendations'),
                  child: SizedBox(height: 260, child: Text('相关推荐 · 滚到才读取'))),
            ],
          ];
        },
      );
}

Widget _host(Widget child,
        {double scale = 1, bool dark = false, bool reduceMotion = false}) =>
    MaterialApp(
      theme: ThemeData(
          fontFamily: 'PanelCapture043',
          brightness: dark ? Brightness.dark : Brightness.light),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: reduceMotion),
          child: child!),
      home: child,
    );

void _view(WidgetTester tester, {double width = 375, double height = 1000}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

ScrollPosition _position(WidgetTester tester, {bool panel = false}) => tester
    .state<ScrollableState>(find.descendant(
        of: find.byKey(panel ? _panelScrollKey : _mainScrollKey),
        matching: find.byType(Scrollable)))
    .position;

Future<void> _open(WidgetTester tester) async {
  final header = find.byKey(_headerKey);
  for (var index = 0; index < 40 && tester.getRect(header).top < 56; index++) {
    await tester.drag(find.byKey(_mainScrollKey), const Offset(0, 120));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('pixiv-author-header-cluster')));
  await tester.pumpAndSettle();
}

Future<void> _reachEnd(WidgetTester tester, {bool settle = true}) async {
  for (var index = 0;
      index < 40 && find.byKey(_inlineKey).evaluate().isEmpty;
      index++) {
    await tester.drag(find.byKey(_mainScrollKey), const Offset(0, -220));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }
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
    expect(deny.calls, 0);
    HttpOverrides.global = previousHttp;
  });

  testWidgets(
      'initial layout and programmatic positions never expose multipage details',
      (tester) async {
    _view(tester, height: 2200);
    final probe = _Probe();
    await tester.pumpWidget(_host(_Fixture(probe: probe)));
    await tester.pumpAndSettle();
    expect(probe.builds, 0);
    expect(probe.roots, 0);
    expect(probe.authorReads, 0);
    expect(probe.recommendations, 0);
    expect(probe.transitions, isEmpty);
    expect(find.byType(PixivCommentsSection), findsNothing);
    expect(find.text('作品信息与标签'), findsNothing);
    expect(find.byKey(const ValueKey('pixiv-gallery-collapsed-cover')),
        findsNothing);
    for (final (index, ratio) in [1.0, .5, 1.5].indexed) {
      final rect =
          tester.getRect(find.byKey(ValueKey('pixiv-image-42-$index')));
      expect(rect.width, 375);
      expect(rect.height, closeTo(375 / ratio, .01));
    }
    expect(
        tester
            .getSize(find.byKey(const ValueKey('pixiv-author-header-cluster')))
            .height,
        greaterThanOrEqualTo(48));
    _position(tester).jumpTo(_position(tester).maxScrollExtent);
    await tester.pumpAndSettle();
    expect(probe.builds, 0);
  });

  testWidgets(
      'real last-page drag hands off once and keeps natural gallery/controller',
      (tester) async {
    _view(tester);
    final probe = _Probe();
    await tester.pumpWidget(_host(_Fixture(probe: probe)));
    await tester.pumpAndSettle();
    final position = _position(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(probe.builds, 0);
    final gesture = await tester.startGesture(const Offset(100, 700));
    await gesture.moveBy(const Offset(0, -70),
        timeStamp: const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump();
    await gesture.moveBy(const Offset(0, -300),
        timeStamp: const Duration(milliseconds: 900));
    await tester.pump();
    final headerTopBeforeRelease = tester.getTopLeft(find.byKey(_headerKey)).dy;
    final pixelsBeforeRelease = position.pixels;
    await gesture.up(timeStamp: const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();
    expect(find.byKey(_headerKey), findsOneWidget);
    final headerTopAfterHandoff = tester.getTopLeft(find.byKey(_headerKey)).dy;
    expect(headerTopAfterHandoff, closeTo(1375 - position.pixels, 1));
    expect(headerTopAfterHandoff, closeTo(headerTopBeforeRelease, 1));
    expect(position.pixels, closeTo(pixelsBeforeRelease, 1));
    await tester.runAsync(() async {
      await Directory(_output).create(recursive: true);
      await File('$_output/actual-user-handoff.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert({
        'realUserGesture': true,
        'initialLayoutDetailBuilds': 0,
        'headerBeforeRelease': headerTopBeforeRelease,
        'headerAfterHandoff': headerTopAfterHandoff,
        'pixelsBeforeRelease': pixelsBeforeRelease,
        'pixelsAfterHandoff': position.pixels,
        'galleryEnd': 1375,
        'headerExtent': tester.getSize(find.byKey(_headerKey)).height,
        'continuousAuthorAnchor': true,
        'recommendationRequests': probe.recommendations,
      }));
    });
    expect(probe.builds, greaterThan(0));
    expect(probe.recommendations, 0);
    expect(identical(position, _position(tester)), isTrue);
    expect(position.pixels, greaterThan(0));
    final idleOffset = position.pixels;
    await tester.pump(const Duration(seconds: 1));
    expect(position.pixels, idleOffset);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(probe.recommendations, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'reverse user drag retracts inline details and a later drag restores them',
      (tester) async {
    _view(tester);
    final probe = _Probe();
    await tester.pumpWidget(_host(_Fixture(probe: probe)));
    await tester.pumpAndSettle();
    await _reachEnd(tester);
    expect(find.byKey(_headerKey), findsOneWidget);
    expect(probe.transitions, [true]);

    final position = _position(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(probe.recommendations, 1);
    expect(probe.roots, 1);
    final comments =
        tester.state(find.byType(PixivCommentsSection, skipOffstage: false));

    position.jumpTo(370);
    await tester.pumpAndSettle();
    expect(probe.transitions, [true],
        reason: 'programmatic positioning alone must not retract details');
    final headerElement = tester.element(find.byKey(_headerKey));
    await tester.drag(find.byKey(_mainScrollKey), const Offset(0, 80));
    await tester.pumpAndSettle();

    expect(find.byKey(_headerKey), findsOneWidget);
    expect(identical(headerElement, tester.element(find.byKey(_headerKey))),
        isTrue);
    expect(find.byKey(const ValueKey('recommendations')), findsNothing);
    expect(probe.transitions, [true, false]);
    expect(probe.recommendations, 1);
    expect(probe.roots, 1);
    expect(position.pixels, lessThan(399));
    expect(
        identical(
            comments,
            tester
                .state(find.byType(PixivCommentsSection, skipOffstage: false))),
        isTrue);

    await _reachEnd(tester);
    expect(find.byKey(_headerKey), findsOneWidget);
    expect(probe.transitions, [true, false, true]);
    expect(probe.roots, 1);
    expect(
        identical(
            comments,
            tester
                .state(find.byType(PixivCommentsSection, skipOffstage: false))),
        isTrue);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(probe.recommendations, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'panel only shows details and four comments; background returns to same image',
      (tester) async {
    _view(tester);
    final probe = _Probe();
    await tester.pumpWidget(_host(_Fixture(probe: probe)));
    await tester.pumpAndSettle();
    final position = _position(tester);
    position.jumpTo(200);
    await tester.pumpAndSettle();
    final before = position.pixels;
    final counter = tester
        .widget<Text>(find.byKey(const ValueKey('pixiv-image-counter')))
        .data;
    await _open(tester);
    expect(tester.getSize(find.byKey(_panelKey)).height, 750);
    expect(probe.transitions, [false]);
    expect(probe.roots, 1);
    expect(find.text('用户4'), findsOneWidget);
    expect(find.byKey(const ValueKey('recommendations')), findsNothing);
    expect(probe.recommendations, 0);
    final comments =
        tester.state(find.byType(PixivCommentsSection, skipOffstage: false));
    await tester.tapAt(const Offset(100, 140));
    await tester.pumpAndSettle();
    expect(find.byKey(_panelKey), findsNothing);
    expect(probe.transitions, [false, true]);
    expect(identical(position, _position(tester)), isTrue);
    expect(position.pixels, before);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('pixiv-image-counter')))
            .data,
        counter);
    expect(probe.readImages, isEmpty);
    expect(probe.recommendations, 0);
    expect(
        identical(
            comments,
            tester
                .state(find.byType(PixivCommentsSection, skipOffstage: false))),
        isTrue);
    expect(
        tester
            .getSize(find.byKey(const ValueKey('pixiv-detail-parked-scroll')))
            .height,
        0);
    await _open(tester);
    expect(probe.roots, 1);
    expect(
        identical(
            comments,
            tester
                .state(find.byType(PixivCommentsSection, skipOffstage: false))),
        isTrue);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-panel-toggle')));
    await tester.pumpAndSettle();
    await _reachEnd(tester);
    expect(
        identical(
            comments,
            tester
                .state(find.byType(PixivCommentsSection, skipOffstage: false))),
        isTrue);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(probe.roots, 1);
    expect(probe.recommendations, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'inline comments move into panel and back without duplicate keys or reload',
      (tester) async {
    _view(tester);
    final probe = _Probe();
    await tester.pumpWidget(_host(_Fixture(probe: probe)));
    await tester.pumpAndSettle();
    await _reachEnd(tester);
    await tester.scrollUntilVisible(find.byType(PixivCommentsSection), 150,
        scrollable: find.descendant(
            of: find.byKey(_mainScrollKey), matching: find.byType(Scrollable)));
    await tester.pumpAndSettle();
    final comments =
        tester.state(find.byType(PixivCommentsSection, skipOffstage: false));
    final position = _position(tester);
    final before = position.pixels;
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('pixiv-author-header-cluster')), -150,
        scrollable: find.descendant(
            of: find.byKey(_mainScrollKey), matching: find.byType(Scrollable)));
    await tester.pumpAndSettle();
    await _open(tester);
    final openOffset = position.pixels;
    expect(
        identical(
            comments,
            tester
                .state(find.byType(PixivCommentsSection, skipOffstage: false))),
        isTrue);
    expect(probe.roots, 1);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-panel-toggle')));
    await tester.pumpAndSettle();
    expect(
        identical(
            comments,
            tester
                .state(find.byType(PixivCommentsSection, skipOffstage: false))),
        isTrue);
    expect(position.pixels, closeTo(openOffset, .01));
    expect(before, greaterThan(0));
    expect(find.byKey(_headerKey), findsOneWidget);
    expect(find.byKey(_inlineKey), findsOneWidget);
    expect(find.byType(PixivCommentsSection), findsOneWidget);
    expect(
        find.byType(PixivCommentsSection, skipOffstage: false), findsOneWidget);
    await _reachEnd(tester);
    expect(probe.roots, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'panel keeps favorite download and busy commands without dismissing',
      (tester) async {
    _view(tester);
    final probe = _Probe();
    await tester.pumpWidget(_host(_Fixture(probe: probe)));
    await tester.pumpAndSettle();
    await _open(tester);
    expect(find.byKey(const ValueKey('pixiv-detail-favorite')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-favorite')));
    await tester.tap(find.byTooltip('下载').last);
    await tester.longPress(find.byTooltip('下载').last);
    await tester.pumpAndSettle();
    expect(probe.favorites, 1);
    expect(probe.actions, 1);
    expect(probe.longActions, 1);
    expect(find.byKey(_panelKey), findsOneWidget);
    await tester.pumpWidget(
        _host(_Fixture(probe: probe, favoriteBusy: true, actionBusy: true)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-favorite')),
        warnIfMissed: false);
    await tester.tap(find.byTooltip('下载').last);
    await tester.pumpAndSettle();
    expect(probe.favorites, 1);
    expect(probe.actions, 1);
    expect(find.byKey(_panelKey), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-panel-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pixiv-image-42-0')));
    expect(probe.readImages, [0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'work change resets panel and deferred details while same-image refresh retains panel',
      (tester) async {
    _view(tester);
    final probe = _Probe();
    await tester.pumpWidget(_host(_Fixture(probe: probe)));
    await tester.pumpAndSettle();
    await _open(tester);
    await tester.pumpWidget(
        _host(_Fixture(probe: probe, ratios: const [1.1, .5, 1.5])));
    await tester.pumpAndSettle();
    expect(find.byKey(_panelKey), findsOneWidget);
    expect(probe.transitions, [false]);
    await tester.pumpWidget(_host(_Fixture(probe: probe, id: '43')));
    await tester.pumpAndSettle();
    expect(find.byKey(_panelKey), findsNothing);
    expect(probe.transitions, [false, true]);
    expect(find.byType(PixivCommentsSection), findsNothing);
    expect(probe.roots, 1);
    await _open(tester);
    expect(probe.roots, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'inactive adjacent entry ignores a real end drag and panel command',
      (tester) async {
    _view(tester, height: 2000);
    final probe = _Probe();
    await tester.pumpWidget(_host(PixivDetailEntryScope(
        entry: PixivDetailEntry(
            key: '42', comicId: '42', builder: (_) => const SizedBox()),
        isActive: false,
        child: TickerMode(enabled: false, child: _Fixture(probe: probe)))));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(_mainScrollKey), const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pixiv-author-header-cluster')));
    await tester.pumpAndSettle();
    expect(probe.builds, 0);
    expect(probe.roots, 0);
    expect(probe.recommendations, 0);
    expect(find.byKey(_panelKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final spec in [
    (375.0, 1000.0, 2.0, false),
    (240.0, 850.0, 2.0, true),
    (812.0, 375.0, 1.0, false)
  ]) {
    testWidgets(
        'bounded detail panel width${spec.$1} scale${spec.$3} dark${spec.$4}',
        (tester) async {
      _view(tester, width: spec.$1, height: spec.$2);
      final probe = _Probe();
      await tester.pumpWidget(
          _host(_Fixture(probe: probe), scale: spec.$3, dark: spec.$4));
      await tester.pumpAndSettle();
      expect(probe.builds, 0);
      await _open(tester);
      expect(tester.getSize(find.byKey(_panelKey)).height,
          closeTo(spec.$2 * .75, .01));
      expect(
          tester
              .getSize(find.byKey(const ValueKey('pixiv-detail-panel-toggle')))
              .height,
          greaterThanOrEqualTo(48));
      final position = _position(tester, panel: true);
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('用户4'), findsOneWidget);
      expect(probe.recommendations, 0);
      await tester.tapAt(Offset(40, spec.$2 * .1));
      await tester.pumpAndSettle();
      expect(find.byKey(_panelKey), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'empty/loading gallery still defers details and allows explicit panel',
      (tester) async {
    _view(tester);
    final probe = _Probe();
    await tester.pumpWidget(
        _host(_Fixture(probe: probe, ratios: const [], loading: true)));
    await tester.pump(const Duration(milliseconds: 30));
    expect(probe.builds, 0);
    expect(probe.roots, 0);
    await tester.tap(find.byKey(const ValueKey('pixiv-author-header-cluster')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(_panelKey), findsOneWidget);
    expect(probe.roots, 1);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-panel-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byKey(_panelKey), findsNothing);
    expect(probe.readImages, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final inline in [false, true]) {
    testWidgets(
        'rotation and text scale keep geometry without new handoff inline$inline',
        (tester) async {
      _view(tester);
      await _fonts(tester);
      final probe = _Probe();
      await tester
          .pumpWidget(_host(_Fixture(probe: probe), reduceMotion: true));
      await tester.pumpAndSettle();
      final position = _position(tester);
      if (inline) {
        await _reachEnd(tester);
        position.jumpTo(1275);
      } else {
        position.jumpTo(200);
      }
      await tester.pumpAndSettle();
      final before = position.pixels;
      final header = tester.element(find.byKey(_headerKey));
      final top = tester.getTopLeft(find.byKey(_headerKey)).dy;
      final callbacks = List<bool>.of(probe.transitions);
      tester.view.physicalSize = const Size(812, 375);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(identical(position, _position(tester)), isTrue);
      expect(identical(header, tester.element(find.byKey(_headerKey))), isTrue);
      expect(probe.transitions, callbacks);
      if (inline) {
        expect(tester.getTopLeft(find.byKey(_headerKey)).dy, closeTo(top, 1));
        expect(position.pixels,
            closeTo(before + (812 - 375) * (1 + 2 + 1 / 1.5), 1));
      } else {
        expect(position.pixels, closeTo(before * 812 / 375, 1));
        expect(probe.builds, 0);
      }
      final rotated = position.pixels;
      final rotatedTop = tester.getTopLeft(find.byKey(_headerKey)).dy;
      await tester.pumpWidget(
          _host(_Fixture(probe: probe), scale: 2, reduceMotion: true));
      await tester.pumpAndSettle();
      expect(probe.transitions, callbacks);
      expect(position.pixels, closeTo(rotated, 1));
      if (inline) {
        expect(tester.getTopLeft(find.byKey(_headerKey)).dy,
            closeTo(rotatedTop, 1));
      } else {
        expect(probe.builds, 0);
      }
      await tester.pump(const Duration(seconds: 1));
      expect(position.pixels, closeTo(rotated, 1));
      expect(tester.takeException(), isNull);
    });
  }

  for (final height in [250, 1000]) {
    testWidgets('late unknown ratio preserves visible author anchor $height',
        (tester) async {
      _view(tester);
      final delayed = _DelayedImageProvider();
      final transitions = <bool>[];
      var reads = 0;
      await tester.pumpWidget(_host(PixivDetailShell(
        title: '迟到尺寸作品',
        author: '作者',
        galleryCollapsible: true,
        images: [
          PixivDetailImage(
              key: 'known', provider: null, aspectRatio: 1, onRead: () {}),
          PixivDetailImage(
              key: 'late',
              provider: delayed,
              aspectRatio: .75,
              aspectRatioKnown: false,
              onRead: () {}),
          PixivDetailImage(
              key: 'last', provider: null, aspectRatio: 1.5, onRead: () {}),
        ],
        actionLabel: '下载',
        actionIcon: Icons.download_outlined,
        onGalleryExpansionChanged: transitions.add,
        sliversBuilder: (_) {
          reads++;
          return const [SliverToBoxAdapter(child: SizedBox(height: 1400))];
        },
      )));
      await tester.pumpAndSettle();
      final position = _position(tester);
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(reads, 0);
      await tester.dragFrom(const Offset(100, 500), const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(transitions, [true]);
      final pixelsBefore = position.pixels;
      final topBefore = tester.getTopLeft(find.byKey(_headerKey)).dy;
      final image = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, 375, height.toDouble()),
            Paint()..color = const Color(0xFFA6C9EB));
        final picture = recorder.endRecording();
        final result = await picture.toImage(375, height);
        picture.dispose();
        return result;
      });
      delayed.complete(ImageInfo(image: image!));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(
          tester.getSize(find.byKey(const ValueKey('pixiv-image-late'))).height,
          closeTo(height.toDouble(), .01));
      expect(
          tester.getTopLeft(find.byKey(_headerKey)).dy, closeTo(topBefore, 1));
      expect(position.pixels, closeTo(pixelsBefore + height - 500, 1));
      expect(transitions, [true]);
      expect(identical(position, _position(tester)), isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(
          tester.getTopLeft(find.byKey(_headerKey)).dy, closeTo(topBefore, 1));
      await tester.runAsync(() async {
        await File('$_output/late-ratio-$height.json')
            .writeAsString(const JsonEncoder.withIndent('  ').convert({
          'offline': true,
          'resolvedHeight': height,
          'headerTopBefore': topBefore,
          'headerTopAfter': tester.getTopLeft(find.byKey(_headerKey)).dy,
          'pixelsBefore': pixelsBefore,
          'pixelsAfter': position.pixels,
          'transitionCallbacks': transitions,
          'sameMainPosition': true,
        }));
      });
      expect(tester.takeException(), isNull);
    });
  }

  for (final closing in [false, true]) {
    testWidgets('late ratio during panel or closing preserves anchor $closing',
        (tester) async {
      _view(tester);
      final delayed = _DelayedImageProvider();
      final transitions = <bool>[];
      await tester.pumpWidget(_host(PixivDetailShell(
        title: '迟到面板尺寸',
        author: '作者',
        galleryCollapsible: true,
        images: [
          PixivDetailImage(
              key: 'known', provider: null, aspectRatio: 1, onRead: () {}),
          PixivDetailImage(
              key: 'late',
              provider: delayed,
              aspectRatio: .75,
              aspectRatioKnown: false,
              onRead: () {}),
          PixivDetailImage(
              key: 'last', provider: null, aspectRatio: 1.5, onRead: () {}),
        ],
        actionLabel: '下载',
        actionIcon: Icons.download_outlined,
        onGalleryExpansionChanged: transitions.add,
        sliversBuilder: (_) =>
            const [SliverToBoxAdapter(child: SizedBox(height: 1400))],
      )));
      await tester.pumpAndSettle();
      final position = _position(tester);
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(100, 500), const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(find.byKey(_inlineKey), findsOneWidget);
      final top = tester.getTopLeft(find.byKey(_headerKey)).dy;
      final before = position.pixels;
      await _open(tester);
      if (closing) {
        await tester.tapAt(const Offset(100, 100));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 64));
        expect(find.byKey(_panelKey), findsOneWidget);
      }
      final height = closing ? 1000 : 250;
      final image = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, 375, height.toDouble()),
            Paint()..color = const Color(0xFFA6C9EB));
        final picture = recorder.endRecording();
        final image = await picture.toImage(375, height);
        picture.dispose();
        return image;
      });
      delayed.complete(ImageInfo(image: image!));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      if (!closing) {
        await tester.tapAt(const Offset(100, 100));
      }
      await tester.pumpAndSettle();
      expect(find.byKey(_panelKey), findsNothing);
      expect(find.byKey(_inlineKey), findsOneWidget);
      expect(identical(position, _position(tester)), isTrue);
      expect(position.pixels, closeTo(before + height - 500, 1));
      expect(tester.getTopLeft(find.byKey(_headerKey)).dy, closeTo(top, 1));
      expect(
          tester.getRect(find.byKey(const ValueKey('pixiv-image-last'))).bottom,
          closeTo(top, 1));
      expect(transitions, [true, false, true]);
      final idle = position.pixels;
      await tester.pump(const Duration(seconds: 1));
      expect(position.pixels, idle);
      expect(tester.takeException(), isNull);
    });
  }

  for (final spec in [
    (375.0, 1000.0, 1.0, false),
    (375.0, 1000.0, 2.0, false),
    (240.0, 850.0, 2.0, true),
    (812.0, 375.0, 1.0, false),
  ]) {
    testWidgets('continuous author anchor frames ${spec.$1} scale${spec.$3}',
        (tester) async {
      _view(tester, width: spec.$1, height: spec.$2);
      await _fonts(tester);
      final probe = _Probe();
      final boundary = GlobalKey();
      await tester.pumpWidget(_host(
          RepaintBoundary(key: boundary, child: _Fixture(probe: probe)),
          scale: spec.$3,
          dark: spec.$4));
      await tester.pumpAndSettle();
      final position = _position(tester);
      final header = find.byKey(_headerKey);
      final element = tester.element(header);
      final height = tester.getSize(header).height;
      final end = spec.$1 * (1 + 2 + 1 / 1.5);
      expect(position.maxScrollExtent,
          closeTo((end + height + 88 - spec.$2).clamp(0, double.infinity), 1));
      position.jumpTo((end - spec.$2 + height - 40)
          .clamp(position.minScrollExtent, position.maxScrollExtent));
      await tester.pumpAndSettle();
      expect(probe.builds, 0);
      final frames = <Map<String, Object?>>[];
      void sample(String phase) {
        final actual = tester.getRect(header);
        final anchor = end - position.pixels;
        final dock = spec.$2 - height;
        final expected = anchor < dock ? anchor : dock;
        expect(actual.top, closeTo(expected, 1));
        expect(actual.height, closeTo(height, 1));
        expect(identical(element, tester.element(header)), isTrue);
        expect(identical(position, _position(tester)), isTrue);
        frames.add({
          'phase': phase,
          'pixels': position.pixels,
          'anchor': anchor,
          'headerTop': actual.top,
          'headerHeight': actual.height,
          'expectedTop': expected,
          'avatarLeft': tester
              .getTopLeft(
                  find.byKey(const ValueKey('pixiv-gallery-author-avatar')))
              .dx,
          'titleTop': tester
              .getTopLeft(
                  find.byKey(const ValueKey('pixiv-author-header-title')))
              .dy,
          'inline': find.byKey(_inlineKey).evaluate().isNotEmpty,
        });
      }

      sample('before');
      final gesture =
          await tester.startGesture(Offset(spec.$1 * .5, spec.$2 * .35));
      for (var index = 0; index < 24 && probe.transitions.isEmpty; index++) {
        await gesture.moveBy(const Offset(0, -20),
            timeStamp: Duration(milliseconds: (index + 1) * 400));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        sample('down-$index');
      }
      expect(probe.transitions, [true]);
      for (var index = 0; index < 20; index++) {
        await gesture.moveBy(const Offset(0, 20),
            timeStamp: Duration(milliseconds: (index + 9) * 400));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        sample('reverse-$index');
      }
      await gesture.up(timeStamp: const Duration(seconds: 13));
      await tester.pumpAndSettle();
      expect(find.byKey(_inlineKey), findsNothing);
      expect(probe.transitions, [true, false]);
      final idle = position.pixels;
      await tester.pump(const Duration(seconds: 1));
      expect(position.pixels, idle);
      sample('idle');
      expect(
          tester
              .getTopLeft(
                  find.byKey(const ValueKey('pixiv-gallery-expansion-toggle')))
              .dx,
          lessThan(tester
              .getTopLeft(
                  find.byKey(const ValueKey('pixiv-gallery-author-avatar')))
              .dx));
      expect(
          tester
              .getTopLeft(
                  find.byKey(const ValueKey('pixiv-gallery-author-avatar')))
              .dx,
          lessThan(tester
              .getTopLeft(
                  find.byKey(const ValueKey('pixiv-author-header-title')))
              .dx));
      await tester.tap(find.byTooltip('下载'));
      await tester.longPress(find.byTooltip('下载'));
      await tester.pumpAndSettle();
      expect(probe.actions, 1);
      expect(probe.longActions, 1);
      final prefix = 'anchor-${spec.$1.toInt()}-scale${spec.$3.toInt()}';
      await _capture(tester, boundary, prefix, {
        'realPointer': true,
        'frames': frames,
        'sameHeaderElement': true,
        'sameMainPosition': true,
        'downloadTap': probe.actions,
        'downloadLongPress': probe.longActions,
        'commentRequests': probe.roots,
        'recommendationRequests': probe.recommendations,
      });
      expect(tester.takeException(), isNull);
    });
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('actual engine handoff/panel/closed screenshots scale$scale',
        (tester) async {
      _view(tester);
      await _fonts(tester);
      final providers = await _captureImages(tester);
      final probe = _Probe();
      final boundary = GlobalKey();
      await tester.pumpWidget(_host(
          RepaintBoundary(
              key: boundary,
              child: _Fixture(probe: probe, providers: providers)),
          scale: scale));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final context = tester.element(find.byType(PixivDetailShell));
        for (final provider in providers) {
          await precacheImage(
              ResizeImage.resizeIfNeeded(450, null, provider), context);
        }
      });
      await tester.pumpAndSettle();
      final prefix = scale == 1 ? '375-normal' : '375-large-text';
      final position = _position(tester);
      await _capture(tester, boundary, '$prefix-look-images', {
        'pixels': position.pixels,
        'detailsBuilds': probe.builds,
        'commentRequests': probe.roots,
        'recommendationRequests': probe.recommendations,
      });
      expect(probe.builds, 0);
      await _reachEnd(tester);
      expect(find.byKey(_headerKey), findsOneWidget);
      expect(find.byKey(_inlineKey), findsOneWidget);
      final counterBeforePanel = tester
          .widget<Text>(find.byKey(const ValueKey('pixiv-image-counter')))
          .data;
      await _capture(tester, boundary, '$prefix-last-page-handoff', {
        'pixels': position.pixels,
        'headerTop': tester.getTopLeft(find.byKey(_headerKey)).dy,
        'imageCounter': counterBeforePanel,
        'galleryEnd': 1375.0,
        'commentRequests': probe.roots,
        'recommendationRequests': probe.recommendations,
      });
      final comments =
          tester.state(find.byType(PixivCommentsSection, skipOffstage: false));
      final openOffset = position.pixels;
      await _open(tester);
      await _capture(tester, boundary, '$prefix-detail-panel', {
        'pixels': position.pixels,
        'panelHeight': tester.getSize(find.byKey(_panelKey)).height,
        'sameCommentState': identical(
            comments,
            tester
                .state(find.byType(PixivCommentsSection, skipOffstage: false))),
        'commentRequests': probe.roots,
        'recommendationRequests': probe.recommendations,
      });
      expect(probe.recommendations, 0);
      _position(tester, panel: true)
          .jumpTo(_position(tester, panel: true).maxScrollExtent);
      await tester.pumpAndSettle();
      await _capture(tester, boundary, '$prefix-panel-four-comments', {
        'pixels': position.pixels,
        'panelPixels': _position(tester, panel: true).pixels,
        'commentRequests': probe.roots,
        'recommendationRequests': probe.recommendations,
      });
      await tester.tapAt(const Offset(100, 150));
      await tester.pumpAndSettle();
      await _capture(tester, boundary, '$prefix-back-to-images', {
        'pixels': position.pixels,
        'sameMainPosition': identical(position, _position(tester)),
        'openPixels': openOffset,
        'readImages': probe.readImages,
        'commentRequests': probe.roots,
        'recommendationRequests': probe.recommendations,
      });
      expect(position.pixels, closeTo(openOffset, .01));
      expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('pixiv-image-counter')))
              .data,
          counterBeforePanel);
      expect(find.byKey(_headerKey), findsOneWidget);
      expect(find.byKey(_inlineKey), findsOneWidget);
      expect(find.byType(PixivCommentsSection, skipOffstage: false),
          findsOneWidget);
      expect(
          tester.state(find.byType(PixivCommentsSection, skipOffstage: false)),
          same(comments));
      expect(probe.readImages, isEmpty);
      expect(probe.recommendations, 0);
      await _reachEnd(tester);
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(probe.recommendations, 1);
      await _capture(tester, boundary, '$prefix-normal-related-tail', {
        'pixels': position.pixels,
        'commentRequests': probe.roots,
        'recommendationRequests': probe.recommendations,
      });
      for (var index = 0;
          index < 40 && find.byKey(_inlineKey).evaluate().isNotEmpty;
          index++) {
        await tester.dragFrom(const Offset(100, 300), const Offset(0, 220));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(_headerKey), findsOneWidget);
      expect(find.byKey(_inlineKey), findsNothing);
      expect(find.byType(PixivCommentsSection), findsNothing);
      expect(probe.roots, 1);
      expect(probe.recommendations, 1);
      await _capture(tester, boundary, '$prefix-scroll-up-return-to-gallery', {
        'pixels': position.pixels,
        'sameMainPosition': identical(position, _position(tester)),
        'imageCounter': tester
            .widget<Text>(find.byKey(const ValueKey('pixiv-image-counter')))
            .data,
        'commentRequests': probe.roots,
        'recommendationRequests': probe.recommendations,
      });
      expect(tester.takeException(), isNull);
    });
  }
}

class _DelayedImageProvider extends ImageProvider<_DelayedImageProvider> {
  final _image = Completer<ImageInfo>();
  void complete(ImageInfo image) => _image.complete(image);
  @override
  Future<_DelayedImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
          _DelayedImageProvider key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_image.future);
}

class _DenyHttp extends HttpOverrides {
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    calls++;
    throw StateError('043 fixtures must not open HTTP');
  }
}

Future<void> _fonts(WidgetTester tester) => tester.runAsync(() async {
      for (final font in [
        ('PanelCapture043', 'C:/Windows/Fonts/msyh.ttc'),
        (
          'MaterialIcons',
          'build/unit_test_assets/fonts/MaterialIcons-Regular.otf'
        )
      ]) {
        final bytes = await File(font.$2).readAsBytes();
        await (FontLoader(font.$1)
              ..addFont(Future.value(ByteData.sublistView(bytes))))
            .load();
      }
    });

Future<List<MemoryImage>> _captureImages(WidgetTester tester) async {
  final result = <MemoryImage>[];
  await tester.runAsync(() async {
    final specs = [
      (375, 375, const Color(0xFFDFCCF6)),
      (375, 750, const Color(0xFFC4DDF6)),
      (375, 250, const Color(0xFFD3E6C7))
    ];
    for (final (index, spec) in specs.indexed) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
          Rect.fromLTWH(0, 0, spec.$1.toDouble(), spec.$2.toDouble()),
          Paint()..color = spec.$3);
      canvas.drawCircle(Offset(spec.$1 * .6, spec.$2 * .45), 100,
          Paint()..color = const Color(0x66FFFFFF));
      final text = TextPainter(
          text: TextSpan(
              text: '离线图片 ${index + 1} / 3',
              style: const TextStyle(
                  fontFamily: 'PanelCapture043',
                  fontSize: 28,
                  color: Color(0xFF403653))),
          textDirection: TextDirection.ltr)
        ..layout();
      text.paint(canvas, const Offset(24, 70));
      final picture = recorder.endRecording();
      final image = await picture.toImage(spec.$1, spec.$2);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      result.add(MemoryImage(Uint8List.fromList(bytes.buffer.asUint8List())));
      image.dispose();
      picture.dispose();
    }
  });
  return result;
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name,
    Map<String, Object?> extra) async {
  await tester.pump();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    image.dispose();
    await Directory(_output).create(recursive: true);
    await File('$_output/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    await File('$_output/$name.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert({
      'offline': true,
      'renderer': 'Flutter RenderRepaintBoundary.toImage',
      'width': boundary.size.width,
      'height': boundary.size.height,
      'font': 'C:/Windows/Fonts/msyh.ttc',
      ...extra,
    }));
  });
}
