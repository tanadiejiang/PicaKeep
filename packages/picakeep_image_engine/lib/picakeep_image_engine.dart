import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

part 'src/bindings.dart';
part 'src/worker_pool.dart';

/// Coordinates always refer to the orientation-normalized original image.
class NativeImageRect {
  const NativeImageRect(this.x, this.y, this.width, this.height);
  final int x;
  final int y;
  final int width;
  final int height;
}

class ImageMetadata {
  const ImageMetadata({
    required this.width,
    required this.height,
    required this.encodedWidth,
    required this.encodedHeight,
    required this.format,
    required this.orientation,
    required this.animated,
    required this.bitDepth,
    required this.hasColorProfile,
    required this.estimatedWorkingBytes,
  });
  final int width;
  final int height;
  final int encodedWidth;
  final int encodedHeight;
  final String format;
  final int orientation;
  final bool animated;
  final int bitDepth;
  final bool hasColorProfile;
  final int estimatedWorkingBytes;
  int get displayWidth => width;
  int get displayHeight => height;
}

class NativePixelBuffer {
  NativePixelBuffer({
    required Uint8List bytes,
    required this.width,
    required this.height,
    required this.stride,
    required this.actualSourceRect,
    required this.workingPeakBytes,
    required this.diskBytes,
    required this.elapsedMicroseconds,
    required this.backend,
    required this.colorSpace,
    this.premultipliedAlpha = false,
    this.workerQueueMicroseconds = 0,
    this.workerStartupMicroseconds = 0,
    this.workerExecutionMicroseconds = 0,
    this.workerTransportMicroseconds = 0,
    this.workerId = 0,
  }) : _bytes = bytes;
  Uint8List? _bytes;
  Uint8List get bytes => _bytes ?? (throw StateError('Pixel buffer disposed'));
  final int width;
  final int height;
  final int stride;
  final NativeImageRect actualSourceRect;
  final int workingPeakBytes;
  final int diskBytes;
  final int elapsedMicroseconds;
  final String backend;
  final String colorSpace;
  String get pixelFormat => 'rgba8888';
  final bool premultipliedAlpha;

  /// Queue includes startup when a fresh worker is needed. Execution includes
  /// codec, alpha conversion and TTD construction; transport excludes both.
  final int workerQueueMicroseconds;
  final int workerStartupMicroseconds;
  final int workerExecutionMicroseconds;
  final int workerTransportMicroseconds;
  final int workerId;
  void dispose() => _bytes = null;
}

class ImageEngineException implements Exception {
  const ImageEngineException(this.code, this.message);
  final int code;
  final String message;
  bool get isCancelled => code == 2;
  bool get isResourceLimited => code == 3;
  bool get isUnsupported => code == 4;
  @override
  String toString() => 'ImageEngineException($code, $message)';
}

/// Temporary Dart worker admission failure, distinct from native status 3
/// memory/disk limits. A caller may retry once queued work has drained.
class ImageEngineQueueExceeded extends ImageEngineException {
  const ImageEngineQueueExceeded(this.limit)
    : super(3, 'Native image worker queue is full');
  final int limit;
}

class NativePreparationResult {
  const NativePreparationResult({
    required this.workingPeakBytes,
    required this.diskPeakBytes,
    required this.elapsedMicroseconds,
    required this.backend,
  });
  final int workingPeakBytes;
  final int diskPeakBytes;
  final int elapsedMicroseconds;
  final String backend;
}

enum NativeImageEncoding { jpeg, png, webp }

class NativeEncodedImage {
  NativeEncodedImage({
    required Uint8List bytes,
    required this.format,
    required this.workingPeakBytes,
    required this.elapsedMicroseconds,
  }) : _bytes = bytes;
  Uint8List? _bytes;
  Uint8List get bytes =>
      _bytes ?? (throw StateError('Encoded buffer disposed'));
  final NativeImageEncoding format;
  final int workingPeakBytes;
  final int elapsedMicroseconds;
  void dispose() => _bytes = null;
}

