/// 库视图「档位」选择器（36 号）：工具栏一颗按钮 → 圆角面板 → 平铺选项。
///
/// ## 为什么抽成共享组件
///
/// 用户要求「所有页的这个三档切换都改成和刚刚图集页的那个样式一样」。
/// 涉及多个页面（已下载 / 图片收藏 / 图库 / 回收站），各自复制一份样式必然分叉
/// —— 一旦分叉，用户下次就会看到"同一件事在几个地方长得不一样"。
///
/// ## 视觉来源：探索页的 `_EntryMenu`（用户点名的参考）
///
/// 数值**全部照抄** `pages/explore/explore_page.dart` 的 `_EntryMenu`：
/// - 面板：右上对齐的 `Dialog` + 圆角 18 + 宽 280（与图集页
///   「资源库显示设置」面板同款）；
/// - 标题行：12px / `onSurfaceVariant` / `w500`；
/// - 选项：`minHeight: 52` / `padding: h12 v8` / 圆角 12；选中 `secondaryContainer`
///   铺底；左侧 32×32 圆角 10 的图标块（选中 `surface@0.65` / 未选中
///   `surfaceContainerHighest`，图标 19）；尾部 20 宽位放 `check_circle_rounded`。
///
/// 图集页的档位区（`pages/local_library_page.dart` 的 `_buildTierSection`）也改用
/// 本文件的 [LibraryViewSelectorTile]，所以"同一套样式"是**一处实现**，
/// 不是两处长得像。
///
/// ## 为什么不做成 `PopupMenuButton`
///
/// 探索页那个是 `PopupMenuButton` + 自定义 `PopupMenuItem`，但它的选项**不需要**
/// 禁用态与禁用原因。而档位在"远程不可用"时必须**置灰 + 写明原因**而不是消失
/// （36 号真机反馈的教训：藏起来等于功能不存在）。选项用普通 `InkWell` 自行
/// 控制禁用渲染；默认放在 `Dialog`，有按钮锚点时放在弹出菜单路由中。
library;

import 'package:flutter/material.dart';

import 'package:picakeep/tools/translations.dart';

/// 面板宽度（与图集页「资源库显示设置」面板一致）。
const double libraryViewSelectorPanelMaxWidth = 280;

/// 单个选项的最小高度。
const double libraryViewSelectorTileMinHeight = 52;

/// 选项容器的圆角。
const double libraryViewSelectorTileRadius = 12;

/// 选项左侧图标块的边长（圆角为其 1/3 左右，照抄探索页的 32 / 10）。
const double libraryViewSelectorIconBoxSize = 32;

/// 图标块内图标的尺寸。
const double libraryViewSelectorIconSize = 19;

/// 面板顶端的留白：与图集页那个面板同款（避开 AppBar）。
const EdgeInsets libraryViewSelectorPanelInset =
    EdgeInsets.only(top: 72, right: 12, left: 80);

/// 面板整体高度的上限系数（乘屏幕高度）。超过就滚动，不 overflow。
const double libraryViewSelectorPanelMaxHeightFactor = 0.6;

/// 一个档位选项。
class LibraryViewSelectorEntry<T> {
  const LibraryViewSelectorEntry({
    required this.value,
    required this.label,
    required this.icon,
    this.enabled = true,
    this.disabledReason,
  });

  final T value;

  /// 完整档位名（例如 `本地已下载` / `远程 · 已下载`）。
  final String label;

  final IconData icon;

  /// 现在能不能选。
  ///
  /// 为假时**仍然列出来**（置灰 + 显示 [disabledReason]），而不是隐藏 ——
  /// 用户真机反馈过"找不到档位切换"，隐藏等于这个功能不存在。
  final bool enabled;

  /// 不可用的原因（例如 `远程服务不可用`）。[enabled] 为真时不显示。
  final String? disabledReason;
}

