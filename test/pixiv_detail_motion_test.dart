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

const _output = 'docs/verification/pixiv-ui-050/049-regression/motion';
const _main = ValueKey('pixiv-detail-page-scroll');
const _panel = ValueKey('pixiv-detail-panel');
const _panelScroll = ValueKey('pixiv-detail-panel-scroll');
const _head = ValueKey('pixiv-gallery-header');
const _panelHead = ValueKey('pixiv-details-panel-header');
const _cluster = ValueKey('pixiv-author-header-cluster');
const _arrow = ValueKey('pixiv-author-header-arrow');
const _toggle = ValueKey('pixiv-gallery-expansion-toggle');
const _panelToggle = ValueKey('pixiv-detail-panel-toggle');
const _scrim = ValueKey('pixiv-detail-panel-scrim');
const _avatar = ValueKey('pixiv-gallery-author-avatar');
const _title = ValueKey('pixiv-author-header-title');
const _name = ValueKey('pixiv-author-header-name');
const _inline = ValueKey('pixiv-inline-details');
const _ratios = [1.0, .5, 1.5];

class _Probe {
  int authorReads = 0, roots = 0, relatedReads = 0;
  int downloads = 0, longDownloads = 0, favorites = 0;
  final transitions = <bool>[];
  final readImages = <int>[];
  final alive = <_IdentityState>{};
  final requests = <(String, int, int)>[];
}

class _Identity extends StatefulWidget {
  const _Identity({required this.probe, required this.id, super.key});
  final _Probe probe;
  final String id;
  @override
  State<_Identity> createState() => _IdentityState();
}

class _IdentityState extends State<_Identity> {
  @override
  void initState() {
    super.initState();
    widget.probe.alive.add(this);
  }

  @override
  void dispose() {
    widget.probe.alive.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
      height: 40,
      child: Text('048 离线作品信息 ${widget.id} · 唯一详情状态',
          maxLines: 2, overflow: TextOverflow.ellipsis));
}

class _Fixture extends StatefulWidget {
  const _Fixture({
    required this.probe,
    required this.providers,
    this.id = '42',
    this.ratios = _ratios,
    this.longText = false,
    this.busy = false,
  });
  final _Probe probe;
  final List<MemoryImage> providers;
  final String id;
  final List<double> ratios;
  final bool longText, busy;
  @override
  State<_Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<_Fixture> {
  bool gallery = true;
  @override
  Widget build(BuildContext context) => PixivDetailShell(
        title: widget.longText
            ? List.filled(8, '长标题星空与远方的绘画作品').join()
            : '048 多图作品 · 图库到正文的连续运动',
        author:
            widget.longText ? List.filled(5, '长名字画师与星空').join() : '离线画师 · 星与海',
        galleryCollapsible: true,
        images: [
          for (var i = 0; i < widget.ratios.length; i++)
            PixivDetailImage(
                key: '${widget.id}-$i',
                provider: widget.providers[i],
                aspectRatio: widget.ratios[i],
                onRead: () => widget.probe.readImages.add(i)),
        ],
        actionLabel: '下载',
        actionIcon: Icons.download_outlined,
        onAction: () => widget.probe.downloads++,
        onActionLongPress: () => widget.probe.longDownloads++,
        actionBusy: widget.busy,
        onFavorite: () => widget.probe.favorites++,
        onGalleryExpansionChanged: (value) {
          setState(() => gallery = value);
          widget.probe.transitions.add(value);
        },
        sliversBuilder: (context) => [
          SliverToBoxAdapter(
              child: _Identity(
                  key: ValueKey('identity-${widget.id}'),
                  id: widget.id,
                  probe: widget.probe)),
          const PixivDetailFavoriteBoundary(),
          PixivDetailViewportTrigger(
              key: ValueKey('author-${widget.id}'),
              onVisible: () => widget.probe.authorReads++),
          SliverToBoxAdapter(
              child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text('当前作者与作品预览 ${widget.id}'))),
          PixivCommentsSection(
              key: ValueKey('comments-${widget.id}'),
              illustId: widget.id,
              previewLimit: 4,
              loadRoots: (id, offset, limit) async {
                widget.probe.roots++;
                widget.probe.requests.add((id, offset, limit));
                return Res(PixivCommentPage(comments: [
                  for (var i = 1; i <= 4; i++)
                    PixivComment(
                        id: '$i',
                        userId: '$i',
                        userName: '用户$i',
                        avatarUrl: '',
                        comment: '离线评论$i：动画保持当前详情状态。',
                        commentDate: '2026-10-09'),
                ], hasNext: false, originalCount: 4));
              }),
          const SliverToBoxAdapter(child: SizedBox(height: 420)),
          if (gallery) ...[
            const SliverToBoxAdapter(child: SizedBox(height: 800)),
            PixivDetailViewportTrigger(
                key: ValueKey('related-${widget.id}'),
                onVisible: () => widget.probe.relatedReads++),
            const SliverToBoxAdapter(
                child: SizedBox(height: 300, child: Text('底部独立作品推荐'))),
          ],
        ],
      );
}

class _Harness {
  _Harness(this.probe, this.providers, this.boundary);
  final _Probe probe;
  final List<MemoryImage> providers;
  final GlobalKey boundary;
}

Widget _host(Widget child,
        {double scale = 1, bool dark = false, bool reduced = false}) =>
    MaterialApp(
        theme: ThemeData(
            fontFamily: 'MotionCapture048',
            brightness: dark ? Brightness.dark : Brightness.light),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: reduced),
            child: child!),
        home: child);

Future<_Harness> _mount(WidgetTester tester,
    {double width = 375,
    double height = 1000,
    double scale = 1,
    bool dark = false,
    bool reduced = false,
    bool longText = false,
    ValueListenable<bool>? entryActive,
    List<double> ratios = _ratios}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await _fonts(tester);
  final probe = _Probe();
  final providers = await _images(tester, ratios);
  final boundary = GlobalKey();
  final fixture = _Fixture(
      probe: probe, providers: providers, ratios: ratios, longText: longText);
  final Widget content;
  if (entryActive == null) {
    content = fixture;
  } else {
    final entry = PixivDetailEntry(
        key: '42', comicId: '42', builder: (_) => const SizedBox());
    content = ValueListenableBuilder<bool>(
        valueListenable: entryActive,
        child: fixture,
        builder: (context, active, child) => PixivDetailEntryScope(
            entry: entry,
            isActive: active,
            child: TickerMode(
                enabled: active,
                child: Offstage(offstage: !active, child: child!))));
  }
  await tester.pumpWidget(_host(RepaintBoundary(key: boundary, child: content),
      scale: scale, dark: dark, reduced: reduced));
  await tester.runAsync(() async {
    final context = tester.element(find.byType(PixivDetailShell));
    for (final provider in providers) {
      await precacheImage(
          ResizeImage.resizeIfNeeded((width * 1.2).round(), null, provider),
          context);
    }
  });
  await _frames(tester, 4);
  expect(probe.authorReads, 0);
  expect(probe.roots, 0);
  expect(probe.relatedReads, 0);
  return _Harness(probe, providers, boundary);
}

