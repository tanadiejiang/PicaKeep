import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/komiic_network/komiic_network.dart';
import 'package:picakeep/network/managed_image_retry.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart' as reader;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/http_image_fixture.dart';
import 'support/image_disk_quota_fixture.dart';

const _kinds = ['picacg', 'Komiic', 'pixiv', 'ehentai', 'nhentai'];

PixivComicInfo _pixiv(String id) => PixivComicInfo(
    id: id,
    title: 'Fixture',
    author: 'Fixture',
    authorId: '1',
    coverUrl: '',
    tags: const [],
    description: '',
    pageCount: 1,
    illustType: 0,
    likeCount: 0,
    viewCount: 0,
    width: 24,
    height: 32,
    isOriginal: true,
    createDate: '',
    uploadDate: '',
    userId: '1');

KomiicComicInfo _komiic(String id) => KomiicComicInfo(
    id: id,
    title: 'Fixture',
    coverUrl: '',
    authors: const [],
    tags: const [],
    description: '',
    status: '',
    year: '',
    updateTime: '',
    views: 0,
    monthViews: 0,
    favoriteCount: 0,
    recommendations: const [],
    chapters: const [
      KomiicChapter(
          id: 'chapter-fixture', serial: '1', type: 'chapter', dateUpdated: '')
    ]);

Gallery _gallery(String id) => Gallery(
    'Fixture',
    '',
    '',
    '',
    0,
    null,
    '',
    {},
    [],
    null,
    false,
    'https://e-hentai.org/g/$id/fixture/',
    '1',
    1,
    [],
    'png',
    24,
    null);

