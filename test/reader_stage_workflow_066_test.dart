// 066 F2/F3: real ReadingData -> buildComicView -> preview pool -> original
// provider -> task-owned HTTP/cache/JM -> Flutter descriptor/codec/frame.
// No diagnostic failure/observation method is called by this test. The only
// injected logic member is the existing diagnostics writer, never the renderer.
// Layout/format/whole-mode cross-products belong to the production-route/JM and
// real-format suites; this file checks the missing diagnostic workflow edges.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'package:picakeep/foundation/image_loader/jm_image_recombine.dart';
import 'package:picakeep/foundation/image_loader/jm_page_loader.dart';
import 'package:picakeep/foundation/image_loader/reader_image_retry.dart';
import 'package:picakeep/foundation/image_loader/reader_preview_provider.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_failure_diagnostics.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_cache.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/komiic_network/komiic_network.dart';
import 'package:picakeep/network/online_image/online_image_cache.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart' as reader;
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep/pages/reader/reader_page_image.dart';
import 'package:picakeep/pages/reader/reader_whole_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

import 'support/http_image_fixture.dart';
import 'support/image_disk_quota_fixture.dart';

const _secretUrl = 'URL_SECRET_066';
const _secretPath = 'PATH_SECRET_066';
const _secretToken = 'TOKEN_SECRET_066';
const _secretHeader = 'HEADER_SECRET_066';
const _secretBody = 'BODY_SECRET_066';

KomiicComicInfo _comic(String id) => KomiicComicInfo(
    id: id,
    title: '066 task fixture',
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
          id: _secretHeader, serial: '1', type: 'chapter', dateUpdated: '')
    ]);

// Only metadata and an optional controlled invalidation I/O are supplied. In
// particular createImageProvider, original loader, identity and scope are real.
class _Komiic extends reader.KomiicReadingData {
  _Komiic(String id, this.urls, OnlineImageManager images)
      : super(comic: _comic(id), imageManager: images);
  final List<String> urls;
  Future<void> Function()? beforeInvalidate;
  Object? invalidationError;
  int invalidations = 0;
  @override
  Future<List<String>> loadEpNetwork(int ep) async => List.of(urls);
  @override
  Future<void> invalidateImage(int ep, int page, String url) async {
    invalidations++;
    try {
      await beforeInvalidate?.call();
      await super.invalidateImage(ep, page, url);
    } catch (error) {
      invalidationError = error;
      rethrow;
    }
  }
}

JmComicInfo _jmInfo(String id) => JmComicInfo(
    id: id,
    title: '066 JM fixture',
    authors: const [],
    description: '',
    likes: 0,
    views: 0,
    comments: 0,
    tags: const [],
    works: const [],
    actors: const [],
    series: {1: '501'},
    epNames: const ['Fixture'],
    isFavourite: false,
    isLiked: false,
    coverUrl: '',
    relatedComics: const []);

class _Jm extends reader.JmReadingData {
  _Jm(String id, this.urls, JmPageLoader loader)
      : super(info: _jmInfo(id), pageLoader: loader);
  final List<String> urls;
  @override
  Future<List<String>> loadEpNetwork(int ep) async => List.of(urls);
}

class _WriterLogic extends reader.ComicReadingPageLogic {
  _WriterLogic(reader.ReadingData data, void Function(String) writer)
      : _session = ReaderFailureDiagnosticsSession(writer: writer),
        super(1, data, 1, () {});
  final ReaderFailureDiagnosticsSession _session;
  @override
  ReaderFailureDiagnosticsSession get failureDiagnosticsSession => _session;
}

// Observe a lease already created by the production page. It does not resolve a
// second provider, issue another request, or inspect any internal relay API.
class _PageResult {
  _PageResult(reader.ReaderPreviewPageImage page)
      : lease = page.pool!.acquire(
            resourceKey: page.resourceKey, loadProvider: page.loadProvider) {
    unawaited(lease.firstFrame.then<void>((value) {
      size = value;
    }, onError: (Object value, StackTrace _) {
      error = value;
    }));
  }
  final ReaderPreviewImageLease lease;
  Size? size;
  Object? error;
  void release() => lease.release();
}

Future<void> _flush(WidgetTester tester, [int turns = 1]) async {
  for (var i = 0; i < turns; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 1));
  }
}

Future<void> _until(
    WidgetTester tester, bool Function() ready, String reason) async {
  for (var i = 0; i < 400 && !ready(); i++) {
    await _flush(tester);
  }
  expect(ready(), isTrue, reason: reason);
}

// Future callbacks collect values only. All expects remain on the awaited test
// chain, not concurrent with WidgetTester's guarded pump/runAsync methods.
Future<T> _drive<T>(
    WidgetTester tester, Future<T> Function() operation, String reason) async {
  var done = false;
  late T result;
  Object? error;
  StackTrace? stack;
  unawaited(operation().then<void>((value) {
    result = value;
    done = true;
  }, onError: (Object value, StackTrace trace) {
    error = value;
    stack = trace;
    done = true;
  }));
  await _until(tester, () => done, reason);
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return result;
}

List<Map<String, dynamic>> _events([String? kind]) => [
      for (final log in LogManager.logs)
        if (log.title == 'ReaderImage')
          jsonDecode(log.content) as Map<String, dynamic>,
    ].where((event) => kind == null || event['event'] == kind).toList();

