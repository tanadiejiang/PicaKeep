/// 图集页的**视图切换悬浮按钮**：收起态一个 FAB，点开是两个带图标 + 文字的选项。
///
/// ## 为什么单独成文件
///
/// `lib/pages/local_library_page.dart` 是 2583 行单文件，新增 UI 一律另起文件
/// （24 号计划「风险或注意事项」第一条）。而且这个控件要自己管两件本地状态
/// （展开/收起、滚动中），独立成控件后父页面完全不用参与。
///
/// ## 需求对应（用户原话）
///
/// - "悬浮按钮点击后展开两个选项，每个选项有对应的标识" → 展开态两个选项，
///   各有**图标 + 文字标签**。
/// - "悬浮按钮本身也有标识表明当前处在哪个视图" → 收起态的按钮画**当前视图的
///   图标**，并在下方贴一个当前视图名的小标签。
/// - "滚动时把透明度降低一点，大约 50" → 透明度过渡用 `AnimatedOpacity`（120 ms）。
/// - "如果焦点不在切换按钮上的话，按钮的透明度减少 50%"（33 号）→ **收起态常态
///   半透明 0.5；展开态与手指按住时 1.0**。详见
///   [_IllustViewSwitcherFabState._opacity] 的合成规则。
/// - "这个切换按钮应该在框那边…"（追问确认：**位置偏高**）+
///   "他靠左时有点不对等" → 底部留白提到 [illustViewSwitcherBottomInset]，
///   左右改由 `Scaffold.floatingActionButtonLocation` 决定（见下）。
/// - "这个图集按钮如果焦点不在时，也就是点击了除了它以外的地方时自己折叠回去"
///   （36 号）→ 展开态下用 `TapRegion.onTapOutside` 自动收起，见
///   [_IllustViewSwitcherFabState._collapse]。
///
/// ## 为什么"点击外部收起"用 `TapRegion` 而不是全屏遮罩
///
/// 遮罩（在 `Stack` 里铺一层透明 `GestureDetector`）会把底下页面的手势全部吃掉：
/// 用户点一颗卡片时只会关掉选项、卡片打不开；滚动也要先穿过它。
/// `TapRegion` **不插入任何 widget**，只在指针落下时判定"落点是否在自己的矩形内"，
/// 所以底下页面照常响应 —— 点卡片既收起选项、也照常打开详情。
///
/// ⚠️ 代价是它依赖"本控件保持收缩包裹"：`TapRegion` 的区域就是这棵子树量出来的
/// 矩形，一旦被撑满整屏，"点击外部"就永远不会触发（与 [IllustViewSwitcherFab]
/// 那条"不要套 `Align` / `SizedBox.expand`"的约束是同一件事）。
///
/// ## 定位职责：本控件只管"抬高"，不管"哪一侧"
///
/// 32 号起左右位置交给父页面的 `floatingActionButtonLocation`
/// （`startFloat` / `endFloat`），本控件只加底部留白与**展开态选项的对齐方向**。
/// 原因见 [IllustViewSwitcherFab] 的类注释：自己选边会让 Scaffold 量到的尺寸
/// 变成屏宽，靠左时按钮被顶到屏幕最左边（左右不对称的真机根因）。
///
/// ## 滚动透明度的实现要点
///
/// 用父页面已有的 `NotificationListener<ScrollNotification>` 先例
/// （`pages/download_page.dart:680-692`）把"滚动中"这个布尔量算出来，
/// **不要**在 `ScrollUpdateNotification` 里顺手恢复透明度：惯性滚动期间
/// update 会持续触发，那样会在滚动途中反复闪回不透明。
/// 恢复只认 `ScrollEndNotification` 与 `UserScrollNotification(direction: idle)`。
///
/// ⚠️ 33 号起这个布尔量**不再改变透明度**（收起态已经是常态 0.5），
/// 详见 [IllustViewSwitcherFab.scrolling]。
library;

import 'package:flutter/material.dart';

import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/tools/translations.dart';

/// **常态**（收起态、且手指没按住）的透明度：0.5。
///
/// 用户真机原话：「如果焦点不在切换按钮上的话，按钮的透明度减少 50%」。
/// 32 号只做了"滚动时降到 0.5"，33 号把"焦点不在按钮上"补全为**常态**。
///
/// 与 32 号那条的关系：**同值、同一条**。滚动中也是"焦点不在按钮上"，
/// 所以两者要求的都是 0.5，合成后没有任何分歧（见 `_IllustViewSwitcherFabState`
/// 的 `_opacity`）。名字从 `...ScrollingOpacity` 改成 `...IdleOpacity` 就是
/// 为了反映这一点：它不再是"滚动专属"的值，而是**默认值**。
const double illustViewSwitcherIdleOpacity = 0.5;

