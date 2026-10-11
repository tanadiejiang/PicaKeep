// Real JM transport, recombination, providers/sources and buildComicView.
// Only chapter metadata is replaced with task-owned loopback page URLs.
import 'dart:async';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/jm_page_loader.dart';
import 'package:picakeep/foundation/image_loader/reader_preview_provider.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_cache.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart' as reader;
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep/pages/reader/reader_page_image.dart';
import 'package:picakeep/pages/reader/reader_whole_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

import 'support/http_image_fixture.dart';
import 'support/image_disk_quota_fixture.dart';

JmComicInfo _info(String episode) => JmComicInfo(
      id: episode,
      title: 'JM production route fixture',
      authors: const [],
      description: '',
      likes: 0,
      views: 0,
      comments: 0,
      tags: const [],
      works: const [],
      actors: const [],
      series: {1: episode},
      epNames: const ['Fixture chapter'],
      isFavourite: false,
      isLiked: false,
      coverUrl: '',
      relatedComics: const [],
    );

class _FixtureJmReadingData extends reader.JmReadingData {
  _FixtureJmReadingData(String episode, this.pageUrls, JmPageLoader loader)
      : super(info: _info(episode), pageLoader: loader);
  final List<String> pageUrls;

  // No provider, resolver, byte loader, cache key or recombiner override.
  @override
  Future<List<String>> loadEpNetwork(int ep) async {
    if (ep != 1) throw StateError('Unexpected fixture chapter $ep');
    return List<String>.of(pageUrls);
  }
}

String _path(String episode, int page) => '/book-$episode/page-$page.png';

Uint8List _pixels(String episode, int page, {required bool restored}) {
  final result = Uint8List(8 * 20 * 4);
  for (var y = 0; y < 20; y++) {
    // 230000 uses ten equal two-row segments; 501 preserves original bytes.
    final sourceY =
        restored && episode == '230000' ? (9 - y ~/ 2) * 2 + y % 2 : y;
    for (var x = 0; x < 8; x++) {
      final offset = (y * 8 + x) * 4;
      result[offset] = sourceY * 10;
      result[offset + 1] = (episode == '501' ? 0 : 90) + page * 25 + x;
      result[offset + 2] = 50;
      result[offset + 3] = 255;
    }
  }
  return result;
}

