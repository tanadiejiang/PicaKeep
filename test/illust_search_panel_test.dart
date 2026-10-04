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
    var matchTags = false;
    var collapseCount = 0;
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
            matchTags: matchTags,
            onMatchTagsChanged: (value) => update(() => matchTags = value),
            onToggleTag: (tag) => update(() => selected.add(tag)),
            onClear: () => update(() {
                  selected.clear();
                  controller.clear();
                }),
            onExpand: () => update(() => expanded = true),
            onCollapse: () => update(() {
                  collapseCount++;
                  expanded = false;
                }));
      },
    ))));

    // 收起且无筛选：零高 —— 不占位、不挂任何芯片。
    expect(find.byType(FilterChip), findsNothing);
    expect(tester.getSize(find.byType(IllustSearchPanel)).height, 0);

    // 19 号起展开 / 收起是**动画**，所以每次切态都要等动画跑完再交互：
    // 动画途中超出当前高度的内容会被 AnimatedSize 的 Clip.hardEdge 裁掉，
    // 这时候 tap 会点在裁剪区外（旧版本"换树即完成"的单帧 pump 不再适用）。
    update(() => expanded = true);
    await tester.pumpAndSettle();
    expect(find.byType(FilterChip), findsOneWidget);

    // 「搜索含标签」用的是 Switch 而不是第二个 FilterChip：
    // 于是按类型定位标签芯片不会歧义（这也是刻意选 Switch 的原因之一）。
    expect(matchTags, isFalse);
    await tester.tap(find.byKey(const Key('illust-search-match-tags')));
    await tester.pumpAndSettle();
    expect(matchTags, isTrue);

    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    expect(selected, contains('风景'));

    // 折叠态：只剩摘要行，芯片让位。
    update(() => expanded = false);
    await tester.pumpAndSettle();
    expect(find.text('风景'), findsOneWidget);
    expect(find.byType(FilterChip), findsNothing);
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(find.text('风景'), findsNothing);

    // 底部「收起搜索」是工具栏那个 × 的等价入口（19 号新增）。
    update(() => expanded = true);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('illust-search-collapse')));
    await tester.pumpAndSettle();
    expect(collapseCount, 1);
    expect(find.byType(FilterChip), findsNothing);
    expect(tester.getSize(find.byType(IllustSearchPanel)).height, 0);
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
              matchTags: false,
              onMatchTagsChanged: (_) {},
              onToggleTag: (_) {},
              onClear: () {},
              onExpand: () {},
              onCollapse: () {},
            ))))));
    expect(tester.takeException(), isNull);
    // 19 号新增的开关行与底部「收起搜索」行都不能把窄屏撑爆 ——
    // 底部那行刻意用 Wrap（换成 Row + Spacer 在这里就会 RenderFlex overflow）。
    expect(find.byKey(const Key('illust-search-match-tags')), findsOneWidget);
    expect(find.byKey(const Key('illust-search-collapse')), findsOneWidget);
    await tester.ensureVisible(find.text('全部 20 个标签'));
    await tester.tap(find.text('全部 20 个标签'));
    await tester.pumpAndSettle();
    expect(find.text('收起标签'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