ScrollPosition _position(WidgetTester tester, {bool panel = false}) => tester
    .state<ScrollableState>(find.descendant(
        of: find.byKey(panel ? _panelScroll : _main),
        matching: find.byType(Scrollable)))
    .position;

ScrollController _controller(WidgetTester tester, {bool panel = false}) =>
    tester
        .widget<CustomScrollView>(find.byKey(panel ? _panelScroll : _main))
        .controller!;

Finder _inHead(Key child, {bool panel = false}) => find.descendant(
    of: find.byKey(panel ? _panelHead : _head), matching: find.byKey(child));

Finder _download({bool panel = false}) => find.descendant(
    of: find.byKey(panel ? _panelHead : _head), matching: find.byTooltip('下载'));

Rect _localRect(WidgetTester tester, Finder child, Finder parent) {
  final childRect = tester.getRect(child);
  final origin = tester.getTopLeft(parent);
  return childRect.shift(-origin);
}

void _sameRect(Rect actual, Rect expected, {double epsilon = 1}) {
  expect(actual.left, closeTo(expected.left, epsilon));
  expect(actual.top, closeTo(expected.top, epsilon));
  expect(actual.width, closeTo(expected.width, epsilon));
  expect(actual.height, closeTo(expected.height, epsilon));
}

double _progress(WidgetTester tester, double end) {
  final h = tester.getSize(find.byKey(_head)).height;
  final viewport = _position(tester).viewportDimension;
  return ((viewport - h - (end - _position(tester).pixels)) / h)
      .clamp(0, 1)
      .toDouble();
}

double _arrowOpacity(WidgetTester tester) {
  final marker = _inHead(_arrow);
  expect(marker, findsOneWidget);
  final dynamic render = tester.renderObject(marker);
  return render.opacity as double;
}

int _expandButtons(WidgetTester tester) {
  final root = tester.getSemantics(_inHead(_cluster)).owner!.rootSemanticsNode!;
  var count = 0;
  void visit(SemanticsNode node) {
    if (node.flagsCollection.isButton &&
        '${node.label} ${node.tooltip}'.contains('展开详情') &&
        node.getSemanticsData().hasAction(ui.SemanticsAction.tap)) {
      count++;
    }
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(root);
  return count;
}

double _scrimAlpha(WidgetTester tester) {
  final marker = find.byKey(_scrim);
  if (marker.evaluate().isEmpty) return 0;
  final boxes = [
    ...marker.evaluate().map((e) => e.widget).whereType<ColoredBox>(),
    ...tester.widgetList<ColoredBox>(
        find.descendant(of: marker, matching: find.byType(ColoredBox))),
  ];
  expect(boxes, isNotEmpty);
  return boxes.first.color.a;
}

String _counterText(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('pixiv-image-counter')))
    .data!;

String _counterFor(WidgetTester tester, {List<double> ratios = _ratios}) {
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  final focus = _position(tester).pixels + 48;
  var end = 0.0;
  for (var index = 0; index < ratios.length; index++) {
    end += width / ratios[index];
    if (focus < end || index == ratios.length - 1) {
      return '${index + 1} / ${ratios.length}';
    }
  }
  throw StateError('The local image fixture must contain pages');
}

Map<String, Object?> _snapshot(WidgetTester tester, _Probe probe,
    {required int milliseconds, String phase = ''}) {
  Rect? rect(Key key) => find.byKey(key).evaluate().isEmpty
      ? null
      : tester.getRect(find.byKey(key).first);
  Map<String, double>? values(Rect? r) => r == null
      ? null
      : {'x': r.left, 'y': r.top, 'width': r.width, 'height': r.height};
  return {
    'ms': milliseconds,
    'phase': phase,
    'pixels': _position(tester).pixels,
    'counter': _counterText(tester),
    'panel': values(rect(_panel)),
    'header': values(rect(_head)),
    'cluster': values(rect(_cluster)),
    'avatar': values(rect(_avatar)),
    'title': values(rect(_title)),
    'author': values(rect(_name)),
    'scrimAlpha': _scrimAlpha(tester),
    'identityStates': probe.alive.length,
    'authorRequests': probe.authorReads,
    'commentRequests': probe.roots,
    'relatedRequests': probe.relatedReads,
  };
}

Future<void> _frames(WidgetTester tester, int count,
    {FutureOr<void> Function(int elapsed)? sample}) async {
  for (var i = 1; i <= count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await sample?.call(i * 16);
  }
}

Future<void> _open(WidgetTester tester) async {
  final target = _inHead(_cluster);
  await tester.tap(target);
  await tester.pump();
  await _frames(tester, 18);
  expect(find.byKey(_panel), findsOneWidget);
}

Future<void> _close(WidgetTester tester, {bool background = false}) async {
  if (background) {
    await tester.tapAt(Offset(tester.view.physicalSize.width * .3,
        tester.view.physicalSize.height * .1));
  } else {
    await tester.tap(find.byKey(_panelToggle));
  }
  await tester.pump();
  await _frames(tester, 14);
  expect(find.byKey(_panel), findsNothing);
}

