import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/image_pipeline/cover_decode_target.dart';
import 'package:picakeep/foundation/image_pipeline/cover_target_provider.dart';
import 'package:picakeep/foundation/image_pipeline/cover_thumbnail_size.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/native_disk_work.dart';
import 'package:picakeep/foundation/image_pipeline/ordinary_jpeg_cover_policy.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart' as native;
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';

import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/illust_cover_diagnostics.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';

const kCoverThumbnailTargetWidth = 720;

/// 缩略图子目录名（位于统一封面缓存根之下）。
const String _coverThumbnailDirName = 'thumbs';

/// 缩略图文件后缀。
///
/// 旧实现把文件名固定成 `cover_thumb_720.png`；现在文件名是稳定哈希，
/// 后缀单独留一个常量，便于识别与清理。
const String _coverThumbnailSuffix = '.png';

class _CoverThumbnailTask {
  const _CoverThumbnailTask({
    required this.coverPath,
    required this.completer,
  });

  final String coverPath;
  final Completer<String?> completer;
}

class _DisplayThumbnailTask {
  final List<bool Function()> requests = [];
  late final Future<String?> result;

  // A request leaving the viewport must not cancel another visible consumer.
  bool get canContinue => requests.any((request) => request());
}

class _PaintThumbnailTask {
  final List<bool Function()> requests = [];
  late final Future<ui.Image> result;
  bool get canContinue => requests.any((request) => request());
}

class _PendingCoverRaster {
  const _PendingCoverRaster(this.image, this.stamp, this.generation);
  final ui.Image image;
  final String stamp;
  final int generation;
}

class _CoverBackfill {
  const _CoverBackfill(this.source, this.destination,
      {required this.stamp,
      required this.generation,
      required this.bucket,
      required this.nativeEncodedFit,
      this.trace});
  final File source, destination;
  final String stamp;
  final int generation, bucket;
  final bool nativeEncodedFit;
  final CoverThumbnailTrace? trace;
}

/// Optional request-local profiling. Stage durations are not first-paint times.
class CoverThumbnailTrace {
  final stages = <Map<String, Object>>[];
  final details = <String, Object>{};

  Future<T> measure<T>(String stage, Future<T> Function() action) async {
    final timelineStart = developer.Timeline.now;
    final watch = Stopwatch()..start();
    try {
      return await IllustCoverDiagnostics.measure('thumbnail.$stage', action);
    } finally {
      stages.add({
        'stage': stage,
        'elapsedUs': watch.elapsedMicroseconds,
        'timelineStartUs': timelineStart,
        'timelineFinishUs': developer.Timeline.now
      });
    }
  }

  void event(String stage) {
    final now = developer.Timeline.now;
    stages.add({
      'stage': stage,
      'elapsedUs': 0,
      'timelineStartUs': now,
      'timelineFinishUs': now
    });
  }
}

class CoverThumbnailCache {
  static const nativeThresholdBytes = 64 << 20;
  static const fallbackThresholdBytes = 64 << 20;
  static const derivativeAlgorithm = 'thumb-v3-area-fit';
  static final Queue<_CoverThumbnailTask> _queue = Queue<_CoverThumbnailTask>();
  static final Map<String, Future<String?>> _pending =
      <String, Future<String?>>{};
  static bool _running = false;

  static final Map<String, _DisplayThumbnailTask> _displayPending = {};
  static Future<void> _displayTail = Future.value();
  static Future<void>? _maintenance;
  static final Map<String, Future<void>> _providerPersistence = {};
  static final Map<String, VoidCallback> _providerPersistenceConsumption = {};
  static final Map<String, _PendingCoverRaster> _providerPersistenceImages = {};
  static final _providerBackfill = <String, _CoverBackfill>{};
  static Future<void>? _providerBackfillWorker;
  static int _providerPersistenceBytes = 0;
  static final Map<String, _PaintThumbnailTask> _paintPending = {};
  static int _providerReloadSequence = 0;
  static int _publicationGeneration = 0;
  static int _visibleWorkClaims = 0;
  static int _visibleWorkRevision = 0;
  static Completer<void>? _visibleWorkIdle;

  /// A page holds this while visible covers are queued or being prepared.
  /// Optional PNG encoding waits for that work without reserving a job slot.
  static VoidCallback deferProviderPersistenceForVisibleWork() {
    _visibleWorkRevision++;
    if (_visibleWorkClaims++ == 0) _visibleWorkIdle = Completer<void>();
    var released = false;
    return () {
      if (released) return;
      released = true;
      _visibleWorkRevision++;
      if (--_visibleWorkClaims == 0) {
        _visibleWorkIdle?.complete();
        _visibleWorkIdle = null;
      }
    };
  }

  static Future<void> _waitForVisibleCoverWork() async {
    while (true) {
      if (_visibleWorkClaims > 0) await _visibleWorkIdle!.future;
      final revision = _visibleWorkRevision;
      // A brief gap between swipes must not start optional PNG encoding.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (_visibleWorkClaims == 0 && revision == _visibleWorkRevision) return;
    }
  }

  @visibleForTesting
  static Future<void> Function()? beforeProviderPersistenceForTesting;
  @visibleForTesting
  static bool? nativeAvailableForTesting;
  @visibleForTesting
  static Future<native.ImageMetadata> Function(String path)?
      nativeProbeForTesting;
  @visibleForTesting
  static Duration? preparedImageLifetimeForTesting;
  @visibleForTesting
  static ImageWorkScheduler? warmSchedulerForTesting;
  @visibleForTesting
  static int? providerPersistenceItemLimitForTesting;
  @visibleForTesting
  static int? providerPersistenceByteLimitForTesting;
  @visibleForTesting
  static int? providerBackfillLimitForTesting;
  @visibleForTesting
  static int get providerPersistenceBytesForTesting =>
      _providerPersistenceBytes;
  @visibleForTesting
  static int get providerBackfillCountForTesting => _providerBackfill.length;
  @visibleForTesting
  static Future<void> waitForProviderPersistenceForTesting() async {
    while (_providerPersistence.isNotEmpty || _providerBackfillWorker != null) {
      await Future.wait([
        ..._providerPersistence.values,
        if (_providerBackfillWorker != null) _providerBackfillWorker!,
      ]);
    }
  }

  static void invalidatePendingPublications() {
    _publicationGeneration++;
    _providerBackfill.clear();
  }

