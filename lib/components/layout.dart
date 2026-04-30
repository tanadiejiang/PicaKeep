import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../base.dart';

class SliverGridDelegateWithComics extends SliverGridDelegate {
  SliverGridDelegateWithComics([this.useBriefMode = false, this.scale]);

  final bool useBriefMode;
  final String? scale;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    var setting = appdata.settings[44].split(',');
    if (setting.length == 1) {
      setting.add("1.0");
    }
    if (setting[0] == "1" || setting[0] == "2" || useBriefMode) {
      return getBriefModeLayout(constraints, double.parse(scale ?? setting[1]));
    } else {
      return getDetailedModeLayout(constraints, double.parse(scale ?? setting[1]));
    }
  }

  SliverGridLayout getDetailedModeLayout(SliverConstraints constraints, double scale) {
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
        reverseCrossAxis: false
    );
  }

  SliverGridLayout getBriefModeLayout(SliverConstraints constraints, double scale) {
    final maxCrossAxisExtent = 192.0 * scale;
    const childAspectRatio = 0.72;
    const crossAxisSpacing = 0.0;
    int crossAxisCount = (constraints.crossAxisExtent / (maxCrossAxisExtent + crossAxisSpacing)).ceil();
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
    return true;
  }
}
