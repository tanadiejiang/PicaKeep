import 'dart:math' as math;
import 'package:flutter/painting.dart';

class ReaderTileDemand {
  const ReaderTileDemand(this.sourceRect, this.density, this.column, this.row,
      {Rect? rasterRect})
      : rasterRect = rasterRect ?? sourceRect;

  /// The original-coordinate region this tile owns for presentation.
  final Rect sourceRect;

  /// Extra original pixels decoded around a tile so image filters can sample
  /// across its presentation edges without clamping to the tile boundary.
  final Rect rasterRect;
  final double density;
  final int column;
  final int row;
  int get outputWidth => math.max(1, (rasterRect.width * density).ceil());
  int get outputHeight => math.max(1, (rasterRect.height * density).ceil());
  String get variant =>
      '${density.toStringAsFixed(6)}:$column:$row:${sourceRect.left}:${sourceRect.top}:${sourceRect.width}:${sourceRect.height}:${rasterRect.left}:${rasterRect.top}:${rasterRect.width}:${rasterRect.height}';
}

/// Maps a transformed image surface back to original pixels.
class ReaderViewportDemand {
  const ReaderViewportDemand({
    required this.visibleSourceRect,
    required this.physicalPixelsPerSourcePixel,
  });
  final Rect visibleSourceRect;
  final double physicalPixelsPerSourcePixel;

  double get density {
    final required = physicalPixelsPerSourcePixel.clamp(0.0, 1.0);
    if (required <= 0) return 0;
    // Power-of-two levels always round toward finer pixels.
    var level = 1.0;
    while (level / 2 >= required) {
      level /= 2;
    }
    return level;
  }

  List<ReaderTileDemand> tiles(Size sourceSize,
      {int tilePixels = 512, double samplingGutterPixels = 0}) {
    if (density == 0 || visibleSourceRect.isEmpty) return const [];
    final sourceBounds = Offset.zero & sourceSize;
    final visible = visibleSourceRect.intersect(sourceBounds);
    if (visible.isEmpty) return const [];
    final sourceTileSize = tilePixels / density;
    final left = (visible.left / sourceTileSize).floor();
    final top = (visible.top / sourceTileSize).floor();
    final right = (visible.right / sourceTileSize).ceil();
    final bottom = (visible.bottom / sourceTileSize).ceil();
    final result = <ReaderTileDemand>[];
    for (var y = top; y < bottom; y++) {
      for (var x = left; x < right; x++) {
        final rect = Rect.fromLTWH(x * sourceTileSize, y * sourceTileSize,
                sourceTileSize, sourceTileSize)
            .intersect(sourceBounds);
        final gutter = samplingGutterPixels / density;
        final rasterRect = Rect.fromLTRB(
            math.max(sourceBounds.left, rect.left - gutter),
            math.max(sourceBounds.top, rect.top - gutter),
            math.min(sourceBounds.right, rect.right + gutter),
            math.min(sourceBounds.bottom, rect.bottom + gutter));
        result
            .add(ReaderTileDemand(rect, density, x, y, rasterRect: rasterRect));
      }
    }
    return result;
  }
}
