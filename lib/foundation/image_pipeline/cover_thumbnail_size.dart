import 'package:flutter/painting.dart';

({int width, int height}) coverFramePhysicalTarget(
    Size logicalFrame, double devicePixelRatio) {
  final ratio = devicePixelRatio.clamp(1.0, double.infinity);
  return (
    width: (logicalFrame.width * ratio * 1.35).ceil().clamp(1, 16384),
    height: (logicalFrame.height * ratio * 1.35).ceil().clamp(1, 16384),
  );
}

int coverThumbnailWidthBucket(int requestedWidth) => requestedWidth <= 384
    ? 384
    : requestedWidth <= 768
        ? 768
        : requestedWidth <= 1024
            ? 1024
            : requestedWidth <= 1536
                ? 1536
                : requestedWidth <= 3072
                    ? 3072
                    : 4096;
