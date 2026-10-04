import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/pages/illust_search_panel.dart';

void main() {
  testWidgets('all 140 tags remain selectable after scrolling and reopening',
      (tester) async {
    final host = await _pumpPanel(tester);
    expect(find.byType(FilterChip).evaluate().length, inInclusiveRange(1, 12));
    await _scrollTagsToEnd(tester);
    expect(_tag('tag-011'), findsOneWidget);
    await _scrollTagsToStart(tester);
    await _showAllTags(tester);
    expect(find.byType(FilterChip).evaluate().length, lessThan(140));

    final lastTag = _tag('tag-139');
    await _scrollTagsToEnd(tester);
    await tester.tap(lastTag);
    await tester.pumpAndSettle();
    expect(host.selected, contains('tag-139'));
    await _scrollTagsToStart(tester);
    expect(tester.widget<FilterChip>(lastTag).selected, isTrue);

    await tester.tap(find.byKey(const Key('illust-search-collapse')));
    await tester.pumpAndSettle();
    expect(find.byType(FilterChip), findsNothing);
    expect(find.text('tag-139'), findsOneWidget);
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(host.selected, isEmpty);
    expect(tester.getSize(find.byType(IllustSearchPanel)).height, 0);

    host.update(() => host.expanded = true);
    await tester.pumpAndSettle();
    expect(find.byType(FilterChip).evaluate().length, lessThan(140));
    await _scrollTagsToEnd(tester);
    await tester.tap(lastTag);
    await tester.pumpAndSettle();
    expect(host.selected, contains('tag-139'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('in-place selection changes refresh chips and selected ordering',
      (tester) async {
    final host = await _pumpPanel(tester);
    final originalSet = host.selected;
    host.update(() => host.selected.add('tag-139'));
    await tester.pumpAndSettle();
    expect(identical(host.selected, originalSet), isTrue);
    expect(tester.widget<FilterChip>(_tag('tag-139')).selected, isTrue);
    expect(_visibleTagNames(tester).first, 'tag-139');

    host.update(() => host.selected.clear());
    await tester.pumpAndSettle();
    expect(find.byType(FilterChip).evaluate().length, inInclusiveRange(1, 12));
    expect(_tag('tag-139'), findsNothing);
    expect(_visibleTagNames(tester).first, 'tag-000');
    expect(tester.widget<FilterChip>(_tag('tag-000')).selected, isFalse);
  });

  testWidgets('replacing tag summaries refreshes counts and available labels',
      (tester) async {
    final host = await _pumpPanel(tester, tagCount: 3);
    expect(find.text('tag-000 · 1'), findsOneWidget);
    host.update(() {
      host.tags = [
        const IllustTagSummary(tag: 'tag-000', count: 99),
        const IllustTagSummary(tag: 'new-tag', count: 7),
      ];
      host.resultCount = 106;
    });
    await tester.pumpAndSettle();
    expect(find.text('tag-000 · 99'), findsOneWidget);
    expect(find.text('new-tag · 7'), findsOneWidget);
    expect(find.text('106 个作品'), findsOneWidget);
    expect(find.text('tag-000 · 1'), findsNothing);
    expect(_tag('tag-002'), findsNothing);

    final originalList = host.tags;
    host.update(() {
      host.tags[0] = const IllustTagSummary(tag: 'tag-000', count: 101);
    });
    await tester.pumpAndSettle();
    expect(identical(host.tags, originalList), isTrue);
    expect(find.text('tag-000 · 101'), findsOneWidget);
    expect(find.text('tag-000 · 99'), findsNothing);

    await tester.tap(_tag('new-tag'));
    await tester.pumpAndSettle();
    expect(host.selected, contains('new-tag'));
  });

  testWidgets('cached chips invoke a replacement parent callback',
      (tester) async {
    final host = await _pumpPanel(tester, tagCount: 3);
    final calls = <String>[];
    host.update(() => host.toggleOverride = (tag) => calls.add('old:$tag'));
    await tester.pumpAndSettle();
    await tester.tap(_tag('tag-000'));
    await tester.pumpAndSettle();
    host.update(() => host.toggleOverride = (tag) => calls.add('new:$tag'));
    await tester.pumpAndSettle();
    await tester.tap(_tag('tag-000'));
    await tester.pumpAndSettle();
    expect(calls, ['old:tag-000', 'new:tag-000']);
  });

  testWidgets('unrelated result and keyword refresh retains mounted chips',
      (tester) async {
    final host = await _pumpPanel(tester, tagCount: 3);
    final originalChip = tester.widget<FilterChip>(_tag('tag-000'));

    host.update(() {
      host.resultCount = 42;
      host.controller.text = 'updated keyword';
    });
    await tester.pumpAndSettle();
    expect(find.text('42 个作品'), findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('illust-search-input')))
            .controller!
            .text,
        'updated keyword');
    expect(identical(tester.widget<FilterChip>(_tag('tag-000')), originalChip),
        isTrue);

    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(host.controller.text, isEmpty);
    expect(host.selected, isEmpty);
    expect(tester.widget<FilterChip>(_tag('tag-000')).selected, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached chips respond to inherited theme and text scaling',
      (tester) async {
    final host = await _pumpPanel(tester, tagCount: 3);
    final label = find.text('tag-000 · 1');
    final originalHeight = tester.getSize(label).height;
    host.update(() {
      host.theme = ThemeData.dark(useMaterial3: true);
      host.textScale = 1.6;
    });
    await tester.pumpAndSettle();
    expect(
        Theme.of(tester.element(_tag('tag-000'))).brightness, Brightness.dark);
    expect(tester.getSize(label).height, greaterThan(originalHeight));
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow RTL and large text can reach and select the final tag',
      (tester) async {
    final host = await _pumpPanel(tester,
        size: const Size(320, 1100),
        textScale: 1.6,
        direction: TextDirection.rtl);
    await _showAllTags(tester);
    final lastTag = _tag('tag-139');
    await _scrollTagsToEnd(tester);
    await tester.tap(lastTag);
    await tester.pumpAndSettle();
    expect(host.selected, contains('tag-139'));
    await _scrollTagsToStart(tester);
    expect(tester.widget<FilterChip>(lastTag).selected, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected FilterChip retains its accessible toggle semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final host = await _pumpPanel(tester, tagCount: 3);
      final chip = _tag('tag-000');
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(host.selected, contains('tag-000'));
      expect(
          tester.getSemantics(chip),
          matchesSemantics(
            label: 'tag-000 · 1',
            textDirection: TextDirection.ltr,
            isButton: true,
            isFocusable: true,
            hasEnabledState: true,
            isEnabled: true,
            hasSelectedState: true,
            isSelected: true,
            hasTapAction: true,
            hasFocusAction: true,
          ));
      final selectedNode = tester.getSemantics(chip);
      selectedNode.owner!.performAction(selectedNode.id, SemanticsAction.focus);
      await tester.pumpAndSettle();
      expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<FilterChip>()
              ?.key,
          const ValueKey('illust-search-tag-tag-000'));
      selectedNode.owner!.performAction(selectedNode.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(host.selected, isEmpty);
      expect(tester.widget<FilterChip>(chip).selected, isFalse);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('tag scrolling mounts only visible rows and bounded semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pumpPanel(tester);
      await _showAllTags(tester);
      final position = _tagScrollPosition(tester);
      expect(position.maxScrollExtent, greaterThan(288));
      expect(_tag('tag-000'), findsOneWidget);
      expect(_tag('tag-139'), findsNothing);
      final initialCount = find.byType(FilterChip).evaluate().length;
      expect(initialCount, inExclusiveRange(0, 140));
      expect(
          _tagSemanticsLabels(tester).length, lessThanOrEqualTo(initialCount));
      expect(_tagScrollSemantics(tester).scrollChildCount, 140);
      expect(_tagScrollSemantics(tester).scrollIndex, 0);

      // Exercise the scroll action used by a screen reader before jumping to
      // the final row; unmounted tags remain reachable through normal scrolling.
      tester.semantics.scrollUp();
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));
      await _scrollTagsToEnd(tester);
      expect(_tag('tag-139'), findsOneWidget);
      expect(_tag('tag-000'), findsNothing,
          reason: 'rows outside the viewport must leave the mounted tree');
      final finalCount = find.byType(FilterChip).evaluate().length;
      expect(finalCount, inExclusiveRange(0, 140));
      expect(_tagSemanticsLabels(tester).length, lessThanOrEqualTo(finalCount));
      expect(_tagSemanticsLabels(tester), isNot(contains('tag-000 · 1')));
      expect(_tagScrollSemantics(tester).scrollChildCount, 140);
      expect(_tagScrollSemantics(tester).scrollIndex, greaterThan(100),
          reason: 'the reported position counts tags rather than rows');

      await _scrollTagsToStart(tester);
      expect(_tag('tag-000'), findsOneWidget);
      expect(_tag('tag-139'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('scrolling preserves active keyboard focus until it moves',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final originalStrategy = FocusManager.instance.highlightStrategy;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    try {
      await _pumpPanel(tester);
      await _showAllTags(tester);
      final first = find.byKey(const ValueKey('illust-search-tag-tag-000'),
          skipOffstage: false);
      final firstNode = tester.getSemantics(first);
      firstNode.owner!.performAction(firstNode.id, SemanticsAction.focus);
      await tester.pumpAndSettle();
      final focused = FocusManager.instance.primaryFocus;
      expect(focused?.context?.findAncestorWidgetOfExactType<FilterChip>()?.key,
          const ValueKey('illust-search-tag-tag-000'));
      await _scrollTagsToEnd(tester);
      expect(_tag('tag-139'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(focused));
      expect(first, findsOneWidget);
      expect(find.byType(FilterChip, skipOffstage: false).evaluate().length,
          lessThan(40));

      final lastNode = tester.getSemantics(_tag('tag-139'));
      lastNode.owner!.performAction(lastNode.id, SemanticsAction.focus);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, isNot(same(focused)));
      expect(first, findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      FocusManager.instance.highlightStrategy = originalStrategy;
      semantics.dispose();
    }
  });
}

Finder _tag(String name) => find.byKey(ValueKey('illust-search-tag-$name'));

ScrollPosition _tagScrollPosition(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(
        of: find.byKey(const Key('illust-search-tag-scroll')),
        matching: find.byType(Scrollable)))
    .position;

Future<void> _scrollTagsToEnd(WidgetTester tester) async {
  final position = _tagScrollPosition(tester);
  position.jumpTo(position.maxScrollExtent);
  await tester.pumpAndSettle();
}

Future<void> _scrollTagsToStart(WidgetTester tester) async {
  _tagScrollPosition(tester).jumpTo(0);
  await tester.pumpAndSettle();
}

List<String> _tagSemanticsLabels(WidgetTester tester) {
  final labels = <String>[];
  void visit(SemanticsNode node) {
    if (node.label.startsWith('tag-')) labels.add(node.label);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.getSemantics(find.byKey(const Key('illust-search-tag-scroll'))));
  return labels;
}

SemanticsNode _tagScrollSemantics(WidgetTester tester) {
  SemanticsNode? scrollNode;
  void visit(SemanticsNode node) {
    if (node.scrollChildCount == 140) scrollNode = node;
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.getSemantics(find.byKey(const Key('illust-search-tag-scroll'))));
  expect(scrollNode, isNotNull);
  return scrollNode!;
}

List<String> _visibleTagNames(WidgetTester tester) => tester
    .widgetList<FilterChip>(find.byType(FilterChip))
    .map((chip) => (chip.key! as ValueKey<String>)
        .value
        .replaceFirst('illust-search-tag-', ''))
    .toList();

Future<void> _showAllTags(WidgetTester tester) async {
  await tester.tap(find.text('全部 140 个标签'));
  await tester.pumpAndSettle();
}

Future<_PanelHostState> _pumpPanel(
  WidgetTester tester, {
  int tagCount = 140,
  Size size = const Size(430, 1000),
  double textScale = 1,
  TextDirection direction = TextDirection.ltr,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey<_PanelHostState>();
  await tester.pumpWidget(_PanelHost(
      key: key,
      tagCount: tagCount,
      textScale: textScale,
      direction: direction));
  await tester.pumpAndSettle();
  return key.currentState!;
}

class _PanelHost extends StatefulWidget {
  const _PanelHost({
    super.key,
    required this.tagCount,
    required this.textScale,
    required this.direction,
  });

  final int tagCount;
  final double textScale;
  final TextDirection direction;

  @override
  State<_PanelHost> createState() => _PanelHostState();
}

class _PanelHostState extends State<_PanelHost> {
  final controller = TextEditingController();
  final selected = <String>{};
  late List<IllustTagSummary> tags;
  late double textScale;
  late int resultCount;
  var expanded = true;
  var matchTags = false;
  var theme = ThemeData(useMaterial3: true);
  ValueChanged<String>? toggleOverride;

  void update(VoidCallback callback) => setState(callback);

  @override
  void initState() {
    super.initState();
    textScale = widget.textScale;
    resultCount = widget.tagCount;
    tags = List.generate(
        widget.tagCount,
        (index) => IllustTagSummary(
            tag: 'tag-${index.toString().padLeft(3, '0')}', count: index + 1));
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
      theme: theme,
      home: Builder(
          builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: Directionality(
                  textDirection: widget.direction,
                  child: Scaffold(
                      body: IllustSearchPanel(
                    expanded: expanded,
                    controller: controller,
                    tags: tags,
                    selectedTags: selected,
                    resultCount: resultCount,
                    matchTags: matchTags,
                    onMatchTagsChanged: (value) =>
                        update(() => matchTags = value),
                    onToggleTag: toggleOverride ??
                        (tag) => update(() {
                              if (!selected.add(tag)) selected.remove(tag);
                            }),
                    onClear: () => update(() {
                      selected.clear();
                      controller.clear();
                    }),
                    onExpand: () => update(() => expanded = true),
                    onCollapse: () => update(() => expanded = false),
                  ))))));
}
