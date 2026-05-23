import 'package:flutter/material.dart';

Widget buildTwoColumnLayout(double width, List<Widget> children) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final child in children)
        SizedBox(width: double.infinity, child: child),
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
  const SettingsTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(text),
    );
  }
}