const _factKeys = [
  'httpStatusClass',
  'encodingContract',
  'rawCacheHit',
  'onlineCacheHit',
  'processedCacheHit',
];

// Assert the Page's public JSON, never the pool relay or mutable producer facts.
// Explicit null is important: a skipped lookup is not a cache miss, and a warm
// execution must not inherit the HTTP success/encoding from the cold execution.
void _facts(
  Map<String, dynamic> event, {
  String status = 'unknown',
  String encoding = 'unknown',
  bool? raw,
  bool? online,
  bool? processed,
  String? reason,
}) {
  final snapshot = event['snapshot'] as Map<String, dynamic>;
  expect(snapshot.keys, containsAll(_factKeys));
  expect({
    for (final key in _factKeys) key: snapshot[key]
  }, {
    'httpStatusClass': status,
    'encodingContract': encoding,
    'rawCacheHit': raw,
    'onlineCacheHit': online,
    'processedCacheHit': processed,
  },
      reason:
          '${event['event']} page=${event['page']} attempt=${event['attempt']} facts');
  if (reason != null) expect(event['reason'], reason);
}

void _safeEvents(Iterable<Map<String, dynamic>> events, Directory root) {
  for (final event in events) {
    final text = jsonEncode(event);
    expect(text.length,
        lessThanOrEqualTo(ReaderFailureDiagnosticsSession.maximumEventLength));
    for (final secret in [
      _secretUrl,
      _secretPath,
      _secretToken,
      _secretHeader,
      _secretBody,
      root.path,
      '127.0.0.1',
      'Bearer ',
      'Authorization',
      'Referer'
    ]) {
      expect(text, isNot(contains(secret)),
          reason: 'ReaderImage must not expose $secret');
    }
    expect(event['pageKey'], matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(event['qualityMode'], 'previewFirst');
    expect(event['chapter'], 1);
    expect(event['attempt'], isA<int>());
    expect(event['generation'], isA<int>());
    if (const {'failure', 'retryScheduled', 'recovered'}
        .contains(event['event'])) {
      final snapshot = event['snapshot'] as Map<String, dynamic>;
      expect(snapshot.keys, containsAll(_factKeys));
      expect(
          snapshot['httpStatusClass'],
          isIn(const {
            'unknown',
            'success',
            'redirect',
            'auth',
            'rateLimited',
            'clientError',
            'serverError',
          }));
      expect(
          snapshot['encodingContract'],
          isIn(const {
            'unknown',
            'identity',
            'gzipDecoded',
            'unsupported',
          }));
      for (final key in _factKeys.skip(2)) {
        expect(snapshot[key], anyOf(isNull, isA<bool>()));
      }
    }
  }
}

RawImage? _visibleFrame(WidgetTester tester) {
  for (final element in find
      .descendant(
          of: find.byType(reader.ReaderPreviewPageImage),
          matching: find.byType(RawImage))
      .evaluate()) {
    final widget = element.widget as RawImage;
    final box = element.renderObject;
    if (widget.image == null || box is! RenderBox || !box.hasSize) continue;
    final rect = MatrixUtils.transformRect(
        box.getTransformTo(null), Offset.zero & box.size);
    if (rect.contains(const Offset(200, 300))) return widget;
  }
  return null;
}

Future<void> _frame(WidgetTester tester) async {
  await _until(tester, () => _visibleFrame(tester) != null,
      'production page must paint a real frame');
  final clone = _visibleFrame(tester)!.image!.clone();
  try {
    expect((clone.width, clone.height), (24, 32));
    final bytes = await _drive(
        tester,
        () => clone.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
        'read actual frame');
    final rgba =
        bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    expect(rgba.length, 24 * 32 * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      expect(rgba.sublist(i, i + 4), [60, 120, 180, 255]);
    }
  } finally {
    clone.dispose();
  }
  expect(find.byType(ReaderWholeImage), findsNothing);
  expect(find.byType(ReaderPageImage), findsNothing);
  expect(find.byType(ReaderImageSurface), findsNothing);
  expect(tester.takeException(), isNull);
}

class _Host {
  _Host(this.tester, this.quota);
  final WidgetTester tester;
  final ImageDiskQuota quota;
  reader.ComicReadingPageLogic? logic;
  final probes = <_PageResult>[];

  Future<void> mount(reader.ReadingData data,
      {int preload = 0, void Function(String)? writer}) async {
    expect(logic, isNull);
    appdata.settings[9] = '1';
    appdata.settings[28] = '$preload';
    final page = reader.ComicReadingPage(data, 1, 1);
    var selected = StateController.find<reader.ComicReadingPageLogic>();
    if (writer != null) {
      _disposeLogic(selected);
      selected = StateController.put<reader.ComicReadingPageLogic>(
          _WriterLogic(data, writer));
    }
    logic = selected;
    selected.urls = await _drive(
        tester, () => data.loadEp(1), 'task-only chapter metadata');
    selected.isLoading = false;
    selected.scrollManager = reader.ScrollManager(selected);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Stack(children: [
      Builder(
          builder: (context) => StateBuilder<reader.ComicReadingPageLogic>(
              builder: (value) =>
                  page.buildComicView(value, context, '066-production'))),
    ]))));
    expect(find.byType(reader.ReaderPreviewPageImage), findsWidgets);
    expect(data.downloaded, isFalse);
  }

  _PageResult observe({int page = 1}) {
    final widget = tester
        .widgetList<reader.ReaderPreviewPageImage>(
            find.byType(reader.ReaderPreviewPageImage))
        .singleWhere((widget) => widget.failureDiagnostics!.page == page);
    final probe = _PageResult(widget);
    probes.add(probe);
    return probe;
  }

  Future<void> failure(String stage, {int page = 1}) async {
    await _until(
        tester,
        () => _events('failure').any((e) =>
            e['stage'] == stage && e['page'] == page && e['terminal'] == true),
        'production page must report terminal $stage at page $page');
    await _until(tester, () => find.text('图片暂时无法打开，请重试').evaluate().isNotEmpty,
        'actual production failure UI');
    expect(find.text('重试'), findsWidgets);
    expect(tester.takeException(), isNull);
  }

  Future<void> retry() async {
    for (final probe in probes) {
      probe.release();
    }
    probes.clear();
    await tester.tap(find.text('重试').hitTestable().first);
    await tester.pump();
  }

  Future<void> unmount() async {
    for (final probe in probes) {
      probe.release();
    }
    probes.clear();
    await tester.pumpWidget(const SizedBox());
    final old = logic;
    logic = null;
    if (old != null) {
      await _flush(tester, 3);
      _disposeLogic(old);
    }
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    BaseImageProvider.clearCache();
    await tester.pump(const Duration(seconds: 6));
    await _until(
        tester,
        () =>
            ReaderPreviewImagePool.globalReservedWorkingBytes == 0 &&
            ReaderPreviewImagePool.globalReservedDecodedBytes == 0 &&
            ReaderPageFileLease.activeLeaseCount == 0 &&
            ReaderWholeImageResidency.shared.bytes == 0 &&
            ReaderRasterCache.pendingBytes == 0 &&
            !ImageWorkScheduler.shared.hasWork &&
            ImageWorkScheduler.shared.reservedBytes == 0 &&
            ImageTemporaryPool.shared.reservedBytes == 0 &&
            quota.pendingOperations == 0 &&
            quota.activeBytes == 0,
        'every scenario drains real IO, grace leases, frame/codec/work/quota owners');
    expect(old?.previewImagePool.activeEntryCount ?? 0, 0);
    expect(ReaderSurfaceDiagnostics.activeSurfaces, 0);
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(tester.takeException(), isNull);
  }
}

