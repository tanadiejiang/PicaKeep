import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/local_jm_page_repair.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/managed_image_retry.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/http_image_fixture.dart';
import 'support/image_disk_quota_fixture.dart';

class _TrackingAdapter implements HttpClientAdapter {
  _TrackingAdapter(this.delegate);
  final HttpClientAdapter delegate;
  final headers = Completer<void>();
  final cancelled = Completer<void>();

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<dynamic>? cancelFuture) async {
    if (cancelFuture != null) {
      unawaited(cancelFuture.then((_) {
        if (!cancelled.isCompleted) cancelled.complete();
      }));
    }
    final response = await delegate.fetch(options, requestStream, cancelFuture);
    if (!headers.isCompleted) headers.complete();
    return response;
  }

  @override
  void close({bool force = false}) => delegate.close(force: force);
}

class _LocalFixture {
  _LocalFixture(this.data, this.chapter, this.transport, this.metadataCalls);
  final OnlineLocalReadingData data;
  final Directory chapter;
  final _TrackingAdapter transport;
  final int Function() metadataCalls;

  File page(int page, [String extension = '.webp']) =>
      File(p.join(chapter.path, '$page$extension'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final savedSettings = List<String>.of(appdata.settings);
  final savedQuota = ImageDiskQuota.overrideForTesting;
  final savedLogging = LogManager.recordingEnabled;
  final png = syntheticHttpPng();
  final sources = <ReaderPageSource>[];
  final gates = <Completer<void>>[];
  late Directory root;
  late ImageDiskQuota quota;
  var sequence = 0;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('online_local_source_057_');
    App.dataPath = p.join(root.path, 'app');
    App.cachePath = p.join(root.path, 'cache');
    await Directory(App.dataPath).create(recursive: true);
    await Directory(App.cachePath).create(recursive: true);
    appdata.settings[22] = p.join(root.path, 'downloads');
    SharedPreferences.setMockInitialValues({});
    LogManager.recordingEnabled = false;
    quota = installTaskDiskQuota(() => [App.cachePath]);
  });

  tearDown(() async {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    gates.clear();
    for (final source in sources) {
      await source.dispose().timeout(const Duration(seconds: 5));
    }
    sources.clear();
    await quota.drain();
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    expect(ImageTemporaryPool.shared.reservedBytes, 0);
  });

  tearDownAll(() async {
    await quota.drain();
    ImageDiskQuota.overrideForTesting = savedQuota;
    appdata.settings = savedSettings;
    LogManager.recordingEnabled = savedLogging;
    expect(p.basename(root.path), startsWith('online_local_source_057_'));
    await root.delete(recursive: true);
  });

  Completer<void> gate() {
    final value = Completer<void>();
    gates.add(value);
    return value;
  }

  Future<HttpImageFixture> serve(
      HttpImageReply Function(Uri, String) reply) async {
    final server = await HttpImageFixture.start(reply);
    addTearDown(server.close);
    return server;
  }

  Future<_LocalFixture> fixture(HttpImageFixture server,
      {int pages = 1,
      String chapterId = '1',
      Directory? existingChapter,
      Future<void> Function()? metadata,
      LocalJmPageRecombiner? recombine,
      bool isJm = true}) async {
    final chapter = existingChapter ??
        Directory(p.join(root.path, 'downloads', 'comic-${sequence++}', '1'));
    await chapter.create(recursive: true);
    final dio = directImageDio();
    final tracker = _TrackingAdapter(dio.httpClientAdapter);
    dio.httpClientAdapter = tracker;
    addTearDown(() => dio.close(force: true));
    var metadataCalls = 0;
    final data = OnlineLocalReadingData(
        title: 'Fixture',
        id: 'jm41',
        rootDirectoryPath: chapter.parent.path,
        chapters: const {'1': 'One'},
        isJm: isJm,
        jmComicId: '41',
        imageDio: dio,
        jmChapterLoader: (ep) async {
          expect(ep, 1);
          metadataCalls++;
          await metadata?.call();
          return (
            chapterId: chapterId,
            urls: [for (var i = 1; i <= pages; i++) server.url('/$i.webp')]
          );
        },
        jmRecombiner: recombine);
    return _LocalFixture(data, chapter, tracker, () => metadataCalls);
  }

