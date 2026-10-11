import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:picakeep/foundation/image_loader/reader_image_observation.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/network/app_dio.dart';
import 'package:picakeep/network/http_image_body.dart';
import 'package:picakeep/network/managed_image_retry.dart';
import 'package:picakeep/network/online_image/online_image_cache.dart';

class OnlineImageLoadResult {
  const OnlineImageLoadResult({required this.stream, this.expectedTotalBytes});
  final Stream<List<int>> stream;
  final int? expectedTotalBytes;
}

class _ImageTransfer {
  final cancelToken = CancelToken();
  final headers = Completer<int?>();
  final file = Completer<File>();
  final consumers = <Object>{};

  /// Shared by every consumer of this transfer, including one that joins after
  /// a different (or absent) first observer. Bounded, operation-scoped relay.
  final observation = ReaderImageObservation();
}

class OnlineImageManager {
  OnlineImageManager._() : _dio = logDio();
  @visibleForTesting
  OnlineImageManager.forTesting(this._dio);
  static final OnlineImageManager instance = OnlineImageManager._();
  final Dio _dio;
  final _inFlight = <String, _ImageTransfer>{};
  final _revisions = <String, int>{};
  int _nextRevision = 0;

  String _baseKey(String url, Map<String, String>? headers, String? identity,
      int maximumBytes) {
    final entries = (headers?.entries.toList() ?? [])
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    final scope = sha256
        .convert(utf8.encode(jsonEncode(
            entries.map((e) => [e.key.toLowerCase(), e.value]).toList())))
        .toString();
    // Different resource policies must not share either a transfer or a .part.
    // Keep the historical default identity, including account/header isolation.
    return jsonEncode([
      'online-image-v2',
      identity ?? url,
      scope,
      if (maximumBytes != OnlineImageCache.maxInputBytes) maximumBytes,
    ]);
  }

  String _key(String url, Map<String, String>? headers, String? identity,
      int maximumBytes,
      {bool? managed}) {
    final base = _baseKey(url, headers, identity, maximumBytes);
    final revision = _revisions[base];
    if (revision == null && !(managed ?? isManagedImageRetry)) return base;
    return jsonEncode([
      base,
      if (revision != null) ['page-revision', revision],
      if (managed ?? isManagedImageRetry) 'reader-managed-retry-v1',
    ]);
  }

  /// New readers use a fresh path; existing consumers retain their transfer
  /// and file leases. Invalidation never touches another account or download.
  Future<void> invalidateImage(
    String url, {
    Map<String, String>? headers,
    String? cacheIdentity,
    int maximumBytes = OnlineImageCache.maxInputBytes,
  }) async {
    final previous = [
      _key(url, headers, cacheIdentity, maximumBytes, managed: false),
      _key(url, headers, cacheIdentity, maximumBytes, managed: true),
    ];
    final base = _baseKey(url, headers, cacheIdentity, maximumBytes);
    _revisions.remove(base);
    _revisions[base] = ++_nextRevision;
    // Keep this small index of manually invalidated pages for this manager's
    // lifetime: falling back to revision zero could revive a late publication
    // or collide with its still-leased body. No bytes or futures are retained.
    for (final identity in previous) {
      final transfer = _inFlight[identity];
      if (transfer != null) {
        // An existing consumer is entitled to finish, but that retired writer
        // must not recreate a completed record after the initial invalidation.
        unawaited(transfer.file.future
            .then<void>((_) {}, onError: (Object _, StackTrace __) {})
            .then((_) => OnlineImageCache.instance.invalidate(identity))
            .catchError((Object error) {
          debugPrint(
              'Retired image metadata cleanup failed: ${error.runtimeType}');
        }));
      }
      await OnlineImageCache.instance.invalidate(identity);
    }
  }

  Future<File> getImageFile(
    String url, {
    Map<String, String>? headers,
    StreamImageAbortSignal? abortSignal,
    String? cacheIdentity,
    int maximumBytes = OnlineImageCache.maxInputBytes,
  }) async {
    final acquired = await _acquire(url,
        headers: headers,
        abortSignal: abortSignal,
        cacheIdentity: cacheIdentity,
        maximumBytes: maximumBytes);
    try {
      return await acquired.file;
    } finally {
      acquired.release();
    }
  }

