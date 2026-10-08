import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/components/pixiv_bookmark_queue.dart';

const _feedbackKey = ValueKey('pixiv-bookmark-feedback');
const _longError =
    '收藏失败：网络连接暂不可用，服务器没有确认此次操作。请检查网络连接后重试；作品收藏状态保持平台确认值，不会把等待中的请求显示为已成功。';

PixivBookmarkQueueEntry _entry(
  int id, {
  PixivBookmarkQueueStatus status = PixivBookmarkQueueStatus.waiting,
  bool? target = true,
  bool private = false,
  bool exiting = false,
  String? text,
}) =>
    PixivBookmarkQueueEntry(
      operationId: id,
      workId: 'work-$id',
      status: status,
      target: target,
      isPrivate: private,
      exiting: exiting,
      text: text ??
          (status == PixivBookmarkQueueStatus.waiting
              ? target == null
                  ? '正在读取收藏状态…'
                  : target
                      ? '正在提交收藏…'
                      : '正在取消收藏…'
              : status == PixivBookmarkQueueStatus.failed
                  ? '收藏失败：服务器拒绝了请求，请稍后重试。'
                  : target == false
                      ? '已取消收藏'
                      : private
                          ? '已添加私密收藏'
                          : '已添加公开收藏'),
    );

Finder _item(int id) => find.byKey(ValueKey('pixiv-bookmark-queue-item-$id'));
Finder _animation(String kind, int id) =>
    find.byKey(ValueKey('pixiv-bookmark-queue-$kind-$id'));

double _opacity(WidgetTester tester, String kind, int id) =>
    tester.widget<FadeTransition>(_animation(kind, id)).opacity.value;
double _translation(WidgetTester tester, String kind, int id) =>
    tester.widget<Transform>(_animation(kind, id)).transform.entry(0, 3);
double _sizeFactor(WidgetTester tester, int id) =>
    tester.widget<SizeTransition>(_animation('exit-size', id)).sizeFactor.value;

class _Fixture {
  _Fixture(this.entries,
      {this.reduced = false,
      this.viewport = const Size(375, 720),
      this.scale = 1,
      this.brightness = Brightness.light});

  List<PixivBookmarkQueueEntry> entries;
  bool reduced;
  final Size viewport;
  final double scale;
  final Brightness brightness;
  late StateSetter change;
  final captureKey = GlobalKey();

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        brightness: brightness,
        fontFamily: 'QueueVerificationSans',
        useMaterial3: true,
      ),
      home: RepaintBoundary(
        key: captureKey,
        child: MediaQuery(
          data: MediaQueryData(
            size: viewport,
            textScaler: TextScaler.linear(scale),
            disableAnimations: reduced,
          ),
          child: Material(
            child: StatefulBuilder(builder: (context, setState) {
              change = setState;
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: PixivBookmarkQueueCapsule(
                    entries: entries,
                    reducedMotion: reduced,
                    showCounts: true,
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    ));
  }

  Future<void> update(
      WidgetTester tester, List<PixivBookmarkQueueEntry> next) async {
    change(() => entries = next);
    await tester.pump();
  }
}

Future<void> _loadVerificationFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    final sans = File('C:/Windows/Fonts/msyh.ttc');
    if (sans.existsSync()) {
      await (FontLoader('QueueVerificationSans')
            ..addFont(
                Future.value(ByteData.sublistView(await sans.readAsBytes()))))
          .load();
    }
    final material =
        File('build/unit_test_assets/fonts/MaterialIcons-Regular.otf');
    if (material.existsSync()) {
      await (FontLoader('MaterialIcons')
            ..addFont(Future.value(
                ByteData.sublistView(await material.readAsBytes()))))
          .load();
    }
  });
}

