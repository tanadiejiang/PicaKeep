import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';

import 'package:path/path.dart' as p;

import '../app.dart';
import 'derived_image_store.dart';
import 'image_work_scheduler.dart';
import 'reader_viewport.dart';
import 'reader_page_source.dart';
import 'reader_raster_diagnostics.dart';

class ReaderRasterCacheIdentity {
  const ReaderRasterCacheIdentity(this.key);
  final DerivedImageKey key;
}

/// Reproducible local lossless rasters. Source byte stamp and complete geometry
/// are part of every key; a URL, backing filename or page index is insufficient.
class ReaderRasterCache {
  static final Map<String, DerivedImageStore> _stores = {};
  static final Map<String, Future<void>> _writes = {};
  static const maximumPixels = 4 * 1024 * 1024;
  static const maximumPendingBytes = 32 << 20;
  static int _pendingBytes = 0;
  static int get pendingBytes => _pendingBytes;

  static DerivedImageStore _store() {
    final root =
        p.join(App.dataPath, 'cache', 'image_pipeline_v1', 'local_reader');
    return _stores.putIfAbsent(root, () => DerivedImageStore(root));
  }

  static Future<DerivedImageKey?> _key(File file, ReaderTileDemand demand,
      {String pixelVersion =
          'native-srgb-premultiplied-rgba8-fit-filter-v4'}) async {
    if (demand.outputWidth * demand.outputHeight > maximumPixels) return null;
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) return null;
    return DerivedImageKey(
        namespace: 'local-reader-raster',
        resourceId: p.normalize(p.absolute(file.path)),
        sourceVersion:
            '${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}',
        usage: demand.column < 0 || demand.row < 0
            ? DerivedImageUsage.readerLevel
            : DerivedImageUsage.readerTile,
        variant:
            '${demand.rasterRect.left}:${demand.rasterRect.top}:${demand.rasterRect.width}:'
            '${demand.rasterRect.height}:${demand.outputWidth}:${demand.outputHeight}:$pixelVersion');
  }

  /// Capture before native decode so an old raster can never be stamped with
  /// a source that was replaced while decoding or waiting for persistence.
  static Future<ReaderRasterCacheIdentity?> capture(
      File file, ReaderTileDemand demand,
      {String pixelVersion =
          'native-srgb-premultiplied-rgba8-fit-filter-v4'}) async {
    final key = await _key(file, demand, pixelVersion: pixelVersion);
    return key == null ? null : ReaderRasterCacheIdentity(key);
  }

  static Future<ui.Image?> load(File file, ReaderTileDemand demand,
      {required String backingPath,
      bool Function()? isCancelled,
      String pixelVersion =
          'native-srgb-premultiplied-rgba8-fit-filter-v4'}) async {
    final lookupClock = Stopwatch()..start();
    final store = _store();
    final key = await _key(file, demand, pixelVersion: pixelVersion);
    if (key == null || isCancelled?.call() == true) return null;
    final entry = await store.lookup(key);
    ReaderRasterDiagnostics.record({
      'rasterCacheLookupUs': lookupClock.elapsedMicroseconds,
      'rasterCacheEntryFound': entry == null ? 0 : 1,
    });
    if (entry == null ||
        entry.mimeType != 'image/png' ||
        !entry.lossless ||
        entry.width != demand.outputWidth ||
        entry.height != demand.outputHeight) {
      return null;
    }
    final lease = store.lease(entry);
    final decodeClock = Stopwatch()..start();
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? ownedImage;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(entry.path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width != demand.outputWidth ||
          descriptor.height != demand.outputHeight) {
        return null;
      }
      codec = await descriptor.instantiateCodec();
      final image = (await codec.getNextFrame()).image;
      ownedImage = image;
      final current = await _key(file, demand, pixelVersion: pixelVersion);
      if (isCancelled?.call() == true || current?.token != key.token) {
        return null;
      }
      ownedImage = null;
      return image;
    } catch (_) {
      return null;
    } finally {
      ownedImage?.dispose();
      ReaderRasterDiagnostics.record({
        'rasterCacheDecodeUs': decodeClock.elapsedMicroseconds,
      });
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
      lease.release();
    }
  }

  /// Clones immediately, then encodes/writes after the caller can paint. Queue
  /// admission and work are bounded; failure never changes the displayed image.
  static void save(File file, ReaderTileDemand demand, ui.Image image,
      {required String backingPath,
      required ReaderRasterCacheIdentity identity,
      String pixelVersion = 'native-srgb-premultiplied-rgba8-fit-filter-v4'}) {
    if (image.width != demand.outputWidth ||
        image.height != demand.outputHeight ||
        image.width * image.height > maximumPixels ||
        _writes.length >= 32 ||
        _pendingBytes + image.width * image.height * 4 > maximumPendingBytes) {
      return;
    }
    final store = _store();
    final generation = store.generation;
    final inputPath = file.path;
    final workKey = '${store.root}:$inputPath:${demand.variant}:$pixelVersion';
    if (_writes.containsKey(workKey)) return;
    final clone = image.clone();
    final retainedBytes = clone.width * clone.height * 4;
    _pendingBytes += retainedBytes;
    final releaseCache = DerivedImageStore.protectTemporaryPath(inputPath);
    final releaseOriginal = ReaderPageFileLease.acquire(file);
    final afterPaint = Completer<bool>();
    // An idle/closed surface must not keep an original alive indefinitely.
    final paintTimeout = Timer(const Duration(seconds: 2), () {
      if (!afterPaint.isCompleted) afterPaint.complete(false);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!afterPaint.isCompleted) afterPaint.complete(true);
    });
    final writing = () async {
      try {
        if (!await afterPaint.future) return;
        paintTimeout.cancel();
        // Move encoder work to the event after that frame has painted.
        await Future<void>(() {});
        final key = await _key(file, demand, pixelVersion: pixelVersion);
        if (key == null ||
            key.token != identity.key.token ||
            generation != store.generation) {
          return;
        }
        final finished = Completer<void>();
        var started = false;
        final ticket = ImageWorkScheduler.shared.submit<void>(
            key: 'reader-raster-persist:$workKey',
            priority: ImageWorkPriority.background,
            estimatedBytes: clone.width * clone.height * 12 + (32 << 20),
            run: (cancel) async {
              started = true;
              try {
                if (cancel.isCancelled || generation != store.generation) {
                  return;
                }
                final encodeClock = Stopwatch()..start();
                ReaderRasterDiagnostics.record({
                  'rasterCachePngEncodeStartedUs': developer.Timeline.now,
                  'rasterCachePngEncodePixels': clone.width * clone.height,
                });
                ByteData? bytes;
                try {
                  bytes =
                      await clone.toByteData(format: ui.ImageByteFormat.png);
                } finally {
                  ReaderRasterDiagnostics.record({
                    'rasterCachePngEncodeEndedUs': developer.Timeline.now,
                    'rasterCachePngEncodeWallUs':
                        encodeClock.elapsedMicroseconds,
                    'rasterCachePngEncodeBytes': bytes?.lengthInBytes ?? 0,
                  });
                }
                if (bytes == null ||
                    cancel.isCancelled ||
                    generation != store.generation) {
                  return;
                }
                final current =
                    await _key(file, demand, pixelVersion: pixelVersion);
                if (current?.token != key.token) return;
                await store.put(
                    key: key,
                    content: Stream.value(bytes.buffer.asUint8List()),
                    mimeType: 'image/png',
                    width: clone.width,
                    height: clone.height,
                    lossless: true,
                    maximumBytes: bytes.lengthInBytes,
                    canPublish: () =>
                        !cancel.isCancelled && generation == store.generation);
              } finally {
                if (!finished.isCompleted) finished.complete();
              }
            });
        try {
          await ticket.future;
        } finally {
          // A cancelled ticket can finish while the raster encoder still uses
          // this clone. Keep it and the source lease until actual run ends.
          if (started) await finished.future;
        }
      } catch (_) {
        // The original image and backing remain authoritative on failure.
      } finally {
        clone.dispose();
        paintTimeout.cancel();
        _pendingBytes -= retainedBytes;
        releaseCache();
        releaseOriginal();
        _writes.remove(workKey);
      }
    }();
    _writes[workKey] = writing;
    unawaited(writing);
  }

  static Future<void> drain() async {
    while (_writes.isNotEmpty) {
      await Future.wait(_writes.values.toList());
    }
  }
}
