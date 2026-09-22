import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/pages/explore/explore_route_scope.dart';

const _menuKey = ValueKey('entry-selector');
const _contentKey = ValueKey('source-content');

class _RestoreProbe extends StatefulWidget {
  const _RestoreProbe({required this.onRestore});

  final VoidCallback onRestore;

  @override
  State<_RestoreProbe> createState() => _RestoreProbeState();
}

class _RestoreProbeState extends State<_RestoreProbe>
    with ExploreRouteRestoreMixin<_RestoreProbe> {
  @override
  void onExploreRouteRestored() => widget.onRestore();

  @override
  Widget build(BuildContext context) => Column(
        children: [
          const SizedBox(
            key: _contentKey,
            height: 42,
            width: double.infinity,
            child: Text('源列表'),
          ),
          PopupMenuButton<String>(
            key: _menuKey,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'latest', child: Text('最新')),
              PopupMenuItem(value: 'weekly', child: Text('每周推荐')),
            ],
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Text('主页推荐'),
            ),
          ),
          const Expanded(child: Center(child: Text('已加载内容'))),
        ],
      );
}

Future<({NaviObserver observer, GlobalKey<NavigatorState> navigator})>
    _pumpPane(
  WidgetTester tester, {
  required VoidCallback onRestore,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final observer = NaviObserver();
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      home: NaviPane(
        observer: observer,
        paneItems: [
          PaneItemEntry(
            label: '探索',
            icon: Icons.explore_outlined,
            activeIcon: Icons.explore,
          ),
          PaneItemEntry(
            label: '收藏',
            icon: Icons.favorite_outline,
            activeIcon: Icons.favorite,
          ),
        ],
        paneActions: [
          PaneActionEntry(
            label: '全局搜索',
            icon: Icons.search,
            onTap: () {},
          ),
        ],
        pageBuilder: (_) => Navigator(
          key: navigator,
          observers: [observer],
          onGenerateRoute: (_) => AppPageRoute<void>(
            preventRebuild: false,
            isRootRoute: true,
            builder: (_) => ExploreRouteScope(
              observer: observer,
              child: NaviPaddingWidget(
                child: _RestoreProbe(onRestore: onRestore),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (observer: observer, navigator: navigator);
}

Finder get _topAction => find.widgetWithIcon(IconButton, Icons.search);
Finder get _bottomTab => find.byIcon(Icons.explore).first;

void main() {
  testWidgets('菜单展开及关闭时顶底栏和内容位置稳定，不触发页面恢复', (tester) async {
    var restored = 0;
    final pane = await _pumpPane(tester, onRestore: () => restored++);
    final topRect = tester.getRect(_topAction);
    final bottomRect = tester.getRect(_bottomTab);
    final contentRect = tester.getRect(find.byKey(_contentKey));
    expect(pane.observer.pageCount, 1);

    for (var round = 0; round < 2; round++) {
      await tester.tap(find.byKey(_menuKey));
      // Check the first animation frame as well as the final popup layout.
      await tester.pump();
      expect(tester.getRect(_topAction), topRect);
      expect(tester.getRect(_bottomTab), bottomRect);
      expect(tester.getRect(find.byKey(_contentKey)), contentRect);
      await tester.pumpAndSettle();
      expect(pane.observer.routes.length, 2);
      expect(pane.observer.pageCount, 1);
      expect(_topAction.hitTestable(), findsOneWidget);
      expect(_bottomTab.hitTestable(), findsOneWidget);
      expect(tester.getRect(_topAction), topRect);
      expect(tester.getRect(_bottomTab), bottomRect);
      expect(tester.getRect(find.byKey(_contentKey)), contentRect);

      pane.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(pane.observer.pageCount, 1);
      expect(restored, 0);
      expect(tester.getRect(_topAction), topRect);
      expect(tester.getRect(_bottomTab), bottomRect);
      expect(tester.getRect(find.byKey(_contentKey)), contentRect);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('真实页面隐藏导航栏，关闭其弹层不恢复探索，返回后核对一次', (tester) async {
    var restored = 0;
    final pane = await _pumpPane(tester, onRestore: () => restored++);
    final topRect = tester.getRect(_topAction);
    final bottomRect = tester.getRect(_bottomTab);
    pane.navigator.currentState!.push(AppPageRoute<void>(
      preventRebuild: false,
      builder: (_) => const Scaffold(body: Center(child: Text('设置页'))),
    ));
    await tester.pumpAndSettle();
    expect(pane.observer.pageCount, 2);
    expect(_topAction.hitTestable(), findsNothing);
    expect(_bottomTab.hitTestable(), findsNothing);
    expect(tester.getRect(_topAction).bottom, lessThanOrEqualTo(0));
    expect(tester.getRect(_bottomTab).top, greaterThanOrEqualTo(844));
    expect(restored, 0);

    showDialog<void>(
      context: tester.element(find.text('设置页')),
      useRootNavigator: false,
      builder: (_) => const AlertDialog(content: Text('设置确认')),
    );
    await tester.pumpAndSettle();
    expect(pane.observer.routes.length, 3);
    expect(pane.observer.pageCount, 2);
    pane.navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(restored, 0);

    pane.navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(restored, 1);
    expect(pane.observer.pageCount, 1);
    expect(tester.getRect(_topAction), topRect);
    expect(tester.getRect(_bottomTab), bottomRect);
    expect(tester.takeException(), isNull);
  });

  testWidgets('根页对话框开合不触发探索恢复或改变导航栏', (tester) async {
    var restored = 0;
    final pane = await _pumpPane(tester, onRestore: () => restored++);
    final topRect = tester.getRect(_topAction);
    final bottomRect = tester.getRect(_bottomTab);
    showDialog<void>(
      context: tester.element(find.byKey(_contentKey)),
      useRootNavigator: false,
      builder: (_) => const AlertDialog(content: Text('临时提示')),
    );
    await tester.pumpAndSettle();
    expect(pane.observer.pageCount, 1);
    expect(pane.observer.routes.length, 2);
    expect(tester.getRect(_topAction), topRect);
    expect(tester.getRect(_bottomTab), bottomRect);
    pane.navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(restored, 0);
    expect(tester.takeException(), isNull);
  });
}
