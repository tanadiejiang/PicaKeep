/// 视图切换悬浮按钮的**真实渲染契约**：可展开、带标识、常态半透明、位置可配。
///
/// ## 为什么要有这个文件
///
/// 用户对这颗按钮提了五条具体要求（原话）：
/// 「点击后展开两个选项，每个选项有对应的标识」「悬浮按钮本身也有标识表明当前
/// 处在哪个视图」「滚动时把透明度降低一点，大约 50」「位置可在设置里改」
/// 「如果焦点不在切换按钮上的话，按钮的透明度减少 50%」。
/// 这些都是**渲染结果**，只看代码常量没有意义 —— 所以这里渲染真实控件
/// `IllustViewSwitcherFab`，量它的图标、文案、透明度与对齐方式。
///
/// 透明度那一条尤其需要真实渲染：33 号之后收起态是**常态半透明**，
/// 展开态与手指按住时**必须回到不透明**。这三态相互覆盖，很容易写成
/// "某个条件把另一个条件盖掉了"（比如 `scrolling ? 0.5 : 1.0` 就会让常态
/// 又变回不透明）。下面按"收起 / 展开 / 按住 / 滚动"四种组合逐一断言。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/pages/local_library_illust_switcher.dart';
import 'package:picakeep/pages/settings/settings_page.dart';