Future<void> _inlineAtHead(WidgetTester tester, double end) async {
  final position = _position(tester);
  final h = tester.getSize(find.byKey(_head)).height;
  position.jumpTo((end - position.viewportDimension + h - 32)
      .clamp(position.minScrollExtent, position.maxScrollExtent));
  await _frames(tester, 2);
  final gesture = await tester.startGesture(Offset(
      tester.view.physicalSize.width * .45,
      tester.view.physicalSize.height * .45));
  var elapsed = 0;
  for (var i = 0; i < 40; i++) {
    elapsed += 64;
    await gesture.moveBy(const Offset(0, -8),
        timeStamp: Duration(milliseconds: elapsed));
    await _frames(tester, 4);
    if (find.byKey(_inline).evaluate().isNotEmpty &&
        _progress(tester, end) >= .65) {
      break;
    }
  }
  elapsed += 128;
  await gesture.up(timeStamp: Duration(milliseconds: elapsed));
  await _frames(tester, 8);
  expect(find.byKey(_inline), findsOneWidget);
}

State<StatefulWidget> _comments(WidgetTester tester) =>
    tester.state(find.byType(PixivCommentsSection, skipOffstage: false));

void _singleDetails(WidgetTester tester, _Probe probe,
    {State<StatefulWidget>? comments, _IdentityState? identity}) {
  expect(
      find.byType(PixivCommentsSection, skipOffstage: false), findsOneWidget);
  expect(probe.alive, hasLength(1));
  if (comments != null) expect(identical(_comments(tester), comments), isTrue);
  if (identity != null) expect(identical(probe.alive.single, identity), isTrue);
  expect(tester.takeException(), isNull);
}

