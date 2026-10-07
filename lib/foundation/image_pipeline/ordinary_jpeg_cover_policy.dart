import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

/// A cover-only JPEG codec choice. It never changes original-pixel reading.
class OrdinaryJpegCoverPlan {
  const OrdinaryJpegCoverPlan._(this.estimatedWorkingBytes);

  static const maximumHeaderBytes = 256 << 10;
  static const maximumEncodedBytes = 32 << 20;
  static const maximumSourceRgbaBytes = 256 << 20;
  static const maximumSourceEdge = 16384;
  static const maximumOutputEdge = 4096;
  static const maximumOutputPixels = 4 * 1024 * 1024;
  @visibleForTesting
  static int? availableMemoryForTesting;
  static int get availableMemoryBytes =>
      availableMemoryForTesting ?? PicakeepImageEngine.availableMemoryBytes;

  /// Charge two full source bitmaps even though JPEG normally decodes close to
  /// the target size. This covers an engine fallback plus scaled CPU/GPU output,
  /// mipmaps and encoded copies rather than assuming scaled IDCT always wins.
  final int estimatedWorkingBytes;

  bool fitsAvailableMemory(int availableBytes) {
    if (availableBytes <= 0) return false;
    final reserve = (256 << 20) + availableBytes ~/ 4;
    return availableBytes > reserve &&
        estimatedWorkingBytes <= availableBytes - reserve;
  }

  static Future<OrdinaryJpegCoverPlan?> inspect(
    File source, {
    required FileStat snapshot,
    required ImageMetadata metadata,
    required int outputWidth,
    required int outputHeight,
    required bool Function() canContinue,
  }) async {
    if (!_eligibleDimensions(snapshot, metadata, outputWidth, outputHeight) ||
        !canContinue()) {
      return null;
    }
    final handle = await source.open();
    try {
      if (!canContinue()) return null;
      final header = await handle.read(maximumHeaderBytes);
      if (!canContinue() ||
          !hasOrdinaryBaselineHeader(header,
              expectedWidth: metadata.encodedWidth,
              expectedHeight: metadata.encodedHeight)) {
        return null;
      }
      final current = await source.stat();
      if (!canContinue() ||
          current.type != FileSystemEntityType.file ||
          current.size != snapshot.size ||
          current.modified != snapshot.modified) {
        return null;
      }
      return OrdinaryJpegCoverPlan._((64 << 20) +
          metadata.width * metadata.height * 8 +
          snapshot.size * 2 +
          outputWidth * outputHeight * 16);
    } finally {
      await handle.close();
    }
  }

  static bool _eligibleDimensions(FileStat snapshot, ImageMetadata metadata,
      int outputWidth, int outputHeight) {
    final sourceRgba = metadata.width * metadata.height * 4;
    return snapshot.type == FileSystemEntityType.file &&
        snapshot.size > 0 &&
        snapshot.size <= maximumEncodedBytes &&
        metadata.format == 'jpeg' &&
        !metadata.animated &&
        metadata.bitDepth == 8 &&
        !metadata.hasColorProfile &&
        metadata.orientation == 1 &&
        metadata.width == metadata.encodedWidth &&
        metadata.height == metadata.encodedHeight &&
        metadata.width > 0 &&
        metadata.height > 0 &&
        metadata.width <= maximumSourceEdge &&
        metadata.height <= maximumSourceEdge &&
        sourceRgba > (64 << 20) &&
        sourceRgba <= maximumSourceRgbaBytes &&
        outputWidth > 0 &&
        outputHeight > 0 &&
        outputWidth < metadata.width &&
        outputHeight < metadata.height &&
        outputWidth <= maximumOutputEdge &&
        outputHeight <= maximumOutputEdge &&
        outputWidth * outputHeight <= maximumOutputPixels;
  }

  /// Recognizes a complete first-scan header, never an extension or SOF alone.
  /// Unsupported, truncated or unusually large headers keep the native route.
  static bool hasOrdinaryBaselineHeader(Uint8List bytes,
      {required int expectedWidth, required int expectedHeight}) {
    if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return false;
    var offset = 2;
    List<int>? components;
    int? adobeTransform;
    while (offset < bytes.length && offset < maximumHeaderBytes) {
      if (bytes[offset++] != 0xff) return false;
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) return false;
      final marker = bytes[offset++];
      if (marker == 0 ||
          marker == 0xd8 ||
          marker == 0xd9 ||
          marker == 0x01 ||
          marker >= 0xd0 && marker <= 0xd7) {
        return false;
      }
      if (offset + 2 > bytes.length) return false;
      final length = bytes[offset] * 256 + bytes[offset + 1];
      if (length < 2 || offset + length > bytes.length) return false;
      final start = offset + 2;
      final end = offset + length;
      if (end > maximumHeaderBytes) return false;

      if (marker == 0xe2 &&
          _startsWith(bytes, start, end, const [
            0x49,
            0x43,
            0x43,
            0x5f,
            0x50,
            0x52,
            0x4f,
            0x46,
            0x49,
            0x4c,
            0x45,
            0x00
          ])) {
        return false;
      }
      if (marker == 0xee &&
          _startsWith(
              bytes, start, end, const [0x41, 0x64, 0x6f, 0x62, 0x65])) {
        if (end - start < 12) return false;
        adobeTransform = bytes[start + 11];
        if (adobeTransform > 1) return false;
      }
      if (marker >= 0xc0 &&
          marker <= 0xcf &&
          marker != 0xc4 &&
          marker != 0xc8 &&
          marker != 0xcc) {
        if (marker != 0xc0 || components != null || end - start < 6) {
          return false;
        }
        final count = bytes[start + 5];
        if (bytes[start] != 8 ||
            bytes[start + 1] * 256 + bytes[start + 2] != expectedHeight ||
            bytes[start + 3] * 256 + bytes[start + 4] != expectedWidth ||
            count != 1 && count != 3 ||
            length != 8 + count * 3) {
          return false;
        }
        components = [];
        for (var index = 0; index < count; index++) {
          final component = start + 6 + index * 3;
          final id = bytes[component];
          final sampling = bytes[component + 1];
          final h = sampling >> 4, v = sampling & 15;
          if (components.contains(id) ||
              h < 1 ||
              h > 4 ||
              v < 1 ||
              v > 4 ||
              bytes[component + 2] > 3) {
            return false;
          }
          components.add(id);
        }
      }
      // Arithmetic/differential coding and DNL cannot enter the ordinary path.
      if (marker == 0xc8 || marker == 0xcc || marker == 0xdc) return false;
      if (marker == 0xda) {
        if (components == null || end - start < 4) return false;
        final count = bytes[start];
        if (count != components.length ||
            length != 6 + count * 2 ||
            adobeTransform == 1 && components.length != 3) {
          return false;
        }
        final scanIds = <int>{};
        for (var index = 0; index < count; index++) {
          final component = start + 1 + index * 2;
          final id = bytes[component];
          final tables = bytes[component + 1];
          if (!components.contains(id) ||
              !scanIds.add(id) ||
              tables >> 4 > 3 ||
              (tables & 15) > 3) {
            return false;
          }
        }
        return bytes[end - 3] == 0 &&
            bytes[end - 2] == 63 &&
            bytes[end - 1] == 0;
      }
      offset = end;
    }
    return false;
  }

  static bool _startsWith(
      Uint8List bytes, int start, int end, List<int> signature) {
    if (end - start < signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[start + index] != signature[index]) return false;
    }
    return true;
  }
}
