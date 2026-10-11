import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/jm_image_recombine.dart';
import 'package:picakeep/foundation/image_loader/jm_page_loader.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/online_image/online_image_cache.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart' as reader;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/http_image_fixture.dart';
import 'support/image_disk_quota_fixture.dart';

JmComicInfo _info(String id, {String episode = '501'}) => JmComicInfo(
      id: id,
      title: 'JM complete-page fixture',
      authors: const [],
      description: '',
      likes: 0,
      views: 0,
      comments: 0,
      tags: const [],
      works: const [],
      actors: const [],
      series: {1: episode},
      epNames: const ['One'],
      isFavourite: false,
      isLiked: false,
      coverUrl: '',
      relatedComics: const [],
    );

String _processedKey(reader.JmReadingData data, int page, String url) {
  final headers = getJmImgHeaders().entries.toList()
    ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
  final scope = sha256
      .convert(utf8.encode(jsonEncode(headers
          .map((entry) => [entry.key.toLowerCase(), entry.value])
          .toList())))
      .toString();
  return jsonEncode([
    JmPageLoader.algorithmVersion,
    data.originalNetworkCacheIdentity(1, page, url),
    scope,
    url,
    data.info.series[1],
    kJmScrambleId,
    Uri.parse(url).pathSegments.last.replaceFirst(RegExp(r'\.[^.]+$'), ''),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open(
            p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
  }
  final png = syntheticHttpPng();
  final savedSettings = List<String>.of(appdata.settings);
  final savedLogging = LogManager.recordingEnabled;
  final savedQuota = ImageDiskQuota.overrideForTesting;
  late Directory root;
  late ImageDiskQuota quota;
  var nextId = 57000;
  final sources = <ReaderPageSource>[];

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('jm_page_loader_057_');
    App.dataPath = p.join(root.path, 'app');
    App.cachePath = p.join(root.path, 'cache');
    await Directory(App.dataPath).create(recursive: true);
    await Directory(App.cachePath).create(recursive: true);
    appdata.settings[22] = p.join(root.path, 'downloads');
    SharedPreferences.setMockInitialValues({});
    LogManager.recordingEnabled = false;
    quota = installTaskDiskQuota(() => [App.cachePath]);
    await downloadManager.init();
    expect(downloadManager.dbFilePath, startsWith(root.path));
    expect(downloadManager.debugRecordCount, 0);
  });

  tearDown(() async {
    for (final source in sources) {
      await source.dispose();
    }
    sources.clear();
    await quota.drain();
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    expect(ImageTemporaryPool.shared.reservedBytes, 0);
  });

  tearDownAll(() async {
    downloadManager.dispose();
    await quota.drain();
    ImageDiskQuota.overrideForTesting = savedQuota;
    appdata.settings = savedSettings;
    LogManager.recordingEnabled = savedLogging;
    expect(p.basename(root.path), startsWith('jm_page_loader_057_'));
    await root.delete(recursive: true);
  });

  Future<HttpImageFixture> serve(
      HttpImageReply Function(Uri, String) reply) async {
    final fixture = await HttpImageFixture.start(reply);
    addTearDown(fixture.close);
    return fixture;
  }

  reader.JmReadingData data({
    JmPageRecombiner? recombine,
    bool forceOnline = false,
    String episode = '501',
    String? id,
  }) {
    final dio = directImageDio();
    addTearDown(() => dio.close(force: true));
    return reader.JmReadingData(
      info: _info(id ?? '${nextId++}', episode: episode),
      forceOnline: forceOnline,
      pageLoader: JmPageLoader.forTesting(
        images: OnlineImageManager.forTesting(dio),
        recombine: recombine,
      ),
    );
  }

  Future<ReaderPageSource> source(reader.JmReadingData data, String url,
      {int page = 0}) async {
    final result = await data.resolvePageSource(1, page, url);
    sources.add(result);
    expect(result, isA<JmReaderPageSource>());
    return result;
  }

  Future<void> until(bool Function() ready, String reason) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) fail(reason);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('ordinary source cold/warm uses real ten-segment PNG recombination once',
      () async {
    final scrambled = image.Image(width: 8, height: 20, numChannels: 4);
    for (var y = 0; y < scrambled.height; y++) {
      for (var x = 0; x < scrambled.width; x++) {
        scrambled.setPixelRgba(x, y, y * 10, x * 20, 50, 255);
      }
    }
    final raw = image.encodePng(scrambled);
    final fixture = await serve((_, headers) {
      expect(headers.toLowerCase(), contains('accept-encoding: gzip\r\n'));
      expect(headers.toLowerCase(), contains('referer: https://localhost/'));
      return HttpImageReply(gzip.encode(raw), encoding: 'gzip');
    });
    var recombinations = 0;
    final reading = data(
      episode: '230000',
      recombine: (bytes,
          {required epsId,
          required scrambleId,
          required pictureName,
          originalExtension = '.webp'}) {
        recombinations++;
        expect(epsId, '230000');
        expect(pictureName, 'page');
        expect(originalExtension, '.png');
        return JmRecombine.recombine(bytes,
            epsId: epsId,
            scrambleId: scrambleId,
            pictureName: pictureName,
            originalExtension: originalExtension);
      },
    );
    expect(reading.downloaded, isFalse);
    final url = fixture.url('/page.webp?version=fixture');
    final cold = await source(reading, url);
    expect(cold.byteLength, isNull);
    final file = await cold.openOriginalFile();
    final processed = await file.readAsBytes();
    expect(cold.byteLength, processed.length);
    expect(cold.extension, '.png');
    expect(cold.mimeType, 'image/png');
    expect(cold.isAuthoritativeOriginal, isTrue);
    expect(cold.isPreviewOnly, isFalse);
    expect(processed, isNot(orderedEquals(raw)));
    final decoded = image.decodePng(processed)!;
    expect((decoded.width, decoded.height), (8, 20));
    for (var y = 0; y < 20; y++) {
      // Ten 2-row bands are reversed; row order within a band stays unchanged.
      final sourceY = (9 - y ~/ 2) * 2 + y % 2;
      expect(decoded.getPixel(3, y).r, sourceY * 10);
      expect(decoded.getPixel(3, y).g, 60);
      expect(decoded.getPixel(3, y).a, 255);
    }
    final key = _processedKey(reading, 0, url);
    final entry = await OnlineImageCache.instance.get(key);
    expect(entry!.file.path, file.path);
    expect(entry.contentType, 'image/png');
    await cold.dispose();
    expect(await file.exists(), isTrue,
        reason: 'source does not own cached originals');
    final warm = await source(reading, url);
    expect((await warm.openOriginalFile()).path, file.path);
    expect(
        await warm.openOriginal().expand((bytes) => bytes).toList(), processed);
    expect(warm.byteLength, processed.length);
    expect(recombinations, 1);
    expect(fixture.requests, hasLength(1));
    // The provider-facing original stream uses the same complete-page cache.
    final providerBody =
        await reading.loadOriginalNetworkWithProgress(1, 0, url);
    expect(providerBody.expectedTotalBytes, processed.length);
    expect(
        await providerBody.stream.expand((bytes) => bytes).toList(), processed);
    expect(recombinations, 1);
    expect(fixture.requests, hasLength(1));
  });

  test(
      'forceOnline bypasses an isolated downloaded record and passes old pages through',
      () async {
    const id = '57999';
    final directory =
        await Directory(p.join(root.path, 'downloads', 'completed'))
            .create(recursive: true);
    final completed = File(p.join(directory.path, '1.png'));
    await completed.writeAsBytes(png);
    final before = sha256.convert(await completed.readAsBytes());
    final db = sqlite3.open(downloadManager.dbFilePath!);
    try {
      db.execute('insert into download values (?,?,?,?,?,?,?)',
          ['jm$id', 'Fixture', '', 0, 'completed', png.length, '{}']);
    } finally {
      db.dispose();
    }
    expect(data(id: id).downloaded, isTrue);
    final reading = data(forceOnline: true, id: id);
    expect(reading.downloaded, isFalse);
    final fixture = await serve((_, __) => HttpImageReply(png));
    final page = await source(reading, fixture.url('/old.png'));
    final file = await page.openOriginalFile();
    expect(await file.readAsBytes(), png);
    expect(page.byteLength, png.length);
    expect(page.extension, '.png');
    expect(page.mimeType, 'image/png');
    expect(file.path, isNot(completed.path));
    expect(sha256.convert(await completed.readAsBytes()), before);
    expect(fixture.requests, hasLength(1));
  });

  test('same-page production sources singleflight and cancel only one consumer',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    var recombinations = 0;
    final reading = data(recombine: (bytes,
        {required epsId,
        required scrambleId,
        required pictureName,
        originalExtension = '.webp'}) async {
      recombinations++;
      entered.complete();
      await release.future;
      return (bytes: bytes, extension: '.png');
    });
    final fixture = await serve((_, __) => HttpImageReply(png));
    final url = fixture.url('/shared.png');
    final first = await source(reading, url);
    final second = await source(reading, url);
    final cancelled = ReaderPageCancellation();
    final a = first.openOriginalFile(cancellation: cancelled);
    final b = second.openOriginalFile();
    final aRejected = expectLater(a, throwsA(anything));
    await entered.future.timeout(const Duration(seconds: 3));
    cancelled.cancel();
    await aRejected;
    await first.dispose();
    release.complete();
    final file = await b.timeout(const Duration(seconds: 3));
    expect(await file.readAsBytes(), png);
    expect(second.byteLength, png.length);
    expect(recombinations, 1);
    expect(fixture.requests, hasLength(1));
    final third = await source(reading, url);
    expect((await third.openOriginalFile()).path, file.path);
    expect(recombinations, 1);
  });

  test('multiple pages serialize aggregate raw collection and recombination',
      () async {
    final fixture = await serve((_, __) => HttpImageReply(png));
    var active = 0, peak = 0, calls = 0;
    Future<({Uint8List bytes, String extension})> recombine(Uint8List bytes,
        {required String epsId,
        required String scrambleId,
        required String pictureName,
        String originalExtension = '.webp'}) async {
      calls++;
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 15));
      active--;
      return (bytes: bytes, extension: '.png');
    }

    final readers = [data(recombine: recombine), data(recombine: recombine)];
    final pages = await Future.wait([
      for (var i = 0; i < 6; i++)
        source(readers[i % 2], fixture.url('/$i.png'), page: i),
    ]);
    final files =
        await Future.wait(pages.map((page) => page.openOriginalFile()));
    expect(files.map((file) => file.path).toSet(), hasLength(6));
    expect(calls, 6);
    expect(peak, 1);
    expect(active, 0);
    expect(fixture.requests, hasLength(6));
  });

  test(
      'six real JM pages fit 640MiB free with 512MiB headroom and retain only actual files',
      () async {
    final rawImage = image.Image(width: 8, height: 20, numChannels: 4);
    for (var y = 0; y < rawImage.height; y++) {
      for (var x = 0; x < rawImage.width; x++) {
        rawImage.setPixelRgba(x, y, y * 10, x * 20, 50, 255);
      }
    }
    final raw = image.encodePng(rawImage, level: 0);
    // A real decoded gzip body has unknown decoded length. This must exercise
    // the production 64MiB raw reservation, not an artificially tiny length.
    final fixture = await serve(
        (_, __) => HttpImageReply(gzip.encode(raw), encoding: 'gzip'));
    final previous = ImageDiskQuota.overrideForTesting;
    var available = 640 << 20;
    final observedReservations = <int>[];
    final controlled = ImageDiskQuota(
      roots: () => [App.cachePath],
      idleLimitBytes: () => 500 << 20,
      headroomBytes: 512 << 20,
      space: (_) async {
        observedReservations.add(ImageTemporaryPool.shared.reservedBytes);
        return ImageDiskSpace(available, 'jm-controlled-fixture-volume');
      },
    );
    final owned = <ReaderPageSource>[];
    ImageDiskQuota.overrideForTesting = controlled;
    try {
      // No injected recombiner: exercise both pass-through and actual ten-row
      // segmentation through the production JmReadingData -> JmPageLoader path.
      final readers = [data(episode: '501'), data(episode: '230000')];
      for (var i = 0; i < 6; i++) {
        owned.add(await source(readers[i % 2], fixture.url('/quota-$i.png'),
            page: i));
      }
      final files =
          await Future.wait(owned.map((page) => page.openOriginalFile()));
      expect(files.map((file) => file.path).toSet(), hasLength(6));
      expect(fixture.requests, hasLength(6));
      expect(controlled.rejectedCount, 0);
      expect(observedReservations, contains(64 << 20));
      expect(observedReservations.every((bytes) => bytes <= 64 << 20), isTrue,
          reason:
              'raw collection is singleflight across both reader instances');
      expect(ImageTemporaryPool.shared.reservedBytes, 0,
          reason:
              'six open sources must not each retain an unknown 512MiB workspace');
      expect(controlled.activeBytes, lessThan(1 << 20));
      final coldHashes = <String>[];
      for (var i = 0; i < files.length; i++) {
        final file = files[i];
        expect(file.path, startsWith(p.join(App.cachePath, 'online_images')));
        expect(DerivedImageStore.isPathLeased(file.path), isTrue);
        final bytes = await file.readAsBytes();
        coldHashes.add(sha256.convert(bytes).toString());
        expect(owned[i].byteLength, bytes.length);
        final decoded = image.decodePng(bytes)!;
        expect((decoded.width, decoded.height), (8, 20));
        expect(decoded.getPixel(3, 0).r, i.isEven ? 0 : 180);
        if (i.isEven) expect(bytes, raw);
        final family = p.withoutExtension(file.path);
        final normalized = p.normalize(p.absolute(family));
        // ImageDiskQuota keys are normalized absolute paths, case-folded on
        // Windows. Match its real identity without weakening retained-byte checks.
        final claimPath =
            Platform.isWindows ? normalized.toLowerCase() : normalized;
        final claims = controlled.reservations
            .where((entry) => entry['path'] == claimPath)
            .toList();
        expect(claims, hasLength(1),
            reason: 'each leased completed page keeps its disk claim');
        final claim = claims.single;
        expect(claim['finished'], isTrue);
        expect(claim['peakBytes'],
            await file.length() + await File('$family.json').length(),
            reason:
                'a completed page retains actual body/metadata bytes, not its input cap');
      }

      // Warm reopen under the SAME 640MiB free / 512MiB headroom quota.
      // Fresh data/loaders preserve the two book identities, not loader-local
      // in-flight state. Cold sources keep the successful originals protected.
      final claimsBeforeWarm =
          controlled.reservations.map((entry) => entry['path']).toSet();
      final observationsBeforeWarm = observedReservations.length;
      final warmReaders = [
        for (final coldReader in readers)
          data(id: coldReader.info.id, episode: coldReader.info.series[1]!),
      ];
      final warmSources = <ReaderPageSource>[];
      for (var i = 0; i < 6; i++) {
        final warm = await source(
            warmReaders[i % 2], fixture.url('/quota-$i.png'),
            page: i);
        warmSources.add(warm);
        owned.add(warm);
      }
      final warmFiles =
          await Future.wait(warmSources.map((page) => page.openOriginalFile()));
      expect(available, 640 << 20);
      expect(ImageDiskQuota.overrideForTesting, same(controlled));
      expect(warmFiles.map((file) => file.path).toList(),
          files.map((file) => file.path).toList());
      expect(fixture.requests, hasLength(6),
          reason:
              'all six warm pages must hit the existing processed originals');
      expect(controlled.rejectedCount, 0);
      expect(ImageTemporaryPool.shared.reservedBytes, 0);
      expect(
          observedReservations
              .skip(observationsBeforeWarm)
              .every((bytes) => bytes == 0),
          isTrue,
          reason:
              'warm hits must not stage additional raw or generic 512MiB inputs');
      expect(controlled.activeBytes, lessThan(1 << 20));
      expect(
          controlled.reservations
              .where((entry) => !claimsBeforeWarm.contains(entry['path'])),
          isEmpty,
          reason: 'warm opens share the existing actual-file claims');
      for (var i = 0; i < warmFiles.length; i++) {
        final file = warmFiles[i];
        final bytes = await file.readAsBytes();
        expect(sha256.convert(bytes).toString(), coldHashes[i]);
        expect(warmSources[i].byteLength, bytes.length);
        expect(DerivedImageStore.isPathLeased(file.path), isTrue);
        final family = p.withoutExtension(file.path);
        final normalized = p.normalize(p.absolute(family));
        final claimPath =
            Platform.isWindows ? normalized.toLowerCase() : normalized;
        final claims = controlled.reservations
            .where((entry) => entry['path'] == claimPath)
            .toList();
        expect(claims, hasLength(1));
        expect(claims.single['finished'], isTrue);
        expect(claims.single['peakBytes'],
            bytes.length + await File('$family.json').length(),
            reason: 'warm owners retain actual body/metadata bytes only');
      }

      final before = (await Directory(App.cachePath)
              .list(recursive: true)
              .where((entry) => entry is File)
              .toList())
          .map((entry) => entry.path)
          .toSet();
      available = ((512 + 64) << 20) - 1;
      final deniedReader = data(episode: '230000');
      final deniedUrl = fixture.url('/quota-denied.png');
      final denied = await source(deniedReader, deniedUrl, page: 99);
      owned.add(denied);
      await expectLater(
          denied.openOriginalFile(), throwsA(isA<ImageDiskQuotaExceeded>()));
      expect(controlled.rejectedCount, greaterThan(0));
      expect(fixture.requests, hasLength(7));
      expect(
          await OnlineImageCache.instance
              .get(_processedKey(deniedReader, 99, deniedUrl)),
          isNull);
      final after = await Directory(App.cachePath)
          .list(recursive: true)
          .where((entry) => entry is File)
          .toList();
      expect(after.where((entry) => !before.contains(entry.path)), isEmpty,
          reason:
              'failed admission must not publish a body, metadata or .part');
      expect(after.where((entry) => entry.path.endsWith('.part')), isEmpty);
      for (final file in files) {
        expect(await file.exists(), isTrue,
            reason: 'six leased successful pages remain intact');
      }
    } finally {
      try {
        // Cold and warm objects can share files: launch every disposal before
        // joining any one source's shared-file lifetime.
        await Future.wait(owned.map((page) => page.dispose()));
        for (final page in owned) {
          sources.remove(page);
        }
        // OnlineImageCache has a real five-second publication grace lease.
        // Drain it before restoring the quota; do not leak claims into a later test.
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (true) {
          await controlled.drain();
          if (controlled.activeBytes == 0 && controlled.pendingCount == 0) {
            break;
          }
          if (DateTime.now().isAfter(deadline)) {
            fail('JM cache grace leases did not drain');
          }
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(ImageTemporaryPool.shared.reservedBytes, 0);
        expect(ReaderPageFileLease.activeLeaseCount, 0);
      } finally {
        ImageDiskQuota.overrideForTesting = previous;
      }
    }
  });

  test(
      'queued cancellation never fetches or publishes and does not poison later pages',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final calls = <String>[];
    final reading = data(recombine: (bytes,
        {required epsId,
        required scrambleId,
        required pictureName,
        originalExtension = '.webp'}) async {
      calls.add(pictureName);
      if (pictureName == 'blocker') {
        entered.complete();
        await release.future;
      }
      return (bytes: bytes, extension: '.png');
    });
    final fixture = await serve((_, __) => HttpImageReply(png));
    final blocker = await source(reading, fixture.url('/blocker.png'));
    final blocking = blocker.openOriginalFile();
    await entered.future.timeout(const Duration(seconds: 3));
    final url = fixture.url('/queued.png');
    final queued = await source(reading, url, page: 1);
    final token = ReaderPageCancellation();
    final opening = queued.openOriginalFile(cancellation: token);
    final rejected = expectLater(opening, throwsA(anything));
    // Allow the cache-miss probe to join the serial queue behind the gate.
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(fixture.requests.map((uri) => uri.path), ['/blocker.png']);
    token.cancel();
    await rejected;
    await queued.dispose();
    release.complete();
    await blocking;
    // Waiting for a subsequent serialized page also drains the cancelled job.
    final following =
        await source(reading, fixture.url('/following.png'), page: 2);
    await following.openOriginalFile();
    expect(fixture.requests.map((uri) => uri.path),
        ['/blocker.png', '/following.png']);
    expect(calls, ['blocker', 'following']);
    expect(await OnlineImageCache.instance.get(_processedKey(reading, 1, url)),
        isNull);
  });

  test(
      'raw-transfer cancellation promptly releases serial admission and no processed cache',
      () async {
    final arrived = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final fixture = await serve((uri, _) {
      if (uri.path == '/cancel.png') {
        if (!arrived.isCompleted) arrived.complete();
        return HttpImageReply(png, prefixBytes: 32, release: release.future);
      }
      return HttpImageReply(png);
    });
    var calls = 0;
    final reading = data(recombine: (bytes,
        {required epsId,
        required scrambleId,
        required pictureName,
        originalExtension = '.webp'}) async {
      calls++;
      return (bytes: bytes, extension: '.png');
    });
    final url = fixture.url('/cancel.png');
    final cancelled = await source(reading, url);
    final token = ReaderPageCancellation();
    final opening = cancelled.openOriginalFile(cancellation: token);
    final rejected = expectLater(opening, throwsA(anything));
    await arrived.future.timeout(const Duration(seconds: 3));
    token.cancel();
    await rejected.timeout(const Duration(seconds: 3));
    await cancelled.dispose();
    final healthy = await source(reading, fixture.url('/healthy.png'), page: 1);
    await healthy.openOriginalFile().timeout(const Duration(seconds: 3));
    expect(calls, 1, reason: 'cancelled raw body never enters recombination');
    expect(await OnlineImageCache.instance.get(_processedKey(reading, 0, url)),
        isNull);
    release.complete();
    await until(() => ImageTemporaryPool.shared.reservedBytes == 0,
        'Cancelled raw cache workspace did not drain');
    expect(
        await Directory(App.cachePath)
            .list(recursive: true)
            .where((entry) => entry.path.endsWith('.part'))
            .toList(),
        isEmpty);
  });

  test(
      'last consumer cancelled during recombination does not publish stale output',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    var calls = 0;
    final reading = data(recombine: (bytes,
        {required epsId,
        required scrambleId,
        required pictureName,
        originalExtension = '.webp'}) async {
      calls++;
      if (calls == 1) {
        entered.complete();
        await release.future;
      }
      return (bytes: bytes, extension: '.png');
    });
    final fixture = await serve((_, __) => HttpImageReply(png));
    final url = fixture.url('/recombine.png');
    final old = await source(reading, url);
    final token = ReaderPageCancellation();
    final opening = old.openOriginalFile(cancellation: token);
    final rejected = expectLater(opening, throwsA(anything));
    await entered.future.timeout(const Duration(seconds: 3));
    token.cancel();
    await rejected;
    await old.dispose();
    expect(await OnlineImageCache.instance.get(_processedKey(reading, 0, url)),
        isNull);
    release.complete();
    final retry = await source(reading, url);
    expect(await (await retry.openOriginalFile()).readAsBytes(), png);
    expect(calls, 2,
        reason: 'cancelled output was not a valid processed cache hit');
    expect(fixture.requests, hasLength(1),
        reason: 'valid complete raw cache may be reused');
  });

  test(
      'final-file source lease survives grace expiry until source disposal and decoder drain',
      () async {
    final fixture = await serve((_, __) => HttpImageReply(png));
    final reading = data();
    final selected = await source(reading, fixture.url('/lease.png'));
    final file = await selected.openOriginalFile();
    // Cache publication has its own five-second grace lease. Let it expire so
    // this assertion measures the source's lease, not accidental grace protection.
    await Future<void>.delayed(const Duration(milliseconds: 5200));
    expect(DerivedImageStore.isPathLeased(file.path), isTrue);
    await OnlineImageCache.instance.trim(maxBytes: 0);
    expect(await file.exists(), isTrue);
    final releaseDecoder = ReaderPageFileLease.acquire(file);
    var disposed = false;
    final disposing = selected.dispose().then((_) => disposed = true);
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isFalse);
    expect(DerivedImageStore.isPathLeased(file.path), isTrue);
    releaseDecoder();
    await disposing;
    // The cache's last lease schedules asynchronous disk-family release.
    await quota.drain();
    expect(DerivedImageStore.isPathLeased(file.path), isFalse);
    await OnlineImageCache.instance.trim(maxBytes: 0);
    expect(await file.exists(), isFalse);
  });

  test(
      'explicit page retry discards bad raw and processed cache without replacing a leased body',
      () async {
    final bad = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0]);
    var requests = 0;
    final fixture =
        await serve((_, __) => HttpImageReply(++requests == 1 ? bad : png));
    final reading = data();
    final url = fixture.url('/retry.png');
    final oldSource = await source(reading, url);
    final old = await oldSource.openOriginalFile();
    final oldHash = sha256.convert(await old.readAsBytes());
    final badBuffer = await ui.ImmutableBuffer.fromFilePath(old.path);
    try {
      await expectLater(
          Future<ui.ImageDescriptor>.sync(
              () => ui.ImageDescriptor.encoded(badBuffer)),
          throwsA(anything));
    } finally {
      badBuffer.dispose();
    }
    await reading.invalidateImage(1, 0, url);
    expect(await OnlineImageCache.instance.get(_processedKey(reading, 0, url)),
        isNull);
    expect(await old.exists(), isTrue);
    expect(DerivedImageStore.isPathLeased(old.path), isTrue);
    final freshSource = await source(reading, url);
    final fresh = await freshSource.openOriginalFile();
    expect(fresh.path, isNot(old.path));
    expect(requests, 2,
        reason: 'both raw and processed must be fresh on explicit retry');
    expect(await fresh.readAsBytes(), png);
    expect(sha256.convert(await old.readAsBytes()), oldHash);
    final buffer = await ui.ImmutableBuffer.fromFilePath(fresh.path);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      expect(descriptor.width, greaterThan(0));
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
    final warm = await source(reading, url);
    expect((await warm.openOriginalFile()).path, fresh.path);
    expect(requests, 2);
  });

  test(
      'cancelled queued pages do not exhaust the live 32-page admission window',
      () async {
    final entered = Completer<void>(), release = Completer<void>();
    var recombinations = 0;
    final reading = data(recombine: (bytes,
        {required epsId,
        required scrambleId,
        required pictureName,
        originalExtension = '.jpg'}) async {
      if (++recombinations == 1) {
        entered.complete();
        await release.future;
      }
      return (bytes: bytes, extension: originalExtension);
    });
    final fixture = await serve((_, __) => HttpImageReply(png));
    final active = await source(reading, fixture.url('/active.png'));
    final activeFile = active.openOriginalFile();
    await entered.future;
    final cancelled = <Future<void>>[];
    for (var index = 0; index < 40; index++) {
      final queued = await source(reading, fixture.url('/queued-$index.png'),
          page: index + 1);
      final opening = queued.openOriginalFile();
      final rejected = expectLater(opening, throwsA(anything));
      await queued.dispose();
      cancelled.add(rejected);
    }
    final last = await source(reading, fixture.url('/last.png'), page: 50);
    final lastFile = last.openOriginalFile();
    release.complete();
    expect(await (await activeFile).readAsBytes(), png);
    expect(await (await lastFile).readAsBytes(), png);
    await Future.wait(cancelled);
    expect(recombinations, 2);
    expect(fixture.requests, hasLength(2));
  });

  test(
      'invalidation prevents late processed metadata from reviving the old generation',
      () async {
    final entered = Completer<void>(), release = Completer<void>();
    var transforms = 0, requests = 0;
    final second =
        image.encodePng(image.Image(width: 2, height: 3, numChannels: 4));
    final fixture =
        await serve((_, __) => HttpImageReply(++requests == 1 ? png : second));
    final reading = data(recombine: (bytes,
        {required epsId,
        required scrambleId,
        required pictureName,
        originalExtension = '.jpg'}) async {
      if (++transforms == 1) {
        entered.complete();
        await release.future;
      }
      return (bytes: bytes, extension: originalExtension);
    });
    final url = fixture.url('/late-generation.png');
    final old = await source(reading, url);
    final oldOpening = old.openOriginalFile();
    await entered.future;
    await reading.invalidateImage(1, 0, url);
    final fresh = await source(reading, url);
    final freshOpening = fresh.openOriginalFile();
    release.complete();
    final oldFile = await oldOpening;
    final freshFile = await freshOpening;
    expect(oldFile.path, isNot(freshFile.path));
    expect(await oldFile.readAsBytes(), png);
    expect(await freshFile.readAsBytes(), second);
    expect(requests, 2);
    expect(transforms, 2);
    final staleKey = _processedKey(reading, 0, url);
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (await OnlineImageCache.instance.get(staleKey) != null) {
      if (DateTime.now().isAfter(deadline)) {
        fail('late old metadata was republished');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(await oldFile.exists(), isTrue,
        reason: 'the surviving old consumer still owns a file lease');
    final warm = await source(reading, url);
    expect((await warm.openOriginalFile()).path, freshFile.path);
    expect(requests, 2);
  });
}
