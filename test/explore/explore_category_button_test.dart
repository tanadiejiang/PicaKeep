import 'dart:ui' show SemanticsAction, SemanticsActionEvent, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/explore/explore_category_button.dart';

void main() {
  Future<void> pumpButton(
    WidgetTester tester,
    Widget button, {
    ThemeData? theme,
    double width = 180,
    double textScale = 1,
  }) =>
      tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: Center(child: SizedBox(width: width, child: button)),
          ),
        ),
      ));

  testWidgets('tap and semantic action activate an enabled category',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var taps = 0;
    await pumpButton(
        tester, ExploreCategoryButton(label: '风景', onPressed: () => taps++));

    final node = tester.getSemantics(find.byType(ExploreCategoryButton));
    expect(node.label, '风景');
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.flagsCollection.isEnabled, Tristate.isTrue);
    expect(node.childrenCount, 0);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    await tester.tap(find.text('风景'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    tester.binding.performSemanticsAction(SemanticsActionEvent(
        type: SemanticsAction.tap,
        viewId: tester.view.viewId,
        nodeId: node.id));
    await tester.pumpAndSettle();
    expect(taps, 2);
    semantics.dispose();
  });

  testWidgets('disabled category cannot tap, focus, or activate by keyboard',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await pumpButton(
        tester,
        ExploreCategoryButton(
            label: '暂不可用', onPressed: null, focusNode: focus));
    final node = tester.getSemantics(find.byType(ExploreCategoryButton));
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.flagsCollection.isEnabled, Tristate.isFalse);
    expect(node.flagsCollection.isFocused, Tristate.none);
    expect(node.childrenCount, 0);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    await tester.tap(find.text('暂不可用'));
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('keyboard traversal supports both Enter and Space',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var taps = 0;
    await pumpButton(
        tester,
        ExploreCategoryButton(
            label: '风景', onPressed: () => taps++, focusNode: focus));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(
        tester
            .getSemantics(find.byType(ExploreCategoryButton))
            .flagsCollection
            .isFocused,
        Tristate.isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(taps, 2);
    semantics.dispose();
  });

  testWidgets('accessibility focus and label stay on the single button node',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await pumpButton(tester,
        ExploreCategoryButton(label: '风景', onPressed: () {}, focusNode: focus));
    final node = tester.getSemantics(find.byType(ExploreCategoryButton));
    expect(node.label, '风景');
    expect(node.childrenCount, 0);
    expect(node.flagsCollection.isFocused, Tristate.isFalse);
    expect(node.getSemanticsData().hasAction(SemanticsAction.focus), isTrue);
    tester.binding.performSemanticsAction(SemanticsActionEvent(
        type: SemanticsAction.focus,
        viewId: tester.view.viewId,
        nodeId: node.id));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(node.flagsCollection.isFocused, Tristate.isTrue);
    await pumpButton(tester,
        ExploreCategoryButton(label: '山川', onPressed: null, focusNode: focus));
    await tester.pumpAndSettle();
    final disabled = tester.getSemantics(find.byType(ExploreCategoryButton));
    expect(disabled.label, '山川');
    expect(disabled.childrenCount, 0);
    expect(disabled.flagsCollection.isFocused, Tristate.none);
    expect(
        disabled.getSemanticsData().hasAction(SemanticsAction.focus), isFalse);
    expect(disabled.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    expect(focus.hasFocus, isFalse);
    semantics.dispose();
  });

  testWidgets('surface follows light and dark themes and keeps its shape',
      (tester) async {
    for (final brightness in Brightness.values) {
      final theme = ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal, brightness: brightness));
      await pumpButton(
          tester, ExploreCategoryButton(label: '风景', onPressed: () {}),
          theme: theme);
      await tester.pumpAndSettle();
      final surface = tester.widget<PhysicalModel>(find.descendant(
          of: find.byType(ExploreCategoryButton),
          matching: find.byType(PhysicalModel)));
      expect(
          surface.color,
          Color.alphaBlend(
              theme.colorScheme.primaryContainer.withValues(alpha: .55),
              theme.colorScheme.surfaceContainerLow));
      expect(surface.elevation, 1);
      expect(surface.borderRadius, BorderRadius.circular(12));
      expect(tester.getSize(find.byType(ExploreCategoryButton)).height,
          greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
      'focus nodes can be replaced without disposing caller-owned nodes',
      (tester) async {
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    Future<void> show(FocusNode? focus) async {
      await pumpButton(
          tester,
          ExploreCategoryButton(
              label: '风景', onPressed: () {}, focusNode: focus));
      await tester.pumpAndSettle();
    }

    await show(first);
    first.requestFocus();
    await tester.pumpAndSettle();
    expect(first.hasFocus, isTrue);
    await show(second);
    second.requestFocus();
    await tester.pumpAndSettle();
    expect(first.hasFocus, isFalse);
    expect(second.hasFocus, isTrue);
    await show(null);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await show(first);
    first.requestFocus();
    await tester.pumpAndSettle();
    expect(first.hasFocus, isTrue);
    // An external node must remain usable after it leaves the button.
    void listener() {}
    first.addListener(listener);
    first.removeListener(listener);
    second.addListener(listener);
    second.removeListener(listener);
    await show(null);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('long labels wrap at large text scale without clipping',
      (tester) async {
    await pumpButton(
        tester,
        ExploreCategoryButton(
          label: '这是可以换行的分类名称',
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          onPressed: () {},
        ),
        width: 160,
        textScale: 2);
    final button = tester.getRect(find.byType(ExploreCategoryButton));
    final text = tester.getRect(find.text('这是可以换行的分类名称'));
    expect(button.height, greaterThan(80));
    expect(text.left, greaterThanOrEqualTo(button.left + 16));
    expect(text.right, lessThanOrEqualTo(button.right - 16));
    expect(text.top, greaterThanOrEqualTo(button.top + 10));
    expect(text.bottom, lessThanOrEqualTo(button.bottom - 10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('touch uses the theme ink splash and leaves no running animation',
      (tester) async {
    final splash = _RecordingSplashFactory();
    var taps = 0;
    await pumpButton(
        tester, ExploreCategoryButton(label: '风景', onPressed: () => taps++),
        theme: ThemeData(splashFactory: splash));
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(ExploreCategoryButton)));
    await tester.pump(const Duration(milliseconds: 120));
    expect(splash.created, 1);
    expect(taps, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(tester.binding.transientCallbackCount, 0);
  });
}

class _RecordingSplashFactory extends InteractiveInkFeatureFactory {
  int created = 0;

  @override
  InteractiveInkFeature create({
    required MaterialInkController controller,
    required RenderBox referenceBox,
    required Offset position,
    required Color color,
    required TextDirection textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    ShapeBorder? customBorder,
    double? radius,
    VoidCallback? onRemoved,
  }) {
    created++;
    return InkRipple.splashFactory.create(
      controller: controller,
      referenceBox: referenceBox,
      position: position,
      color: color,
      textDirection: textDirection,
      containedInkWell: containedInkWell,
      rectCallback: rectCallback,
      borderRadius: borderRadius,
      customBorder: customBorder,
      radius: radius,
      onRemoved: onRemoved,
    );
  }
}