  Future<ReaderPageSource> source(_LocalFixture fixture,
      {int page = 1, String extension = '.webp'}) async {
    final value = await fixture.data
        .resolvePageSource(1, page - 1, fixture.page(page, extension).path);
    sources.add(value);
    return value;
  }

  Future<File> open(ReaderPageSource source, {bool managed = true}) => managed
      ? runWithManagedImageRetry(() => source.openOriginalFile())
      : source.openOriginalFile();

  void noStaging(_LocalFixture fixture) {
    expect(
        fixture.chapter.listSync().where((file) =>
            p.basename(file.path).startsWith('.reader-repair-') ||
            file.path.endsWith('.part')),
        isEmpty);
  }

  test(
      'production sharp source lazily repairs real JM bands and exposes exact PNG metadata',
      () async {
    final original = image.Image(width: 8, height: 20);
    for (var y = 0; y < original.height; y++) {
      for (var x = 0; x < original.width; x++) {
        original.setPixelRgba(x, y, y * 10, x * 20, (y * 13) % 256, 255);
      }
    }
    final raw = image.encodePng(original, level: 0);
    final server = await serve(
        (_, __) => HttpImageReply(gzip.encode(raw), encoding: 'gzip'));
    final local = await fixture(server, chapterId: '230000');
    final placeholder = local.page(1);
    await placeholder.writeAsBytes([]);
    final sharp = await source(local);
    expect(local.metadataCalls(), 0);
    expect(server.requests, isEmpty);
    final file = await open(sharp);
    expect(file.path, local.page(1, '.png').path);
    expect(sharp.extension, '.png');
    expect(sharp.mimeType, 'image/png');
    expect(sharp.byteLength, await file.length());
    expect(sharp.isAuthoritativeOriginal, isTrue);
    final decoded = image.decodePng(await file.readAsBytes())!;
    expect((decoded.width, decoded.height), (8, 20));
    for (var y = 0; y < 20; y++) {
      final originalY = (9 - y ~/ 2) * 2 + y % 2;
      for (var x = 0; x < 8; x++) {
        final pixel = decoded.getPixel(x, y);
        expect([pixel.r, pixel.g, pixel.b, pixel.a],
            [originalY * 10, x * 20, (originalY * 13) % 256, 255]);
      }
    }
    expect(await placeholder.length(), 0);
    await sharp.dispose();
    expect(await file.exists(), isTrue);
    expect(await local.data.loadEpNetwork(1), [file.path]);
    final warm =
        await source(local); // Even the old zero-byte URL is recoverable.
    expect((await open(warm)).path, file.path);
    // Direct legacy/progress calls use a different retry Zone but still read
    // this session's repaired user file rather than redownloading the old URL.
    final warmProgress = await local.data
        .loadOriginalNetworkWithProgress(1, 0, placeholder.path);
    expect(warmProgress.expectedTotalBytes, await file.length());
    expect(await warmProgress.stream.expand((chunk) => chunk).toList(),
        await file.readAsBytes());
    final reopened = await fixture(server,
        existingChapter: local.chapter,
        metadata: () async =>
            throw StateError('Warm local open must not resolve metadata'));
    final warmLocal = await source(reopened, extension: '.png');
    expect((await open(warmLocal)).path, file.path);
    expect(reopened.metadataCalls(), 0);
    expect(server.requests, hasLength(1));
    noStaging(local);
  });

  test(
      'existing nonempty invalid user file is read-only with no native probe or repair',
      () async {
    final server = await serve((_, __) => throw StateError('No HTTP allowed'));
    final local = await fixture(server,
        metadata: () async => throw StateError('No metadata allowed'),
        recombine: (bytes,
                {required epsId,
                required scrambleId,
                required pictureName,
                required originalExtension}) async =>
            throw StateError('No codec/recombine allowed'));
    final original = local.page(1);
    await original.writeAsBytes([7, 8, 9]);
    final before = sha256.convert(await original.readAsBytes());
    final sharp = await source(local);
    expect((await open(sharp)).path, original.path);
    await sharp.dispose();
    expect(sha256.convert(await original.readAsBytes()), before);
    expect(local.metadataCalls(), 0);
    expect(server.requests, isEmpty);
    noStaging(local);
  });

