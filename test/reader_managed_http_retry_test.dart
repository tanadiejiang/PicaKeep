import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/reader_preview_provider.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/app_dio.dart';
import 'package:picakeep/network/managed_image_retry.dart';
import 'package:picakeep/network/online_image/online_image_cache.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';

import 'support/http_image_fixture.dart';
import 'support/image_disk_quota_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ImageDiskQuota quota;
  final savedQuota = ImageDiskQuota.overrideForTesting;
  final savedLog = LogManager.recordingEnabled;
  final png = syntheticHttpPng();

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('reader_http_057_');
    App.cachePath = root.path;
    App.dataPath = root.path;
    quota = installTaskDiskQuota(() => [root.path]);
    LogManager.recordingEnabled = false;
  });
  tearDownAll(() async {
    await quota.drain();
    ImageDiskQuota.overrideForTesting = savedQuota;
    LogManager.recordingEnabled = savedLog;
    await root.delete(recursive: true);
  });

  Future<HttpImageFixture> serve(
      HttpImageReply Function(Uri, String) handler) async {
    final fixture = await HttpImageFixture.start(handler);
    addTearDown(fixture.close);
    return fixture;
  }

  OnlineImageManager manager() {
    final dio = logDio();
    dio.options.followRedirects = false;
    dio.httpClientAdapter = RetryHttpClientAdapter()
      ..createHttpClient = directImageClient;
    addTearDown(() => dio.close(force: true));
    return OnlineImageManager.forTesting(dio);
  }

  Future<List<int>> load(OnlineImageManager images, String url,
      {bool managed = false, Map<String, String>? headers}) {
    Future<List<int>> operation() async {
      final result =
          await images.getImage(url, maximumBytes: 64 << 20, headers: headers);
      return result.stream.expand((e) => e).toList();
    }

    return managed ? runWithManagedImageRetry(operation) : operation();
  }

  test(
      'real managed provider makes four requests, not transport retry multiplication',
      () async {
    var requests = 0;
    final fixture = await serve((_, __) => ++requests < 4
        ? HttpImageReply([], disconnectBeforeHeaders: true)
        : HttpImageReply(png));
    final images = manager();
    final delays = <Duration>[];
    final pool = ReaderPreviewImagePool(
        waitForRetry: (delay, abort) async => delays.add(delay));
    final lease = pool.acquire(
        resourceKey: 'retry-http',
        loadProvider: (abort) => StreamImageProvider.withProgress(
            () => images.getImage(fixture.url('/retry.png'),
                abortSignal: abort, maximumBytes: 64 << 20),
            fixture.url('/retry.png'),
            abortSignal: abort));
    final stream = lease.provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) => info.dispose(),
        onError: (Object _, StackTrace? __) {});
    stream.addListener(listener);
    expect(await lease.firstFrame.timeout(const Duration(seconds: 5)),
        const Size(24, 32));
    expect(requests, 4);
    expect(delays.map((e) => e.inSeconds), [2, 4, 8]);
    stream.removeListener(listener);
    lease.release();
    pool.dispose();
  });

  test('non-reader transport retains its existing two-attempt policy',
      () async {
    var requests = 0;
    final fixture = await serve((_, __) => ++requests == 1
        ? HttpImageReply([], disconnectBeforeHeaders: true)
        : HttpImageReply(png));
    expect(await load(manager(), fixture.url('/ordinary.png')), png);
    expect(requests, 2);
    expect(isManagedImageRetry, isFalse);
  });

  test(
      'managed and normal pending transfers do not inherit each other retry ownership',
      () async {
    final gate = Completer<void>();
    final fixture =
        await serve((_, __) => HttpImageReply(png, release: gate.future));
    final images = manager();
    final url = fixture.url('/policy.png');
    final first = await images.getImage(url, maximumBytes: 64 << 20);
    final second = await runWithManagedImageRetry(
        () => images.getImage(url, maximumBytes: 64 << 20));
    final a = first.stream.expand((e) => e).toList();
    final b = second.stream.expand((e) => e).toList();
    gate.complete();
    expect(await a, png);
    expect(await b, png);
    expect(fixture.requests, hasLength(2));
  });

  test(
      'late old transfer cannot resurrect metadata after more than 256 invalidations',
      () async {
    final gate = Completer<void>();
    var requests = 0;
    final fixture = await serve((_, __) => ++requests == 1
        ? HttpImageReply([1, 2, 3], release: gate.future)
        : HttpImageReply(png));
    final images = manager();
    final url = fixture.url('/late.png');
    final old = await images.getImage(url, maximumBytes: 64 << 20);
    final oldBytes = old.stream.expand((e) => e).toList();
    final oldFile = images.getImageFile(url, maximumBytes: 64 << 20);
    await images.invalidateImage(url, maximumBytes: 64 << 20);
    for (var i = 0; i < 260; i++) {
      await images.invalidateImage(fixture.url('/unused-$i'),
          maximumBytes: 64 << 20);
    }
    expect(await load(images, url), png,
        reason: 'still-pending old transfer must not be rejoined');
    expect(requests, 2);
    gate.complete();
    expect(await oldBytes, [1, 2, 3]);
    final file = await oldFile;
    final metadata =
        File('${file.path.substring(0, file.path.lastIndexOf('.'))}.json');
    for (var i = 0; i < 50 && await metadata.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await metadata.exists(), isFalse,
        reason: 'retired publication must be tombstoned');
    expect(await file.readAsBytes(), [1, 2, 3],
        reason: 'valid old consumer keeps its body');
    expect(await load(images, url), png);
    expect(requests, 2,
        reason:
            'new revision stays warm and never falls back to leased old path');
  });

  test(
      'page invalidation refreshes both policies, not another account; old lease survives',
      () async {
    final fixture = await serve((_, __) => HttpImageReply(png));
    final images = manager();
    final url = fixture.url('/invalidate.png');
    const one = {'Authorization': 'Bearer fixture-one'};
    const two = {'Authorization': 'Bearer fixture-two'};
    expect(await load(images, url, headers: one), png);
    expect(await load(images, url, headers: one, managed: true), png);
    expect(await load(images, url, headers: two), png);
    final old =
        await images.getImageFile(url, headers: one, maximumBytes: 64 << 20);
    final release = OnlineImageCache.instance.lease(old);
    await images.invalidateImage(url, headers: one, maximumBytes: 64 << 20);
    expect(await old.readAsBytes(), png);
    expect(await load(images, url, headers: one), png);
    expect(await load(images, url, headers: one, managed: true), png);
    expect(await load(images, url, headers: two), png);
    expect(fixture.requests, hasLength(5));
    release();
  });
}