  Future<StreamImageLoadResult> getImage(
    String url, {
    Map<String, String>? headers,
    StreamImageAbortSignal? abortSignal,
    String? cacheIdentity,
    int maximumBytes = OnlineImageCache.maxInputBytes,
  }) async {
    final acquired = await _acquire(url,
        headers: headers,
        abortSignal: abortSignal,
        cacheIdentity: cacheIdentity,
        maximumBytes: maximumBytes);
    var discarded = false;
    Stream<List<int>> stream() async* {
      try {
        if (discarded) throw StateError('Image load aborted');
        final file = await acquired.file;
        if (discarded || abortSignal?.isAborted == true) {
          throw StateError('Image load aborted');
        }
        final releaseFile = OnlineImageCache.instance.lease(file);
        try {
          await for (final chunk in file.openRead()) {
            if (discarded || abortSignal?.isAborted == true) {
              throw StateError('Image load aborted');
            }
            yield chunk;
          }
        } catch (error, stack) {
          if (!discarded && abortSignal?.isAborted != true) {
            // A known completed cache file read is a cache boundary.
            observeReaderImageFailure(ReaderImageStage.cache, error, stack);
          }
          rethrow;
        } finally {
          releaseFile();
        }
      } finally {
        acquired.release();
      }
    }

    return StreamImageLoadResult(
        stream: stream(),
        expectedTotalBytes: acquired.length,
        cancel: () async {
          discarded = true;
          acquired.release();
        });
  }

