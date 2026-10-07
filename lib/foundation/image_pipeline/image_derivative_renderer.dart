import 'dart:io';
import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:picakeep_image_engine/picakeep_image_engine.dart' as native;
import 'native_disk_work.dart';

class ImageDerivativeProbe {
  const ImageDerivativeProbe(
      {required this.width,
      required this.height,
      this.animated = false,
      this.bitDepth = 8,
      this.colorSpace = 'sRGB',
      this.tilesAvailable = true,
      this.estimatedWorkingBytes = 64 * 1024 * 1024});
  final int width, height;
  final bool animated;
  final int bitDepth;
  final String colorSpace;
  final bool tilesAvailable;
  final int estimatedWorkingBytes;
}

class ImageDerivativeRect {
  const ImageDerivativeRect(this.x, this.y, this.width, this.height);
  final int x, y, width, height;
}

class ImageDerivativeRaster {
  const ImageDerivativeRaster(
      {required this.bytes,
      required this.width,
      required this.height,
      required this.mimeType,
      required this.lossless});
  final Uint8List bytes;
  final int width, height;
  final String mimeType;
  final bool lossless;
}

abstract interface class ImageDerivativeRenderer {
  Future<ImageDerivativeProbe> probe(String path);
  Future<ImageDerivativeRaster> render(
    String path, {
    required ImageDerivativeRect region,
    required int width,
    required int height,
    required String format,
    required String backingPath,
    required bool Function() isCancelled,
    int? jobBudgetBytes,
  });
  bool get supportsLargeRegions;
}

/// Decode and bounded PNG/JPEG/WebP encoding run in native worker isolates.
class NativeImageDerivativeRenderer implements ImageDerivativeRenderer {
  const NativeImageDerivativeRenderer(
      {this.memoryBudgetBytes = 1024 * 1024 * 1024,
      this.diskBudgetBytes = 1024 * 1024 * 1024});
  final int memoryBudgetBytes;
  final int diskBudgetBytes;
  @override
  bool get supportsLargeRegions => native.PicakeepImageEngine.isAvailable;

  @override
  Future<ImageDerivativeProbe> probe(String path) async {
    final metadata = await const native.PicakeepImageEngine().probe(path);
    return ImageDerivativeProbe(
        width: metadata.width,
        height: metadata.height,
        animated: metadata.animated,
        bitDepth: metadata.bitDepth,
        colorSpace:
            metadata.hasColorProfile ? 'profile-normalized-sRGB' : 'sRGB',
        estimatedWorkingBytes:
            math.max(64 * 1024 * 1024, metadata.estimatedWorkingBytes),
        tilesAvailable: !metadata.animated && metadata.bitDepth <= 8);
  }

  @override
  Future<ImageDerivativeRaster> render(
    String path, {
    required ImageDerivativeRect region,
    required int width,
    required int height,
    required String format,
    required String backingPath,
    required bool Function() isCancelled,
    int? jobBudgetBytes,
  }) async {
    if (isCancelled()) throw StateError('Derivative cancelled');
    final effectiveBudget =
        math.min(memoryBudgetBytes, jobBudgetBytes ?? memoryBudgetBytes);
    if (effectiveBudget <= 0) {
      throw ArgumentError.value(jobBudgetBytes, 'jobBudgetBytes');
    }
    final token = native.NativeCancellationToken();
    final cancellationWatch =
        Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (isCancelled()) token.cancel();
    });
    native.NativePixelBuffer? pixels;
    native.NativeEncodedImage? encoded;
    try {
      final box = native.NativeImageRect(
          region.x, region.y, region.width, region.height);
      pixels = await withNativeDiskWork<native.NativePixelBuffer>(
          File(path), backingPath,
          region: box,
          outputWidth: width,
          outputHeight: height,
          run: (diskBudget) => const native.PicakeepImageEngine().decodeRegion(
              path, box,
              backingPath: backingPath,
              outputWidth: width,
              outputHeight: height,
              memoryBudgetBytes: effectiveBudget,
              diskBudgetBytes: math.min(diskBudgetBytes, diskBudget),
              cancelToken: token));
      if (isCancelled()) throw StateError('Derivative cancelled');
      var hasAlpha = false;
      if (format == 'jpeg') {
        for (var offset = 3; offset < pixels.bytes.length; offset += 4) {
          if (pixels.bytes[offset] != 255) {
            hasAlpha = true;
            break;
          }
        }
      }
      final encoding = switch (format) {
        'jpeg' when !hasAlpha => native.NativeImageEncoding.jpeg,
        'webp' => native.NativeImageEncoding.webp,
        _ => native.NativeImageEncoding.png,
      };
      encoded = await const native.PicakeepImageEngine().encodePixels(
          pixels.bytes,
          width: width,
          height: height,
          stride: pixels.stride,
          format: encoding,
          quality: 85,
          lossless: encoding != native.NativeImageEncoding.jpeg,
          memoryBudgetBytes: math.min(effectiveBudget, 128 * 1024 * 1024),
          maxOutputBytes:
              math.min(32 * 1024 * 1024, math.max(65536, width * height * 8)),
          cancelToken: token);
      if (isCancelled()) throw StateError('Derivative cancelled');
      return ImageDerivativeRaster(
          bytes: encoded.bytes,
          width: width,
          height: height,
          mimeType: switch (encoding) {
            native.NativeImageEncoding.jpeg => 'image/jpeg',
            native.NativeImageEncoding.webp => 'image/webp',
            _ => 'image/png',
          },
          lossless: encoding != native.NativeImageEncoding.jpeg);
    } finally {
      cancellationWatch.cancel();
      pixels?.dispose();
      encoded?.dispose();
      token.dispose();
    }
  }
}