  test('non-JM missing local source does not acquire online repair ability',
      () async {
    final server = await serve((_, __) => throw StateError('No HTTP allowed'));
    final local = await fixture(server, isJm: false);
    final sharp = await source(local);
    await expectLater(open(sharp), throwsA(anything));
    expect(local.metadataCalls(), 0);
    expect(server.requests, isEmpty);
  });

  test(
      'metadata cancellation waits for actual completion and publishes no page or stale metadata',
      () async {
    final entered = Completer<void>();
    final release = gate();
    final server = await serve((_, __) => HttpImageReply(png));
    var calls = 0;
    final local = await fixture(server, metadata: () async {
      if (++calls == 1) {
        entered.complete();
        await release.future;
      }
    });
    await local.page(1).writeAsBytes([]);
    final sharp = await source(local);
    final rejected = expectLater(open(sharp), throwsA(anything));
    await entered.future;
    var disposed = false;
    final disposing = sharp.dispose().then((_) => disposed = true);
    await rejected;
    expect(disposed, isFalse);
    expect(server.requests, isEmpty);
    release.complete();
    await disposing;
    expect(await local.page(1, '.png').exists(), isFalse);
    expect(await local.page(1).length(), 0);
    final retry = await source(local);
    expect(await (await open(retry)).readAsBytes(), png);
    expect(calls, 2, reason: 'cancelled metadata was not cached');
    expect(server.requests, hasLength(1));
    noStaging(local);
  });

  test(
      'source disposal cancels actual HTTP body and drains without waiting for server EOF',
      () async {
    final release = gate();
    var requests = 0;
    final server = await serve((_, __) => ++requests == 1
        ? HttpImageReply(png, prefixBytes: 32, release: release.future)
        : HttpImageReply(png));
    final local = await fixture(server);
    await local.page(1).writeAsBytes([]);
    final sharp = await source(local);
    final rejected = expectLater(open(sharp), throwsA(anything));
    await local.transport.headers.future.timeout(const Duration(seconds: 3));
    await Future<void>.delayed(Duration.zero);
    await sharp.dispose().timeout(const Duration(seconds: 3));
    await rejected;
    await local.transport.cancelled.future.timeout(const Duration(seconds: 1));
    expect(release.isCompleted, isFalse);
    expect(requests, 1,
        reason: 'cancellation must never retry inside the adapter');
    expect(await local.page(1, '.png').exists(), isFalse);
    expect(await local.page(1).length(), 0);
    noStaging(local);
    release.complete();
    final retry = await source(local);
    expect(await (await open(retry)).readAsBytes(), png);
    expect(requests, 2);
  });

  test(
      'non-preemptible recombine cancellation keeps disposal pending until drain and never publishes',
      () async {
    final entered = Completer<void>();
    final release = gate();
    var calls = 0;
    final server = await serve((_, __) => HttpImageReply(png));
    final local = await fixture(server, recombine: (bytes,
        {required epsId,
        required scrambleId,
        required pictureName,
        required originalExtension}) async {
      if (++calls == 1) {
        entered.complete();
        await release.future;
      }
      return (bytes: bytes, extension: '.png');
    });
    await local.page(1).writeAsBytes([]);
    final sharp = await source(local);
    final rejected = expectLater(open(sharp), throwsA(anything));
    await entered.future;
    var disposed = false;
    final disposing = sharp.dispose().then((_) => disposed = true);
    await rejected;
    expect(disposed, isFalse);
    expect(await local.page(1, '.png').exists(), isFalse);
    release.complete();
    await disposing;
    expect(await local.page(1, '.png').exists(), isFalse);
    expect(await local.page(1).length(), 0);
    noStaging(local);
    final retry = await source(local);
    expect(await (await open(retry)).readAsBytes(), png);
    expect(calls, 2);
    expect(server.requests, hasLength(2));
  });