/// Cancellation is shared with the native worker. Disposal cancels outstanding
/// work and defers freeing the native token until every worker has returned.
class NativeCancellationToken {
  NativeCancellationToken()
    : _address = _Bindings.instance.tokenCreate().address {
    if (_address == 0) {
      throw const ImageEngineException(3, 'Cannot allocate cancellation token');
    }
  }
  final int _address;
  bool _disposed = false;
  int _active = 0;
  void cancel() {
    if (!_disposed) {
      _Bindings.instance.tokenCancel(Pointer<Void>.fromAddress(_address));
      _ImageWorkerPool.instance.cancelQueued(_address);
    }
  }

  void dispose() {
    if (!_disposed) {
      cancel();
      _disposed = true;
      if (_active == 0) _destroy();
    }
  }

  void _retain() {
    if (_disposed) throw StateError('Cancellation token disposed');
    _active++;
  }

  void _release() {
    _active--;
    if (_active == 0 && _disposed) _destroy();
  }

  void _destroy() =>
      _Bindings.instance.tokenDestroy(Pointer<Void>.fromAddress(_address));
}

/// All codec work runs outside the UI isolate. The caller owns task concurrency,
/// cache leases, GPU/upload budgets, and the writable per-resource backing path.
class PicakeepImageEngine {
  const PicakeepImageEngine();
  static bool get isSupported => Platform.isAndroid || Platform.isWindows;
  static bool get isAvailable {
    if (!isSupported) return false;
    try {
      _Bindings.instance;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<ImageMetadata> probe(String path) async =>
      (await _ImageWorkerPool.instance.run(_WorkerOperation.probe, [
            path,
          ])).value
          as ImageMetadata;
  static Map<String, int> get workerDiagnostics =>
      _ImageWorkerPool.instance.diagnostics;

  /// Releases only idle workers. Active native calls finish normally, retaining
  /// their cancellation handle and the caller's source/budget leases.
  static Future<void> shutdownIdleWorkers() =>
      _ImageWorkerPool.instance.shutdownIdle();
  static int get availableMemoryBytes =>
      isAvailable ? _Bindings.instance.availableMemory() : 0;

  /// Reads OS space available to this caller on the actual target volume.
  /// A missing output path uses its nearest existing ancestor. No directory or
  /// data is created. Query failure is explicit, never treated as unlimited.
  Future<({int availableBytes, String volumeId})> availableDiskSpace(
    String path,
  ) async {
    if (!isSupported) {
      throw const ImageEngineException(4, 'Disk query platform is unsupported');
    }
    if (path.isEmpty || path.contains('\u0000')) {
      throw const ImageEngineException(1, 'Invalid disk query path');
    }
    return Isolate.run(() => _queryDiskSpace(path));
  }

  Future<int> availableDiskBytes(String path) async =>
      (await availableDiskSpace(path)).availableBytes;

  Future<int> estimateWorkingBytes(
    String path, {
    required String backingPath,
    required int outputWidth,
    required int outputHeight,
  }) async =>
      (await _ImageWorkerPool.instance.run(_WorkerOperation.estimate, [
            path,
            backingPath,
            outputWidth,
            outputHeight,
          ])).value
          as int;

  /// Prepare a reusable exact original-pixel disk layer in the caller's idle
  /// queue. This never returns a display image or modifies the original.
  Future<NativePreparationResult> prepareBacking(
    String path, {
    required String backingPath,
    int memoryBudgetBytes = 384 * 1024 * 1024,
    int diskBudgetBytes = 1024 * 1024 * 1024,
    NativeCancellationToken? cancelToken,
  }) async {
    final metadata = await probe(path);
    final result = await decodeRegion(
      path,
      NativeImageRect(0, 0, metadata.width, metadata.height),
      backingPath: backingPath,
      outputWidth: 1,
      outputHeight: 1,
      memoryBudgetBytes: memoryBudgetBytes,
      diskBudgetBytes: diskBudgetBytes,
      cancelToken: cancelToken,
    );
    try {
      return NativePreparationResult(
        workingPeakBytes: result.workingPeakBytes,
        diskPeakBytes: result.diskBytes,
        elapsedMicroseconds: result.elapsedMicroseconds,
        backend: result.backend,
      );
    } finally {
      result.dispose();
    }
  }

  Future<NativeEncodedImage> encodePixels(
    Uint8List rgba, {
    required int width,
    required int height,
    int? stride,
    required NativeImageEncoding format,
    int quality = 85,
    bool lossless = false,
    int memoryBudgetBytes = 128 * 1024 * 1024,
    int maxOutputBytes = 32 * 1024 * 1024,
    NativeCancellationToken? cancelToken,
  }) async {
    if (width <= 0 ||
        height <= 0 ||
        quality < 0 ||
        quality > 100 ||
        width > 16383 ||
        height > 16383 ||
        (stride ?? width * 4) < width * 4 ||
        rgba.length < (stride ?? width * 4) * height) {
      throw ArgumentError('Invalid RGBA pixels or encoder options');
    }
    if (rgba.length > memoryBudgetBytes || maxOutputBytes <= 0) {
      throw const ImageEngineException(
        3,
        'Encoder input exceeds memory budget',
      );
    }
    cancelToken?._retain();
    final tokenAddress = cancelToken?._address ?? 0;
    try {
      final data = TransferableTypedData.fromList([rgba]);
      final encoded = await Isolate.run(
        () => _encodePixels(
          data,
          width,
          height,
          stride ?? width * 4,
          format,
          quality,
          lossless,
          memoryBudgetBytes,
          maxOutputBytes,
          tokenAddress,
        ),
      );
      return NativeEncodedImage(
        bytes: encoded.$1.materialize().asUint8List(),
        format: format,
        workingPeakBytes: encoded.$2,
        elapsedMicroseconds: encoded.$3,
      );
    } finally {
      cancelToken?._release();
    }
  }

  /// [preparedOnly] validates and reads an existing original-pixel backing,
  /// never creating or replacing one. A missing/stale backing returns native
  /// error 5; an older library reports 4. The caller retains its source/backing
  /// leases and memory admission until completion, including cancellation.
  /// Disk bytes then report existing occupancy, not newly reserved storage.
  Future<NativePixelBuffer> decodeRegion(
    String path,
    NativeImageRect sourceRect, {
    required String backingPath,
    int? outputWidth,
    int? outputHeight,
    int memoryBudgetBytes = 384 * 1024 * 1024,
    int diskBudgetBytes = 1024 * 1024 * 1024,
    bool premultiplyAlpha = false,
    NativeCancellationToken? cancelToken,
    bool preparedOnly = false,
  }) async {
    if (sourceRect.x < 0 ||
        sourceRect.y < 0 ||
        sourceRect.width <= 0 ||
        sourceRect.height <= 0 ||
        (outputWidth != null && outputWidth <= 0) ||
        (outputHeight != null && outputHeight <= 0)) {
      throw ArgumentError(
        'Image region and output dimensions must be positive',
      );
    }
    if (preparedOnly && (memoryBudgetBytes < 0 || diskBudgetBytes < 0)) {
      throw ArgumentError('Prepared read budgets must not be negative');
    }
    if (preparedOnly && _Bindings.instance.decodePrepared == null) {
      throw const ImageEngineException(
        4,
        'Prepared backing reads are unavailable',
      );
    }
    cancelToken?._retain();
    final address = cancelToken?._address ?? 0;
    try {
      final response = await _ImageWorkerPool.instance.run(
        preparedOnly
            ? _WorkerOperation.decodePrepared
            : _WorkerOperation.decode,
        [
          path,
          sourceRect,
          backingPath,
          outputWidth ?? sourceRect.width,
          outputHeight ?? sourceRect.height,
          memoryBudgetBytes,
          preparedOnly ? 0 : diskBudgetBytes,
          address,
          premultiplyAlpha,
        ],
        tokenAddress: address,
      );
      final result = response.value as _WorkerPixels;
      return NativePixelBuffer(
        bytes: result.pixels.materialize().asUint8List(),
        width: result.width,
        height: result.height,
        stride: result.stride,
        actualSourceRect: sourceRect,
        workingPeakBytes: result.peak,
        diskBytes: result.disk,
        elapsedMicroseconds: result.elapsed,
        backend: result.backend,
        colorSpace: 'sRGB',
        premultipliedAlpha: premultiplyAlpha,
        workerQueueMicroseconds: response.queueMicroseconds,
        workerStartupMicroseconds: response.startupMicroseconds,
        workerExecutionMicroseconds: response.executionMicroseconds,
        workerTransportMicroseconds: response.transportMicroseconds,
        workerId: response.workerId,
      );
    } finally {
      cancelToken?._release();
    }
  }

  static bool get preparedReadsAvailable =>
      isAvailable && _Bindings.instance.decodePrepared != null;
}

({int availableBytes, String volumeId}) _queryDiskSpace(String path) {
  if (!PicakeepImageEngine.isAvailable) {
    throw const ImageEngineException(4, 'Native disk query is unavailable');
  }
  final nativePath = path.toNativeUtf8();
  final available = calloc<Uint64>();
  final volume = calloc<Uint8>(256);
  final error = calloc<Uint8>(512);
  try {
    final query = _Bindings.instance.diskSpace;
    if (query == null) {
      throw const ImageEngineException(4, 'Native disk query is unavailable');
    }
    final status = query(nativePath, available, volume, 256, error, 512);
    if (status != 0) {
      throw ImageEngineException(status, error.cast<Utf8>().toDartString());
    }
    final identity = volume.cast<Utf8>().toDartString();
    if (identity.isEmpty || available.value < 0) {
      throw const ImageEngineException(
        1,
        'Native disk query returned invalid data',
      );
    }
    return (availableBytes: available.value, volumeId: identity);
  } finally {
    calloc.free(nativePath);
    calloc.free(available);
    calloc.free(volume);
    calloc.free(error);
  }
}

(TransferableTypedData, int, int) _encodePixels(
  TransferableTypedData data,
  int width,
  int height,
  int stride,
  NativeImageEncoding format,
  int quality,
  bool lossless,
  int memoryBudget,
  int maxOutput,
  int tokenAddress,
) {
  final input = data.materialize().asUint8List();
  final nativePixels = calloc<Uint8>(input.length);
  final request = calloc<_NativeEncodeRequest>();
  final output = calloc<_NativeEncodedResult>();
  final error = calloc<Uint8>(512);
  try {
    nativePixels.asTypedList(input.length).setAll(0, input);
    request.ref
      ..width = width
      ..height = height
      ..stride = stride
      ..format = format.index + 1
      ..quality = quality
      ..lossless = lossless ? 1 : 0
      ..inputBytes = input.length
      ..memoryBudget = memoryBudget
      ..outputLimit = maxOutput
      ..cancelToken = Pointer<Void>.fromAddress(tokenAddress);
    final status = _Bindings.instance.encode(
      nativePixels,
      request,
      output,
      error,
      512,
    );
    if (status != 0) {
      throw ImageEngineException(status, error.cast<Utf8>().toDartString());
    }
    return (
      TransferableTypedData.fromList([
        output.ref.bytes.asTypedList(output.ref.byteLength),
      ]),
      output.ref.workingPeak,
      output.ref.elapsedMicros,
    );
  } finally {
    _Bindings.instance.encodedRelease(output);
    calloc.free(nativePixels);
    calloc.free(request);
    calloc.free(output);
    calloc.free(error);
  }
}

ImageMetadata _probe(String path) {
  final nativePath = path.toNativeUtf8();
  final meta = calloc<_NativeMetadata>();
  final error = calloc<Uint8>(512);
  try {
    final status = _Bindings.instance.probe(nativePath, meta, error, 512);
    if (status != 0) {
      throw ImageEngineException(status, error.cast<Utf8>().toDartString());
    }
    return ImageMetadata(
      width: meta.ref.width,
      height: meta.ref.height,
      encodedWidth: meta.ref.encodedWidth,
      encodedHeight: meta.ref.encodedHeight,
      format: _format(meta.ref.format),
      orientation: meta.ref.orientation,
      animated: meta.ref.animated != 0,
      bitDepth: meta.ref.bitDepth,
      hasColorProfile: meta.ref.hasProfile != 0,
      estimatedWorkingBytes: meta.ref.estimatedWorkingBytes,
    );
  } finally {
    calloc.free(nativePath);
    calloc.free(meta);
    calloc.free(error);
  }
}

String _format(int format) => switch (format) {
  1 => 'jpeg',
  2 => 'png',
  3 => 'webp',
  _ => 'unknown',
};

class _WorkerPixels {
  const _WorkerPixels(
    this.pixels,
    this.width,
    this.height,
    this.stride,
    this.peak,
    this.disk,
    this.elapsed,
    this.backend,
  );
  final TransferableTypedData pixels;
  final int width, height, stride, peak, disk, elapsed;
  final String backend;
}

_WorkerPixels _decode(
  String path,
  NativeImageRect rect,
  String backingPath,
  int width,
  int height,
  int memoryBudget,
  int diskBudget,
  int tokenAddress,
  bool premultiplyAlpha, {
  bool preparedOnly = false,
}) {
  final nativePath = path.toNativeUtf8();
  final nativeBacking = backingPath.toNativeUtf8();
  final request = calloc<_NativeRequest>();
  final output = calloc<_NativeResult>();
  final error = calloc<Uint8>(512);
  try {
    request.ref
      ..x = rect.x
      ..y = rect.y
      ..width = rect.width
      ..height = rect.height
      ..outputWidth = width
      ..outputHeight = height
      ..memoryBudget = memoryBudget
      ..diskBudget = diskBudget
      ..cancelToken = Pointer<Void>.fromAddress(tokenAddress);
    final decode = preparedOnly
        ? _Bindings.instance.decodePrepared!
        : _Bindings.instance.decode;
    final status = decode(
      nativePath,
      nativeBacking,
      request,
      output,
      error,
      512,
    );
    if (status != 0) {
      throw ImageEngineException(status, error.cast<Utf8>().toDartString());
    }
    final value = output.ref;
    final pixels = value.pixels.asTypedList(value.byteLength);
    if (premultiplyAlpha) {
      // Transform the existing native view in this worker before transferring
      // it. The default retains straight-alpha RGB, including hidden RGB.
      for (var y = 0; y < value.height; y++) {
        final row = y * value.stride;
        for (var x = 0; x < value.width; x++) {
          final i = row + x * 4;
          final alpha = pixels[i + 3];
          if (alpha == 255) continue;
          pixels[i] = (pixels[i] * alpha + 127) ~/ 255;
          pixels[i + 1] = (pixels[i + 1] * alpha + 127) ~/ 255;
          pixels[i + 2] = (pixels[i + 2] * alpha + 127) ~/ 255;
        }
      }
    }
    return _WorkerPixels(
      TransferableTypedData.fromList([pixels]),
      value.width,
      value.height,
      value.stride,
      value.workingPeak,
      value.diskBytes,
      value.elapsedMicros,
      value.backend.cast<Utf8>().toDartString(),
    );
  } finally {
    _Bindings.instance.release(output);
    calloc.free(nativePath);
    calloc.free(nativeBacking);
    calloc.free(request);
    calloc.free(output);
    calloc.free(error);
  }
}
