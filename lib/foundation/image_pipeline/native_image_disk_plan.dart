import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:picakeep_image_engine/picakeep_image_engine.dart';

/// Disk workspace upper bound for the actual codec, not a fixed 1GiB claim.
/// A prior backing is conservatively retained alongside a possible replacement.
/// Native still validates its exact source stamp under its own backing lock.
class NativeImageDiskPlan {
  const NativeImageDiskPlan(
      this.finalBackingBytes, this.additionalBytes, this.nativeDiskBudgetBytes);
  final int finalBackingBytes, additionalBytes, nativeDiskBudgetBytes;

  static const _maximumHeaderBytes = 8 << 20;
  static const _headerBlockBytes = 64 << 10;

  // Unknown JPEG sampling may include four components and 4x4 MCU factors.
  // Align both axes before charging coefficients: thin images amplify padding.
  static int _unknownJpegCoefficients(int width, int height) =>
      ((width + 31) ~/ 32 * 32) * ((height + 31) ~/ 32 * 32) * 8;

  /// Classify one opened source for display grouping, without caching headers.
  /// False includes progressive, unknown and changed/unreadable originals;
  /// native decode retains the final codec, source and allocation checks.
  static Future<bool> isBaselineJpeg(File source,
      {required int encodedWidth,
      required int encodedHeight,
      FileStat? expectedSnapshot}) async {
    if (encodedWidth <= 0 || encodedHeight <= 0) return false;
    try {
      final before = await source.stat();
      bool same(FileStat other, FileStat reference) =>
          other.type == FileSystemEntityType.file &&
          other.size == reference.size &&
          other.modified == reference.modified &&
          other.changed == reference.changed;
      if (before.type != FileSystemEntityType.file ||
          before.size <= 0 ||
          expectedSnapshot != null && !same(expectedSnapshot, before)) {
        return false;
      }
      final handle = await source.open();
      late ({bool progressive, int coefficientBytes}) header;
      try {
        header = await _readJpegCodec(handle,
            encodedWidth: encodedWidth, encodedHeight: encodedHeight);
      } finally {
        await handle.close();
      }
      return !header.progressive && same(await source.stat(), before);
    } on FileSystemException {
      return false;
    }
  }

  @visibleForTesting
  static Future<({bool progressive, int coefficientBytes})>
      readJpegCodecForTesting(RandomAccessFile handle,
              {required int encodedWidth, required int encodedHeight}) =>
          _readJpegCodec(handle,
              encodedWidth: encodedWidth, encodedHeight: encodedHeight);

  /// Keep a single bounded header block. Most SOFs are in the first block;
  /// unusually large APP segments are skipped without reading their payload.
  /// Unknown, malformed and truncated headers reserve the conservative codec.
  static Future<({bool progressive, int coefficientBytes})> _readJpegCodec(
      RandomAccessFile handle,
      {required int encodedWidth,
      required int encodedHeight}) async {
    final unknown = (
      progressive: true,
      coefficientBytes: _unknownJpegCoefficients(encodedWidth, encodedHeight)
    );
    final reader =
        _JpegHeaderReader(handle, _headerBlockBytes, _maximumHeaderBytes);
    final signature = await reader.readAt(0, 2);
    if (signature == null || signature[0] != 0xff || signature[1] != 0xd8) {
      return unknown;
    }
    var offset = 2;
    while (offset < _maximumHeaderBytes) {
      final marker = await reader.readAt(offset, 2);
      if (marker == null || marker[0] != 0xff) return unknown;
      var kind = marker[1];
      offset += 2;
      // JPEG permits repeated 0xff fill bytes before a marker.
      while (kind == 0xff) {
        final next = await reader.readAt(offset, 1);
        if (next == null) return unknown;
        kind = next[0];
        offset++;
      }
      if (kind == 0 ||
          kind == 0x01 ||
          kind == 0xc8 ||
          kind == 0xcc ||
          kind == 0xdc ||
          kind == 0xd8 ||
          kind == 0xda ||
          kind == 0xd9 ||
          kind >= 0xd0 && kind <= 0xd7) {
        return unknown;
      }
      final encoded = await reader.readAt(offset, 2);
      if (encoded == null) return unknown;
      final length = encoded[0] * 256 + encoded[1];
      if (length < 2 || offset > _maximumHeaderBytes - length) return unknown;
      if (kind == 0xc0 || kind == 0xc2) {
        if (length < 8 || length > 1024) return unknown;
        final sof = await reader.readAt(offset + 2, length - 2);
        if (sof == null ||
            sof.length < 6 ||
            sof[5] < 1 ||
            sof[5] > 4 ||
            length != 8 + sof[5] * 3 ||
            sof[1] * 256 + sof[2] != encodedHeight ||
            sof[3] * 256 + sof[4] != encodedWidth ||
            kind == 0xc0 && sof[0] != 8) {
          return unknown;
        }
        var maximumH = 0, maximumV = 0, blocks = 0;
        final components = <int>{};
        for (var component = 0; component < sof[5]; component++) {
          final factors = sof[7 + component * 3];
          final h = factors >> 4, v = factors & 15;
          if (h < 1 ||
              h > 4 ||
              v < 1 ||
              v > 4 ||
              !components.add(sof[6 + component * 3])) {
            return unknown;
          }
          maximumH = math.max(maximumH, h);
          maximumV = math.max(maximumV, v);
          blocks += h * v;
        }
        return (
          progressive: kind == 0xc2,
          coefficientBytes:
              ((encodedWidth + 8 * maximumH - 1) ~/ (8 * maximumH)) *
                  ((encodedHeight + 8 * maximumV - 1) ~/ (8 * maximumV)) *
                  blocks *
                  128
        );
      }
      // Other SOF types cannot select the baseline shortcut even if a later
      // marker happens to resemble SOF0. Keep unknown formats conservative.
      if (kind >= 0xc0 &&
          kind <= 0xcf &&
          kind != 0xc4 &&
          kind != 0xc8 &&
          kind != 0xcc) {
        return unknown;
      }
      offset += length;
    }
    return unknown;
  }

