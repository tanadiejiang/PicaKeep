import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:picakeep_image_engine/picakeep_image_engine.dart';
import 'reader_viewport.dart';
import 'image_work_scheduler.dart';
import 'reader_page_source.dart';
import 'reader_raster_cache.dart';
import 'reader_raster_diagnostics.dart';
import 'native_disk_work.dart';
import 'native_image_disk_plan.dart';
import 'derived_image_store.dart';
import 'reader_raw_image_decoder.dart';
export 'reader_raster_diagnostics.dart';

/// Small static files use Flutter's codec at the demanded sample density.
/// A crop always comes from that same original; zoom requests a denser decode.
class FlutterReaderRasterBackend extends ReaderRasterBackend {
  const FlutterReaderRasterBackend(this.metadata,
      {this.persistRaster = true,
      this.preferRawSync = false,
      this.preferPreparedRead = false})
      : _maximumDecodedBytes = 64 << 20,
        _strictWholeFit = false;
  const FlutterReaderRasterBackend._boundedPngFit(this.metadata,
      {this.persistRaster = true})
      : _maximumDecodedBytes = 128 << 20,
        _strictWholeFit = true,
        preferRawSync = false,
        preferPreparedRead = false;
  final ReaderRasterMetadata metadata;
  final bool persistRaster;
  final bool preferRawSync;
  final bool preferPreparedRead;
  final int _maximumDecodedBytes;
  final bool _strictWholeFit;
  static const _pixelVersion = 'flutter-srgb-rgba8-adaptive-v4';
  NativeReaderRasterBackend get _native => NativeReaderRasterBackend(
      preferRawSync: preferRawSync,
      persistRaster: persistRaster,
      preferPreparedRead: preferPreparedRead);
  bool _flutter(ReaderTileDemand demand) =>
      _whole(demand) || metadata.hasColorProfile;
  bool _whole(ReaderTileDemand demand) => demand.column < 0 && demand.row < 0;
  @override
  bool get requiresFileBacking => false;
  @override
  bool get supportsIdlePreparation => true;
  @override
  Future<int> estimateBackingWorkingBytes(File file,
          {required String backingPath}) =>
      _native.estimateBackingWorkingBytes(file, backingPath: backingPath);
  @override
  Future<void> prepareBacking(File file,
          {required String backingPath,
          required int memoryBudgetBytes,
          required Future<void> cancelled}) =>
      _native.prepareBacking(file,
          backingPath: backingPath,
          memoryBudgetBytes: memoryBudgetBytes,
          cancelled: cancelled);
  @override
  Future<ReaderRasterMetadata> probe(File file) async => metadata;
  @override
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
          {required String backingPath}) async =>
      !_flutter(demand)
          ? await _native.estimateWorkingBytes(file, demand,
              backingPath: backingPath)
          : metadata.size.width.round() * metadata.size.height.round() * 12 +
              await file.length() * 2 +
              demand.outputWidth * demand.outputHeight * 12;
  @override
  int? preparedWorkingBytes(
          ReaderRasterMetadata metadata, ReaderTileDemand demand) =>
      _flutter(demand) ? null : _native.preparedWorkingBytes(metadata, demand);
  @override
  Future<ui.Image> decodePrepared(File file, ReaderTileDemand demand,
          {required String backingPath,
          required int memoryBudgetBytes,
          required bool Function() isCancelled,
          Future<void>? cancelled}) =>
      _native.decodePrepared(file, demand,
          backingPath: backingPath,
          memoryBudgetBytes: memoryBudgetBytes,
          isCancelled: isCancelled,
          cancelled: cancelled);
  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    if (isCancelled()) {
      throw const ImageWorkCancelled();
    }
    if (!_flutter(demand)) {
      return await _native.decode(file, demand,
          backingPath: backingPath,
          memoryBudgetBytes: memoryBudgetBytes,
          isCancelled: isCancelled,
          cancelled: cancelled);
    }
    final cacheEnabled = persistRaster && !metadata.hasColorProfile;
    ReaderRasterCacheIdentity? rasterIdentity;
    if (cacheEnabled) {
      final cached = await ReaderRasterCache.load(file, demand,
          backingPath: backingPath,
          isCancelled: isCancelled,
          pixelVersion: _pixelVersion);
      if (cached != null) {
        ReaderRasterDiagnostics.record({'diskRasterHit': 1});
        return cached;
      }
      rasterIdentity = await ReaderRasterCache.capture(file, demand,
          pixelVersion: _pixelVersion);
    }
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? whole;
    ui.Image? ownedResult;
    final clock = Stopwatch()..start();
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width != metadata.size.width ||
          descriptor.height != metadata.size.height ||
          descriptor.width * descriptor.height * 4 > _maximumDecodedBytes) {
        throw ImageWorkBudgetExceeded(
            descriptor.width * descriptor.height * 4, _maximumDecodedBytes);
      }
      if (isCancelled()) throw const ImageWorkCancelled();
      final width = (descriptor.width * demand.density).ceil();
      final height = (descriptor.height * demand.density).ceil();
      codec = await descriptor.instantiateCodec(
          targetWidth: width, targetHeight: height);
      whole = (await codec.getNextFrame()).image;
      if (isCancelled()) throw const ImageWorkCancelled();
      if (_strictWholeFit &&
          (whole.width != width ||
              whole.height != height ||
              whole.colorSpace != ui.ColorSpace.sRGB)) {
        throw StateError('Bounded PNG fit dimensions/color space changed');
      }
      ui.Image result;
      if (demand.rasterRect == ui.Offset.zero & metadata.size &&
          whole.width == demand.outputWidth &&
          whole.height == demand.outputHeight) {
        result = whole;
        whole = null;
      } else {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        final scaled = ui.Rect.fromLTWH(
            demand.rasterRect.left * whole.width / metadata.size.width,
            demand.rasterRect.top * whole.height / metadata.size.height,
            demand.rasterRect.width * whole.width / metadata.size.width,
            demand.rasterRect.height * whole.height / metadata.size.height);
        // An integer 1:1 crop copies source pixels. Android's medium sampler
        // can alter premultiplied low-alpha channels even without scaling.
        // Fractional coordinates and resized crops still need interpolation.
        final integerPixelCopy = scaled.width == demand.outputWidth &&
            scaled.height == demand.outputHeight &&
            scaled.left == scaled.left.roundToDouble() &&
            scaled.top == scaled.top.roundToDouble();
        if (integerPixelCopy) {
          // Output bounds crop an integer translation of the original image.
          // Avoid a second source-rectangle sampler for an exact pixel copy.
          canvas.drawImage(whole, -scaled.topLeft,
              ui.Paint()..filterQuality = ui.FilterQuality.none);
        } else {
          canvas.drawImageRect(
              whole,
              scaled,
              ui.Rect.fromLTWH(0, 0, demand.outputWidth.toDouble(),
                  demand.outputHeight.toDouble()),
              ui.Paint()..filterQuality = ui.FilterQuality.medium);
        }
        final picture = recorder.endRecording();
        try {
          result =
              await picture.toImage(demand.outputWidth, demand.outputHeight);
        } finally {
          picture.dispose();
        }
      }
      ownedResult = result;
      if (isCancelled()) {
        throw const ImageWorkCancelled();
      }
      ReaderRasterDiagnostics.record({
        'flutterCodecWallUs': clock.elapsedMicroseconds,
        'outputPixels': result.width * result.height
      });
      if (rasterIdentity != null) {
        ReaderRasterCache.save(file, demand, result,
            backingPath: backingPath,
            identity: rasterIdentity,
            pixelVersion: _pixelVersion);
      }
      ownedResult = null;
      return result;
    } finally {
      ownedResult?.dispose();
      whole?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}

