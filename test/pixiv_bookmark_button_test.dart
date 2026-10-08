import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/components/pixiv_bookmark_button.dart';
import 'package:picakeep/pages/online_common/online_waterfall_card.dart';

const _buttonKey = ValueKey('test-bookmark');
const _mainScaleKey = ValueKey('pixiv-bookmark-main-scale');
const _mainIconKey = ValueKey('pixiv-bookmark-main-icon');
const _ringKey = ValueKey('pixiv-bookmark-ring');
const _fallIconKey = ValueKey('pixiv-bookmark-fall-icon');

Widget _fixture({
  bool bookmarked = false,
  bool known = true,
  bool busy = false,
  bool enabled = true,
  bool active = true,
  bool reduced = false,
  bool ticker = true,
  Object? identity = 'account:artwork',
  Object? visualEpoch = 0,
  PixivBookmarkEvent? event,
  VoidCallback? onPressed,
  VoidCallback? onLongPress,
  VoidCallback? onParent,
  double size = 48,
  double iconSize = 22,
}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: TickerMode(
          enabled: ticker,
          child: Center(
            child: GestureDetector(
              onTap: onParent,
              behavior: HitTestBehavior.opaque,
              child: SizedBox.square(
                dimension: 200,
                child: Center(
                  child: PixivBookmarkButton(
                    key: _buttonKey,
                    isBookmarked: bookmarked,
                    stateKnown: known,
                    busy: busy,
                    enabled: enabled,
                    active: active,
                    identity: identity,
                    visualEpoch: visualEpoch,
                    event: event,
                    onPressed: onPressed,
                    onLongPress: onLongPress,
                    size: size,
                    iconSize: iconSize,
                    circularBackground: size == 56,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

Finder get _button => find.byKey(_buttonKey);
double _scale(WidgetTester tester, [Key key = _mainScaleKey]) =>
    tester.widget<Transform>(find.byKey(key)).transform.entry(0, 0);
IconData? _mainIcon(WidgetTester tester) =>
    tester.widget<Icon>(find.byKey(_mainIconKey)).icon;
double _opacity(WidgetTester tester, String key) =>
    tester.widget<Opacity>(find.byKey(ValueKey(key))).opacity;

const _add = PixivBookmarkEvent(
  sequence: 2,
  operationId: 1,
  phase: PixivBookmarkPhase.begin,
  target: true,
);
const _remove = PixivBookmarkEvent(
  sequence: 2,
  operationId: 1,
  phase: PixivBookmarkPhase.begin,
  target: false,
);
PixivBookmarkEvent _settle({
  int sequence = 3,
  int operationId = 1,
  bool success = true,
  PixivBookmarkEvent? begin,
}) =>
    PixivBookmarkEvent(
      sequence: sequence,
      operationId: operationId,
      phase: PixivBookmarkPhase.settle,
      success: success,
      begin: begin,
    );

void main() {
  testWidgets(
      'ordinary press has only a state layer; cancel never begins motion',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(_fixture(onPressed: () => calls++));
    final gesture = await tester.startGesture(tester.getCenter(_button));
    await tester.pump();
    expect(find.byKey(const ValueKey('pixiv-bookmark-press-layer')),
        findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_scale(tester), 1);
    expect(_mainIcon(tester), Icons.favorite_border);
    await gesture.cancel();
    await tester.pump();
    expect(
        find.byKey(const ValueKey('pixiv-bookmark-press-layer')), findsNothing);
    expect(_scale(tester), 1);
    expect(calls, 0);
  });

  testWidgets('tap, long press and drag use single gesture paths',
      (tester) async {
    var taps = 0;
    var longs = 0;
    await tester.pumpWidget(_fixture(
      onPressed: () => taps++,
      onLongPress: () => longs++,
    ));
    await tester.tap(_button);
    await tester.longPress(_button);
    expect(taps, 1);
    expect(longs, 1);
    final gesture = await tester.startGesture(tester.getCenter(_button));
    await gesture.moveBy(const Offset(100, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(longs, 1);
    expect(_scale(tester), 1);
  });

  testWidgets(
      'passive busy remains authoritative without a waiting ring or ticker',
      (tester) async {
    await tester.pumpWidget(_fixture(busy: true));
    await tester.pump(const Duration(seconds: 3));
    expect(_mainIcon(tester), Icons.favorite_border);
    expect(find.descendant(of: _button, matching: find.byType(CustomPaint)),
        findsNothing);
    expect(find.byKey(const ValueKey('pixiv-bookmark-waiting')), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(_fixture(bookmarked: true, busy: true));
    expect(_mainIcon(tester), Icons.favorite);
    expect(_scale(tester), 1);
  });

  testWidgets('accepted unknown state never guesses an add or remove direction',
      (tester) async {
    await tester.pumpWidget(_fixture(known: false));
    await tester.pumpWidget(_fixture(
      bookmarked: true,
      known: false,
      busy: true,
      event: const PixivBookmarkEvent(
        sequence: 1,
        operationId: 1,
        phase: PixivBookmarkPhase.accepted,
      ),
    ));
    await tester.pump(const Duration(seconds: 2));
    expect(_mainIcon(tester), Icons.favorite_border);
    expect(_scale(tester), 1);
    expect(find.byKey(_ringKey), findsNothing);
    expect(find.byKey(_fallIconKey), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await tester
        .pumpWidget(_fixture(known: false, event: _settle(success: false)));
    expect(_mainIcon(tester), Icons.favorite_border);
    expect(_scale(tester), 1);
  });

  testWidgets('first-bound events including carried begin stay static',
      (tester) async {
    await tester
        .pumpWidget(_fixture(bookmarked: true, event: _settle(begin: _add)));
    expect(_mainIcon(tester), Icons.favorite);
    expect(_scale(tester), 1);
    expect(find.byKey(_ringKey), findsNothing);
    await tester.pumpWidget(_fixture(event: _settle(begin: _add)));
    expect(_mainIcon(tester), Icons.favorite_border);
    expect(_scale(tester), 1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_scale(tester), 1);
  });

  testWidgets('add uses 100ms cosine shrink then 200ms tension-2 overshoot',
      (tester) async {
    await tester.pumpWidget(_fixture());
    await tester.pumpWidget(_fixture(busy: true, event: _add));
    expect(_mainIcon(tester), Icons.favorite_border);
    await tester.pump(const Duration(milliseconds: 25));
    expect(_scale(tester), closeTo(.8681980515, .00001));
    await tester.pump(const Duration(milliseconds: 25));
    expect(_scale(tester), closeTo(.55, .00001));
    await tester.pump(const Duration(milliseconds: 50));
    expect(_scale(tester), closeTo(.1, .00001));
    expect(_mainIcon(tester), Icons.favorite);
    expect(tester.getSize(find.byKey(_ringKey)), const Size(30, 30));
    expect(_opacity(tester, 'pixiv-bookmark-ring-alpha'), 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_scale(tester), closeTo(1.1125, .00001));
    expect(_scale(tester, const ValueKey('pixiv-bookmark-ring-scale')),
        closeTo(1.15, .00001));
    expect(_opacity(tester, 'pixiv-bookmark-ring-alpha'), closeTo(.25, .00001));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_scale(tester), 1);
    expect(find.byKey(_ringKey), findsNothing);
    // The still unconfirmed target survives the end of the 300ms motion.
    expect(_mainIcon(tester), Icons.favorite);
    await tester.pump(const Duration(seconds: 2));
    expect(_mainIcon(tester), Icons.favorite);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('busy changes do not interrupt a begin motion', (tester) async {
    await tester.pumpWidget(_fixture());
    await tester.pumpWidget(_fixture(event: _add));
    await tester.pump(const Duration(milliseconds: 25));
    final scale = _scale(tester);
    await tester.pumpWidget(_fixture(busy: true, event: _add));
    expect(_scale(tester), scale);
    await tester.pump(const Duration(milliseconds: 75));
    expect(_scale(tester), closeTo(.1, .00001));
    await tester.pumpWidget(_fixture(event: _add));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_mainIcon(tester), Icons.favorite);
    expect(_scale(tester), 1);
  });

  for (final milliseconds in [10, 700, 2500]) {
    testWidgets('success at ${milliseconds}ms confirms without replay',
        (tester) async {
      await tester.pumpWidget(_fixture());
      await tester.pumpAndSettle();
      await tester.pumpWidget(_fixture(busy: true, event: _add));
      await tester.pump(Duration(milliseconds: milliseconds));
      final scale = _scale(tester);
      await tester
          .pumpWidget(_fixture(bookmarked: true, event: _settle(begin: _add)));
      expect(_scale(tester), scale);
      if (milliseconds < 100) {
        expect(_mainIcon(tester), Icons.favorite_border);
        await tester.pump(Duration(milliseconds: 100 - milliseconds));
        expect(_scale(tester), closeTo(.1, .00001));
        expect(_mainIcon(tester), Icons.favorite);
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(_scale(tester), 1);
      expect(_mainIcon(tester), Icons.favorite);
      expect(find.byKey(_ringKey), findsNothing);
      // Flutter's interpolation simulation stops on time > duration.
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
    });
  }

  for (final target in [true, false]) {
    testWidgets(
        'coalesced begin and settle retain first ${target ? 'add' : 'remove'} motion',
        (tester) async {
      final begin = target ? _add : _remove;
      await tester.pumpWidget(_fixture(bookmarked: !target));
      // Only settle reaches the widget: Future.value completed before a frame.
      await tester.pumpWidget(_fixture(
        bookmarked: target,
        event: _settle(begin: begin),
      ));
      expect(_scale(tester), target ? 1 : .1);
      expect(_mainIcon(tester), Icons.favorite_border);
      await tester.pump(const Duration(milliseconds: 50));
      expect(_scale(tester), lessThan(1));
      await tester.pumpAndSettle();
      expect(
          _mainIcon(tester), target ? Icons.favorite : Icons.favorite_border);
      expect(_scale(tester), 1);
      await tester.pumpWidget(_fixture(
        bookmarked: target,
        event: _settle(sequence: 4, begin: begin),
      ));
      expect(_scale(tester), 1);
      expect(tester.binding.transientCallbackCount, 0);
    });
  }

  testWidgets(
      'remove uses 500ms height and 36 degrees with independent 300ms alpha',
      (tester) async {
    await tester.pumpWidget(_fixture(bookmarked: true, iconSize: 32));
    await tester.pumpWidget(
        _fixture(bookmarked: true, busy: true, event: _remove, iconSize: 32));
    expect(_mainIcon(tester), Icons.favorite_border);
    expect(_scale(tester), closeTo(.1, .00001));
    expect(_opacity(tester, 'pixiv-bookmark-fall-alpha'), 1);
    await tester.pump(const Duration(milliseconds: 250));
    expect(_scale(tester), closeTo(.55, .00001));
    final translation = tester.widget<Transform>(
        find.byKey(const ValueKey('pixiv-bookmark-fall-translation')));
    expect(translation.transform.entry(1, 3), closeTo(16, .00001));
    final rotation = tester.widget<Transform>(
        find.byKey(const ValueKey('pixiv-bookmark-fall-rotation')));
    expect(rotation.transform.entry(0, 0),
        closeTo(math.cos(18 * math.pi / 180), .00001));
    expect(_opacity(tester, 'pixiv-bookmark-fall-alpha'),
        closeTo(.0669872981, .00001));
    await tester.pump(const Duration(milliseconds: 50));
    expect(_opacity(tester, 'pixiv-bookmark-fall-alpha'), 0);
    expect(_scale(tester), lessThan(1));
    await tester.pump(const Duration(milliseconds: 100));
    final laterTranslation = tester.widget<Transform>(
        find.byKey(const ValueKey('pixiv-bookmark-fall-translation')));
    expect(
        laterTranslation.transform.entry(1, 3), closeTo(28.94427191, .00001));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(_fallIconKey), findsNothing);
    expect(_scale(tester), 1);
    expect(_mainIcon(tester), Icons.favorite_border);
    // Authority was not changed; success releases the target without replay.
    await tester
        .pumpWidget(_fixture(bookmarked: true, event: _settle(), iconSize: 32));
    expect(_mainIcon(tester), Icons.favorite);
    expect(_scale(tester), 1);
  });

  testWidgets(
      'duplicate begin and stale settle cannot replace the current operation',
      (tester) async {
    await tester.pumpWidget(_fixture());
    await tester.pumpWidget(_fixture(busy: true, event: _add));
    await tester.pump(const Duration(milliseconds: 150));
    final before = _scale(tester);
    await tester.pumpWidget(_fixture(
        busy: true,
        event: const PixivBookmarkEvent(
          sequence: 3,
          operationId: 1,
          phase: PixivBookmarkPhase.begin,
          target: true,
        )));
    expect(_scale(tester), before);
    await tester.pumpWidget(_fixture(
        bookmarked: true,
        event: const PixivBookmarkEvent(
          sequence: 4,
          operationId: 2,
          phase: PixivBookmarkPhase.begin,
          target: false,
        )));
    expect(_scale(tester), closeTo(.1, .00001));
    await tester.pump(const Duration(milliseconds: 500));
    await tester
        .pumpWidget(_fixture(bookmarked: true, event: _settle(sequence: 5)));
    expect(_mainIcon(tester), Icons.favorite_border);
    await tester.pumpWidget(_fixture(
        bookmarked: true, event: _settle(sequence: 6, operationId: 2)));
    expect(_mainIcon(tester), Icons.favorite);
    await tester.pumpWidget(_fixture(event: _add));
    expect(_mainIcon(tester), Icons.favorite_border);
    expect(_scale(tester), 1);
  });

  testWidgets('settle without begin never invents a result animation',
      (tester) async {
    for (final success in [true, false]) {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_fixture(known: false, busy: true));
      await tester.pumpWidget(
          _fixture(bookmarked: true, event: _settle(success: success)));
      expect(_mainIcon(tester), Icons.favorite);
      expect(_scale(tester), 1);
      expect(find.byKey(_ringKey), findsNothing);
      expect(find.byKey(_fallIconKey), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    }
  });

  testWidgets(
      'failure fades to latest known authority in 140ms without reverse motion',
      (tester) async {
    await tester.pumpWidget(_fixture(known: false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_fixture(known: false, busy: true, event: _remove));
    await tester.pump(const Duration(milliseconds: 500));
    expect(_mainIcon(tester), Icons.favorite_border);
    await tester.pumpWidget(_fixture(
        bookmarked: true, known: true, event: _settle(success: false)));
    expect(_mainIcon(tester), Icons.favorite);
    expect(_opacity(tester, 'pixiv-bookmark-restore-alpha'), 0);
    expect(_scale(tester), 1);
    expect(find.byKey(_ringKey), findsNothing);
    expect(find.byKey(_fallIconKey), findsNothing);
    await tester.pump(const Duration(milliseconds: 70));
    expect(
        _opacity(tester, 'pixiv-bookmark-restore-alpha'), closeTo(.5, .00001));
    await tester.pump(const Duration(milliseconds: 70));
    expect(find.byKey(const ValueKey('pixiv-bookmark-restore-alpha')),
        findsNothing);
    expect(_mainIcon(tester), Icons.favorite);
    await tester.pump(const Duration(milliseconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('unknown read failure retains unknown semantics and no motion',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_fixture(known: false, bookmarked: true));
    await tester.pumpWidget(_fixture(
        known: false, bookmarked: true, event: _settle(success: false)));
    final node = tester.getSemantics(_button);
    expect(node.flagsCollection.isToggled.toBoolOrNull(), isNull);
    expect(node.label, '切换平台收藏');
    expect(_mainIcon(tester), Icons.favorite_border);
    expect(tester.binding.transientCallbackCount, 0);
    handle.dispose();
  });

  testWidgets(
      'pending is local; semantics use authority and explicitly remain unconfirmed',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_fixture(onPressed: () {}));
    await tester
        .pumpWidget(_fixture(busy: true, event: _add, onPressed: () {}));
    await tester.pump(const Duration(milliseconds: 300));
    final node = tester.getSemantics(_button);
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.flagsCollection.isToggled.toBoolOrNull(), isFalse);
    expect(node.flagsCollection.isEnabled.toBoolOrNull(), isFalse);
    expect(node.label, '正在添加收藏，尚未确认');
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    var buttonCount = 0;
    void countButtons(SemanticsNode current) {
      if (current.flagsCollection.isButton) buttonCount++;
      current.visitChildren((child) {
        countButtons(child);
        return true;
      });
    }

    countButtons(node.owner!.rootSemanticsNode!);
    expect(buttonCount, 1);
    await tester.pumpWidget(
        _fixture(bookmarked: true, event: _settle(), onPressed: () {}));
    expect(tester.getSemantics(_button).label, '取消平台收藏');
    handle.dispose();
  });

  testWidgets(
      'two buttons share authority but only initiating button has a pending target',
      (tester) async {
    Widget pair(PixivBookmarkEvent? event) => MaterialApp(
            home: Center(
                child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PixivBookmarkButton(
                key: _buttonKey, isBookmarked: false, busy: true, event: event),
            const PixivBookmarkButton(
                key: ValueKey('passive'), isBookmarked: false, busy: true),
          ],
        )));
    await tester.pumpWidget(pair(null));
    await tester.pumpWidget(pair(_add));
    await tester.pump(const Duration(milliseconds: 300));
    final own = find.descendant(of: _button, matching: find.byType(Icon));
    final passive = find.descendant(
        of: find.byKey(const ValueKey('passive')), matching: find.byType(Icon));
    expect(tester.widget<Icon>(own).icon, Icons.favorite);
    expect(tester.widget<Icon>(passive).icon, Icons.favorite_border);
  });

  testWidgets(
      'busy, disabled and inactive swallow only their own taps and long presses',
      (tester) async {
    var childCalls = 0;
    var parentCalls = 0;
    for (final status in ['busy', 'disabled', 'inactive']) {
      await tester.pumpWidget(_fixture(
        busy: status == 'busy',
        enabled: status != 'disabled',
        active: status != 'inactive',
        onPressed: () => childCalls++,
        onLongPress: () => childCalls++,
        onParent: () => parentCalls++,
      ));
      await tester.tap(_button);
      await tester.longPress(_button);
      expect(childCalls, 0);
      expect(parentCalls, ['busy', 'disabled', 'inactive'].indexOf(status));
      await tester
          .tapAt(tester.getRect(_button).bottomCenter + const Offset(0, 4));
      expect(parentCalls, ['busy', 'disabled', 'inactive'].indexOf(status) + 1);
    }
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'keyboard focus is visible; Enter, Space and semantics activate once',
      (tester) async {
    final handle = tester.ensureSemantics();
    var calls = 0;
    await tester.pumpWidget(_fixture(onPressed: () => calls++));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final detector = tester.widget<FocusableActionDetector>(find.descendant(
      of: _button,
      matching: find.byType(FocusableActionDetector),
    ));
    expect(detector.focusNode!.hasFocus, isTrue);
    final decoration = tester
        .widget<DecoratedBox>(find.descendant(
          of: _button,
          matching: find.byType(DecoratedBox),
        ))
        .decoration as BoxDecoration;
    expect(decoration.border, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    final node = tester.getSemantics(_button);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    expect(calls, 3);
    await tester.pumpWidget(_fixture(busy: true, onPressed: () => calls++));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(calls, 3);
    handle.dispose();
  });

  testWidgets('reduce motion keeps static pending target until real settlement',
      (tester) async {
    await tester.pumpWidget(_fixture());
    await tester.pumpWidget(_fixture(busy: true, event: _add));
    await tester.pump(const Duration(milliseconds: 25));
    await tester.pumpWidget(_fixture(reduced: true, busy: true, event: _add));
    expect(_scale(tester), 1);
    expect(_mainIcon(tester), Icons.favorite);
    expect(find.byKey(_ringKey), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(_fixture(busy: true, event: _add));
    expect(_mainIcon(tester), Icons.favorite);
    expect(tester.binding.transientCallbackCount, 0);
    await tester
        .pumpWidget(_fixture(event: _settle(success: false), reduced: true));
    expect(_mainIcon(tester), Icons.favorite_border);
    expect(_scale(tester), 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
      'begin under reduce motion resolves unknown direction without transforms',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_fixture(reduced: true, known: false));
    await tester.pumpWidget(
        _fixture(reduced: true, known: false, busy: true, event: _remove));
    expect(_mainIcon(tester), Icons.favorite_border);
    expect(_scale(tester), 1);
    expect(find.byKey(_fallIconKey), findsNothing);
    expect(tester.getSemantics(_button).label, '正在取消收藏，尚未确认');
    expect(
        tester.getSemantics(_button).flagsCollection.isToggled.toBoolOrNull(),
        isNull);
    expect(tester.binding.transientCallbackCount, 0);
    handle.dispose();
  });

  for (final boundary in ['identity', 'epoch', 'active', 'enabled', 'ticker']) {
    testWidgets('$boundary change clears pending and old motion without replay',
        (tester) async {
      await tester.pumpWidget(_fixture());
      await tester.pumpWidget(_fixture(busy: true, event: _add));
      await tester.pump(const Duration(milliseconds: 150));
      expect(_mainIcon(tester), Icons.favorite);
      await tester.pumpWidget(_fixture(
        busy: true,
        event: _add,
        identity: boundary == 'identity' ? 'new-artwork' : 'account:artwork',
        visualEpoch: boundary == 'epoch' ? 1 : 0,
        active: boundary != 'active',
        enabled: boundary != 'enabled',
        ticker: boundary != 'ticker',
      ));
      expect(_mainIcon(tester), Icons.favorite_border);
      expect(_scale(tester), 1);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(_fixture(event: _add));
      expect(_mainIcon(tester), Icons.favorite_border);
      expect(_scale(tester), 1);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('epoch invalidation with null event still remembers old begin',
      (tester) async {
    await tester.pumpWidget(_fixture());
    await tester.pumpWidget(_fixture(busy: true, event: _add));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(_fixture(busy: true, visualEpoch: 1));
    expect(_mainIcon(tester), Icons.favorite_border);
    await tester.pumpWidget(_fixture(busy: true, visualEpoch: 1, event: _add));
    expect(_mainIcon(tester), Icons.favorite_border);
    expect(_scale(tester), 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('event null does not clear an in-flight pending target',
      (tester) async {
    await tester.pumpWidget(_fixture());
    await tester.pumpWidget(_fixture(busy: true, event: _add));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(_fixture(busy: true));
    expect(_mainIcon(tester), Icons.favorite);
    await tester.pumpWidget(_fixture(event: _settle(success: false)));
    await tester.pump(const Duration(milliseconds: 140));
    expect(_mainIcon(tester), Icons.favorite_border);
  });

  for (final size in [48.0, 56.0]) {
    testWidgets(
        'fall can paint outside ${size.toInt()}dp target without enlarging its hit area',
        (tester) async {
      var calls = 0;
      var parentCalls = 0;
      await tester.pumpWidget(_fixture(
          bookmarked: true,
          size: size,
          iconSize: 32,
          onPressed: () => calls++,
          onParent: () => parentCalls++));
      final rect = tester.getRect(_button);
      await tester.pumpWidget(_fixture(
          bookmarked: true,
          busy: true,
          event: _remove,
          size: size,
          iconSize: 32,
          onPressed: () => calls++,
          onParent: () => parentCalls++));
      await tester.pump(const Duration(milliseconds: 250));
      final box = tester.renderObject<RenderBox>(find.byKey(_fallIconKey));
      final paintedBottom =
          box.localToGlobal(Offset(box.size.width, box.size.height));
      expect(paintedBottom.dy, greaterThan(rect.bottom));
      expect(
          find.ancestor(
              of: find.byKey(_fallIconKey), matching: find.byType(ClipRect)),
          findsNothing);
      final stack = tester.widget<Stack>(find
          .ancestor(of: find.byKey(_fallIconKey), matching: find.byType(Stack))
          .first);
      expect(stack.clipBehavior, Clip.none);
      final ignore = tester.widget<IgnorePointer>(find
          .ancestor(
              of: find.byKey(_fallIconKey),
              matching: find.byType(IgnorePointer))
          .first);
      expect(ignore.ignoring, isTrue);
      expect(
          find.ancestor(
              of: find.byKey(_fallIconKey),
              matching: find.byType(ExcludeSemantics)),
          findsNWidgets(2));
      expect(tester.getRect(_button), rect);
      await tester.tapAt(rect.bottomCenter + const Offset(0, 3));
      expect(calls, 0);
      expect(parentCalls, 1);
      expect(tester.getSize(_button), Size.square(size));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'waterfall clips only image and passes visual epoch while keeping target position',
      (tester) async {
    Widget card(PixivBookmarkEvent? event, Object epoch) => MaterialApp(
            home: Center(
          child: SizedBox(
              width: 180,
              child: OnlineWaterfallCard(
                title: '作品',
                cover: '',
                imageHeaders: const {},
                onTap: () {},
                onToggleFavorite: () {},
                isFavorited: true,
                pixivBookmarkAnimations: true,
                favoriteEvent: event,
                favoriteVisualEpoch: epoch,
              )),
        ));
    await tester.pumpWidget(card(null, 0));
    final favorite = find.byKey(const ValueKey('waterfall-favorite'));
    final rect = tester.getRect(favorite);
    expect(tester.getSize(favorite), const Size(48, 48));
    expect(find.ancestor(of: favorite, matching: find.byType(ClipRRect)),
        findsNothing);
    expect(find.byType(ClipRRect), findsOneWidget);
    final coverRect = tester.getRect(find.byType(ClipRRect));
    expect(rect.right, coverRect.right);
    expect(rect.bottom, coverRect.bottom);
    await tester.pumpWidget(card(_remove, 0));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(_fallIconKey), findsOneWidget);
    final ancestors = tester.widgetList<Stack>(find.ancestor(
        of: find.byKey(_fallIconKey), matching: find.byType(Stack)));
    expect(ancestors.every((stack) => stack.clipBehavior == Clip.none), isTrue);
    expect(tester.getRect(favorite), rect);
    await tester.pumpWidget(card(_remove, 1));
    expect(find.byKey(_fallIconKey), findsNothing);
    expect(_mainIcon(tester), Icons.favorite);
    expect(_scale(tester), 1);
  });

  testWidgets('button emits no duplicate haptic for begin or settle',
      (tester) async {
    var vibrations = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') vibrations++;
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(_fixture(onPressed: () {}));
    await tester.tap(_button);
    await tester.pumpWidget(_fixture(busy: true, event: _add));
    await tester.pump(const Duration(milliseconds: 10));
    await tester
        .pumpWidget(_fixture(bookmarked: true, event: _settle(begin: _add)));
    await tester.pumpAndSettle();
    expect(vibrations, 0);
  });
}
