// Task-only readback of an integer physical-pixel extent. The original scene
// transform remains intact and the returned image is never resized.
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class ImagePipeline022ReadbackBoundary extends SingleChildRenderObjectWidget {
  const ImagePipeline022ReadbackBoundary({super.key, required super.child});

  @override
  ImagePipeline022ReadbackRenderObject createRenderObject(
          BuildContext context) =>
      ImagePipeline022ReadbackRenderObject();
}

class ImagePipeline022ReadbackRenderObject extends RenderRepaintBoundary {
  Future<ui.Image> capturePixels(
      {required int width, required int height, required double pixelRatio}) {
    if (width <= 0 || height <= 0 || pixelRatio <= 0) {
      throw ArgumentError('Positive capture dimensions and DPR are required');
    }
    assert(!debugNeedsPaint);
    // OffsetLayer rounds each physical dimension up. At DPR=2.75 an exact
    // 800 / DPR * DPR may become 800.0000000000001, adding a spurious column.
    // This infinitesimal inward bound changes only ceil's extent, not the
    // scene scale or pixel sampling. It still yields every requested pixel.
    return (layer! as OffsetLayer).toImage(
        Rect.fromLTWH(
            0, 0, (width - 1e-7) / pixelRatio, (height - 1e-7) / pixelRatio),
        pixelRatio: pixelRatio);
  }
}