/// Explicit profile candidate only. A budgeted small whole fit can use Flutter
/// for a bounded PNG while native pixels/ROIs always retain the native backend.
/// [textureEdgeLowerBound] must come from an actual engine endpoint probe.
class BoundedPngFitReaderRasterBackend extends ReaderRasterBackend {
  const BoundedPngFitReaderRasterBackend(this.metadata,
      {required this.textureEdgeLowerBound,
      this.persistRaster = true,
      this.nativeBackend = const NativeReaderRasterBackend()});
  final ReaderRasterMetadata metadata;
  final int textureEdgeLowerBound;
  final bool persistRaster;
  final ReaderRasterBackend nativeBackend;

  bool get sourceEligible =>
      metadata.format == 'png' &&
      !metadata.animated &&
      metadata.bitDepth == 8 &&
      !metadata.hasColorProfile &&
      metadata.size.width > 0 &&
      metadata.size.height > 0 &&
      metadata.size.width * metadata.size.height * 4 <= 128 << 20 &&
      textureEdgeLowerBound > 0 &&
      metadata.size.width <= textureEdgeLowerBound &&
      metadata.size.height <= textureEdgeLowerBound;

  bool supportsWholeFit(ReaderTileDemand demand) =>
      sourceEligible &&
      demand.density > 0 &&
      demand.density < 1 &&
      demand.column < 0 &&
      demand.row < 0 &&
      demand.rasterRect == ui.Offset.zero & metadata.size &&
      demand.outputWidth <= textureEdgeLowerBound &&
      demand.outputHeight <= textureEdgeLowerBound &&
      demand.outputWidth * demand.outputHeight * 4 <= 32 << 20;