  Future<({Future<File> file, int? length, void Function() release})> _acquire(
    String url, {
    Map<String, String>? headers,
    StreamImageAbortSignal? abortSignal,
    String? cacheIdentity,
    required int maximumBytes,
  }) async {
    if (maximumBytes <= 0 || maximumBytes > OnlineImageCache.maxInputBytes) {
      throw ArgumentError.value(maximumBytes, 'maximumBytes');
    }
    if (abortSignal?.isAborted == true) throw StateError('Image load aborted');
    final key = _key(url, headers, cacheIdentity, maximumBytes);
    final cached = await OnlineImageCache.instance.get(key);
    observeReaderImageFacts(onlineCacheHit: cached != null);
    if (abortSignal?.isAborted == true) throw StateError('Image load aborted');
    if (cached != null) {
      final release = OnlineImageCache.instance.lease(cached.file);
      try {
        // A known completed cache file read is a cache boundary.
        final length = await observeReaderImageStage(
            ReaderImageStage.cache, () => cached.file.length());
        if (abortSignal?.isAborted == true) {
          throw StateError('Image load aborted');
        }
        if (length == 0 || length > maximumBytes) {
          throw observeReaderImageReason(
              StateError('Cached image exceeds input limit or is empty'),
              length == 0
                  ? ReaderImageReason.emptyInput
                  : ReaderImageReason.inputLimit);
        }
        if (abortSignal != null) {
          unawaited(abortSignal.aborted.then((_) => release()));
        }
        return (
          file: Future.value(cached.file),
          length: length,
          release: release
        );
      } catch (error, stack) {
        if (abortSignal?.isAborted != true) {
          observeReaderImageFailure(ReaderImageStage.cache, error, stack);
        }
        release();
        rethrow;
      }
    }
    var transfer = _inFlight[key];
    // The last consumer can cancel just before a new one arrives. Let the
    // retired writer unwind before reusing its cache destination on retry.
    if (transfer?.cancelToken.isCancelled == true) {
      try {
        await transfer!.file.future;
      } catch (_) {}
      return _acquire(url,
          headers: headers,
          abortSignal: abortSignal,
          cacheIdentity: cacheIdentity,
          maximumBytes: maximumBytes);
    }
    final ownsStream = transfer == null;
    transfer ??= _ImageTransfer();
    final active = transfer;
    final consumer = Object();
    active.consumers.add(consumer);
    bool released = false;
    void release() {
      if (released) return;
      released = true;
      active.consumers.remove(consumer);
      if (active.consumers.isEmpty && !active.file.isCompleted) {
        active.cancelToken.cancel('Image consumers left');
      }
    }

    if (abortSignal != null) {
      unawaited(abortSignal.aborted.then((_) => release()));
    }
    if (ownsStream) {
      active.observation
          .mergeFacts(const ReaderImageFacts(onlineCacheHit: false));
      // Header failures can precede the first body subscription.
      unawaited(active.file.future
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      _inFlight[key] = active;
      unawaited(_download(url, key, headers, active, maximumBytes));
    }
    try {
      final length = await (abortSignal == null
          ? active.headers.future
          : Future.any<int?>([
              active.headers.future,
              abortSignal.aborted
                  .then<int?>((_) => throw StateError('Image load aborted')),
            ]));
      if (abortSignal?.isAborted == true) {
        release();
        throw StateError('Image load aborted');
      }
      Future<File> relayFile(Future<File> pending) async {
        try {
          final file = await pending;
          if (abortSignal?.isAborted != true) {
            forwardReaderImageFacts(active.observation);
          }
          return file;
        } catch (error, stack) {
          // Body/publication errors arrive AFTER _acquire returned its headers.
          // Relay in this consumer's Zone, not the first downloader's Zone.
          if (abortSignal?.isAborted != true) {
            forwardReaderImageStage(active.observation, error, stack);
          }
          rethrow;
        }
      }

      final file = relayFile(abortSignal == null
          ? active.file.future
          : Future.any<File>([
              active.file.future,
              abortSignal.aborted
                  .then<File>((_) => throw StateError('Image load aborted')),
            ]));
      // The stream may be subscribed only after cancellation/body failure.
      unawaited(file.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      return (file: file, length: length, release: release);
    } catch (error, stack) {
      // Surface the shared transfer's real innermost stage to this consumer,
      // whose first consumer may have had no observer at all.
      forwardReaderImageStage(active.observation, error, stack);
      release();
      rethrow;
    }
  }

  Stream<List<int>> getImageBytes(
    String url, {
    Map<String, String>? headers,
    StreamImageAbortSignal? abortSignal,
    String? cacheIdentity,
    int maximumBytes = OnlineImageCache.maxInputBytes,
  }) async* {
    final result = await getImage(url,
        headers: headers,
        abortSignal: abortSignal,
        cacheIdentity: cacheIdentity,
        maximumBytes: maximumBytes);
    yield* result.stream;
  }

  Future<void> _download(String url, String key, Map<String, String>? headers,
          _ImageTransfer transfer, int maximumBytes) =>
      ReaderImageObservation.run(transfer.observation, () async {
        // Cancellation is set by cleanup for EVERY failure, so the real cause
        // must be captured at the boundary BEFORE that call.
        void recordFetch(Object error, StackTrace stack) {
          if (transfer.cancelToken.isCancelled) return;
          observeReaderImageFailure(ReaderImageStage.fetch, error, stack);
        }

        try {
          late final ResponseBody body;
          late final HttpImageBodyContract contract;
          late final String contentType;
          try {
            final response = await _dio.get<ResponseBody>(url,
                options: Options(
                    headers: headers, responseType: ResponseType.stream),
                cancelToken: transfer.cancelToken);
            observeReaderImageFacts(
                httpStatusClass: readerHttpStatusClass(response.statusCode));
            final received = response.data;
            if (received == null) {
              throw const HttpImageBodyException('empty-body');
            }
            body = received;
            contract = HttpImageBodyContract.fromHeaders(response.headers.map,
                maximumBytes: maximumBytes);
            contentType = response.headers.value('content-type') ?? '';
          } catch (error, stack) {
            // Only a typed actual response supplies a status; no text parsing.
            if (error is DioException && error.response?.statusCode != null) {
              observeReaderImageFacts(
                  httpStatusClass:
                      readerHttpStatusClass(error.response!.statusCode));
            }
            // Request/header/transport failure = fetch.
            recordFetch(error, stack);
            rethrow;
          }
          transfer.headers.complete(contract.expectedBytes);
          Stream<List<int>> chunks() async* {
            try {
              await for (final chunk in contract
                  .validate(body.stream.timeout(const Duration(seconds: 30)))) {
                if (transfer.cancelToken.isCancelled) {
                  throw StateError('Image load aborted');
                }
                yield chunk;
              }
              if (transfer.cancelToken.isCancelled) {
                throw StateError('Image load aborted');
              }
            } catch (error, stack) {
              // HTTP body validation/transport while consumed = fetch.
              recordFetch(error, stack);
              rethrow;
            }
          }

          final file = await OnlineImageCache.instance.putStream(key, chunks(),
              contentType: contentType,
              expectedBytes: contract.expectedBytes,
              maximumBytes: maximumBytes,
              isCancelled: () => transfer.cancelToken.isCancelled);
          transfer.file.complete(file);
        } catch (error, stack) {
          transfer.cancelToken.cancel('Image body rejected');
          if (!transfer.headers.isCompleted) {
            transfer.headers.completeError(error, stack);
          }
          if (!transfer.file.isCompleted) {
            transfer.file.completeError(error, stack);
          }
        } finally {
          if (identical(_inFlight[key], transfer)) _inFlight.remove(key);
        }
      });
}
