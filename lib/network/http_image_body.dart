import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:picakeep/foundation/image_loader/reader_image_observation.dart';

/// A body failure, not a fabricated network timeout. No URL or credentials.
class HttpImageBodyException implements IOException {
  const HttpImageBodyException(this.reason, {this.expected, this.received});

  final String reason;
  final int? expected;
  final int? received;

  @override
  String toString() => 'HttpImageBodyException: $reason'
      '${expected == null ? '' : ' expected=$expected'}'
      '${received == null ? '' : ' received=$received'}';
}

/// Contract for bytes delivered by Dart IO's default autoUncompress=true client.
///
/// The SDK recognizes only the exact single value `gzip`. It leaves the wire
/// Content-Length/Content-Encoding headers unchanged after decoding. Never
/// normalize an unsupported coding and then assume the SDK decoded its bytes.
/// Custom adapters must preserve this contract (or reject encoded responses).
class HttpImageBodyContract {
  HttpImageBodyContract._(this.maximumBytes, this.expectedBytes);

  factory HttpImageBodyContract.fromHeaders(
    Map<String, List<String>> headers, {
    required int maximumBytes,
    bool autoUncompress = true,
  }) {
    if (maximumBytes <= 0) {
      throw ArgumentError.value(
          maximumBytes, 'maximumBytes', 'Must be positive');
    }
    List<String> values(String name) => [
          for (final entry in headers.entries)
            if (entry.key.toLowerCase() == name) ...entry.value,
        ];
    final encodings = values('content-encoding');
    final identity = encodings.isEmpty ||
        (encodings.length == 1 && encodings.single == 'identity');
    final decodedGzip =
        autoUncompress && encodings.length == 1 && encodings.single == 'gzip';
    observeReaderImageFacts(
        encodingContract: identity
            ? ReaderEncodingContract.identity
            : decodedGzip
                ? ReaderEncodingContract.gzipDecoded
                : ReaderEncodingContract.unsupported);
    if (!identity && !decodedGzip) {
      throw const HttpImageBodyException('unsupported-content-encoding');
    }
    // Even a valid wire length says nothing about a decoded gzip body's size.
    int? expected;
    if (identity) {
      final lengths = values('content-length');
      if (lengths.isNotEmpty) {
        if (lengths.length != 1 ||
            !RegExp(r'^\d+$').hasMatch(lengths.single) ||
            (expected = int.tryParse(lengths.single)) == null) {
          throw const HttpImageBodyException('invalid-content-length');
        }
        if (expected! > maximumBytes) {
          throw HttpImageBodyException('maximum-bytes-exceeded',
              expected: maximumBytes, received: expected);
        }
      }
    }
    return HttpImageBodyContract._(maximumBytes, expected);
  }

  final int maximumBytes;

  /// Length of the bytes the consumer receives, NOT the encoded wire length.
  final int? expectedBytes;

  Stream<List<int>> validate(Stream<List<int>> source) async* {
    var received = 0;
    await for (final chunk in source) {
      received += chunk.length;
      if (received > maximumBytes) {
        throw HttpImageBodyException('maximum-bytes-exceeded',
            expected: maximumBytes, received: received);
      }
      if (expectedBytes != null && received > expectedBytes!) {
        throw HttpImageBodyException('body-length-mismatch',
            expected: expectedBytes, received: received);
      }
      yield chunk;
    }
    // Only normal EOF reaches these checks. Framing, gzip, timeout and cancel
    // exceptions are deliberately propagated without being reclassified.
    if (received == 0) throw const HttpImageBodyException('empty-body');
    if (expectedBytes != null && received != expectedBytes) {
      throw HttpImageBodyException('body-length-mismatch',
          expected: expectedBytes, received: received);
    }
  }
}

/// Shared bounded byte path for JM task downloads and local missing-page repair.
/// Keeping ResponseType.stream bounds decoded bytes before buffering them.
Future<Uint8List> fetchHttpImageBytes(
  Dio dio,
  String url, {
  required int maximumBytes,
  Map<String, String>? headers,
  CancelToken? cancelToken,
  void Function()? checkCancelled,
  void Function(int)? onChunk,
}) async {
  final token = cancelToken ?? CancelToken();
  try {
    final response = await dio.get<ResponseBody>(url,
        cancelToken: token,
        options: Options(
          headers: headers,
          responseType: ResponseType.stream,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ));
    checkCancelled?.call();
    observeReaderImageFacts(
        httpStatusClass: readerHttpStatusClass(response.statusCode));
    final body = response.data;
    if (body == null) throw const HttpImageBodyException('empty-body');
    final contract = HttpImageBodyContract.fromHeaders(response.headers.map,
        maximumBytes: maximumBytes);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in contract
        .validate(body.stream.timeout(const Duration(seconds: 20)))) {
      checkCancelled?.call();
      onChunk?.call(chunk.length);
      bytes.add(chunk);
    }
    checkCancelled?.call();
    return bytes.takeBytes();
  } catch (error, stack) {
    if (!token.isCancelled) {
      if (error is DioException && error.response?.statusCode != null) {
        observeReaderImageFacts(
            httpStatusClass: readerHttpStatusClass(error.response!.statusCode));
      }
      observeReaderImageFailure(ReaderImageStage.fetch, error, stack);
    }
    token.cancel('Image body rejected');
    rethrow;
  }
}

bool isRetryableHttpImageError(Object error) =>
    error is TimeoutException ||
    error is SocketException ||
    error is HttpException ||
    error is HandshakeException ||
    (error is HttpImageBodyException &&
        (error.reason == 'body-length-mismatch' ||
            error.reason == 'empty-body')) ||
    (error is DioException &&
        (error.type == DioExceptionType.connectionTimeout ||
            error.type == DioExceptionType.receiveTimeout ||
            error.type == DioExceptionType.sendTimeout ||
            error.type == DioExceptionType.connectionError ||
            (error.error != null && isRetryableHttpImageError(error.error!))));
