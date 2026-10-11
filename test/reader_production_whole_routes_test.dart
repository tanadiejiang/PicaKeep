import 'dart:async';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:archive/archive.dart' as zip;
import 'package:picakeep/foundation/archive/archive_models.dart';
import 'package:picakeep/foundation/archive/archive_registry.dart';
import 'package:picakeep/foundation/archive/archive_reading_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photo_view/photo_view.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_diagnostics.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/network/komiic_network/komiic_network.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart' as reader;
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep/pages/reader/reader_whole_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';

import 'support/http_image_fixture.dart';
import 'support/image_disk_quota_fixture.dart';

// Count the real local entry points, never replace source resolution/rendering.
class _LocalRouteData extends LocalPathReadingData {
  _LocalRouteData(String source, String fixtureId, List<String> paths)
      : super(
            title: 'Route fixture',
            id: fixtureId,
            downloadId: fixtureId,
            sourceKey: source,
            directoryPath: '',
            hasEp: false,
            comicType: ComicType.other,
            episodeFiles: {0: paths},
            downloadedEpisodeIndexes: const [0]);
  var providers = 0, resolutions = 0;
  final providersByPage = <int, int>{};
  String version = 'v1';
  @override
  ImageProvider createImageProvider(int ep, int page, String url,
      {StreamImageAbortSignal? abortSignal}) {
    providers++;
    providersByPage.update(page, (n) => n + 1, ifAbsent: () => 1);
    return super.createImageProvider(ep, page, url, abortSignal: abortSignal);
  }

  @override
  String buildImageKey(int ep, int page, String url) =>
      '${super.buildImageKey(ep, page, url)}:$version';
  @override
  Future<ReaderPageSource> resolvePageSource(int ep, int page, String url) {
    resolutions++;
    return super.resolvePageSource(ep, page, url);
  }
}

KomiicComicInfo _comic(String id) => KomiicComicInfo(
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
          id: 'fixture-chapter', serial: '1', type: 'chapter', dateUpdated: '')
    ]);

class _HeaderGateKomiic extends reader.KomiicReadingData {
  _HeaderGateKomiic(OnlineImageManager images)
      : super(comic: _comic('gated'), imageManager: images);
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<StreamImageLoadResult> loadOriginalNetworkWithProgress(
      int ep, int page, String url,
      {StreamImageAbortSignal? abortSignal}) async {
    final response = await super.loadOriginalNetworkWithProgress(ep, page, url,
        abortSignal: abortSignal);
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return response;
  }
}