  @override
  bool get requiresFileBacking => nativeBackend.requiresFileBacking;
  @override
  bool get supportsIdlePreparation => nativeBackend.supportsIdlePreparation;
  @override
  ImageWorkLane get executionLane => nativeBackend.executionLane;
  @override
  Future<ReaderRasterMetadata> probe(File file) async => metadata;
  @override
  Future<int> estimateBackingWorkingBytes(File file,
          {required String backingPath}) =>
      nativeBackend.estimateBackingWorkingBytes(file, backingPath: backingPath);
  @override
  Future<void> prepareBacking(File file,
          {required String backingPath,
          required int memoryBudgetBytes,
          required Future<void> cancelled}) =>
      nativeBackend.prepareBacking(file,
          backingPath: backingPath,
          memoryBudgetBytes: memoryBudgetBytes,
          cancelled: cancelled);
  @override
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
      {required String backingPath}) async {
    if (!supportsWholeFit(demand)) {
      return nativeBackend.estimateWorkingBytes(file, demand,
          backingPath: backingPath);
    }
    final length = await file.length();
    if (length > 64 << 20) {
      throw ImageWorkBudgetExceeded(length, 64 << 20);
    }
    // Full PNG bitmap/codec/texture/mips plus output and encoded handoffs;
    // the surface additionally charges its existing three output copies.
    return metadata.size.width.round() * metadata.size.height.round() * 20 +
        demand.outputWidth * demand.outputHeight * 16 +
        length * 2;
  }

  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    if (!supportsWholeFit(demand)) {
      return nativeBackend.decode(file, demand,
          backingPath: backingPath,
          memoryBudgetBytes: memoryBudgetBytes,
          isCancelled: isCancelled,
          cancelled: cancelled);
    }
    if (isCancelled()) throw const ImageWorkCancelled();
    final required =
        await estimateWorkingBytes(file, demand, backingPath: backingPath);
    if (required > memoryBudgetBytes) {
      throw ImageWorkBudgetExceeded(required, memoryBudgetBytes);
    }
    await _verifySrgbPng(file, isCancelled);
    if (isCancelled()) throw const ImageWorkCancelled();
    ReaderRasterDiagnostics.record({
      'boundedPngFit': 1,
      'textureEdgeLowerBound': textureEdgeLowerBound,
      'boundedPngWorkingBytes': required,
    });
    return FlutterReaderRasterBackend._boundedPngFit(metadata,
            persistRaster: persistRaster)
        .decode(file, demand,
            backingPath: backingPath,
            memoryBudgetBytes: memoryBudgetBytes,
            isCancelled: isCancelled,
            cancelled: cancelled);
  }

  // Native metadata flags ICC only. Other color/EXIF/animation chunks can alter
  // the engine's pixel format or coordinates, so this candidate rejects them
  // before starting its whole codec. No unbounded header aggregate is created.
  Future<void> _verifySrgbPng(File file, bool Function() isCancelled) async {
    final input = await file.open();
    try {
      final signature = await input.read(8);
      const expected = [137, 80, 78, 71, 13, 10, 26, 10];
      if (signature.length != 8 ||
          List.generate(8, (i) => signature[i] == expected[i])
              .contains(false)) {
        throw StateError('Bounded PNG fit requires an original PNG');
      }
      var scanned = 8;
      while (scanned <= 1 << 20) {
        if (isCancelled()) throw const ImageWorkCancelled();
        final header = await input.read(8);
        if (header.length != 8) throw StateError('Truncated PNG header');
        final length =
            header[0] << 24 | header[1] << 16 | header[2] << 8 | header[3];
        final type = String.fromCharCodes(header.sublist(4));
        if (type == 'IDAT') return;
        if (const ['iCCP', 'cHRM', 'cICP', 'mDCv', 'cLLi', 'eXIf', 'acTL']
            .contains(type)) {
          throw StateError('PNG color/orientation chunk excluded from fit');
        }
        if (length < 0 || scanned + length + 12 > 1 << 20) {
          throw StateError('PNG header exceeds bounded fit inspection');
        }
        if (type == 'IHDR') {
          final info = await input.read(length);
          if (length != 13 ||
              info.length != 13 ||
              info[8] != 8 ||
              info[9] != 2 && info[9] != 6) {
            throw StateError('Bounded PNG fit requires RGB/RGBA8');
          }
        } else if (type == 'gAMA') {
          final gamma = await input.read(length);
          if (length != 4 ||
              gamma.length != 4 ||
              (gamma[0] << 24 | gamma[1] << 16 | gamma[2] << 8 | gamma[3]) !=
                  45455) {
            throw StateError('Non-sRGB PNG gamma excluded from fit');
          }
        } else {
          await input.setPosition(await input.position() + length);
        }
        await input.setPosition(await input.position() + 4); // CRC
        scanned += length + 12;
      }
      throw StateError('PNG fit inspection did not reach image data');
    } finally {
      await input.close();
    }
  }
}