  test(
      'same-page shared repair survives one source cancelling without competing part writers',
      () async {
    final entered = Completer<void>();
    final release = gate();
    var calls = 0;
    final server = await serve((_, __) => HttpImageReply(png));
    final local = await fixture(server, recombine: (bytes,
        {required epsId,
        required scrambleId,
        required pictureName,
        required originalExtension}) async {
      calls++;
      entered.complete();
      await release.future;
      return (bytes: bytes, extension: '.png');
    });
    await local.page(1).writeAsBytes([]);
    await local.page(1, '.jpg').writeAsBytes([]);
    final first = await source(local);
    final second = await source(local, extension: '.jpg');
    final firstRejected = expectLater(open(first), throwsA(anything));
    final secondFile = open(second);
    await entered.future;
    var disposed = false;
    final disposing = first.dispose().then((_) => disposed = true);
    await firstRejected;
    expect(disposed, isFalse);
    release.complete();
    final file = await secondFile;
    await disposing;
    await second.dispose();
    expect(await file.readAsBytes(), png);
    expect(calls, 1);
    expect(server.requests, hasLength(1));
    expect(await local.page(1).length(), 0);
    expect(await local.page(1, '.jpg').length(), 0);
    expect(await local.data.loadEpNetwork(1), [file.path]);
    noStaging(local);
  });

  test(
      'different pages across independent readers serialize recombination admission',
      () async {
    final entered = Completer<void>();
    final release = gate();
    var active = 0, peak = 0, calls = 0;
    Future<({Uint8List bytes, String extension})> recombine(Uint8List bytes,
        {required String epsId,
        required String scrambleId,
        required String pictureName,
        required String originalExtension}) async {
      active++;
      if (active > peak) peak = active;
      try {
        if (++calls == 1) {
          entered.complete();
          await release.future;
        }
        return (bytes: bytes, extension: '.png');
      } finally {
        active--;
      }
    }

    final server = await serve((_, __) => HttpImageReply(png));
    final first = await fixture(server, pages: 3, recombine: recombine);
    final second = await fixture(server,
        pages: 3, existingChapter: first.chapter, recombine: recombine);
    final firstSource = await source(first);
    final firstFile = open(firstSource);
    await entered.future;
    final secondFile = open(await source(second, page: 2));
    final thirdFile = open(await source(first, page: 3));
    await Future<void>.delayed(Duration.zero);
    expect(server.requests, hasLength(1));
    expect(calls, 1);
    release.complete();
    for (final future in [firstFile, secondFile, thirdFile]) {
      expect(await (await future).readAsBytes(), png);
    }
    expect(peak, 1);
    expect(calls, 3);
    noStaging(first);
  });

  test(
      'queued cancellation drains promptly without bypassing the occupied serial slot',
      () async {
    final entered = Completer<void>();
    final release = gate();
    var calls = 0;
    final server = await serve((_, __) => HttpImageReply(png));
    final local = await fixture(server, pages: 3, recombine: (bytes,
        {required epsId,
        required scrambleId,
        required pictureName,
        required originalExtension}) async {
      if (++calls == 1) {
        entered.complete();
        await release.future;
      }
      return (bytes: bytes, extension: '.png');
    });
    final first = await source(local);
    final firstFile = open(first);
    await entered.future;
    final queued = await source(local, page: 2);
    final rejected = expectLater(open(queued), throwsA(anything));
    await queued.dispose().timeout(const Duration(seconds: 1));
    await rejected;
    final thirdFile = open(await source(local, page: 3));
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    expect(server.requests, hasLength(1));
    release.complete();
    await firstFile;
    await thirdFile;
    expect(server.requests.map((u) => u.path), ['/1.webp', '/3.webp']);
    expect(await local.page(2, '.png').exists(), isFalse);
  });