/// Compatibility backend for small images. It never full-decodes giant sources.
class BoundedDartImageDerivativeRenderer implements ImageDerivativeRenderer {
  const BoundedDartImageDerivativeRenderer(
      {this.maximumSourcePixels = 4 * 1024 * 1024,
      this.maximumSourceBytes = 16 * 1024 * 1024});
  final int maximumSourcePixels, maximumSourceBytes;
  @override
  bool get supportsLargeRegions => false;

  Future<Uint8List> _readBounded(String path) async {
    final file = File(path);
    if (await file.length() > maximumSourceBytes) {
      throw StateError('Image source exceeds compatibility budget');
    }
    return file.readAsBytes();
  }

  @override
  Future<ImageDerivativeProbe> probe(String path) async {
    final transfer = TransferableTypedData.fromList([await _readBounded(path)]);
    final maximum = maximumSourcePixels;
    return Isolate.run(() {
      final bytes = transfer.materialize().asUint8List();
      final decoder = img.findDecoderForData(bytes);
      final info = decoder?.startDecode(bytes);
      if (info == null ||
          info.width <= 0 ||
          info.height <= 0 ||
          info.width * info.height > maximum) {
        throw StateError('Image exceeds compatibility pixel budget');
      }
      final image = decoder!.decodeFrame(0);
      if (image == null) throw const FormatException('Invalid image');
      final normalized = img.bakeOrientation(image);
      return ImageDerivativeProbe(
          width: normalized.width,
          height: normalized.height,
          animated: info.numFrames > 1,
          bitDepth: image.bitsPerChannel,
          tilesAvailable: info.numFrames == 1 && image.bitsPerChannel <= 8);
    });
  }

  @override
  Future<ImageDerivativeRaster> render(
    String path, {
    required ImageDerivativeRect region,
    required int width,
    required int height,
    required String format,
    required String backingPath,
    required bool Function() isCancelled,
    int? jobBudgetBytes,
  }) async {
    if (isCancelled()) throw StateError('Derivative cancelled');
    final transfer = TransferableTypedData.fromList([await _readBounded(path)]);
    final maximum = maximumSourcePixels;
    final result = await Isolate.run(() {
      final bytes = transfer.materialize().asUint8List();
      final decoder = img.findDecoderForData(bytes);
      final info = decoder?.startDecode(bytes);
      if (info == null || info.width * info.height > maximum) {
        throw StateError('Image exceeds compatibility pixel budget');
      }
      final decoded = decoder!.decodeFrame(0);
      if (decoded == null || info.numFrames > 1 || decoded.bitsPerChannel > 8) {
        throw StateError('Image requires original-format rendering');
      }
      final original = img.bakeOrientation(decoded);
      if (region.x < 0 ||
          region.y < 0 ||
          region.width <= 0 ||
          region.height <= 0 ||
          region.x + region.width > original.width ||
          region.y + region.height > original.height) {
        throw RangeError('Invalid derivative region');
      }
      var image = img.copyCrop(original,
          x: region.x, y: region.y, width: region.width, height: region.height);
      if (image.width != width || image.height != height) {
        image = img.copyResize(image,
            width: width,
            height: height,
            interpolation: img.Interpolation.average);
      }
      return TransferableTypedData.fromList([
        format == 'jpeg'
            ? img.encodeJpg(image, quality: 85)
            : img.encodePng(image, level: 3)
      ]);
    });
    if (isCancelled()) throw StateError('Derivative cancelled');
    return ImageDerivativeRaster(
        bytes: result.materialize().asUint8List(),
        width: width,
        height: height,
        mimeType: format == 'jpeg' ? 'image/jpeg' : 'image/png',
        lossless: format != 'jpeg');
  }
}

(int, int) imageDerivativeCoverSize(
    int sourceWidth, int sourceHeight, int width) {
  final scale = math.min(
      1.0,
      math.min(
          width / sourceWidth,
          math.min(4096 / math.max(sourceWidth, sourceHeight),
              math.sqrt(4 * 1024 * 1024 / (sourceWidth * sourceHeight)))));
  return (
    math.max(1, (sourceWidth * scale).round()),
    math.max(1, (sourceHeight * scale).round())
  );
}
