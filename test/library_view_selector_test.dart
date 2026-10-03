/// 库视图「档位」选择器的**真实渲染契约**（36 号）。
///
/// ## 为什么要有这个文件
///
/// 用户要求「所有页的这个三档切换都改成和刚刚图集页的那个样式一样」，
/// 于是 4 个页面（已下载 / 图片收藏 / 图库 / 回收站）改用同一个
/// `components/library_view_selector.dart`。样式数值本身只是观感，但下面几条是
/// **行为契约**，改坏了用户会立刻看出来：
///
/// 1. 面板里**列出全部档位**（包括当前不可选的那些）—— 36 号真机反馈的原始症状
///    就是"档位不见了"，所以"禁用但仍在列表里"必须钉住；
/// 2. 禁用项**点不动**且写明原因，而不是静默无反应；
/// 3. 选中项有对勾，用户要能看出自己停在哪一档；
/// 4. `LibraryViewSelectorAction` 在**只有一项时也照常显示** —— 一旦改成
///    "没得选就隐藏"，用户又会看到按钮消失。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/components/library_view_selector.dart';

enum _Tier { local, aggregate, remote }

List<LibraryViewSelectorEntry<_Tier>> _entries({
  bool remoteEnabled = true,
}) =>
    <LibraryViewSelectorEntry<_Tier>>[
      const LibraryViewSelectorEntry<_Tier>(
        value: _Tier.local,
        label: '本地图集',
        icon: Icons.folder_outlined,
      ),
      LibraryViewSelectorEntry<_Tier>(
        value: _Tier.aggregate,
        label: '聚合',
        icon: Icons.layers_outlined,
        enabled: remoteEnabled,
        disabledReason: '远程服务不可用',
      ),
      LibraryViewSelectorEntry<_Tier>(
        value: _Tier.remote,
        label: '远程 · 图集',
        icon: Icons.cloud_outlined,
        enabled: remoteEnabled,
        disabledReason: '远程服务不可用',
      ),
    ];

