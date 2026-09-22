import 'package:flutter/painting.dart';

final _separateParagraph = RegExp(
  r'[\x00-\x1f\u0085\u200e\u200f\u2028-\u202e\u2066-\u2069]',
);

/// Shares paragraph layout for the default category typography.
List<double> measureCategoryLabelWidths(
  List<String> labels, {
  required TextStyle style,
  required TextScaler textScaler,
  required TextDirection textDirection,
  required Locale locale,
}) {
  if (labels.isEmpty) return const [];
  final widths = List<double>.filled(labels.length, 0);
  final batchIndices = <int>[];
  final individualIndices = <int>[];
  // Native line metrics and standalone paragraph widths can round differently
  // with custom spacing or scaling. Keep the original path for those contexts.
  final batchTypography = style.fontSize == 14 &&
      textScaler.scale(14) == 14 &&
      style.letterSpacing == .1 &&
      (style.wordSpacing ?? 0) == 0 &&
      style.fontStyle != FontStyle.italic &&
      (style.fontFeatures?.isEmpty ?? true) &&
      (style.fontVariations?.isEmpty ?? true);
  for (var index = 0; index < labels.length; index++) {
    final label = labels[index];
    // Line metrics omit trailing whitespace and a hard break creates extra
    // lines. Preserve TextPainter.width semantics for these exceptional labels.
    if (!batchTypography ||
        label.length > 128 ||
        label.isEmpty ||
        label.trim() != label ||
        _separateParagraph.hasMatch(label)) {
      individualIndices.add(index);
    } else {
      batchIndices.add(index);
    }
  }
  final painter = TextPainter(
    textDirection: textDirection,
    textScaler: textScaler,
    locale: locale,
  );
  try {
    if (batchIndices.isNotEmpty) {
      painter.text = TextSpan(
        text: batchIndices.map((index) => labels[index]).join('\n'),
        style: style,
      );
      painter.layout();
      final lines = painter.computeLineMetrics();
      if (lines.length == batchIndices.length) {
        for (var index = 0; index < lines.length; index++) {
          final width = lines[index].width;
          widths[batchIndices[index]] = width;
          // Native paragraph arithmetic can differ by a few subpixels for a
          // line in a batch. Near an integer this could change the ceil used by
          // the button layout, so resolve ambiguous widths alone.
          final rounded = width.roundToDouble();
          if ((width - rounded).abs() < .01) {
            individualIndices.add(batchIndices[index]);
          }
        }
      } else {
        individualIndices.addAll(batchIndices);
      }
    }
    for (final index in individualIndices) {
      painter.text = TextSpan(text: labels[index], style: style);
      painter.layout();
      widths[index] = painter.width;
    }
  } finally {
    painter.dispose();
  }
  return widths;
}
