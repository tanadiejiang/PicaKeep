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
    createHttpClient = () => _client ??= _buildHttpClient();
  }

  /// 复用的底层 HttpClient，懒初始化并在本 adapter 生命周期内复用，
  /// 避免每个请求都新建连接（零连接池、重复 TLS 握手）。
  HttpClient? _client;

  /// 构造 [_client] 时读取的代理配置指纹，用于判断代理是否已在运行期变更。
  String? _proxyFingerprint;

  /// 当前代理配置是否已偏离构造 [_client] 时读取的值。
  ///
  /// dio 的 [IOHttpClientAdapter] 在首次创建后会一直缓存该 HttpClient，
  /// 单个 adapter 实例本身无法感知之后的代理变化；长生命周期的共享
  /// adapter（见 [sharedDownloadDio]）需要据此判断是否整体重建。
  bool get isProxyStale =>
      _proxyFingerprint != null &&
      _proxyFingerprint != appdata.settings[8].trim();

  HttpClient _buildHttpClient() {
    final client = HttpClient();
    // 连接池：允许同 host 多条并发 keep-alive 连接，避免每次请求都重新握手。
    client.maxConnectionsPerHost = 8;
    client.idleTimeout = const Duration(seconds: 100);
    final manualProxy = appdata.settings[8].trim();
    _proxyFingerprint = manualProxy;
    if (manualProxy.isNotEmpty && manualProxy != '0') {
      client.findProxy = (_) => 'PROXY $manualProxy';
    }
    // 不设置 findProxy 时，dart:io HttpClient 默认走系统代理（尊重 VPN/系统设置）
    return client;
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

Dio? _sharedDownloadDio;
RetryHttpClientAdapter? _sharedDownloadAdapter;

/// 下载链路专用共享 Dio：连接池保活、复用 HttpClient，避免每页多次 TLS 握手。
///
/// 与 [logDio] 不同，本函数返回 library-level 的同一个 Dio + 同一个
/// [RetryHttpClientAdapter] 实例，供下载流水线的并发请求复用底层连接池
/// （keep-alive、maxConnectionsPerHost）。[options] 仅在首次创建该单例时
/// 生效；单例已存在时忽略，避免中途改写正在使用的 BaseOptions。
///
/// CancelToken 是 per-request 参数而非 BaseOptions 的一部分，因此调用方
/// 仍应在每次请求（如 `dio.get(..., cancelToken: token)`）时传入各自独立
/// 的 CancelToken；共享 Dio 实例不影响这一语义，也不会把 cancelToken 放入
/// 共享的 BaseOptions 中。
///
/// 若代理设置在运行期发生变化，底层 [RetryHttpClientAdapter] 会被重建
/// （旧连接池关闭），但返回的 Dio 实例保持不变。
Dio sharedDownloadDio({BaseOptions? options}) {
  if (_sharedDownloadDio == null) {
    final adapter = RetryHttpClientAdapter();
    final dio = Dio(options)..interceptors.add(MyLogInterceptor());
    dio.httpClientAdapter = adapter;
    _sharedDownloadAdapter = adapter;
    _sharedDownloadDio = dio;
  } else if (_sharedDownloadAdapter?.isProxyStale ?? false) {
    _sharedDownloadAdapter?.close(force: false);
    final adapter = RetryHttpClientAdapter();
    _sharedDownloadDio!.httpClientAdapter = adapter;
    _sharedDownloadAdapter = adapter;
  }
  return _sharedDownloadDio!;
}
