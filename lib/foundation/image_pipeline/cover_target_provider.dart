import 'package:flutter/painting.dart';

/// Encoded cover variants must match the card before its decoder can downsize.
abstract interface class CoverTargetProvider {
  ImageProvider<Object> forCoverTarget({
    required int frameWidth,
    required int frameHeight,
    required BoxFit fit,
  });
}

/// A validated thumbnail whose decoded pixels are independent of card geometry.
///
/// Implementations must include their resolution bucket and source version in
/// their own cache identity, return themselves from [ImageProvider.obtainKey],
/// and guarantee every decoded frame is at most 4096 pixels on either axis and
/// 4 Mi pixels in area. Original files and unvalidated remote images do not meet
/// this contract. Keeping these pixels avoids another decode when only a
/// placeholder aspect ratio or the card's fit changes.
abstract interface class BoundedCoverProvider {}
