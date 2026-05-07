import 'dart:math' as math;
import 'package:flutter/rendering.dart';
import '../base.dart';

class SliverGridDelegateWithComics extends SliverGridDelegate {
  SliverGridDelegateWithComics([
    this.useBriefMode = false,
    this.scale,
    String? layoutSetting,
  ])  : layoutSetting = layoutSetting ?? appdata.settings[44],
        resolvedUseBriefMode =
            _resolveUseBriefMode(useBriefMode, layoutSetting ?? appdata.settings[44]),
        resolvedScale =
            _resolveScale(scale, layoutSetting ?? appdata.settings[44]);

  final bool useBriefMode;
  final String? scale;
  final String layoutSetting;
  final bool resolvedUseBriefMode;
  final double resolvedScale;

  static List<String> _splitLayoutSetting(String setting) {
    final parts = setting.split(',');
    if (parts.length == 1) {
      parts.add('1.0');
    }
    return parts;
  }

  static bool _resolveUseBriefMode(bool useBriefMode, String layoutSetting) {
    final setting = _splitLayoutSetting(layoutSetting);
    return useBriefMode || setting[0] == '1' || setting[0] == '2';
  }

  static double _resolveScale(String? scale, String layoutSetting) {
    final setting = _splitLayoutSetting(layoutSetting);
    return double.tryParse(scale ?? setting[1]) ?? 1.0;
  }

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    if (resolvedUseBriefMode) {
      return getBriefModeLayout(constraints, resolvedScale);
    }
    return getDetailedModeLayout(constraints, resolvedScale);
  }

  SliverGridLayout getDetailedModeLayout(
      SliverConstraints constraints, double scale) {
    const maxCrossAxisExtent = 650;
    final itemHeight = 164 * scale;
    final width = constraints.crossAxisExtent;
    var crossItems = width ~/ maxCrossAxisExtent;
    if (width % maxCrossAxisExtent != 0) {
      crossItems += 1;
    }
    return SliverGridRegularTileLayout(
      crossAxisCount: crossItems,
      mainAxisStride: itemHeight,
      crossAxisStride: width / crossItems,
      childMainAxisExtent: itemHeight,
      childCrossAxisExtent: width / crossItems,
      reverseCrossAxis: false,
    );
  }

  SliverGridLayout getBriefModeLayout(
      SliverConstraints constraints, double scale) {
    final maxCrossAxisExtent = 192.0 * scale;
    const childAspectRatio = 0.72;
    const crossAxisSpacing = 0.0;
    int crossAxisCount =
        (constraints.crossAxisExtent / (maxCrossAxisExtent + crossAxisSpacing))
            .ceil();
    crossAxisCount = math.max(1, crossAxisCount);
    final double usableCrossAxisExtent = math.max(
      0.0,
      constraints.crossAxisExtent - crossAxisSpacing * (crossAxisCount - 1),
    );
    final double childCrossAxisExtent = usableCrossAxisExtent / crossAxisCount;
    final double childMainAxisExtent = childCrossAxisExtent / childAspectRatio;
    return SliverGridRegularTileLayout(
      crossAxisCount: crossAxisCount,
      mainAxisStride: childMainAxisExtent,
      crossAxisStride: childCrossAxisExtent + crossAxisSpacing,
      childMainAxisExtent: childMainAxisExtent,
      childCrossAxisExtent: childCrossAxisExtent,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(covariant SliverGridDelegate oldDelegate) {
    return oldDelegate is! SliverGridDelegateWithComics ||
        oldDelegate.resolvedUseBriefMode != resolvedUseBriefMode ||
        oldDelegate.resolvedScale != resolvedScale;
  }
}