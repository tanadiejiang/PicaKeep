import 'dart:math' as math;
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'cover_target_provider.dart';

/// Decode density follows both physical frame axes and the encoded aspect.
class CoverDecodeTarget extends ImageProvider<CoverDecodeKey> {
  const CoverDecodeTarget(this.imageProvider,
      {required this.frameWidth,
      required this.frameHeight,
      required this.fit,
      this.maximumEdge = 4096,
      this.maximumPixels = 4 * 1024 * 1024});
  final ImageProvider imageProvider;
  final int frameWidth, frameHeight, maximumEdge, maximumPixels;
  final BoxFit fit;

  static const _boundedMaximumEdge = 4096;
  static const _boundedMaximumPixels = 4 * 1024 * 1024;

  /// Mirrors [obtainKey] for a self-keyed, validated thumbnail provider.
  static CoverDecodeKey cacheKeyForBoundedProvider(ImageProvider provider,
      {int maximumEdge = _boundedMaximumEdge,
      int maximumPixels = _boundedMaximumPixels}) {
    if (provider is! BoundedCoverProvider ||
        maximumEdge < _boundedMaximumEdge ||
        maximumPixels < _boundedMaximumPixels) {
      throw ArgumentError('Provider must satisfy the bounded cover contract');
    }
    return CoverDecodeKey(
        provider, 0, 0, BoxFit.contain, maximumEdge, maximumPixels, provider);
  }

  bool _usesBoundedPixels(ImageProvider provider) =>
      provider is BoundedCoverProvider &&
      maximumEdge >= _boundedMaximumEdge &&
      maximumPixels >= _boundedMaximumPixels;

  @override
  Future<CoverDecodeKey> obtainKey(ImageConfiguration configuration) async {
    final provider = imageProvider is CoverTargetProvider
        ? (imageProvider as CoverTargetProvider).forCoverTarget(
            frameWidth: frameWidth, frameHeight: frameHeight, fit: fit)
        : imageProvider;
    if (_usesBoundedPixels(provider)) {
      return cacheKeyForBoundedProvider(provider,
          maximumEdge: maximumEdge, maximumPixels: maximumPixels);
    }
    return CoverDecodeKey(await provider.obtainKey(configuration), frameWidth,
        frameHeight, fit, maximumEdge, maximumPixels, provider);
  }

  @override
  ImageStreamCompleter loadImage(
      CoverDecodeKey key, ImageDecoderCallback decode) {
    final completer = _usesBoundedPixels(key.decoderProvider)
        ? key.decoderProvider.loadImage(key.providerKey, decode)
        : key.decoderProvider.loadImage(
            key.providerKey,
            (ui.ImmutableBuffer buffer,
                    {ui.TargetImageSizeCallback? getTargetSize}) =>
                decode(buffer,
                    getTargetSize: (intrinsicWidth, intrinsicHeight) {
                  final size = dimensions(intrinsicWidth, intrinsicHeight,
                      frameWidth, frameHeight, fit,
                      maximumEdge: maximumEdge, maximumPixels: maximumPixels);
                  return ui.TargetImageSize(width: size.$1, height: size.$2);
                }));
    completer.addEphemeralErrorListener((Object error, StackTrace? stack) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
    return completer;
  }

  static (int, int) dimensions(
      int width, int height, int frameWidth, int frameHeight, BoxFit fit,
      {int maximumEdge = 4096, int maximumPixels = 4 * 1024 * 1024}) {
    final sx = frameWidth / width;
    final sy = frameHeight / height;
    final fittingScale =
        fit == BoxFit.cover ? math.max(sx, sy) : math.min(sx, sy);
    final scale = math.min(
        1.0,
        math.min(
            fittingScale,
            math.min(maximumEdge / math.max(width, height),
                math.sqrt(maximumPixels / (width * height)))));
    return (
      math.max(1, (width * scale).ceil()),
      math.max(1, (height * scale).ceil())
    );
  }
}

class CoverDecodeKey {
  const CoverDecodeKey(this.providerKey, this.width, this.height, this.fit,
      this.maximumEdge, this.maximumPixels, this.decoderProvider);
  final dynamic providerKey;
  final ImageProvider decoderProvider;
  final int width, height, maximumEdge, maximumPixels;
  final BoxFit fit;
  @override
  bool operator ==(Object other) =>
      other is CoverDecodeKey &&
      providerKey == other.providerKey &&
      width == other.width &&
      height == other.height &&
      fit == other.fit &&
      maximumEdge == other.maximumEdge &&
      maximumPixels == other.maximumPixels;
  @override
  int get hashCode =>
      Object.hash(providerKey, width, height, fit, maximumEdge, maximumPixels);
}