  static Future<NativeImageDiskPlan> inspect(File source,
      {required String backingPath,
      int? outputWidth,
      int? outputHeight,
      NativeImageRect? region,
      bool prepare = false}) async {
    final metadata = await const PicakeepImageEngine().probe(source.path);
    final pixels = metadata.encodedWidth * metadata.encodedHeight;
    var coefficientBytes =
        _unknownJpegCoefficients(metadata.encodedWidth, metadata.encodedHeight);
    bool progressive = metadata.format == 'jpeg', interlaced = false;
    if (metadata.format == 'jpeg' || metadata.format == 'png') {
      final handle = await source.open();
      try {
        if (metadata.format == 'png') {
          final signature = await handle.read(32);
          interlaced = signature.length < 29 || signature[28] != 0;
        } else {
          final header = await _readJpegCodec(handle,
              encodedWidth: metadata.encodedWidth,
              encodedHeight: metadata.encodedHeight);
          progressive = header.progressive;
          coefficientBytes = header.coefficientBytes;
        }
      } finally {
        await handle.close();
      }
    }
    final exists = await File(backingPath).exists();
    final box = region;
    var quick = false;
    if (!prepare &&
        !exists &&
        box != null &&
        outputWidth != null &&
        outputHeight != null) {
      final denominator = box.width ~/ outputWidth;
      final sampled = denominator == 1
          ? box.width == outputWidth && box.height == outputHeight
          : metadata.orientation == 1 &&
              denominator <= 8 &&
              denominator > 1 &&
              denominator & (denominator - 1) == 0 &&
              box.width == outputWidth * denominator &&
              box.height == outputHeight * denominator &&
              box.x % denominator == 0 &&
              box.y % denominator == 0;
      // Native's whole-image scaled IDCT includes the final partial MCU when
      // the original axes are odd. Arbitrary cropped/fractional regions still
      // need backing pixels; only exact ceil(source/d) fits take this route.
      final wholeSampled = metadata.orientation == 1 &&
          !metadata.hasColorProfile &&
          box.x == 0 &&
          box.y == 0 &&
          box.width == metadata.encodedWidth &&
          box.height == metadata.encodedHeight &&
          const [2, 4, 8].any((scale) =>
              outputWidth == (metadata.encodedWidth + scale - 1) ~/ scale &&
              outputHeight == (metadata.encodedHeight + scale - 1) ~/ scale);
      quick = metadata.format == 'jpeg' &&
          !progressive &&
          metadata.bitDepth == 8 &&
          (sampled || wholeSampled);
      quick = quick ||
          (metadata.format == 'png' &&
              !interlaced &&
              metadata.bitDepth <= 8 &&
              !metadata.hasColorProfile &&
              metadata.orientation == 1 &&
              box.x == 0 &&
              box.y == 0 &&
              box.width == metadata.width &&
              box.height == metadata.height &&
              outputWidth < box.width &&
              outputHeight < box.height &&
              outputWidth * outputHeight > 1);
    }
    if (quick) return const NativeImageDiskPlan(0, 0, 1);
    final raw = 128 + pixels * 4;
    final codec = progressive
        // libjpeg's virtual coefficient arrays are MCU padded, and the native
        // guard also reserves six coefficient bytes per source pixel.  Keep
        // both bounds: sampling-aware padding covers thin images while the
        // physical-pixel bound covers ordinary subsampled frames.
        ? math.max(pixels * 6, coefficientBytes) + 256 * 1024
        // Virtual-array file headers.
        : metadata.format == 'png' &&
                interlaced &&
                metadata.bitDepth == 16 &&
                metadata.hasColorProfile
            ? pixels * 8
            : 0;
    return NativeImageDiskPlan(raw, raw + codec, raw + codec);
  }
}

/// Small parser requests are served from one block; no whole-image staging.
/// Offsets are monotonic, so a large metadata segment needs at most one seek.
class _JpegHeaderReader {
  _JpegHeaderReader(this.handle, this.blockBytes, this.limitBytes);
  final RandomAccessFile handle;
  final int blockBytes, limitBytes;
  Uint8List _block = Uint8List(0);
  int _blockOffset = 0, _filePosition = 0;

  Future<Uint8List?> readAt(int offset, int length) async {
    if (offset < 0 || length < 0 || offset > limitBytes - length) return null;
    if (length == 0) return Uint8List(0);
    Uint8List? combined;
    var consumed = 0;
    while (consumed < length) {
      final position = offset + consumed;
      if (position < _blockOffset || position >= _blockOffset + _block.length) {
        if (_filePosition != position) {
          await handle.setPosition(position);
          _filePosition = position;
        }
        _blockOffset = position;
        _block = await handle.read(math.min(blockBytes, limitBytes - position));
        _filePosition += _block.length;
        if (_block.isEmpty) return null;
      }
      final start = position - _blockOffset;
      final available = math.min(length - consumed, _block.length - start);
      if (consumed == 0 && available == length) {
        return Uint8List.sublistView(_block, start, start + length);
      }
      combined ??= Uint8List(length);
      combined.setRange(consumed, consumed + available, _block, start);
      consumed += available;
    }
    return combined;
  }
}