/// A remote page can expose verified lossless tiles while retaining a separate
/// original-file stream for exports. Its locator is never treated as a file.
abstract class RasterReaderPageSource implements ReaderPageSource {
  ReaderRasterBackend get rasterBackend;
  File get rasterLocator;
  Future<ReaderRasterMetadata> openRasterMetadata();
}

class ReaderRasterMetadata {
  const ReaderRasterMetadata(
      {required this.size,
      required this.animated,
      required this.format,
      required this.workingBytes,
      this.bitDepth = 8,
      this.hasColorProfile = false,
      this.baselineJpeg});
  final ui.Size size;
  final bool animated;
  final String format;
  final int workingBytes;
  final int bitDepth;
  final bool hasColorProfile;

  /// True only for a verified baseline JPEG header. Null means unclassified;
  /// progressive/unknown JPEGs must not opt into larger fit decode groups.
  final bool? baselineJpeg;
}

abstract class ReaderRasterBackend {
  const ReaderRasterBackend();
  ImageWorkLane get executionLane => ImageWorkLane.execution;
  bool get requiresFileBacking => true;
  bool get supportsIdlePreparation => false;
  Future<int> estimateBackingWorkingBytes(File file,
          {required String backingPath}) async =>
      (await probe(file)).workingBytes;
  Future<void> prepareBacking(File file,
      {required String backingPath,
      required int memoryBudgetBytes,
      required Future<void> cancelled}) async {}
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
          {required String backingPath}) async =>
      (await probe(file)).workingBytes;
  Future<ReaderRasterMetadata> probe(File file);

  /// The Surface may use this bound only with verified metadata from its
  /// leased, resolved original. A non-null bound permits a read-only attempt,
  /// never a cold decode inside that reservation.
  int? preparedWorkingBytes(
          ReaderRasterMetadata metadata, ReaderTileDemand demand) =>
      null;
  Future<ui.Image> decodePrepared(File file, ReaderTileDemand demand,
          {required String backingPath,
          required int memoryBudgetBytes,
          required bool Function() isCancelled,
          Future<void>? cancelled}) =>
      Future.error(StateError('Backend has no prepared admission path'));
  Future<ui.Image> decode(
    File file,
    ReaderTileDemand demand, {
    required String backingPath,
    required int memoryBudgetBytes,
    required bool Function() isCancelled,
    Future<void>? cancelled,
  });
}

