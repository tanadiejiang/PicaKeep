import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:picakeep/network/http_image_body.dart';

import 'stream_image_provider.dart';

class ReaderImageCancelled implements Exception {
  const ReaderImageCancelled();
  @override
  String toString() => 'Reader image load cancelled';
}

/// Three retries, four total attempts. TLS/auth/decode/quota failures are terminal.
Duration? readerImageRetryDelay(Object error, int retry, {DateTime? now}) {
  if (retry < 1 || retry > 3) return null;
  final backoff = Duration(seconds: 1 << retry);
  if (error is HandshakeException || error is TlsException) return null;
  if (error is DioException) {
    if (error.type == DioExceptionType.cancel ||
        error.type == DioExceptionType.badCertificate) {
      return null;
    }
    if (error.type == DioExceptionType.badResponse) {
      final status = error.response?.statusCode;
      if (status == 429) {
        final values = error.response?.headers['retry-after'];
        if (values == null || values.isEmpty) return backoff;
        if (values.length != 1) return null;
        final value = values.single.trim();
        Duration wait;
        final seconds = int.tryParse(value);
        if (seconds != null) {
          // Check before constructing Duration: extreme integer values could
          // overflow its microsecond representation and shorten a server pause.
          if (seconds < 0 || seconds > 120) return null;
          wait = Duration(seconds: seconds);
        } else {
          try {
            wait = HttpDate.parse(value).difference(now ?? DateTime.now());
          } catch (_) {
            return null; // Never guess around malformed throttling metadata.
          }
        }
        // A long server pause is shown to the user, never shortened by us.
        if (wait > const Duration(minutes: 2)) return null;
        return wait > backoff ? wait : backoff;
      }
      if (status == 408 ||
          status == 425 ||
          (status != null &&
              status >= 500 &&
              status <= 599 &&
              status != 501 &&
              status != 505)) {
        return backoff;
      }
      return null;
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return backoff;
    }
    if (error.error != null) {
      return readerImageRetryDelay(error.error!, retry, now: now);
    }
    return error.type == DioExceptionType.connectionError ? backoff : null;
  }
  if (error is TimeoutException ||
      error is SocketException ||
      error is HttpException) {
    return backoff;
  }
  if (error is HttpImageBodyException &&
      error.reason == 'body-length-mismatch') {
    return backoff;
  }
  return null;
}

Future<void> waitForReaderImageRetry(
    Duration delay, StreamImageAbortSignal abort) {
  if (abort.isAborted) return Future.error(const ReaderImageCancelled());
  final done = Completer<void>();
  final timer = Timer(delay, () => done.complete());
  unawaited(abort.aborted.then((_) {
    if (done.isCompleted) return;
    timer.cancel();
    done.completeError(const ReaderImageCancelled());
  }));
  return done.future;
}
