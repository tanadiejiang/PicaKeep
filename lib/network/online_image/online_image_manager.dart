import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/network/app_dio.dart';
import 'package:picakeep/network/online_image/online_image_cache.dart';

class OnlineImageLoadResult {
  const OnlineImageLoadResult({
    required this.stream,
    this.expectedTotalBytes,
  });

  final Stream<List<int>> stream;
  final int? expectedTotalBytes;
}

class OnlineImageManager {
  OnlineImageManager._() : _dio = logDio();

  @visibleForTesting
  OnlineImageManager.forTesting(this._dio);

  static final OnlineImageManager instance = OnlineImageManager._();

  final Dio _dio;
  final _inFlight = <String, Future<List<int>>>{};

  Future<StreamImageLoadResult> getImage(
    String url, {
    Map<String, String>? headers,
    StreamImageAbortSignal? abortSignal,
  }) async {
    if (abortSignal?.isAborted == true) {
      throw StateError('Image load aborted');
    }
    final cached = await OnlineImageCache.instance.get(url);
    if (cached != null && !cached.file.path.endsWith('.json')) {
      final length = await cached.file.length();
      return StreamImageLoadResult(
        stream: cached.file.openRead(),
        expectedTotalBytes: length,
      );
    }

    final completer = Completer<StreamImageLoadResult>();
    final controller = StreamController<List<int>>();
    unawaited(_download(
      url,
      headers: headers,
      abortSignal: abortSignal,
      controller: controller,
      complete: completer.complete,
      completeError: completer.completeError,
    ));
    return completer.future;
  }

  Stream<List<int>> getImageBytes(
    String url, {
    Map<String, String>? headers,
    StreamImageAbortSignal? abortSignal,
  }) async* {
    final result = await getImage(
      url,
      headers: headers,
      abortSignal: abortSignal,
    );
    yield* result.stream;
  }

  Future<void> _download(
    String url, {
    Map<String, String>? headers,
    StreamImageAbortSignal? abortSignal,
    required StreamController<List<int>> controller,
    required void Function(StreamImageLoadResult result) complete,
    required void Function(Object error, [StackTrace? stackTrace])
        completeError,
  }) async {
    final cancelToken = CancelToken();
    Future<List<int>>? ownedDownload;
    var streamDelivered = false;
    void deliver(StreamImageLoadResult result) {
      streamDelivered = true;
      complete(result);
    }

    StreamSubscription<void>? abortSubscription;
    if (abortSignal != null) {
      abortSubscription = abortSignal.aborted.asStream().listen((_) {
        if (!cancelToken.isCancelled) {
          cancelToken.cancel('Image load aborted');
        }
      });
    }

    try {
      final existing = _inFlight[url];
      if (existing != null) {
        deliver(StreamImageLoadResult(stream: Stream.fromFuture(existing)));
        return;
      }

      final future = _downloadBytes(
        url,
        headers: headers,
        cancelToken: cancelToken,
        controller: controller,
        complete: deliver,
      );
      ownedDownload = future;
      _inFlight[url] = future;
      await future;
    } catch (error, stackTrace) {
      final failure =
          cancelToken.isCancelled ? StateError('Image load aborted') : error;
      if (!streamDelivered) {
        // HTTP errors occur before anyone can subscribe to controller.stream.
        // Awaiting close() here would wait forever and hide the error from Image.
        completeError(failure, stackTrace);
      } else if (!controller.isClosed) {
        // Once headers were delivered, report a body/network failure on the
        // stream. Completing the result future again throws and loses the error.
        controller.addError(failure, stackTrace);
      }
    } finally {
      unawaited(controller.close());
      // A subscriber sharing this download must not remove its owner's entry.
      if (ownedDownload != null && identical(_inFlight[url], ownedDownload)) {
        _inFlight.remove(url);
      }
      await abortSubscription?.cancel();
    }
  }

  Future<List<int>> _downloadBytes(
    String url, {
    Map<String, String>? headers,
    required CancelToken cancelToken,
    required StreamController<List<int>> controller,
    required void Function(StreamImageLoadResult result) complete,
  }) async {
    final response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        headers: headers,
        responseType: ResponseType.stream,
      ),
      cancelToken: cancelToken,
    );
    final body = response.data;
    if (body == null) {
      throw StateError('Empty image response');
    }
    complete(StreamImageLoadResult(
      stream: controller.stream,
      expectedTotalBytes: body.contentLength > 0 ? body.contentLength : null,
    ));
    final builder = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      if (cancelToken.isCancelled) {
        throw StateError('Image load aborted');
      }
      builder.add(chunk);
      controller.add(chunk);
    }
    unawaited(controller.close());
    final bytes = builder.takeBytes();
    await OnlineImageCache.instance.put(
      url,
      bytes,
      contentType: response.headers.value('content-type') ?? '',
    );
    return bytes;
  }
}
