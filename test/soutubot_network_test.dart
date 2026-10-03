import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/network/cloudflare.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/network/soutubot_network/soutubot_network.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handle);
  final Future<ResponseBody> Function(RequestOptions, Uint8List) handle;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final body = BytesBuilder(copy: false);
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        body.add(chunk);
      }
    }
    return handle(options, body.takeBytes());
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object data,
        {int status = 200, Map<String, List<String>> headers = const {}}) =>
    ResponseBody.fromString(jsonEncode(data), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
      ...headers
    });

final _png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 0, 255]);

void main() {
  SoutubotNetwork client(
      Future<ResponseBody> Function(RequestOptions, Uint8List) request) {
    final dio = Dio()..httpClientAdapter = _Adapter(request);
    dio.interceptors.add(CloudflareInterceptor());
    addTearDown(() => dio.close(force: true));
    return SoutubotNetwork.forTesting(dio, userAgent: 'test-agent');
  }

  test('服务按文件part格式验收PNG/JPEG/GIF/WebP/BMP；二进制原样上传', () async {
    final formats = <({String extension, String mime, List<int> bytes})>[
      (extension: 'png', mime: 'image/png', bytes: _png),
      (
        extension: 'jpg',
        mime: 'image/jpeg',
        bytes: [255, 216, 255, 224, 0, 255]
      ),
      (
        extension: 'gif',
        mime: 'image/gif',
        bytes: [71, 73, 70, 56, 57, 97, 0, 255]
      ),
      (
        extension: 'webp',
        mime: 'image/webp',
        bytes: [82, 73, 70, 70, 20, 0, 0, 0, 87, 69, 66, 80, 0, 255]
      ),
      (extension: 'bmp', mime: 'image/bmp', bytes: [66, 77, 0, 255]),
    ];
    for (final format in formats) {
      final result = await client((options, body) async {
        final boundary = options.contentType!.split('boundary=').last;
        final header = latin1.encode('--$boundary\r\n'
            'Content-Disposition: form-data; name="file"; filename="image.${format.extension}"\r\n'
            'Content-Type: ${format.mime}\r\n\r\n');
        // Simulate the current service rejecting non-image file parts. This
        // inspects bytes after Dio's request transformation, not only helpers.
        if (!latin1.decode(body).contains('Content-Type: ${format.mime}\r\n')) {
          return _json({'detail': '仅支持常见图片格式'}, status: 415);
        }
        expect(body.take(header.length), orderedEquals(header));
        expect(body.sublist(header.length, header.length + format.bytes.length),
            orderedEquals(format.bytes));
        expect(latin1.decode(body), endsWith('--$boundary--\r\n'));
        return _json({'results': [], 'result_id': format.extension});
      }).searchByImage(Uint8List.fromList(format.bytes));
      expect(result.success, isTrue, reason: format.mime);
      expect(result.data.id, format.extension);
    }
  });

  test('未知格式和伪装的RIFF音频在上传前拒绝，415不会误报服务故障', () async {
    var calls = 0;
    final api = client((_, __) async {
      calls++;
      return _json({'detail': '仅支持常见图片格式'}, status: 415);
    });
    for (final bytes in <List<int>>[
      [],
      [1, 2, 3],
      [137, 80, 78, 71],
      [82, 73, 70, 70, 20, 0, 0, 0, 87, 65, 86, 69],
    ]) {
      final result = await api.searchByImage(Uint8List.fromList(bytes));
      expect(result.errorCode, ResErrorCode.invalidArgument);
    }
    expect(calls, 0);
    final result = await api.searchByImage(_png);
    expect(calls, 1);
    expect(result.statusCode, 415);
    expect(result.errorCode, ResErrorCode.invalidArgument);
    expect(result.errorMessage, contains('图片格式'));
    expect(result.errorMessage, isNot(contains('服务异常')));
  });

  test('新版直接一次POST，不请求主页/签名；multipart字段和图片字节保持准确', () async {
    var calls = 0;
    final result = await client((options, body) async {
      calls++;
      expect(options.method, 'POST');
      expect(options.uri.toString(), 'https://soutubot.moe/api/search');
      expect(options.followRedirects, isFalse);
      expect(options.headers['x-api-key'], isNull);
      expect(options.headers['user-agent'], 'test-agent');
      final payload = latin1.decode(body);
      expect(payload, contains('name="file"; filename="image.png"'));
      expect(payload, contains('Content-Type: image/png\r\n\r\n'));
      expect(options.contentType, startsWith('multipart/form-data; boundary='));
      expect(payload, contains('name="factor"\r\n\r\n1.2'));
      expect(payload, contains('name="metadata_mode"\r\n\r\ndisplay'));
      expect(payload, contains(String.fromCharCodes(_png)));
      return _json({'results': [], 'result_id': 'empty'});
    }).searchByImage(_png);
    expect(calls, 1);
    expect(result.success, isTrue);
    expect(result.data.items, isEmpty);
  });

  test('已验证适配器可替换endpoint字段和响应路径', () async {
    final result = await client((options, body) async {
      expect(options.uri.path, '/api/v3/search');
      expect(latin1.decode(body),
          contains('name="picture"; filename="image.png"'));
      expect(latin1.decode(body), contains('name="mode"\r\n\r\nquick'));
      return _json({'items': [], 'token': 'r1'});
    }).searchByImage(_png, adapter: {
      'endpoint': 'https://soutubot.moe/api/v3/search',
      'fileField': 'picture',
      'fields': {'mode': 'quick'},
      'response': {
        'format': 'soutubot_v2',
        'resultsPath': 'items',
        'idPath': 'token'
      },
    });
    expect(result.data.id, 'r1');
  });

  test('拒绝不同主机/协议/凭据/重定向；不转发图片或cookie', () async {
    var calls = 0;
    final api = client((_, __) async {
      calls++;
      return _json({});
    });
    for (final endpoint in [
      'https://evil.example/api/search',
      'http://soutubot.moe/api/search',
      'https://user:pass@soutubot.moe/api/search',
      'https://soutubot.moe:444/api/search',
      'https://soutubot.moe/api/search#x'
    ]) {
      expect(
          (await api.searchByImage(_png, adapter: {'endpoint': endpoint}))
              .errorCode,
          ResErrorCode.invalidArgument);
    }
    expect(calls, 0);
    final redirect = await client((_, __) async => _json({},
        status: 302,
        headers: {
          'location': ['https://elsewhere.example']
        })).searchByImage(_png);
    expect(redirect.errorCode, ResErrorCode.unsupported);
  });

  test('结构错误明确失败，旧data和正常空结果兼容', () async {
    for (final data in [
      {},
      {'results': {}},
      {'message': 'busy'}
    ]) {
      final res =
          await client((_, __) async => _json(data)).searchByImage(_png);
      expect(res.errorCode, ResErrorCode.parse);
    }
    expect(
        (await client((_, __) async => _json({'data': []})).searchByImage(_png))
            .success,
        isTrue);
  });

  test('HTTP权限/限流/图片/服务错误可区分，CF仍原样上抛', () async {
    for (final status in [401, 403, 413, 415, 429, 500]) {
      final res = await client((_, __) async => _json({}, status: status))
          .searchByImage(_png);
      expect(res.statusCode, status);
      expect(res.errorMessage, isNot(contains('签名')));
    }
    await expectLater(
        client((_, __) async => _json({},
            status: 403,
            headers: {
              'cf-mitigated': ['challenge']
            })).searchByImage(_png),
        throwsA(isA<CloudflareException>()));
  });

  test('响应超过8MiB停止读取并返回解析错误', () async {
    final res = await client((_, __) async =>
            ResponseBody(Stream.value(Uint8List(8 * 1024 * 1024 + 1)), 200))
        .searchByImage(_png);
    expect(res.errorCode, ResErrorCode.parse);
  });
}
