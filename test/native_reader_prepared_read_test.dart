import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

import 'support/image_disk_quota_fixture.dart';

Future<Uint8List> _rgba(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

int _nativeCancellations() {
  final diagnostics = PicakeepImageEngine.workerDiagnostics;
  return (diagnostics['jobsFailedCode2'] ?? 0) +
      diagnostics['jobsCancelledBeforeExecution']!;
}

void _expectNativeWorkReleased(String backing) {
  expect(ReaderPageFileLease.activeLeaseCount, 0);
  expect(DerivedImageStore.isPathLeased(backing), isFalse);
  expect(ImageDiskQuota.shared.pendingCount, 0);
  expect(ImageTemporaryPool.shared.reservedBytes, 0);
  expect(PicakeepImageEngine.workerDiagnostics['activeJobs'], 0);
  expect(PicakeepImageEngine.workerDiagnostics['queuedJobs'], 0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixtures = Platform.environment['PICAKEEP_IMAGE_ENGINE_FIXTURES'];
  final enabled = fixtures != null && PicakeepImageEngine.isAvailable;
  final preparedAvailable =
      enabled && PicakeepImageEngine.preparedReadsAvailable;
  const engine = PicakeepImageEngine();
  const demand = ReaderTileDemand(ui.Rect.fromLTWH(31, 73, 129, 137), 1, 0, 0);
  late Directory directory;
  late Directory suiteDirectory;
  late File source;
  late String backing;

  setUpAll(() async {
    if (!enabled) return;
    suiteDirectory = await Directory(Platform.isWindows
            ? r'E:\picakeep-image-pipeline-022-work'
            : Directory.systemTemp.path)
        .createTemp('prepared-backend-');
    App.cachePath = suiteDirectory.path;
    App.dataPath = suiteDirectory.path;
  });
  tearDownAll(() async {
    if (enabled) await suiteDirectory.delete(recursive: true);
  });
  setUp(() async {
    if (!enabled) return;
    directory = await suiteDirectory.createTemp('case-');
    source = File('$fixtures/640x960-alpha.png');
    backing = '${directory.path}/original.raw';
    installTaskDiskQuota(() => [directory.path]);
  });
  tearDown(() async {
    if (!enabled) return;
    await ImageDiskQuota.shared.drain();
    ImageDiskQuota.overrideForTesting = null;
    await PicakeepImageEngine.shutdownIdleWorkers();
    await directory.delete(recursive: true);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  test('prepared read returns exact raw image without write admission',
      () async {
    await engine.prepareBacking(source.path,
        backingPath: backing,
        memoryBudgetBytes: 96 << 20,
        diskBudgetBytes: 32 << 20);
    final expected = await engine.decodeRegion(
        source.path, const NativeImageRect(31, 73, 129, 137),
        backingPath: backing,
        memoryBudgetBytes: 96 << 20,
        diskBudgetBytes: 32 << 20,
        premultiplyAlpha: true);
    final rgba = Uint8List.fromList(expected.bytes);
    expected.dispose();
    ImageDiskQuota.overrideForTesting = ImageDiskQuota(
        roots: () => [directory.path],
        idleLimitBytes: () => 32 << 20,
        space: (_) async =>
            throw StateError('Warm read must not admit a write'));
    const backend = NativeReaderRasterBackend(
        persistRaster: false, preferPreparedRead: true);
    final metadata = await backend.probe(source);
    final warmBytes = backend.preparedWorkingBytes(metadata, demand)!;
    final nativeEstimate = await backend.estimateWorkingBytes(source, demand,
        backingPath: backing);
    expect(warmBytes, greaterThanOrEqualTo(nativeEstimate));
    final workersBefore = PicakeepImageEngine.workerDiagnostics;
    final image = await backend.decodePrepared(source, demand,
        backingPath: backing,
        memoryBudgetBytes: warmBytes,
        isCancelled: () => false);
    try {
      expect(await _rgba(image), orderedEquals(rgba));
      expect(ImageDiskQuota.shared.pendingCount, 0);
      expect(ImageDiskQuota.shared.rejectedCount, 0);
      expect(ReaderPageFileLease.activeLeaseCount, 0);
      final workersAfter = PicakeepImageEngine.workerDiagnostics;
      expect(workersAfter['jobsSubmittedEstimate'],
          workersBefore['jobsSubmittedEstimate']);
      expect(workersAfter['jobsSubmittedDecodePrepared'],
          workersBefore['jobsSubmittedDecodePrepared']! + 1);
    } finally {
      image.dispose();
    }
  }, skip: !preparedAvailable);

  test('prepared admission miss never creates a backing under warm budget',
      () async {
    const backend = NativeReaderRasterBackend(
        persistRaster: false, preferPreparedRead: true);
    final metadata = await backend.probe(source);
    final warmBytes = backend.preparedWorkingBytes(metadata, demand)!;
    final workersBefore = PicakeepImageEngine.workerDiagnostics;
    ImageDiskQuota.overrideForTesting = ImageDiskQuota(
        roots: () => [directory.path],
        idleLimitBytes: () => 32 << 20,
        space: (_) async => throw StateError('Read-only miss cannot write'));
    await expectLater(
        backend.decodePrepared(source, demand,
            backingPath: backing,
            memoryBudgetBytes: warmBytes,
            isCancelled: () => false),
        throwsA(isA<ReaderPreparedReadMiss>()));
    expect(await File(backing).exists(), isFalse);
    expect(await directory.list().toList(), isEmpty);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    expect(ImageDiskQuota.shared.pendingCount, 0);
    final workersAfter = PicakeepImageEngine.workerDiagnostics;
    expect(workersAfter['jobsSubmittedEstimate'],
        workersBefore['jobsSubmittedEstimate']);
    expect(workersAfter['jobsSubmittedDecode'],
        workersBefore['jobsSubmittedDecode']);
    expect(workersAfter['jobsFailedDecodePrepared'],
        workersBefore['jobsFailedDecodePrepared']! + 1);
  }, skip: !preparedAvailable);

  test('native backend decodes sampling gutter at original coordinates',
      () async {
    const rasterRect = ui.Rect.fromLTWH(29, 71, 133, 141);
    const gutteredDemand = ReaderTileDemand(
        ui.Rect.fromLTWH(31, 73, 129, 137), 1, 0, 0,
        rasterRect: rasterRect);
    final expected = await engine.decodeRegion(
        source.path, const NativeImageRect(29, 71, 133, 141),
        backingPath: '${directory.path}/expected.raw',
        memoryBudgetBytes: 96 << 20,
        diskBudgetBytes: 32 << 20,
        premultiplyAlpha: true);
    final expectedBytes = Uint8List.fromList(expected.bytes);
    expected.dispose();
    final image = await const NativeReaderRasterBackend(persistRaster: false)
        .decode(source, gutteredDemand,
            backingPath: backing,
            memoryBudgetBytes: 96 << 20,
            isCancelled: () => false);
    addTearDown(image.dispose);
    expect(gutteredDemand.sourceRect, const ui.Rect.fromLTWH(31, 73, 129, 137));
    expect((image.width, image.height), (133, 141));
    expect(await _rgba(image), orderedEquals(expectedBytes));
  }, skip: !enabled);

  for (final prepared in [false, true]) {
    test(
        '${prepared ? 'prepared' : 'cold'} native cancellation is not a page '
        'failure and releases its reservations', () async {
      if (prepared) {
        await engine.prepareBacking(source.path,
            backingPath: backing,
            memoryBudgetBytes: 96 << 20,
            diskBudgetBytes: 32 << 20);
      }
      const backend = NativeReaderRasterBackend(persistRaster: false);
      final cancellationCount = _nativeCancellations();
      final images = <ui.Image>[];
      final previous = ui.Image.onCreate;
      ui.Image.onCreate = images.add;
      try {
        // Keep the Dart predicate false: the cancellation future must reach
        // the real native token and its status 2 must cross the backend bridge.
        // A Dart pre-check alone cannot satisfy this regression.
        await expectLater(
            prepared
                ? backend.decodePrepared(source, demand,
                    backingPath: backing,
                    memoryBudgetBytes: 96 << 20,
                    isCancelled: () => false,
                    cancelled: SynchronousFuture<void>(null))
                : backend.decode(source, demand,
                    backingPath: backing,
                    memoryBudgetBytes: 96 << 20,
                    isCancelled: () => false,
                    cancelled: SynchronousFuture<void>(null)),
            throwsA(isA<ImageWorkCancelled>()));
        expect(_nativeCancellations(), cancellationCount + 1);
        expect(images, isEmpty);
        _expectNativeWorkReleased(backing);
      } finally {
        ui.Image.onCreate = previous;
      }
      // The same original/backing and worker must remain usable after cancel.
      final image = prepared
          ? await backend.decodePrepared(source, demand,
              backingPath: backing,
              memoryBudgetBytes: 96 << 20,
              isCancelled: () => false)
          : await backend.decode(source, demand,
              backingPath: backing,
              memoryBudgetBytes: 96 << 20,
              isCancelled: () => false);
      try {
        expect((image.width, image.height), (129, 137));
      } finally {
        image.dispose();
      }
      _expectNativeWorkReleased(backing);
    }, skip: prepared ? !preparedAvailable : !enabled);
  }

  test('native backing preparation cancellation releases quota and can recover',
      () async {
    const backend = NativeReaderRasterBackend(persistRaster: false);
    final cancellationCount = _nativeCancellations();
    await expectLater(
        backend.prepareBacking(source,
            backingPath: backing,
            memoryBudgetBytes: 96 << 20,
            cancelled: SynchronousFuture<void>(null)),
        throwsA(isA<ImageWorkCancelled>()));
    expect(_nativeCancellations(), cancellationCount + 1);
    _expectNativeWorkReleased(backing);
    await backend.prepareBacking(source,
        backingPath: backing,
        memoryBudgetBytes: 96 << 20,
        cancelled: Completer<void>().future);
    expect(await File(backing).exists(), isTrue);
    _expectNativeWorkReleased(backing);
  }, skip: !enabled);

  test(
      'full native worker queue remains recoverable across backend entrypoints',
      () async {
    await PicakeepImageEngine.shutdownIdleWorkers();
    const backend = NativeReaderRasterBackend(persistRaster: false);
    final limit = PicakeepImageEngine.workerDiagnostics['queuedLimit']!;
    // Starting workers have no receive port yet. Fill the actual pool before
    // yielding this turn, so every rejected backend request sees the same full
    // queue without timers, large decodes or a substitute engine.
    final fillers = <Future<ImageMetadata>>[
      for (var i = 0; i < limit; i++) engine.probe(source.path)
    ];
    expect(PicakeepImageEngine.workerDiagnostics['queuedJobs'], limit);
    final requests = <Future<dynamic>>[
      backend.probe(source),
      backend.estimateBackingWorkingBytes(source, backingPath: backing),
      backend.estimateWorkingBytes(source, demand, backingPath: backing),
      backend.prepareBacking(source,
          backingPath: backing,
          memoryBudgetBytes: 96 << 20,
          cancelled: Completer<void>().future),
      backend.decode(source, demand,
          backingPath: backing,
          memoryBudgetBytes: 96 << 20,
          isCancelled: () => false),
      if (preparedAvailable)
        backend.decodePrepared(source, demand,
            backingPath: backing,
            memoryBudgetBytes: 96 << 20,
            isCancelled: () => false),
    ];
    try {
      await Future.wait(requests.map((request) => expectLater(
          request,
          throwsA(isA<ImageWorkQueueExceeded>()
              .having((error) => error.lane, 'lane', ImageWorkLane.execution)
              .having((error) => error.limit, 'limit', limit)))));
    } finally {
      await Future.wait(fillers);
    }
    _expectNativeWorkReleased(backing);
    expect(await File(backing).exists(), isFalse);
    final image = await backend.decode(source, demand,
        backingPath: backing,
        memoryBudgetBytes: 96 << 20,
        isCancelled: () => false);
    try {
      expect((image.width, image.height), (129, 137));
    } finally {
      image.dispose();
    }
    _expectNativeWorkReleased(backing);
  }, skip: !enabled);

  test(
      'prepared miss falls back through full quota and releases image on cancel',
      () async {
    final quota = ImageDiskQuota.shared;
    final image = await const NativeReaderRasterBackend(
            persistRaster: false, preferPreparedRead: true)
        .decode(source, demand,
            backingPath: backing,
            memoryBudgetBytes: 96 << 20,
            isCancelled: () => false);
    expect(await File(backing).exists(), isTrue);
    image.dispose();
    expect(quota.pendingCount, 0);
    final created = <ui.Image>[];
    var cancelled = false;
    final previous = ui.Image.onCreate;
    ui.Image.onCreate = (image) {
      created.add(image);
      cancelled = true;
    };
    try {
      await expectLater(
          const NativeReaderRasterBackend(
                  persistRaster: false, preferPreparedRead: true)
              .decode(source, demand,
                  backingPath: backing,
                  memoryBudgetBytes: 96 << 20,
                  isCancelled: () => cancelled),
          throwsA(isA<ImageWorkCancelled>()));
      expect(created, isNotEmpty);
      expect(created.every((image) => image.debugDisposed), isTrue);
      expect(ReaderPageFileLease.activeLeaseCount, 0);
    } finally {
      ui.Image.onCreate = previous;
    }
  }, skip: !preparedAvailable);

  test('non-miss prepared error is not hidden by write fallback', () async {
    await engine.prepareBacking(source.path,
        backingPath: backing,
        memoryBudgetBytes: 96 << 20,
        diskBudgetBytes: 32 << 20);
    final images = <ui.Image>[];
    final previous = ui.Image.onCreate;
    ui.Image.onCreate = images.add;
    try {
      for (final memoryBytes in [0, 1, 1024]) {
        await expectLater(
            const NativeReaderRasterBackend(
                    persistRaster: false, preferPreparedRead: true)
                .decode(source, demand,
                    backingPath: backing,
                    memoryBudgetBytes: memoryBytes,
                    isCancelled: () => false),
            throwsA(isA<ImageEngineException>()
                .having((e) => e.code, 'code', 3)
                .having((e) => e is ImageEngineQueueExceeded, 'queue overload',
                    isFalse)));
      }
      expect(images, isEmpty);
      expect(ImageDiskQuota.shared.pendingCount, 0);
      expect(ReaderPageFileLease.activeLeaseCount, 0);
      await expectLater(
          engine.decodeRegion(
              source.path, const NativeImageRect(31, 73, 129, 137),
              backingPath: backing, preparedOnly: true, diskBudgetBytes: -1),
          throwsArgumentError);
    } finally {
      ui.Image.onCreate = previous;
    }
  }, skip: !preparedAvailable);

  test('library without prepared symbol retains the fully admitted path',
      () async {
    expect(PicakeepImageEngine.preparedReadsAvailable, isFalse);
    final image = await const NativeReaderRasterBackend(
            persistRaster: false, preferPreparedRead: true)
        .decode(source, demand,
            backingPath: backing,
            memoryBudgetBytes: 96 << 20,
            isCancelled: () => false);
    try {
      expect((image.width, image.height), (129, 137));
      expect(await File(backing).exists(), isTrue);
      expect(ImageDiskQuota.shared.pendingCount, 0);
    } finally {
      image.dispose();
    }
  }, skip: !enabled || preparedAvailable);
}