/// 档位面板里的一个选项（图集页与本组件共用这一份渲染）。
class LibraryViewSelectorTile<T> extends StatelessWidget {
  const LibraryViewSelectorTile({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final LibraryViewSelectorEntry<T> entry;
  final bool selected;

  /// 选中回调；[LibraryViewSelectorEntry.enabled] 为假时不会被调用。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 置灰用手动降透明度，而不是 `ListTile(enabled: false)`：后者会把选中底色
    // 一起变灰，用户就看不出"当前停在哪一档"。
    final titleColor = entry.enabled
        ? (selected ? colors.onSecondaryContainer : colors.onSurface)
        : colors.onSurface.withValues(alpha: 0.38);
    final iconColor = entry.enabled
        ? (selected ? colors.onSecondaryContainer : colors.onSurfaceVariant)
        : colors.onSurfaceVariant.withValues(alpha: 0.38);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(libraryViewSelectorTileRadius),
        onTap: entry.enabled ? onTap : null,
        child: Container(
          constraints:
              const BoxConstraints(minHeight: libraryViewSelectorTileMinHeight),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? colors.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(libraryViewSelectorTileRadius),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: libraryViewSelectorIconBoxSize,
                height: libraryViewSelectorIconBoxSize,
                decoration: BoxDecoration(
                  color: selected
                      ? colors.surface.withValues(alpha: 0.65)
                      : colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  entry.icon,
                  size: libraryViewSelectorIconSize,
                  color: iconColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      entry.label.tl,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                        color: titleColor,
                      ),
                    ),
                    if (!entry.enabled &&
                        (entry.disabledReason ?? '').isNotEmpty)
                      Text(
                        entry.disabledReason!.tl,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 20,
                child: selected
                    ? Icon(
                        Icons.check_circle_rounded,
                        size: 20,
                        color: entry.enabled
                            ? colors.primary
                            : colors.primary.withValues(alpha: 0.5),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 弹出档位面板，返回用户选中的值（点外部/返回键取消时为 null）。
/// [anchorContext] 用于抽屉内的工具栏：面板跟随实际按钮，而非固定在页顶。
Future<T?> showLibraryViewSelector<T>({
  required BuildContext context,
  BuildContext? anchorContext,
  required String title,
  required List<LibraryViewSelectorEntry<T>> entries,
  required T selected,
}) {
  Widget content(BuildContext panelContext) {
    final colors = Theme.of(panelContext).colorScheme;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              title.tl,
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          for (final entry in entries)
            LibraryViewSelectorTile<T>(
              entry: entry,
              selected: entry.value == selected,
              onTap: () => Navigator.of(panelContext).pop(entry.value),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  if (anchorContext != null) {
    final overlay = Navigator.of(context, rootNavigator: true)
        .overlay!
        .context
        .findRenderObject()! as RenderBox;
    return showMenu<T>(
      context: context,
      useRootNavigator: true,
      // Re-evaluate the actual button after layout / viewport changes. The
      // popup route also clamps the panel to the screen's safe area.
      positionBuilder: (context, constraints) {
        final button = anchorContext.findRenderObject()! as RenderBox;
        final origin = button.localToGlobal(Offset.zero, ancestor: overlay);
        return RelativeRect.fromRect(
          Rect.fromLTWH(origin.dx, origin.dy + button.size.height + 4,
              button.size.width, 0),
          Offset.zero & overlay.size,
        );
      },
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      menuPadding: EdgeInsets.zero,
      constraints: BoxConstraints(
        maxWidth: libraryViewSelectorPanelMaxWidth,
        maxHeight: MediaQuery.sizeOf(context).height *
            libraryViewSelectorPanelMaxHeightFactor,
      ),
      items: [
        PopupMenuItem<T>(
          enabled: false,
          padding: EdgeInsets.zero,
          height: 0,
          child: SizedBox(
            width: libraryViewSelectorPanelMaxWidth,
            child: Builder(builder: content),
          ),
        ),
      ],
    );
  }

  return showDialog<T>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (dialogContext) {
      return Dialog(
        insetPadding: libraryViewSelectorPanelInset,
        alignment: Alignment.topRight,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: libraryViewSelectorPanelMaxWidth,
            maxHeight: MediaQuery.of(dialogContext).size.height *
                libraryViewSelectorPanelMaxHeightFactor,
          ),
          child: content(dialogContext),
        ),
      );
    },
  );
}

/// 工具栏上的档位按钮：图标 = 当前档，点击弹出 [showLibraryViewSelector]。
///
/// ⚠️ **只有一项时也照常显示**（不要改成"少于两项就隐藏"）：
/// 远程不可用时可供选择的档位可能少到只剩一项，而按钮一旦消失，用户就会以为
/// 档位功能被删了 —— 这正是 36 号第一轮真机反馈的原始症状。
class LibraryViewSelectorAction<T> extends StatelessWidget {
  const LibraryViewSelectorAction({
    super.key,
    required this.title,
    required this.entries,
    required this.selected,
    required this.onSelected,
  });

  /// 面板标题（也用作按钮 tooltip），例如 `已下载 · 档位`。
  final String title;

  final List<LibraryViewSelectorEntry<T>> entries;
  final T selected;
  final ValueChanged<T> onSelected;

  IconData get _currentIcon {
    for (final entry in entries) {
      if (entry.value == selected) {
        return entry.icon;
      }
    }
    return entries.isEmpty ? Icons.tune : entries.first.icon;
  }

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }
    return IconButton(
      icon: Icon(_currentIcon),
      tooltip: title.tl,
      onPressed: () async {
        final picked = await showLibraryViewSelector<T>(
          context: context,
          title: title,
          entries: entries,
          selected: selected,
        );
        if (picked == null || picked == selected) {
          return;
        }
        onSelected(picked);
      },
    );
  }
}
