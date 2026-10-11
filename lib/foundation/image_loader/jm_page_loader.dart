import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/online_image/online_image_cache.dart';
import 'package:picakeep/network/http_image_body.dart';
import 'package:picakeep/network/managed_image_retry.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';

import 'jm_image_recombine.dart';
import 'reader_image_observation.dart';
import 'stream_image_provider.dart';

typedef JmPageRecombiner = Future<({Uint8List bytes, String extension})>
    Function(
  Uint8List bytes, {
  required String epsId,
  required String scrambleId,
  required String pictureName,
  String originalExtension,
});

/// A lease on the complete, correctly ordered page, never on a shuffled raw body.
class JmLoadedPage {
  JmLoadedPage._(
      this.file, this.byteLength, this.extension, this.mimeType, this._release);

  final File file;
  final int byteLength;
  final String extension;
  final String mimeType;
  final VoidCallback _release;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

class _JmPageRecord {
  const _JmPageRecord(this.file, this.length, this.extension, this.mime);
  final File file;
  final int length;
  final String extension, mime;
}

class _JmPageTransfer {
  final abort = StreamImageAbortSignal();
  final consumers = <Object>{};

  /// Shared by every consumer of this page transfer, including a differing
  /// reader mode or a consumer with no observer at all.
  late final observation =
      ReaderImageObservation(isCancelled: () => abort.isAborted);
  late Future<_JmPageRecord> future;
  VoidCallback? releaseFile;
  bool finished = false;

  void release(Object consumer) {
    consumers.remove(consumer);
    if (consumers.isNotEmpty) return;
    if (!finished) abort.abort();
    releaseFile?.call();
    releaseFile = null;
  }
}

/// The legacy JM loading contract: fetch -> recombine -> cache the whole page.
/// Raw and processed cache identities are intentionally different. A serial
/// admission precedes raw collection, not merely the recombination isolate:
/// queued pages cannot accumulate decoded RGBA or completed output in memory.
class JmPageLoader {
  JmPageLoader._() : _images = OnlineImageManager.instance;

  @visibleForTesting
  JmPageLoader.forTesting(
      {required OnlineImageManager images, JmPageRecombiner? recombine})
      : _images = images,
        _recombine = recombine;

  static final instance = JmPageLoader._();
  static const maximumRawBytes = 64 << 20;
  static const maximumOutputBytes = 128 << 20;
  static const maximumPending = 32;
  static const algorithmVersion = 'jm-lossless-whole-v1';
  static Future<void> _workTail = Future<void>.value();
  final OnlineImageManager _images;
  JmPageRecombiner? _recombine;
  final _transfers = <String, _JmPageTransfer>{};
  final _revisions = <String, int>{};
  int _nextRevision = 0;

  String _baseKey(String url, String cacheIdentity, Map<String, String> headers,
      String episodeId, String scrambleId, String pictureName) {
    final sorted = headers.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    final scope = sha256
        .convert(utf8.encode(jsonEncode(
            sorted.map((e) => [e.key.toLowerCase(), e.value]).toList())))
        .toString();
    return jsonEncode([
      algorithmVersion,
      cacheIdentity,
      scope,
      url,
      episodeId,
      scrambleId,
      pictureName
    ]);
  }

  String _key(String base) => _revisions[base] == null
      ? base
      : jsonEncode([base, 'page-revision', _revisions[base]]);

  /// Explicit retry forgets only this raw/processed page. An old consumer can
  /// keep its leased bytes; the retry writes another path and cannot overwrite it.
  Future<void> invalidatePage(
      {required String url,
      required String cacheIdentity,
      required Map<String, String> headers,
      required String episodeId,
      required String scrambleId,
      required String pictureName}) async {
    final base = _baseKey(
        url, cacheIdentity, headers, episodeId, scrambleId, pictureName);
    final oldKey = _key(base);
    final oldTransfer = _transfers[oldKey];
    _revisions.remove(base);
    _revisions[base] = ++_nextRevision;
    // Keep only revision numbers (not bytes/futures) for explicitly retried
    // pages for this loader's lifetime. Never recycle a still-leased old path.
    // Both revision changes happen synchronously before either metadata unlink
    // yields. A newly joining consumer must not combine new processed + old raw.
    final rawInvalidation = _images.invalidateImage(url,
        headers: headers,
        cacheIdentity: cacheIdentity,
        maximumBytes: maximumRawBytes);
    if (oldTransfer != null) {
      unawaited(oldTransfer.future.then<void>((_) async {
        await OnlineImageCache.instance.invalidate(oldKey);
      }, onError: (Object _, StackTrace __) {}).catchError((Object _) {}));
    }
    await Future.wait<void>([
      OnlineImageCache.instance.invalidate(oldKey),
      rawInvalidation,
    ]);
  }