void main() {
  Widget anchoredHost({
    required GlobalKey buttonKey,
    required double top,
    required List<_Tier?> picked,
    double textScale = 1,
  }) {
    return MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Stack(
            children: [
              Positioned(
                top: top,
                right: 12,
                width: 56,
                height: 82,
                child: TextButton(
                  key: buttonKey,
                  onPressed: () async {
                    picked.add(await showLibraryViewSelector<_Tier>(
                      context: context,
                      anchorContext: buttonKey.currentContext,
                      title: '收藏 · 档位',
                      entries: _entries(),
                      selected: _Tier.local,
                    ));
                  },
                  child: const Text('open'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  group('抽屉工具栏的实际按钮锚点', () {
    for (final top in <double>[160, 420]) {
      testWidgets('按钮在 $top 时菜单紧贴按钮下方并可选档', (tester) async {
        tester.view.physicalSize = const Size(393, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final buttonKey = GlobalKey();
        final picked = <_Tier?>[];
        await tester.pumpWidget(
          anchoredHost(buttonKey: buttonKey, top: top, picked: picked),
        );
        final button = tester.getRect(find.byKey(buttonKey));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final popup = tester.getRect(find.byType(PopupMenuItem<_Tier>));
        expect(popup.top, closeTo(button.bottom + 4, 1));
        expect(popup.right, closeTo(button.right, 1));
        await tester.tap(find.text('远程 · 图集'));
        await tester.pumpAndSettle();
        expect(picked, [_Tier.remote]);
        expect(find.text('收藏 · 档位'), findsNothing);
        expect(find.text('open'), findsOneWidget);
      });
    }

    testWidgets('窄屏大字按钮靠下时菜单保持在安全区且返回只关闭菜单', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 30);
      addTearDown(tester.view.reset);
      final picked = <_Tier?>[];
      await tester.pumpWidget(anchoredHost(
        buttonKey: GlobalKey(),
        top: 520,
        picked: picked,
        textScale: 1.8,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final popup = tester.getRect(find.byType(PopupMenuItem<_Tier>));
      expect(popup.left, greaterThanOrEqualTo(8));
      expect(popup.right, lessThanOrEqualTo(312));
      expect(popup.top, greaterThanOrEqualTo(32));
      expect(popup.bottom, lessThanOrEqualTo(602));
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(picked, [null]);
      expect(find.text('收藏 · 档位'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });
  });

  /// 直接走 [showLibraryViewSelector] 的宿主；返回值写进 [picked]。
  Widget panelHost({
    required List<_Tier?> picked,
    bool remoteEnabled = true,
    _Tier selected = _Tier.local,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                picked.add(
                  await showLibraryViewSelector<_Tier>(
                    context: context,
                    title: '测试 · 档位',
                    entries: _entries(remoteEnabled: remoteEnabled),
                    selected: selected,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  group('面板：列出全部档位', () {
    testWidgets('标题 + 三项 + 图标块都在场', (tester) async {
      await tester.pumpWidget(panelHost(picked: <_Tier?>[]));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('测试 · 档位'), findsOneWidget);
      for (final label in <String>['本地图集', '聚合', '远程 · 图集']) {
        expect(find.text(label), findsOneWidget, reason: '$label 应列出');
      }
      // 图标块（每项一个）。
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
      expect(find.byIcon(Icons.layers_outlined), findsOneWidget);
      expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
    });

    testWidgets('选中项打勾，且只有一个对勾', (tester) async {
      await tester
          .pumpWidget(panelHost(picked: <_Tier?>[], selected: _Tier.remote));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    });

    testWidgets('点某一项 → 面板关闭并回传该值', (tester) async {
      final picked = <_Tier?>[];
      await tester.pumpWidget(panelHost(picked: picked));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('聚合'));
      await tester.pumpAndSettle();

      expect(picked.single, _Tier.aggregate);
      expect(find.text('测试 · 档位'), findsNothing, reason: '选完应关闭面板');
    });

    testWidgets('点面板外部（barrier）取消 → 回传 null', (tester) async {
      final picked = <_Tier?>[];
      await tester.pumpWidget(panelHost(picked: picked));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(20, 300));
      await tester.pumpAndSettle();

      expect(picked.single, isNull);
      expect(find.text('测试 · 档位'), findsNothing);
    });
  });

  group('禁用项：仍在列表里，但点不动', () {
    testWidgets('远程不可用 → 两项仍在场，并各写明一次原因', (tester) async {
      // **这是 33 号与 36 号最关键的行为差异**：33 号在远程不可用时把档位
      // 整块隐藏，用户因此以为功能被删了。
      await tester.pumpWidget(
        panelHost(picked: <_Tier?>[], remoteEnabled: false),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('聚合'), findsOneWidget);
      expect(find.text('远程 · 图集'), findsOneWidget);
      expect(find.text('远程服务不可用'), findsNWidgets(2));
    });

    testWidgets('点禁用项不动：既不关面板，也不回传值', (tester) async {
      final picked = <_Tier?>[];
      await tester.pumpWidget(
        panelHost(picked: picked, remoteEnabled: false),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('聚合'));
      await tester.pumpAndSettle();

      expect(find.text('测试 · 档位'), findsOneWidget, reason: '禁用项不该关闭面板');
      expect(picked, isEmpty, reason: '禁用项不该回传任何值');
    });

    testWidgets('可用的那一项照常能选（不能用"整块禁用"图省事）', (tester) async {
      final picked = <_Tier?>[];
      await tester.pumpWidget(
        panelHost(picked: picked, remoteEnabled: false),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 本地档已经选中，改选……只有本地可用，因此这里验证它**点得动**
      // （点已选中项同样会关闭面板并回传该值，属于正常语义）。
      await tester.tap(find.text('本地图集'));
      await tester.pumpAndSettle();

      expect(picked.single, _Tier.local);
    });

    testWidgets('启用的项不显示禁用原因（文案不能常驻）', (tester) async {
      await tester.pumpWidget(panelHost(picked: <_Tier?>[]));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('远程服务不可用'), findsNothing);
    });
  });

  group('工具栏按钮 LibraryViewSelectorAction', () {
    Widget actionHost({
      required List<_Tier> picked,
      bool remoteEnabled = true,
      _Tier selected = _Tier.local,
      int entryCount = 3,
    }) {
      return MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: <Widget>[
              LibraryViewSelectorAction<_Tier>(
                title: '已下载 · 档位',
                entries: _entries(remoteEnabled: remoteEnabled)
                    .take(entryCount)
                    .toList(),
                selected: selected,
                onSelected: picked.add,
              ),
            ],
          ),
        ),
      );
    }

    testWidgets('图标 = 当前档，tooltip = 标题', (tester) async {
      await tester.pumpWidget(
        actionHost(picked: <_Tier>[], selected: _Tier.remote),
      );
      expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
      expect(find.byTooltip('已下载 · 档位'), findsOneWidget);
    });

    testWidgets('点击 → 打开面板；选中另一档 → 回调收到它', (tester) async {
      final picked = <_Tier>[];
      await tester.pumpWidget(actionHost(picked: picked));
      await tester.tap(find.byTooltip('已下载 · 档位'));
      await tester.pumpAndSettle();
      // 面板标题就是按钮传进来的那个（`find.byTooltip` 找的是 Tooltip 的
      // message，不是 Text，所以这里的 findsOneWidget 只会命中面板标题）。
      expect(find.text('已下载 · 档位'), findsOneWidget);

      await tester.tap(find.text('聚合'));
      await tester.pumpAndSettle();
      expect(picked.single, _Tier.aggregate);
    });

    testWidgets('选中当前档 → 不触发回调（避免白跑一次重载）', (tester) async {
      final picked = <_Tier>[];
      await tester.pumpWidget(actionHost(picked: picked));
      await tester.tap(find.byTooltip('已下载 · 档位'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('本地图集'));
      await tester.pumpAndSettle();

      expect(picked, isEmpty);
    });

    testWidgets('**只有一项时按钮仍在**（不能因为"没得选"就消失）', (tester) async {
      // 远程不可用 + 只有一个可选档位时，按钮一旦消失，用户就会以为档位功能
      // 被删了 —— 这正是 36 号第一轮真机反馈的原始症状。
      await tester.pumpWidget(
        actionHost(picked: <_Tier>[], entryCount: 1),
      );
      expect(find.byTooltip('已下载 · 档位'), findsOneWidget);
    });

    testWidgets('完全没有档位时才让位（entries 为空 → 不挂按钮）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: <Widget>[
                LibraryViewSelectorAction<_Tier>(
                  title: '已下载 · 档位',
                  entries: const <LibraryViewSelectorEntry<_Tier>>[],
                  selected: _Tier.local,
                  onSelected: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.byTooltip('已下载 · 档位'), findsNothing);
      expect(find.byType(IconButton), findsNothing);
    });
  });
}