void main() {
  testWidgets('empty queue has no feedback semantics or animation',
      (tester) async {
    final fixture = _Fixture([]);
    await fixture.pump(tester);
    expect(find.byKey(_feedbackKey), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('entry fades and translates right to rest over real 180ms frames',
      (tester) async {
    final fixture = _Fixture([_entry(1)]);
    await fixture.pump(tester);
    expect(_opacity(tester, 'entrance-opacity', 1), 0);
    expect(_translation(tester, 'entrance-translation', 1), 12);
    final start = tester.getTopLeft(_item(1));
    await tester.pump(const Duration(milliseconds: 90));
    expect(_opacity(tester, 'entrance-opacity', 1), inExclusiveRange(0, 1));
    expect(_translation(tester, 'entrance-translation', 1),
        inExclusiveRange(0, 12));
    expect(tester.getTopLeft(_item(1)), start);
    await tester.pump(const Duration(milliseconds: 90));
    expect(_opacity(tester, 'entrance-opacity', 1), 1);
    expect(_translation(tester, 'entrance-translation', 1), 0);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(seconds: 5));
    expect(_opacity(tester, 'entrance-opacity', 1), 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
      'append preserves capsule and head state and only animates new tail',
      (tester) async {
    final fixture = _Fixture([_entry(1)]);
    await fixture.pump(tester);
    await tester.pumpAndSettle();
    final headState = tester.state(_item(1));
    final capsuleElement =
        find.byType(PixivBookmarkQueueCapsule).evaluate().single;
    await fixture.update(tester, [_entry(1), _entry(2)]);
    expect(tester.state(_item(1)), same(headState));
    expect(find.byType(PixivBookmarkQueueCapsule).evaluate().single,
        same(capsuleElement));
    expect(_opacity(tester, 'entrance-opacity', 1), 1);
    expect(_translation(tester, 'entrance-translation', 1), 0);
    expect(_opacity(tester, 'entrance-opacity', 2), 0);
    expect(_translation(tester, 'entrance-translation', 2), 12);
    await tester.pump(const Duration(milliseconds: 90));
    expect(_opacity(tester, 'entrance-opacity', 2), inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 90));
    expect(_translation(tester, 'entrance-translation', 2), 0);
    expect(tester.getTopLeft(_item(1)).dx,
        lessThan(tester.getTopLeft(_item(2)).dx));
    expect(tester.takeException(), isNull);
  });

  testWidgets('completion fills rose heart and peaks gently at real 80ms frame',
      (tester) async {
    final fixture = _Fixture([_entry(1)]);
    await fixture.pump(tester);
    await tester.pumpAndSettle();
    final state = tester.state(_item(1));
    await fixture.update(tester, [
      _entry(1, status: PixivBookmarkQueueStatus.completed),
    ]);
    expect(tester.state(_item(1)), same(state));
    expect(find.byKey(const ValueKey('pixiv-bookmark-queue-status-1-waiting')),
        findsNothing);
    expect(
        find.byKey(const ValueKey('pixiv-bookmark-queue-status-1-completed')),
        findsOneWidget);
    expect(tester.widget<Opacity>(_animation('heart-fill', 1)).opacity, 0);
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.widget<Opacity>(_animation('heart-fill', 1)).opacity,
        closeTo(.5, .01));
    expect(
        tester
            .widget<Transform>(_animation('completion-scale', 1))
            .transform
            .entry(0, 0),
        closeTo(1.1, .01));
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.widget<Opacity>(_animation('heart-fill', 1)).opacity, 1);
    expect(
        tester
            .widget<Transform>(_animation('completion-scale', 1))
            .transform
            .entry(0, 0),
        1);
    final heart = tester.widget<Icon>(
        find.descendant(of: _item(1), matching: find.byIcon(Icons.favorite)));
    expect(heart.color, const Color(0xFFB92E58));
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('only head slides left and collapses continuously over 240ms',
      (tester) async {
    final fixture = _Fixture([
      _entry(1, status: PixivBookmarkQueueStatus.completed),
      _entry(2),
      _entry(3, status: PixivBookmarkQueueStatus.completed),
    ]);
    await fixture.pump(tester);
    await tester.pumpAndSettle();
    final originalWidth = tester.getSize(_item(1)).width;
    final tailState = tester.state(_item(2));
    final originalTailX = tester.getTopLeft(_item(2)).dx;
    final capsuleElement =
        find.byType(PixivBookmarkQueueCapsule).evaluate().single;
    await fixture.update(tester, [
      _entry(1, status: PixivBookmarkQueueStatus.completed, exiting: true),
      _entry(2),
      _entry(3, status: PixivBookmarkQueueStatus.completed, exiting: true),
    ]);
    expect(_sizeFactor(tester, 1), 1);
    expect(_translation(tester, 'exit-translation', 1), 0);
    await tester.pump(const Duration(milliseconds: 120));
    expect(_sizeFactor(tester, 1), inExclusiveRange(0, 1));
    expect(_opacity(tester, 'exit-opacity', 1), inExclusiveRange(0, 1));
    expect(
        _translation(tester, 'exit-translation', 1), inExclusiveRange(-24, 0));
    expect(tester.getSize(_item(1)).width, inExclusiveRange(0, originalWidth));
    expect(tester.getTopLeft(_item(2)).dx, lessThan(originalTailX));
    expect(_sizeFactor(tester, 3), 1);
    expect(_translation(tester, 'exit-translation', 3), 0);
    expect(_opacity(tester, 'exit-opacity', 3), 1);
    await tester.pump(const Duration(milliseconds: 120));
    expect(_sizeFactor(tester, 1), 0);
    expect(_opacity(tester, 'exit-opacity', 1), 0);
    expect(_translation(tester, 'exit-translation', 1), -24);
    expect(tester.getSize(_item(1)).width, 0);
    expect(find.byType(PixivBookmarkQueueCapsule).evaluate().single,
        same(capsuleElement));
    await fixture.update(tester, [
      _entry(2),
      _entry(3, status: PixivBookmarkQueueStatus.completed, exiting: true),
    ]);
    expect(tester.state(_item(2)), same(tailState));
    expect(_opacity(tester, 'entrance-opacity', 2), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('exiting tail waits for its own turn at the head',
      (tester) async {
    final fixture = _Fixture([
      _entry(1),
      _entry(2, status: PixivBookmarkQueueStatus.completed, exiting: true),
    ]);
    await fixture.pump(tester);
    await tester.pumpAndSettle();
    final state = tester.state(_item(2));
    expect(_sizeFactor(tester, 2), 1);
    await fixture.update(tester, [
      _entry(2, status: PixivBookmarkQueueStatus.completed, exiting: true),
    ]);
    expect(tester.state(_item(2)), same(state));
    await tester.pump(const Duration(milliseconds: 120));
    expect(_sizeFactor(tester, 2), inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 120));
    expect(_sizeFactor(tester, 2), 0);
  });

  testWidgets(
      'single pending, add, private, remove and failed states stay distinct',
      (tester) async {
    final fixture = _Fixture([_entry(1, target: null)], reduced: true);
    await fixture.pump(tester);
    expect(find.text('正在读取收藏状态…'), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(find.byIcon(Icons.more_horiz), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(RotationTransition), findsNothing);
    await fixture.update(tester, [
      _entry(1, status: PixivBookmarkQueueStatus.completed, private: true),
    ]);
    expect(find.text('已添加私密收藏'), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    await fixture.update(tester, [
      _entry(1, status: PixivBookmarkQueueStatus.completed, target: false),
    ]);
    expect(find.text('已取消收藏'), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsNothing);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    await fixture.update(tester, [
      _entry(1, status: PixivBookmarkQueueStatus.failed, text: _longError),
    ]);
    expect(find.text(_longError), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('one live region reads all counts and full latest error',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final fixture = _Fixture([
      _entry(1),
      _entry(2, status: PixivBookmarkQueueStatus.failed, text: _longError),
      _entry(3, status: PixivBookmarkQueueStatus.completed),
      _entry(4),
    ], reduced: true);
    await fixture.pump(tester);
    final node = tester.getSemantics(find.byKey(_feedbackKey));
    expect(node.label, '2 项等待 · 1 项完成 · 1 项失败。已添加公开收藏。最近错误：$_longError');
    expect(node.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
    expect(find.text('2 项等待 · 1 项完成 · 1 项失败 · $_longError'), findsOneWidget);
    expect(node.childrenCount, 0);
    expect(find.byKey(_feedbackKey), findsOneWidget);
    await fixture.update(tester, [_entry(1), _entry(4, target: null)]);
    expect(tester.getSemantics(find.byKey(_feedbackKey)).label,
        '2 项等待 · 0 项完成。正在读取收藏状态…');
    expect(tester.getSemantics(find.byKey(_feedbackKey)).label,
        isNot(contains('已添加')));
    semantics.dispose();
  });

  testWidgets('latest caption uses result, otherwise current reading',
      (tester) async {
    final fixture =
        _Fixture([_entry(1), _entry(2, target: null)], reduced: true);
    await fixture.pump(tester);
    expect(find.text('2 项等待 · 0 项完成 · 正在读取收藏状态…'), findsOneWidget);
    await fixture.update(tester, [
      _entry(1, status: PixivBookmarkQueueStatus.completed, target: false),
      _entry(2, target: null),
    ]);
    expect(find.text('1 项等待 · 1 项完成 · 已取消收藏'), findsOneWidget);
    await fixture.update(tester, [
      _entry(1, status: PixivBookmarkQueueStatus.completed, target: false),
      _entry(2, status: PixivBookmarkQueueStatus.failed, text: _longError),
      _entry(3),
    ]);
    expect(find.text('1 项等待 · 1 项完成 · 1 项失败 · $_longError'), findsOneWidget);
  });

  for (final width in [160.0, 320.0, 375.0, 812.0]) {
    testWidgets('width $width folds views but preserves every pending count',
        (tester) async {
      final fixture = _Fixture(List.generate(17, (index) => _entry(index + 1)),
          viewport: Size(width, width == 812 ? 375 : 720),
          scale: 2,
          reduced: true);
      await fixture.pump(tester);
      final visible = List.generate(17, (index) => _item(index + 1))
          .where((finder) => finder.evaluate().isNotEmpty)
          .length;
      expect(visible, inInclusiveRange(1, 5));
      expect(find.text('＋${17 - visible}'), findsOneWidget);
      expect(find.text('17 项等待 · 0 项完成 · 正在提交收藏…'), findsOneWidget);
      expect(fixture.entries.length, 17);
      final strip = tester
          .getRect(find.byKey(const ValueKey('pixiv-bookmark-queue-strip')));
      final folded = tester
          .getRect(find.byKey(const ValueKey('pixiv-bookmark-queue-folded')));
      expect(folded.right, lessThanOrEqualTo(strip.right + .01));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('reduced motion is static across entrance, completion and exit',
      (tester) async {
    final fixture = _Fixture([_entry(1), _entry(2)], reduced: true);
    await fixture.pump(tester);
    expect(_opacity(tester, 'entrance-opacity', 1), 1);
    expect(_translation(tester, 'entrance-translation', 1), 0);
    expect(tester.binding.transientCallbackCount, 0);
    await fixture.update(tester, [
      _entry(1, status: PixivBookmarkQueueStatus.completed),
      _entry(2),
    ]);
    expect(tester.widget<Opacity>(_animation('heart-fill', 1)).opacity, 1);
    expect(
        tester
            .widget<Transform>(_animation('completion-scale', 1))
            .transform
            .entry(0, 0),
        1);
    expect(tester.binding.transientCallbackCount, 0);
    await fixture.update(tester, [
      _entry(1, status: PixivBookmarkQueueStatus.completed, exiting: true),
      _entry(2),
    ]);
    expect(_sizeFactor(tester, 1), 0);
    expect(_opacity(tester, 'exit-opacity', 1), 0);
    expect(_sizeFactor(tester, 2), 1);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(seconds: 10));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('turning reduced motion on stops in-progress controllers',
      (tester) async {
    final fixture = _Fixture([_entry(1)]);
    await fixture.pump(tester);
    await tester.pump(const Duration(milliseconds: 30));
    fixture.change(() => fixture.reduced = true);
    await tester.pump();
    expect(_opacity(tester, 'entrance-opacity', 1), 1);
    expect(_translation(tester, 'entrance-translation', 1), 0);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
      'disposal interrupts entrance, completion and exit without tickers',
      (tester) async {
    final fixture = _Fixture([_entry(1), _entry(2)]);
    await fixture.pump(tester);
    await tester.pump(const Duration(milliseconds: 30));
    await fixture.update(tester, [
      _entry(1, status: PixivBookmarkQueueStatus.completed, exiting: true),
      _entry(2, status: PixivBookmarkQueueStatus.completed),
      _entry(3),
    ]);
    await tester.pump(const Duration(milliseconds: 30));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  for (final spec in <(String, Size, Brightness, double, String)>[
    ('queue-light', const Size(375, 720), Brightness.light, 1, 'mixed'),
    ('queue-dark', const Size(375, 720), Brightness.dark, 1, 'mixed'),
    ('queue-single', const Size(375, 720), Brightness.light, 1, 'private'),
    ('queue-waiting', const Size(320, 720), Brightness.light, 1, 'waiting'),
    ('queue-large-error', const Size(320, 720), Brightness.light, 2, 'error'),
    ('queue-landscape', const Size(812, 375), Brightness.dark, 2, 'error'),
  ]) {
    testWidgets('actual Flutter render fits full text for ${spec.$1}',
        (tester) async {
      await _loadVerificationFonts(tester);
      final entries = spec.$5 == 'private'
          ? [
              _entry(1,
                  status: PixivBookmarkQueueStatus.completed, private: true)
            ]
          : spec.$5 == 'waiting'
              ? List.generate(13, (index) => _entry(index + 1))
              : [
                  _entry(1, status: PixivBookmarkQueueStatus.completed),
                  _entry(2,
                      status: PixivBookmarkQueueStatus.completed,
                      target: false),
                  _entry(3),
                  _entry(4, private: true),
                  _entry(5,
                      status: spec.$5 == 'error'
                          ? PixivBookmarkQueueStatus.failed
                          : PixivBookmarkQueueStatus.completed,
                      text: spec.$5 == 'error' ? _longError : null),
                  _entry(6),
                  _entry(7),
                ];
      final fixture = _Fixture(entries,
          viewport: spec.$2,
          brightness: spec.$3,
          scale: spec.$4,
          reduced: true);
      await fixture.pump(tester);
      final rect = tester.getRect(find.byKey(_feedbackKey));
      expect(rect.width, lessThanOrEqualTo(420));
      expect(rect.height, greaterThanOrEqualTo(48));
      expect(rect.left, greaterThanOrEqualTo(16));
      expect(rect.right, lessThanOrEqualTo(spec.$2.width - 16));
      expect(rect.top, greaterThanOrEqualTo(16));
      expect(rect.bottom, lessThanOrEqualTo(spec.$2.height - 16));
      final textWidgets = tester.widgetList<Text>(find.descendant(
          of: find.byKey(_feedbackKey), matching: find.byType(Text)));
      final paragraphs = tester.renderObjectList<RenderParagraph>(
          find.descendant(
              of: find.byKey(_feedbackKey), matching: find.byType(RichText)));
      expect(
          textWidgets.every((text) => text.overflow != TextOverflow.ellipsis),
          isTrue);
      expect(paragraphs.every((text) => !text.didExceedMaxLines), isTrue);
      if (spec.$5 == 'error') {
        final caption = tester.widget<Text>(
            find.byKey(const ValueKey('pixiv-bookmark-queue-caption')));
        expect(caption.data, endsWith(_longError));
        expect(caption.maxLines, isNull);
      }
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary = fixture.captureKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = File(
              'docs/verification/pixiv-bookmark-queue-counts-036/${spec.$1}.png');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(data!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
    });
  }
}
