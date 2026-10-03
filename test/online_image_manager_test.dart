import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handle);
  final Future<ResponseBody> Function(RequestOptions) handle;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      handle(options);

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory cache;

  setUpAll(() async {
    cache = await Directory.systemTemp.createTemp('online_cover_errors_');
    App.cachePath = cache.path;
  });
  tearDownAll(() async => cache.delete(recursive: true));

  OnlineImageManager manager(
      Future<ResponseBody> Function(RequestOptions) get) {
    final dio = Dio()..httpClientAdapter = _Adapter(get);
    addTearDown(() => dio.close(force: true));
    return OnlineImageManager.forTesting(dio);
  }

  test('404 before headers completes with an error and permits retry',
      () async {
    var requests = 0;
    final images = manager((_) async {
      requests++;
      return ResponseBody.fromString('not found', 404);
    });
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(
        images
            .getImage('https://i.pximg.net/missing.jpg')
            .timeout(const Duration(seconds: 2)),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'status', 404)),
      );
    }
    expect(requests, 2);
  });

  test('connection failure before headers is not left pending', () async {
    final images = manager((options) async => throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionTimeout,
        ));
    await expectLater(
      images
          .getImage('https://i.pximg.net/unreachable.jpg')
          .timeout(const Duration(seconds: 2)),
      throwsA(isA<DioException>()
          .having((e) => e.type, 'type', DioExceptionType.connectionTimeout)),
    );
  });

  test('body failure reaches the image consumer rather than truncated bytes',
      () async {
    final body = StreamController<Uint8List>();
    final images = manager((_) async => ResponseBody(body.stream, 200));
    final result = await images.getImage('https://i.pximg.net/interrupted.jpg');
    final consumed = result.stream.toList();
    final assertion = expectLater(consumed.timeout(const Duration(seconds: 2)),
        throwsA(isA<SocketException>()));
    body.add(Uint8List.fromList([1, 2]));
    body.addError(const SocketException('connection reset'));
    await body.close();
    await assertion;
  });

  test('multiple consumers share pending request until its body completes',
      () async {
    final body = StreamController<Uint8List>();
    var requests = 0;
    final images = manager((_) async {
      requests++;
      return ResponseBody(body.stream, 200, headers: {
        Headers.contentTypeHeader: ['image/png']
      });
    });
    const url = 'https://i.pximg.net/shared.png';
    final first = await images.getImage(url);
    final firstBytes = first.stream.expand((chunk) => chunk).toList();
    final second = await images.getImage(url);
    final secondBytes = second.stream.expand((chunk) => chunk).toList();
    // Previously the second request removed the owner's in-flight entry on
    // returning its stream, so this third consumer started another HTTP request.
    final third = await images.getImage(url);
    final thirdBytes = third.stream.expand((chunk) => chunk).toList();
    body.add(Uint8List.fromList([1, 2, 3]));
    await body.close();
    for (final bytes in [firstBytes, secondBytes, thirdBytes]) {
      expect(await bytes.timeout(const Duration(seconds: 2)), [1, 2, 3]);
    }
    expect(requests, 1);
    final cached = await images.getImage(url);
    expect(await cached.stream.expand((chunk) => chunk).toList(), [1, 2, 3]);
    expect(requests, 1);
  });
}
