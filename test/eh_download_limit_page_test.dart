import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// EH 下载链路 509 判定的契约回归防护。
///
/// `OnlineDownloadManager._downloadFileOnce`（detectEhLimitPage:true）依赖两条 dio
/// 行为：
/// 1. dio 默认 validateStatus 只放行 2xx，509 会在拿到 ResponseBody 之前抛
///    DioException.badResponse——所以「读响应头判 text/html」那段代码在状态码型
///    509 上根本执行不到，必须显式放开 validateStatus。
/// 2. 放开后能同时读到 statusCode 与响应头 Content-Type，且流可正常 drain
///    （509 页只有几百字节，读完丢弃让连接归还连接池）。
///
/// 私有成员无法直接单测，这里用本地 HttpServer 锁住上面两条前提：dio 升级后行为
/// 若变化，本测试先炸，而不是等真机下载时静默退化成「该页直接失败、0 次换节点」。
void main() {
  late HttpServer server;
  late String limitUrl;
  late String htmlOkUrl;
  late String imageUrl;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      switch (request.uri.path) {
        case '/limit':
          // H@H 配额耗尽：非 2xx + text/html body。
          request.response.statusCode = 509;
          request.response.headers.contentType =
              ContentType('text', 'html', charset: 'utf-8');
          request.response.write('<html>Bandwidth exceeded</html>');
          break;
        case '/html-ok':
          // 失效节点：状态码 200 但 body 是 html。
          request.response.statusCode = 200;
          request.response.headers.contentType =
              ContentType('text', 'html', charset: 'utf-8');
          request.response.write('<html>nope</html>');
          break;
        default:
          request.response.statusCode = 200;
          request.response.headers.contentType = ContentType('image', 'jpeg');
          request.response.add(const [1, 2, 3, 4]);
      }
      await request.response.close();
    });
    final base = 'http://${server.address.address}:${server.port}';
    limitUrl = '$base/limit';
    htmlOkUrl = '$base/html-ok';
    imageUrl = '$base/image.jpg';
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('dio 默认 validateStatus 会让 509 在读响应头之前就抛异常', () async {
    final dio = Dio();
    await expectLater(
      dio.get<ResponseBody>(limitUrl,
          options: Options(responseType: ResponseType.stream)),
      throwsA(isA<DioException>()
          .having((e) => e.type, 'type', DioExceptionType.badResponse)),
    );
  });

  test('放开 validateStatus 后 509 能按响应头判定并 drain 掉 body', () async {
    final dio = Dio();
    final res = await dio.get<ResponseBody>(
      limitUrl,
      options: Options(
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
      ),
    );
    expect(res.statusCode, 509);
    final body = res.data!;
    final contentType =
        body.headers['Content-Type']?[0] ?? body.headers['content-type']?[0];
    expect(contentType, isNotNull);
    expect(contentType!.startsWith('text/html'), isTrue);
    // 读完丢弃不应抛错（下载侧 drain 的前提）。
    await body.stream.drain<void>().timeout(const Duration(seconds: 5));
  });

  test('状态码 200 但 Content-Type 为 text/html 同样被判成失效节点', () async {
    final dio = Dio();
    final res = await dio.get<ResponseBody>(
      htmlOkUrl,
      options: Options(
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
      ),
    );
    expect(res.statusCode, 200);
    final body = res.data!;
    final contentType =
        body.headers['Content-Type']?[0] ?? body.headers['content-type']?[0];
    expect(contentType!.startsWith('text/html'), isTrue);
    await body.stream.drain<void>().timeout(const Duration(seconds: 5));
  });

  test('正常图片响应不命中任何判定条件', () async {
    final dio = Dio();
    final res = await dio.get<ResponseBody>(
      imageUrl,
      options: Options(
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
      ),
    );
    expect(res.statusCode, 200);
    final body = res.data!;
    final contentType =
        body.headers['Content-Type']?[0] ?? body.headers['content-type']?[0];
    expect(contentType!.startsWith('text/html'), isFalse);
    final bytes = <int>[];
    await for (final chunk in body.stream) {
      bytes.addAll(chunk);
    }
    expect(bytes, const [1, 2, 3, 4]);
  });
}