class _EofGateKomiic extends reader.KomiicReadingData {
  _EofGateKomiic(OnlineImageManager images)
      : super(comic: _comic('eof-gated'), imageManager: images);
  final bodyEnded = Completer<void>(), releaseEof = Completer<void>();
  @override
  Future<StreamImageLoadResult> loadOriginalNetworkWithProgress(
      int ep, int page, String url,
      {StreamImageAbortSignal? abortSignal}) async {
    final result = await super.loadOriginalNetworkWithProgress(ep, page, url,
        abortSignal: abortSignal);
    Stream<List<int>> gated() async* {
      yield* result.stream;
      bodyEnded.complete();
      await releaseEof.future;
    }

    return StreamImageLoadResult(
        stream: gated(),
        expectedTotalBytes: result.expectedTotalBytes,
        cancel: result.cancel);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open(
            '${Directory.current.path}/windows/sqlite3.dll'));
  }
  var ehOpened = false;
  final savedQuota = ImageDiskQuota.overrideForTesting;
  final savedSources = List<ComicSource>.of(ComicSource.sources);
  final savedSettings = List<String>.of(appdata.settings);
  final savedImplicit = List<String>.of(appdata.implicitData);
  final savedLog = LogManager.recordingEnabled;
  late Directory root;
  late ImageDiskQuota quota;
  late List<File> files;
  late List<String> originals;
  var serial = 0;
  Uint8List png(int red, int green) => img.encodePng(
      img.Image(width: 64, height: 96)..clear(img.ColorRgb8(red, green, 20)));
  final red = png(200, 10), green = png(10, 200);

  setUpAll(() async {
    root =
        await Directory.systemTemp.createTemp('reader_production_routes_057_');
    App.dataPath = '${root.path}/data';
    App.cachePath = '${root.path}/cache';
    await Directory(App.dataPath).create();
    await Directory(App.cachePath).create();
    quota = installTaskDiskQuota(() => [App.cachePath]);
    files = [for (var i = 0; i < 6; i++) File('${root.path}/page-$i.png')];
    for (var i = 0; i < files.length; i++) {
      await files[i].writeAsBytes(i.isEven ? red : green);
    }
    originals = [
      for (final file in files)
        sha256.convert(await file.readAsBytes()).toString()
    ];
    LogManager.recordingEnabled = false;
  });
  setUp(() {
    appdata.settings[9] = '1';
    appdata.settings[28] = '0';
    appdata.settings[43] = '0';
    appdata.settings[49] = '0';
    appdata.settings[50] = 'zh';
    appdata.implicitData[1] = '0';
    SharedPreferences.setMockInitialValues({});
    ComicSource.sources
      ..clear()
      ..add(ComicSource.named(
          key: 'komiic', name: 'Fixture', data: {'token': 'account-a'}));
    ReaderRasterDiagnostics.drainSamples();
  });
  tearDownAll(() async {
    if (ehOpened) EhNetwork().cookieJar.dispose();
    // Completed widget-zone futures cannot dispatch new callbacks after that
    // FakeAsync is closed. refresh starts an independent real-zone operation
    // (the last widget already asserted its real IO/quota work was drained).
    await quota.refresh();
    await quota.drain();
    ImageDiskQuota.overrideForTesting = savedQuota;
    appdata.settings = savedSettings;
    appdata.implicitData = savedImplicit;
    ComicSource.sources
      ..clear()
      ..addAll(savedSources);
    LogManager.recordingEnabled = savedLog;
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    expect(root.path.split(Platform.pathSeparator).last,
        startsWith('reader_production_routes_057_'));
    await root.delete(recursive: true);
  });

  void mode(ReaderDisplayMode selected,
      {bool illust = false,
      ReaderLargeImagePolicy policy = ReaderLargeImagePolicy.safeWhole}) {
    final other = selected == ReaderDisplayMode.previewFirst
        ? ReaderDisplayMode.sharpFirst
        : ReaderDisplayMode.previewFirst;
    appdata.settings[readerImagePipelineSettingIndex] =
        ReaderImagePipelineSettings(
                comic: illust ? other : selected,
                illust: illust ? selected : other,
                largeImagePolicy: policy)
            .encode();
  }

  Future<void> flush(WidgetTester tester, [int turns = 15]) async {
    for (var i = 0; i < turns; i++) {
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  List<RawImage> pixels(WidgetTester tester) => tester
      .widgetList<RawImage>(find.byType(RawImage))
      .where((image) => image.image != null)
      .toList();
  Future<void> waitPixels(WidgetTester tester) async {
    for (var i = 0; i < 60 && pixels(tester).isEmpty; i++) {
      await flush(tester, 1);
    }
    expect(pixels(tester), isNotEmpty);
    expect(tester.takeException(), isNull);
  }

  Future<reader.ComicReadingPageLogic> mount(WidgetTester tester,
      reader.ReadingData data, List<String> urls, int layout) async {
    appdata.settings[9] = '$layout';
    final page = reader.ComicReadingPage(data, 1, 1);
    // The real constructor defaults illustration sources to single page;
    // this models the user selecting the requested layout afterward.
    appdata.settings[9] = '$layout';
    final logic = StateController.find<reader.ComicReadingPageLogic>();
    logic.urls = urls;
    logic.isLoading = false;
    logic.scrollManager = reader.ScrollManager(logic);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Stack(children: [
      Builder(
          builder: (context) => StateBuilder<reader.ComicReadingPageLogic>(
              builder: (logic) =>
                  page.buildComicView(logic, context, 'production-fixture')))
    ]))));
    await waitPixels(tester);
    return logic;
  }

  Future<void> unmount(
      WidgetTester tester, reader.ComicReadingPageLogic logic) async {
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    logic.clearPhotoViewControllers();
    logic.pageController.dispose();
    logic.scrollController.dispose();
    logic.focusNode.dispose();
    logic.viewportChanges.dispose();
    logic.dispose();
    await flush(tester, 3);
    await tester.runAsync(quota.drain);
    expect(tester.takeException(), isNull);
  }

  for (final source in ['jm', 'local_album']) {
    for (final selected in ReaderDisplayMode.values) {
      for (final layout in [1, 5, 4]) {
        testWidgets(
            'production $source $selected layout=$layout stays whole through transforms and policy',
            (tester) async {
          tester.view.physicalSize = const Size(400, 600);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          mode(selected, illust: source == 'local_album');
          final data = _LocalRouteData(
              source, 'route-${serial++}', files.map((f) => f.path).toList());
          final logic = await mount(
              tester, data, files.map((f) => f.path).toList(), layout);
          if (selected == ReaderDisplayMode.previewFirst) {
            expect(data.providers, greaterThan(0));
            expect(data.resolutions, 0);
            expect(ReaderRasterDiagnostics.drainSamples(), isEmpty,
                reason:
                    'preview never starts the source metadata/probe pipeline');
            expect(find.byType(ReaderWholeImage), findsNothing);
            for (final image in tester.widgetList<Image>(find.byType(Image))) {
              expect(image.image, isNot(isA<ResizeImage>()));
            }
            for (final image in tester.widgetList<reader.ComicImage>(
                find.byType(reader.ComicImage))) {
              expect(image.image, isNot(isA<ResizeImage>()));
            }
            for (final view
                in tester.widgetList<PhotoView>(find.byType(PhotoView))) {
              expect(view.imageProvider, isNot(isA<ResizeImage>()));
            }
          } else {
            expect(data.providers, 0);
            expect(data.resolutions, greaterThan(0));
            expect(find.byType(ReaderWholeImage), findsWidgets);
          }
          expect(find.byType(ReaderImageSurface), findsNothing);
          expect(
              pixels(tester)
                  .every((v) => v.image!.width == 64 && v.image!.height == 96),
              isTrue);
          final episode = logic.order;
          final index = logic.index;
          logic.photoViewController.updateMultiple(
              scale: 2, rotation: 0.15, position: const Offset(10, 15));
          await flush(tester);
          expect(logic.order, episode);
          expect(logic.index, index);
          tester.view.physicalSize = const Size(600, 400);
          await flush(tester);
          expect(logic.index, index);
          expect(find.byType(ReaderImageSurface), findsNothing);
          logic.photoViewController
              .updateMultiple(scale: 1, rotation: 0, position: Offset.zero);
          if (layout == 4) {
            logic.itemScrollController.jumpTo(index: 2);
          } else {
            logic.pageController.jumpToPage(2);
          }
          await flush(tester);
          expect(logic.index, greaterThan(1));
          final moved = logic.index;
          final offset = logic.scrollController.hasClients
              ? logic.scrollController.offset
              : null;
          mode(selected,
              illust: source == 'local_album',
              policy: ReaderLargeImagePolicy.strictOriginal);
          logic.update();
          await flush(tester);
          expect(logic.index, moved);
          expect(logic.order, episode);
          if (offset != null) {
            expect(logic.scrollController.offset, closeTo(offset, 0.1));
          }
          expect(find.byType(ReaderImageSurface), findsNothing);
          if (selected == ReaderDisplayMode.sharpFirst) {
            expect(find.byType(ReaderWholeImage), findsWidgets);
          }
          await unmount(tester, logic);
          await tester.runAsync(() async {
            for (var i = 0; i < files.length; i++) {
              expect(sha256.convert(await files[i].readAsBytes()).toString(),
                  originals[i]);
            }
          });
        });
      }
    }
  }

  testWidgets(
      'builder and preloader share opaque scope/version keys; stale queued closures cannot load',
      (tester) async {
    mode(ReaderDisplayMode.previewFirst);
    appdata.settings[28] = '2';
    final data = _LocalRouteData(
        'jm', 'identity-route', files.map((f) => f.path).toList());
    final logic =
        await mount(tester, data, files.map((f) => f.path).toList(), 1);
    await flush(tester);
    final before = tester
        .widgetList<reader.ReaderPreviewPageImage>(
            find.byType(reader.ReaderPreviewPageImage))
        .first;
    final oldKey = before.resourceKey;
    expect(oldKey, matches(RegExp(r'^reader-page-v1:[a-f0-9]{64}$')));
    expect(oldKey, isNot(contains(root.path)));
    final preloadKeys = logic.previewPreloader.retainedKeys;
    expect(preloadKeys, isNotEmpty);
    data.version = 'v2';
    expect(
        () => before.loadProvider(StreamImageAbortSignal()), throwsStateError);
    logic.update();
    await flush(tester);
    final newKey = tester
        .widgetList<reader.ReaderPreviewPageImage>(
            find.byType(reader.ReaderPreviewPageImage))
        .first
        .resourceKey;
    expect(newKey, isNot(oldKey));
    expect(
        logic.previewPreloader.retainedKeys
            .toSet()
            .intersection(preloadKeys.toSet()),
        isEmpty);
    await unmount(tester, logic);
  });

  testWidgets(
      'production prefetch hands its warm frame to the next visible page',
      (tester) async {
    mode(ReaderDisplayMode.previewFirst);
    appdata.settings[28] = '2';
    final data = _LocalRouteData(
        'jm', 'handoff-route', files.map((f) => f.path).toList());
    final logic =
        await mount(tester, data, files.map((f) => f.path).toList(), 1);
    await flush(tester);
    expect(logic.previewPreloader.retainedKeys, isNotEmpty);
    final warmed = data.providersByPage[1];
    expect(warmed, isNotNull);
    logic.jumpToPage(2);
    await flush(tester);
    expect(logic.index, 2);
    expect(data.providersByPage[1], warmed,
        reason: 'visible must acquire before preload releases');
    expect(data.resolutions, 0);
    expect(find.byType(ReaderImageSurface), findsNothing);
    await unmount(tester, logic);
  });

  testWidgets(
      'actual archive adapter reaches preview/whole and preserves member/container bytes',
      (tester) async {
    ArchiveRegistry.initDefaults();
    final file = (await tester.runAsync(() async {
      final archive = zip.Archive()
        ..addFile(zip.ArchiveFile('1.png', red.length, red));
      final file = await File('${root.path}/reader-original.cbz')
          .writeAsBytes(zip.ZipEncoder().encode(archive));
      await ArchiveReadingService.instance
          .getIndex(file.path, readerInput: true);
      return file;
    }))!;
    final original = (await tester.runAsync(
        () async => sha256.convert(await file.readAsBytes()).toString()))!;
    final uri = buildArchiveUri(file.path, '1.png').toString();
    for (final selected in ReaderDisplayMode.values) {
      mode(selected);
      ReaderRasterDiagnostics.drainSamples();
      final data = _LocalRouteData('jm', 'archive-${selected.name}', [uri]);
      final logic = await mount(tester, data, [uri], 1);
      expect(find.byType(ReaderImageSurface), findsNothing);
      if (selected == ReaderDisplayMode.previewFirst) {
        expect(data.providers, greaterThan(0));
        expect(data.resolutions, 0);
        expect(ReaderRasterDiagnostics.drainSamples(), isEmpty);
      } else {
        expect(data.providers, 0);
        expect(data.resolutions, greaterThan(0));
        expect(find.byType(ReaderWholeImage), findsWidgets);
      }
      expect(pixels(tester).first.image!.width, 64);
      await unmount(tester, logic);
    }
    await tester.runAsync(() async {
      expect(sha256.convert(await file.readAsBytes()).toString(), original);
      final member = await ArchiveReadingService.instance
          .readEntryBytes(file.path, '1.png');
      expect(sha256.convert(member), sha256.convert(red));
    });
  });

  Future<HttpImageFixture> serve(
      HttpImageReply Function(Uri, String) reply) async {
    final fixture = await HttpImageFixture.start(reply);
    addTearDown(fixture.close);
    return fixture;
  }

  OnlineImageManager images() {
    final dio = directImageDio();
    addTearDown(() => dio.close(force: true));
    return OnlineImageManager.forTesting(dio);
  }

  void token(String value) =>
      ComicSource.require('komiic').data['token'] = value;

  test(
      'Komiic provider captured before account switch cannot start the new account request',
      () async {
    final fixture = await serve((_, __) => HttpImageReply(red));
    final data = reader.KomiicReadingData(
        comic: _comic('before-start'), imageManager: images());
    final provider = data.createImageProvider(
        1, 0, fixture.url('/original.png')) as StreamImageProvider;
    final oldKey = provider.key;
    token('account-b');
    final next = data.createImageProvider(1, 0, fixture.url('/original.png'))
        as StreamImageProvider;
    expect(next.key, isNot(oldKey));
    expect(data.sourceKey, 'Komiic');
    final chunks = StreamController<ImageChunkEvent>();
    await expectLater(provider.load(chunks), throwsStateError);
    expect(fixture.requests, isEmpty);
    unawaited(chunks.close());
  });

  test('Komiic scope changed while awaiting headers discards its response',
      () async {
    final body = Completer<void>();
    final fixture =
        await serve((_, __) => HttpImageReply(red, release: body.future));
    final data = _HeaderGateKomiic(images());
    final provider = data.createImageProvider(1, 0, fixture.url('/pending.png'))
        as StreamImageProvider;
    final chunks = StreamController<ImageChunkEvent>();
    final result = expectLater(provider.load(chunks), throwsStateError);
    await data.entered.future;
    token('account-b');
    data.release.complete();
    await result;
    body.complete();
    expect(fixture.requests, hasLength(1));
    expect(fixture.requestHeaders.single, contains('Bearer account-a'));
    unawaited(chunks.close());
  });

  test('Komiic body cannot publish bytes after its captured scope changed',
      () async {
    final body = Completer<void>();
    final fixture =
        await serve((_, __) => HttpImageReply(red, release: body.future));
    final data = _HeaderGateKomiic(images());
    final provider = data.createImageProvider(1, 0, fixture.url('/body.png'))
        as StreamImageProvider;
    final events = StreamController<ImageChunkEvent>.broadcast();
    var chunks = 0;
    final subscription = events.stream.listen((_) => chunks++);
    final checked = expectLater(provider.load(events), throwsStateError);
    await data.entered.future;
    data.release.complete();
    await Future<void>.delayed(Duration.zero);
    token('account-b');
    body.complete();
    await checked;
    expect(chunks, 0);
    expect(
        () => provider.obtainKey(ImageConfiguration.empty), throwsStateError);
    await subscription.cancel();
    await events.close();
  });

  test('Komiic complete body is still discarded if scope changes before EOF',
      () async {
    final fixture = await serve((_, __) => HttpImageReply(red));
    final data = _EofGateKomiic(images());
    final provider = data.createImageProvider(1, 0, fixture.url('/eof.png'))
        as StreamImageProvider;
    final events = StreamController<ImageChunkEvent>.broadcast();
    var received = 0;
    final sub =
        events.stream.listen((event) => received = event.cumulativeBytesLoaded);
    final checked = expectLater(provider.load(events), throwsStateError);
    await data.bodyEnded.future;
    expect(received, red.length);
    token('account-b');
    data.releaseEof.complete();
    await checked;
    await sub.cancel();
    await events.close();
  });

  Gallery ehGallery() => Gallery(
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
      'https://e-hentai.org/g/579001/fixture/',
      '1',
      1,
      [],
      'png',
      64,
      null);
  void ehAccount(String value) {
    ehOpened = true;
    final jar = EhNetwork().cookieJar;
    jar.deleteAll();
    jar.saveFromResponse(Uri.parse('https://e-hentai.org/'), [
      Cookie('ipb_member_id', value),
      Cookie('ipb_pass_hash', 'hash-$value')
    ]);
  }

  test(
      'EH scope reflects real isolated cookies but not transient nw/sp toggles',
      () {
    ehAccount('member-a');
    final data = reader.EhReadingData(ehGallery());
    final first = data.buildImageKey(1, 0, '');
    EhNetwork().cookieJar.saveFromResponse(Uri.parse('https://e-hentai.org/'),
        [Cookie('nw', '0'), Cookie('sp', 'temporary-reader-preference')]);
    expect(data.buildImageKey(1, 0, ''), first);
    ehAccount('member-b');
    expect(data.buildImageKey(1, 0, ''), isNot(first));
    expect(first, isNot(contains('member-a')));
    expect(ComicSource.find('ehentai'), isNull,
        reason: 'the real CookieJar changed without a source.data mirror');
  });

  test(
      'EH account change during URL resolution cannot send old signed URL as new account',
      () async {
    ehAccount('member-a');
    final fixture = await serve((_, __) => HttpImageReply(red));
    final entered = Completer<void>(), release = Completer<void>();
    final data = reader.EhReadingData(ehGallery(), imageManager: images(),
        imageUrlLoader: (_) async {
      entered.complete();
      await release.future;
      return fixture.url('/old-account-signed.png');
    });
    final provider = data.createImageProvider(1, 0, '') as StreamImageProvider;
    final events = StreamController<ImageChunkEvent>.broadcast();
    final checked = expectLater(provider.load(events), throwsStateError);
    await entered.future;
    ehAccount('member-b');
    release.complete();
    await checked;
    expect(fixture.requests, isEmpty);
    await events.close();
  });

  testWidgets(
      'new Komiic session across tokens does not reuse previous account pixels',
      (tester) async {
    final fixture = (await tester.runAsync(() => serve((_, headers) =>
        HttpImageReply(headers.contains('Bearer account-a') ? red : green))))!;
    final manager = images();
    mode(ReaderDisplayMode.previewFirst);
    Future<reader.ComicReadingPageLogic> session() => mount(
        tester,
        reader.KomiicReadingData(
            comic: _comic('same-work'), imageManager: manager),
        [fixture.url('/same.png')],
        1);
    Future<List<int>> firstPixel() async {
      final image = pixels(tester).first.image!;
      final bytes = (await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
      return bytes.buffer.asUint8List().take(4).toList();
    }

    final first = await session();
    final oldKey = tester
        .widget<reader.ReaderPreviewPageImage>(
            find.byType(reader.ReaderPreviewPageImage))
        .resourceKey;
    expect(await firstPixel(), [200, 10, 20, 255]);
    await unmount(tester, first);
    token('account-b');
    final second = await session();
    final newKey = tester
        .widget<reader.ReaderPreviewPageImage>(
            find.byType(reader.ReaderPreviewPageImage))
        .resourceKey;
    expect(newKey, isNot(oldKey));
    expect(await firstPixel(), [10, 200, 20, 255]);
    expect(fixture.requests, hasLength(2));
    await unmount(tester, second);
    // OnlineImageCache holds a fresh-file lease for five seconds. Its release
    // queues quota work in this widget zone: drive native IO AND that zone,
    // rather than waiting for a FakeAsync continuation from inside runAsync.
    await tester.pump(const Duration(seconds: 6));
    var drained = false;
    unawaited(quota.drain().then((_) { drained = true; }));
    for (var i = 0; i < 40 && !drained; i++) {
      await flush(tester, 1);
    }
    expect(drained, isTrue);
  });
}