void main() {
  /// 只渲染这颗按钮（用于**非位置**断言：图标、文案、透明度、触控区域）。
  ///
  /// ⚠️ 32 号起本控件**不再自己定位左右**（改由父页面的
  /// `Scaffold.floatingActionButtonLocation` 决定，见下方 `scaffoldHost`）。
  /// 所以这里的 `Stack` 必须是 `StackFit.loose`：`StackFit.expand` 会给非定位子项
  /// **紧约束**，把这个"收缩包裹"的控件强行撑满，量出来的结果与生产不一致。
  ///
  /// 位置类断言一律走 [scaffoldHost] —— 那才是生产里的挂载方式，也是
  /// 「靠左时不对等」那个 bug 真正发生的地方（本文件的 `位置可配` 分组）。
  Widget standalone({
    IllustLibraryView current = IllustLibraryView.album,
    ValueChanged<IllustLibraryView>? onSelected,
    bool scrolling = false,
    bool alignLeft = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          fit: StackFit.loose,
          children: [
            IllustViewSwitcherFab(
              currentView: current,
              scrolling: scrolling,
              alignLeft: alignLeft,
              onViewSelected: onSelected ?? (_) {},
            ),
          ],
        ),
      ),
    );
  }

  /// **与生产完全一致**的挂载：`Scaffold` 的 FAB 槽位 + `FloatingActionButtonLocation`。
  ///
  /// 位置断言必须用它。改动前的位置用例刻意避开了 Scaffold 槽位（怕混入
  /// Scaffold 自己的外边距与 FAB 位移动画），结果**恰好把 bug 挡在了测试之外**：
  /// 真机上的不对称正是"控件撑满整屏 → Scaffold 量到的尺寸 = 屏宽 → `endFloat`
  /// 偏移算成 -16 → 靠左时按钮贴到屏幕最左边"造出来的。
  ///
  /// `pumpAndSettle()` 之后 FAB 的位移动画已完成，`tester.getRect` 量到的就是
  /// 稳定位置，不会混入动画中间值。
  Widget scaffoldHost({
    required bool alignLeft,
    IllustLibraryView current = IllustLibraryView.album,
    ValueChanged<IllustLibraryView>? onSelected,
  }) {
    return MaterialApp(
      home: Scaffold(
        // 与 `local_library_page.dart` 的 `_floatingActionButtonLocation` 同构。
        floatingActionButtonLocation: alignLeft
            ? FloatingActionButtonLocation.startFloat
            : FloatingActionButtonLocation.endFloat,
        floatingActionButton: IllustViewSwitcherFab(
          currentView: current,
          alignLeft: alignLeft,
          onViewSelected: onSelected ?? (_) {},
        ),
      ),
    );
  }

  /// 带**真实可滚动内容**的宿主，用同一套滚动判定驱动按钮透明度。
  ///
  /// 这里的 `NotificationListener` 回调刻意复刻生产代码
  /// （`pages/local_library_page.dart` 的 `_handleScrollNotification`）：
  /// 恢复只认 ScrollEnd / UserScroll(idle)，**绝不**在 ScrollUpdate 里恢复。
  Widget scrollHost() {
    return MaterialApp(
      home: _ScrollHost(),
    );
  }

  group('收起态：标识当前视图', () {
    testWidgets('图集视图：画图集图标 + 「图集」文案', (tester) async {
      await tester.pumpWidget(standalone());
      await tester.pumpAndSettle();
      expect(find.byKey(illustViewSwitcherFabKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(illustViewSwitcherFabKey),
          matching: find.byIcon(illustViewIcon(IllustLibraryView.album)),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(illustViewSwitcherFabKey),
          matching: find.text('图集'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('插画视图：画插画图标 + 「插画」文案（标识随视图变）',
        (tester) async {
      await tester.pumpWidget(
        standalone(current: IllustLibraryView.illust),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(illustViewSwitcherFabKey),
          matching: find.byIcon(illustViewIcon(IllustLibraryView.illust)),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(illustViewSwitcherFabKey),
          matching: find.text('插画'),
        ),
        findsOneWidget,
      );
      // 收起态不该出现两个并列选项。
      expect(
        find.byKey(illustViewOptionKey(IllustLibraryView.album)),
        findsNothing,
      );
    });
  });

  group('展开态：两个带图标 + 文字的选项', () {
    testWidgets('点击后展开两个选项，各有图标与文字标签', (tester) async {
      await tester.pumpWidget(standalone());
      await tester.pumpAndSettle();
      expect(
        find.byKey(illustViewOptionKey(IllustLibraryView.album)),
        findsNothing,
      );

      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();

      for (final view in IllustLibraryView.values) {
        final option = find.byKey(illustViewOptionKey(view));
        expect(option, findsOneWidget, reason: '${view.name} 选项应存在');
        // "对应的标识" = 图标 + 文字标签，两者都要在。
        expect(
          find.descendant(of: option, matching: find.byIcon(illustViewIcon(view))),
          findsOneWidget,
          reason: '${view.name} 选项缺少图标标识',
        );
        expect(
          find.descendant(of: option, matching: find.text(illustViewLabel(view))),
          findsOneWidget,
          reason: '${view.name} 选项缺少文字标识',
        );
      }
    });

    testWidgets('选中另一视图 → 回调收到它，且自动收起', (tester) async {
      IllustLibraryView? picked;
      await tester.pumpWidget(
        standalone(onSelected: (view) => picked = view),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(illustViewOptionKey(IllustLibraryView.illust)));
      await tester.pumpAndSettle();

      expect(picked, IllustLibraryView.illust);
      expect(
        find.byKey(illustViewOptionKey(IllustLibraryView.illust)),
        findsNothing,
        reason: '选完应收起',
      );
    });

    testWidgets('再次点击收起按钮 → 选项消失', (tester) async {
      await tester.pumpWidget(standalone());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(illustViewOptionKey(IllustLibraryView.album)),
        findsOneWidget,
      );
      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(illustViewOptionKey(IllustLibraryView.album)),
        findsNothing,
      );
    });
  });

  group('透明度：收起态常态半透明，展开态 / 手指按住时不透明（33 号）', () {
    testWidgets('收起态、没按住 → 常态 0.5（"焦点不在按钮上就减 50%"）',
        (tester) async {
      await tester.pumpWidget(standalone());
      await tester.pumpAndSettle();
      expect(_opacityOf(tester), illustViewSwitcherIdleOpacity);
      expect(illustViewSwitcherIdleOpacity, closeTo(0.5, 0.01),
          reason: '用户要的是"透明度减少 50%"，即 0.5');
    });

    testWidgets('收起态 + 滚动中 → **仍是** 0.5（与 32 号那条同值，不打架）',
        (tester) async {
      // 32 号只做了"滚动时降到 0.5"；33 号要求收起态**常态**就是 0.5。
      // 两条规则要求的值相同，所以 scrolling 不再单独改变透明度 ——
      // 这条用例锁住"合成后没有分歧"：开与不开滚动，收起态都是 0.5。
      await tester.pumpWidget(standalone(scrolling: true));
      await tester.pumpAndSettle();
      expect(_opacityOf(tester), illustViewSwitcherIdleOpacity);
    });

    testWidgets('展开态 → 不透明（选项文字要看得清）', (tester) async {
      await tester.pumpWidget(standalone());
      await tester.pumpAndSettle();
      expect(_opacityOf(tester), illustViewSwitcherIdleOpacity);

      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(illustViewOptionKey(IllustLibraryView.illust)),
        findsOneWidget,
        reason: '前置条件：确实展开了',
      );
      expect(_opacityOf(tester), 1.0);
    });

    testWidgets('展开态 + 滚动中 → 依然不透明（展开优先于滚动）', (tester) async {
      await tester.pumpWidget(standalone(scrolling: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();
      expect(_opacityOf(tester), 1.0);
    });

    testWidgets('手指按住 → 不透明；松手 → 回到常态 0.5', (tester) async {
      await tester.pumpWidget(standalone());
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(illustViewSwitcherFabKey)),
      );
      await tester.pumpAndSettle();
      expect(_opacityOf(tester), 1.0, reason: '按下去就是"焦点在按钮上"');

      await gesture.up();
      await tester.pumpAndSettle();
      expect(_opacityOf(tester), illustViewSwitcherIdleOpacity,
          reason: '松手之后按钮重新变回常态半透明');
    });

    testWidgets('手指按下后移出按钮再松开 → 也要回到常态（不能卡在不透明）',
        (tester) async {
      await tester.pumpWidget(standalone());
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(illustViewSwitcherFabKey)),
      );
      await tester.pumpAndSettle();
      expect(_opacityOf(tester), 1.0);

      // 滑出去再松手：`onPointerUp` 仍然会到（Listener 收的是自己命中的那条指针），
      // 万一被 cancel 掉，`onPointerCancel` 也要兜住。
      await gesture.moveTo(const Offset(5, 5));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_opacityOf(tester), illustViewSwitcherIdleOpacity);
    });

    testWidgets('真实滚动列表：全程保持 0.5，停下也不回到不透明', (tester) async {
      await tester.pumpWidget(scrollHost());
      await tester.pumpAndSettle();
      expect(_opacityOf(tester), illustViewSwitcherIdleOpacity);

      // 用 fling 制造一次真实的惯性滚动（松手后还会继续滑一段）。
      await tester.fling(find.byType(ListView), const Offset(0, -300), 3000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(_opacityOf(tester), illustViewSwitcherIdleOpacity,
          reason: '收起态滚动中也是常态值');

      await tester.pumpAndSettle();
      expect(_opacityOf(tester), illustViewSwitcherIdleOpacity,
          reason: '停下后**不是**回到 1.0 —— 33 号要的是常态半透明');
    });

    testWidgets('惯性滚动全程不会"闪"到不透明（每帧都是 0.5）', (tester) async {
      await tester.pumpWidget(scrollHost());
      await tester.pumpAndSettle();

      await tester.fling(find.byType(ListView), const Offset(0, -400), 4000);
      await tester.pump();
      // 惯性阶段连续采样：整个过程中都必须保持常态值。
      // 若实现里在 ScrollEnd / ScrollUpdate 里把透明度算回 1.0，这几帧会出现 1.0。
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final animating = tester.widget<AnimatedOpacity>(
          find.byType(AnimatedOpacity),
        );
        expect(
          animating.opacity,
          illustViewSwitcherIdleOpacity,
          reason: '惯性滚动第 $i 帧不该变化',
        );
      }
      await tester.pumpAndSettle();
      expect(_opacityOf(tester), illustViewSwitcherIdleOpacity);
    });

    testWidgets('透明度变化是过渡而不是瞬间跳变（用的是 AnimatedOpacity）',
        (tester) async {
      await tester.pumpWidget(standalone());
      await tester.pumpAndSettle();
      final animated = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(animated.duration, illustViewSwitcherOpacityDuration);
      expect(animated.duration.inMilliseconds, greaterThan(0));

      // 按住（1.0）→ 松手（0.5）：第一帧的**渲染结果**还没到 0.5（说明是过渡）。
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(illustViewSwitcherFabKey)),
      );
      await tester.pumpAndSettle();
      expect(_opacityOf(tester), 1.0);

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      final mid = _renderedOpacity(tester);
      expect(mid, greaterThan(illustViewSwitcherIdleOpacity));
      expect(mid, lessThan(1.0));
      await tester.pumpAndSettle();
      expect(_opacityOf(tester), illustViewSwitcherIdleOpacity);
    });
  });

  group('位置可配：靠右（默认）/ 靠左（32 号真机反馈的修复点）', () {
    Future<void> setScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
    }

    /// 按钮距屏幕某侧的留白 = Scaffold 槽位自带的 16 + 本控件自己的
    /// [illustViewSwitcherEdgeInset]。
    const insetFromScreenEdge =
        kFloatingActionButtonMargin + illustViewSwitcherEdgeInset;

    testWidgets('默认靠右：右边缘距屏幕右侧 = 槽位留白 + 本控件留白', (tester) async {
      await setScreen(tester);
      await tester.pumpWidget(scaffoldHost(alignLeft: false));
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byKey(illustViewSwitcherFabKey));
      expect(rect.right, closeTo(360 - insetFromScreenEdge, 1.0));
      expect(rect.center.dx, greaterThan(360 / 2));
    });

    testWidgets('靠左：左边缘距屏幕左侧 = **同一个**留白（这就是"不对等"的修复）',
        (tester) async {
      await setScreen(tester);
      await tester.pumpWidget(scaffoldHost(alignLeft: true));
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byKey(illustViewSwitcherFabKey));
      expect(rect.left, closeTo(insetFromScreenEdge, 1.0));
      expect(rect.center.dx, lessThan(360 / 2));
    });

    testWidgets('左右**对称**：两种模式的留白逐像素相等（回归用例）',
        (tester) async {
      await setScreen(tester);

      await tester.pumpWidget(scaffoldHost(alignLeft: false));
      await tester.pumpAndSettle();
      final rightMode = tester.getRect(find.byKey(illustViewSwitcherFabKey));

      await tester.pumpWidget(scaffoldHost(alignLeft: true));
      await tester.pumpAndSettle();
      final leftMode = tester.getRect(find.byKey(illustViewSwitcherFabKey));

      final rightInset = 360 - rightMode.right;
      final leftInset = leftMode.left;
      expect(
        leftInset,
        closeTo(rightInset, 0.5),
        reason: '真机反馈「他靠左时有点不对等」：改动前左 0 / 右 32。'
            '根因是本控件外面套了一层撑满整屏的 Align，Scaffold 量到的 FAB 尺寸'
            '等于屏宽，endFloat 的偏移被算成 -16，正好把按钮顶到屏幕最左边。'
            '现在左右都由 Scaffold 的槽位决定，这两个值必须相等。',
      );
      // 左边距不能是 0（"贴在屏幕最左边"是用户看到的那个症状）
      expect(leftInset, greaterThan(0));
      expect(
        rightMode.left - leftMode.left,
        closeTo(360 - insetFromScreenEdge * 2 - rightMode.width, 1.0),
      );
    });

    testWidgets('按钮被**抬高**：距屏幕底部的总留白 = illustViewSwitcherBottomInset',
        (tester) async {
      await setScreen(tester);
      for (final alignLeft in <bool>[false, true]) {
        await tester.pumpWidget(scaffoldHost(alignLeft: alignLeft));
        await tester.pumpAndSettle();
        final rect = tester.getRect(find.byKey(illustViewSwitcherFabKey));
        expect(
          tester.view.physicalSize.height / tester.view.devicePixelRatio -
              rect.bottom,
          closeTo(illustViewSwitcherBottomInset, 1.0),
          reason: '用户要求按钮比改动前更高（"应该在框那边"，追问确认=位置偏高）。'
              '改动前是 32，现在应为一个按钮高度之上。',
        );
      }
    });

    testWidgets('抬高量与"一个按钮高度"对得上（88 = 32 + 56）', (tester) async {
      // 这条把常量之间的算术关系钉住：改动前实测总留白 32（Scaffold 16 + 控件 16），
      // 用户圈出的位置约在按钮正上方一个按钮高度（56）处。
      expect(
        illustViewSwitcherBottomInset,
        closeTo(32 + illustViewSwitcherCollapsedSize, 0.001),
      );
      expect(
        illustViewSwitcherBottomInset,
        illustViewSwitcherScaffoldPadding + kFloatingActionButtonMargin,
      );
    });

    testWidgets('展开态的选项跟着按钮一起靠左/靠右', (tester) async {
      await setScreen(tester);
      await tester.pumpWidget(scaffoldHost(alignLeft: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();
      for (final view in IllustLibraryView.values) {
        final rect = tester.getRect(find.byKey(illustViewOptionKey(view)));
        expect(
          rect.left,
          closeTo(insetFromScreenEdge, 2.0),
          reason: '${view.name} 选项没有跟着按钮一起靠左',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('收展切换不改变按钮的落点（展开时向上长，不横向漂移）',
        (tester) async {
      await setScreen(tester);
      await tester.pumpWidget(scaffoldHost(alignLeft: true));
      await tester.pumpAndSettle();
      final collapsed = tester.getRect(find.byKey(illustViewSwitcherFabKey));

      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();
      final expanded = tester.getRect(find.byKey(illustViewSwitcherFabKey));
      expect(expanded.left, closeTo(collapsed.left, 0.5));
      expect(expanded.bottom, closeTo(collapsed.bottom, 0.5));
    });

    testWidgets('设置里的「视图切换按钮位置」改动会通知图集页重建（否则选了靠左没反应）',
        (tester) async {
      // 位置现在由 `Scaffold.floatingActionButtonLocation` 决定，而它在图集页的
      // `build` 里读。设置页是非 opaque 路由，pop 回去**不会**重建那一页
      // （实测见 `foundation/app.dart` 的 displaySettingsVersion 注释），
      // 所以这条通知是"靠左"能生效的必要条件。
      tester.view.physicalSize = const Size(400 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      var notified = 0;
      void listener() => notified++;
      App.displaySettingsVersion.addListener(listener);
      addTearDown(() => App.displaySettingsVersion.removeListener(listener));

      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(400, 2400)),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  child: SettingsPage(initialPage: 0),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final setting = tester
          .widgetList<SelectSetting>(find.byType(SelectSetting))
          .firstWhere(
            (s) => s.settingsIndex == illustViewSwitcherPositionSettingIndex,
          );
      expect(setting.onChanged, isNotNull,
          reason: '「视图切换按钮位置」必须挂上变更回调');
      setting.onChanged!(illustViewSwitcherLeft);
      expect(
        notified,
        greaterThan(0),
        reason: '改位置后必须通知，否则图集页不重建、"靠左"看起来没生效',
      );
    });
  });

  group('失焦自动收起（36 号第二轮真机反馈）', () {
    /// 一个**确定在按钮区域之外**的落点。
    ///
    /// ⚠️ 不能用屏幕左上角：`standalone()` 里按钮贴在左上（`Stack` 未定位的子项
    /// 默认左上对齐），`Offset(20, 20)` 恰恰**落在按钮上** —— 那样写出来的
    /// "点外部会收起"其实是"再点一次按钮"，测试会假绿。
    /// 默认测试窗口是 800×600，取正中心，任何挂法下都远离按钮。
    const outsidePoint = Offset(400, 300);

    /// 带一个**可点区域**的宿主：用来验证"点别处"既收起选项、又不吞掉
    /// 底下控件的手势（`TapRegion` 与"全屏遮罩"方案的关键差别）。
    Widget tapHost({required VoidCallback onBackgroundTap}) {
      return MaterialApp(
        home: Scaffold(
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          floatingActionButton: IllustViewSwitcherFab(
            currentView: IllustLibraryView.album,
            onViewSelected: (_) {},
          ),
          body: Align(
            alignment: Alignment.topLeft,
            child: TextButton(
              onPressed: onBackgroundTap,
              child: const Text('background'),
            ),
          ),
        ),
      );
    }

    testWidgets('展开后点击按钮以外的任何地方 → 自动收起', (tester) async {
      await tester.pumpWidget(standalone());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(illustViewOptionKey(IllustLibraryView.illust)),
        findsOneWidget,
        reason: '前置条件：确实展开了',
      );

      await tester.tapAt(outsidePoint);
      await tester.pumpAndSettle();

      for (final view in IllustLibraryView.values) {
        expect(
          find.byKey(illustViewOptionKey(view)),
          findsNothing,
          reason: '点了别处就该自己折叠回去',
        );
      }
    });

    testWidgets('点别处收起后，再点按钮仍能正常展开（状态没坏）', (tester) async {
      await tester.pumpWidget(standalone());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();
      await tester.tapAt(outsidePoint);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(illustViewOptionKey(IllustLibraryView.illust)),
        findsOneWidget,
      );
    });

    testWidgets('点展开态**选项本身**不算"点外部"：仍能正常选中', (tester) async {
      IllustLibraryView? picked;
      await tester.pumpWidget(
        standalone(onSelected: (view) => picked = view),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(illustViewOptionKey(IllustLibraryView.illust)),
      );
      await tester.pumpAndSettle();

      expect(picked, IllustLibraryView.illust,
          reason: 'onTapOutside 不应把选项自身的点击当成"点外部"吃掉');
    });

    testWidgets('点别处 → 收起，且底下控件**照常**收到点击（不吞手势）',
        (tester) async {
      var backgroundTaps = 0;
      await tester.pumpWidget(
        tapHost(onBackgroundTap: () => backgroundTaps++),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();

      await tester.tap(find.text('background'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(illustViewOptionKey(IllustLibraryView.illust)),
        findsNothing,
      );
      expect(
        backgroundTaps,
        1,
        reason: 'TapRegion 不插入 widget，不该像全屏遮罩那样吃掉底下点击',
      );
    });

    testWidgets('展开后**滚动**列表 → 也自动收起（用户补充：「点击和滚动」）',
        (tester) async {
      // 滚动必然以一次指针落下开始，而 `onTapOutside` 挂的正是 PointerDown，
      // 所以点击与拖动由同一处覆盖。这条用例守住"别把它改成只认 onTap"。
      await tester.pumpWidget(scrollHost());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(illustViewOptionKey(IllustLibraryView.illust)),
        findsOneWidget,
        reason: '前置条件：确实展开了',
      );

      await tester.fling(find.byType(ListView), const Offset(0, -300), 3000);
      await tester.pumpAndSettle();

      expect(
        find.byKey(illustViewOptionKey(IllustLibraryView.illust)),
        findsNothing,
        reason: '在按钮以外的区域开始拖动 = 焦点离开了它，应当收起',
      );
    });

    testWidgets('收起态点别处不产生任何副作用（回调只在展开态挂）', (tester) async {
      await tester.pumpWidget(standalone());
      await tester.pumpAndSettle();
      await tester.tapAt(outsidePoint);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(illustViewSwitcherFabKey), findsOneWidget);
      expect(_opacityOf(tester), illustViewSwitcherIdleOpacity);
    });

    testWidgets('失焦收起后透明度回到常态 0.5（与 33 号那条合成规则一致）',
        (tester) async {
      await tester.pumpWidget(standalone());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();
      expect(_opacityOf(tester), 1.0, reason: '展开态不透明');

      await tester.tapAt(outsidePoint);
      await tester.pumpAndSettle();
      expect(_opacityOf(tester), illustViewSwitcherIdleOpacity);
    });
  });

  group('触控区域', () {
    testWidgets('收起态按钮本体不小于 48dp（"紧凑"不能把触控做小）',
        (tester) async {
      await tester.pumpWidget(standalone());
      await tester.pumpAndSettle();
      final size = tester.getSize(find.byKey(illustViewSwitcherFabKey));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });

    testWidgets('展开态每个选项高度不小于 40dp', (tester) async {
      await tester.pumpWidget(standalone());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();
      for (final view in IllustLibraryView.values) {
        final size = tester.getSize(find.byKey(illustViewOptionKey(view)));
        expect(size.height, greaterThanOrEqualTo(40),
            reason: '${view.name} 选项太小点不中');
      }
    });
  });
}

/// 当前生效的目标透明度。
double _opacityOf(WidgetTester tester) {
  return tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;
}

/// 某一帧**实际渲染出来**的透明度（过渡中间值）。
///
/// `AnimatedOpacity` 自己没有 RenderObject，它建的是 `RenderAnimatedOpacity`
/// （就是 `Opacity` 那个 render object 的子类），所以直接按 `Opacity` 找。
double _renderedOpacity(WidgetTester tester) {
  final opacity = tester.renderObject<RenderAnimatedOpacity>(
    find.byType(AnimatedOpacity),
  );
  return opacity.opacity.value;
}

/// 一个够长、真能滚的列表 + 与生产代码同判定的滚动监听。
class _ScrollHost extends StatefulWidget {
  @override
  State<_ScrollHost> createState() => _ScrollHostState();
}

class _ScrollHostState extends State<_ScrollHost> {
  bool _scrolling = false;

  bool _onNotification(ScrollNotification notification) {
    final interacting = notification is ScrollStartNotification ||
        (notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle);
    final settled = notification is ScrollEndNotification ||
        (notification is UserScrollNotification &&
            notification.direction == ScrollDirection.idle);
    if (interacting && !_scrolling) {
      setState(() => _scrolling = true);
    } else if (settled && _scrolling) {
      setState(() => _scrolling = false);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: IllustViewSwitcherFab(
        currentView: IllustLibraryView.album,
        scrolling: _scrolling,
        onViewSelected: (_) {},
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: _onNotification,
        child: ListView.builder(
          itemCount: 80,
          itemBuilder: (context, index) =>
              SizedBox(height: 56, child: Text('item $index')),
        ),
      ),
    );
  }
}
