import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'image_work_scheduler.dart';

typedef ReaderSyncRgbaDecoder = ui.Image Function(
    Uint8List bytes, int width, int height, ui.PixelFormat format);

class ReaderRawImageDecodeResult {
  const ReaderRawImageDecodeResult({
    required this.image,
    required this.immutableBufferMicroseconds,
    required this.imageCreationMicroseconds,
    required this.syncAttempted,
    required this.usedSync,
    required this.syncUnsupported,
  });

  final ui.Image image;
  final int immutableBufferMicroseconds;
  final int imageCreationMicroseconds;
  final bool syncAttempted;
  final bool usedSync;
  final bool syncUnsupported;

  /// The sync API returns before its raster upload finishes. Neither this flag
  /// nor the object creation time establishes that a frame has been displayed.
  bool get uploadDeferred => usedSync;
}

/// Creates an image from already premultiplied, sRGB RGBA8 pixels, without
/// resizing or converting them. The caller retains its pixels, cancellation
/// token, source lease and scheduler reservation until [decode] completes.
/// A returned image belongs to the caller, including any deferred raster work.
///
/// Sync is an explicit Android candidate only. It still copies the input and
/// uploads a texture; frame completion must be measured separately. Once the
/// engine reports it unsupported, this instance uses the existing async path.
class ReaderRawImageDecoder {
  ReaderRawImageDecoder()
      : _isAndroid = Platform.isAndroid,
        _syncDecode = ui.decodeImageFromPixelsSync;

  @visibleForTesting
  ReaderRawImageDecoder.forTesting({
    required bool isAndroid,
    ReaderSyncRgbaDecoder? syncDecode,
  })  : _isAndroid = isAndroid,
        _syncDecode = syncDecode ?? ui.decodeImageFromPixelsSync;

  static final shared = ReaderRawImageDecoder();
  static const _maximumSyncPixels = 4 * 1024 * 1024;
  static const _maximumSyncEdge = 16384;
  static const _skiaUnsupported =
      'decodeImageFromPixelsSync is not implemented on Skia.';

  final bool _isAndroid;
  final ReaderSyncRgbaDecoder _syncDecode;
  bool _syncUnsupported = false;

  Future<ReaderRawImageDecodeResult> decode(
    Uint8List bytes, {
    required int width,
    required int height,
    required int rowBytes,
    required bool Function() isCancelled,
    bool preferSync = false,
  }) async {
    if (isCancelled()) throw const ImageWorkCancelled();
    if (width <= 0 || height <= 0 || rowBytes < width * 4) {
      throw ArgumentError('Invalid RGBA dimensions or row stride');
    }
    if (bytes.length < rowBytes * height) {
      throw ArgumentError('RGBA bytes do not contain every complete row');
    }

    final useSync = preferSync &&
        _isAndroid &&
        !_syncUnsupported &&
        rowBytes == width * 4 &&
        width <= _maximumSyncEdge &&
        height <= _maximumSyncEdge &&
        width * height <= _maximumSyncPixels;
    var syncAttempted = false;
    if (useSync) {
      syncAttempted = true;
      final clock = Stopwatch()..start();
      ui.Image? image;
      try {
        image = _syncDecode(bytes, width, height, ui.PixelFormat.rgba8888);
      } catch (error) {
        // This SDK throws a String on Skia. Do not turn resource, pixel or GPU
        // failures into a successful fallback and obscure a broken candidate.
        if (error is! UnsupportedError && error != _skiaUnsupported) rethrow;
        _syncUnsupported = true;
      }
      clock.stop();
      if (image != null) {
        _validateResult(image, width, height, isCancelled);
        return ReaderRawImageDecodeResult(
          image: image,
          immutableBufferMicroseconds: 0,
          imageCreationMicroseconds: clock.elapsedMicroseconds,
          syncAttempted: true,
          usedSync: true,
          syncUnsupported: false,
        );
      }
    }

    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      if (isCancelled()) throw const ImageWorkCancelled();
      final copyClock = Stopwatch()..start();
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      copyClock.stop();
      if (isCancelled()) throw const ImageWorkCancelled();
      final createClock = Stopwatch()..start();
      descriptor = ui.ImageDescriptor.raw(buffer,
          width: width,
          height: height,
          rowBytes: rowBytes,
          pixelFormat: ui.PixelFormat.rgba8888);
      codec = await descriptor.instantiateCodec();
      if (isCancelled()) throw const ImageWorkCancelled();
      final image = (await codec.getNextFrame()).image;
      createClock.stop();
      _validateResult(image, width, height, isCancelled);
      return ReaderRawImageDecodeResult(
        image: image,
        immutableBufferMicroseconds: copyClock.elapsedMicroseconds,
        imageCreationMicroseconds: createClock.elapsedMicroseconds,
        syncAttempted: syncAttempted,
        usedSync: false,
        syncUnsupported: _syncUnsupported,
      );
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  static void _validateResult(
      ui.Image image, int width, int height, bool Function() isCancelled) {
    try {
      if (isCancelled()) throw const ImageWorkCancelled();
      if (image.width != width || image.height != height) {
        throw StateError('RGBA image dimensions changed');
      }
    } catch (_) {
      image.dispose();
      rethrow;
    }
  }
}