Future<void> _flush(WidgetTester tester, [int turns = 1]) async {
  for (var i = 0; i < turns; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _until(
    WidgetTester tester, bool Function() ready, String reason) async {
  for (var i = 0; i < 300 && !ready(); i++) {
    await _flush(tester);
  }
  expect(ready(), isTrue, reason: reason);
}

// Keep operations which may meet a widget-zone future in that same lifecycle,
// while advancing both its clock and real IO. A broken phase fails, not hangs.
Future<T?> _drive<T>(
    WidgetTester tester, Future<T> Function() operation, String phase) async {
  var finished = false;
  T? result;
  Object? failure;
  StackTrace? failureStack;
  unawaited(operation().then<void>((value) {
    result = value;
    finished = true;
  }, onError: (Object error, StackTrace stack) {
    failure = error;
    failureStack = stack;
    finished = true;
  }));
  await _until(tester, () => finished, '$phase did not finish');
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  return result;
}

void _stage(String stage) => debugPrintSynchronously('JM production: $stage');

// Select an actual painted current-page image, not an offscreen retained page.
RawImage? _visibleImage(WidgetTester tester, ReaderDisplayMode mode) {
  final renderer = mode == ReaderDisplayMode.previewFirst
      ? find.byType(reader.ReaderPreviewPageImage)
      : find.byType(ReaderWholeImage);
  final raw = find.descendant(
      of: renderer,
      matching: find.byWidgetPredicate(
          (widget) => widget is RawImage && widget.image != null));
  for (final element in raw.evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.attached || !box.hasSize) continue;
    final bounds = MatrixUtils.transformRect(
        box.getTransformTo(null), Offset.zero & box.size);
    if (bounds.contains(const Offset(200, 300))) {
      return element.widget as RawImage;
    }
  }
  return null;
}

Future<void> _expectPixels(WidgetTester tester, ReaderDisplayMode mode,
    String episode, int page) async {
  final expected = _pixels(episode, page, restored: true);
  Uint8List? actual;
  RawImage? presented;
  for (var turn = 0; turn < 300; turn++) {
    await _flush(tester);
    presented = _visibleImage(tester, mode);
    if (presented == null) continue;
    final clone = presented.image!.clone();
    try {
      final bytes = await _drive(
          tester,
          () => clone.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
          '${mode.name}/$episode/${page + 1} actual image byte read');
      actual =
          bytes?.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      clone.dispose();
    }
    if (actual != null &&
        actual.length == expected.length &&
        Iterable<int>.generate(expected.length)
            .every((i) => actual![i] == expected[i])) {
      break;
    }
  }
  if (presented == null) {
    _stage('${mode.name}/$episode/${page + 1} no visible pixels; '
        'preview=${find.byType(reader.ReaderPreviewPageImage).evaluate().length}, '
        'whole=${find.byType(ReaderWholeImage).evaluate().length}, '
        'work=${ImageWorkScheduler.shared.hasWork}, '
        'working=${ReaderPreviewImagePool.globalReservedWorkingBytes}, '
        'decoded=${ReaderPreviewImagePool.globalReservedDecodedBytes}, '
        'UI=${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).toList()}');
    for (final element in find.byType(RawImage).evaluate()) {
      final widget = element.widget as RawImage;
      final box = element.renderObject;
      final bounds = box is RenderBox && box.attached && box.hasSize
          ? MatrixUtils.transformRect(
              box.getTransformTo(null), Offset.zero & box.size)
          : null;
      _stage(
          'raw=${widget.image == null ? 'null' : '${widget.image!.width}x${widget.image!.height}'} bounds=$bounds');
    }
    for (final log in LogManager.logs
        .skip(LogManager.logs.length > 12 ? LogManager.logs.length - 12 : 0)) {
      _stage('diagnostic ${log.title}: ${log.content}');
    }
  }
  expect(presented, isNotNull,
      reason: 'the current JM page must really be painted');
  expect((presented!.image!.width, presented.image!.height), (8, 20));
  expect(actual, orderedEquals(expected),
      reason: '$mode $episode page ${page + 1}: all original/restored pixels');
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open(
            p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
  }
  final savedSettings = List<String>.of(appdata.settings);
  final savedImplicit = List<String>.of(appdata.implicitData);
  final savedQuota = ImageDiskQuota.overrideForTesting;
  final savedLog = LogManager.recordingEnabled;
  late Directory root;
  late ImageDiskQuota quota;
  final payloads = <String, Uint8List>{};
  final rawFiles = <String, File>{};
  final rawHashes = <String, String>{};

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('jm_production_modes_057_');
    App.dataPath = p.join(root.path, 'data');
    App.cachePath = p.join(root.path, 'cache');
    await Directory(App.dataPath).create();
    await Directory(App.cachePath).create();
    appdata.settings[22] = p.join(root.path, 'downloads');
    SharedPreferences.setMockInitialValues({});
    LogManager.recordingEnabled = false;
    quota = installTaskDiskQuota(() => [App.cachePath]);
    await downloadManager.init();
    expect(downloadManager.dbFilePath, startsWith(root.path));
    expect(downloadManager.debugRecordCount, 0);
    for (final episode in ['501', '230000']) {
      for (var page = 0; page < 3; page++) {
        final rgba = _pixels(episode, page, restored: false);
        final raw = image.encodePng(
            image.Image.fromBytes(
                width: 8,
                height: 20,
                bytes: rgba.buffer,
                numChannels: 4,
                order: image.ChannelOrder.rgba),
            level: 0);
        final path = _path(episode, page);
        payloads[path] = raw;
        rawFiles[path] = await File(p.join(root.path, 'raw-$episode-$page.png'))
            .writeAsBytes(raw);
        rawHashes[path] = sha256.convert(raw).toString();
      }
    }
  });

  void resetSettings() {
    appdata.settings[9] = '1';
    appdata.settings[28] = '0'; // No eager chapter fetch or invisible preloads.
    appdata.settings[43] = '0';
    appdata.settings[49] = '0';
    appdata.settings[50] = 'zh';
    appdata.implicitData[1] = '0';
  }

  setUp(resetSettings);

  tearDownAll(() async {
    try {
      downloadManager.dispose();
      _stage('tearDownAll quota refresh start');
      expect(quota.pendingOperations, 0);
      // Do not await the completed tail captured by the closed widget zone.
      // With no pending operations, refresh creates the current real-zone tail.
      await quota.refresh().timeout(const Duration(seconds: 5));
      await quota.drain().timeout(const Duration(seconds: 5));
      _stage('tearDownAll quota refresh/drain done');
      expect(ReaderPageFileLease.activeLeaseCount, 0);
      expect(ImageTemporaryPool.shared.reservedBytes, 0);
      expect(p.basename(root.path), startsWith('jm_production_modes_057_'));
      await root.delete(recursive: true);
    } finally {
      ImageDiskQuota.overrideForTesting = savedQuota;
      appdata.settings = savedSettings;
      appdata.implicitData = savedImplicit;
      LogManager.recordingEnabled = savedLog;
    }
  });

  Future<void> exerciseMode(WidgetTester tester, ReaderDisplayMode mode) async {
    resetSettings();
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Test-owned diagnostics only; LogFileService is not initialized here.
    LogManager.recordingEnabled = true;
    appdata.settings[readerImagePipelineSettingIndex] =
        ReaderImagePipelineSettings(
                comic: mode,
                illust: mode == ReaderDisplayMode.previewFirst
                    ? ReaderDisplayMode.sharpFirst
                    : ReaderDisplayMode.previewFirst)
            .encode();
    _stage('${mode.name} loopback start');
    final fixture =
        (await tester.runAsync(() => HttpImageFixture.start((uri, _) {
              if (uri.query.isNotEmpty || !payloads.containsKey(uri.path)) {
                throw StateError(
                    'JM fixture permits only its six full page URLs, without ROI/tile queries');
              }
              return HttpImageReply(payloads[uri.path]!);
            }).timeout(const Duration(seconds: 5))))!;
    _stage('${mode.name} loopback ready');
    final dio = directImageDio();
    final loader =
        JmPageLoader.forTesting(images: OnlineImageManager.forTesting(dio));
    reader.ComicReadingPageLogic? mounted;
    final pendingProbeSources = <ReaderPageSource>[];

    Future<void> unmount() async {
      _stage(
          '${mode.name} unmount start (${pendingProbeSources.length} probes, ${fixture.requests.length} requests)');
      final logic = mounted;
      mounted = null;
      await tester.pumpWidget(const SizedBox());
      if (logic != null) {
        await _flush(tester, 3);
        logic.clearPhotoViewControllers();
        logic.pageController.dispose();
        logic.scrollController.dispose();
        logic.focusNode.dispose();
        logic.viewportChanges.dispose();
        logic.dispose();
      }
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      // Start every source disposal before waiting: multiple sources may
      // refer to the same original, including the just-unmounted UI source.
      final probes = List<ReaderPageSource>.of(pendingProbeSources);
      pendingProbeSources.clear();
      var probesDisposed = false;
      Object? probeDisposalError;
      final probeDisposals =
          Future.wait<void>(probes.map((source) => source.dispose()))
              .then<void>((_) {
        probesDisposed = true;
      }, onError: (Object error, StackTrace stack) {
        probeDisposalError = error;
        probesDisposed = true;
      });
      // Drain the real cache publication grace timer, not just UI leases.
      await tester.pump(const Duration(seconds: 6));
      await _until(
          tester,
          () =>
              probesDisposed &&
              ReaderWholeImageResidency.shared.bytes == 0 &&
              ReaderPreviewImagePool.globalReservedWorkingBytes == 0 &&
              ReaderPreviewImagePool.globalReservedDecodedBytes == 0 &&
              ReaderPageFileLease.activeLeaseCount == 0 &&
              ReaderRasterCache.pendingBytes == 0 &&
              !ImageWorkScheduler.shared.hasWork &&
              ImageWorkScheduler.shared.reservedBytes == 0 &&
              ImageTemporaryPool.shared.reservedBytes == 0 &&
              quota.pendingOperations == 0 &&
              quota.activeBytes == 0,
          'JM route exit must drain images, real cache writes and file/grace leases');
      await probeDisposals;
      expect(probeDisposalError, isNull);
      _stage('${mode.name} UI/probes/budgets drained; quota refresh start');
      await tester.runAsync(() async {
        // pendingOperations is already zero. refresh's _serial resets the
        // dispatch root here instead of awaiting a completed FakeAsync tail.
        await quota.refresh().timeout(const Duration(seconds: 5));
        await quota.drain().timeout(const Duration(seconds: 5));
      });
      _stage('${mode.name} quota refresh/drain done');
      expect(ReaderSurfaceDiagnostics.activeSurfaces, 0);
      expect(ReaderSurfaceDiagnostics.residentBytes, 0);
      expect(tester.takeException(), isNull);
    }

    var modeClosed = false;
    Future<void> closeMode() async {
      if (modeClosed) return;
      modeClosed = true;
      try {
        await unmount();
      } finally {
        dio.close(force: true);
        _stage('${mode.name} loopback close start');
        await tester.runAsync(
            () => fixture.close().timeout(const Duration(seconds: 5)));
        _stage('${mode.name} loopback close done');
      }
    }

    addTearDown(closeMode);

    Future<reader.ComicReadingPageLogic> mount(
        _FixtureJmReadingData data) async {
      final page = reader.ComicReadingPage(data, 1, 1);
      appdata.settings[9] = '1';
      final logic = StateController.find<reader.ComicReadingPageLogic>();
      mounted = logic;
      logic.urls = (await _drive(
          tester, () => data.loadEp(1), '${mode.name} fixture chapter URLs'))!;
      logic.isLoading = false;
      logic.scrollManager = reader.ScrollManager(logic);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
                  builder: (context) =>
                      StateBuilder<reader.ComicReadingPageLogic>(
                          builder: (logic) => Stack(children: [
                                page.buildComicView(
                                    logic, context, 'jm-production-fixture'),
                              ]))))));
      expect(logic.order, 1);
      return logic;
    }

    final expectedRequests = <String>[];
    final authoritativeHashes = <String, String>{};
    for (final episode in ['501', '230000']) {
      final urls = [for (var i = 0; i < 3; i++) fixture.url(_path(episode, i))];
      final data = _FixtureJmReadingData(episode, urls, loader);
      expect(data.forceOnline, isFalse);
      expect(data.downloaded, isFalse,
          reason:
              'this exercises ordinary online JM from the isolated empty download DB');
      for (final warm in [false, true]) {
        final round = '${mode.name}/$episode/${warm ? 'warm' : 'cold'}';
        _stage('$round mount start');
        final logic = await mount(data);
        _stage('$round mount done');
        for (var page = 0; page < 3; page++) {
          _stage('$round page ${page + 1} display start');
          if (page > 0) logic.pageController.jumpToPage(page + 1);
          await _expectPixels(tester, mode, episode, page);
          _stage('$round page ${page + 1} pixels done');
          expect(logic.index, page + 1);
          expect(logic.previewPreloader.retainedKeys, isEmpty);
          expect(find.byType(ReaderImageSurface), findsNothing);
          expect(ReaderSurfaceDiagnostics.activeSurfaces, 0);
          expect(ReaderSurfaceDiagnostics.residentBytes, 0);
          if (mode == ReaderDisplayMode.previewFirst) {
            expect(find.byType(reader.ReaderPreviewPageImage), findsWidgets);
            expect(find.byType(ReaderPageImage), findsNothing);
            expect(find.byType(ReaderWholeImage), findsNothing);
            for (final widget in tester.widgetList<Image>(find.byType(Image))) {
              expect(widget.image, isNot(isA<ResizeImage>()));
            }
          } else {
            expect(find.byType(ReaderPageImage), findsWidgets);
            expect(find.byType(ReaderWholeImage), findsWidgets);
            expect(find.byType(reader.ReaderPreviewPageImage), findsNothing);
            for (final whole in tester
                .widgetList<ReaderWholeImage>(find.byType(ReaderWholeImage))) {
              expect(whole.metadata.size, const Size(8, 20));
              // This checks the actual widget's production plan, not an
              // independent backend-call spy (covered by whole-render tests).
              final demand = ReaderWholeImagePlan.create(
                      sourceSize: whole.metadata.size,
                      policy: whole.policy,
                      textureEdge: whole.textureEdge)
                  .demand;
              expect(demand.sourceRect, const Rect.fromLTWH(0, 0, 8, 20));
              expect((demand.row, demand.column), (-1, -1));
            }
          }
          final path = _path(episode, page);
          if (!warm) expectedRequests.add(path);
          await _flush(tester, 2);
          expect(fixture.requests.map((uri) => uri.path).toList(),
              expectedRequests,
              reason:
                  'only the displayed cold page fetches; warm reopen makes no new request');

          // Settle the post-paint writer, but not the visible whole widget's
          // legitimate original-file handoff lease (released on unmount).
          await _until(
              tester,
              () =>
                  ReaderRasterCache.pendingBytes == 0 &&
                  !ImageWorkScheduler.shared.hasWork,
              'the visible page and its real cache writer must settle');
          // Resolve only AFTER the real visible route loaded. This cannot
          // seed the cache and manufacture a passing display/network result.
          _stage('$round page ${page + 1} probe start');
          final probed = (await _drive(tester, () async {
            final source = await data.resolvePageSource(1, page, urls[page]);
            // Register immediately so cleanup also owns a stalled opener.
            pendingProbeSources.add(source);
            _stage('$round page ${page + 1} probe source resolved; open start');
            final file = await source.openOriginalFile();
            _stage(
                '$round page ${page + 1} probe file opened; read/hash start');
            return (
              source: source,
              file: file,
              bytes: await file.readAsBytes()
            );
          }, '$round page ${page + 1} original probe'))!;
          // Assertions belong to the awaited test chain, never to a callback
          // that can resume concurrently with WidgetTester's guarded pump.
          expect(probed.source, isA<JmReaderPageSource>());
          expect(probed.source, isNot(isA<RasterReaderPageSource>()));
          expect(probed.source.isAuthoritativeOriginal, isTrue);
          expect(probed.file.path, startsWith(App.cachePath));
          final digest = sha256.convert(probed.bytes).toString();
          if (episode == '501') {
            expect(digest, rawHashes[path],
                reason:
                    'the no-reorder episode preserves original encoded bytes');
          } else {
            expect(digest, isNot(rawHashes[path]));
          }
          if (warm) {
            expect(digest, authoritativeHashes[path]);
          } else {
            authoritativeHashes[path] = digest;
          }
          final decoded = image.decodePng(probed.bytes)!;
          expect((decoded.width, decoded.height), (8, 20));
          expect(decoded.getBytes(order: image.ChannelOrder.rgba),
              orderedEquals(_pixels(episode, page, restored: true)));
          _stage('$round page ${page + 1} probe done');
          expect(fixture.requests.map((uri) => uri.path).toList(),
              expectedRequests);
        }
        await unmount();
      }
    }
    expect(fixture.requests, hasLength(6));
    _stage('${mode.name} final raw/cache SHA start');
    final hashes = (await _drive(tester, () async {
      final inputs = <String, String>{};
      for (final entry in rawFiles.entries) {
        inputs[entry.key] =
            sha256.convert(await entry.value.readAsBytes()).toString();
      }
      final cached = <String>{};
      await for (final file
          in Directory(p.join(App.cachePath, 'online_images')).list()) {
        if (file is File && p.extension(file.path) == '.png') {
          cached.add(sha256.convert(await file.readAsBytes()).toString());
        }
      }
      return (inputs: inputs, cached: cached);
    }, '${mode.name} final original hashes'))!;
    expect(hashes.inputs, rawHashes);
    expect(hashes.cached, containsAll(rawHashes.values),
        reason:
            'raw network originals remain unchanged alongside restored authoritative pages');
    _stage('${mode.name} all assertions done');
    await closeMode();
  }

  // JM's process-wide completed work tail must not cross a closed FakeAsync
  // zone. Keep both modes in one clock, but not one reader/transport:
  // exerciseMode clears UI caches, drains all owners and closes its own server.
  // This is one composite case with the original 24 page displays, not a skip.
  testWidgets(
      'real JM sharpFirst and previewFirst present both books first/middle/last cold and warm',
      (tester) async {
    for (final mode in ReaderDisplayMode.values) {
      await exerciseMode(tester, mode);
    }
  });
}
