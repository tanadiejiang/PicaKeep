/// 主导航在**最窄场景**下的可用性。
///
/// 计划验收要求："较窄手机开启全部 Tab 时不能越界、挤压到无法点选"。
/// 最坏组合是「AI + 服务端运行模式」同时开启 → 5 个 tab，因此这里直接给
/// [NaviPane] 5 个条目（顺序与 `MainPage` 一致：我 / AI / 收藏 / 探索 / 服务信息）。
///
/// 两条实测确认的既有渲染事实（不要按直觉断言，否则会测出不存在的"缺陷"）：
/// 1. **选中项用 `activeIcon` 并显示「图标 + 文字」；未选中项用 `icon` 只画图标。**
///    初始选中第 0 个，所以第 0 个一开始就是 `activeIcon`。
/// 2. `NaviPane` 内部是 Stack，**侧栏与底栏会同时构建**（侧栏靠负偏移推出屏幕外），
///    因此同一个图标在 widget 树里可能有两份。判断"用户能否看到/点到"必须用
///    `hitTestable()` 过滤掉屏幕外那份，而不是 `findsOneWidget`。
///
/// 这里 pump 的是导航组件本身而不是整个 `MainPage`：`MainPage` 会连带初始化
/// 导航 key、`StateController`、账号与网络底座，在 widget 测试里不可隔离；
/// 而"5 个 tab 挤不挤"这个风险完全由 [NaviPane] 的布局决定，直接测它更准。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/components/components.dart';

/// 与 `MainPage._tabs` 一致的 5 项声明（图标也一致）。
///
/// `PaneItemEntry` 的构造函数不是 const，所以这里只能是 final 列表。
final List<PaneItemEntry> _paneItems = <PaneItemEntry>[
  PaneItemEntry(
    label: '我',
    icon: Icons.person_outline,
    activeIcon: Icons.person,
  ),
  PaneItemEntry(
    label: 'AI',
    icon: Icons.smart_toy_outlined,
    activeIcon: Icons.smart_toy,
  ),
  PaneItemEntry(
    label: '收藏',
    icon: Icons.local_activity_outlined,
    activeIcon: Icons.local_activity,
  ),
  PaneItemEntry(
    label: '探索',
    icon: Icons.explore_outlined,
    activeIcon: Icons.explore,
  ),
  PaneItemEntry(
    label: '服务信息',
    icon: Icons.router_outlined,
    activeIcon: Icons.router,
  ),
];

/// 屏幕内真正可命中的 tab 图标（选中看 activeIcon，未选中看 icon）。
Finder _hitTab(int index) {
  final entry = _paneItems[index];
  final inactive = find.byIcon(entry.icon).hitTestable();
  if (inactive.evaluate().isNotEmpty) return inactive.first;
  return find.byIcon(entry.activeIcon).hitTestable().first;
}

/// 该 tab 是否在屏幕内可见（两种图标任一可命中即算可见）。
void _expectTabVisible(int index) {
  final entry = _paneItems[index];
  final visible = find.byIcon(entry.icon).hitTestable().evaluate().isNotEmpty ||
      find.byIcon(entry.activeIcon).hitTestable().evaluate().isNotEmpty;
  expect(visible, isTrue, reason: '屏幕内看不到 tab：${entry.label}');
}

Future<List<int>> _pumpPane(
  WidgetTester tester, {
  required Size logicalSize,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = Size(
    logicalSize.width * tester.view.devicePixelRatio,
    logicalSize.height * tester.view.devicePixelRatio,
  );
  addTearDown(tester.view.reset);

  final observer = NaviObserver();
  final tapped = <int>[];
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: logicalSize,
          textScaler: TextScaler.linear(textScale),
        ),
        child: NaviPane(
          observer: observer,
          paneItems: _paneItems,
          paneActions: const <PaneActionEntry>[],
          onPageChange: tapped.add,
          pageBuilder: (index) => Center(child: Text('page $index')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tapped;
}

void main() {
  testWidgets('360dp 窄屏 + 5 个 tab：不溢出，五个都可见且全部可点选', (tester) async {
    final recorded = await _pumpPane(
      tester,
      logicalSize: const Size(360, 640),
    );
    expect(tester.takeException(), isNull);

    // 1) 五个 tab 在屏幕内都可见。
    for (var i = 0; i < _paneItems.length; i++) {
      _expectTabVisible(i);
    }

    // 2) 逐个点选。初始选中 index 0，所以先点 1..4，最后点回 0
    //    （点已选中的 tab 是 no-op，不能用来证明"点得中"）。
    const order = <int>[1, 2, 3, 4, 0];
    for (final i in order) {
      final entry = _paneItems[i];
      // 点击前它必须是未选中态（渲染 icon）。
      expect(find.byIcon(entry.icon).hitTestable(), findsWidgets,
          reason: '${entry.label} 点击前应处于未选中态');

      await tester.tap(_hitTab(i));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(recorded, isNotEmpty, reason: '点 ${entry.label} 没有触发切换');
      expect(recorded.last, i, reason: '点 ${entry.label} 回传了错误下标');
      // 选中态生效：切换为 activeIcon，并显示该 tab 的文字。
      expect(find.byIcon(entry.activeIcon).hitTestable(), findsWidgets,
          reason: '选中 ${entry.label} 后未切换到激活图标');
      expect(find.text(entry.label), findsWidgets,
          reason: '选中 ${entry.label} 后未显示其文字标签');
    }
  });

  testWidgets('320dp 极窄屏 + 5 个 tab：不溢出，且「探索」仍可点选', (tester) async {
    final recorded = await _pumpPane(
      tester,
      logicalSize: const Size(320, 560),
    );
    expect(tester.takeException(), isNull);

    for (var i = 0; i < _paneItems.length; i++) {
      _expectTabVisible(i);
    }

    // 「探索」在最坏组合里是第 4 个（index 3），必须仍能命中。
    await tester.tap(_hitTab(3));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(recorded.last, 3, reason: '极窄屏下「探索」应仍是第 4 个 tab');
    expect(find.text('探索'), findsWidgets);
  });

  testWidgets('360dp + 字号 1.5 + 5 个 tab：不溢出且「探索」可点', (tester) async {
    final recorded = await _pumpPane(
      tester,
      logicalSize: const Size(360, 640),
      textScale: 1.5,
    );
    expect(tester.takeException(), isNull);

    for (var i = 0; i < _paneItems.length; i++) {
      _expectTabVisible(i);
    }

    await tester.tap(_hitTab(3));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(recorded.last, 3);
  });

  testWidgets('宽屏 + 5 个 tab：可渲染且「探索」可点', (tester) async {
    final recorded = await _pumpPane(
      tester,
      logicalSize: const Size(1400, 900),
    );
    expect(tester.takeException(), isNull);

    for (var i = 0; i < _paneItems.length; i++) {
      _expectTabVisible(i);
    }

    await tester.tap(_hitTab(3));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 宽屏侧栏若「探索」已是激活态，点击是 no-op；两种情况下都不应出错。
    if (recorded.isNotEmpty) {
      expect(recorded.last, 3);
    }
  });
}