/// The read-only reservation must finish before the Surface estimates and
/// submits a separately admitted cold job. Only native status 5 maps here.
class ReaderPreparedReadMiss implements Exception {
  const ReaderPreparedReadMiss();
}

class NativeReaderRasterBackend extends ReaderRasterBackend {
  const NativeReaderRasterBackend(
      {this.persistRaster = true,
      this.preferRawSync = false,
      this.preferPreparedRead = false});
  final bool persistRaster;
  final bool preferRawSync;
  final bool preferPreparedRead;
  static const _engine = PicakeepImageEngine();
  @override
  bool get requiresFileBacking => true;
  @override
  bool get supportsIdlePreparation => true;
  @override
  Future<int> estimateBackingWorkingBytes(File file,
      {required String backingPath}) async {
    try {
      return await _engine.estimateWorkingBytes(file.path,
          backingPath: backingPath, outputWidth: 1, outputHeight: 1);
    } on ImageEngineQueueExceeded catch (error) {
      throw ImageWorkQueueExceeded(ImageWorkLane.execution, error.limit);
    }
  }

  @override
  Future<void> prepareBacking(File file,
      {required String backingPath,
      required int memoryBudgetBytes,
      required Future<void> cancelled}) async {
    final token = NativeCancellationToken();
    var completed = false;
    unawaited(cancelled.then((_) {
      if (!completed) token.cancel();
    }));
    try {
      await withNativeDiskWork(file, backingPath,
          prepare: true,
          run: (diskBudget) => _engine.prepareBacking(file.path,
              backingPath: backingPath,
              memoryBudgetBytes: memoryBudgetBytes,
              diskBudgetBytes: diskBudget,
              cancelToken: token));
    } on ImageEngineQueueExceeded catch (error) {
      throw ImageWorkQueueExceeded(ImageWorkLane.execution, error.limit);
    } on ImageEngineException catch (error) {
      // Native cancellation (status 2) is a scheduler outcome, not a page
      // failure. Keep source, resource and format errors unchanged.
      if (error.isCancelled) throw const ImageWorkCancelled();
      rethrow;
    } finally {
      completed = true;
      token.dispose();
    }
  }

