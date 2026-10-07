import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/network/app_dio.dart';
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
}

class OnlineImageManager {
  OnlineImageManager._() : _dio = logDio();
  @visibleForTesting
  OnlineImageManager.forTesting(this._dio);
  static final OnlineImageManager instance = OnlineImageManager._();
  final Dio _dio;
  final _inFlight = <String, _ImageTransfer>{};

  String _key(String url, Map<String, String>? headers, String? identity) {
    final entries = (headers?.entries.toList() ?? [])
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    final scope = sha256
        .convert(utf8.encode(jsonEncode(
            entries.map((e) => [e.key.toLowerCase(), e.value]).toList())))
        .toString();
    return jsonEncode(['online-image-v2', identity ?? url, scope]);
  }

  Future<File> getImageFile(
    String url, {
    Map<String, String>? headers,
    StreamImageAbortSignal? abortSignal,
    String? cacheIdentity,
  }) async {
    final acquired = await _acquire(url,
        headers: headers,
        abortSignal: abortSignal,
        cacheIdentity: cacheIdentity);
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
  }) async {
    final acquired = await _acquire(url,
        headers: headers,
        abortSignal: abortSignal,
        cacheIdentity: cacheIdentity);
    Stream<List<int>> stream() async* {
      try {
        final file = await acquired.file;
        if (abortSignal?.isAborted == true) {
          throw StateError('Image load aborted');
        }
        final releaseFile = OnlineImageCache.instance.lease(file);
        try {
          yield* file.openRead();
        } finally {
          releaseFile();
        }
      } finally {
        acquired.release();
      }
    }

    return StreamImageLoadResult(
        stream: stream(), expectedTotalBytes: acquired.length);
  }

  Future<({Future<File> file, int? length, void Function() release})> _acquire(
    String url, {
    Map<String, String>? headers,
    StreamImageAbortSignal? abortSignal,
    String? cacheIdentity,
  }) async {
    if (abortSignal?.isAborted == true) throw StateError('Image load aborted');
    final key = _key(url, headers, cacheIdentity);
    final cached = await OnlineImageCache.instance.get(key);
    if (cached != null) {
      final release = OnlineImageCache.instance.lease(cached.file);
      return (
        file: Future.value(cached.file),
        length: await cached.file.length(),
        release: release
      );
    }
    var transfer = _inFlight[key];
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
      // Header failures can precede the first body subscription.
      unawaited(active.file.future
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      _inFlight[key] = active;
      unawaited(_download(url, key, headers, active));
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
      final file = abortSignal == null
          ? active.file.future
          : Future.any<File>([
              active.file.future,
              abortSignal.aborted
                  .then<File>((_) => throw StateError('Image load aborted')),
            ]);
      return (file: file, length: length, release: release);
    } catch (_) {
      release();
      rethrow;
    }
  }

  Stream<List<int>> getImageBytes(
    String url, {
    Map<String, String>? headers,
    StreamImageAbortSignal? abortSignal,
    String? cacheIdentity,
  }) async* {
    final result = await getImage(url,
        headers: headers,
        abortSignal: abortSignal,
        cacheIdentity: cacheIdentity);
    yield* result.stream;
  }

  Future<void> _download(String url, String key, Map<String, String>? headers,
      _ImageTransfer transfer) async {
    try {
      final response = await _dio.get<ResponseBody>(url,
          options: Options(headers: headers, responseType: ResponseType.stream),
          cancelToken: transfer.cancelToken);
      final body = response.data;
      if (body == null) throw StateError('Empty image response');
      if (body.contentLength > OnlineImageCache.maxInputBytes) {
        transfer.cancelToken.cancel('Image file exceeds disk budget');
        throw StateError('Image file exceeds disk budget');
      }
      transfer.headers
          .complete(body.contentLength > 0 ? body.contentLength : null);
      Stream<List<int>> chunks() async* {
        await for (final chunk
            in body.stream.timeout(const Duration(seconds: 30))) {
          if (transfer.cancelToken.isCancelled) {
            throw StateError('Image load aborted');
          }
          yield chunk;
        }
      }

      final file = await OnlineImageCache.instance.putStream(key, chunks(),
          contentType: response.headers.value('content-type') ?? '',
          expectedBytes: body.contentLength > 0 ? body.contentLength : null);
      transfer.file.complete(file);
    } catch (error, stack) {
      if (!transfer.headers.isCompleted) {
        transfer.headers.completeError(error, stack);
      }
      if (!transfer.file.isCompleted) transfer.file.completeError(error, stack);
    } finally {
      if (identical(_inFlight[key], transfer)) _inFlight.remove(key);
    }
  }
}
