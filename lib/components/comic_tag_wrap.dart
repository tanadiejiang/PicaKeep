import 'dart:math' as math;
import 'package:flutter/material.dart';

const _tagChipHorizontalPadding = 3.0;
const _tagChipTopPadding = 1.0;
const _tagChipBottomPadding = 3.0;
const comicTagTrailingGap = 4.0;
const _tagChipRunGap = 3.0;

/// 标签 chip 的默认字号。
const _tagChipBaseFontSize = 12.0;

/// 缩小后的字号下限。
///
/// 再小就难读了；到了下限还放不下就**接受截断**，不做无限制缩放
/// （用户要的是"显示不全时缩一点"，不是"缩到看不清也要塞完"）。
const _tagChipMinFontSize = 9.5;

/// 自适应时每次缩小的步长。
const _tagChipFontStep = 1.5;

/// 「标签显示行数」为 3 行或不限时的基准字号：比默认小一档，给内容让位。
const _tagChipCompactFontSize = 10.5;

/// 该显示几行时用哪个基准字号。
///
/// - 2 行（默认）：12pt，与改动前完全一致；
/// - 3 行 / 不限：10.5pt —— 这两档本就是"想多看点标签"，小一档换更多内容。
double tagChipBaseFontSizeFor(int? maxTagRows) {
  if (maxTagRows == null || maxTagRows >= 3) {
    return _tagChipCompactFontSize;
  }
  return _tagChipBaseFontSize;
}

class ComicTagWrap extends StatelessWidget {
  const ComicTagWrap({
    super.key,
    required this.tags,
    required this.maxRows,
    this.fontSize = _tagChipBaseFontSize,
    this.reserveRows = false,
  });

  final List<String> tags;

  /// null 显示全部标签，按卡片宽度自然换行。
  final int? maxRows;

  /// chip 字号；由调用方按"显示几行 / 是否还能放下"决定。
  final double fontSize;

  /// 瀑布流使用固定行预算；空标签也保留空间，不改变旧定高卡片布局。
  final bool reserveRows;

  @override
  Widget build(BuildContext context) {
    final inheritedStyle =
        DefaultTextStyle.of(context).style.merge(TextStyle(fontSize: fontSize));
    final textStyle = reserveRows && MediaQuery.boldTextOf(context)
        ? inheritedStyle.copyWith(fontWeight: FontWeight.bold)
        : inheritedStyle;
    final strut = reserveRows
        ? StrutStyle.fromTextStyle(textStyle, forceStrutHeight: true)
        : null;
    Widget wrap() => _buildWrap(context, textStyle, strut);
    if (!reserveRows || maxRows == null) return wrap();
    final painter = TextPainter(
      text: TextSpan(text: '\u200b', style: textStyle),
      strutStyle: strut,
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
    )..layout();
    final rowHeight = painter.height +
        _tagChipTopPadding +
        _tagChipBottomPadding +
        _tagChipRunGap;
    painter.dispose();
    return SizedBox(height: math.max(0, maxRows!) * rowHeight, child: wrap());
  }

  Widget _buildWrap(
      BuildContext context, TextStyle textStyle, StrutStyle? strut) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final visibleTags = maxRows == null
            ? tags
            : _visibleTagPrefix(
                tags: tags,
                maxRows: maxRows!,
                maxWidth: constraints.maxWidth,
                maxHeight: constraints.maxHeight,
                textStyle: textStyle,
                textScaler: MediaQuery.textScalerOf(context),
                textDirection: Directionality.of(context),
                locale: Localizations.maybeLocaleOf(context),
                strutStyle: strut,
              );
        if (visibleTags.isEmpty) {
          return const SizedBox.shrink();
        }

        final maxChipWidth =
            math.max(0.0, constraints.maxWidth - comicTagTrailingGap);
        return Wrap(
          runAlignment: WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            for (final tag in visibleTags)
              ComicTagChip(
                tag: tag,
                maxWidth: maxChipWidth,
                fontSize: fontSize,
                strutStyle: strut,
              ),
          ],
        );
      },
    );
  }
}

class ComicTagChip extends StatelessWidget {
  const ComicTagChip({
    super.key,
    required this.tag,
    required this.maxWidth,
    this.fontSize = _tagChipBaseFontSize,
    this.strutStyle,
  });

