import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'image_work_scheduler.dart';
import 'reader_page_source.dart';
import 'reader_raster_backend.dart';
import 'reader_viewport.dart';

/// One bounded first raster, started after resolving its original metadata.
/// The scheduled job stays reserved while the image waits for its surface.
/// Cancellation drains the actual decoder before releasing the original lease.
class ReaderOriginalRasterHandoff {
  ReaderOriginalRasterHandoff.start({
    required this.file,
    required this.metadata,
    required this.fileSnapshot,
    required this.backend,
    required this.backingPath,
    required Future<void> Function() verifyOriginal,
    ImageWorkScheduler? scheduler,
  })  : _verifyOriginal = verifyOriginal,
        _scheduler = scheduler ?? ImageWorkScheduler.shared,
        demand = ReaderTileDemand(ui.Offset.zero & metadata.size, 1, -1, -1),
        _releaseOriginal = ReaderPageFileLease.acquire(file) {
    // The parent can be disposed before the child subscribes to readiness.
    unawaited(ready.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    unawaited(_start());
  }

  final File file;
  final ReaderRasterMetadata metadata;
  final FileStat fileSnapshot;
  final ReaderRasterBackend backend;
  final String backingPath;
  final ReaderTileDemand demand;
  final Future<void> Function() _verifyOriginal;
  final ImageWorkScheduler _scheduler;
  final void Function() _releaseOriginal;
  final _ready = Completer<void>();
  final _drained = Completer<void>();
  final _ownershipDecided = Completer<void>();
  final _actualRunDone = Completer<void>();
  ImageWorkTicket<void>? _ticket;
  ui.Image? _ownedImage;
  bool _cancelled = false, _transferred = false, _runStarted = false;

  Future<void> get ready => _ready.future;
  Future<void> get drained => _drained.future;
  int get outputBytes => demand.outputWidth * demand.outputHeight * 4;

  static bool isEligible(ReaderRasterMetadata metadata, FileStat snapshot,
          ReaderRasterBackend backend) =>
      backend is FlutterReaderRasterBackend &&
      snapshot.type == FileSystemEntityType.file &&
      snapshot.size > 0 &&
      snapshot.size <= 64 << 20 &&
      metadata.format == 'png' &&
      !metadata.animated &&
      metadata.bitDepth == 8 &&
      !metadata.hasColorProfile &&
      metadata.size.width.isFinite &&
      metadata.size.height.isFinite &&
      metadata.size.width > 0 &&
      metadata.size.height > 0 &&
      metadata.size.width == metadata.size.width.roundToDouble() &&
      metadata.size.height == metadata.size.height.roundToDouble() &&
      metadata.size.width * metadata.size.height * 4 <= 64 << 20;

  Future<void> _start() async {
    try {
      if (!isEligible(metadata, fileSnapshot, backend)) {
        throw ArgumentError('Original is not eligible for an early PNG raster');
      }
      final estimateClock = Stopwatch()..start();
      final working = math.max(
          2 << 20,
          await backend.estimateWorkingBytes(file, demand,
              backingPath: backingPath));
      _throwIfCancelled();
      ReaderRasterDiagnostics.record({
        'earlyOriginalRasterSubmittedUs': developer.Timeline.now,
        'earlyOriginalRasterEstimateUs': estimateClock.elapsedMicroseconds,
        'earlyOriginalRasterWorkingBytes': working + outputBytes * 3,
      });
      _ticket = _scheduler.submit<void>(
          key: 'reader-first-original:${identityHashCode(this)}',
          priority: ImageWorkPriority.visible,
          lane: backend.executionLane,
          estimatedBytes: working + outputBytes * 3,
          run: (cancel) async {
            _runStarted = true;
            unawaited(cancel.cancelled.then((_) => this.cancel()));
            ReaderRasterDiagnostics.record({
              'earlyOriginalRasterStartedUs': developer.Timeline.now,
            });
            try {
              _throwIfCancelled();
              cancel.throwIfCancelled();
              await _verifyOriginal();
              await _verifySrgbPng();
              _throwIfCancelled();
              cancel.throwIfCancelled();
              _ownedImage = await backend.decode(file, demand,
                  backingPath: backingPath,
                  memoryBudgetBytes: working,
                  cancelled: cancel.cancelled,
                  isCancelled: () => _cancelled || cancel.isCancelled);
              _throwIfCancelled();
              cancel.throwIfCancelled();
              await _verifyOriginal();
              _throwIfCancelled();
              if (_ownedImage!.width != demand.outputWidth ||
                  _ownedImage!.height != demand.outputHeight ||
                  _ownedImage!.colorSpace != ui.ColorSpace.sRGB) {
                throw StateError(
                    'Early PNG raster dimensions or colors changed');
              }
              ReaderRasterDiagnostics.record({
                'earlyOriginalRasterReadyUs': developer.Timeline.now,
                'earlyOriginalRasterOutputPixels':
                    demand.outputWidth * demand.outputHeight,
              });
              _ready.complete();
              // Keep the image's live bytes charged even if its surface has
              // not built or must wait for resident image eviction first.
              await _ownershipDecided.future;
            } finally {
              _ownedImage?.dispose();
              _ownedImage = null;
              _actualRunDone.complete();
            }
          });
      await _ticket!.future;
    } catch (error, stack) {
      if (!_ready.isCompleted) _ready.completeError(error, stack);
    } finally {
      // A ticket cancels its listener promptly, but its native codec can still
      // be running. Its source must remain alive until that run actually ends.
      if (_runStarted) await _actualRunDone.future;
      _releaseOriginal();
      _drained.complete();
    }
  }

  /// Verify again immediately before the surface transfers and charges the
  /// image. Source replacement while waiting for a consumer must be rejected.
  Future<void> verifyForTransfer() async {
    _throwIfCancelled();
    try {
      await _verifyOriginal();
      _throwIfCancelled();
    } catch (_) {
      cancel();
      rethrow;
    }
  }

  /// Transfer exactly once, synchronously with the surface's resident charge.
  /// The receiver owns disposal after this call; later parent cancellation
  /// cannot dispose that transferred image.
  ui.Image take() {
    _throwIfCancelled();
    if (_transferred || _ownedImage == null) {
      throw StateError('First original raster is not ready or was transferred');
    }
    final image = _ownedImage!;
    _ownedImage = null;
    _transferred = true;
    _ownershipDecided.complete();
    return image;
  }

  void cancel() {
    if (_cancelled || _transferred) return;
    _cancelled = true;
    if (!_ready.isCompleted) {
      _ready.completeError(const ImageWorkCancelled());
    }
    if (!_ownershipDecided.isCompleted) _ownershipDecided.complete();
    _ticket?.cancel();
  }

  void _throwIfCancelled() {
    if (_cancelled) throw const ImageWorkCancelled();
  }

  Future<void> _verifySrgbPng() async {
    final input = await file.open();
    try {
      const signature = [137, 80, 78, 71, 13, 10, 26, 10];
      final actual = await input.read(8);
      if (actual.length != 8 ||
          List.generate(8, (i) => signature[i] == actual[i]).contains(false)) {
        throw StateError('Early original raster requires an original PNG');
      }
      var scanned = 8, sawHeader = false;
      while (scanned <= 1 << 20) {
        _throwIfCancelled();
        final header = await input.read(8);
        if (header.length != 8) throw StateError('Truncated PNG header');
        int integer(List<int> b, int offset) =>
            b[offset] << 24 |
            b[offset + 1] << 16 |
            b[offset + 2] << 8 |
            b[offset + 3];
        final length = integer(header, 0);
        final type = String.fromCharCodes(header.sublist(4));
        if (type == 'IDAT') {
          if (!sawHeader) throw StateError('PNG has no original size header');
          return;
        }
        if (const [
          'iCCP',
          'cHRM',
          'cICP',
          'mDCv',
          'cLLi',
          'eXIf',
          'acTL',
          'fcTL'
        ].contains(type)) {
          throw StateError('PNG color/orientation excluded from early raster');
        }
        if (scanned + length + 12 > 1 << 20 ||
            scanned + length + 12 > fileSnapshot.size) {
          throw StateError('PNG header exceeds bounded inspection');
        }
        if (type == 'IHDR') {
          final info = await input.read(length);
          if (sawHeader ||
              scanned != 8 ||
              length != 13 ||
              info.length != 13 ||
              integer(info, 0) != demand.outputWidth ||
              integer(info, 4) != demand.outputHeight ||
              info[8] != 8 ||
              info[9] != 2 && info[9] != 6 ||
              info[10] != 0 ||
              info[11] != 0 ||
              info[12] > 1) {
            throw StateError('PNG original dimensions or RGBA8 header changed');
          }
          sawHeader = true;
        } else if (type == 'gAMA') {
          final gamma = await input.read(length);
          if (length != 4 || gamma.length != 4 || integer(gamma, 0) != 45455) {
            throw StateError('Non-sRGB PNG gamma excluded from early raster');
          }
        } else if (type == 'sRGB') {
          final intent = await input.read(length);
          if (length != 1 || intent.length != 1 || intent[0] > 3) {
            throw StateError('Invalid original PNG sRGB rendering intent');
          }
        } else {
          await input.setPosition(await input.position() + length);
        }
        await input.setPosition(await input.position() + 4);
        scanned += length + 12;
      }
      throw StateError('PNG header inspection did not reach image data');
    } finally {
      await input.close();
    }
  }
}