  static void _check(StreamImageAbortSignal abort) {
    if (abort.isAborted) throw const ImageWorkCancelled();
  }

  Future<JmLoadedPage> load({
    required String url,
    required String cacheIdentity,
    required Map<String, String> headers,
    required String episodeId,
    required String scrambleId,
    required String pictureName,
    StreamImageAbortSignal? abortSignal,
  }) async {
    if (abortSignal?.isAborted == true) throw const ImageWorkCancelled();
    final key = _key(_baseKey(
        url, cacheIdentity, headers, episodeId, scrambleId, pictureName));
    var transfer = _transfers[key];
    if (transfer == null || transfer.abort.isAborted) {
      if (_transfers.length >= maximumPending) {
        throw const ImageWorkQueueExceeded(
            ImageWorkLane.execution, maximumPending);
      }
      transfer = _JmPageTransfer();
      final active = transfer;
      _transfers[key] = active;
      active.future = _produce(key, active,
              url: url,
              rawIdentity: cacheIdentity,
              headers: headers,
              episodeId: episodeId,
              scrambleId: scrambleId,
              pictureName: pictureName)
          .whenComplete(() {
        active.finished = true;
        if (identical(_transfers[key], active)) _transfers.remove(key);
        if (active.consumers.isEmpty) {
          active.releaseFile?.call();
          active.releaseFile = null;
        }
      });
      // Cancellation can remove every listener before queued work unwinds.
      unawaited(active.future
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    }
    final active = transfer;
    final consumer = Object();
    active.consumers.add(consumer);
    void releaseConsumer() {
      active.release(consumer);
      if (active.consumers.isEmpty &&
          active.abort.isAborted &&
          identical(_transfers[key], active)) {
        _transfers.remove(key);
      }
    }

    if (abortSignal != null) {
      unawaited(abortSignal.aborted.then((_) => releaseConsumer()));
    }
    try {
      final record = await (abortSignal == null
          ? active.future
          : Future.any<_JmPageRecord>([
              active.future,
              abortSignal.aborted
                  .then<_JmPageRecord>((_) => throw const ImageWorkCancelled())
            ]));
      if (abortSignal?.isAborted == true) throw const ImageWorkCancelled();
      forwardReaderImageFacts(active.observation);
      final release = OnlineImageCache.instance.lease(record.file);
      return JmLoadedPage._(
          record.file, record.length, record.extension, record.mime, release);
    } catch (error, stack) {
      // Surface the shared transfer's real stage to this consumer, whose first
      // consumer (another mode/reader) may have had no observer at all.
      forwardReaderImageStage(active.observation, error, stack);
      rethrow;
    } finally {
      releaseConsumer();
    }
  }

  Future<_JmPageRecord?> _cached(String key, _JmPageTransfer transfer) async {
    _check(transfer.abort);
    final cached = await OnlineImageCache.instance.get(key);
    observeReaderImageFacts(processedCacheHit: cached != null);
    _check(transfer.abort);
    if (cached == null) return null;
    final release = OnlineImageCache.instance.lease(cached.file);
    try {
      // A known completed cache file read is a cache boundary.
      final length = await observeReaderImageStage(
          ReaderImageStage.cache, () => cached.file.length());
      if (length <= 0 || length > maximumOutputBytes) {
        throw observeReaderImageReason(
            StateError('Invalid cached JM whole page size'),
            length <= 0
                ? ReaderImageReason.emptyInput
                : ReaderImageReason.inputLimit);
      }
      _check(transfer.abort);
      transfer.releaseFile = release;
      return _JmPageRecord(cached.file, length,
          '.${cached.file.path.split('.').last}', cached.contentType);
    } catch (error, stack) {
      if (!transfer.abort.isAborted) {
        observeReaderImageFailure(ReaderImageStage.cache, error, stack);
      }
      release();
      rethrow;
    }
  }

  Future<_JmPageRecord> _produce(
    String key,
    _JmPageTransfer transfer, {
    required String url,
    required String rawIdentity,
    required Map<String, String> headers,
    required String episodeId,
    required String scrambleId,
    required String pictureName,
  }) =>
      ReaderImageObservation.run(transfer.observation, () async {
        final cached = await _cached(key, transfer);
        if (cached != null) return cached;
        final previous = _workTail;
        final finished = Completer<void>();
        _workTail = finished.future;
        var stage = 'queued', rawCount = 0, outputCount = 0;
        try {
          await previous;
          _check(transfer.abort);
          final nowCached = await _cached(key, transfer);
          if (nowCached != null) return nowCached;
          stage = 'raw';
          // Processed pages are shared across both reader modes; transport retry
          // ownership cannot depend on which mode happened to create this job first.
          final response = await runWithManagedImageRetry(() =>
              _images.getImage(url,
                  headers: headers,
                  cacheIdentity: rawIdentity,
                  abortSignal: transfer.abort,
                  maximumBytes: maximumRawBytes));
          final builder = BytesBuilder(copy: false);
          await for (final chunk in response.stream) {
            _check(transfer.abort);
            rawCount += chunk.length;
            if (rawCount > maximumRawBytes) {
              throw observeReaderImageReason(
                  StateError('JM raw page exceeds the input budget'),
                  ReaderImageReason.inputLimit);
            }
            builder.add(chunk);
          }
          _check(transfer.abort);
          if (rawCount == 0) {
            throw observeReaderImageReason(
                StateError('Empty JM image response'),
                ReaderImageReason.emptyInput);
          }
          final raw = builder.takeBytes();
          final rawType = readerPageTypeFromHeader(raw);
          stage = 'recombine';
          // JM recombine invocation plus output validation is a transform boundary.
          final recombined = await observeReaderImageStage(
              ReaderImageStage.transform, () async {
            final result = await (_recombine ?? JmRecombine.recombine)(raw,
                epsId: episodeId,
                scrambleId: scrambleId,
                pictureName: pictureName,
                originalExtension: rawType.extension);
            _check(transfer.abort);
            outputCount = result.bytes.length;
            if (outputCount == 0 || outputCount > maximumOutputBytes) {
              throw observeReaderImageReason(
                  StateError('JM whole page exceeds the output budget'),
                  outputCount == 0
                      ? ReaderImageReason.emptyInput
                      : ReaderImageReason.transformOutputLimit);
            }
            return result;
          });
          final type = readerPageTypeFromHeader(recombined.bytes);
          stage = 'publish';
          final file = await OnlineImageCache.instance.putStream(
              key, Stream<List<int>>.value(recombined.bytes),
              contentType: type.mime,
              expectedBytes: outputCount,
              maximumBytes: maximumOutputBytes,
              isCancelled: () => transfer.abort.isAborted);
          _check(transfer.abort);
          transfer.releaseFile = OnlineImageCache.instance.lease(file);
          return _JmPageRecord(file, outputCount, type.extension, type.mime);
        } catch (error) {
          if (error is! ImageWorkCancelled && !transfer.abort.isAborted) {
            LogManager.addLog(
                LogLevel.error,
                'JmPageLoad',
                jsonEncode({
                  'stage': stage,
                  'errorType': error.runtimeType.toString(),
                  'rawBytes': rawCount,
                  'outputBytes': outputCount,
                  if (error is HttpImageBodyException) ...{
                    'reason': error.reason,
                    if (error.expected != null) 'expectedBytes': error.expected,
                    if (error.received != null) 'receivedBytes': error.received,
                  } else if (error is JmRecombineLimit) ...{
                    'reason': error.reason,
                    'encodedBytes': error.encodedBytes,
                    if (error.width != null) 'width': error.width,
                    if (error.height != null) 'height': error.height,
                    if (error.estimatedWorkingBytes != null)
                      'estimatedWorkingBytes': error.estimatedWorkingBytes,
                    'maximumWorkingBytes': error.maximumWorkingBytes,
                  },
                }));
          }
          rethrow;
        } finally {
          finished.complete();
        }
      });
}

/// Opens the leased final cache file directly, without reserving an unknown
/// 512 MiB stream workspace or making a second temporary copy of every page.
class JmReaderPageSource extends DeferredReaderPageSource {
  factory JmReaderPageSource(
      {required ReaderPageIdentity identity,
      required Future<JmLoadedPage> Function(StreamImageAbortSignal) load}) {
    final holder = _JmSourceHolder();
    return JmReaderPageSource._(identity, holder, load);
  }

  JmReaderPageSource._(ReaderPageIdentity identity, this._holder,
      Future<JmLoadedPage> Function(StreamImageAbortSignal) load)
      : super(
            identity: identity,
            ownsFile: false,
            opener: (cancellation) async {
              final abort = StreamImageAbortSignal();
              if (cancellation.isCancelled) abort.abort();
              unawaited(cancellation.cancelled.then((_) => abort.abort()));
              final page = await load(abort);
              _holder.page = page;
              cancellation.throwIfCancelled();
              return page.file;
            },
            onDispose: () => _holder.page?.release());

  final _JmSourceHolder _holder;
  @override
  String? get extension => _holder.page?.extension;
  @override
  String? get mimeType => _holder.page?.mimeType;
  @override
  int? get byteLength => _holder.page?.byteLength;
}

class _JmSourceHolder {
  JmLoadedPage? page;
}