void _readOnce(_Probe probe) {
  expect(probe.authorReads, 1);
  expect(probe.roots, 1);
  expect(probe.relatedReads, 0);
  expect(probe.requests, [('42', 0, 4)]);
  expect(probe.readImages, isEmpty);
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

  for (final spec in [
    (375.0, 1000.0, 1.0, false),
    (240.0, 850.0, 2.0, true),
    (812.0, 375.0, 1.0, false),
  ]) {
    testWidgets(
        '048 real slow pointer 52dp collapse and immediate reverse '
        '${spec.$1} scale${spec.$3}', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final harness = await _mount(tester,
            width: spec.$1,
            height: spec.$2,
            scale: spec.$3,
            dark: spec.$4,
            longText: spec.$3 > 1);
        final probe = harness.probe;
        final position = _position(tester);
        final controller = _controller(tester);
        final head = tester.element(find.byKey(_head));
        final h = tester.getSize(find.byKey(_head)).height;
        expect(
            tester.getSize(_inHead(_toggle)).height, greaterThanOrEqualTo(48));
        final end = spec.$1 * (1 + 2 + 1 / 1.5);
        position.jumpTo((end - spec.$2 + h - 32)
            .clamp(position.minScrollExtent, position.maxScrollExtent));
        await _frames(tester, 2);
        expect(_progress(tester, end), 0);
        final base = [
          for (final key in [_avatar, _title, _name, _cluster])
            _localRect(tester, _inHead(key), find.byKey(_head)),
        ];
        final download = _localRect(tester, _download(), find.byKey(_head));
        final samples = <Map<String, Object?>>[];
        var elapsed = 0;
        var maximum = 0.0;
        void sample(String phase, {int? frameMilliseconds}) {
          final p = _progress(tester, end);
          maximum = p > maximum ? p : maximum;
          final actual = tester.getRect(find.byKey(_head));
          expect(actual.height, closeTo(h, 1));
          expect(
              actual.top,
              closeTo(
                  (end - position.pixels).clamp(-double.infinity, spec.$2 - h),
                  1));
          for (final (i, key) in [_avatar, _title, _name, _cluster].indexed) {
            final r = _localRect(tester, _inHead(key), find.byKey(_head));
            expect(r.left, closeTo(base[i].left - 52 * p, 1));
            expect(r.top, closeTo(base[i].top, 1));
            expect(r.width, closeTo(base[i].width, 1));
          }
          _sameRect(
              _localRect(tester, _download(), find.byKey(_head)), download);
          expect(_arrowOpacity(tester), closeTo(1 - p, .02));
          final dynamic arrowBox = tester.renderObject(_inHead(_arrow));
          final visibleWidth = arrowBox.visibleWidth as double;
          expect(visibleWidth, closeTo(52 * (1 - p), 1));
          if (visibleWidth < 48) {
            final result = BoxHitTestResult();
            expect(
                arrowBox.hitTest(result,
                    position: Offset(
                        visibleWidth / 2, (arrowBox.size as Size).height / 2)),
                isFalse);
          }
          expect(identical(position, _position(tester)), isTrue);
          expect(identical(controller, _controller(tester)), isTrue);
          expect(identical(head, tester.element(find.byKey(_head))), isTrue);
          samples.add({
            ..._snapshot(tester, probe,
                milliseconds: frameMilliseconds ?? elapsed, phase: phase),
            'progress': p,
            'expectedShift': -52 * p,
            'arrowOpacity': _arrowOpacity(tester),
            'arrowVisibleWidth': visibleWidth,
          });
        }

        sample('before');
        final gesture =
            await tester.startGesture(Offset(spec.$1 * .4, spec.$2 * .65));
        var steps = 0;
        for (; steps < 60 && maximum < 1; steps++) {
          elapsed += 64;
          await gesture.moveBy(const Offset(0, -8),
              timeStamp: Duration(milliseconds: elapsed));
          await _frames(tester, 4, sample: (frame) {
            sample('down-$steps-$frame',
                frameMilliseconds: elapsed - 64 + frame);
          });
        }
        expect(maximum, 1);
        expect(_expandButtons(tester), 1);
        expect(probe.transitions, [true]);
        for (var i = 0; i < steps + (h / 8).ceil() + 6; i++) {
          elapsed += 64;
          await gesture.moveBy(const Offset(0, 8),
              timeStamp: Duration(milliseconds: elapsed));
          await _frames(tester, 4, sample: (frame) {
            sample('reverse-$i-$frame',
                frameMilliseconds: elapsed - 64 + frame);
          });
        }
        elapsed += 128;
        await gesture.up(timeStamp: Duration(milliseconds: elapsed));
        await _frames(tester, 8);
        expect(_progress(tester, end), 0);
        expect(probe.transitions, [true, false]);
        final idle = position.pixels;
        await tester.pump(const Duration(seconds: 1));
        expect(position.pixels, closeTo(idle, 1));
        sample('idle');
        expect(probe.relatedReads, 0);
        expect(probe.readImages, isEmpty);
        await _capture(tester, harness.boundary,
            'slow-${spec.$1.toInt()}-scale${spec.$3.toInt()}', {
          'frames': samples,
          'sameMainController': true,
          'sameMainPosition': true,
          'sameHeaderElement': true,
          'httpAttempts': deny.calls,
        });
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets(
      '048 programmatic geometry and idle never activate deferred feeds',
      (tester) async {
    final harness = await _mount(tester);
    final position = _position(tester);
    const end = 1375.0;
    final h = tester.getSize(find.byKey(_head)).height;
    for (final fraction in [0.0, .3, .7, 1.0, 0.0]) {
      position.jumpTo(position.maxScrollExtent * fraction);
      await _frames(tester, 2);
      expect(
          tester.getTopLeft(find.byKey(_head)).dy,
          closeTo(
              (end - position.pixels).clamp(-double.infinity, 1000 - h), 1));
      expect(_arrowOpacity(tester), closeTo(1 - _progress(tester, end), .02));
      expect(_counterText(tester), _counterFor(tester));
      expect(harness.probe.transitions, isEmpty);
      expect(harness.probe.alive, isEmpty);
      expect(harness.probe.authorReads, 0);
      expect(harness.probe.roots, 0);
      expect(harness.probe.relatedReads, 0);
    }
    position.jumpTo(position.maxScrollExtent);
    await _frames(tester, 2);
    expect(_counterText(tester), '2 / 3');
    tester.view.physicalSize = const Size(375, 1800);
    await _frames(tester, 3);
    expect(identical(position, _position(tester)), isTrue);
    expect(position.pixels, closeTo(0, .01));
    expect(_counterText(tester), '1 / 3');
    expect(_counterText(tester), _counterFor(tester));
    expect(tester.getTopLeft(find.byKey(_head)).dy,
        closeTo(end - position.pixels, 1));
    expect(
        tester.getRect(find.byKey(const ValueKey('pixiv-image-42-2'))).bottom,
        closeTo(tester.getTopLeft(find.byKey(_head)).dy, 1));
    expect(_arrowOpacity(tester), closeTo(1 - _progress(tester, end), .02));
    expect(harness.probe.transitions, isEmpty);
    expect(harness.probe.authorReads, 0);
    expect(harness.probe.roots, 0);
    final corrected = _snapshot(tester, harness.probe,
        milliseconds: 0, phase: 'viewport-clamped');
    tester.view.physicalSize = const Size(812, 375);
    await _frames(tester, 3);
    expect(identical(position, _position(tester)), isTrue);
    const rotatedEnd = 812 * (1 + 2 + 1 / 1.5);
    final rotatedHeight = tester.getSize(find.byKey(_head)).height;
    expect(
        tester.getTopLeft(find.byKey(_head)).dy,
        closeTo(
            (rotatedEnd - position.pixels)
                .clamp(-double.infinity, 375 - rotatedHeight),
            1));
    expect(
        _arrowOpacity(tester), closeTo(1 - _progress(tester, rotatedEnd), .02));
    expect(_counterText(tester), _counterFor(tester));
    expect(harness.probe.transitions, isEmpty);
    expect(harness.probe.authorReads, 0);
    expect(harness.probe.roots, 0);
    expect(harness.probe.relatedReads, 0);
    final before = position.pixels;
    await tester.pump(const Duration(seconds: 1));
    expect(position.pixels, before);
    expect(tester.takeException(), isNull);
    await _capture(tester, harness.boundary, 'silent-geometry', {
      'frames': [
        corrected,
        _snapshot(tester, harness.probe,
            milliseconds: 1000, phase: 'rotated-idle')
      ],
      'sameMainPosition': true,
      'httpAttempts': deny.calls,
    });
  });

  testWidgets(
      '048 silent correctBy paints and hits corrected anchor in one frame',
      (tester) async {
    final harness = await _mount(tester);
    final probe = harness.probe;
    final position = _position(tester);
    final controller = _controller(tester);
    position.jumpTo(300);
    await _frames(tester, 2);
    expect(_counterText(tester), '1 / 3');
    final headElement = tester.element(find.byKey(_head));
    final baseCluster =
        _localRect(tester, _inHead(_cluster), find.byKey(_head));
    final before =
        _snapshot(tester, probe, milliseconds: 0, phase: 'before-correction');
    var normalNotifications = 0;
    void normalListener() => normalNotifications++;
    controller.addListener(normalListener);
    position.correctBy(180);
    final viewport = tester.renderObject<RenderViewport>(find.descendant(
        of: find.byKey(_main), matching: find.byType(Viewport)));
    viewport.markNeedsLayout();
    await tester.pump();
    controller.removeListener(normalListener);
    expect(normalNotifications, 0);
    expect(position.pixels, closeTo(480, .01));
    expect(identical(position, _position(tester)), isTrue);
    expect(identical(headElement, tester.element(find.byKey(_head))), isTrue);
    final header = tester.getRect(find.byKey(_head));
    expect(header.top, closeTo(1375 - position.pixels, 1));
    expect(
        tester.getRect(find.byKey(const ValueKey('pixiv-image-42-2'))).bottom,
        closeTo(header.top, 1));
    final p = _progress(tester, 1375);
    expect(_localRect(tester, _inHead(_cluster), find.byKey(_head)).left,
        closeTo(baseCluster.left - 52 * p, 1));
    final dynamic arrow = tester.renderObject(_inHead(_arrow));
    expect(arrow.visibleWidth as double, closeTo(52 * (1 - p), 1));
    expect(arrow.hitTest(BoxHitTestResult(), position: const Offset(5, 24)),
        isFalse);
    expect(probe.transitions, isEmpty);
    expect(probe.authorReads, 0);
    expect(probe.roots, 0);
    final corrected = _snapshot(tester, probe,
        milliseconds: 0, phase: 'corrected-single-pump');
    final correctedCluster = tester.getRect(_inHead(_cluster));
    await _frames(tester, 2);
    expect(_counterText(tester), _counterFor(tester));
    expect(_counterText(tester), '2 / 3');
    expect(position.pixels, closeTo(480, .01));
    _sameRect(tester.getRect(find.byKey(_head)), header);
    _sameRect(tester.getRect(_inHead(_cluster)), correctedCluster);
    expect(
        tester.getRect(find.byKey(const ValueKey('pixiv-image-42-2'))).bottom,
        closeTo(header.top, 1));
    final synchronized = _snapshot(tester, probe,
        milliseconds: 32, phase: 'counter-synchronized');
    await tester.tapAt(Offset(header.left + 21, header.top + 24));
    await tester.pump();
    expect(find.byKey(_panel), findsNothing);
    expect(probe.readImages, isEmpty);
    await _open(tester);
    _readOnce(probe);
    await _close(tester);
    expect(position.pixels, closeTo(480, .01));
    expect(find.byKey(_inline), findsNothing);
    await _frames(tester, 20);
    await _capture(tester, harness.boundary, 'silent-correction-paint', {
      'frames': [before, corrected, synchronized],
      'normalScrollNotifications': normalNotifications,
      'sameMainPosition': true,
      'sameHeaderElement': true,
      'httpAttempts': deny.calls,
    });
  });

  for (final spec in [
    (375.0, 1000.0, 1.0, false),
    (375.0, 1000.0, 2.0, false),
    (240.0, 850.0, 2.0, true),
    (812.0, 375.0, 1.0, false),
  ]) {
    testWidgets(
        '048 opening and closing have intermediate frames ${spec.$1} scale${spec.$3}',
        (tester) async {
      final harness = await _mount(tester,
          width: spec.$1,
          height: spec.$2,
          scale: spec.$3,
          dark: spec.$4,
          longText: spec.$3 > 1);
      final probe = harness.probe;
      final position = _position(tester);
      position.jumpTo(120);
      await _frames(tester, 2);
      final pixels = position.pixels;
      final controller = _controller(tester);
      await tester.tap(_inHead(_cluster));
      await tester.pump();
      final samples = <Map<String, Object?>>[];
      final opening = <double>[];
      ScrollController? panelController;
      State<StatefulWidget>? comments;
      _IdentityState? identity;
      await _frames(tester, 18, sample: (elapsed) async {
        expect(find.byKey(_panel), findsOneWidget);
        final rect = tester.getRect(find.byKey(_panel));
        opening.add(rect.top);
        expect(rect.height, closeTo(spec.$2 * .75, 1));
        expect(_scrimAlpha(tester), inInclusiveRange(0, .241));
        expect(_scrimAlpha(tester),
            closeTo(.24 * (spec.$2 - rect.top) / (spec.$2 * .75), .005));
        expect(position.pixels, closeTo(pixels, .01));
        expect(identical(position, _position(tester)), isTrue);
        expect(identical(controller, _controller(tester)), isTrue);
        panelController ??= _controller(tester, panel: true);
        expect(identical(panelController, _controller(tester, panel: true)),
            isTrue);
        comments ??= _comments(tester);
        identity ??= probe.alive.single;
        _singleDetails(tester, probe, comments: comments, identity: identity);
        samples.add(
            _snapshot(tester, probe, milliseconds: elapsed, phase: 'opening'));
        if (spec.$1 == 375 && spec.$3 == 1 && [16, 96, 176].contains(elapsed)) {
          await _capture(tester, harness.boundary, 'panel-opening-$elapsed', {
            'frame': samples.last,
            'httpAttempts': deny.calls,
          });
        }
      });
      expect(opening.any((top) => top > spec.$2 * .25 + 1 && top < spec.$2 - 1),
          isTrue);
      for (var i = 1; i < opening.length; i++) {
        expect(opening[i], lessThanOrEqualTo(opening[i - 1] + .01));
      }
      expect(opening.last, closeTo(spec.$2 * .25, 1));
      expect(_scrimAlpha(tester), closeTo(.24, .005));
      _readOnce(probe);
      if (spec.$1 == 375 && spec.$3 == 1) {
        await _capture(
            tester, harness.boundary, 'panel-open', {'frames': samples});
      }
      final closeSource = spec.$1 == 812 ? 'system-back' : 'header-toggle';
      if (spec.$1 == 812) {
        expect(await tester.binding.handlePopRoute(), isTrue);
      } else {
        await tester.tap(find.byKey(_panelToggle));
      }
      await tester.pump();
      expect(find.byType(PixivDetailShell), findsOneWidget);
      final closing = <double>[];
      await _frames(tester, 14, sample: (elapsed) async {
        if (find.byKey(_panel).evaluate().isNotEmpty) {
          final rect = tester.getRect(find.byKey(_panel));
          closing.add(rect.top);
          expect(_scrimAlpha(tester),
              closeTo(.24 * (spec.$2 - rect.top) / (spec.$2 * .75), .005));
          if (spec.$1 == 375 && spec.$3 == 1 && [64, 128].contains(elapsed)) {
            await _capture(tester, harness.boundary, 'panel-closing-$elapsed', {
              'frame': _snapshot(tester, probe,
                  milliseconds: elapsed, phase: 'closing'),
              'httpAttempts': deny.calls,
            });
          }
        }
        expect(position.pixels, closeTo(pixels, .01));
        expect(identical(position, _position(tester)), isTrue);
        _singleDetails(tester, probe, comments: comments, identity: identity);
        samples.add(_snapshot(tester, probe,
            milliseconds: 288 + elapsed, phase: 'closing'));
      });
      expect(closing.any((top) => top > spec.$2 * .25 + 1 && top < spec.$2 - 1),
          isTrue);
      for (var i = 1; i < closing.length; i++) {
        expect(closing[i], greaterThanOrEqualTo(closing[i - 1] - .01));
      }
      expect(find.byKey(_panel), findsNothing);
      expect(find.byKey(_scrim), findsNothing);
      expect(find.byKey(_inline), findsNothing);
      _readOnce(probe);
      await _frames(tester, 20);
      expect(position.pixels, closeTo(pixels, .01));
      await _capture(tester, harness.boundary,
          'panel-closed-${spec.$1.toInt()}-scale${spec.$3.toInt()}', {
        'frames': samples,
        'restoredPixels': pixels,
        'restoredMode': 'gallery',
        'closeSource': closeSource,
        'httpAttempts': deny.calls,
      });
    });
  }

  testWidgets(
      '048 real slow panel pointer only scrolls panel and preserves reads',
      (tester) async {
    final harness = await _mount(tester);
    final probe = harness.probe;
    final position = _position(tester);
    position.jumpTo(200);
    await _frames(tester, 2);
    await _open(tester);
    final before = position.pixels;
    final panelPosition = _position(tester, panel: true);
    final panelController = _controller(tester, panel: true);
    final comments = _comments(tester);
    final identity = probe.alive.single;
    final gesture = await tester.startGesture(const Offset(180, 650));
    var elapsed = 0;
    var moved = false;
    final frames = <Map<String, Object?>>[];
    for (final direction in [-1, 1]) {
      for (var i = 0; i < 20; i++) {
        elapsed += 64;
        await gesture.moveBy(Offset(0, direction * 8.0),
            timeStamp: Duration(milliseconds: elapsed));
        await _frames(tester, 4);
        moved = moved || panelPosition.pixels > 1;
        expect(position.pixels, before);
        expect(
            identical(panelPosition, _position(tester, panel: true)), isTrue);
        expect(identical(panelController, _controller(tester, panel: true)),
            isTrue);
        _singleDetails(tester, probe, comments: comments, identity: identity);
        frames.add({
          ..._snapshot(tester, probe,
              milliseconds: elapsed, phase: 'panel-drag'),
          'panelPixels': panelPosition.pixels,
        });
      }
    }
    await gesture.up(timeStamp: Duration(milliseconds: elapsed + 128));
    await _frames(tester, 8);
    expect(moved, isTrue);
    _readOnce(probe);
    await _close(tester, background: true);
    expect(position.pixels, before);
    _singleDetails(tester, probe, comments: comments, identity: identity);
    await _capture(tester, harness.boundary, 'panel-real-slow-pointer', {
      'frames': frames,
      'sameMainPosition': true,
      'samePanelController': true,
      'httpAttempts': deny.calls,
    });
  });

  for (final inline in [false, true]) {
    for (final lastRatio in [.5, 3.0]) {
      testWidgets(
          '048 close restores exact pixels and mode inline$inline last$lastRatio',
          (tester) async {
        final ratios = [1.0, .5, lastRatio];
        final harness = await _mount(tester, ratios: ratios);
        final probe = harness.probe;
        final position = _position(tester);
        final controller = _controller(tester);
        final end = 375 * (1 + 2 + 1 / lastRatio);
        if (inline) {
          await _inlineAtHead(tester, end);
        } else {
          position.jumpTo(200);
          await _frames(tester, 2);
        }
        final pixels = position.pixels;
        final maxExtent = position.maxScrollExtent;
        final mode = inline ? 'inline' : 'gallery';
        final head = tester.getRect(find.byKey(_head));
        final image = find.byKey(const ValueKey('pixiv-image-42-2'));
        final imageElement = tester.element(image);
        final imageRect = tester.getRect(image);
        final counter = tester
            .widget<Text>(find.byKey(const ValueKey('pixiv-image-counter')))
            .data;
        await _open(tester);
        final comments = _comments(tester);
        final identity = probe.alive.single;
        final panelController = _controller(tester, panel: true);
        _position(tester, panel: true)
            .jumpTo(_position(tester, panel: true).maxScrollExtent);
        await _frames(tester, 3);
        await _close(tester, background: lastRatio > 1);
        expect(identical(position, _position(tester)), isTrue);
        expect(identical(controller, _controller(tester)), isTrue);
        expect(position.pixels, closeTo(pixels, .01));
        final restoredMaxExtent = position.maxScrollExtent;
        if (!inline) {
          expect(restoredMaxExtent, closeTo(maxExtent, 1));
        }
        final mainSlivers =
            tester.widget<CustomScrollView>(find.byKey(_main)).slivers;
        expect(mainSlivers.whereType<SliverToBoxAdapter>(), hasLength(2),
            reason:
                'only reserved author anchor and original 88dp tail remain');
        expect(find.byKey(_inline), inline ? findsOneWidget : findsNothing);
        _sameRect(tester.getRect(find.byKey(_head)), head);
        _sameRect(tester.getRect(image), imageRect);
        expect(identical(imageElement, tester.element(image)), isTrue);
        expect(
            tester
                .widget<Text>(find.byKey(const ValueKey('pixiv-image-counter')))
                .data,
            counter);
        final h = head.height;
        expect(head.top,
            closeTo((end - pixels).clamp(-double.infinity, 1000 - h), 1));
        if (inline && head.top < 1000 - h - 1) {
          expect(imageRect.bottom, closeTo(head.top, 1),
              reason:
                  'flowing author header must join actual final-image edge');
        }
        _singleDetails(tester, probe, comments: comments, identity: identity);
        _readOnce(probe);
        final idle = position.pixels;
        await tester.pump(const Duration(seconds: 1));
        expect(position.pixels, closeTo(idle, .01));
        await _open(tester);
        expect(identical(panelController, _controller(tester, panel: true)),
            isTrue);
        _singleDetails(tester, probe, comments: comments, identity: identity);
        _readOnce(probe);
        await _close(tester);
        expect(position.pixels, closeTo(pixels, .01));
        expect(position.maxScrollExtent, closeTo(restoredMaxExtent, 1));
        if (!inline) {
          await tester.tapAt(const Offset(100, 300));
          expect(probe.readImages, [1],
              reason: 'closed scrim must release gallery hit testing');
        }
        await _frames(tester, 20);
        expect(position.pixels, closeTo(pixels, .01));
        await _capture(tester, harness.boundary,
            'restore-$mode-last${lastRatio.toString().replaceAll('.', '-')}', {
          'mode': mode,
          'pixelsBefore': pixels,
          'pixelsAfter': position.pixels,
          'maxExtentBefore': maxExtent,
          'maxExtentAfter': position.maxScrollExtent,
          'lastImageBottom': tester.getRect(image).bottom,
          'headerTop': tester.getRect(find.byKey(_head)).top,
          'httpAttempts': deny.calls,
        });
      });
    }
  }

  testWidgets(
      '048 download stays fixed and busy commands preserve panel target',
      (tester) async {
    final harness = await _mount(tester);
    final probe = harness.probe;
    final position = _position(tester);
    final base = _localRect(tester, _download(), find.byKey(_head));
    for (final pixels in [400.0, 483.0, 519.0]) {
      position.jumpTo(pixels);
      await _frames(tester, 2);
      _sameRect(_localRect(tester, _download(), find.byKey(_head)), base);
    }
    final download = _download();
    final ink = tester.widget<InkWell>(
        find.descendant(of: download, matching: find.byType(InkWell)).first);
    expect(ink.borderRadius, BorderRadius.circular(8));
    final box = tester.widget<DecoratedBox>(find
        .descendant(of: download, matching: find.byType(DecoratedBox))
        .first);
    expect((box.decoration as BoxDecoration).borderRadius,
        BorderRadius.circular(8));
    final icon = tester.widget<Icon>(
        find.descendant(of: download, matching: find.byType(Icon)).first);
    expect(icon.size, 18);
    final text = tester.widget<Text>(
        find.descendant(of: download, matching: find.text('下载')).first);
    expect(text.style!.fontSize, 12);
    expect(tester.getSize(download).height, greaterThanOrEqualTo(48));
    await tester.tap(download);
    await tester.longPress(download);
    expect(probe.downloads, 1);
    expect(probe.longDownloads, 1);
    expect(probe.transitions, isEmpty);
    await _open(tester);
    await tester.tap(_download(panel: true));
    await tester.longPress(_download(panel: true));
    expect(probe.downloads, 2);
    expect(probe.longDownloads, 2);
    expect(find.byKey(_panel), findsOneWidget);
    await tester.pumpWidget(_host(RepaintBoundary(
        key: harness.boundary,
        child:
            _Fixture(probe: probe, providers: harness.providers, busy: true))));
    await _frames(tester, 2);
    await tester.tap(_download(panel: true));
    await tester.longPress(_download(panel: true));
    expect(probe.downloads, 2);
    expect(probe.longDownloads, 2);
    expect(find.byKey(_panel), findsOneWidget);
    await _close(tester);
    expect(position.pixels, closeTo(519, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '048 rapid open close open reverses from current visible progress',
      (tester) async {
    final harness = await _mount(tester);
    final probe = harness.probe;
    final position = _position(tester);
    final controller = _controller(tester);
    final before = position.pixels;
    final frames = <Map<String, Object?>>[];
    await tester.tap(_inHead(_cluster));
    await tester.pump();
    await _frames(tester, 6);
    final beforeReverse = tester.getRect(find.byKey(_panel)).top;
    final comments = _comments(tester);
    final identity = probe.alive.single;
    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    expect(tester.getRect(find.byKey(_panel)).top, closeTo(beforeReverse, 1));
    await _frames(tester, 2);
    final beforeReopen = tester.getRect(find.byKey(_panel)).top;
    expect(beforeReopen, greaterThan(beforeReverse));
    final toggle = find.byKey(_panelToggle);
    expect(tester.widget<IconButton>(toggle).tooltip, '展开详情');
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.getRect(find.byKey(_panel)).top, closeTo(beforeReopen, 1));
    await _frames(tester, 18, sample: (elapsed) {
      expect(position.pixels, before);
      expect(identical(controller, _controller(tester)), isTrue);
      expect(identical(position, _position(tester)), isTrue);
      _singleDetails(tester, probe, comments: comments, identity: identity);
      frames.add(_snapshot(tester, probe,
          milliseconds: elapsed + 128, phase: 'reopen'));
    });
    expect(tester.getRect(find.byKey(_panel)).top, closeTo(250, 1));
    expect(_scrimAlpha(tester), closeTo(.24, .005));
    _readOnce(probe);
    await _close(tester);
    expect(position.pixels, before);
    _singleDetails(tester, probe, comments: comments, identity: identity);
    await _capture(
        tester, harness.boundary, 'rapid-reverse', {'frames': frames});
  });

  testWidgets(
      '048 reduced motion reaches endpoints next frame with same ownership',
      (tester) async {
    final harness = await _mount(tester, reduced: true);
    final probe = harness.probe;
    final position = _position(tester);
    await _inlineAtHead(tester, 1375);
    final before = position.pixels;
    await tester.tap(_inHead(_cluster));
    await tester.pump();
    expect(tester.getRect(find.byKey(_panel)).top, closeTo(250, 1));
    expect(_scrimAlpha(tester), closeTo(.24, .005));
    await _frames(tester, 3);
    final comments = _comments(tester);
    final identity = probe.alive.single;
    await tester.tap(find.byKey(_panelToggle));
    await tester.pump();
    expect(find.byKey(_panel), findsNothing);
    expect(find.byKey(_scrim), findsNothing);
    expect(find.byKey(_inline), findsOneWidget);
    expect(position.pixels, closeTo(before, .01));
    _singleDetails(tester, probe, comments: comments, identity: identity);
    await tester.pump(const Duration(seconds: 1));
    expect(position.pixels, closeTo(before, .01));
    expect(_arrowOpacity(tester), closeTo(1 - _progress(tester, 1375), .02));
    _readOnce(probe);
  });

  testWidgets(
      '048 same entry hides during close and resumes original inline ownership',
      (tester) async {
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    final harness = await _mount(tester, entryActive: active);
    final probe = harness.probe;
    await _inlineAtHead(tester, 1375);
    final position = _position(tester);
    final controller = _controller(tester);
    final pixels = position.pixels;
    final header = tester.getRect(find.byKey(_head));
    final fixtureState = tester.state(find.byType(_Fixture));
    final shellState = tester.state(find.byType(PixivDetailShell));
    final scopeElement = tester.element(find.byType(PixivDetailEntryScope));
    await _open(tester);
    final comments = _comments(tester);
    final identity = probe.alive.single;
    final panelController = _controller(tester, panel: true);
    _readOnce(probe);
    await tester.tap(find.byKey(_panelToggle));
    await tester.pump();
    await _frames(tester, 4);
    final closingRect = tester.getRect(find.byKey(_panel));
    expect(closingRect.top, inExclusiveRange(250, 1000));
    final closing = _snapshot(tester, probe,
        milliseconds: 64, phase: 'closing-before-hidden');
    final transitions = List<bool>.of(probe.transitions);
    active.value = false;
    await tester.pump();
    final hiddenShell = find.byType(PixivDetailShell, skipOffstage: false);
    expect(find.byKey(_panel), findsNothing);
    expect(find.byKey(_panel, skipOffstage: false), findsOneWidget);
    expect(identical(tester.state(hiddenShell), shellState), isTrue);
    expect(
        identical(tester.state(find.byType(_Fixture, skipOffstage: false)),
            fixtureState),
        isTrue);
    expect(
        identical(
            tester.element(
                find.byType(PixivDetailEntryScope, skipOffstage: false)),
            scopeElement),
        isTrue);
    expect(TickerMode.valuesOf(tester.element(hiddenShell)).enabled, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(_panel, skipOffstage: false), findsOneWidget);
    expect(probe.transitions, transitions);
    expect(position.pixels, closeTo(pixels, .01));
    expect(
        identical(
            tester
                .widget<CustomScrollView>(
                    find.byKey(_main, skipOffstage: false))
                .controller,
            controller),
        isTrue);
    expect(
        identical(
            tester
                .widget<CustomScrollView>(
                    find.byKey(_panelScroll, skipOffstage: false))
                .controller,
            panelController),
        isTrue);
    _singleDetails(tester, probe, comments: comments, identity: identity);
    _readOnce(probe);
    active.value = true;
    await tester.pump();
    await _frames(tester, 16);
    expect(identical(tester.state(find.byType(PixivDetailShell)), shellState),
        isTrue);
    expect(
        identical(tester.state(find.byType(_Fixture)), fixtureState), isTrue);
    expect(
        identical(
            tester.element(find.byType(PixivDetailEntryScope)), scopeElement),
        isTrue);
    expect(identical(position, _position(tester)), isTrue);
    expect(identical(controller, _controller(tester)), isTrue);
    expect(find.byKey(_panel, skipOffstage: false), findsNothing);
    expect(find.byKey(_scrim), findsNothing);
    expect(find.byKey(_inline), findsOneWidget);
    expect(position.pixels, closeTo(pixels, .01));
    _sameRect(tester.getRect(find.byKey(_head)), header);
    expect(probe.transitions, [...transitions, true]);
    _singleDetails(tester, probe, comments: comments, identity: identity);
    _readOnce(probe);
    await tester.pump(const Duration(seconds: 1));
    expect(position.pixels, closeTo(pixels, .01));
    expect(probe.transitions, [...transitions, true]);
    _singleDetails(tester, probe, comments: comments, identity: identity);
    _readOnce(probe);
    await _capture(tester, harness.boundary, 'hidden-closing-resume', {
      'frames': [
        closing,
        _snapshot(tester, probe,
            milliseconds: 2320, phase: 'resumed-inline-idle')
      ],
      'hiddenMilliseconds': 1000,
      'sameScopeElement': true,
      'sameFixtureState': true,
      'sameShellState': true,
      'sameCommentsState': true,
      'sameMainPosition': true,
      'restoredMode': 'inline',
      'restoredPixels': pixels,
      'httpAttempts': deny.calls,
    });
  });

  testWidgets('048 inactive entry does not open a panel or read data',
      (tester) async {
    final harness = await _mount(tester);
    await tester.pumpWidget(_host(PixivDetailEntryScope(
        entry: PixivDetailEntry(
            key: '42', comicId: '42', builder: (_) => const SizedBox()),
        isActive: false,
        child: TickerMode(
            enabled: false,
            child: _Fixture(
                probe: harness.probe, providers: harness.providers)))));
    await _frames(tester, 2);
    await tester.tap(_inHead(_cluster));
    await _frames(tester, 20);
    expect(find.byKey(_panel), findsNothing);
    expect(harness.probe.authorReads, 0);
    expect(harness.probe.roots, 0);
    expect(harness.probe.relatedReads, 0);
    expect(harness.probe.transitions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '048 work replacement and disposal cancel pending motion completions',
      (tester) async {
    final harness = await _mount(tester);
    final probe = harness.probe;
    await tester.tap(_inHead(_cluster));
    await tester.pump();
    await _frames(tester, 6);
    expect(find.byKey(_panel), findsOneWidget);
    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    await _frames(tester, 2);
    await tester.pumpWidget(_host(RepaintBoundary(
        key: harness.boundary,
        child:
            _Fixture(probe: probe, providers: harness.providers, id: '43'))));
    await _frames(tester, 24);
    expect(find.byKey(_panel), findsNothing);
    expect(find.byKey(_scrim), findsNothing);
    expect(find.byKey(const ValueKey('identity-42'), skipOffstage: false),
        findsNothing);
    expect(find.byKey(_inline), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(_inHead(_cluster));
    await tester.pump();
    await _frames(tester, 6);
    await tester.pumpWidget(const SizedBox());
    await _frames(tester, 24);
    expect(probe.alive, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

class _DenyHttp extends HttpOverrides {
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    calls++;
    throw StateError('048 fixtures must not open HTTP');
  }
}

Future<void> _fonts(WidgetTester tester) => tester.runAsync(() async {
      for (final font in [
        ('MotionCapture048', 'C:/Windows/Fonts/msyh.ttc'),
        (
          'MaterialIcons',
          'build/unit_test_assets/fonts/MaterialIcons-Regular.otf'
        ),
      ]) {
        final bytes = await File(font.$2).readAsBytes();
        await (FontLoader(font.$1)
              ..addFont(Future.value(ByteData.sublistView(bytes))))
            .load();
      }
    });

Future<List<MemoryImage>> _images(
    WidgetTester tester, List<double> ratios) async {
  final result = <MemoryImage>[];
  await tester.runAsync(() async {
    for (final (i, ratio) in ratios.indexed) {
      final height = (375 / ratio).round();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
          Rect.fromLTWH(0, 0, 375, height.toDouble()),
          Paint()
            ..color = [
              const Color(0xFFDFCCF6),
              const Color(0xFFC4DDF6),
              const Color(0xFFD3E6C7)
            ][i]);
      canvas.drawRect(Rect.fromLTWH(0, height - 12, 375, 12),
          Paint()..color = const Color(0xFF506B50));
      final text = TextPainter(
          text: TextSpan(
              text: '048 离线图片 ${i + 1}',
              style: const TextStyle(
                  fontFamily: 'MotionCapture048',
                  fontSize: 24,
                  color: Color(0xFF403653))),
          textDirection: TextDirection.ltr)
        ..layout();
      text.paint(canvas, const Offset(24, 24));
      text.dispose();
      final picture = recorder.endRecording();
      final image = await picture.toImage(375, height);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      result.add(MemoryImage(Uint8List.fromList(bytes.buffer.asUint8List())));
      image.dispose();
      picture.dispose();
    }
  });
  return result;
}

Future<void> _capture(WidgetTester tester, GlobalKey boundaryKey, String name,
    Map<String, Object?> extra) async {
  await tester.pump();
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
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
      'font': 'C:/Windows/Fonts/msyh.ttc',
      'images': 'local MemoryImage, no HTTP',
      'width': boundary.size.width,
      'height': boundary.size.height,
      ...extra,
    }));
  });
}