  test(
      'late nonempty target and neighboring original remain byte-for-byte untouched',
      () async {
    final entered = Completer<void>();
    final release = gate();
    final server = await serve((_, __) => HttpImageReply(png));
    final local = await fixture(server, recombine: (bytes,
        {required epsId,
        required scrambleId,
        required pictureName,
        required originalExtension}) async {
      entered.complete();
      await release.future;
      return (bytes: bytes, extension: '.png');
    });
    await local.page(1).writeAsBytes([]);
    final neighbor = local.page(1, '.jpg');
    await neighbor.writeAsBytes([17, 18, 19]);
    final before = sha256.convert(await neighbor.readAsBytes());
    final sharp = await source(local);
    final loading = open(sharp);
    await entered.future;
    final target = local.page(1, '.png');
    await target.writeAsBytes([40, 41, 42]);
    final targetBefore = sha256.convert(await target.readAsBytes());
    release.complete();
    expect((await loading).path, target.path);
    await sharp.dispose();
    expect(sha256.convert(await target.readAsBytes()), targetBefore);
    expect(sha256.convert(await neighbor.readAsBytes()), before);
    expect(await local.page(1).length(), 0);
    noStaging(local);
  });

  test(
      'an original populated during recombination wins without publishing a duplicate',
      () async {
    final entered = Completer<void>();
    final release = gate();
    final server = await serve((_, __) => HttpImageReply(png));
    final local = await fixture(server, recombine: (bytes,
        {required epsId,
        required scrambleId,
        required pictureName,
        required originalExtension}) async {
      entered.complete();
      await release.future;
      return (bytes: bytes, extension: '.png');
    });
    final original = local.page(1);
    await original.writeAsBytes([]);
    final sharp = await source(local);
    final loading = open(sharp);
    await entered.future;
    await original.writeAsBytes([71, 72, 73]);
    final before = sha256.convert(await original.readAsBytes());
    release.complete();
    expect((await loading).path, original.path);
    await sharp.dispose();
    expect(sha256.convert(await original.readAsBytes()), before);
    expect(await local.page(1, '.png').exists(), isFalse);
    noStaging(local);
  });

  for (final managed in [true, false]) {
    test(
        '${managed ? 'managed reader' : 'standalone'} failure has ${managed ? 1 : 3} bounded raw attempt(s)',
        () async {
      var failing = true;
      final server = await serve((_, __) => HttpImageReply(failing ? [] : png));
      final local = await fixture(server);
      await local.page(1).writeAsBytes([]);
      final neighbor = local.page(1, '.jpg');
      await neighbor.writeAsBytes([3, 2, 1]);
      final before = sha256.convert(await neighbor.readAsBytes());
      final sharp = await source(local);
      await expectLater(open(sharp, managed: managed), throwsA(anything));
      await sharp.dispose();
      expect(server.requests, hasLength(managed ? 1 : 3));
      expect(await local.page(1).length(), 0);
      expect(sha256.convert(await neighbor.readAsBytes()), before);
      expect(await local.page(1, '.png').exists(), isFalse);
      noStaging(local);
      failing = false;
      final retried = await source(local);
      expect(await (await open(retried, managed: managed)).readAsBytes(), png);
      expect(server.requests, hasLength(managed ? 2 : 4));
      expect(sha256.convert(await neighbor.readAsBytes()), before);
    });
  }

  test(
      'queued managed repair keeps its own retry Zone after an unmanaged predecessor',
      () async {
    final entered = Completer<void>();
    final release = gate();
    final server = await serve(
        (uri, _) => HttpImageReply(uri.path == '/1.webp' ? png : []));
    final local = await fixture(server, pages: 2, recombine: (bytes,
        {required epsId,
        required scrambleId,
        required pictureName,
        required originalExtension}) async {
      entered.complete();
      await release.future;
      return (bytes: bytes, extension: '.png');
    });
    final first = open(await source(local), managed: false);
    await entered.future;
    final second = await source(local, page: 2);
    final rejected = expectLater(open(second), throwsA(anything));
    release.complete();
    await first;
    await rejected;
    expect(server.requests.map((u) => u.path), ['/1.webp', '/2.webp']);
  });