  /// A cold cover becomes paintable before PNG encoding and disk persistence.
  /// The existing path-returning API remains available for preload/test callers.
  static Future<ImageProvider<Object>?> prepareProvider(
      String coverPath, int requestedWidth,
      {required bool Function() canContinue,
      bool nativeEncodedFit = false,
      CoverThumbnailTrace? trace}) async {
    final source = File(coverPath);
    final stat = await _measure(trace, 'sourceStat', source.stat);
    if (stat.type != FileSystemEntityType.file ||
        stat.size == 0 ||
        !canContinue()) {
      return null;
    }
    final bucket = coverThumbnailWidthBucket(requestedWidth);
    if (bucket == 0) return null;
    final stamp = '${stat.size}|${stat.modified.microsecondsSinceEpoch}';
    final algorithm = nativeEncodedFit
        ? '$derivativeAlgorithm-native-encoded-png-v1'
        : derivativeAlgorithm;
    final key = LocalCoverCache.stableHashForFileName(
        '$coverPath|$stamp|$bucket|$algorithm');
    final destination = File(p.join(_thumbRoot().path, '$key.png'));
    final generation = _publicationGeneration;
    final warmProvider = _PreparedCoverProvider(
        null, source, destination, key, bucket,
        nativeEncodedFit: nativeEncodedFit,
        trace: trace,
        canContinue: canContinue,
        generation: generation,
        sourceStamp: stamp,
        sourceSnapshot: stat);
    final imageCache = PaintingBinding.instance.imageCache;
    final memory = imageCache.statusForKey(warmProvider);
    final boundedMemory = imageCache.statusForKey(
        CoverDecodeTarget.cacheKeyForBoundedProvider(warmProvider));
    // A live pending stream can still belong to a cancelled former page. Only
    // completed cached pixels bypass original decoding, with this page's fresh
    // cancellation callback retained if a later eviction requires a reload.
    bool completed(ImageCacheStatus status) =>
        !status.pending && (status.keepAlive || status.live);
    final memoryHit = imageCache.maximumSize > 0 &&
        imageCache.maximumSizeBytes > 0 &&
        (completed(memory) || completed(boundedMemory));
    trace?.details.addAll({'bucket': bucket, 'memoryHit': memoryHit});
    if (memoryHit) {
      IllustCoverDiagnostics.event('thumbnail.memoryHit');
      trace?.event('memoryHit');
      return canContinue() && generation == _publicationGeneration
          ? warmProvider
          : null;
    }
    final retained = _clonePendingRaster(destination, stamp, generation);
    if (retained != null) {
      if (!canContinue() || generation != _publicationGeneration) {
        retained.dispose();
        return null;
      }
      trace?.details['pendingRasterHit'] = true;
      trace?.event('pendingRasterHit');
      IllustCoverDiagnostics.event('thumbnail.pendingRasterHit');
      return _PreparedCoverProvider(retained, source, destination, key, bucket,
          trace: trace,
          nativeEncodedFit: nativeEncodedFit,
          canContinue: canContinue,
          generation: generation,
          sourceStamp: stamp,
          sourceSnapshot: stat,
          onPreparedImageConsumed:
              _providerPersistenceConsumption[destination.path]);
    }
    final cached = await _measure(trace, 'cacheStat', destination.stat);
    trace?.details.addAll({'bucket': bucket, 'diskHit': cached.size > 0});
    if (cached.type == FileSystemEntityType.file && cached.size > 0) {
      return canContinue() && generation == _publicationGeneration
          ? warmProvider
          : null;
    }
    final taskKey = '${destination.path}:$generation';
    var pending = _paintPending[taskKey];
    if (pending == null) {
      final task = pending = _PaintThumbnailTask()..requests.add(canContinue);
      task.result = _decodeCoverImage(source, bucket,
          taskKey: taskKey,
          sourceStat: stat,
          nativeEncodedFit: nativeEncodedFit,
          trace: trace,
          canContinue: () =>
              task.canContinue && generation == _publicationGeneration);
      _paintPending[taskKey] = pending;
      unawaited(task.result.then<void>((master) {
        unawaited(Future<void>(() {
          _paintPending.remove(taskKey);
          master.dispose();
        }));
      }, onError: (Object _, StackTrace __) {
        _paintPending.remove(taskKey);
      }));
    } else {
      pending.requests.add(canContinue);
    }
    ui.Image image;
    try {
      image = (await pending.result).clone();
    } on ImageWorkQueueExceeded {
      rethrow;
    } on ImageWorkCancelled {
      return null;
    } catch (_) {
      return null;
    }
    try {
      final after = await _measure(trace, 'postDecodeSourceStat', source.stat);
      if (!canContinue() ||
          generation != _publicationGeneration ||
          after.type != FileSystemEntityType.file ||
          '${after.size}|${after.modified.microsecondsSinceEpoch}' != stamp) {
        image.dispose();
        return null;
      }
    } catch (_) {
      image.dispose();
      rethrow;
    }
    trace?.details
        .addAll({'decodedWidth': image.width, 'decodedHeight': image.height});
    final consumed = _prepareProviderPersistence(image, source, destination,
        stamp: stamp,
        generation: generation,
        taskKey: taskKey,
        trace: trace,
        bucket: bucket,
        nativeEncodedFit: nativeEncodedFit);
    return _PreparedCoverProvider(image, source, destination, key, bucket,
        trace: trace,
        nativeEncodedFit: nativeEncodedFit,
        canContinue: canContinue,
        generation: generation,
        sourceStamp: stamp,
        sourceSnapshot: stat,
        onPreparedImageConsumed: consumed);
  }

  /// Borrows only already decoded bounded pixels. The caller owns the clone.
  /// An alias must come from the manager's current original-fingerprint lookup.
  static Future<ui.Image?> cloneCachedReaderPreview(
      ImageProvider<Object> provider,
      {required File original,
      required FileStat snapshot,
      required ui.Size originalSize,
      String? validatedAliasPath}) async {
    if (provider is! _PreparedCoverProvider ||
        provider.generation != _publicationGeneration ||
        !originalSize.width.isFinite ||
        !originalSize.height.isFinite ||
        originalSize.width <= 0 ||
        originalSize.height <= 0) {
      return null;
    }
    final sourcePath = _readerPreviewPath(provider.source.path);
    if (sourcePath != _readerPreviewPath(original.path) &&
        (validatedAliasPath == null ||
            sourcePath != _readerPreviewPath(validatedAliasPath))) {
      return null;
    }
    ui.Image? image;
    try {
      if (!_sameReaderPreviewSnapshot(await original.stat(), snapshot) ||
          !_sameReaderPreviewSnapshot(
              await provider.source.stat(), provider.sourceSnapshot)) {
        return null;
      }
      // Inspect the completed stream without resolving the provider: resolve
      // would turn a cache miss into another original-image decode.
      final cache = PaintingBinding.instance.imageCache;
      for (final key in <Object>[
        CoverDecodeTarget.cacheKeyForBoundedProvider(provider),
        provider,
      ]) {
        final status = cache.statusForKey(key);
        if (status.pending || (!status.keepAlive && !status.live)) continue;
        final completer = cache.putIfAbsent(
            key, () => throw StateError('Cached reader preview was evicted'),
            onError: (_, __) {});
        if (completer == null) continue;
        final listener = ImageStreamListener((info, synchronous) {
          try {
            image ??= info.image.clone();
          } finally {
            info.dispose();
          }
        }, onError: (_, __) {});
        completer.addListener(listener);
        completer.removeListener(listener);
        if (image != null) break;
      }
      image ??= provider._first?.clone();
      image ??= _clonePendingRaster(
          provider.destination, provider.sourceStamp, provider.generation);
      if (image == null ||
          image!.width > 4096 ||
          image!.height > 4096 ||
          image!.width * image!.height > 4 * 1024 * 1024 ||
          (image!.width -
                      image!.height * originalSize.width / originalSize.height)
                  .abs() >
              2 ||
          provider.generation != _publicationGeneration ||
          !_sameReaderPreviewSnapshot(await original.stat(), snapshot) ||
          !_sameReaderPreviewSnapshot(
              await provider.source.stat(), provider.sourceSnapshot)) {
        return null;
      }
      final owned = image;
      image = null;
      return owned;
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
    }
  }

