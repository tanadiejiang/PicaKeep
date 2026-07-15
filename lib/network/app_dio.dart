import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/log_file_service.dart';

const Duration networkConnectTimeout = Duration(seconds: 20);
const Duration networkReceiveTimeout = Duration(seconds: 30);
const Duration networkSendTimeout = Duration(seconds: 20);

/// Testable, non-mutating redactor for values copied into network logs.
class NetworkLogRedactor {
  NetworkLogRedactor._();

  static Object? redactCopy(Object? value) =>
      LogCredentialRedactor.redactCopy(value);

  static Uri redactUri(Uri uri) => LogCredentialRedactor.redactUri(uri);

  static String redactText(String text) =>
      LogCredentialRedactor.redactText(text);
}

class MyLogInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.connectTimeout ??= networkConnectTimeout;
    options.receiveTimeout ??= networkReceiveTimeout;
    options.sendTimeout ??= networkSendTimeout;
    final headers = Map<String, dynamic>.from(options.headers);
    headers.removeWhere((key, _) => key.toLowerCase() == 'cookie');
    final message = '${options.method} '
        '${NetworkLogRedactor.redactUri(options.uri)}\n'
        'headers:${NetworkLogRedactor.redactCopy(headers)}\n'
        'data:${NetworkLogRedactor.redactCopy(options.data)}';
    LogManager.addLog(
      LogLevel.info,
      'Network',
      NetworkLogRedactor.redactText(message),
    );
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final headers = response.headers.map.map(
      (key, value) => MapEntry(
        key.toLowerCase(),
        value.length == 1 ? value.first : value.toString(),
      ),
    )..remove('cookie');
    final redactedData = NetworkLogRedactor.redactCopy(response.data);
    final message = 'Response '
        '${NetworkLogRedactor.redactUri(response.realUri)} '
        '${response.statusCode}\n'
        'headers:${NetworkLogRedactor.redactCopy(headers)}\n'
        '${NetworkLogRedactor.redactText(_responsePreview(redactedData))}';
    LogManager.addLog(
      response.statusCode != null && response.statusCode! < 400
          ? LogLevel.info
          : LogLevel.error,
      'Network',
      NetworkLogRedactor.redactText(message),
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final message = '${err.requestOptions.method} '
        '${NetworkLogRedactor.redactUri(err.requestOptions.uri)}\n'
        '${NetworkLogRedactor.redactText(err.toString())}\n'
        '${NetworkLogRedactor.redactCopy(err.response?.data)}';
    LogManager.addLog(
      LogLevel.error,
      'Network',
      NetworkLogRedactor.redactText(message),
    );
    handler.next(_friendlyError(err));
  }

  DioException _friendlyError(DioException err) {
    switch (err.type) {
      case DioExceptionType.badResponse:
        final statusCode = err.response?.statusCode;
        if (statusCode != null) {
          return err.copyWith(
            message: 'Invalid Status Code: $statusCode. '
                '${_statusCodeInfo(statusCode)}',
          );
        }
      case DioExceptionType.connectionTimeout:
        return err.copyWith(message: '连接超时，请检查网络或代理');
      case DioExceptionType.receiveTimeout:
        return err.copyWith(message: '响应超时，请稍后重试');
      case DioExceptionType.sendTimeout:
        return err.copyWith(message: '发送超时，请稍后重试');
      case DioExceptionType.unknown:
        final text = err.toString();
        if (text.contains('Connection terminated during handshake')) {
          return err.copyWith(
            message: 'Connection terminated during handshake',
          );
        }
        if (text.contains('Connection reset by peer')) {
          return err.copyWith(message: 'Connection reset by peer');
        }
      default:
        break;
    }
    return err;
  }

  String _statusCodeInfo(int statusCode) {
    if (statusCode >= 500) {
      return 'Server-side error, please try again later.';
    }
    return const <int, String>{
          400: 'The request is invalid.',
          401: 'The request is unauthorized.',
          403: 'No permission to access the resource.',
          404: 'Not found.',
          429: 'Too many requests. Please try again later.',
        }[statusCode] ??
        '';
  }

  String _responsePreview(Object? data) {
    if (data is List<int>) {
      try {
        return utf8.decode(data, allowMalformed: false);
      } catch (_) {
        return '<Bytes length:${data.length}>';
      }
    }
    return data.toString();
  }
}

class RetryHttpClientAdapter extends IOHttpClientAdapter {
  RetryHttpClientAdapter() {
    createHttpClient = () {
      final client = HttpClient();
      final manualProxy = appdata.settings[8].trim();
      if (manualProxy.isNotEmpty && manualProxy != '0') {
        client.findProxy = (_) => 'PROXY $manualProxy';
      }
      // 不设置 findProxy 时，dart:io HttpClient 默认走系统代理（尊重 VPN/系统设置）
      return client;
    };
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var retry = 0;
    while (true) {
      try {
        return await super.fetch(options, requestStream, cancelFuture);
      } catch (error) {
        if (error is DioException) {
          final noRetry = options.extra['noRetry'] == true;
          if (noRetry) {
            rethrow;
          }
          final code = error.response?.statusCode;
          if (code != null && code >= 400 && code < 500) {
            rethrow;
          }
        }
        retry++;
        if (retry >= 2) {
          rethrow;
        }
        LogManager.addLog(
          LogLevel.warning,
          'Network',
          NetworkLogRedactor.redactText(
            '${options.method} ${NetworkLogRedactor.redactUri(options.uri)}\n'
            '${NetworkLogRedactor.redactText(error.toString())}\nRetrying...',
          ),
        );
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }
}

Dio logDio([BaseOptions? options]) {
  final dio = Dio(options)..interceptors.add(MyLogInterceptor());
  dio.httpClientAdapter = RetryHttpClientAdapter();
  return dio;
}