class _SourceFixture {
  _SourceFixture(this.data, this.input, this.target, this.metadataCalls);
  final reader.ReadingData data;
  final String input, target;
  final int Function() metadataCalls;
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
  final savedImplicit = List<String>.of(appdata.implicitData);
  final savedSources = List<ComicSource>.of(ComicSource.sources);
  final savedQuota = ImageDiskQuota.overrideForTesting;
  final savedLogging = LogManager.recordingEnabled;
  late Directory root;
  late ImageDiskQuota quota;
  final opened = <ReaderPageSource>[];
  var counter = 571000;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('reader_source_retry_057_');
    App.dataPath = p.join(root.path, 'app');
    App.cachePath = p.join(root.path, 'cache');
    await Directory(App.dataPath).create(recursive: true);
    await Directory(App.cachePath).create(recursive: true);
    appdata.settings[22] = p.join(root.path, 'downloads');
    appdata.settings[20] = '0';
    appdata.implicitData[3] = 'Fixture EH Reader UA';
    SharedPreferences.setMockInitialValues({});
    LogManager.recordingEnabled = false;
    quota = installTaskDiskQuota(() => [App.cachePath]);
    await downloadManager.init();
  });

  setUp(() {
    ComicSource.sources
      ..clear()
      ..addAll([
        for (final key in ['picacg', 'komiic', 'pixiv', 'ehentai', 'nhentai'])
          ComicSource.named(
              key: key, name: 'Fixture', data: {'token': 'account-a'}),
      ]);
    EhNetwork().cookieJar.deleteAll();
    EhNetwork().cookieJar.saveFromResponse(Uri.parse('https://e-hentai.org/'),
        [Cookie('ipb_member_id', 'fixture-member-a')]);
  });

  tearDown(() async {
    for (final source in opened) {
      await source.dispose();
    }
    opened.clear();
    await quota.drain();
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    expect(ImageTemporaryPool.shared.reservedBytes, 0);
  });

  tearDownAll(() async {
    downloadManager.dispose();
    EhNetwork().cookieJar.dispose();
    await quota.drain();
    ImageDiskQuota.overrideForTesting = savedQuota;
    appdata.settings = savedSettings;
    appdata.implicitData = savedImplicit;
    ComicSource.sources
      ..clear()
      ..addAll(savedSources);
    LogManager.recordingEnabled = savedLogging;
    expect(p.basename(root.path), startsWith('reader_source_retry_057_'));
    await root.delete(recursive: true);
  });

  Future<HttpImageFixture> serve(
      HttpImageReply Function(Uri, String) response) async {
    final server = await HttpImageFixture.start(response);
    addTearDown(server.close);
    return server;
  }

  OnlineImageManager images() {
    final dio = directImageDio();
    addTearDown(() => dio.close(force: true));
    return OnlineImageManager.forTesting(dio);
  }

  _SourceFixture create(String kind, String target,
      {OnlineImageManager? manager, bool bestAvailable = false}) {
    manager ??= images();
    final id = '${counter++}';
    var metadataCalls = 0;
    final reader.ReadingData data;
    switch (kind) {
      case 'picacg':
        data = reader.PicacgReadingData(
            comic: PicacgComicItem.fromApi(
                json: {'_id': id, 'title': 'Fixture'},
                eps: const ['One'],
                recommendation: const []),
            imageManager: manager);
      case 'Komiic':
        data =
            reader.KomiicReadingData(comic: _komiic(id), imageManager: manager);
      case 'pixiv':
        data = reader.PixivReadingData(
            comic: _pixiv(id),
            imageManager: manager,
            pagesLoader: () async {
              metadataCalls++;
              return [
                PixivPage(
                    thumbMini: '',
                    small: '',
                    regular: target,
                    original: bestAvailable ? '' : target,
                    width: 24,
                    height: 32)
              ];
            });
      case 'ehentai':
        data = reader.EhReadingData(_gallery(id), imageManager: manager,
            imageUrlLoader: (page) async {
          expect(page, 1);
          metadataCalls++;
          return target;
        });
      case 'nhentai':
        data = reader.NhentaiReadingData(
            comic: NhentaiComic(id, 'Fixture', '', '', {}, false, [], [], ''),
            imageManager: manager);
      default:
        throw StateError(kind);
    }
    return _SourceFixture(
        data, kind == 'ehentai' ? '' : target, target, () => metadataCalls);
  }

  Future<ReaderPageSource> source(_SourceFixture fixture) async {
    final result = await fixture.data.resolvePageSource(1, 0, fixture.input);
    opened.add(result);
    return result;
  }

  Future<List<int>> progress(_SourceFixture fixture,
      {StreamImageAbortSignal? abort, int? expected}) async {
    final result = await fixture.data.loadOriginalNetworkWithProgress(
        1, 0, fixture.input,
        abortSignal: abort);
    if (expected != null) expect(result.expectedTotalBytes, expected);
    return result.stream.expand((chunk) => chunk).toList();
  }

  void expectHeaders(String kind, _SourceFixture fixture, String raw) {
    final headers = raw.toLowerCase();
    switch (kind) {
      case 'Komiic':
        expect(
            headers,
            contains(
                'referer: https://komiic.com/comic/${fixture.data.id}/chapter/chapter-fixture/images/all'));
        expect(headers, contains('authorization: bearer account-a'));
        expect(headers,
            contains('user-agent: ${KomiicNetwork.komiicUA.toLowerCase()}'));
      case 'pixiv':
        expect(headers, contains('referer: https://www.pixiv.net/'));
        expect(headers,
            contains('user-agent: ${PixivNetwork.pixivWebUA.toLowerCase()}'));
      case 'ehentai':
        expect(headers, contains('referer: https://e-hentai.org'));
        expect(headers, contains('cookie: ipb_member_id=fixture-member-a'));
        expect(headers, contains('user-agent: fixture eh reader ua'));
      case 'nhentai':
        expect(headers, contains('referer: https://nhentai.net/'));
      case 'picacg':
        expect(headers, isNot(contains('authorization:')));
    }
  }

  for (final kind in _kinds) {
    test(
        '$kind production sharp source and progress share headers and complete cache',
        () async {
      final server = await serve((_, __) => HttpImageReply(png));
      final fixture = create(kind, server.url('/image.png'));
      final sharp = await source(fixture);
      final file = await sharp.openOriginalFile();
      expect(await file.readAsBytes(), png);
      expect(sharp.identity.sourceKey, kind);
      expect(sharp.identity.sourceVersion, 'original:${fixture.target}');
      expect(await progress(fixture, expected: png.length), png);
      expect(server.requests, hasLength(1),
          reason: 'display paths must use the same complete-image cache');
      expectHeaders(kind, fixture, server.requestHeaders.single);
      final metadataBefore = fixture.metadataCalls();
      await fixture.data.invalidateImage(1, 0, fixture.input);
      expect(fixture.metadataCalls(), metadataBefore,
          reason: 'retry invalidation must not resolve a new URL');
      final retried = await source(fixture);
      final fresh = await retried.openOriginalFile();
      expect(fresh.path, isNot(file.path));
      expect(retried.identity.stableKey, sharp.identity.stableKey);
      expect(await fresh.readAsBytes(), png);
      expect(server.requests, hasLength(2));
      expect(await file.exists(), isTrue,
          reason: 'live old consumers retain their file lease');
      expect(await progress(fixture, expected: png.length), png);
      expect(server.requests, hasLength(2));
    });

    test(
        '$kind explicitly retries a cached image-decode failure with fresh bytes',
        () async {
      var requests = 0;
      final server = await serve(
          (_, __) => HttpImageReply(++requests == 1 ? [1, 2, 3] : png));
      final fixture = create(kind, server.url('/retry.png'));
      final broken = await source(fixture);
      final stale = await broken.openOriginalFile();
      await expectLater(ui.instantiateImageCodec(await stale.readAsBytes()),
          throwsA(anything));
      await fixture.data.invalidateImage(1, 0, fixture.input);
      final retry = await source(fixture);
      final fresh = await retry.openOriginalFile();
      final codec = await ui.instantiateImageCodec(await fresh.readAsBytes());
      final frame = await codec.getNextFrame();
      expect((frame.image.width, frame.image.height), (24, 32));
      frame.image.dispose();
      codec.dispose();
      expect(requests, 2);
      expect(fresh.path, isNot(stale.path));
    });

    test('$kind progress forwards abort during the raw HTTP body', () async {
      final arrived = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var requests = 0;
      final server = await serve((_, __) {
        requests++;
        if (requests == 1) {
          arrived.complete();
          return HttpImageReply(png, prefixBytes: 32, release: release.future);
        }
        return HttpImageReply(png);
      });
      final fixture = create(kind, server.url('/abort.png'));
      final abort = StreamImageAbortSignal();
      final loading = fixture.data.loadOriginalNetworkWithProgress(
          1, 0, fixture.input,
          abortSignal: abort);
      await arrived.future.timeout(const Duration(seconds: 3));
      final response = await loading.timeout(const Duration(seconds: 3));
      expect(response.expectedTotalBytes, png.length);
      final pending = response.stream.expand((chunk) => chunk).toList();
      final rejected = expectLater(pending, throwsA(anything));
      abort.abort();
      await rejected.timeout(const Duration(seconds: 3));
      release.complete();
      expect(await progress(fixture, expected: png.length), png);
      expect(requests, 2);
    });

    test(
        '$kind downloaded invalidation is a no-op for original files and cache',
        () async {
      final server = await serve((_, __) => HttpImageReply(png));
      final fixture = create(kind, server.url('/downloaded.png'));
      final originalSource = await source(fixture);
      final cached = await originalSource.openOriginalFile();
      final directory = await Directory(p.join(root.path, 'downloads',
              fixture.data.downloadId.replaceAll('/', '_')))
          .create(recursive: true);
      final userOriginal = File(p.join(directory.path, '1.png'));
      await userOriginal.writeAsBytes(png);
      final before = sha256.convert(await userOriginal.readAsBytes());
      final db = sqlite3.open(downloadManager.dbFilePath!);
      try {
        db.execute('insert into download values (?,?,?,?,?,?,?)', [
          fixture.data.downloadId,
          'Fixture',
          '',
          0,
          p.basename(directory.path),
          png.length,
          '{}'
        ]);
        fixture.data.downloadedEps = [0];
        expect(fixture.data.downloaded, isTrue);
        final metadataBefore = fixture.metadataCalls();
        await fixture.data.invalidateImage(1, 0, fixture.input);
        expect(fixture.metadataCalls(), metadataBefore);
        expect(sha256.convert(await userOriginal.readAsBytes()), before);
        expect(await cached.exists(), isTrue);
        db.execute(
            'delete from download where id = ?', [fixture.data.downloadId]);
      } finally {
        db.dispose();
      }
      final reread = await source(fixture);
      expect((await reread.openOriginalFile()).path, cached.path);
      expect(server.requests, hasLength(1),
          reason:
              'downloaded retry did not invalidate the network cache either');
    });
  }

  test('Komiic invalidation never clears another Bearer scope on the same URL',
      () async {
    final server = await serve((_, __) => HttpImageReply(png));
    final fixture = create('Komiic', server.url('/accounts.png'));
    final account = ComicSource.require('komiic');
    final a = await source(fixture);
    final aFile = await a.openOriginalFile();
    account.data['token'] = 'account-b';
    final b = await source(fixture);
    final bFile = await b.openOriginalFile();
    expect(aFile.path, isNot(bFile.path));
    await fixture.data.invalidateImage(1, 0, fixture.input);
    final bRetry = await source(fixture);
    expect((await bRetry.openOriginalFile()).path, isNot(bFile.path));
    expect(server.requests, hasLength(3));
    account.data['token'] = 'account-a';
    final aWarm = await source(fixture);
    expect((await aWarm.openOriginalFile()).path, aFile.path);
    expect(server.requests, hasLength(3));
  });

  test(
      'source invalidation retires both managed and ordinary retry-policy caches',
      () async {
    final server = await serve((_, __) => HttpImageReply(png));
    final fixture = create('Komiic', server.url('/retry-policies.png'));
    expect(await progress(fixture, expected: png.length), png);
    expect(
        await runWithManagedImageRetry(
            () => progress(fixture, expected: png.length)),
        png);
    expect(server.requests, hasLength(2));
    await fixture.data.invalidateImage(1, 0, fixture.input);
    expect(await progress(fixture, expected: png.length), png);
    expect(
        await runWithManagedImageRetry(
            () => progress(fixture, expected: png.length)),
        png);
    expect(server.requests, hasLength(4));
  });

  for (final change in ['cookie', 'account-scope']) {
    test('EH does not invalidate a previous request after $change changes',
        () async {
      final server = await serve((_, __) => HttpImageReply(png));
      final fixture = create('ehentai', server.url('/eh-account.png'));
      final first = await source(fixture);
      final file = await first.openOriginalFile();
      final metadataBefore = fixture.metadataCalls();
      if (change == 'cookie') {
        EhNetwork().cookieJar.saveFromResponse(
            Uri.parse('https://e-hentai.org/'),
            [Cookie('ipb_member_id', 'fixture-member-b')]);
      } else {
        ComicSource.require('ehentai').data['token'] = 'account-b';
      }
      await fixture.data.invalidateImage(1, 0, fixture.input);
      expect(fixture.metadataCalls(), metadataBefore);
      EhNetwork().cookieJar.saveFromResponse(Uri.parse('https://e-hentai.org/'),
          [Cookie('ipb_member_id', 'fixture-member-a')]);
      ComicSource.require('ehentai').data['token'] = 'account-a';
      final warm = await source(fixture);
      expect((await warm.openOriginalFile()).path, file.path);
      expect(server.requests, hasLength(1));
    });
  }

  test(
      'Pixiv highest-available fallback keeps tier identity and invalidates exact target',
      () async {
    final server = await serve((_, __) => HttpImageReply(png));
    final fixture =
        create('pixiv', server.url('/regular.png'), bestAvailable: true);
    final selected = await source(fixture);
    final file = await selected.openOriginalFile();
    expect(selected.isAuthoritativeOriginal, isFalse);
    expect(selected.identity.sourceVersion, 'bestAvailable:${fixture.target}');
    expect(selected.width, isNull);
    expect(selected.height, isNull);
    await fixture.data.invalidateImage(1, 0, 'unused-stale-url');
    final retry = await source(fixture);
    expect((await retry.openOriginalFile()).path, isNot(file.path));
    expect(server.requests.map((uri) => uri.path),
        ['/regular.png', '/regular.png']);
  });
}
