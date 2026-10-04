import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/pages/illust_search_tag_list.dart';

const _tags = [
  IllustTagSummary(tag: 'A', count: 1),
  IllustTagSummary(tag: 'Landscape', count: 24),
  IllustTagSummary(tag: 'long landscape label beyond the viewport', count: 3),
];
const _selected = {'Landscape'};

void main() {
  testWidgets('idle measurement warms hidden tags without mounting them',
      (tester) async {
    final cache = IllustSearchTagMetricsCache(capacity: 256);
    final tags = List.generate(
        140, (i) => IllustTagSummary(tag: 'prewarm-tag-$i', count: i + 1));
    late StateSetter update;
    int? limit = 12;
    var width = 400.0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return SizedBox(
          width: width,
          child: IllustSearchTagList(
              tags: tags,
              selectedTags: const {},
              onToggleTag: _ignore,
              visibleTagLimit: limit,
              metricsCache: cache),
        );
      })),
    ));
    expect(cache.measurementCount, 12);
    expect(find.byType(FilterChip).evaluate().length, lessThanOrEqualTo(12));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(cache.measurementCount, 140);
    expect(find.byType(FilterChip).evaluate().length, lessThanOrEqualTo(12));
    update(() => limit = null);
    await tester.pumpAndSettle();
    expect(cache.measurementCount, 140,
        reason: 'opening all tags must reuse the idle measurements');
    update(() => width = 320);
    await tester.pumpAndSettle();
    expect(cache.measurementCount, 140,
        reason: 'natural text sizes do not depend on the wrapping width');
    await tester.fling(find.byKey(const Key('illust-search-tag-scroll')),
        const Offset(0, -200), 1500);
    await tester.pumpAndSettle();
    expect(cache.measurementCount, 140);
    expect(find.byType(FilterChip).evaluate().length, lessThan(30));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'reopening reuses bounded value cache and text scaling invalidates',
      (tester) async {
    final cache = IllustSearchTagMetricsCache(capacity: 8);
    Future<void> pump(double scale) async {
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: Scaffold(
                      body: SizedBox(
                          width: 430,
                          child: IllustSearchTagList(
                              tags: _tags,
                              selectedTags: _selected,
                              onToggleTag: _ignore,
                              metricsCache: cache)))))));
      await tester.pumpAndSettle();
    }

    await pump(1);
    expect(cache.measurementCount, 3);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await pump(1);
    expect(cache.measurementCount, 3);
    await pump(1.6);
    expect(cache.measurementCount, 6);
    await pump(2);
    expect(cache.measurementCount, 9);
    expect(cache.entryCount, 8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued warmup follows replacement data and cancels on disposal',
      (tester) async {
    final cache = IllustSearchTagMetricsCache(capacity: 200);
    late StateSetter update;
    var tags =
        List.generate(80, (i) => IllustTagSummary(tag: 'old-$i', count: 1));
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return SizedBox(
            width: 400,
            child: IllustSearchTagList(
                tags: tags,
                visibleTagLimit: 12,
                selectedTags: const {},
                onToggleTag: _ignore,
                metricsCache: cache));
      }),
    )));
    expect(cache.measurementCount, 12);
    update(() => tags =
        List.generate(50, (i) => IllustTagSummary(tag: 'new-$i', count: 2)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(cache.measurementCount, 62,
        reason:
            'only the original prefix and the replacement candidates are measured');
    expect(find.text('old-0 · 1'), findsNothing);
    expect(find.text('new-0 · 2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    final before = cache.measurementCount;
    await tester.pump(const Duration(seconds: 1));
    expect(cache.measurementCount, before);
    expect(tester.takeException(), isNull);
  });

  final scenarios = <String, _Style>{
    'M3': _Style(ThemeData(useMaterial3: true)),
    'dark M3': _Style(ThemeData.dark(useMaterial3: true)),
    'M2': _Style(ThemeData(useMaterial3: false)),
    'large RTL': _Style(ThemeData(useMaterial3: true),
        textScale: 1.6, direction: TextDirection.rtl, width: 320),
    'bold text': _Style(ThemeData(useMaterial3: true), bold: true),
    'custom chip padding and label font': _Style(ThemeData(
        useMaterial3: true,
        chipTheme: const ChipThemeData(
            labelStyle: TextStyle(fontSize: 21, height: 1.3),
            padding: EdgeInsets.fromLTRB(3, 5, 11, 7),
            labelPadding: EdgeInsets.symmetric(horizontal: 3, vertical: 2)))),
    'compact shrink wrap without checkmark': _Style(ThemeData(
        useMaterial3: true,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        chipTheme: const ChipThemeData(showCheckmark: false))),
    'custom border widths': _Style(ThemeData(
        useMaterial3: true,
        chipTheme: ChipThemeData(
            side: WidgetStateBorderSide.resolveWith((states) => BorderSide(
                width: states.contains(WidgetState.selected) ? 3 : 2))))),
    'interaction border geometry fallback': _Style(ThemeData(
        useMaterial3: true,
        chipTheme: ChipThemeData(
            side: WidgetStateBorderSide.resolveWith((states) => BorderSide(
                width: states.contains(WidgetState.focused) ? 4 : 1))))),
  };

  for (final scenario in scenarios.entries) {
    testWidgets('${scenario.key} rows match the original FilterChip Wrap',
        (tester) async {
      await _pump(tester, scenario.value, lazy: false);
      final original = _rects(tester);
      final originalHeight =
          tester.getSize(find.byKey(const Key('frame'))).height;
      await _pump(tester, scenario.value, lazy: true);
      final actual = _rects(tester);
      expect(actual.keys, original.keys);
      for (final tag in original.keys) {
        final before = original[tag]!;
        final after = actual[tag]!;
        expect(after.left, closeTo(before.left, .02), reason: '$tag left');
        expect(after.top, closeTo(before.top, .02), reason: '$tag top');
        expect(after.width, closeTo(before.width, .02), reason: '$tag width');
        expect(after.height, closeTo(before.height, .02),
            reason: '$tag height');
      }
      expect(tester.getSize(find.byKey(const Key('frame'))).height,
          closeTo(originalHeight, .02),
          reason: 'a small tag list must keep its natural height');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('width and text scaling updates recalculate row positions',
      (tester) async {
    await _pump(tester, _Style(ThemeData(useMaterial3: true)), lazy: true);
    final before = _rects(tester);
    await _pump(tester,
        _Style(ThemeData(useMaterial3: true), width: 250, textScale: 1.6),
        lazy: true);
    final after = _rects(tester);
    expect(after['Landscape']!.top, greaterThan(before['Landscape']!.top));
    expect(tester.takeException(), isNull);
    await _pump(tester,
        _Style(ThemeData(useMaterial3: true), width: 250, textScale: 1.6),
        lazy: false);
    final expected = _rects(tester);
    expect(after['Landscape']!.top, closeTo(expected['Landscape']!.top, .02));
  });

  testWidgets('rapid scrolling recycles rows and list shrink clamps the offset',
      (tester) async {
    final tags = List.generate(
        140, (i) => IllustTagSummary(tag: 'landscape-$i', count: i + 1));
    final selected = <String>{};
    late StateSetter update;
    var currentTags = tags;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return SizedBox(
          width: 400,
          child: IllustSearchTagList(
              tags: currentTags, selectedTags: selected, onToggleTag: (_) {}));
    }))));
    await tester.pumpAndSettle();
    final scrollable = find.descendant(
        of: find.byKey(const Key('illust-search-tag-scroll')),
        matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(scrollable).position;
    for (var i = 0; i < 4; i++) {
      await tester.fling(find.byKey(const Key('illust-search-tag-scroll')),
          const Offset(0, -200), 1800);
      await tester.pumpAndSettle();
      expect(find.byType(FilterChip).evaluate().length, lessThan(30));
      expect(tester.takeException(), isNull);
    }
    expect(position.pixels, greaterThan(0));
    update(() => currentTags = tags.take(2).toList());
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
    expect(find.byType(FilterChip), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    update(() => currentTags = []);
    await tester.pumpAndSettle();
    expect(find.byType(FilterChip), findsNothing);
    update(() => currentTags = tags);
    await tester.pumpAndSettle();
    expect(find.byType(FilterChip).evaluate().length, lessThan(30));
    expect(tester.takeException(), isNull);
  });

  testWidgets('focus-dependent border geometry keeps the natural chip layout',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final style = scenarios['interaction border geometry fallback']!;
      await _pump(tester, style, lazy: true);
      final chip = find.byKey(const ValueKey('illust-search-tag-A'));
      final before = tester.getSize(chip).width;
      final node = tester.getSemantics(chip);
      node.owner!.performAction(node.id, SemanticsAction.focus);
      await tester.pumpAndSettle();
      expect(tester.getSize(chip).width, closeTo(before + 6, .02));
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}

class _Style {
  _Style(this.theme,
      {this.textScale = 1,
      this.width = 430,
      this.direction = TextDirection.ltr,
      this.bold = false});
  final ThemeData theme;
  final double textScale;
  final double width;
  final TextDirection direction;
  final bool bold;
}

Future<void> _pump(WidgetTester tester, _Style style,
    {required bool lazy}) async {
  final Widget content = lazy
      ? const IllustSearchTagList(
          tags: _tags, selectedTags: _selected, onToggleTag: _ignore)
      : ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 288),
          child: SingleChildScrollView(
              primary: false,
              padding: const EdgeInsets.only(bottom: 30),
              child: Wrap(spacing: 6, runSpacing: 2, children: [
                for (final tag in _tags)
                  FilterChip(
                    key: ValueKey('illust-search-tag-${tag.tag}'),
                    label: Text('${tag.tag} · ${tag.count}'),
                    selected: _selected.contains(tag.tag),
                    onSelected: (_) {},
                  ),
              ])));
  await tester.pumpWidget(MaterialApp(
      theme: style.theme,
      home: Builder(
          builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(style.textScale),
                  boldText: style.bold),
              child: Directionality(
                  textDirection: style.direction,
                  child: Scaffold(
                      body: Align(
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                              key: const Key('frame'),
                              width: style.width,
                              child: content))))))));
  await tester.pumpAndSettle();
}

void _ignore(String _) {}

Map<String, Rect> _rects(WidgetTester tester) {
  final origin = tester.getTopLeft(find.byKey(const Key('frame')));
  return {
    for (final tag in _tags)
      tag.tag: tester
          .getRect(find.byKey(ValueKey('illust-search-tag-${tag.tag}')))
          .shift(-origin),
  };
}