  @override
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
      {required String backingPath}) async {
    try {
      return await _engine.estimateWorkingBytes(file.path,
          backingPath: backingPath,
          outputWidth: demand.outputWidth,
          outputHeight: demand.outputHeight);
    } on ImageEngineQueueExceeded catch (error) {
      throw ImageWorkQueueExceeded(ImageWorkLane.execution, error.limit);
    }
  }

  @override
  Future<ReaderRasterMetadata> probe(File file) async {
    try {
      final snapshot = await file.stat();
      final value = await _engine.probe(file.path);
      final baselineJpeg = value.format == 'jpeg'
          ? value.bitDepth == 8 &&
              await NativeImageDiskPlan.isBaselineJpeg(file,
                  encodedWidth: value.encodedWidth,
                  encodedHeight: value.encodedHeight,
                  expectedSnapshot: snapshot)
          : null;
      return ReaderRasterMetadata(
          size: ui.Size(value.width.toDouble(), value.height.toDouble()),
          animated: value.animated,
          format: value.format,
          workingBytes: value.estimatedWorkingBytes,
          bitDepth: value.bitDepth,
          hasColorProfile: value.hasColorProfile,
          baselineJpeg: baselineJpeg);
    } on ImageEngineQueueExceeded catch (error) {
      throw ImageWorkQueueExceeded(ImageWorkLane.execution, error.limit);
    }
  }

  @override
  int? preparedWorkingBytes(
      ReaderRasterMetadata metadata, ReaderTileDemand demand) {
    if (!preferPreparedRead ||
        !PicakeepImageEngine.preparedReadsAvailable ||
        metadata.animated ||
        !metadata.size.width.isFinite ||
        !metadata.size.height.isFinite ||
        metadata.size.width <= 0 ||
        metadata.size.height <= 0 ||
        metadata.size.width != metadata.size.width.roundToDouble() ||
        metadata.size.height != metadata.size.height.roundToDouble()) {
      return null;
    }
    // Native warm admission is 32 MiB + output RGBA + encodedWidth * 32.
    // Metadata is orientation-normalized, so max(width,height) conservatively
    // covers the encoded row width for every EXIF orientation.
    final longest = metadata.size.longestSide.round();
    return (32 << 20) +
        demand.outputWidth * demand.outputHeight * 4 +
        longest * 32;
  }

  @override
  Future<ui.Image> decodePrepared(File file, ReaderTileDemand demand,
          {required String backingPath,
          required int memoryBudgetBytes,
          required bool Function() isCancelled,
          Future<void>? cancelled}) =>
      _decode(file, demand,
          backingPath: backingPath,
          memoryBudgetBytes: memoryBudgetBytes,
          isCancelled: isCancelled,
          cancelled: cancelled,
          preparedAdmission: true);

  @override
  Future<ui.Image> decode(
    File file,
    ReaderTileDemand demand, {
    required String backingPath,
    required int memoryBudgetBytes,
    required bool Function() isCancelled,
    Future<void>? cancelled,
  }) =>
      _decode(file, demand,
          backingPath: backingPath,
          memoryBudgetBytes: memoryBudgetBytes,
          isCancelled: isCancelled,
          cancelled: cancelled);

  Future<ui.Image> _decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled,
      bool preparedAdmission = false}) async {
    if (isCancelled()) throw const ImageWorkCancelled();
    ReaderRasterCacheIdentity? rasterIdentity;
    if (persistRaster) {
      final diskClock = Stopwatch()..start();
      final cached = await ReaderRasterCache.load(file, demand,
          backingPath: backingPath, isCancelled: isCancelled);
      diskClock.stop();
      if (cached != null) {
        ReaderRasterDiagnostics.record({
          'diskRasterHit': 1,
          'diskRasterLoadUs': diskClock.elapsedMicroseconds,
          'outputPixels': cached.width * cached.height,
        });
        return cached;
      }
      rasterIdentity = await ReaderRasterCache.capture(file, demand);
    }
    final nativeWall = Stopwatch()..start();
    final rect = demand.rasterRect;
    final token = NativeCancellationToken();
    var completed = false;
    if (cancelled != null) {
      unawaited(cancelled.then((_) {
        if (!completed) token.cancel();
      }));
    }
    NativePixelBuffer? pixels;
    ui.Image? ownedImage;
    void Function()? releasePreparedSource, releasePreparedBacking;
    try {
      final region = NativeImageRect(rect.left.round(), rect.top.round(),
          rect.width.round(), rect.height.round());
      NativePixelBuffer? preparedPixels;
      var preparedReadUsed = 0, preparedReadMiss = 0;
      final preparedReadAttempted = preparedAdmission ||
          preferPreparedRead && PicakeepImageEngine.preparedReadsAvailable;
      if (preparedReadAttempted) {
        releasePreparedSource = ReaderPageFileLease.acquire(file);
        releasePreparedBacking =
            DerivedImageStore.protectTemporaryPath(backingPath);
        try {
          preparedPixels = await _engine.decodeRegion(file.path, region,
              backingPath: backingPath,
              outputWidth: demand.outputWidth,
              outputHeight: demand.outputHeight,
              memoryBudgetBytes: memoryBudgetBytes,
              diskBudgetBytes: 0,
              premultiplyAlpha: true,
              cancelToken: token,
              preparedOnly: true);
          preparedReadUsed = 1;
        } on ImageEngineException catch (error) {
          if (error.code != 5) rethrow;
          preparedReadMiss = 1;
          if (isCancelled()) throw const ImageWorkCancelled();
          if (preparedAdmission) {
            ReaderRasterDiagnostics.record({
              'preparedReadAttempted': 1,
              'preparedReadMiss': 1,
              'preparedAdmissionMiss': 1,
              'preparedAdmissionWorkingBytes': memoryBudgetBytes,
              'nativeWorkerWallUs': nativeWall.elapsedMicroseconds,
            });
            throw const ReaderPreparedReadMiss();
          }
        }
      }
      final decodedPixels = preparedPixels ??
          await withNativeDiskWork<NativePixelBuffer>(file, backingPath,
              region: region,
              outputWidth: demand.outputWidth,
              outputHeight: demand.outputHeight,
              run: (diskBudget) => _engine.decodeRegion(file.path, region,
                  backingPath: backingPath,
                  outputWidth: demand.outputWidth,
                  outputHeight: demand.outputHeight,
                  memoryBudgetBytes: memoryBudgetBytes,
                  diskBudgetBytes: diskBudget,
                  premultiplyAlpha: true,
                  cancelToken: token));
      pixels = decodedPixels;
      nativeWall.stop();
      if (isCancelled()) throw const ImageWorkCancelled();
      // ImageDescriptor.raw expects premultiplied alpha.
      final bytes = decodedPixels.bytes;
      if (!decodedPixels.premultipliedAlpha) {
        for (var i = 0; i < bytes.length; i += 4) {
          final alpha = bytes[i + 3];
          if (alpha == 255) continue;
          bytes[i] = (bytes[i] * alpha + 127) ~/ 255;
          bytes[i + 1] = (bytes[i + 1] * alpha + 127) ~/ 255;
          bytes[i + 2] = (bytes[i + 2] * alpha + 127) ~/ 255;
        }
      }
      final created = await ReaderRawImageDecoder.shared.decode(bytes,
          width: decodedPixels.width,
          height: decodedPixels.height,
          rowBytes: decodedPixels.stride,
          isCancelled: isCancelled,
          preferSync: preferRawSync);
      final image = created.image;
      ownedImage = image;
      decodedPixels.dispose();
      ReaderRasterDiagnostics.record({
        'nativeCodecUs': decodedPixels.elapsedMicroseconds,
        'nativeWorkerWallUs': nativeWall.elapsedMicroseconds,
        'nativeWorkerQueueUs': decodedPixels.workerQueueMicroseconds,
        'nativeWorkerStartupUs': decodedPixels.workerStartupMicroseconds,
        'nativeWorkerExecutionUs': decodedPixels.workerExecutionMicroseconds,
        'nativeWorkerTransportUs': decodedPixels.workerTransportMicroseconds,
        'nativeWorkerId': decodedPixels.workerId,
        'preparedReadAttempted': preparedReadAttempted ? 1 : 0,
        'preparedReadUsed': preparedReadUsed,
        'preparedReadMiss': preparedReadMiss,
        'preparedAdmissionUsed': preparedAdmission ? 1 : 0,
        'preparedAdmissionWorkingBytes':
            preparedAdmission ? memoryBudgetBytes : 0,
        'immutableBufferUs': created.immutableBufferMicroseconds,
        'uiImageCreationUs': created.imageCreationMicroseconds,
        'rawSyncAttempted': created.syncAttempted ? 1 : 0,
        'rawSyncUsed': created.usedSync ? 1 : 0,
        'rawSyncUnsupported': created.syncUnsupported ? 1 : 0,
        'rawUploadDeferred': created.uploadDeferred ? 1 : 0,
        'outputPixels': image.width * image.height,
        'nativeWorkingPeakBytes': decodedPixels.workingPeakBytes,
      });
      if (isCancelled()) {
        throw const ImageWorkCancelled();
      }
      if (rasterIdentity != null) {
        ReaderRasterCache.save(file, demand, image,
            backingPath: backingPath, identity: rasterIdentity);
      }
      ownedImage = null;
      return image;
    } on ImageEngineQueueExceeded catch (error) {
      throw ImageWorkQueueExceeded(ImageWorkLane.execution, error.limit);
    } on ImageEngineException catch (error) {
      // Both prepared reads and cold decodes share the same native status.
      // Surface must not retain a cancelled tile in its failure set.
      if (error.isCancelled) throw const ImageWorkCancelled();
      rethrow;
    } finally {
      ownedImage?.dispose();
      completed = true;
      token.dispose();
      pixels?.dispose();
      releasePreparedSource?.call();
      releasePreparedBacking?.call();
    }
  }
}
