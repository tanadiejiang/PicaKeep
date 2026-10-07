import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'derived_image_store.dart';
import 'image_derivative_renderer.dart';
import 'image_work_scheduler.dart';
import 'image_disk_quota.dart';

class ImageDerivativePreparation {
  const ImageDerivativePreparation({this.entry, this.error, this.busy = false});
  final DerivedImageEntry? entry;
  final Object? error;
  final bool busy;
  bool get isPreparing => entry == null && error == null;
}

class _PreparationJob {
  _PreparationJob(this.ticket);
  final ImageWorkTicket<DerivedImageEntry?> ticket;
  Timer? expiry;
}

/// A polling HTTP response owns a short lease on work, not the work's lifetime.
class ImageDerivativeService {
  ImageDerivativeService(
      {required this.store,
      required this.renderer,
      ImageWorkScheduler? scheduler,
      this.maximumPending = 32,
      this.jobLease = const Duration(seconds: 20),
      this.responseWait = const Duration(milliseconds: 120)})
      : scheduler = scheduler ?? ImageWorkScheduler.shared;
  final DerivedImageStore store;
  final ImageDerivativeRenderer renderer;
  final ImageWorkScheduler scheduler;
  final int maximumPending;
  final Duration jobLease, responseWait;
  final Map<String, _PreparationJob> _jobs = {};
  bool _disposed = false;

  int get pendingCount => _jobs.length;

  Future<ImageDerivativePreparation> prepare({
    required String sourcePath,
    required DerivedImageKey key,
    required ImageDerivativeRect region,
    required int width,
    required int height,
    required String format,
    required Future<bool> Function() isSourceCurrent,
    void Function() Function()? acquireSource,
    int estimatedWorkingBytes = 64 * 1024 * 1024,
    ImageWorkPriority priority = ImageWorkPriority.visible,
  }) async {
    if (_disposed) {
      return const ImageDerivativePreparation(error: 'service stopped');
    }
    final cached = await store.lookup(key);
    if (cached != null && await isSourceCurrent()) {
      return ImageDerivativePreparation(entry: cached);
    }
    final jobKey = '${store.root}::${key.token}';
    var job = _jobs[jobKey];
    if (job == null) {
      if (_jobs.length >= maximumPending) {
        return const ImageDerivativePreparation(busy: true);
      }
      final generation = store.generation;
      final releaseSource = acquireSource?.call();
      var started = false;
      var sourceReleased = false;
      void releaseInput() {
        if (sourceReleased) return;
        sourceReleased = true;
        releaseSource?.call();
      }

      final ticket = scheduler.submit<DerivedImageEntry?>(
          servesNetwork: true,
          key: jobKey,
          priority: priority,
          estimatedBytes: estimatedWorkingBytes + width * height * 24,
          run: (cancellation) async {
            started = true;
            try {
              bool cancelled() =>
                  _disposed ||
                  cancellation.isCancelled ||
                  store.generation != generation;
              if (cancelled() || !await isSourceCurrent()) return null;
              final workRoot = Directory(p.join(store.root, 'work'));
              await workRoot.create(recursive: true);
              final resourceBacking = DerivedImageKey(
                      namespace: key.namespace,
                      resourceId: key.resourceId,
                      sourceVersion: key.sourceVersion,
                      usage: DerivedImageUsage.readerTile,
                      variant: 'normalized-backing-v1')
                  .token;
              final backingPath =
                  p.join(workRoot.path, '$resourceBacking.pixels');
              final releaseBacking = store.protectOwnedPath(backingPath);
              ImageDiskReservation? backingHold;
              try {
                backingHold = await ImageDiskQuota.shared
                    .admitWorkspace(backingPath, peakBytes: 1);
                await backingHold.finishWorkspace();
                final raster = await renderer.render(sourcePath,
                    region: region,
                    width: width,
                    height: height,
                    format: format,
                    backingPath: backingPath,
                    jobBudgetBytes: estimatedWorkingBytes + width * height * 4,
                    isCancelled: cancelled);
                if (cancelled() || !await isSourceCurrent()) return null;
                return await store.put(
                    key: key,
                    content: Stream.value(raster.bytes),
                    mimeType: raster.mimeType,
                    width: raster.width,
                    height: raster.height,
                    lossless: raster.lossless,
                    maximumBytes: math.min(
                        32 * 1024 * 1024, math.max(65536, raster.bytes.length)),
                    canPublish: () => !cancelled());
              } finally {
                releaseBacking();
                if (cancelled()) {
                  try {
                    final file = File(backingPath);
                    if (await file.exists()) await file.delete();
                  } catch (_) {}
                }
                await backingHold?.abort();
              }
            } finally {
              releaseInput();
            }
          });
      job = _PreparationJob(ticket);
      _jobs[jobKey] = job;
      if (releaseSource != null) {
        // Cancellation completes a consumer ticket before native IO ends.
        // A running job releases its source only in its own finally block.
        unawaited(ticket.future.then<void>((_) {
          if (!started) releaseInput();
        }, onError: (Object _, StackTrace __) {
          if (!started) releaseInput();
        }));
      }
      unawaited(ticket.future.then<void>((_) => _finish(jobKey, ticket),
          onError: (Object _, StackTrace __) => _finish(jobKey, ticket)));
    }
    job.expiry?.cancel();
    job.expiry = Timer(jobLease, () {
      if (identical(_jobs[jobKey], job)) {
        _jobs.remove(jobKey);
        job!.ticket.cancel();
      }
    });
    try {
      final entry = await job.ticket.future.timeout(responseWait);
      if (entry == null) {
        return const ImageDerivativePreparation(
            error: 'source changed or request cancelled');
      }
      return ImageDerivativePreparation(entry: entry);
    } on TimeoutException {
      return const ImageDerivativePreparation();
    } catch (error) {
      return ImageDerivativePreparation(error: error);
    }
  }

  void _finish(String key, ImageWorkTicket<DerivedImageEntry?> ticket) {
    final job = _jobs[key];
    if (job == null || !identical(job.ticket, ticket)) return;
    job.expiry?.cancel();
    _jobs.remove(key);
  }

  void dispose() {
    _disposed = true;
    for (final job in _jobs.values) {
      job.expiry?.cancel();
      job.ticket.cancel();
    }
    _jobs.clear();
    store.dispose();
  }
}