  final String tag;
  final double maxWidth;
  final double fontSize;
  final StrutStyle? strutStyle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(0, 0, comicTagTrailingGap, _tagChipRunGap),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          padding: const EdgeInsets.fromLTRB(
            _tagChipHorizontalPadding,
            _tagChipTopPadding,
            _tagChipHorizontalPadding,
            _tagChipBottomPadding,
          ),
          decoration: BoxDecoration(
            color: tag == "Unavailable"
                ? Theme.of(context).colorScheme.errorContainer
                : Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: Text(
            tag,
            style: TextStyle(fontSize: fontSize),
            strutStyle: strutStyle,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// 自适应标签字号："显示不全就把字号调小"。
///
/// 语义：
/// - 先算基准字号下能显示多少标签（[baseCount]）；
/// - 再逐步缩小字号，只要"可见标签数 **不少于** 基准"就继续缩 ——
///   缩小后能塞进更多标签（数量可能超过基准，那是白赚的）；
/// - 到达 [minFontSize] 下限即停；再小就难读，剩下的一律截断。
///
/// 只缩不放：不会出现"比默认字号还大"的情况。
double fitComicTagFontSize({
  required List<String> tags,
  required double baseFontSize,
  required int maxRows,
  required double maxWidth,
  required double maxHeight,
  required double maxTagWidth,
  required TextStyle tagStyle,
  required TextScaler textScaler,
  required TextDirection textDirection,
  required Locale? locale,
}) {
  if (tags.isEmpty) {
    return baseFontSize;
  }
  int visibleCount(double fontSize) {
    return _visibleTagPrefix(
      tags: tags,
      maxRows: maxRows,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      textStyle: tagStyle.merge(TextStyle(fontSize: fontSize)),
      textScaler: textScaler,
      textDirection: textDirection,
      locale: locale,
      maxChipWidthOverride: maxTagWidth,
    ).length;
  }

  final baseCount = visibleCount(baseFontSize);
  if (baseCount >= tags.length) {
    return baseFontSize;
  }
  final candidates = <double>[];
  for (var size = baseFontSize - _tagChipFontStep;
      size >= _tagChipMinFontSize - 0.001;
      size -= _tagChipFontStep) {
    candidates.add(size);
  }
  if (candidates.isEmpty) {
    return baseFontSize;
  }
  var best = baseFontSize;
  var bestCount = baseCount;
  // 从大到小试：优先保住可读性，只在"可见数不减少"时接受更小字号。
  for (final size in candidates) {
    final count = visibleCount(size);
    if (count >= bestCount) {
      best = size;
      bestCount = count;
    } else {
      break;
    }
  }
  return best;
}

List<String> _visibleTagPrefix({
  required List<String> tags,
  required int maxRows,
  required double maxWidth,
  required double maxHeight,
  required TextStyle textStyle,
  required TextScaler textScaler,
  required TextDirection textDirection,
  required Locale? locale,
  StrutStyle? strutStyle,

  /// 覆盖芯片最大宽度（用于"按实际渲染宽度"复核；默认由 maxWidth 推导）。
  double? maxChipWidthOverride,
}) {
  if (maxRows <= 0 ||
      !maxWidth.isFinite ||
      maxWidth <= comicTagTrailingGap ||
      maxHeight <= 0) {
    return const <String>[];
  }

  // 复核时用"实际渲染宽度"（chips 外面还有 trailingGap），避免低估占位。
  final maxChipWidth = maxChipWidthOverride ?? (maxWidth - comicTagTrailingGap);
  final maxTextWidth = math.max(
    0.0,
    maxChipWidth - _tagChipHorizontalPadding * 2,
  );
  final visibleTags = <String>[];
  var completedRowsHeight = 0.0;
  var currentRowWidth = 0.0;
  var currentRowHeight = 0.0;
  var row = 0;

  for (final tag in tags) {
    final metrics = _measureTagChip(
      tag,
      textStyle: textStyle,
      textScaler: textScaler,
      textDirection: textDirection,
      locale: locale,
      maxChipWidth: maxChipWidth,
      maxTextWidth: maxTextWidth,
      strutStyle: strutStyle,
    );
    final startsNewRow =
        currentRowWidth > 0 && currentRowWidth + metrics.width > maxWidth;
    if (startsNewRow) {
      completedRowsHeight += currentRowHeight;
      currentRowWidth = 0;
      currentRowHeight = 0;
      row++;
    }
    if (row >= maxRows) {
      break;
    }

    final candidateRowHeight = math.max(currentRowHeight, metrics.height);
    if (maxHeight.isFinite &&
        completedRowsHeight + candidateRowHeight > maxHeight) {
      break;
    }

    visibleTags.add(tag);
    currentRowWidth += metrics.width;
    currentRowHeight = candidateRowHeight;
  }
  return visibleTags;
}

_TagChipMetrics _measureTagChip(
  String tag, {
  required TextStyle textStyle,
  required TextScaler textScaler,
  required TextDirection textDirection,
  required Locale? locale,
  required double maxChipWidth,
  required double maxTextWidth,
  StrutStyle? strutStyle,
}) {
  final textPainter = TextPainter(
    text: TextSpan(text: tag, style: textStyle),
    textDirection: textDirection,
    textScaler: textScaler,
    locale: locale,
    maxLines: 1,
    ellipsis: '...',
    strutStyle: strutStyle,
  )..layout(maxWidth: maxTextWidth);
  final metrics = _TagChipMetrics(
    width: math.min(
          maxChipWidth,
          textPainter.width + _tagChipHorizontalPadding * 2,
        ) +
        comicTagTrailingGap,
    height: textPainter.height +
        _tagChipTopPadding +
        _tagChipBottomPadding +
        _tagChipRunGap,
  );
  textPainter.dispose();
  return metrics;
}

class _TagChipMetrics {
  const _TagChipMetrics({
    required this.width,
    required this.height,
  });

  final double width;
  final double height;
}
