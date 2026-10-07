import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive_io.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/archive/archive_registry.dart';
import 'package:picakeep/foundation/archive/archive_backend.dart';
import 'package:picakeep/foundation/archive/archive_models.dart';
import 'package:picakeep/foundation/archive/backends/dart_zip_backend.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_trash_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_derivative_renderer.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/image_server_protocol.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/image_pipeline/server_reader_page_source.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/server/server_app.dart';
import 'package:picakeep/server/server_config.dart';
import 'package:sqlite3/open.dart';
import 'support/image_disk_quota_fixture.dart';

class _SlowRenderer implements ImageDerivativeRenderer {
  final delegate = const BoundedDartImageDerivativeRenderer();
  Duration delay = Duration.zero;
  int renders = 0;
  @override
  bool get supportsLargeRegions => false;
  @override
  Future<ImageDerivativeProbe> probe(String path) => delegate.probe(path);
  @override
  Future<ImageDerivativeRaster> render(
    String path, {
    required ImageDerivativeRect region,
    required int width,
    required int height,
    required String format,
    required String backingPath,
    required bool Function() isCancelled,
    int? jobBudgetBytes,
  }) async {
    renders++;
    await Future<void>.delayed(delay);
    return delegate.render(path,
        region: region,
        width: width,
        height: height,
        format: format,
        backingPath: backingPath,
        jobBudgetBytes: jobBudgetBytes,
        isCancelled: isCancelled);
  }
}

class _RealHttpOverrides extends HttpOverrides {}

