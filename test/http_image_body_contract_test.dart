import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/network/http_image_body.dart';
import 'package:picakeep/network/online_image/online_image_cache.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';

import 'support/http_image_fixture.dart';
import 'support/image_disk_quota_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = syntheticHttpPng();
  final compact = gzip.encode(png);
  final expanded = GZipCodec(level: 0).encode(png);
  late Directory root;
  late ImageDiskQuota quota;
  final savedQuota = ImageDiskQuota.overrideForTesting;

  setUpAll(() async {
    expect(compact.length, lessThan(png.length));
    expect(expanded.length, greaterThan(png.length));
    root = await Directory.systemTemp.createTemp('http_image_contract_056_');
    App.cachePath = root.path;
    quota = installTaskDiskQuota(() => [root.path]);
  });
  tearDownAll(() async {
    await quota.drain();
    ImageDiskQuota.overrideForTesting = savedQuota;
    await root.delete(recursive: true);
  });

  Future<HttpImageFixture> serve(
      HttpImageReply Function(Uri, String) response) async {
    final fixture = await HttpImageFixture.start(response);
    addTearDown(fixture.close);
    return fixture;
  }

  Dio dio() {
    final value = directImageDio();
    addTearDown(() => value.close(force: true));
    return value;
  }

  Future<List<int>> consume(OnlineImageManager manager, String url,
      {int maximumBytes = 64 << 20,
      StreamImageAbortSignal? abortSignal}) async {
    final result = await manager.getImage(url,
        maximumBytes: maximumBytes, abortSignal: abortSignal);
    return result.stream.expand((chunk) => chunk).toList();
  }

  for (final entry
      in {'wire-smaller': compact, 'wire-larger': expanded}.entries) {
    test('real HttpClient/Dio stream+bytes gzip ${entry.key}', () async {
      final fixture =
          await serve((_, __) => HttpImageReply(entry.value, encoding: 'gzip'));
      final client = directImageClient();
      addTearDown(() => client.close(force: true));
      final request =
          await client.getUrl(Uri.parse(fixture.url('/client.png')));
      request.followRedirects = false;
      final response = await request.close();
      expect(response.compressionState,
          HttpClientResponseCompressionState.decompressed);
      expect(response.contentLength, entry.value.length);
      expect(response.headers.value('content-encoding'), 'gzip');
      expect(await response.expand((chunk) => chunk).toList(), png);

      final transport = dio();
      final bytes = await transport.get<List<int>>(fixture.url('/bytes.png'),
          options: Options(responseType: ResponseType.bytes));
      expect(bytes.data, png);
      expect(bytes.headers.value('content-length'), '${entry.value.length}');
      final body = await transport.get<ResponseBody>(fixture.url('/stream.png'),
          options: Options(responseType: ResponseType.stream));
      final contract = HttpImageBodyContract.fromHeaders(body.headers.map,
          maximumBytes: png.length);
      expect(contract.expectedBytes, isNull);
      expect(
          await contract.validate(body.data!.stream).expand((e) => e).toList(),
          png);
      // Old equality/upper-limit checks reject at least one of these directions.
      expect(entry.value.length, isNot(png.length));
    });

    test('online cold/warm gzip ${entry.key} respects decoded limit', () async {
      final fixture =
          await serve((_, __) => HttpImageReply(entry.value, encoding: 'gzip'));
      final manager = OnlineImageManager.forTesting(dio());
      final url = fixture.url('/cold.png');
      final cold = await manager.getImage(url, maximumBytes: png.length);
      expect(cold.expectedTotalBytes, isNull);
      expect(await cold.stream.expand((e) => e).toList(), png);
      final warm = await manager.getImage(url, maximumBytes: png.length);
      expect(warm.expectedTotalBytes, png.length);
      expect(await warm.stream.expand((e) => e).toList(), png);
      expect(fixture.requests, hasLength(1));
    });
  }

  for (final encoding in <String?>[null, 'identity']) {
    test('identity exact length ($encoding), real HTTP', () async {
      final fixture =
          await serve((_, __) => HttpImageReply(png, encoding: encoding));
      final result = await OnlineImageManager.forTesting(dio())
          .getImage(fixture.url('/identity.png'), maximumBytes: png.length);
      expect(result.expectedTotalBytes, png.length);
      expect(await result.stream.expand((e) => e).toList(), png);
    });
  }

  test('legal unknown-length chunked preserves bytes', () async {
    final fixture = await serve((_, __) => HttpImageReply(png, chunked: true));
    final result = await OnlineImageManager.forTesting(dio())
        .getImage(fixture.url('/chunked.png'), maximumBytes: png.length);
    expect(result.expectedTotalBytes, isNull);
    expect(await result.stream.expand((e) => e).toList(), png);
  });

  final corrupt = List<int>.of(compact)..[compact.length - 8] ^= 0xff;
  final failures = <String, HttpImageReply>{
    'identity-short-read': HttpImageReply(png.sublist(0, png.length - 4),
        declaredLength: png.length),
    'gzip-short-wire': HttpImageReply(compact.sublist(0, compact.length - 4),
        encoding: 'gzip', declaredLength: compact.length),
    'gzip-corrupt': HttpImageReply(corrupt, encoding: 'gzip'),
    'empty-identity': HttpImageReply([]),
    'empty-gzip': HttpImageReply(gzip.encode([]), encoding: 'gzip'),
    'chunked-truncated':
        HttpImageReply(png, chunked: true, brokenChunked: true),
  };
  for (final entry in failures.entries) {
    test('${entry.key} first cache failure really refetches successfully',
        () async {
      var attempts = 0;
      final fixture = await serve((_, __) => ++attempts == 1
          ? entry.value
          : HttpImageReply(compact, encoding: 'gzip'));
      final manager = OnlineImageManager.forTesting(dio());
      final baseline = ImageTemporaryPool.shared.reservedBytes;
      final url = fixture.url('/retry.png');
      await expectLater(consume(manager, url), throwsA(anything));
      expect(ImageTemporaryPool.shared.reservedBytes, baseline);
      expect(await consume(manager, url), png);
      expect(attempts, 2);
      expect(await consume(manager, url), png);
      expect(attempts, 2);
      expect(
          await Directory('${root.path}/online_images')
              .list()
              .where((f) => f.path.endsWith('.part'))
              .toList(),
          isEmpty);
    });
  }

  test(
      'SDK limitation: missing gzip ISIZE with matching wire CL is not a framing error',
      () async {
    // Dart's streaming decoder accepts this malformed member. The delivered
    // PNG is complete, but decoded bytes cannot prove the original gzip footer.
    // We reject real wire truncation/CRC errors above, not claim impossible
    // detection of every server-side content defect after autoUncompress.
    final fixture = await serve((_, __) => HttpImageReply(
        compact.sublist(0, compact.length - 4),
        encoding: 'gzip'));
    expect(
        await consume(OnlineImageManager.forTesting(dio()),
            fixture.url('/sdk-lenient-footer.png')),
        png);
  });

  test('real receive timeout clears in-flight/cache and permits retry',
      () async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    var attempts = 0;
    // Dio 5.4.1 starts its between-chunk timer only after the first chunk.
    // Headers without a body chunk are covered by the manager's 30s timeout.
    final fixture = await serve((_, __) => HttpImageReply(png,
        prefixBytes: 1, release: ++attempts == 1 ? gate.future : null));
    final transport = dio()
      ..options.receiveTimeout = const Duration(milliseconds: 100);
    final manager = OnlineImageManager.forTesting(transport);
    await expectLater(
        consume(manager, fixture.url('/timeout.png')),
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.receiveTimeout)));
    expect(await consume(manager, fixture.url('/timeout.png')), png);
    gate.complete();
    expect(attempts, 2);
  });

  test('warm cache rechecks caller maximum even when metadata length matches',
      () async {
    final fixture = await serve((_, __) => HttpImageReply(png));
    final manager = OnlineImageManager.forTesting(dio());
    final url = fixture.url('/warm-limit.png');
    final file = await manager.getImageFile(url, maximumBytes: png.length);
    final metadata =
        File('${file.path.substring(0, file.path.lastIndexOf('.'))}.json');
    final json =
        jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
    await file.writeAsBytes([...png, 0]);
    json['length'] = png.length + 1;
    await metadata.writeAsString(jsonEncode(json));
    await expectLater(
        consume(manager, url, maximumBytes: png.length), throwsStateError);
    expect(fixture.requests, hasLength(1),
        reason:
            'oversized warm hit must be rejected, not silently redownloaded');
  });

  test('retry keeps chapter Referer/Bearer and separates account caches',
      () async {
    var attempts = 0;
    final fixture = await serve((_, __) => ++attempts == 1
        ? HttpImageReply(png.sublist(0, 5), declaredLength: png.length)
        : HttpImageReply(png));
    final manager = OnlineImageManager.forTesting(dio());
    const headers = {
      'Referer': 'https://fixture.invalid/chapter/1',
      'Authorization': 'Bearer offline-fixture-one'
    };
    Future<List<int>> load(Map<String, String> values) async {
      final result = await manager.getImage(fixture.url('/headers.png'),
          headers: values,
          maximumBytes: png.length,
          cacheIdentity: 'Komiic-fixture');
      return result.stream.expand((e) => e).toList();
    }

    await expectLater(load(headers), throwsA(anything));
    expect(await load(headers), png);
    expect(await load(headers), png);
    expect(attempts, 2);
    expect(
        await load({...headers, 'Authorization': 'Bearer offline-fixture-two'}),
        png);
    expect(attempts, 3);
    for (final request in fixture.requestHeaders.take(2)) {
      expect(request.toLowerCase(),
          contains('referer: https://fixture.invalid/chapter/1'));
      expect(request.toLowerCase(),
          contains('authorization: bearer offline-fixture-one'));
    }
  });

  for (final coding in [
    'GZIP',
    'br',
    'deflate',
    'gzip, identity',
    'x-gzip',
    'unknown'
  ]) {
    test('real HTTP rejects unsupported SDK coding $coding', () async {
      final fixture =
          await serve((_, __) => HttpImageReply(compact, encoding: coding));
      await expectLater(
          consume(
              OnlineImageManager.forTesting(dio()), fixture.url('/bad.png')),
          throwsA(isA<HttpImageBodyException>().having(
              (e) => e.reason, 'reason', 'unsupported-content-encoding')));
    });
  }
  for (final coding in [' gzip', 'gzip ', 'Gzip', 'gzip, gzip', '']) {
    test('contract never guesses SDK decoding for literal [$coding]', () {
      expect(
          () => HttpImageBodyContract.fromHeaders({
                'content-encoding': [coding]
              }, maximumBytes: 100),
          throwsA(isA<HttpImageBodyException>()));
    });
  }
  test('HTTP parser trims outer whitespace before SDK recognizes gzip',
      () async {
    final fixture =
        await serve((_, __) => HttpImageReply(compact, encoding: ' gzip '));
    expect(
        await consume(
            OnlineImageManager.forTesting(dio()), fixture.url('/spaces.png')),
        png);
  });
  test('disabled autoUncompress and multiple header fields are not decoded',
      () {
    expect(
        () => HttpImageBodyContract.fromHeaders({
              'content-encoding': ['gzip']
            }, maximumBytes: 100, autoUncompress: false),
        throwsA(isA<HttpImageBodyException>()));
    expect(
        () => HttpImageBodyContract.fromHeaders({
              'content-encoding': ['gzip', 'gzip']
            }, maximumBytes: 100),
        throwsA(isA<HttpImageBodyException>()));
  });
  test(
      'identity strict equality/nonempty, independent maximum, and source errors',
      () async {
    final contract = HttpImageBodyContract.fromHeaders({
      'content-length': ['3']
    }, maximumBytes: 4);
    for (final body in <List<int>>[
      [],
      [1, 2],
      [1, 2, 3, 4]
    ]) {
      await expectLater(contract.validate(Stream.value(body)).toList(),
          throwsA(isA<HttpImageBodyException>()));
    }
    final failure = StateError('source marker');
    await expectLater(contract.validate(Stream.error(failure)).toList(),
        throwsA(same(failure)));
    expect(
        () => HttpImageBodyContract.fromHeaders({
              'content-length': ['-1']
            }, maximumBytes: 4),
        throwsA(isA<HttpImageBodyException>()));
  });

  test('concurrent maximum policies cannot widen each other', () async {
    final gate = Completer<void>();
    final fixture = await serve((_, __) =>
        HttpImageReply(compact, encoding: 'gzip', release: gate.future));
    final manager = OnlineImageManager.forTesting(dio());
    final url = fixture.url('/limits.png');
    final small = await manager.getImage(url, maximumBytes: png.length - 1);
    final large = await manager.getImage(url, maximumBytes: png.length);
    final rejected = expectLater(
        small.stream.toList(), throwsA(isA<HttpImageBodyException>()));
    final accepted = large.stream.expand((e) => e).toList();
    gate.complete();
    await rejected;
    expect(await accepted, png);
    expect(fixture.requests, hasLength(2));
    await expectLater(consume(manager, url, maximumBytes: png.length - 1),
        throwsA(isA<HttpImageBodyException>()));
    expect(await consume(manager, url, maximumBytes: png.length), png);
  });

  test('one shared consumer abort cannot cancel another', () async {
    final gate = Completer<void>();
    final fixture = await serve((_, __) =>
        HttpImageReply(compact, encoding: 'gzip', release: gate.future));
    final manager = OnlineImageManager.forTesting(dio());
    final abort = StreamImageAbortSignal();
    final first = await manager.getImage(fixture.url('/shared.png'),
        maximumBytes: 64 << 20, abortSignal: abort);
    final second = await manager.getImage(fixture.url('/shared.png'),
        maximumBytes: 64 << 20);
    final stopped = expectLater(first.stream.toList(), throwsStateError);
    final completed = second.stream.expand((e) => e).toList();
    abort.abort();
    await stopped;
    gate.complete();
    expect(await completed, png);
    expect(fixture.requests, hasLength(1));
  });

  test('last consumer abort unwinds and allows an immediate fresh retry',
      () async {
    final gate = Completer<void>();
    var attempts = 0;
    final fixture = await serve((_, __) => HttpImageReply(compact,
        encoding: 'gzip', release: ++attempts == 1 ? gate.future : null));
    final manager = OnlineImageManager.forTesting(dio());
    final abort = StreamImageAbortSignal();
    final result = await manager.getImage(fixture.url('/cancel-retry.png'),
        maximumBytes: 64 << 20, abortSignal: abort);
    final stopped = expectLater(result.stream.toList(), throwsStateError);
    abort.abort();
    await stopped;
    expect(await consume(manager, fixture.url('/cancel-retry.png')), png);
    gate.complete();
    expect(attempts, 2);
  });

  test('cache admission uses independent maximum or known decoded length',
      () async {
    final cache = OnlineImageCache.instance;
    for (final policy in <({int maximum, int? expected, int reserve})>[
      (maximum: 512 << 20, expected: null, reserve: 512 << 20),
      (maximum: 64 << 20, expected: null, reserve: 64 << 20),
      (maximum: 128 << 20, expected: png.length, reserve: png.length),
    ]) {
      final started = Completer<void>();
      final chunks = StreamController<List<int>>(onListen: started.complete);
      final baseline = ImageTemporaryPool.shared.reservedBytes;
      final write = cache.putStream(
          'admission-${policy.maximum}', chunks.stream,
          maximumBytes: policy.maximum, expectedBytes: policy.expected);
      await started.future;
      expect(
          ImageTemporaryPool.shared.reservedBytes, baseline + policy.reserve);
      chunks.add(png);
      await chunks.close();
      expect(await (await write).readAsBytes(), png);
      expect(ImageTemporaryPool.shared.reservedBytes, baseline);
    }
  });

  test('cache callback cancels before publication, preserving existing bytes',
      () async {
    final cache = OnlineImageCache.instance;
    var cancelled = false;
    Stream<List<int>> chunks() async* {
      yield [1, 2, 3];
      cancelled = true;
    }

    final key = cache.keyForUrl('cancel-processed');
    final previous = File('${root.path}/online_images/$key.img');
    await previous.writeAsBytes([9, 8]);
    await File('${root.path}/online_images/$key.json').writeAsString(
        jsonEncode({'extension': 'img', 'contentType': '', 'length': 2}));
    final baseline = ImageTemporaryPool.shared.reservedBytes;
    await expectLater(
        cache.putStream('cancel-processed', chunks(),
            maximumBytes: 20, expectedBytes: 3, isCancelled: () => cancelled),
        throwsStateError);
    expect(await previous.readAsBytes(), [9, 8]);
    expect(await (await cache.get('cancel-processed'))!.file.readAsBytes(),
        [9, 8]);
    expect(ImageTemporaryPool.shared.reservedBytes, baseline);
    await expectLater(
        cache.putStream('too-big', Stream.value([1, 2, 3]), maximumBytes: 2),
        throwsStateError);
    expect(await cache.get('too-big'), isNull);
  });
}
