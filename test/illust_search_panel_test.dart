import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/pages/illust_search_panel.dart';

void main() {
  testWidgets('collapsed filters stay visible and clearable; no idle tag bar',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var expanded = false;
    final selected = <String>{};
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(
      builder: (context, setState) {
        update = setState;
        return IllustSearchPanel(
            expanded: expanded,
            controller: controller,
            tags: const [IllustTagSummary(tag: '风景', count: 2)],
            selectedTags: selected,
            resultCount: 2,
            onToggleTag: (tag) => update(() => selected.add(tag)),
            onClear: () => update(() {
                  selected.clear();
                  controller.clear();
                }),
            onExpand: () => update(() => expanded = true));
      },
    ))));
    expect(find.byType(FilterChip), findsNothing);
    update(() => expanded = true);
    await tester.pump();
    await tester.tap(find.byType(FilterChip));
    await tester.pump();
    expect(selected, contains('风景'));
    update(() => expanded = false);
    await tester.pump();
    expect(find.text('风景'), findsOneWidget);
    expect(find.byType(FilterChip), findsNothing);
    await tester.tap(find.text('清除'));
    await tester.pump();
    expect(selected, isEmpty);
    expect(find.text('风景'), findsNothing);
  });

  testWidgets(
      'narrow dark panel with large text can expand tags without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: Scaffold(
                body: SingleChildScrollView(
                    child: IllustSearchPanel(
              expanded: true,
              controller: controller,
              tags: List.generate(
                  20,
                  (i) =>
                      IllustTagSummary(tag: 'Genshin Impact $i', count: i + 1)),
              selectedTags: const {},
              resultCount: 20,
              onToggleTag: (_) {},
              onClear: () {},
              onExpand: () {},
            ))))));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('全部 20 个标签'));
    await tester.tap(find.text('全部 20 个标签'));
    await tester.pumpAndSettle();
    expect(find.text('收起标签'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