/// 透明度过渡时长。
///
/// 用户要求不要瞬间跳变；120 ms 比 Material 默认的 200 ms 更短，
/// 因为"开始滚动"这个动作需要立刻得到视觉反馈，太慢会显得按钮"粘着"。
const Duration illustViewSwitcherOpacityDuration =
    Duration(milliseconds: 120);

/// 收起态按钮的直径（与 Material 常规 FAB 一致，触控区域达标）。
const double illustViewSwitcherCollapsedSize = 56;

/// 收起态按钮在本控件基础上**额外**的左右留白。
///
/// Scaffold 的 FAB 槽位自带 [kFloatingActionButtonMargin]（16），本值叠加在其上，
/// 所以按钮距屏幕边缘的实际留白是 `16 + 本值 = 32`。
///
/// ⚠️ **左右必须用同一个值**。32 号真机反馈「他靠左时有点不对等」的根因就在这一条
/// 曾经被破坏：改动前本控件外面套了一层**会撑满整屏的** `Align`，于是
/// `Scaffold` 量到的 FAB 尺寸等于屏宽，`endFloat` 的偏移变成 `-16`，
/// 本控件自己的 `left: 16` 正好把它抵回屏幕最左边 —— 实测左边距 **0**、
/// 右边距 **32**（见 `test/local_library_illust_switcher_test.dart` 的位置用例）。
///
/// 现在的做法是：**本控件不再自己定位**，左右由父页面用
/// `Scaffold.floatingActionButtonLocation` 的 `startFloat` / `endFloat` 决定
/// （见 `local_library_page.dart` 的 `_floatingActionButtonLocation`）。
/// 这样两侧都由 Flutter 自己的槽位机制摆，天然对称，也不会再被"控件撑满"破坏。
const double illustViewSwitcherEdgeInset = 16;

/// 收起态按钮距**屏幕底部**的总留白（含 Scaffold 槽位自带的 16）。
///
/// ## 为什么从 32 提到 88
///
/// 用户真机反馈「这个切换按钮应该在框那边」（追问确认：**按钮应该比现在更高**），
/// 并圈出了按钮正上方约**一个按钮高度**的位置。改动前实际是 32（=Scaffold 16 +
/// 本控件 16），一个按钮高 56，所以 32 + 56 = 88。
///
/// 做成**具名常量**（而不是把 72 散在 `Padding` 里）是为了后续微调只需改一个数：
/// 这里写的是"距屏幕底部的总留白"这一**可读的观感量**，与 Scaffold 自带多少无关。
/// 真正的 padding 由 [illustViewSwitcherScaffoldPadding] 扣掉 Scaffold 那份得到。
const double illustViewSwitcherBottomInset = 88;

/// 本控件实际交给 `Padding` 的底部留白 = 总留白 − Scaffold 槽位自带的那份。
///
/// 单独抽出来是为了**可测**：位置用例断言的是"距屏幕底部的总留白等于
/// [illustViewSwitcherBottomInset]"，这个换算式一旦和 Scaffold 的机制脱节，
/// 用例会立刻失败，而不是等到真机上才发现按钮位置偏了。
const double illustViewSwitcherScaffoldPadding =
    illustViewSwitcherBottomInset - kFloatingActionButtonMargin;

/// 每个视图的图标 + 文案（收起态与展开态共用，保证"标识"一致）。
IconData illustViewIcon(IllustLibraryView view) {
  switch (view) {
    case IllustLibraryView.album:
      return Icons.photo_library_outlined;
    case IllustLibraryView.illust:
      return Icons.brush_outlined;
  }
}

String illustViewLabel(IllustLibraryView view) {
  switch (view) {
    case IllustLibraryView.album:
      return '图集'.tl;
    case IllustLibraryView.illust:
      return '插画'.tl;
  }
}

/// 收起态按钮的 Key（测试用来找它并点击展开）。
const Key illustViewSwitcherFabKey = Key('illust-view-switcher');

/// 展开态某个选项的 Key（测试用来断言"两个选项各带标识"）。
Key illustViewOptionKey(IllustLibraryView view) =>
    Key('illust-view-option-${view.name}');

