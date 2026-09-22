import 'package:flutter/material.dart';

/// A category action whose surface stays static while its ink handles feedback.
///
/// Category rows are frequently created and recycled while scrolling. Keeping
/// elevation and shape out of implicit animations avoids allocating animation
/// controllers for properties that never change during that interaction.
class ExploreCategoryButton extends StatefulWidget {
  const ExploreCategoryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.textStyle,
    this.focusNode,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final TextStyle? textStyle;
  final FocusNode? focusNode;
  final bool autofocus;

  /// Use the same label metrics when arranging buttons into visual rows.
  static TextStyle labelStyleOf(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.elevatedButtonTheme.style?.textStyle
            ?.resolve(const <WidgetState>{}) ??
        theme.textTheme.labelLarge!;
    return MediaQuery.boldTextOf(context)
        ? style.copyWith(fontWeight: FontWeight.bold)
        : style;
  }

  @override
  State<ExploreCategoryButton> createState() => _ExploreCategoryButtonState();
}

class _ExploreCategoryButtonState extends State<ExploreCategoryButton> {
  static const _radius = BorderRadius.all(Radius.circular(12));
  late FocusNode _focusNode;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focused = _focusNode.hasFocus;
  }

  @override
  void didUpdateWidget(covariant ExploreCategoryButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      if (oldWidget.focusNode == null) _focusNode.dispose();
      _focusNode = widget.focusNode ?? FocusNode();
      _focused = _focusNode.hasFocus;
    }
  }

  @override
  void dispose() {
    if (widget.focusNode == null) _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange(bool _) {
    final focused = _focusNode.hasFocus;
    if (mounted && _focused != focused) setState(() => _focused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final enabled = widget.onPressed != null;
    final style =
        (widget.textStyle ?? ExploreCategoryButton.labelStyleOf(context))
            .copyWith(
      color:
          enabled ? colors.onSurface : colors.onSurface.withValues(alpha: .38),
    );
    return Semantics(
      container: true,
      // The entire control is one accessible button. Supplying its complete
      // semantics here keeps scrolling from traversing the decorative ink,
      // material and label render objects for every geometry update.
      excludeSemantics: true,
      label: widget.label,
      button: true,
      enabled: enabled,
      focused: enabled ? _focused : null,
      onTap: widget.onPressed,
      onFocus: enabled ? _focusNode.requestFocus : null,
      child: PhysicalModel(
        color: enabled
            ? Color.alphaBlend(
                colors.primaryContainer.withValues(alpha: .55),
                colors.surfaceContainerLow,
              )
            : colors.onSurface.withValues(alpha: .12),
        shadowColor: colors.shadow,
        elevation: enabled ? 1 : 0,
        borderRadius: _radius,
        child: Material(
          type: MaterialType.transparency,
          textStyle: style,
          child: InkWell(
            onTap: widget.onPressed,
            focusNode: _focusNode,
            autofocus: widget.autofocus,
            canRequestFocus: enabled,
            onFocusChange: _onFocusChange,
            borderRadius: _radius,
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed) ||
                  states.contains(WidgetState.focused)) {
                return colors.primary.withValues(alpha: .1);
              }
              if (states.contains(WidgetState.hovered)) {
                return colors.primary.withValues(alpha: .08);
              }
              return null;
            }),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Align(
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Text(widget.label, textAlign: TextAlign.center),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