class _ChangedArchiveBackend extends ArchiveBackend
    implements StreamingArchiveBackend {
  final delegate = DartZipBackend();
  Future<void> Function()? changeBeforeMaterialize;
  int? observedMaximum;
  @override
  String get id => 'quota-reservation-zip';
  @override
  ArchiveBackendCapabilities get capabilities => delegate.capabilities;
  @override
  bool supportsPath(String path) => path.endsWith('-reservation.zip');
  @override
  Future<ArchiveProbeResult> probe(String path) => delegate.probe(path);
  @override
  Future<ArchiveIndex> openIndex(String path, {String? password}) =>
      delegate.openIndex(path, password: password);
  @override
  Future<Uint8List> readEntry(String path, String entry, {String? password}) =>
      delegate.readEntry(path, entry, password: password);
  @override
  Future<File> materializeEntry(String path, String entry, File destination,
      {String? password,
      int maxBytes = 2 << 30,
      bool Function()? isCancelled}) async {
    observedMaximum = maxBytes;
    await changeBeforeMaterialize?.call();
    return delegate.materializeEntry(path, entry, destination,
        password: password, maxBytes: maxBytes, isCancelled: isCancelled);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  late PicaKeepAdminServer server;
  late _SlowRenderer renderer;
  late String base;
  late String itemId;
  late Uint8List original;
  final savedSettings = List<String>.of(appdata.settings);
  late HttpClient client;
  late HttpOverrides? savedHttpOverrides;
  final changedArchive = _ChangedArchiveBackend();
  Future<({int status, Map<String, String> headers, Uint8List body})> get(
      String path,
      {String? etag}) async {
    final request = await client.getUrl(Uri.parse('$base$path'));
    if (etag != null) request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
    final response = await request.close();
    final headers = <String, String>{};
    response.headers.forEach((key, value) => headers[key] = value.join(', '));
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
    }
    return (
      status: response.statusCode,
      headers: headers,
      body: bytes.takeBytes()
    );
  }

  setUpAll(() async {
    savedHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    client = HttpClient();
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows,
          () => DynamicLibrary.open(
              p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
    }
    final parent = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-runtime')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    workspace = await parent.createTemp('pk022-http-');
    installTaskDiskQuota(() => [workspace.path]);
    App.dataPath = p.join(workspace.path, 'app');
    App.cachePath = p.join(workspace.path, 'cache');
    await Directory(App.dataPath).create();
    ArchiveRegistry.instance.register(changedArchive);
    ArchiveRegistry.instance.register(DartZipBackend());
    final library = Directory(p.join(workspace.path, 'library', '作品%一'));
    await library.create(recursive: true);
    final image = img.Image(width: 700, height: 650, numChannels: 4);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgba(x, y, x % 256, y % 256, (x + y) % 256, 255);
      }
    }
    original = Uint8List.fromList(img.encodePng(image));
    await File(p.join(library.path, '1.png')).writeAsBytes(original);
    await File(p.join(library.path, 'cover.png')).writeAsBytes(original);
    renderer = _SlowRenderer();
    server = PicaKeepAdminServer(
        configPath: p.join(workspace.path, 'server.data'),
        imageRenderer: renderer,
        imageResponseWait: const Duration(milliseconds: 10));
    await server.start(
        config: PicaKeepServerConfig.defaults().copyWith(
            host: '127.0.0.1',
            port: 0,
            customLibraryRoots: [library.parent.path],
            managedDataRoot: App.dataPath,
            consolePassword: 'test-password'));
    base = server.buildStatusPayload()['statusUrl'] as String;
    base = base.substring(0, base.length - '/status'.length);
    itemId = server.snapshot!.items.single.id;
    appdata.settings[remoteServerAddressSettingIndex] = base;
  });
  tearDownAll(() async {
    client.close(force: true);
    await server.stop();
    LocalFavoritesManager().dispose();
    HistoryManager().dispose();
    LocalTrashStore.instance.dispose();
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    await workspace.delete(recursive: true);
    ImageDiskQuota.overrideForTesting = null;
    HttpOverrides.global = savedHttpOverrides;
  });

  test(
      'full HTTP server keeps original bytes and exposes negotiated capabilities',
      () async {
    final status = jsonDecode(utf8.decode((await get('/status')).body)) as Map;
    expect((status['imageCapabilities'] as Map)['largeRegions'], isFalse);
    final response = await get(imagePagePath(itemId, 0, 0));
    expect(response.status, 200);
    expect(response.body, original);
    final oldCover =
        await get('/api/library/items/${Uri.encodeComponent(itemId)}/cover');
    expect(oldCover.body, original);
    expect((await get('/api/admin/summary')).status, 401);
  });
  test(
      'manifest points at exact source coordinates and lossless native tile pixels',
      () async {
    final path = imagePagePath(itemId, 0, 0);
    final response = await get('$path/manifest');
    expect(response.status, 200);
    final manifest = ImagePageManifest.fromJson(Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.body)) as Map));
    expect((manifest.width, manifest.height), (700, 650));
    expect(manifest.algorithmVersion, imageDerivativeAlgorithmVersion);
    expect(Uri.parse(manifest.levels.last.url).queryParameters['a'],
        '$imageDerivativeAlgorithmVersion');
    final oldStore = DerivedImageStore(
        p.join(App.dataPath, 'cache', 'image_pipeline_v1', 'server'));
    try {
      final oldPixels = img.Image(width: 188, height: 138);
      final oldBytes = img.encodePng(oldPixels);
      await oldStore.put(
          key: DerivedImageKey(
              namespace: 'server-page',
              resourceId: '$itemId:0:0',
              sourceVersion: manifest.sourceVersion,
              usage: DerivedImageUsage.readerTile,
              variant: 'tile:${manifest.levels.last.index}:1:1:512:png'),
          content: Stream.value(oldBytes),
          mimeType: 'image/png',
          width: 188,
          height: 138,
          lossless: true,
          maximumBytes: oldBytes.length,
          canPublish: () => true);
    } finally {
      oldStore.dispose();
    }
    final tileUrl = manifest.levels.last.tileUrlTemplate
        .replaceAll('{x}', '1')
        .replaceAll('{y}', '1');
    var tile = await get(tileUrl);
    for (var i = 0; tile.status == 202 && i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      tile = await get(tileUrl);
    }
    expect(tile.status, 200);
    expect(tile.headers['content-type'], 'image/png');
    final decoded = img.decodePng(tile.body)!;
    expect((decoded.width, decoded.height), (188, 138));
    final reference = img.decodePng(original)!;
    for (var y = 0; y < decoded.height; y++) {
      for (var x = 0; x < decoded.width; x++) {
        expect(decoded.getPixel(x, y).toList(),
            reference.getPixel(x + 512, y + 512).toList());
      }
    }
    expect((await get(tileUrl, etag: tile.headers['etag'])).status, 304);
    expect((await get('$path/tiles/0/0/0?v=stale')).status, 409);
    final oldManifest = manifest.toJson()..remove('algorithmVersion');
    expect(
        ImagePageManifest.fromJson(Map<String, dynamic>.from(oldManifest))
            .algorithmVersion,
        1);
  });
  test(
      'slow preparing response retains one job across polls; JSON never image cached',
      () async {
    renderer.delay = const Duration(milliseconds: 200);
    final path = imagePagePath(itemId, 0, 0);
    final manifest =
        jsonDecode(utf8.decode((await get('$path/manifest')).body)) as Map;
    final highest = (manifest['levels'] as List).last['index'];
    final url = '$path/tiles/$highest/0/0?v=${manifest['sourceVersion']}';
    final before = renderer.renders;
    final first = await get(url);
    final second = await get(url);
    expect(first.status, 202);
    expect(second.status, 202);
    expect(first.headers['content-type'], contains('application/json'));
    expect(jsonDecode(utf8.decode(first.body))['state'], 'preparing');
    var finalResponse = second;
    for (var i = 0; finalResponse.status == 202 && i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      finalResponse = await get(url);
    }
    expect(finalResponse.status, 200);
    expect(renderer.renders - before, 1);
    renderer.delay = Duration.zero;
  });
  test(
      'new client handles typed state, conditional body eviction and original compatibility',
      () async {
    final remote = RemoteLibraryClient.fromCurrentSettings();
    final manifest =
        (await remote.fetchImageManifest(imagePagePath(itemId, 0, 0)))!;
    final url = manifest.levels.last.tileUrlTemplate
        .replaceAll('{x}', '0')
        .replaceAll('{y}', '0');
    final ready = await remote.loadImageDerivative(url);
    expect(ready.isImage, isTrue);
    final conditional = await remote.loadImageDerivative(url,
        etag: ready.headers['etag'], localBody: () async => null);
    expect(conditional.statusCode, 200);
    expect(conditional.body, ready.body);
    final version = server.buildStatusPayload();
    expect(version['serviceName'], 'PicaKeepServer');
  });
  test('remote raster metadata and exact tile do not download the original',
      () async {
    final remote = RemoteLibraryClient.fromCurrentSettings();
    final path = imagePagePath(itemId, 0, 0);
    final manifest = (await remote.fetchImageManifest(path))!;
    var originalsOpened = 0;
    final source = ServerReaderPageSource(
        original: DeferredReaderPageSource(
            identity: ReaderPageIdentity(
                sourceKey: 'remote',
                workId: itemId,
                downloadId: itemId,
                episode: 0,
                page: 0,
                sourceVersion: 'url-version'),
            ownsFile: false,
            opener: (cancellation) async {
              originalsOpened++;
              final response = await get(manifest.originalUrl);
              expect(response.status, 200);
              final file =
                  File(p.join(workspace.path, 'exported-original.png'));
              return file.writeAsBytes(response.body);
            }),
        manifest: manifest,
        cacheRoot: p.join(App.dataPath, 'cache', 'remote-reader'),
        serverScope: base,
        request: (url, {etag, maximumBodyBytes, localBody, abortSignal}) =>
            remote.loadImageDerivative(url,
                etag: etag,
                maximumBodyBytes: maximumBodyBytes ?? 32 * 1024 * 1024,
                localBody: localBody,
                abortSignal: abortSignal),
        refreshManifest: () async {
          await remote.fetchImageManifest(path);
        });
    try {
      final metadata = await source.openRasterMetadata();
      expect(metadata.size, const ui.Size(700, 650));
      expect(source.rasterBackend.requiresFileBacking, isFalse);
      expect(originalsOpened, 0);
      const demand =
          ReaderTileDemand(ui.Rect.fromLTWH(512, 512, 188, 138), 1, 1, 1);
      final image = await source.rasterBackend.decode(
          source.rasterLocator, demand,
          backingPath: p.join(workspace.path, 'unused-remote.pixels'),
          memoryBudgetBytes: 32 * 1024 * 1024,
          isCancelled: () => false);
      try {
        expect((image.width, image.height), (188, 138));
        final pixels =
            (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
                .buffer
                .asUint8List();
        final reference = img.decodePng(original)!;
        for (var y = 0; y < image.height; y++) {
          for (var x = 0; x < image.width; x++) {
            final offset = (y * image.width + x) * 4;
            expect(pixels.sublist(offset, offset + 4),
                reference.getPixel(x + 512, y + 512).toList());
          }
        }
        expect(originalsOpened, 0);
      } finally {
        image.dispose();
      }
      final preview = await source.rasterBackend.decode(source.rasterLocator,
          const ReaderTileDemand(ui.Rect.fromLTWH(0, 0, 700, 650), .3, -1, -1),
          backingPath: p.join(workspace.path, 'unused-preview.pixels'),
          memoryBudgetBytes: 32 * 1024 * 1024,
          isCancelled: () => false);
      expect((preview.width, preview.height), (210, 195));
      preview.dispose();
      expect(originalsOpened, 0);
      expect(await (await source.openOriginalFile()).readAsBytes(), original);
      expect(originalsOpened, 1);
    } finally {
      await source.dispose();
    }
  });
  test('old service without capabilities keeps the original image path',
      () async {
    final legacy = await HttpServer.bind('127.0.0.1', 0);
    final requests = <String>[];
    legacy.listen((request) async {
      requests.add(request.uri.path);
      if (request.uri.path == '/status') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'serviceName': 'PicaKeepServer'}));
      } else {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(original);
      }
      await request.response.close();
    });
    try {
      appdata.settings[remoteServerAddressSettingIndex] =
          'http://127.0.0.1:${legacy.port}';
      final remote = RemoteLibraryClient.fromCurrentSettings();
      expect(
          await remote.fetchImageManifest('/api/library/items/old/pages/0/0'),
          isNull);
      expect(
          await remote
              .loadCoverDerivative('/api/library/items/old/cover?v=old'),
          isNull);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in remote.loadImage('/original.png')) {
        bytes.add(chunk);
      }
      expect(bytes.takeBytes(), original);
      expect(requests, ['/status', '/original.png']);
    } finally {
      await legacy.close(force: true);
      appdata.settings[remoteServerAddressSettingIndex] = base;
    }
  });
  test(
      'response bodies exceeding requested memory bounds abort and recover connection permits',
      () async {
    final endpoint = await HttpServer.bind('127.0.0.1', 0);
    var requests = 0;
    endpoint.listen((request) async {
      requests++;
      request.response.headers.contentType = ContentType('image', 'png');
      if (request.uri.path == '/stream') {
        request.response.bufferOutput = false;
        request.response.add(original.sublist(0, 16));
        await request.response.flush();
        request.response.add(original.sublist(16));
      } else {
        request.response.contentLength = original.length;
        request.response.add(original);
      }
      try {
        await request.response.close();
      } catch (_) {}
    });
    try {
      appdata.settings[remoteServerAddressSettingIndex] =
          'http://127.0.0.1:${endpoint.port}';
      final remote = RemoteLibraryClient.fromCurrentSettings();
      for (var i = 0; i < 8; i++) {
        await expectLater(
            remote.loadImageDerivative(i.isEven ? '/declared' : '/stream',
                maximumBodyBytes: 64),
            throwsA(isA<RemoteLibraryDataSourceException>()));
      }
      final recovered = await remote.loadImageDerivative('/recovered',
          maximumBodyBytes: original.length);
      expect(recovered.isImage, isTrue);
      expect(recovered.body, original);
      expect(requests, 9);
    } finally {
      await endpoint.close(force: true);
      appdata.settings[remoteServerAddressSettingIndex] = base;
    }
  });
  test(
      'abort after derivative response headers promptly closes stalled body and recovers its permit',
      () async {
    final endpoint = await HttpServer.bind('127.0.0.1', 0);
    final sent = <Completer<void>>[];
    final hold = Completer<void>();
    endpoint.listen((request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      if (request.uri.path == '/stall') {
        request.response.contentLength = original.length;
        request.response.add(original.sublist(0, 16));
        await request.response.flush();
        sent.last.complete();
        await hold.future;
        try {
          request.response.add(original.sublist(16));
        } catch (_) {}
      } else {
        request.response.add(original);
      }
      try {
        await request.response.close();
      } catch (_) {}
    });
    try {
      appdata.settings[remoteServerAddressSettingIndex] =
          'http://127.0.0.1:${endpoint.port}';
      final remote = RemoteLibraryClient.fromCurrentSettings();
      for (var i = 0; i < 3; i++) {
        final signal = StreamImageAbortSignal();
        sent.add(Completer<void>());
        final response =
            remote.loadImageDerivative('/stall', abortSignal: signal);
        final cancelled = expectLater(response, throwsA(anything));
        await sent.last.future;
        final clock = Stopwatch()..start();
        signal.abort();
        await cancelled.timeout(const Duration(seconds: 2));
        expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      }
      expect((await remote.loadImageDerivative('/recovered')).body, original);
    } finally {
      hold.complete();
      await endpoint.close(force: true);
      appdata.settings[remoteServerAddressSettingIndex] = base;
    }
  });

  test(
      'declared original headers use exact staging admission and rejected bodies release HTTP permits',
      () async {
    for (var i = 0; i < 1000 && ImageWorkScheduler.shared.hasWork; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(ImageWorkScheduler.shared.hasWork, isFalse);
    final endpoint = await HttpServer.bind('127.0.0.1', 0);
    final hold = Completer<void>();
    endpoint.listen((request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.contentLength = original.length;
      request.response.add(original.sublist(0, 16));
      await request.response.flush();
      if (request.uri.path == '/stall') await hold.future;
      try {
        request.response.add(original.sublist(16));
        await request.response.close();
      } catch (_) {}
    });
    final oldQuota = ImageDiskQuota.overrideForTesting;
    var available = original.length + 2;
    final quota = ImageDiskQuota(
        roots: () => [workspace.path],
        idleLimitBytes: () => 500 << 20,
        headroomBytes: 1,
        space: (_) async => ImageDiskSpace(available, 'task'));
    ImageDiskQuota.overrideForTesting = quota;
    try {
      appdata.settings[remoteServerAddressSettingIndex] =
          'http://127.0.0.1:${endpoint.port}';
      final remote = RemoteLibraryClient.fromCurrentSettings();
      final data = RemoteLibraryReadingData(
          item: RemoteLibraryComicItem.fromJson(
              {'id': 'original-admission', 'title': 'task'}, remote));
      for (var i = 0; i < 4; i++) {
        final source = await data.resolvePageSource(
            0, i, remote.resolveUrlString('/original-$i'));
        final file = await source.openOriginalFile();
        expect(await file.readAsBytes(), original);
        expect(quota.activeBytes, original.length);
        await source.dispose();
        await Future<void>.delayed(Duration.zero);
        await quota.drain();
        expect(quota.pendingCount, 0, reason: quota.reservations.toString());
      }
      available = 0;
      for (var i = 0; i < 4; i++) {
        final denied = await data.resolvePageSource(
            0, i, remote.resolveUrlString('/stall'));
        await expectLater(
            denied.openOriginalFile().timeout(const Duration(seconds: 2)),
            throwsA(isA<ImageDiskQuotaExceeded>()));
        await denied.dispose();
      }
      available = original.length + 2;
      final recovered = await data.resolvePageSource(
          0, 0, remote.resolveUrlString('/recovered'));
      expect(
          await (await recovered.openOriginalFile()).readAsBytes(), original);
      await recovered.dispose();
      await Future<void>.delayed(Duration.zero);
      await quota.drain();
      expect(quota.activeBytes, 0);
      expect(quota.rejectedCount, 4);
    } finally {
      ImageDiskQuota.overrideForTesting = oldQuota;
      hold.complete();
      await endpoint.close(force: true);
      appdata.settings[remoteServerAddressSettingIndex] = base;
    }
  });
  test(
      'ZIP page manifest and lossless tile use bounded member extraction; warm cache repeats safely',
      () async {
    final archive = Archive()
      ..add(ArchiveFile('1.png', original.length, original));
    await File(p.join(workspace.path, 'library', 'archive.zip'))
        .writeAsBytes(ZipEncoder().encode(archive));
    await server.rescanResources();
    final item = server.snapshot!.items.singleWhere((entry) => entry.isArchive);
    final remote = RemoteLibraryClient.fromCurrentSettings();
    final page = imagePagePath(item.id, 0, 0);
    final manifest = (await remote.fetchImageManifest(page))!;
    expect((manifest.width, manifest.height), (700, 650));
    final url = manifest.levels.last.tileUrlTemplate
        .replaceAll('{x}', '1')
        .replaceAll('{y}', '1');
    final first = await remote.loadImageDerivative(url);
    final second = await remote.loadImageDerivative(url);
    expect(first.isImage, isTrue);
    expect(second.body, first.body);
    final raster = img.decodePng(first.body)!;
    expect((raster.width, raster.height), (188, 138));
    final reference = img.decodePng(original)!;
    for (var y = 0; y < raster.height; y++) {
      for (var x = 0; x < raster.width; x++) {
        expect(raster.getPixel(x, y).toList(),
            reference.getPixel(x + 512, y + 512).toList());
      }
    }
    expect((await get(manifest.originalUrl)).body, original);
  });
  test('server ZIP source replacement cannot exceed its admitted member size',
      () async {
    final before =
        Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
    final archiveFile =
        File(p.join(workspace.path, 'library', 'changed-reservation.zip'));
    await archiveFile.writeAsBytes(ZipEncoder()
        .encode(Archive()..add(ArchiveFile('1.png', before.length, before))));
    await server.rescanResources();
    final item = server.snapshot!.items
        .singleWhere((entry) => entry.title == 'changed-reservation');
    final larger = img.encodePng(
        img.Image(width: 700, height: 650)..setPixelRgb(0, 0, 255, 0, 0));
    expect(larger.length, greaterThan(before.length));
    final replacement = ZipEncoder()
        .encode(Archive()..add(ArchiveFile('1.png', larger.length, larger)));
    changedArchive.changeBeforeMaterialize =
        () async => archiveFile.writeAsBytes(replacement);
    final reservedBefore = ImageTemporaryPool.shared.reservedBytes;
    final claimsBefore = ImageDiskQuota.shared.pendingCount;
    try {
      final result = await get('${imagePagePath(item.id, 0, 0)}/manifest');
      expect(result.status, 422);
      expect(changedArchive.observedMaximum, before.length,
          reason: 'The extractor may only spend the reserved member bytes');
      expect(await archiveFile.readAsBytes(), replacement);
      await ImageDiskQuota.shared.drain();
      expect(ImageDiskQuota.shared.pendingCount, claimsBefore);
      expect(ImageTemporaryPool.shared.reservedBytes, reservedBefore);
    } finally {
      changedArchive.changeBeforeMaterialize = null;
    }
  });
  test(
      'server ZIP page lists omit separate covers, preserve chapter pages and retain cover-only fallback',
      () async {
    for (final fixture in ['with-cover', 'only-cover', 'chapters']) {
      final archive = Archive();
      final names = fixture == 'with-cover'
          ? ['cover.jpg', '1.png', '2.png']
          : fixture == 'only-cover'
              ? ['cover.webp']
              : [
                  'part1/cover.png',
                  'part1/1.png',
                  'part2/cover.jpeg',
                  'part2/2.png'
                ];
      for (final name in names) {
        archive.add(ArchiveFile(name, original.length, original));
      }
      await File(p.join(workspace.path, 'library', '$fixture.zip'))
          .writeAsBytes(ZipEncoder().encode(archive));
    }
    await server.rescanResources();
    for (final fixture in ['with-cover', 'only-cover', 'chapters']) {
      final item =
          server.snapshot!.items.singleWhere((item) => item.title == fixture);
      final response =
          await get('/api/library/items/${Uri.encodeComponent(item.id)}');
      expect(response.status, 200);
      final detail = jsonDecode(utf8.decode(response.body)) as Map;
      final episodes = detail['episodes'] as List;
      expect(episodes.length, fixture == 'chapters' ? 2 : 1);
      expect(detail['imageCount'], fixture == 'only-cover' ? 1 : 2);
      for (final episode in episodes) {
        expect(
            (episode['pages'] as List).length, fixture == 'with-cover' ? 2 : 1);
      }
      if (fixture != 'only-cover') {
        expect(
            item.episodes.expand((episode) => episode.imagePaths).any((uri) =>
                (Uri.parse(uri).queryParameters['entry'] ?? '')
                    .split('/')
                    .last
                    .startsWith('cover.')),
            isFalse);
      }
      expect((await get(detail['coverUrl'] as String)).body, original,
          reason: 'cover remains available independently of reading pages');
    }
  });
  test(
      'cover 409 refreshes only cover metadata and retries the new version once',
      () async {
    final endpoint = await HttpServer.bind('127.0.0.1', 0);
    final coverVersions = <String>[];
    var details = 0, manifests = 0;
    endpoint.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/status') {
        request.response.write(jsonEncode({
          'imageCapabilities': const ImageServerCapabilities(
              coverWidths: [384, 768], coverFormats: ['png']).toJson()
        }));
      } else if (request.uri.path.endsWith('/cover')) {
        final version = request.uri.queryParameters['v']!;
        coverVersions.add(version);
        if (version == 'old') {
          request.response.statusCode = 409;
          request.response.write(jsonEncode(
              {'state': 'sourceVersionChanged', 'sourceVersion': 'new'}));
        } else {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.headers.set('x-image-source-version', 'new');
          request.response.add(original);
        }
      } else if (request.uri.path.endsWith('/manifest')) {
        manifests++;
        request.response.statusCode = 500;
      } else {
        details++;
        request.response.write(jsonEncode({
          'id': 'versioned',
          'title': 'test',
          'coverUrl': '/api/library/items/versioned/cover?v=new',
          'episodes': []
        }));
      }
      await request.response.close();
    });
    try {
      appdata.settings[remoteServerAddressSettingIndex] =
          'http://127.0.0.1:${endpoint.port}';
      final remote = RemoteLibraryClient.fromCurrentSettings();
      expect(
          await remote
              .loadCoverDerivative('/api/library/items/versioned/cover?v=old'),
          original);
      expect(coverVersions, ['old', 'new']);
      expect(details, 1);
      expect(manifests, 0);
    } finally {
      await endpoint.close(force: true);
      appdata.settings[remoteServerAddressSettingIndex] = base;
    }
  });
}