/// 视图切换悬浮按钮。
///
/// ## 定位由父页面负责（32 号的关键改动）
///
/// 本控件**不自己摆左右位置**，只负责"按钮长什么样 + 收起/展开"：
///
/// - 左右：父页面把 `Scaffold.floatingActionButtonLocation` 设成
///   `startFloat`（靠左）或 `endFloat`（靠右）；
/// - 底部：本控件用 `Padding` 把它抬高 [illustViewSwitcherBottomInset]。
///
/// 为什么这么分：改动前本控件用一层撑满整屏的 `Align` 自己选边，导致
/// `Scaffold` 量到的 FAB 尺寸 = 屏宽，`endFloat` 的偏移被算成 `-16`，
/// 靠左时按钮正好贴在屏幕最左边（实测左边距 0 / 右边距 32，用户原话
/// 「他靠左时有点不对等」）。交给 Scaffold 的槽位机制后，两侧由同一套算术决定，
/// 结构上就不可能不对称。
///
/// ⚠️ **本控件必须保持"收缩包裹"**（不要在外面套 `Align` / `SizedBox.expand`）：
/// 一旦它撑满，上面那个 bug 会立刻回来。
///
/// 父页面同时负责**互斥**（多选态下不挂载本控件），本控件不感知多选。
class IllustViewSwitcherFab extends StatefulWidget {
  const IllustViewSwitcherFab({
    super.key,
    required this.currentView,
    required this.onViewSelected,
    this.scrolling = false,
    this.alignLeft = false,
  });

  final IllustLibraryView currentView;

  /// 用户选定某个视图。父页面负责持久化 + 换数据源。
  final ValueChanged<IllustLibraryView> onViewSelected;

  /// 页面是否正在滚动（由父页面的 `NotificationListener` 驱动）。
  ///
  /// ## 33 号起它**不再改变透明度**（有意为之，不是漏接线）
  ///
  /// 32 号用它是为了"滚动时降到 0.5、停下恢复 1.0"；33 号用户要求
  /// **收起态常态就半透明**（"焦点不在切换按钮上的话，透明度减少 50%"）。
  /// 两条规则要求的**是同一个值**（[illustViewSwitcherIdleOpacity]），
  /// 于是"滚动中"与"常态"合成后没有分歧 —— 收起态不管滚不滚都是 0.5，
  /// 展开态一律不透明。所以这个入参现在是**语义已内化**的：
  ///
  /// - 保留它：不动父页面的滚动监听接线（`local_library_page.dart` 的
  ///   `_handleScrollNotification` / `_scrollInteracting`），将来若要
  ///   "滚动时比常态更淡"还有现成信号可用；
  /// - 不参与计算：参与进去反而会与"收起态常态 0.5"打架
  ///   （比如把它写成"滚动 ? 0.5 : 1.0"就会让常态又回到不透明，直接违背 33 号）。
  final bool scrolling;

  /// 是否靠左（对应 `settings[illustViewSwitcherPositionSettingIndex]`）。
  ///
  /// 只影响**展开态选项的对齐方向**（选项要贴着按钮那一侧）；按钮本身的左右
  /// 由父页面通过 `FloatingActionButtonLocation` 决定，本控件不据此定位。
  final bool alignLeft;

  @override
  State<IllustViewSwitcherFab> createState() => _IllustViewSwitcherFabState();
}

class _IllustViewSwitcherFabState extends State<IllustViewSwitcherFab> {
  bool _expanded = false;

  /// 手指是否正按在这颗按钮上（33 号：按住时要不透明，作为"按到了"的反馈）。
  ///
  /// 用 `Listener` 而不是 `InkWell.onHighlightChanged`：后者是 Material 高亮
  /// 扩散的语义，触发时机比指针落下晚一帧（还要等水波纹），而这里要的正是
  /// **指针落下 / 抬起**本身。
  bool _pressed = false;