  static String _readerPreviewPath(String path) {
    final normalized = p.normalize(p.absolute(path));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  static bool _sameReaderPreviewSnapshot(FileStat current, FileStat expected) =>
      current.type == FileSystemEntityType.file &&
      current.size > 0 &&
      current.size == expected.size &&
      current.modified == expected.modified &&
      current.changed == expected.changed;

  /// Returns the first-paint signal, retaining a separately bounded clone.
  /// Re-decoded expired providers use this same path to populate the disk cache.
  static VoidCallback? _prepareProviderPersistence(
      ui.Image image, File source, File destination,
      {required String stamp,
      required int generation,
      required String taskKey,
      required int bucket,
      required bool nativeEncodedFit,
      CoverThumbnailTrace? trace}) {
    final persistencePixels = image.width * image.height * 4;
    VoidCallback? consumed = _providerPersistenceConsumption[destination.path];
    final previous = _providerPersistenceImages[destination.path];
    if (previous?.generation == generation && previous?.stamp == stamp) {
      return consumed;
    }
    if (!_providerPersistence.containsKey(destination.path) &&
        _providerPersistence.length <
            (providerPersistenceItemLimitForTesting ?? 32) &&
        _providerPersistenceBytes + persistencePixels <=
            (providerPersistenceByteLimitForTesting ?? 32 * 1024 * 1024)) {
      final persistenceImage = image.clone();
      _providerPersistenceBytes += persistencePixels;
      _providerPersistenceImages[destination.path] =
          _PendingCoverRaster(persistenceImage, stamp, generation);
      final afterFirstFrame = Completer<bool>();
      var firstFrameAccepted = false;
      final firstFrameTimeout = Timer(const Duration(seconds: 2), () {
        if (!afterFirstFrame.isCompleted) afterFirstFrame.complete(false);
      });
      consumed = () {
        trace?.event('providerConsumed');
        SchedulerBinding.instance.addPostFrameCallback((_) {
          trace?.event('uiPostFrame');
          if (!afterFirstFrame.isCompleted) {
            firstFrameAccepted = true;
            afterFirstFrame.complete(true);
          } else if (!firstFrameAccepted &&
              generation == _publicationGeneration) {
            // A retained clone can reach a new page just as the unpainted
            // timeout releases the original persistence task. Its later real
            // first frame still needs a source-only publication request.
            _enqueueProviderBackfill(_CoverBackfill(source, destination,
                stamp: stamp,
                generation: generation,
                bucket: bucket,
                nativeEncodedFit: nativeEncodedFit,
                trace: trace));
          }
        });
      };
      _providerPersistenceConsumption[destination.path] = consumed;
      final releaseSource = DerivedImageStore.protectTemporaryPath(source.path);
      final future = () async {
        File? temporary;
        ImageDiskReservation? diskReservation;
        try {
          if (!await afterFirstFrame.future) return;
          firstFrameTimeout.cancel();
          // The prepared image was available synchronously in that frame.
          // Encoding starts in a later event and reserves background budget.
          await Future<void>(() {});
          var deferred = false;
          do {
            deferred = false;
            await _waitForVisibleCoverWork();
            await beforeProviderPersistenceForTesting?.call();
            if (generation != _publicationGeneration) return;
            final finished = Completer<void>();
            var started = false;
            trace?.event('persistSubmitted');
            final ticket = ImageWorkScheduler.shared.submit<void>(
                key: 'cover-persist:$taskKey',
                priority: ImageWorkPriority.background,
                estimatedBytes: persistencePixels * 3 + (32 << 20),
                run: (cancel) async {
                  started = true;
                  try {
                    if (cancel.isCancelled ||
                        generation != _publicationGeneration) {
                      return;
                    }
                    // Work can resume while this background ticket is queued.
                    // Release the slot before waiting for idle and retry later.
                    if (_visibleWorkClaims > 0) {
                      deferred = true;
                      return;
                    }
                    final bytes = await _measure(
                        trace,
                        'persistEncode',
                        () => persistenceImage.toByteData(
                            format: ui.ImageByteFormat.png));
                    if (bytes == null ||
                        cancel.isCancelled ||
                        generation != _publicationGeneration) {
                      return;
                    }
                    await destination.parent.create(recursive: true);
                    diskReservation = await _measure(
                        trace,
                        'diskAdmission',
                        () => ImageDiskQuota.shared.admitPublication(
                            destination.path,
                            maximumBytes: bytes.lengthInBytes));
                    temporary = File(
                        '${destination.path}.${DateTime.now().microsecondsSinceEpoch}.part');
                    await _measure(
                        trace,
                        'persistWrite',
                        () => temporary!.writeAsBytes(
                            bytes.buffer.asUint8List(),
                            flush: true));
                    final current = await source.stat();
                    if (cancel.isCancelled ||
                        generation != _publicationGeneration ||
                        current.type != FileSystemEntityType.file ||
                        '${current.size}|${current.modified.microsecondsSinceEpoch}' !=
                            stamp) {
                      return;
                    }
                    await temporary!.rename(destination.path);
                    temporary = null;
                    await diskReservation!.commit([destination.path]);
                    _scheduleMaintenance(destination.path);
                  } finally {
                    if (!finished.isCompleted) finished.complete();
                  }
                });
            try {
              await ticket.future;
            } finally {
              // Ticket cancellation can precede the actual encoder completion.
              // Retain the clone and source until native use has ended.
              if (started) await finished.future;
            }
          } while (deferred && generation == _publicationGeneration);
        } catch (_) {
          /* First paint already succeeded; persistence is optional. */
        } finally {
          _providerPersistenceImages.remove(destination.path);
          persistenceImage.dispose();
          firstFrameTimeout.cancel();
          releaseSource();
          _providerPersistenceBytes -= persistencePixels;
          if (temporary != null) {
            try {
              await temporary!.delete();
            } catch (_) {}
          }
          try {
            await diskReservation?.abort();
          } catch (_) {}
          _providerPersistence.remove(destination.path);
          _providerPersistenceConsumption.remove(destination.path);
        }
      }();
      _providerPersistence[destination.path] = future;
    } else {
      // No pixel clone is retained beyond the existing budget. Remember only
      // sources whose first frame was consumed, then fill the disk cache idle.
      var scheduled = false;
      consumed = () {
        if (scheduled) return;
        scheduled = true;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (generation != _publicationGeneration) return;
          _enqueueProviderBackfill(_CoverBackfill(source, destination,
              stamp: stamp,
              generation: generation,
              bucket: bucket,
              nativeEncodedFit: nativeEncodedFit,
              trace: trace));
        });
      };
    }
    return consumed;
  }

  static ui.Image? _clonePendingRaster(
      File destination, String stamp, int generation) {
    final raster = _providerPersistenceImages[destination.path];
    if (raster == null ||
        raster.stamp != stamp ||
        raster.generation != generation ||
        generation != _publicationGeneration) {
      return null;
    }
    // Clones own independent handles. Persistence can dispose its handle while
    // another page paints; no old page callback is retained by the new provider.
    return raster.image.clone();
  }

  static void _enqueueProviderBackfill(_CoverBackfill entry) {
    if (entry.generation != _publicationGeneration) return;
    final limit = providerBackfillLimitForTesting ?? 256;
    if (limit <= 0) return;
    final key = entry.destination.path;
    if (!_providerBackfill.containsKey(key) &&
        _providerBackfill.length >= limit) {
      _providerBackfill.remove(_providerBackfill.keys.first);
      entry.trace?.event('persistBackfillLimit');
    }
    _providerBackfill[key] = entry;
    entry.trace?.event('persistBackfillQueued');
    IllustCoverDiagnostics.event('thumbnail.persistBackfillQueued');
    if (_providerBackfillWorker != null) return;
    final worker = _drainProviderBackfill();
    _providerBackfillWorker = worker;
    unawaited(worker.whenComplete(() {
      _providerBackfillWorker = null;
      // An entry can arrive between the final loop condition and completion.
      if (_providerBackfill.isNotEmpty) {
        _enqueueProviderBackfill(_providerBackfill.values.first);
      }
    }));
  }

  static Future<void> _drainProviderBackfill() async {
    // Schedule after this turn so the worker field is installed before it can
    // finish. This worker never joins the serial prepareDisplay chain.
    await Future<void>(() {});
    int? idleRevision;
    while (_providerBackfill.isNotEmpty) {
      if (_visibleWorkClaims > 0 || idleRevision != _visibleWorkRevision) {
        _providerBackfill.values.first.trace
            ?.event('persistBackfillWaitingForIdle');
        await _waitForVisibleCoverWork();
        idleRevision = _visibleWorkRevision;
      }
      // Explicit cache clearing can remove all entries while idle is awaited.
      if (_providerBackfill.isEmpty) return;
      // Drain the pixel clones first. Backfill holds at most one temporary
      // bounded raster, rather than enlarging the persistent clone budget.
      if (_providerPersistence.isNotEmpty) {
        await Future.wait(_providerPersistence.values.toList());
        continue;
      }
      final key = _providerBackfill.keys.first;
      final entry = _providerBackfill[key]!;
      var retry = false;
      try {
        retry = await _publishProviderBackfill(entry);
      } catch (_) {
        // This optional cache must never change a successful visible result.
      }
      if (!retry && identical(_providerBackfill[key], entry)) {
        _providerBackfill.remove(key);
      }
    }
  }

  /// Returns true only when foreground work interrupted this idle attempt.
  static Future<bool> _publishProviderBackfill(_CoverBackfill entry) async {
    final idleRevision = _visibleWorkRevision;
    bool current() => entry.generation == _publicationGeneration;
    bool idle() =>
        current() &&
        _visibleWorkClaims == 0 &&
        idleRevision == _visibleWorkRevision;
    if (!current()) return false;
    if (!idle()) return true;
    final before = await entry.source.stat();
    if (!current() ||
        before.type != FileSystemEntityType.file ||
        '${before.size}|${before.modified.microsecondsSinceEpoch}' !=
            entry.stamp) {
      return false;
    }
    final cached = await entry.destination.stat();
    if (cached.type == FileSystemEntityType.file && cached.size > 0) {
      return false;
    }
    final releaseSource =
        DerivedImageStore.protectTemporaryPath(entry.source.path);
    ui.Image? image;
    File? temporary;
    ImageDiskReservation? reservation;
    try {
      try {
        image = await _decodeCoverImage(entry.source, entry.bucket,
            taskKey: 'backfill:${entry.destination.path}:${entry.generation}',
            sourceStat: before,
            nativeEncodedFit: entry.nativeEncodedFit,
            trace: entry.trace,
            priority: ImageWorkPriority.background,
            canContinue: idle);
      } on ImageWorkCancelled {
        return current();
      }
      if (!idle()) return current();
      final owned = image;
      final finished = Completer<void>();
      var started = false;
      var deferred = false;
      final ticket = ImageWorkScheduler.shared.submit<void>(
          key:
              'cover-backfill-persist:${entry.destination.path}:${entry.generation}',
          priority: ImageWorkPriority.background,
          estimatedBytes: owned.width * owned.height * 12 + (32 << 20),
          run: (cancel) async {
            started = true;
            try {
              if (cancel.isCancelled || !current()) return;
              if (!idle()) {
                deferred = true;
                return;
              }
              final bytes = await _measure(entry.trace, 'backfillEncode',
                  () => owned.toByteData(format: ui.ImageByteFormat.png));
              if (bytes == null || cancel.isCancelled || !current()) return;
              await entry.destination.parent.create(recursive: true);
              reservation = await ImageDiskQuota.shared.admitPublication(
                  entry.destination.path,
                  maximumBytes: bytes.lengthInBytes);
              temporary = File('${entry.destination.path}.'
                  '${DateTime.now().microsecondsSinceEpoch}.part');
              await _measure(
                  entry.trace,
                  'backfillWrite',
                  () => temporary!
                      .writeAsBytes(bytes.buffer.asUint8List(), flush: true));
              final after = await entry.source.stat();
              if (cancel.isCancelled ||
                  !current() ||
                  after.type != FileSystemEntityType.file ||
                  '${after.size}|${after.modified.microsecondsSinceEpoch}' !=
                      entry.stamp) {
                return;
              }
              await temporary!.rename(entry.destination.path);
              temporary = null;
              await reservation!.commit([entry.destination.path]);
              _scheduleMaintenance(entry.destination.path);
              entry.trace?.event('persistBackfillPublished');
            } finally {
              finished.complete();
            }
          });
      try {
        await ticket.future;
      } finally {
        if (started) await finished.future;
      }
      return deferred && current();
    } finally {
      image?.dispose();
      releaseSource();
      try {
        if (temporary != null) await temporary!.delete();
      } catch (_) {}
      try {
        await reservation?.abort();
      } catch (_) {}
    }
  }

  static Future<T> _measure<T>(CoverThumbnailTrace? trace, String stage,
          Future<T> Function() action) =>
      trace == null ? action() : trace.measure(stage, action);

  static final List<VoidCallback> _maintenanceProtections = [];

  static Future<ui.Image> _decodeCoverImage(
    File source,
    int bucket, {
    required String taskKey,
    required bool Function() canContinue,
    FileStat? sourceStat,
    CoverThumbnailTrace? trace,
    bool nativeEncodedFit = false,
    ImageWorkPriority priority = ImageWorkPriority.cover,
  }) async {
    final stat = sourceStat ?? await source.stat();
    native.ImageMetadata? nativeMetadata;
    final nativeAvailable =
        nativeAvailableForTesting ?? native.PicakeepImageEngine.isAvailable;
    if (!canContinue()) throw const ImageWorkCancelled();
    if (nativeAvailable) {
      try {
        nativeMetadata = await _measure(
            trace,
            'nativeProbe',
            () =>
                nativeProbeForTesting?.call(source.path) ??
                const native.PicakeepImageEngine().probe(source.path));
      } on native.ImageEngineQueueExceeded catch (error) {
        throw ImageWorkQueueExceeded(ImageWorkLane.execution, error.limit);
      } on native.ImageEngineException catch (error) {
        if (error.isCancelled) throw const ImageWorkCancelled();
        if (!error.isUnsupported) rethrow;
        /* Other Flutter-supported formats use the small-image path. */
      }
    }
    if (!canContinue()) throw const ImageWorkCancelled();
    var width = nativeMetadata?.width ?? 0;
    var height = nativeMetadata?.height ?? 0;
    if (nativeMetadata == null) {
      if (stat.size > 64 * 1024 * 1024) {
        throw ImageWorkBudgetExceeded(stat.size * 2, 64 * 1024 * 1024);
      }
      final header = await ui.ImmutableBuffer.fromFilePath(source.path);
      ui.ImageDescriptor? descriptor;
      try {
        descriptor = await ui.ImageDescriptor.encoded(header);
        width = descriptor.width;
        height = descriptor.height;
      } finally {
        descriptor?.dispose();
        header.dispose();
      }
    }
    final scale = math.min(
        1.0,
        math.min(
            bucket / width,
            math.min(4096 / math.max(width, height),
                math.sqrt(4 * 1024 * 1024 / (width * height)))));
    final demand = ReaderTileDemand(
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        scale,
        -1,
        -1);
    final outputWidth = demand.outputWidth;
    final outputHeight = demand.outputHeight;
    OrdinaryJpegCoverPlan? ordinaryJpeg;
    if (nativeMetadata != null && nativeMetadata.format == 'jpeg') {
      final candidate = await _measure(
          trace,
          'ordinaryJpegEligibility',
          () => OrdinaryJpegCoverPlan.inspect(source,
              snapshot: stat,
              metadata: nativeMetadata!,
              outputWidth: outputWidth,
              outputHeight: outputHeight,
              canContinue: canContinue));
      if (!canContinue()) throw const ImageWorkCancelled();
      if (candidate?.fitsAvailableMemory(
              OrdinaryJpegCoverPlan.availableMemoryBytes) ==
          true) {
        ordinaryJpeg = candidate;
      }
    }
    var useNativeEncoded = nativeEncodedFit &&
        nativeMetadata?.format == 'png' &&
        nativeMetadata?.animated == false &&
        nativeMetadata?.bitDepth == 8 &&
        nativeMetadata?.hasColorProfile == false &&
        nativeMetadata?.orientation == 1 &&
        outputWidth < width &&
        outputHeight < height;
    if (useNativeEncoded) {
      final handle = await source.open();
      try {
        final header = await _measure(
            trace, 'nativePngEligibility', () => handle.read(29));
        useNativeEncoded = header.length == 29 && header[28] == 0;
      } finally {
        await handle.close();
      }
    }
    final useNative = ordinaryJpeg == null &&
        (width * height * 4 >
                (nativeAvailable
                    ? nativeThresholdBytes
                    : fallbackThresholdBytes) ||
            nativeMetadata?.orientation != null &&
                nativeMetadata!.orientation != 1 ||
            nativeMetadata?.hasColorProfile == true ||
            (nativeMetadata?.bitDepth ?? 8) > 8 ||
            useNativeEncoded);
    trace?.details.addAll({
      'backend': useNativeEncoded
          ? 'native-encoded-png'
          : useNative
              ? 'native'
              : 'flutter',
      'nativeEncodedFitRequested': nativeEncodedFit,
      'nativeEncodedFitUsed': useNativeEncoded,
      'ordinaryJpegScaledFit': ordinaryJpeg != null,
    });
    IllustCoverDiagnostics.event('thumbnail.backend', arguments: {
      'backend': useNativeEncoded
          ? 'native-encoded-png'
          : useNative
              ? 'native'
              : 'flutter',
      'format': nativeMetadata?.format ?? 'flutter-supported',
      'width': width,
      'height': height,
      'sourceBytes': stat.size,
      'outputWidth': outputWidth,
      'outputHeight': outputHeight,
      'ordinaryJpegScaledFit': ordinaryJpeg != null,
    });
    if (useNative && nativeMetadata == null) {
      throw ImageWorkBudgetExceeded(width * height * 4, 64 * 1024 * 1024);
    }
    final backingKey = LocalCoverCache.stableHashForFileName(
        '${source.path}|${stat.size}|${stat.modified.microsecondsSinceEpoch}|cover-backing-v1');
    final backingPath = p.join(
        App.cachePath, 'image_pipeline', 'cover_backing', '$backingKey.rgba');
    var nativeWorking = 0;
    if (useNative) {
      try {
        nativeWorking = await _measure(
            trace,
            'nativeEstimate',
            () => const native.PicakeepImageEngine().estimateWorkingBytes(
                source.path,
                backingPath: backingPath,
                outputWidth: outputWidth,
                outputHeight: outputHeight));
      } on native.ImageEngineQueueExceeded catch (error) {
        throw ImageWorkQueueExceeded(ImageWorkLane.execution, error.limit);
      } on native.ImageEngineException catch (error) {
        if (error.isCancelled) throw const ImageWorkCancelled();
        rethrow;
      }
    }
    final outputBytes = outputWidth * outputHeight * 4;
    final encodedLimit = math.min(32 << 20, math.max(65536, outputBytes * 2));
    final encoderBudget =
        math.min(128 << 20, outputBytes * 2 + encodedLimit * 2 + (8 << 20));
    final estimate = useNative
        ? useNativeEncoded
            // Include native/TTD/FFI pixels, encoder growth, encoded copies,
            // Flutter decoding and GPU handoff in the existing shared budget.
            ? nativeWorking +
                encoderBudget +
                outputBytes * 6 +
                encodedLimit * 3 +
                (32 << 20)
            : nativeWorking + outputWidth * outputHeight * 12
        : ordinaryJpeg?.estimatedWorkingBytes ??
            64 * 1024 * 1024 + width * height * 4 + stat.size * 2;
    if (ordinaryJpeg != null) {
      trace?.details['jobEstimatedBytes'] = estimate;
    }
    if (useNativeEncoded) {
      trace?.details.addAll({
        'nativeWorkingBudgetBytes': nativeWorking,
        'encodedLimitBytes': encodedLimit,
        'encoderBudgetBytes': encoderBudget,
        'jobEstimatedBytes': estimate,
      });
    }
    if (!canContinue()) throw const ImageWorkCancelled();
    final queueWatch = trace == null ? null : (Stopwatch()..start());
    final queueStart = trace == null ? null : developer.Timeline.now;
    return ImageWorkScheduler.shared
        .submit<ui.Image>(
            key: 'cover-decode:$taskKey',
            priority: priority,
            estimatedBytes: estimate,
            disposeResult: (image) => image.dispose(),
            run: (cancel) async {
              if (queueWatch != null) {
                IllustCoverDiagnostics.event('thumbnail.queueWait',
                    arguments: {'elapsedUs': queueWatch.elapsedMicroseconds});
                trace!.stages.add({
                  'stage': 'decodeQueueWait',
                  'elapsedUs': queueWatch.elapsedMicroseconds,
                  'timelineStartUs': queueStart!,
                  'timelineFinishUs': developer.Timeline.now,
                });
              }
              bool cancelled() => cancel.isCancelled || !canContinue();
              if (cancelled()) throw const ImageWorkCancelled();
              final releaseSource =
                  DerivedImageStore.protectTemporaryPath(source.path);
              try {
                if (useNative) {
                  final releaseBacking =
                      DerivedImageStore.protectTemporaryPath(backingPath);
                  final completed = Completer<void>();
                  final watch =
                      Timer.periodic(const Duration(milliseconds: 25), (_) {
                    if (cancelled() && !completed.isCompleted) {
                      completed.complete();
                    }
                  });
                  unawaited(cancel.cancelled.then((_) {
                    if (!completed.isCompleted) completed.complete();
                  }));
                  try {
                    await Directory(p.dirname(backingPath))
                        .create(recursive: true);
                    final image = useNativeEncoded
                        ? await _decodeNativeEncodedCover(source, demand,
                            backingPath: backingPath,
                            nativeBudgetBytes: nativeWorking,
                            encoderBudgetBytes: encoderBudget,
                            encodedLimitBytes: encodedLimit,
                            isCancelled: cancelled,
                            cancelled: completed.future,
                            trace: trace)
                        : await _measure(
                            trace,
                            'nativeRaster',
                            () => const NativeReaderRasterBackend(
                                    persistRaster: false)
                                .decode(source, demand,
                                    backingPath: backingPath,
                                    memoryBudgetBytes: nativeWorking,
                                    isCancelled: cancelled,
                                    cancelled: completed.future));
                    DerivedImageStore.scheduleMaintenance(backingPath);
                    return image;
                  } finally {
                    watch.cancel();
                    releaseBacking();
                  }
                }
                if (ordinaryJpeg != null) {
                  final available = OrdinaryJpegCoverPlan.availableMemoryBytes;
                  if (!ordinaryJpeg.fitsAvailableMemory(available)) {
                    throw ImageWorkBudgetExceeded(estimate,
                        math.max(0, available - (256 << 20) - available ~/ 4));
                  }
                  final current = await source.stat();
                  if (cancelled()) throw const ImageWorkCancelled();
                  if (current.type != FileSystemEntityType.file ||
                      current.size != stat.size ||
                      current.modified != stat.modified) {
                    throw StateError('JPEG cover changed before target decode');
                  }
                }
                final buffer = await _measure(trace, 'flutterBuffer',
                    () => ui.ImmutableBuffer.fromFilePath(source.path));
                ui.ImageDescriptor? descriptor;
                ui.Codec? codec;
                try {
                  if (cancelled()) throw const ImageWorkCancelled();
                  descriptor = await _measure(trace, 'flutterDescriptor',
                      () => ui.ImageDescriptor.encoded(buffer));
                  if (cancelled()) throw const ImageWorkCancelled();
                  if (ordinaryJpeg != null &&
                      (descriptor!.width != width ||
                          descriptor.height != height)) {
                    throw StateError('JPEG cover dimensions changed');
                  }
                  codec = await _measure(
                      trace,
                      'flutterCodec',
                      () => descriptor!.instantiateCodec(
                          targetWidth: outputWidth,
                          targetHeight: outputHeight));
                  if (cancelled()) throw const ImageWorkCancelled();
                  if (ordinaryJpeg != null && codec!.frameCount != 1) {
                    throw StateError('Ordinary JPEG cover became animated');
                  }
                  final image = (await _measure(
                          trace, 'flutterFirstFrame', codec!.getNextFrame))
                      .image;
                  if (cancelled()) {
                    image.dispose();
                    throw const ImageWorkCancelled();
                  }
                  if (ordinaryJpeg != null &&
                      (image.width != outputWidth ||
                          image.height != outputHeight ||
                          image.width > 4096 ||
                          image.height > 4096 ||
                          image.width * image.height > 4 * 1024 * 1024)) {
                    image.dispose();
                    throw StateError('JPEG cover exceeded target pixel limits');
                  }
                  return image;
                } finally {
                  codec?.dispose();
                  descriptor?.dispose();
                  buffer.dispose();
                }
              } finally {
                releaseSource();
              }
            })
        .future;
  }

  static Future<ui.Image> _decodeNativeEncodedCover(
      File source, ReaderTileDemand demand,
      {required String backingPath,
      required int nativeBudgetBytes,
      required int encoderBudgetBytes,
      required int encodedLimitBytes,
      required bool Function() isCancelled,
      required Future<void> cancelled,
      CoverThumbnailTrace? trace}) async {
    final token = native.NativeCancellationToken();
    unawaited(cancelled.then((_) => token.cancel()));
    native.NativePixelBuffer? pixels;
    native.NativeEncodedImage? encoded;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? ownedImage;
    void checkCancelled() {
      if (isCancelled()) {
        token.cancel();
        throw const ImageWorkCancelled();
      }
    }

    try {
      checkCancelled();
      final box = native.NativeImageRect(
          demand.sourceRect.left.round(),
          demand.sourceRect.top.round(),
          demand.sourceRect.width.round(),
          demand.sourceRect.height.round());
      final decodedPixels = await _measure(
          trace,
          'nativePngDecode',
          () => withNativeDiskWork<native.NativePixelBuffer>(
              source, backingPath,
              region: box,
              outputWidth: demand.outputWidth,
              outputHeight: demand.outputHeight,
              run: (diskBudget) => const native.PicakeepImageEngine()
                  .decodeRegion(source.path, box,
                      backingPath: backingPath,
                      outputWidth: demand.outputWidth,
                      outputHeight: demand.outputHeight,
                      memoryBudgetBytes: nativeBudgetBytes,
                      diskBudgetBytes: diskBudget,
                      cancelToken: token)));
      pixels = decodedPixels;
      checkCancelled();
      trace?.details.addAll({
        'nativeCodecUs': decodedPixels.elapsedMicroseconds,
        'nativeWorkerQueueUs': decodedPixels.workerQueueMicroseconds,
        'nativeWorkerExecutionUs': decodedPixels.workerExecutionMicroseconds,
        'nativeWorkerTransportUs': decodedPixels.workerTransportMicroseconds,
        'nativeWorkingPeakBytes': decodedPixels.workingPeakBytes,
      });
      final encodedPng = await _measure(
          trace,
          'nativePngEncode',
          () => const native.PicakeepImageEngine().encodePixels(
              decodedPixels.bytes,
              width: decodedPixels.width,
              height: decodedPixels.height,
              stride: decodedPixels.stride,
              format: native.NativeImageEncoding.png,
              lossless: true,
              memoryBudgetBytes: encoderBudgetBytes,
              maxOutputBytes: encodedLimitBytes,
              cancelToken: token));
      encoded = encodedPng;
      decodedPixels.dispose();
      pixels = null;
      checkCancelled();
      trace?.details.addAll({
        'nativePngCodecEncodeUs': encodedPng.elapsedMicroseconds,
        'nativePngEncoderPeakBytes': encodedPng.workingPeakBytes,
        'nativePngEncodedBytes': encodedPng.bytes.length,
      });
      buffer = await _measure(trace, 'nativePngBuffer',
          () => ui.ImmutableBuffer.fromUint8List(encodedPng.bytes));
      encodedPng.dispose();
      encoded = null;
      checkCancelled();
      final pngDescriptor = await _measure(trace, 'nativePngDescriptor',
          () => ui.ImageDescriptor.encoded(buffer!));
      descriptor = pngDescriptor;
      if (pngDescriptor.width != demand.outputWidth ||
          pngDescriptor.height != demand.outputHeight) {
        throw StateError('Native PNG cover dimensions changed');
      }
      final pngCodec = await _measure(
          trace, 'nativePngCodec', pngDescriptor.instantiateCodec);
      codec = pngCodec;
      ownedImage =
          (await _measure(trace, 'nativePngFirstFrame', pngCodec.getNextFrame))
              .image;
      checkCancelled();
      if (ownedImage.width != demand.outputWidth ||
          ownedImage.height != demand.outputHeight) {
        throw StateError('Native PNG cover texture dimensions changed');
      }
      final image = ownedImage;
      ownedImage = null;
      return image;
    } finally {
      ownedImage?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
      encoded?.dispose();
      pixels?.dispose();
      token.dispose();
    }
  }

  @visibleForTesting
  static Future<void> Function(String protectedPath)? maintenanceForTesting;

  @visibleForTesting
  static Future<void> waitForMaintenanceForTesting() async {
    await _maintenance;
  }

  static void _scheduleMaintenance(String path) {
    _maintenanceProtections.add(RemoteLibraryDataSource.protectCacheFile(path));
    if (_maintenance != null) return;
    final dataRoot = App.dataPath;
    final cacheRoot = App.cachePath;
    final maintenance = maintenanceForTesting;
    // Schedule on the next event turn: returning a prepared image and releasing
    // the serial decoder never waits for a full-cache quota scan.
    _maintenance = Future<void>(() async {
      try {
        if (App.dataPath != dataRoot || App.cachePath != cacheRoot) return;
        if (maintenance != null) {
          await maintenance(path);
        } else {
          await RemoteLibraryDataSource.trimCacheToLimit(protectedPath: path);
        }
      } catch (_) {
        // Quota maintenance is best effort, not an image failure.
      } finally {
        for (final release in _maintenanceProtections) {
          release();
        }
        _maintenanceProtections.clear();
        _maintenance = null;
      }
    });
  }

  /// Prepared off the build path. Only application-internal resolved covers
  /// belong here; external privileged sources must first use the manager.
  static Future<String?> prepareDisplay(String coverPath, int requestedWidth,
      {required bool Function() canContinue,
      ImageWorkPriority priority = ImageWorkPriority.cover}) async {
    if (!canContinue()) return null;
    final publicationGeneration = _publicationGeneration;
    final source = File(coverPath);
    final before = await source.stat();
    if (before.type != FileSystemEntityType.file || before.size == 0) {
      return null;
    }
    final bucket = coverThumbnailWidthBucket(requestedWidth);
    if (bucket == 0) return coverPath;
    final stamp = '${before.size}|${before.modified.microsecondsSinceEpoch}';
    final key = LocalCoverCache.stableHashForFileName(
        '$coverPath|$stamp|$bucket|$derivativeAlgorithm');
    final destination = File(p.join(_thumbRoot().path, '$key.png'));
    final cached = await destination.stat();
    if (!canContinue()) return null;
    if (cached.type == FileSystemEntityType.file && cached.size > 0) {
      IllustCoverDiagnostics.event('thumbnail.hit');
      return destination.path;
    }
    // Include the destination root so a data-directory switch cannot join an
    // in-flight task writing a previous application's cache.
    final taskKey = destination.path;
    final pending = _displayPending[taskKey];
    if (pending != null) {
      pending.requests.add(canContinue);
      final result = await pending.result;
      return canContinue() ? result : null;
    }
    final task = _DisplayThumbnailTask()..requests.add(canContinue);
    _displayPending[taskKey] = task;
    final previous = _displayTail;
    final done = Completer<void>();
    _displayTail = done.future;
    task.result =
        IllustCoverDiagnostics.measure('thumbnail.generate', () async {
      await IllustCoverDiagnostics.measure('thumbnail.wait', () => previous);
      ui.Image? image;
      File? temporary;
      ImageDiskReservation? diskReservation;
      try {
        if (!task.canContinue) return null;
        if (priority == ImageWorkPriority.background) {
          await _waitForVisibleCoverWork();
          if (!task.canContinue) return null;
        }
        image = await IllustCoverDiagnostics.measure(
            'thumbnail.decode',
            () => _decodeCoverImage(source, bucket,
                taskKey: '$taskKey:$publicationGeneration',
                sourceStat: before,
                priority: priority,
                canContinue: () =>
                    task.canContinue &&
                    publicationGeneration == _publicationGeneration));
        if (!task.canContinue) return null;
        if (priority == ImageWorkPriority.background) {
          await _waitForVisibleCoverWork();
          if (!task.canContinue) return null;
        }
        final bytes = await IllustCoverDiagnostics.measure('thumbnail.encode',
            () => image!.toByteData(format: ui.ImageByteFormat.png));
        if (bytes == null || !task.canContinue) return null;
        await destination.parent.create(recursive: true);
        diskReservation = await ImageDiskQuota.shared.admitPublication(
            destination.path,
            maximumBytes: bytes.lengthInBytes);
        temporary = File(
            '${destination.path}.${DateTime.now().microsecondsSinceEpoch}.part');
        await temporary.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
        final after = await source.stat();
        if (!task.canContinue ||
            publicationGeneration != _publicationGeneration ||
            after.type != FileSystemEntityType.file ||
            '${after.size}|${after.modified.microsecondsSinceEpoch}' != stamp) {
          return null;
        }
        await temporary.rename(destination.path);
        temporary = null;
        await diskReservation.commit([destination.path]);
        _scheduleMaintenance(destination.path);
        return destination.path;
      } catch (_) {
        return null;
      } finally {
        try {
          if (temporary != null && await temporary.exists()) {
            await temporary.delete();
          }
        } catch (_) {
          // A disposable .part may remain; never stall the serial worker.
        } finally {
          try {
            await diskReservation?.abort();
          } catch (_) {}
          image?.dispose();
          done.complete();
          _displayPending.remove(taskKey);
        }
      }
    });
    final result = await task.result;
    return canContinue() ? result : null;
  }

  /// 缩略图路径：**统一缓存根下的 `thumbs/` 子目录**（plan/12）。
  ///
  /// ## 改动前的问题
  ///
  /// 旧实现是 `原封面父目录/cover_thumb_720.png`，有两个真问题：
  ///
  /// 1. **往用户下载目录里写文件** —— 原封面在下载目录时，缩略图就落在那里，
  ///    违背"缓存只写应用目录"（计划验收标准 4）；
  /// 2. **同一目录下的多个封面共用一个文件名** —— 一个下载目录里的两张封面
  ///    会互相覆盖对方的缩略图，`_freshThumbnailFile` 的 mtime 判断还可能
  ///    让它误认为"是这张图的缩略图"，于是显示**别人的图**。
  ///
  /// ## 键的构成
  ///
  /// `哈希(封面绝对路径 + 封面长度 + 封面 mtime)`：源图变化后键就变了，
  /// 于是**不会误用旧缩略图**（计划第 5 条的要求）。旧键的残留文件由
  /// 缓存目录整体清理，不影响正确性。
  static String thumbnailPathForCover(String coverPath) {
    return p.join(
        _thumbRoot().path, '${_thumbnailKey(coverPath)}$_coverThumbnailSuffix');
  }

  /// 缩略图根目录：`<App.dataPath>/local_library_cache/covers/thumbs`。
  static Directory _thumbRoot() {
    return Directory(
      p.join(
        LocalCoverCache.rootDirectory().path,
        _coverThumbnailDirName,
      ),
    );
  }

  static String _thumbnailKey(String coverPath) {
    var fingerprint = '0|0';
    try {
      final stat = File(coverPath).statSync();
      fingerprint = '${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    } catch (_) {}
    // 用与 LocalCoverCache 同一套稳定哈希，避免再引入一个哈希实现。
    return LocalCoverCache.stableHashForFileName(
        '$coverPath|$fingerprint|$derivativeAlgorithm');
  }

  static String displayPathForCover(String coverPath) {
    final thumbnail = _freshThumbnailFile(coverPath);
    return thumbnail?.path ?? coverPath;
  }

  static bool hasFreshThumbnail(String coverPath) {
    return _freshThumbnailFile(coverPath) != null;
  }

  static Future<String?> ensureForCoverPath(String coverPath) {
    final normalized = coverPath.trim();
    if (normalized.isEmpty) {
      return Future<String?>.value(null);
    }

    final fresh = _freshThumbnailFile(normalized);
    if (fresh != null) {
      return Future<String?>.value(fresh.path);
    }

    final existing = _pending[normalized];
    if (existing != null) {
      return existing;
    }

    final completer = Completer<String?>();
    if (_queue.length >= 32) {
      final removed = _queue.removeFirst();
      if (!removed.completer.isCompleted) removed.completer.complete(null);
    }
    _queue.add(
      _CoverThumbnailTask(
        coverPath: normalized,
        completer: completer,
      ),
    );
    final future = completer.future.whenComplete(() {
      _pending.remove(normalized);
    });
    _pending[normalized] = future;
    if (!_running) {
      unawaited(_drainQueue());
    }
    return future;
  }

  static Future<void> _drainQueue() async {
    if (_running) {
      return;
    }
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final task = _queue.removeFirst();
        try {
          final result = await _generateThumbnail(task.coverPath);
          if (!task.completer.isCompleted) {
            task.completer.complete(result);
          }
        } catch (_) {
          if (!task.completer.isCompleted) {
            task.completer.complete(null);
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 24));
      }
    } finally {
      _running = false;
      if (_queue.isNotEmpty) {
        unawaited(_drainQueue());
      }
    }
  }

  static File? _freshThumbnailFile(String coverPath) {
    try {
      final coverFile = File(coverPath);
      if (!coverFile.existsSync()) {
        return null;
      }
      final thumbFile = File(thumbnailPathForCover(coverPath));
      if (!thumbFile.existsSync()) {
        return null;
      }
      final coverStat = coverFile.statSync();
      final thumbStat = thumbFile.statSync();
      if (thumbStat.size <= 0) {
        return null;
      }
      if (thumbStat.modified.isBefore(coverStat.modified)) {
        return null;
      }
      return thumbFile;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _generateThumbnail(String coverPath) async {
    final fresh = _freshThumbnailFile(coverPath);
    if (fresh != null) {
      return fresh.path;
    }

    final coverFile = File(coverPath);
    if (!coverFile.existsSync()) {
      return null;
    }

    final stamp = await coverFile.stat();
    final generation = _publicationGeneration;
    ui.Image? image;
    File? temporary;
    ImageDiskReservation? diskReservation;
    try {
      image = await _decodeCoverImage(coverFile, kCoverThumbnailTargetWidth,
          sourceStat: stamp,
          taskKey:
              'legacy:$coverPath:${stamp.size}:${stamp.modified}:$generation',
          canContinue: () => generation == _publicationGeneration);
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      final pngBytes = byteData?.buffer.asUint8List();
      if (pngBytes == null || pngBytes.isEmpty) {
        return null;
      }
      final thumbPath = thumbnailPathForCover(coverPath);
      final thumbFile = File(thumbPath);
      await thumbFile.parent.create(recursive: true);
      diskReservation = await ImageDiskQuota.shared
          .admitPublication(thumbPath, maximumBytes: pngBytes.length);
      temporary =
          File('$thumbPath.${DateTime.now().microsecondsSinceEpoch}.part');
      await temporary.writeAsBytes(pngBytes, flush: true);
      final after = await coverFile.stat();
      if (generation != _publicationGeneration ||
          stamp.size != after.size ||
          stamp.modified != after.modified) {
        return null;
      }
      await temporary.rename(thumbPath);
      temporary = null;
      await diskReservation.commit([thumbPath]);
      _scheduleMaintenance(thumbPath);
      return thumbPath;
    } catch (_) {
      return null;
    } finally {
      try {
        image?.dispose();
      } catch (_) {}
      try {
        if (temporary != null) await temporary.delete();
      } catch (_) {}
      try {
        await diskReservation?.abort();
      } catch (_) {}
    }
  }
}

class _PreparedCoverProvider extends ImageProvider<_PreparedCoverProvider>
    implements BoundedCoverProvider {
  _PreparedCoverProvider(ui.Image? image, this.source, this.destination,
      this.identity, this.bucket,
      {required this.canContinue,
      required this.generation,
      required this.sourceStamp,
      required this.sourceSnapshot,
      this.trace,
      this.nativeEncodedFit = false,
      this.onPreparedImageConsumed})
      : _first = image {
    if (image != null) {
      _expiry = Timer(
          CoverThumbnailCache.preparedImageLifetimeForTesting ??
              const Duration(seconds: 5), () {
        _first?.dispose();
        _first = null;
      });
    }
  }
  final File source, destination;
  final String identity;
  final int bucket;
  final bool Function() canContinue;
  final int generation;
  final String sourceStamp;
  final FileStat sourceSnapshot;
  final bool nativeEncodedFit;
  final CoverThumbnailTrace? trace;
  final VoidCallback? onPreparedImageConsumed;
  ui.Image? _first;
  Timer? _expiry;

  bool get _current =>
      canContinue() && generation == CoverThumbnailCache._publicationGeneration;

  void _checkCurrent() {
    if (!_current) throw const ImageWorkCancelled();
  }

  Future<void> _verifySource() async {
    _checkCurrent();
    final stat = await source.stat();
    _checkCurrent();
    if (stat.type != FileSystemEntityType.file ||
        '${stat.size}|${stat.modified.microsecondsSinceEpoch}' != sourceStamp) {
      throw StateError('Cover source changed after provider preparation');
    }
  }

  Future<ImageInfo> _reload() async {
    await _verifySource();
    final retained = CoverThumbnailCache._clonePendingRaster(
        destination, sourceStamp, generation);
    if (retained != null) {
      trace?.details['pendingRasterHit'] = true;
      trace?.event('pendingRasterHit');
      IllustCoverDiagnostics.event('thumbnail.pendingRasterHit');
      CoverThumbnailCache._providerPersistenceConsumption[destination.path]
          ?.call();
      return ImageInfo(image: retained);
    }
    ui.Image? image;
    try {
      image = await CoverThumbnailCache._decodeCoverImage(source, bucket,
          // A scheduler result is one owned handle. Different stream loads
          // must not share that exact image without the paint-task clone path.
          taskKey: 'provider-reload:$identity:$generation:'
              '${++CoverThumbnailCache._providerReloadSequence}',
          canContinue: () => _current,
          nativeEncodedFit: nativeEncodedFit,
          trace: trace);
      await _verifySource();
      // A newly decoded cover can paint before its optional encoder starts.
      // Expiration/deletion recovery follows the same publication budget and
      // source verification as a normal cold prepared provider.
      final consumed = CoverThumbnailCache._prepareProviderPersistence(
          image, source, destination,
          stamp: sourceStamp,
          generation: generation,
          taskKey: 'provider-reload:$identity:$generation',
          trace: trace,
          bucket: bucket,
          nativeEncodedFit: nativeEncodedFit);
      consumed?.call();
      final owned = image;
      image = null;
      return ImageInfo(image: owned);
    } finally {
      image?.dispose();
    }
  }

  Future<ImageInfo> _loadWarm(
      ImageDecoderCallback decode, FileStat cachedStat) async {
    _checkCurrent();
    // Width is bucket-bounded, height is edge-bounded and the validated PNG
    // never exceeds 4 MP. Reserve the worst permitted output before allocating
    // its buffer, including decode/GPU handoff and encoded input copies.
    final outputPixels = math.min(bucket * 4096, 4 * 1024 * 1024);
    final estimate = outputPixels * 8 + cachedStat.size * 2 + (1 << 20);
    final queueWatch = trace == null ? null : (Stopwatch()..start());
    final queueStart = trace == null ? null : developer.Timeline.now;
    final releaseVisible =
        CoverThumbnailCache.deferProviderPersistenceForVisibleWork();
    try {
      final image = await (CoverThumbnailCache.warmSchedulerForTesting ??
              ImageWorkScheduler.shared)
          .submit<ui.Image>(
              // Each stream owns one image handle; do not deduplicate these
              // results across independently cancellable provider loads.
              key: 'cover-warm:$identity:$generation:'
                  '${++CoverThumbnailCache._providerReloadSequence}',
              // A displayed disk thumbnail can use the reserved foreground slot
              // instead of waiting behind a large original cover decode.
              priority: ImageWorkPriority.visible,
              estimatedBytes: estimate,
              disposeResult: (image) => image.dispose(),
              run: (cancel) async {
                if (queueWatch != null) {
                  trace!.stages.add({
                    'stage': 'warmQueueWait',
                    'elapsedUs': queueWatch.elapsedMicroseconds,
                    'timelineStartUs': queueStart!,
                    'timelineFinishUs': developer.Timeline.now,
                  });
                  trace!.details['warmJobEstimatedBytes'] = estimate;
                }
                cancel.throwIfCancelled();
                await _verifySource();
                return _decodeWarm(decode, cancel);
              })
          .future;
      return ImageInfo(image: image);
    } finally {
      releaseVisible();
    }
  }

  Future<ui.Image> _decodeWarm(
      ImageDecoderCallback decode, ImageWorkCancellation cancel) async {
    void checkCurrent() {
      cancel.throwIfCancelled();
      _checkCurrent();
    }

    checkCurrent();
    final buffer = await CoverThumbnailCache._measure(trace, 'warmBuffer',
        () => ui.ImmutableBuffer.fromFilePath(destination.path));
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    var transferredBuffer = false;
    try {
      checkCurrent();
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 ||
          descriptor.height <= 0 ||
          descriptor.width > bucket ||
          descriptor.width > 4096 ||
          descriptor.height > 4096 ||
          descriptor.width * descriptor.height > 4 * 1024 * 1024) {
        throw StateError('Cached cover dimensions exceed thumbnail limits');
      }
      descriptor.dispose();
      descriptor = null;
      checkCurrent();
      transferredBuffer = true;
      codec = await CoverThumbnailCache._measure(
          trace, 'warmCodec', () => decode(buffer));
      checkCurrent();
      image = (await CoverThumbnailCache._measure(
              trace, 'warmFirstFrame', codec!.getNextFrame))
          .image;
      checkCurrent();
      await _verifySource();
      checkCurrent();
      trace?.details
          .addAll({'decodedWidth': image.width, 'decodedHeight': image.height});
      final owned = image;
      image = null;
      return owned;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      // The decoder callback owns a transferred input buffer.
      if (!transferredBuffer) buffer.dispose();
    }
  }

  @override
  Future<_PreparedCoverProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
      _PreparedCoverProvider key, ImageDecoderCallback decode) {
    _expiry?.cancel();
    _expiry = null;
    final first = _first;
    _first = null;
    if (first != null) {
      // An already prepared image needs no new work admission. Scrolling can
      // pause its queue after decode and must not turn paintable pixels into an
      // error. A global invalidation still rejects the old publication.
      if (generation != CoverThumbnailCache._publicationGeneration) {
        first.dispose();
        return OneFrameImageStreamCompleter(
            Future<ImageInfo>.error(const ImageWorkCancelled()));
      }
      onPreparedImageConsumed?.call();
      return OneFrameImageStreamCompleter(
          SynchronousFuture(ImageInfo(image: first)));
    }
    Future<ImageInfo> load() async {
      await _verifySource();
      final before = await destination.stat();
      if (before.type != FileSystemEntityType.file) {
        return _reload();
      }
      try {
        return await _loadWarm(decode, before);
      } on ImageWorkCancelled {
        rethrow;
      } on ImageWorkQueueExceeded {
        rethrow;
      } on ImageWorkBudgetExceeded {
        rethrow;
      } catch (_) {
        // Repair a disposable thumbnail once. A true source/decode failure is
        // surfaced by _reload, never looped or converted into unrestricted IO.
        await _verifySource();
        trace?.event('warmThumbnailInvalidated');
        final current = await destination.stat();
        _checkCurrent();
        // A concurrent publisher may already have replaced the bad cache.
        // Only this application's unchanged disposable thumbnail is removed.
        if (p.isWithin(
                CoverThumbnailCache._thumbRoot().path, destination.path) &&
            current.type == FileSystemEntityType.file &&
            current.size == before.size &&
            current.modified == before.modified &&
            current.changed == before.changed) {
          try {
            await destination.delete();
          } on FileSystemException {
            // A concurrent cache eviction may already have removed the file.
          }
        }
        return _reload();
      }
    }

    return OneFrameImageStreamCompleter(load());
  }

  @override
  bool operator ==(Object other) =>
      other is _PreparedCoverProvider &&
      identity == other.identity &&
      generation == other.generation;
  @override
  int get hashCode => Object.hash(identity, generation);
}