  test(
      'progress loader forwards raw abort and frees admission for the next page',
      () async {
    final release = gate();
    final server = await serve((uri, _) => uri.path == '/1.webp'
        ? HttpImageReply(png, prefixBytes: 32, release: release.future)
        : HttpImageReply(png));
    final local = await fixture(server, pages: 2);
    final abort = StreamImageAbortSignal();
    final pending = runWithManagedImageRetry(() => local.data
        .loadOriginalNetworkWithProgress(1, 0, local.page(1).path,
            abortSignal: abort));
    final rejected = expectLater(pending, throwsA(anything));
    await local.transport.headers.future;
    await Future<void>.delayed(Duration.zero);
    abort.abort();
    await rejected;
    await local.transport.cancelled.future.timeout(const Duration(seconds: 1));
    final next = await source(local, page: 2);
    expect(
        await (await open(next).timeout(const Duration(seconds: 3)))
            .readAsBytes(),
        png);
    expect(release.isCompleted, isFalse);
    expect(await local.page(1, '.png').exists(), isFalse);
    final progress = await local.data
        .loadOriginalNetworkWithProgress(1, 1, local.page(2, '.png').path);
    expect(progress.expectedTotalBytes, png.length);
    expect(await progress.stream.expand((chunk) => chunk).toList(), png);
    expect(server.requests.map((u) => u.path), ['/1.webp', '/2.webp']);
    noStaging(local);
  });

  test('progress cancellation also waits for non-preemptible backend drain',
      () async {
    final entered = Completer<void>();
    final release = gate();
    final server = await serve((_, __) => HttpImageReply(png));
    final local = await fixture(server, recombine: (bytes,
        {required epsId,
        required scrambleId,
        required pictureName,
        required originalExtension}) async {
      entered.complete();
      await release.future;
      return (bytes: bytes, extension: '.png');
    });
    final abort = StreamImageAbortSignal();
    var settled = false;
    final pending = runWithManagedImageRetry(() => local.data
        .loadOriginalNetworkWithProgress(1, 0, local.page(1).path,
            abortSignal: abort)).whenComplete(() => settled = true);
    final rejected = expectLater(pending, throwsA(anything));
    await entered.future;
    abort.abort();
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    expect(await local.page(1, '.png').exists(), isFalse);
    release.complete();
    await rejected;
    expect(settled, isTrue);
    expect(await local.page(1, '.png').exists(), isFalse);
    noStaging(local);
  });

  test(
      'recombination failure never publishes and explicit retry remains possible',
      () async {
    var fail = true;
    final server = await serve((_, __) => HttpImageReply(png));
    final local = await fixture(server, recombine: (bytes,
        {required epsId,
        required scrambleId,
        required pictureName,
        required originalExtension}) async {
      if (fail) throw StateError('fixture codec rejected input');
      return (bytes: bytes, extension: '.png');
    });
    await local.page(1).writeAsBytes([]);
    final broken = await source(local);
    await expectLater(open(broken), throwsA(isA<StateError>()));
    await broken.dispose();
    expect(server.requests, hasLength(1));
    expect(await local.page(1, '.png').exists(), isFalse);
    expect(await local.page(1).length(), 0);
    noStaging(local);
    fail = false;
    final retry = await source(local);
    final file = await open(retry);
    await retry.dispose();
    expect(await file.readAsBytes(), png);
    expect(server.requests, hasLength(2));
  });

  test(
      'missing-path repair cannot write outside the configured downloaded comic',
      () async {
    final server = await serve((_, __) => throw StateError('No HTTP allowed'));
    final local = await fixture(server);
    final outside = File(p.join(root.path, 'outside', '1.webp'));
    await outside.parent.create(recursive: true);
    await outside.writeAsBytes([]);
    final sharp = await local.data.resolvePageSource(1, 0, outside.path);
    sources.add(sharp);
    await expectLater(open(sharp), throwsA(isA<StateError>()));
    await sharp.dispose();
    expect(await outside.length(), 0);
    expect(local.metadataCalls(), 0);
    expect(server.requests, isEmpty);
    expect(await File(p.join(outside.parent.path, '1.png')).exists(), isFalse);
  });

  test(
      'source disposal waits for a decoder file lease but never deletes user download',
      () async {
    final server = await serve((_, __) => HttpImageReply(png));
    final local = await fixture(server);
    final sharp = await source(local);
    final file = await open(sharp);
    final releaseLease = ReaderPageFileLease.acquire(file);
    var disposed = false;
    final disposing = sharp.dispose().then((_) => disposed = true);
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isFalse);
    expect(await file.exists(), isTrue);
    releaseLease();
    await disposing;
    expect(await file.readAsBytes(), png);
  });
}