  /// 当前应有的透明度。**三条规则合成在一处，避免将来各改一半而互相打架**：
  ///
  /// 1. **展开态 → `1.0`**：展开后是两个带文字的选项，半透明会让文字发灰看不清；
  ///    用户要的就是"焦点在按钮上就不淡"。
  /// 2. **手指按住 → `1.0`**：同理，按住时按钮就是焦点。
  /// 3. **其余（收起态常态）→ [illustViewSwitcherIdleOpacity]（0.5）**。
  ///    33 号截图里按钮压住了第三张卡片的信息，常态淡一点正是用户提这一条的原因。
  ///
  /// 与 32 号"滚动时降到 0.5"的关系：收起态**本来就是** 0.5，滚动落进第 3 条、
  /// 值完全相同，所以 `widget.scrolling` 不再参与计算（理由见该字段的注释）。
  /// 展开态下即使列表在滚，也按第 1 条保持不透明。
  double get _opacity =>
      (_expanded || _pressed) ? 1.0 : illustViewSwitcherIdleOpacity;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() {
      _pressed = value;
    });
  }

  void _toggleExpanded() {
    setState(() {
      _expanded = !_expanded;
    });
  }

  /// 点击**或滚动**本控件以外的任何地方 → 收起。
  ///
  /// 用户真机要求原话：「这个图集按钮如果焦点不在时，也就是点击了除了它以外
  /// 的地方时自己折叠回去」，随后补充「注意是，**点击和滚动**除了它以外的地方」。
  ///
  /// 两个动作由**同一处**覆盖：`onTapOutside` 挂的是指针**落下**（PointerDown）
  /// 事件，而手指滚动列表也必然以一次落子开始 —— 所以拖动同样会让它收起，
  /// 不需要再接滚动通知。
  ///
  /// 这也正是选 `TapRegion` 而不是"监听滚动位置"的原因：后者在
  /// 程序化滚动、列表不足一屏（根本不产生滚动通知）、或用户按住不动时都会漏判，
  /// 而"落子在区域外"这一条判据对点击与拖动是同一个。
  void _collapse() {
    if (!_expanded) {
      return;
    }
    setState(() {
      _expanded = false;
    });
  }

  void _select(IllustLibraryView view) {
    setState(() {
      _expanded = false;
    });
    widget.onViewSelected(view);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 收缩包裹：`SafeArea` + `Padding` 都不改变自身的宽度语义，
    // 于是 `Scaffold` 量到的 FAB 尺寸就是按钮列的真实宽度（收起态 56）。
    //
    // `TapRegion` 同样**不改变尺寸语义**（它是个 proxy box），所以外层套它
    // 之后上面那条位置约束依然成立 —— 这点很关键：它的"区域"就是这棵子树
    // 量出来的矩形，一旦被撑满整屏，"点击外部"将永远不会触发。
    return TapRegion(
      // 只在展开态挂回调：收起态再响应"点了外面"没有意义，
      // 而且会让每次指针落下都多走一次区域判定。
      onTapOutside: _expanded ? (_) => _collapse() : null,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(
            left: illustViewSwitcherEdgeInset,
            right: illustViewSwitcherEdgeInset,
            bottom: illustViewSwitcherScaffoldPadding,
          ),
          child: AnimatedOpacity(
            opacity: _opacity,
            duration: illustViewSwitcherOpacityDuration,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: widget.alignLeft
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.end,
              children: [
                if (_expanded) ...[
                  for (final view in IllustLibraryView.values.reversed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _buildOption(theme, view),
                    ),
                  const SizedBox(height: 2),
                ],
                _buildCollapsedButton(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 收起态：一个圆形 FAB，图标 = 当前视图，图标下方贴当前视图名。
  Widget _buildCollapsedButton(ThemeData theme) {
    final label = illustViewLabel(widget.currentView);
    return Tooltip(
      message: '${'切换视图'.tl} · $label',
      child: SizedBox(
        key: illustViewSwitcherFabKey,
        width: illustViewSwitcherCollapsedSize,
        height: illustViewSwitcherCollapsedSize,
        // `Listener` 放在 SizedBox **里面**：它不参与布局（约束原样传给子级），
        // 所以按钮量出来的尺寸仍是 56×56，「距屏幕边缘的留白」那几条位置用例不受影响。
        child: Listener(
          onPointerDown: (_) => _setPressed(true),
          onPointerUp: (_) => _setPressed(false),
          onPointerCancel: (_) => _setPressed(false),
          child: Material(
            color: theme.colorScheme.primaryContainer,
            shape: const CircleBorder(),
            elevation: 6,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _toggleExpanded,
              customBorder: const CircleBorder(),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    illustViewIcon(widget.currentView),
                    size: 22,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                  // 当前视图名做"标识"：光靠图标不够，用户要的是"一眼看出在哪个视图"。
                  Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontSize: 10,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 展开态的一个选项：**图标 + 文字标签**（用户第 2 点明确要求）。
  Widget _buildOption(ThemeData theme, IllustLibraryView view) {
    final selected = view == widget.currentView;
    final foreground = selected
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;
    return Material(
      key: illustViewOptionKey(view),
      color: selected
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(24),
      elevation: 4,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _select(view),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(illustViewIcon(view), size: 20, color: foreground),
              const SizedBox(width: 8),
              Text(
                illustViewLabel(view),
                style: theme.textTheme.labelLarge?.copyWith(color: foreground),
              ),
              if (selected) ...[
                const SizedBox(width: 6),
                Icon(Icons.check, size: 16, color: foreground),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
