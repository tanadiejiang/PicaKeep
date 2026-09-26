import 'package:flutter/material.dart';

/// 设置项分组**之间**的主分割线。
///
/// ## 需求来源
///
/// 用户真机反馈原话：「设置页的每个分区没有主要的分割线，需要增加」。
/// 改动前 `SettingsTitle` 是个**裸 `ListTile`**，分区标题与上下设置项之间没有任何
/// 视觉分界；设置项彼此之间也没有线 —— 结果是一长条平铺的列表，
/// "这里换了一个分区"只能靠读标题文字才知道。
///
/// ## 与"设置项之间的细线"的区别
///
/// 本控件刻意**更重**（更粗 + 上下留白），这样即便将来某个分区内部加了细线，
/// 两级层级仍然一眼可分：
/// - 分区之间：本控件（`thickness` 1.2 + 上下各 12/4 留白）；
/// - 分区内部设 置项之间：各页自己决定，通常 `Divider(height: 1, thickness: 0.6)`。
///
/// 观感与既有先例 `comic_card_display_settings.dart` 的
/// `_CardDisplayDivider(section: true)` 对齐（同一个色、同样的粗细），
/// 避免设置页内部出现两套"分区线"。
class SettingsSectionDivider extends StatelessWidget {
  const SettingsSectionDivider({super.key});

  /// 分割线粗细（略重于 1px，肉眼能立刻分出"这是分区"）。
  static const double thickness = 1.2;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    return Padding(
      // 上留白比下留白大：视觉上"线跟着它下面那个分区标题走"，
      // 归属关系比居中更清楚。
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Divider(height: 1, thickness: thickness, color: color),
    );
  }
}

/// 设置页的两列（窄屏一列）布局：**同时负责在分区之间插主分割线**。
///
/// ## 为什么在这里插，而不是每个页面各写一遍
///
/// `SettingsTitle` 的语义就是"从这里开始是新分区"，而它在本项目里**总是**
/// 直接作为 [buildTwoColumnLayout] 的子项出现（22 处调用点都是如此）。所以
/// "新分区之前画一条主分割线"这条规则放在这里实现一次，就自动覆盖了
/// 「浏览 / 下载 / 网络 / 阅读 / 应用 / 关于 / AI …」全部设置页 ——
/// 包括将来新加的页面，不会有人忘了加。
///
/// 首个子项**之前不画**：那是页面顶部（标题栏下方），画一条线会像是"上面还有
/// 内容"，反而制造困惑。
Widget buildTwoColumnLayout(double width, List<Widget> children) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0 && children[i] is SettingsTitle)
          const SettingsSectionDivider(),
        SizedBox(width: double.infinity, child: children[i]),
      ],
    ],
  );
}

Widget buildResponsiveSettingTile({
  Widget? leading,
  required Widget title,
  Widget? subtitle,
  required Widget trailing,
  double trailingWidth = 140,
  bool expandTrailingOnNarrow = false,
  VoidCallback? onTap,
}) {
  return LayoutBuilder(
    builder: (context, constraints) {
      const horizontalPadding = 32.0;
      const reservedLeadingWidth = 56.0;
      const reservedTitleWidth = 120.0;
      const minimumTrailingWidth = 72.0;
      final availableTrailingWidth = constraints.maxWidth -
          horizontalPadding -
          (leading != null ? reservedLeadingWidth : 0.0) -
          reservedTitleWidth;
      final safeTrailingWidth = availableTrailingWidth > minimumTrailingWidth
          ? availableTrailingWidth
          : minimumTrailingWidth;
      final effectiveTrailingWidth = expandTrailingOnNarrow
          ? safeTrailingWidth
          : (safeTrailingWidth < trailingWidth
              ? safeTrailingWidth
              : trailingWidth);

      return ListTile(
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing: SizedBox(
          width: effectiveTrailingWidth,
          child: Align(
            alignment: Alignment.centerRight,
            child: trailing,
          ),
        ),
        onTap: onTap,
      );
    },
  );
}

class SettingsTitle extends StatelessWidget {
  const SettingsTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(text),
      trailing: trailing,
    );
  }
}