void _disposeLogic(reader.ComicReadingPageLogic logic) {
  logic.clearPhotoViewControllers();
  logic.pageController.dispose();
  logic.scrollController.dispose();
  logic.focusNode.dispose();
  logic.viewportChanges.dispose();
  logic.dispose();
}

// Reproduce the PUBLIC online cache identity contract only to place an actual
// filesystem obstacle before the writer opens its .part. No relay is involved.
String _komiicCacheIdentity(_Komiic data, String url) {
  final headers = <String, String>{
    'Referer':
        'https://komiic.com/comic/${data.id}/chapter/$_secretHeader/images/all',
    'User-Agent': KomiicNetwork.komiicUA,
    'Authorization': 'Bearer ${KomiicNetwork().token}',
  }.entries.toList()
    ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
  final scope = sha256
      .convert(utf8.encode(jsonEncode(
          headers.map((e) => [e.key.toLowerCase(), e.value]).toList())))
      .toString();
  final base = jsonEncode(
      ['online-image-v2', data.originalNetworkCacheIdentity(1, 0, url), scope]);
  return jsonEncode([base, 'reader-managed-retry-v1']);
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
  final savedSources = List<ComicSource>.of(ComicSource.sources);
  final savedQuota = ImageDiskQuota.overrideForTesting;
  final savedLog = LogManager.recordingEnabled;
  late Directory root;
  late ImageDiskQuota quota;
  final png = syntheticHttpPng();
  final corrupt =
      Uint8List.fromList(utf8.encode('$_secretBody not an encoded image'));

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('reader_stage_workflow_066_');
    App.dataPath = p.join(root.path, 'data');
    App.cachePath = p.join(root.path, 'cache');
    await Directory(App.dataPath).create();
    await Directory(App.cachePath).create();
    appdata.settings[22] = p.join(root.path, 'downloads');
    SharedPreferences.setMockInitialValues({});
    quota = installTaskDiskQuota(() => [App.cachePath]);
    await downloadManager.init();
    expect(downloadManager.dbFilePath, startsWith(root.path));
    expect(downloadManager.debugRecordCount, 0);
    appdata.settings[9] = '1';
    appdata.settings[28] = '0';
    appdata.settings[43] = '0';
    appdata.settings[49] = '0';
    appdata.settings[50] = 'zh';
    appdata.implicitData[1] = '0';
    appdata.settings[readerImagePipelineSettingIndex] =
        const ReaderImagePipelineSettings(
                comic: ReaderDisplayMode.previewFirst,
                illust: ReaderDisplayMode.previewFirst)
            .encode();
    ComicSource.sources
      ..clear()
      ..add(ComicSource.named(
          key: 'komiic', name: '066 fixture', data: {'token': _secretToken}));
  });

  tearDownAll(() async {
    downloadManager.dispose();
    expect(quota.pendingOperations, 0);
    // Create a real-zone tail, never await a completed tail in closed FakeAsync.
    await quota.refresh().timeout(const Duration(seconds: 5));
    await quota.drain().timeout(const Duration(seconds: 5));
    ImageDiskQuota.overrideForTesting = savedQuota;
    appdata.settings = savedSettings;
    appdata.implicitData = savedImplicit;
    ComicSource.sources
      ..clear()
      ..addAll(savedSources);
    LogManager.recordingEnabled = savedLog;
    expect(p.basename(root.path), startsWith('reader_stage_workflow_066_'));
    await root.delete(recursive: true);
  });

  // All JM work, including success after an injected transform fault, remains
  // inside ONE live FakeAsync. Do not alter the production static queue/tail.
  testWidgets(
      '066 F2/F3 production reader stage, retry, scope and lifecycle workflow',
      (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = _Host(tester, quota);
    final replies = <String, HttpImageReply Function()>{};
    final fixture =
        (await tester.runAsync(() => HttpImageFixture.start((uri, _) {
              final reply = replies[uri.path];
              if (reply == null) {
                throw StateError('Unexpected non-fixture HTTP request');
              }
              return reply();
            })))!;
    final dio = directImageDio();
    final manager = OnlineImageManager.forTesting(dio);
    final collected = <Map<String, dynamic>>[];
    final gates = <Completer<void>>[];
    var serial = 0;
    String urlFor(String label, HttpImageReply Function() reply) {
      final path = '/$_secretUrl-${serial++}-$label.png';
      replies[path] = reply;
      return fixture.url(path);
    }

    _Komiic dataFor(String url) => _Komiic('case-${serial++}', [url], manager);
    int requests(String url) =>
        fixture.requests.where((r) => r.path == Uri.parse(url).path).length;
    void checkpoint() {
      final events = _events();
      _safeEvents(events, root);
      collected.addAll(events);
      LogManager.clear();
    }

    Future<void> finish() async {
      await host.unmount();
      checkpoint();
    }

    addTearDown(() async {
      for (final gate in gates) {
        if (!gate.isCompleted) gate.complete();
      }
      try {
        await host.unmount();
      } finally {
        dio.close(force: true);
        await tester.runAsync(fixture.close);
      }
    });
    LogManager.recordingEnabled = true;
    LogManager.clear();

    // FETCH: actual HTTP headers arrive, then the wire body ends short while
    // OnlineImageCache.putStream is consuming it. Outer writer must not relabel.
    var fetchHealthy = false;
    final shortUrl = urlFor(
        'short',
        () => HttpImageReply(png,
            declaredLength: fetchHealthy ? png.length : png.length + 23));
    final shortData = dataFor(shortUrl);
    await host.mount(shortData);
    final shortResult = host.observe();
    for (var retry = 1; retry <= 3; retry++) {
      await _until(tester, () => _events('retryScheduled').length == retry,
          'short HTTP body schedules bounded retry $retry');
      expect(requests(shortUrl), retry);
      final halfDelay = Duration(seconds: 1 << (retry - 1));
      await tester.pump(halfDelay);
      await _flush(tester, 3);
      expect(requests(shortUrl), retry,
          reason: 'no request before 2/4/8 backoff expires');
      await tester.pump(halfDelay);
    }
    await host.failure('fetch');
    expect(requests(shortUrl), 4);
    expect(shortResult.error, isNotNull);
    expect(readerImageRetryDelay(shortResult.error!, 1),
        const Duration(seconds: 2));
    expect(readerImageRetryDelay(shortResult.error!, 4), isNull);
    final autoEvents = _events();
    for (final event in autoEvents) {
      _facts(event,
          status: 'success',
          encoding: 'identity',
          raw: false,
          online: false,
          reason: event['event'] == 'failure' ? 'network' : null);
    }
    // Dart IO reports this real wire truncation as HttpException before normal
    // EOF. It is network, not the contract's distinct typed lengthMismatch.
    expect(shortResult.error, isA<HttpException>());
    expect(
        autoEvents
            .where((e) => e['event'] == 'retryScheduled')
            .map((e) => e['retry']),
        [1, 2, 3]);
    expect(autoEvents.map((e) => e['pageKey']).toSet(), hasLength(1));
    expect(autoEvents.map((e) => e['attempt']).toSet(), {1});
    expect(autoEvents.map((e) => e['generation']).toSet(), {1});
    final retrySnapshots = _events('retryScheduled')
        .map((event) => event['snapshot'] as Map<String, dynamic>)
        .toList();
    final terminalSnapshot =
        _events('failure').last['snapshot'] as Map<String, dynamic>;
    expect(retrySnapshots.map((snapshot) => snapshot['operationId']).toSet(),
        {terminalSnapshot['operationId']},
        reason: 'automatic retries retain one physical page operation');
    expect({
      ...retrySnapshots.map((snapshot) => snapshot['executionId']),
      terminalSnapshot['executionId'],
    }, hasLength(4),
        reason: 'four executions must not reuse old cause metadata');
    expect(retrySnapshots.every((snapshot) => snapshot['replayed'] == false),
        isTrue);
    expect(_events('failure').map((e) => e['stage']).toSet(), {'fetch'});
    expect(_events('failure').last['failureCount'], 4,
        reason:
            'dedup emits one nonterminal plus terminal, but counts all failures');
    await tester.pump(const Duration(seconds: 20));
    await _flush(tester, 3);
    expect(requests(shortUrl), 4, reason: 'no fifth automatic request');
    fetchHealthy = true;
    await host.retry();
    await _frame(tester);
    expect(requests(shortUrl), 5);
    expect(shortData.invalidations, 1);
    final manual = _events('explicitRetry').single;
    final recovered = _events('recovered').single;
    expect((manual['attempt'], manual['generation']), (2, 2));
    expect((recovered['attempt'], recovered['generation']), (2, 2));
    expect(recovered['pageKey'], autoEvents.first['pageKey']);
    _facts(recovered,
        status: 'success', encoding: 'identity', raw: false, online: false);
    expect(recovered.containsKey('reason'), isFalse,
        reason:
            'a failure reason must not become the next successful execution reason');
    await finish();
    // Force raw-memory/Flutter-cache cold while preserving the actual disk hit.
    await host.mount(shortData);
    await _frame(tester);
    expect(requests(shortUrl), 5);
    expect(_events(), isEmpty,
        reason: 'cache hit is not a fabricated stage failure');
    await finish();

    // Header-only rejection is fetch too, and does not gain transport retries.
    final authUrl =
        urlFor('headers', () => HttpImageReply(corrupt, status: 401));
    await host.mount(dataFor(authUrl));
    final auth = host.observe();
    await host.failure('fetch');
    expect(requests(authUrl), 1);
    expect(readerImageRetryDelay(auth.error!, 1), isNull);
    _facts(_events('failure').single,
        status: 'auth', raw: false, online: false, reason: 'httpStatus');
    expect(_events('retryScheduled'), isEmpty);
    await finish();

    // CACHE: a task-owned directory occupies the real writer's .png.part path.
    // This is not an artificial provider throwing FileSystemException.
    final cacheUrl = urlFor('cache-write', () => HttpImageReply(png));
    final cacheData = dataFor(cacheUrl);
    final cacheIdentity = _komiicCacheIdentity(cacheData, cacheUrl);
    final cacheKey = OnlineImageCache.instance.keyForUrl(cacheIdentity);
    final obstacle =
        Directory(p.join(App.cachePath, 'online_images', '$cacheKey.png.part'));
    await _drive(tester, () => obstacle.create(recursive: true),
        'install cache writer obstacle');
    await host.mount(cacheData);
    final cacheResult = host.observe();
    await host.failure('cache');
    final sameError = cacheResult.error!;
    expect(sameError, isA<FileSystemException>());
    _facts(_events('failure').single,
        status: 'success',
        encoding: 'identity',
        raw: false,
        online: false,
        reason: 'fileIO');
    expect(requests(cacheUrl), 1);
    expect(_events('retryScheduled'), isEmpty);
    expect(readerImageRetryDelay(sameError, 1), isNull);
    expect(
        await _drive(tester, () => OnlineImageCache.instance.get(cacheIdentity),
            'failed publication has no completed cache record'),
        isNull);
    await finish();
    // Verify exact task-owned target before removal, never follow arbitrary paths.
    expect(p.isWithin(root.path, obstacle.path), isTrue);
    await _drive(
        tester, () => obstacle.delete(), 'remove task-owned cache obstacle');
    await host.mount(cacheData);
    await _frame(tester);
    expect(requests(cacheUrl), 2);
    await finish();

    // TRANSFORM: the production JM helper calls its documented testing
    // recombiner after actual raw HTTP/cache completion. Throw the SAME object
    // observed from the cache writer: stage must be positional, not type based.
    var transformFails = true;
    var recombines = 0;
    final jmUrl = urlFor('jm', () => HttpImageReply(png));
    final loader = JmPageLoader.forTesting(
        images: manager,
        recombine: (bytes,
            {required epsId,
            required scrambleId,
            required pictureName,
            originalExtension = '.jpg'}) async {
          recombines++;
          if (transformFails) throw sameError;
          return JmRecombine.recombine(bytes,
              epsId: epsId,
              scrambleId: scrambleId,
              pictureName: pictureName,
              originalExtension: originalExtension);
        });
    final jmData = _Jm('066-jm', [jmUrl], loader);
    await host.mount(jmData);
    final transformed = host.observe();
    await host.failure('transform');
    expect(identical(transformed.error, sameError), isTrue,
        reason:
            'original error object survives helper/provider/pool without wrapping');
    expect(readerImageRetryDelay(transformed.error!, 1), isNull);
    expect(_events('retryScheduled'), isEmpty);
    expect(requests(jmUrl), 1);
    expect(recombines, 1);
    expect(_events('failure').single['errorType'],
        sameError.runtimeType.toString());
    _facts(_events('failure').single,
        status: 'success',
        encoding: 'identity',
        raw: false,
        online: false,
        processed: false,
        reason: 'fileIO');
    await finish();
    // Reopen without invalidation: processed lookup still misses, but the real
    // raw HTTP disk file is already complete. No HTTP happened this execution.
    await host.mount(jmData);
    final rawWarmTransform = host.observe();
    await host.failure('transform');
    expect(identical(rawWarmTransform.error, sameError), isTrue);
    expect((requests(jmUrl), recombines), (1, 2));
    _facts(_events('failure').single,
        raw: false, online: true, processed: false, reason: 'fileIO');
    transformFails = false;
    await host.retry();
    await _frame(tester);
    expect((requests(jmUrl), recombines), (2, 3));
    expect(_events('explicitRetry').single['attempt'], 2);
    expect(_events('recovered').single['generation'], 2);
    _facts(_events('recovered').single,
        status: 'success',
        encoding: 'identity',
        raw: false,
        online: false,
        processed: false);
    await finish();
    await host.mount(jmData);
    await _frame(tester);
    expect((requests(jmUrl), recombines), (2, 3),
        reason: 'warm JM has no extra fetch/recombine');
    expect(_events(), isEmpty,
        reason: 'an ordinary processed hit needs no fake success event');
    // Refresh the fixture's page URL to a genuine 401, then back to its cached
    // original within the SAME logical page/session. This creates a legitimate
    // recovered Page event for a processed hit, without calling diagnostics.
    final jmDenied =
        urlFor('jm-denied', () => HttpImageReply(corrupt, status: 401));
    host.logic!.urls = [jmDenied];
    host.logic!.update();
    await tester.pump();
    await host.failure('fetch');
    _facts(_events('failure').single,
        status: 'auth',
        raw: false,
        online: false,
        processed: false,
        reason: 'httpStatus');
    BaseImageProvider.clearCache();
    host.logic!.urls = [jmUrl];
    host.logic!.update();
    await tester.pump();
    await _frame(tester);
    _facts(_events('recovered').single, raw: false, processed: true);
    expect(_events('recovered').single['attempt'], 3);
    expect(_events('recovered').single['pageKey'],
        _events('failure').single['pageKey']);
    expect((requests(jmUrl), requests(jmDenied), recombines), (2, 1, 3));
    await finish();

    // DECODE: complete, length-correct bytes really reach the completed cache;
    // Flutter's descriptor (not a fake raster/decoder) rejects their contents.
    var decodeHealthy = false;
    final decodeUrl =
        urlFor('decode', () => HttpImageReply(decodeHealthy ? png : corrupt));
    final decodeData = dataFor(decodeUrl);
    await host.mount(decodeData);
    final decoded = host.observe();
    await host.failure('decode');
    expect(decoded.error, isNotNull);
    expect(readerImageRetryDelay(decoded.error!, 1), isNull);
    _facts(_events('failure').single,
        status: 'success',
        encoding: 'identity',
        raw: false,
        online: false,
        reason: 'other');
    expect(requests(decodeUrl), 1);
    final completed = await _drive(
        tester,
        () => OnlineImageCache.instance
            .get(_komiicCacheIdentity(decodeData, decodeUrl)),
        'inspect completed corrupt body');
    expect(completed, isNotNull);
    expect(
        await _drive(
            tester, completed!.file.readAsBytes, 'read task cache bytes'),
        corrupt);
    expect(_events('failure').map((e) => e['stage']).toSet(), {'decode'});
    expect(_events('retryScheduled'), isEmpty);
    await finish();
    // The disk lookup/read succeeds on a warm complete body, then the REAL
    // descriptor still rejects it. Warm cache facts must not borrow cold HTTP.
    await host.mount(decodeData);
    await host.failure('decode');
    expect(requests(decodeUrl), 1);
    _facts(_events('failure').single,
        raw: false, online: true, reason: 'other');

    // Manual retry opens attempt/generation BEFORE source invalidation. Here an
    // actual nonempty task-cache directory cannot be deleted without recursion.
    // Only that I/O condition is injected at ReadingData.invalidateImage; the
    // production page/pool performs invalidation ordering and catches the error.
    final invalidationTarget = Directory(p.join(App.cachePath, _secretPath));
    await _drive(tester, () async {
      await invalidationTarget.create();
      await File(p.join(invalidationTarget.path, 'owned'))
          .writeAsString(_secretBody);
    }, 'prepare nonempty cache invalidation target');
    decodeData.beforeInvalidate = () async {
      await invalidationTarget.delete();
    };
    await host.retry();
    await host.failure('cache');
    final invalidated = _events('failure').last;
    expect((
      invalidated['stage'],
      invalidated['attempt'],
      invalidated['generation']
    ), (
      'cache',
      2,
      2
    ));
    expect(decodeData.invalidationError, isA<FileSystemException>());
    _facts(invalidated, reason: 'fileIO');
    expect(requests(decodeUrl), 1,
        reason: 'failed invalidation cannot start a replacement provider');
    expect(_events('explicitRetry').single['attempt'], 2);
    decodeData.beforeInvalidate = null;
    decodeHealthy = true;
    await host.retry();
    await _frame(tester);
    expect(requests(decodeUrl), 2);
    expect(decodeData.invalidations, 2);
    _facts(_events('recovered').single,
        status: 'success', encoding: 'identity', raw: false, online: false);
    expect(_events('explicitRetry').map((e) => e['attempt']), [2, 3]);
    expect((
      _events('recovered').single['attempt'],
      _events('recovered').single['generation']
    ), (
      3,
      3
    ));
    await finish();

    // Real production preloader starts page 2 before a visible page joins it.
    // Release a complete corrupt body only AFTER handoff. The resulting failure
    // belongs to visible page 2, not to the initiating page 1 or an opaque retry.
    final handoff = Completer<void>();
    gates.add(handoff);
    final firstUrl = urlFor('prefetch-first', () => HttpImageReply(png));
    final secondUrl = urlFor('prefetch-second',
        () => HttpImageReply(corrupt, release: handoff.future));
    final sharedData = _Komiic('066-prefetch', [firstUrl, secondUrl], manager);
    await host.mount(sharedData, preload: 1);
    await _frame(tester);
    await _until(
        tester,
        () =>
            requests(secondUrl) == 1 &&
            host.logic!.previewPreloader.retainedKeys.isNotEmpty,
        'production speculative request');
    expect(_events(), isEmpty);
    host.logic!.pageController.jumpToPage(2);
    await tester.pump();
    await _until(
        tester,
        () => tester
            .widgetList<reader.ReaderPreviewPageImage>(
                find.byType(reader.ReaderPreviewPageImage))
            .any((w) => w.failureDiagnostics!.page == 2),
        'prefetched page becomes visible');
    handoff.complete();
    await host.failure('decode', page: 2);
    expect((requests(firstUrl), requests(secondUrl)), (1, 1));
    expect(_events('failure').every((e) => e['page'] == 2 && e['attempt'] == 1),
        isTrue);
    _facts(_events('failure').single,
        status: 'success',
        encoding: 'identity',
        raw: false,
        online: false,
        reason: 'other');
    await finish();

    // A second handoff joins DURING the prefetch's real 2-second backoff.
    // A 503 then a 200 makes execution-fact reset observable: the recovered page
    // must not retain serverError/unknown from the replayed failed execution.
    // Observe only public ReaderImage JSON, not the pool's relay/history.
    var speculativeRequests = 0;
    final replayFirst = urlFor('replay-first', () => HttpImageReply(png));
    final replaySecond = urlFor('replay-second', () {
      speculativeRequests++;
      return HttpImageReply(png, status: speculativeRequests == 1 ? 503 : 200);
    });
    await host.mount(
        _Komiic('066-replay', [replayFirst, replaySecond], manager),
        preload: 1);
    await _frame(tester);
    await _until(
        tester,
        () =>
            requests(replaySecond) == 1 &&
            host.logic!.previewPreloader.retainedKeys.isNotEmpty &&
            host.logic!.previewImagePool.reservedPreloadBytes == 0 &&
            ImageTemporaryPool.shared.reservedBytes == 0,
        'prefetch failed, retired its IO, and retained its backoff operation');
    expect(_events(), isEmpty,
        reason: 'hidden prefetch does not invent a visible page attempt');
    host.logic!.pageController.jumpToPage(2);
    await tester.pump();
    await _until(tester, () => _events('retryScheduled').isNotEmpty,
        'visible consumer replays the existing physical retry');
    final replayEvent = _events('retryScheduled').single;
    expect((
      replayEvent['page'],
      replayEvent['attempt'],
      replayEvent['generation'],
      replayEvent['stage'],
      replayEvent['retry']
    ), (
      2,
      1,
      1,
      'fetch',
      1
    ));
    expect((replayEvent['snapshot'] as Map)['replayed'], isTrue);
    _facts(replayEvent, status: 'serverError', raw: false, online: false);
    _facts(_events('failure').single,
        status: 'serverError', raw: false, online: false, reason: 'httpStatus');
    expect(requests(replaySecond), 1,
        reason: 'handoff must not start another fetch');
    await tester.pump(const Duration(seconds: 2));
    await _frame(tester);
    expect((requests(replayFirst), requests(replaySecond)), (1, 2));
    final replayRecovery = _events('recovered').single;
    expect((
      replayRecovery['page'],
      replayRecovery['attempt'],
      replayRecovery['generation']
    ), (
      2,
      1,
      1
    ));
    expect(replayRecovery['pageKey'], replayEvent['pageKey']);
    _facts(replayRecovery,
        status: 'success', encoding: 'identity', raw: false, online: false);
    expect(replayRecovery.containsKey('reason'), isFalse);
    expect(_events('retryScheduled'), hasLength(1));
    await finish();

    // Cancel an old scope while its body is outstanding, then paint a new scope
    // under the SAME page diagnostics session. Late old bytes cannot log failure
    // or recovery against the replacement attempt, nor revive an old cache key.
    final lateGate = Completer<void>();
    gates.add(lateGate);
    var lateRequest = 0;
    var lateHealthy = false;
    final lateUrl = urlFor('late-scope', () {
      lateRequest++;
      return lateRequest == 1
          ? HttpImageReply(corrupt, prefixBytes: 1, release: lateGate.future)
          : HttpImageReply(lateHealthy ? png : corrupt);
    });
    final lateData = dataFor(lateUrl);
    await host.mount(lateData);
    await _until(
        tester, () => requests(lateUrl) == 1, 'old scope transfer started');
    final oldWidget = tester.widget<reader.ReaderPreviewPageImage>(
        find.byType(reader.ReaderPreviewPageImage).first);
    final oldKey = oldWidget.resourceKey;
    ComicSource.sources.single.data['token'] = '${_secretToken}_scope_b';
    host.logic!.update();
    await tester.pump();
    await host.failure('decode');
    final newWidget = tester.widget<reader.ReaderPreviewPageImage>(
        find.byType(reader.ReaderPreviewPageImage).first);
    expect(newWidget.resourceKey, isNot(oldKey));
    expect(newWidget.failureDiagnostics!.pageKey,
        oldWidget.failureDiagnostics!.pageKey);
    expect(requests(lateUrl), 2);
    expect(_events('failure').single['attempt'], 2,
        reason: 'same logical page has a new attempt after its scope changed');
    _facts(_events('failure').single,
        status: 'success',
        encoding: 'identity',
        raw: false,
        online: false,
        reason: 'other');
    lateHealthy = true;
    await host.retry();
    await _frame(tester);
    final currentRecovery = _events('recovered').single;
    expect((currentRecovery['attempt'], currentRecovery['generation']), (3, 2));
    _facts(currentRecovery,
        status: 'success', encoding: 'identity', raw: false, online: false);
    final beforeLate = jsonEncode(_events());
    lateGate.complete();
    await _flush(tester, 20);
    await _frame(tester);
    expect(jsonEncode(_events()), beforeLate,
        reason:
            'cancelled old operation cannot report into the new attempt/generation');
    expect(requests(lateUrl), 3);
    await finish();

    // Writer throws on EVERY attempted event. The page still sees the original
    // terminal error and can recover to real pixels through its retry button.
    _Jm writerJm(String id, String url, bool Function() healthy,
            void Function() count) =>
        _Jm(
            id,
            [url],
            JmPageLoader.forTesting(
                images: manager,
                recombine: (bytes,
                    {required epsId,
                    required scrambleId,
                    required pictureName,
                    originalExtension = '.jpg'}) async {
                  count();
                  if (!healthy()) throw sameError;
                  return JmRecombine.recombine(bytes,
                      epsId: epsId,
                      scrambleId: scrambleId,
                      pictureName: pictureName,
                      originalExtension: originalExtension);
                }));
    var writerHealthy = false;
    var writerRecombines = 0;
    final writerUrl = urlFor('writer-throws', () => HttpImageReply(png));
    final writerData = writerJm('066-writer-jm', writerUrl, () => writerHealthy,
        () => writerRecombines++);
    final attemptedWrites = <Map<String, dynamic>>[];
    void failingWriter(String text) {
      attemptedWrites.add(jsonDecode(text) as Map<String, dynamic>);
      throw StateError('$_secretPath writer unavailable');
    }

    await host.mount(writerData, writer: failingWriter);
    final writerFailure = host.observe();
    await _until(
        tester,
        () =>
            writerFailure.error != null &&
            find.text('重试').evaluate().isNotEmpty,
        'throwing writer cannot prevent original failure UI');
    expect(
        attemptedWrites.where((e) => e['event'] == 'failure').single['stage'],
        'transform');
    expect(identical(writerFailure.error, sameError), isTrue,
        reason:
            'throwing writer must not replace or swallow the original exception');
    expect(readerImageRetryDelay(writerFailure.error!, 1), isNull);
    expect(requests(writerUrl), 1);
    writerHealthy = true;
    await host.retry();
    await _frame(tester);
    expect(requests(writerUrl), 2);
    expect(attemptedWrites.map((e) => e['event']),
        containsAll(['failure', 'explicitRetry', 'recovered']));
    for (final event in attemptedWrites.where((event) =>
        event['event'] == 'failure' || event['event'] == 'recovered')) {
      _facts(event,
          status: 'success',
          encoding: 'identity',
          raw: false,
          online: false,
          processed: false,
          reason: event['event'] == 'failure' ? 'fileIO' : null);
    }
    _safeEvents(attemptedWrites, root);
    await finish();
    await host.mount(writerData, writer: failingWriter);
    await _frame(tester);
    expect((requests(writerUrl), writerRecombines), (2, 2),
        reason: 'writer cannot perturb warm cache identity or recombine count');
    await finish();

    // Closing LogManager suppresses even a configured writer. Both failure and
    // success are still real. No assertion mistakes an absent log for success.
    LogManager.recordingEnabled = false;
    final callsBeforeDisabled = attemptedWrites.length;
    var disabledHealthy = false;
    var disabledRecombines = 0;
    final disabledUrl = urlFor('logging-disabled', () => HttpImageReply(png));
    final disabledData = writerJm('066-disabled-jm', disabledUrl,
        () => disabledHealthy, () => disabledRecombines++);
    await host.mount(disabledData, writer: failingWriter);
    final disabledFailure = host.observe();
    await _until(
        tester,
        () =>
            disabledFailure.error != null &&
            find.text('重试').evaluate().isNotEmpty,
        'logging-disabled page still reports failure UI');
    expect(identical(disabledFailure.error, sameError), isTrue,
        reason: 'logging disabled preserves the same original failure object');
    disabledHealthy = true;
    await host.retry();
    await _frame(tester);
    expect(requests(disabledUrl), 2);
    expect(attemptedWrites.length, callsBeforeDisabled);
    expect(_events(), isEmpty);
    await finish();
    await host.mount(disabledData, writer: failingWriter);
    await _frame(tester);
    expect((requests(disabledUrl), disabledRecombines), (2, 2));
    expect(attemptedWrites.length, callsBeforeDisabled);
    await finish();
    LogManager.recordingEnabled = true;
    expect(
        collected
            .where((e) => e['event'] == 'failure')
            .map((e) => e['stage'])
            .toSet(),
        {'fetch', 'cache', 'transform', 'decode'});
    _safeEvents(collected, root);
    expect(downloadManager.debugRecordCount, 0);
  });
}
