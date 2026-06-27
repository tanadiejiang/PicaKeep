import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/log.dart';

const Duration networkConnectTimeout = Duration(seconds: 20);
const Duration networkReceiveTimeout = Duration(seconds: 30);
const Duration networkSendTimeout = Duration(seconds: 20);

class MyLogInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.connectTimeout ??= networkConnectTimeout;
    options.receiveTimeout ??= networkReceiveTimeout;
    options.sendTimeout ??= networkSendTimeout;
    final headers = Map<String, dynamic>.from(options.headers);
    headers.removeWhere((key, _) => key.toLowerCase() == 'cookie');
    LogManager.addLog(
      LogLevel.info,
      'Network',
      '${options.method} ${options.uri}\nheaders:$headers\ndata:${options.data}',
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
    LogManager.addLog(
      response.statusCode != null && response.statusCode! < 400
          ? LogLevel.info
          : LogLevel.error,
      'Network',
      'Response ${response.realUri} ${response.statusCode}\n'
          'headers:$headers\n${_responsePreview(response.data)}',
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    LogManager.addLog(
      LogLevel.error,
      'Network',
      '${err.requestOptions.method} ${err.requestOptions.uri}\n$err\n'
          '${err.response?.data}',
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
          '${options.method} ${options.uri}\n$error\nRetrying...',
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
