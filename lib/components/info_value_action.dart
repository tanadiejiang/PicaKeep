import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The source-independent interaction contract for a visible metadata value.
///
/// The widget deliberately keeps display/copy text separate from the search
/// callback.  Translated labels can therefore be copied as shown while the
/// page supplies the source-specific raw search intent.
class InfoValueData {
  const InfoValueData({
    required this.displayText,
    this.copyText,
    this.rawSearchValue,
    this.rawNamespace = '',
  });

  final String displayText;
  final String? copyText;
  final String? rawSearchValue;
  final String rawNamespace;

  String get clipboardText => (copyText ?? displayText).trim();

  String get searchText => (rawSearchValue ?? displayText).trim();

  /// Empty/placeholder values describe missing metadata, not search intent.
  /// Keep this guard in the shared component so a caller cannot accidentally
  /// turn a visible `未知`/`N/A` fallback into a real query.
  bool get hasSearchableText {
    final value = searchText.trim();
    if (value.isEmpty) return false;
    switch (value.toLowerCase()) {
      case '未知':
      case '无':
      case '不确定':
      case 'unknown':
      case 'n/a':
      case 'na':
      case '-':
      case '--':
        return false;
      default:
        return true;
    }
  }
}

typedef InfoValueClipboardWriter = Future<void> Function(String text);

/// Controls how [InfoValueAction] sizes its child.
///
/// Metadata chips are commonly placed in a [Wrap], where the action wrapper
/// must keep the child's natural size. Callers that intentionally need a
/// full-width value (for example, a title row) can opt in explicitly.
enum InfoValueActionLayout {
  intrinsic,
  expand,
}

/// A compact visual value with a non-overlapping, accessible hit target.
///
/// Tap invokes the supplied search intent. Long press writes the visible value
/// directly to the clipboard; it never opens a secondary menu.
class InfoValueAction extends StatelessWidget {
  const InfoValueAction({
    super.key,
    required this.data,
    required this.child,
    this.onSearch,
    this.focusNode,
    this.clipboardWriter = _defaultClipboardWriter,
    this.copySuccessMessage = '已复制到剪贴板',
    this.copyFailureMessage = '复制失败',
    this.layout = InfoValueActionLayout.intrinsic,
  });

  final InfoValueData data;
  final Widget child;
  final VoidCallback? onSearch;

  /// Optional node for desktop/keyboard callers that need to place focus on
  /// a particular value (and for deterministic accessibility tests).
  final FocusNode? focusNode;
  final InfoValueClipboardWriter clipboardWriter;
  final String copySuccessMessage;
  final String copyFailureMessage;
  final InfoValueActionLayout layout;

  static Future<void> _defaultClipboardWriter(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _copy(BuildContext context) async {
    final text = data.clipboardText;
    if (text.isEmpty) return;
    try {
      await clipboardWriter(text);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(copySuccessMessage),
          duration: const Duration(seconds: 1),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(copyFailureMessage),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = data.displayText.trim();
    final canSearch = onSearch != null && data.hasSearchableText;
    final semanticsLabel = label.isEmpty ? '信息值' : label;
    final actionLabel =
        !canSearch ? '$semanticsLabel，长按复制' : '$semanticsLabel，点击搜索，长按复制';

    // InkWell supplies touch/hover feedback, while FocusableActionDetector
    // makes the same value reachable with Tab and activatable with Enter or
    // Space on desktop and assistive keyboards.
    final laidOutChild = switch (layout) {
      InfoValueActionLayout.intrinsic => child,
      InfoValueActionLayout.expand => SizedBox(
          width: double.infinity,
          child: child,
        ),
    };

    return FocusableActionDetector(
      focusNode: focusNode,
      shortcuts: !canSearch
          ? const <ShortcutActivator, Intent>{}
          : const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
      actions: !canSearch
          ? const <Type, Action<Intent>>{}
          : <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
                onSearch!();
                return null;
              }),
            },
      child: Semantics(
        button: true,
        enabled: data.clipboardText.isNotEmpty || canSearch,
        label: actionLabel,
        onTap: canSearch ? onSearch : null,
        onLongPress:
            data.clipboardText.isEmpty ? null : () => unawaited(_copy(context)),
        child: InkWell(
          onTap: canSearch ? onSearch : null,
          onLongPress: data.clipboardText.isEmpty
              ? null
              : () => unawaited(_copy(context)),
          focusColor:
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
          hoverColor:
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          child: laidOutChild,
        ),
      ),
    );
  }
}
