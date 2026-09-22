import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/explore/explore_keep_alive_switcher.dart';

class _Counts {
  int builds = 0;
  int layouts = 0;
  int paints = 0;
  int ticks = 0;
  int created = 0;
  int disposed = 0;
}

class _Probe extends StatefulWidget {
  const _Probe({required this.counts, required this.label});
  final _Counts counts;
  final String label;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with SingleTickerProviderStateMixin {
  late final _ticker = createTicker((_) => widget.counts.ticks++);
  int clicks = 0;
  void increment() => setState(() => clicks++);

  @override
  void initState() {
    super.initState();
    widget.counts.created++;
    _ticker.start();
  }

  @override
  void dispose() {
    widget.counts.disposed++;
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    widget.counts.builds++;
    return _LayoutProbe(
      counts: widget.counts,
      child: TextButton(
        onPressed: increment,
        child: Text('${widget.label}: $clicks'),
      ),
    );
  }
}

class _LayoutProbe extends SingleChildRenderObjectWidget {
  const _LayoutProbe({required this.counts, required super.child});
  final _Counts counts;

  @override
  RenderObject createRenderObject(BuildContext context) => _LayoutBox(counts);

  @override
  void updateRenderObject(BuildContext context, _LayoutBox renderObject) =>
      renderObject.markNeedsLayout();
}

class _LayoutBox extends RenderProxyBox {
  _LayoutBox(this.counts);
  final _Counts counts;

  @override
  void performLayout() {
    counts.layouts++;
    super.performLayout();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    counts.paints++;
    super.paint(context, offset);
  }
}

void main() {
  testWidgets('switching and resizing skip hidden layout, paint and tickers',
      (tester) async {
    final counts = [_Counts(), _Counts()];
    final children = [
      _Probe(counts: counts[0], label: 'first'),
      _Probe(counts: counts[1], label: 'second'),
    ];
    var index = 0;
    var width = 300.0;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return Center(
          child: SizedBox(
            width: width,
            height: 500,
            child: ExploreKeepAliveSwitcher(index: index, children: children),
          ),
        );
      }),
    ));
    await tester.pump(const Duration(milliseconds: 32));
    expect(counts[0].layouts, 1);
    expect(counts[1].layouts, 0);
    expect(counts[1].paints, 0);
    expect(counts[0].ticks, greaterThan(0));
    expect(counts[1].ticks, 0);
    expect(find.text('second: 0'), findsNothing);
    expect(find.text('second: 0', skipOffstage: false), findsOneWidget);

    await tester.tap(find.text('first: 0'));
    await tester.pump();
    final initialLayouts = counts[0].layouts;
    update(() => index = 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final hiddenTicks = counts[0].ticks;
    final hiddenPaints = counts[0].paints;
    update(() => width = 260);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(counts[0].layouts, initialLayouts,
        reason: 'even viewport resizing must not lay out a hidden page');
    expect(counts[0].ticks, hiddenTicks);
    expect(counts[0].paints, hiddenPaints);
    expect(counts[1].layouts, 2);
    expect(counts[1].ticks, greaterThan(0));

    update(() => index = 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('first: 1'), findsOneWidget);
    expect(counts.map((c) => c.created), everyElement(1));
    expect(counts.map((c) => c.disposed), everyElement(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('switch animation is directional and never rebuilds page frames',
      (tester) async {
    final counts = [_Counts(), _Counts()];
    final children = [
      _Probe(counts: counts[0], label: 'first'),
      _Probe(counts: counts[1], label: 'second'),
    ];
    var index = 0;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return ExploreKeepAliveSwitcher(index: index, children: children);
      }),
    ));
    Finder slide() => find.descendant(
        of: find.byType(ExploreKeepAliveSwitcher),
        matching: find.byType(SlideTransition));
    Finder fade() => find.descendant(
        of: find.byType(ExploreKeepAliveSwitcher),
        matching: find.byType(FadeTransition));

    update(() => index = 1);
    await tester.pump();
    expect(tester.widget<SlideTransition>(slide()).position.value.dx,
        greaterThan(0));
    expect(tester.widget<FadeTransition>(fade()).opacity.value, lessThan(1));
    final builds = counts.map((c) => c.builds).toList();
    final layouts = counts.map((c) => c.layouts).toList();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(counts.map((c) => c.builds), builds);
    expect(counts.map((c) => c.layouts), layouts);

    // Interrupt an unfinished transition, then immediately reverse it again.
    update(() => index = 0);
    await tester.pump();
    expect(
        tester.widget<SlideTransition>(slide()).position.value.dx, lessThan(0));
    update(() => index = 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.widget<SlideTransition>(slide()).position.value, Offset.zero);
    expect(tester.widget<FadeTransition>(fade()).opacity.value, 1);
    expect(find.text('second: 0'), findsOneWidget);
    expect(counts.map((c) => c.created), everyElement(1));
    expect(tester.takeException(), isNull);
  });

  for (final disableAnimations in [false, true]) {
    testWidgets('same-page motion key honors reduced motion=$disableAnimations',
        (tester) async {
      var motionKey = 0;
      var animate = true;
      late StateSetter update;
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: StatefulBuilder(builder: (context, setState) {
            update = setState;
            return ExploreKeepAliveSwitcher(
              index: 0,
              animate: animate,
              motionKey: motionKey,
              children: const [Text('content')],
            );
          }),
        ),
      ));
      final fade = find.descendant(
          of: find.byType(ExploreKeepAliveSwitcher),
          matching: find.byType(FadeTransition));
      update(() => motionKey++);
      await tester.pump();
      final value = tester.widget<FadeTransition>(fade).opacity.value;
      expect(value, disableAnimations ? 1 : lessThan(1));
      update(() => animate = false);
      await tester.pump();
      expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('only the visible page has semantics and can receive focus',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final nodes = [FocusNode(), FocusNode()];
    addTearDown(() {
      for (final node in nodes) {
        node.dispose();
      }
    });
    var index = 0;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return ExploreKeepAliveSwitcher(
          index: index,
          children: [
            for (var i = 0; i < nodes.length; i++)
              Focus(
                focusNode: nodes[i],
                child: Semantics(
                  label: 'page $i',
                  child: const SizedBox.expand(),
                ),
              ),
          ],
        );
      }),
    ));
    expect(find.bySemanticsLabel('page 0'), findsOneWidget);
    expect(find.bySemanticsLabel('page 1'), findsNothing);
    nodes[1].requestFocus();
    await tester.pump();
    expect(nodes[1].hasFocus, isFalse);
    update(() => index = 1);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('page 0'), findsNothing);
    expect(find.bySemanticsLabel('page 1'), findsOneWidget);
    nodes[1].requestFocus();
    await tester.pump();
    expect(nodes[1].hasFocus, isTrue);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
      'a hidden async state update survives and leaves visible layout alone',
      (tester) async {
    final counts = [_Counts(), _Counts()];
    final children = [
      _Probe(counts: counts[0], label: 'first'),
      _Probe(counts: counts[1], label: 'second'),
    ];
    var index = 0;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return ExploreKeepAliveSwitcher(index: index, children: children);
      }),
    ));
    final first = tester.state<_ProbeState>(find.byType(_Probe));
    update(() => index = 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final layouts = counts.map((c) => c.layouts).toList();
    Future<void>.microtask(first.increment);
    await tester.pump();
    expect(counts[1].layouts, layouts[1]);
    update(() => index = 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('first: 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
