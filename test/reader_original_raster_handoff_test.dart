import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_original_raster_handoff.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';

const _metadata = ReaderRasterMetadata(
    size: ui.Size(7, 5), animated: false, format: 'png', workingBytes: 140);

Future<ui.Image> _makeImage({int width = 7, int height = 5}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      canvas.drawRect(
          ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1),
          ui.Paint()
            ..color = Color.fromARGB(255, x * 31, y * 47, (x + y) * 19));
    }
  }
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

class _Backend extends FlutterReaderRasterBackend {
  _Backend() : super(_metadata, persistRaster: false);
  Completer<void>? blocked;
  Completer<void>? estimateBlocked;
  Object? failure;
  int estimates = 0, decodes = 0;
  ui.Image? created;
  @override
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
      {required String backingPath}) async {
    estimates++;
    if (estimateBlocked != null) await estimateBlocked!.future;
    return 2 << 20;
  }

  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    decodes++;
    if (blocked != null) await blocked!.future;
    if (failure != null) throw failure!;
    // Intentionally returns a real image even after cancellation to exercise
    // the ownership guard independently from a cooperative backend.
    created = await _makeImage();
    return created!;
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 150 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File file;
  late FileStat snapshot;

  setUp(() async {
    final parent = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    directory = await parent.createTemp('first-original-raster-');
    file = File('${directory.path}/original.png');
    final image = await _makeImage();
    try {
      final encoded = await image.toByteData(format: ui.ImageByteFormat.png);
      await file.writeAsBytes(encoded!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
    snapshot = await file.stat();
  });
  tearDown(() async {
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    await directory.delete(recursive: true);
  });

  ReaderOriginalRasterHandoff start(
          _Backend backend, ImageWorkScheduler scheduler,
          {Future<void> Function()? verify}) =>
      ReaderOriginalRasterHandoff.start(
          file: file,
          metadata: _metadata,
          fileSnapshot: snapshot,
          backend: backend,
          backingPath: '${directory.path}/unused.rgba',
          scheduler: scheduler,
          verifyOriginal: verify ?? () async {});

  test('ready original stays budgeted and leased until exactly one transfer',
      () async {
    final backend = _Backend();
    final scheduler = ImageWorkScheduler(memoryBudgetBytes: 8 << 20);
    final handoff = start(backend, scheduler);
    await handoff.ready;
    expect(backend.estimates, 1);
    expect(backend.decodes, 1);
    expect(scheduler.activeCount, 1);
    expect(scheduler.reservedBytes, (2 << 20) + 140 * 3);
    expect(ReaderPageFileLease.activeLeaseCount, 1);
    expect(backend.created!.debugDisposed, isFalse);
    await handoff.verifyForTransfer();
    final image = handoff.take();
    expect(() => handoff.take(), throwsStateError);
    await handoff.drained;
    expect(scheduler.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    handoff.cancel();
    expect(image.debugDisposed, isFalse,
        reason: 'Transferred image belongs to its consumer');
    image.dispose();
  });

  test('cancelled running decode drains real image before releasing its source',
      () async {
    final backend = _Backend()..blocked = Completer<void>();
    final scheduler = ImageWorkScheduler(memoryBudgetBytes: 8 << 20);
    final handoff = start(backend, scheduler);
    await _until(() => backend.decodes == 1);
    handoff.cancel();
    await expectLater(handoff.ready, throwsA(isA<ImageWorkCancelled>()));
    var drained = false;
    unawaited(handoff.drained.then((_) => drained = true));
    await Future<void>.delayed(const Duration(milliseconds: 3));
    expect(drained, isFalse);
    expect(scheduler.reservedBytes, greaterThan(0));
    expect(ReaderPageFileLease.activeLeaseCount, 1);
    backend.blocked!.complete();
    await handoff.drained;
    await _until(() => scheduler.reservedBytes == 0);
    expect(backend.created!.debugDisposed, isTrue);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  test('cancelled ready raster is disposed and its reservation is drained',
      () async {
    final backend = _Backend();
    final scheduler = ImageWorkScheduler(memoryBudgetBytes: 8 << 20);
    final handoff = start(backend, scheduler);
    await handoff.ready;
    handoff.cancel();
    await handoff.drained;
    await _until(() => scheduler.reservedBytes == 0);
    expect(backend.created!.debugDisposed, isTrue);
    expect(handoff.take, throwsA(isA<ImageWorkCancelled>()));
  });

  test('scheduler cancellation drains a ready handoff without a consumer',
      () async {
    final backend = _Backend();
    final scheduler = ImageWorkScheduler(memoryBudgetBytes: 8 << 20);
    final handoff = start(backend, scheduler);
    await handoff.ready;
    scheduler.cancelWhere((key) => key.startsWith('reader-first-original:'));
    await handoff.drained;
    await _until(() => scheduler.reservedBytes == 0);
    expect(backend.created!.debugDisposed, isTrue);
    expect(handoff.take, throwsA(isA<ImageWorkCancelled>()));
  });

  test('cancellation while estimating never starts a codec or abandons a lease',
      () async {
    final backend = _Backend()..estimateBlocked = Completer<void>();
    final scheduler = ImageWorkScheduler(memoryBudgetBytes: 8 << 20);
    final handoff = start(backend, scheduler);
    await _until(() => backend.estimates == 1);
    handoff.cancel();
    await expectLater(handoff.ready, throwsA(isA<ImageWorkCancelled>()));
    expect(ReaderPageFileLease.activeLeaseCount, 1);
    backend.estimateBlocked!.complete();
    await handoff.drained;
    expect(backend.decodes, 0);
    expect(scheduler.reservedBytes, 0);
  });

  test('a budget refusal never starts full PNG decoding', () async {
    final backend = _Backend();
    final scheduler = ImageWorkScheduler(memoryBudgetBytes: 1 << 20);
    final handoff = start(backend, scheduler);
    await expectLater(handoff.ready, throwsA(isA<ImageWorkBudgetExceeded>()));
    await handoff.drained;
    expect(backend.decodes, 0);
    expect(scheduler.reservedBytes, 0);
  });

  test('cancellation of a queued handoff never starts decoding', () async {
    final blocker = Completer<void>();
    final scheduler =
        ImageWorkScheduler(maxConcurrent: 1, memoryBudgetBytes: 8 << 20);
    final other = scheduler.submit<void>(
        key: 'blocker',
        priority: ImageWorkPriority.visible,
        estimatedBytes: 1024,
        run: (_) => blocker.future);
    final backend = _Backend();
    final handoff = start(backend, scheduler);
    await _until(() => scheduler.pendingCount == 2);
    handoff.cancel();
    await expectLater(handoff.ready, throwsA(isA<ImageWorkCancelled>()));
    await handoff.drained;
    expect(backend.decodes, 0);
    expect(scheduler.reservedBytes, 1024);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    blocker.complete();
    await other.future;
    expect(scheduler.reservedBytes, 0);
  });

  test('source changed during decode disposes the image before publishing',
      () async {
    final backend = _Backend()..blocked = Completer<void>();
    final scheduler = ImageWorkScheduler(memoryBudgetBytes: 8 << 20);
    var current = true;
    final handoff = start(backend, scheduler, verify: () async {
      if (!current) throw StateError('Original replaced');
    });
    await _until(() => backend.decodes == 1);
    current = false;
    backend.blocked!.complete();
    await expectLater(handoff.ready, throwsStateError);
    await handoff.drained;
    expect(backend.created!.debugDisposed, isTrue);
  });

  test(
      'source changed while waiting for a surface cannot transfer stale pixels',
      () async {
    final backend = _Backend();
    final scheduler = ImageWorkScheduler(memoryBudgetBytes: 8 << 20);
    var current = true;
    final handoff = start(backend, scheduler, verify: () async {
      if (!current) throw StateError('Original replaced');
    });
    await handoff.ready;
    current = false;
    await expectLater(handoff.verifyForTransfer(), throwsStateError);
    await handoff.drained;
    expect(backend.created!.debugDisposed, isTrue);
    expect(handoff.take, throwsA(isA<ImageWorkCancelled>()));
  });

  test('backend failure drains the original and later work still succeeds',
      () async {
    final scheduler = ImageWorkScheduler(memoryBudgetBytes: 8 << 20);
    final backend = _Backend()..failure = StateError('Codec failed');
    final failed = start(backend, scheduler);
    await expectLater(failed.ready, throwsStateError);
    await failed.drained;
    expect(scheduler.reservedBytes, 0);
    backend.failure = null;
    final recovered = start(backend, scheduler);
    await recovered.ready;
    final image = recovered.take();
    await recovered.drained;
    image.dispose();
    expect(backend.decodes, 2);
  });

  test('non-sRGB PNG chunks are rejected before starting a whole codec',
      () async {
    final original = await file.readAsBytes();
    final unsupportedChunk = Uint8List.fromList([
      0,
      0,
      0,
      0,
      ...'cICP'.codeUnits,
      0,
      0,
      0,
      0,
    ]);
    await file.writeAsBytes([
      ...original.sublist(0, 33),
      ...unsupportedChunk,
      ...original.sublist(33),
    ]);
    snapshot = await file.stat();
    final backend = _Backend();
    final scheduler = ImageWorkScheduler(memoryBudgetBytes: 8 << 20);
    final handoff = start(backend, scheduler);
    await expectLater(handoff.ready, throwsStateError);
    await handoff.drained;
    expect(backend.decodes, 0);
    expect(scheduler.reservedBytes, 0);
  });

  test('PNG original dimensions are checked again before whole decoding',
      () async {
    final bytes = await file.readAsBytes();
    bytes[19] = 8;
    await file.writeAsBytes(bytes);
    snapshot = await file.stat();
    final backend = _Backend();
    final handoff =
        start(backend, ImageWorkScheduler(memoryBudgetBytes: 8 << 20));
    await expectLater(handoff.ready, throwsStateError);
    await handoff.drained;
    expect(backend.decodes, 0);
  });

  testWidgets(
      'Surface consumes one earlier raster with normal frame and retire',
      (tester) async {
    final source = FileReaderPageSource(
        identity: const ReaderPageIdentity(
            sourceKey: 'first-raster-test',
            workId: 'one',
            downloadId: 'test',
            sourceVersion: 'v1',
            episode: 1,
            page: 0),
        file: file,
        width: 7,
        height: 5);
    final backend = _Backend();
    final resolved = ReaderResolvedOriginal(
        source: source,
        file: file,
        metadata: _metadata,
        fileSnapshot: snapshot);
    final handoff = (await tester.runAsync(() async => start(
        backend, ImageWorkScheduler.shared,
        verify: resolved.verifyCurrent)))!;
    final changes = ValueNotifier(0);
    final viewport = GlobalKey();
    final frames = <ReaderPresentedFrame>[];
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
                key: viewport,
                width: 7,
                height: 5,
                child: ReaderImageSurface(
                    source: source,
                    sourceSize: _metadata.size,
                    metadata: _metadata,
                    backend: backend,
                    resolvedOriginal: resolved,
                    originalRasterHandoff: handoff,
                    fullOrdinaryImage: true,
                    viewportKey: viewport,
                    transformChanges: changes,
                    mode: ReaderDisplayMode.sharpFirst,
                    onPresented: frames.add)))));
    for (var i = 0; i < 20 && frames.isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 4)));
      await tester.pump();
    }
    expect(frames, isNotEmpty,
        reason: ReaderSurfaceDiagnostics.snapshot().toString());
    expect(frames.last.complete, isTrue);
    expect(frames.last.nativePixels, isTrue);
    expect(backend.decodes, 1);
    await tester.runAsync(() => handoff.drained);
    expect(ReaderSurfaceDiagnostics.residentBytes, 140);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() => handoff.drained);
    expect(backend.created!.debugDisposed, isTrue);
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ReaderSurfaceDiagnostics.pendingBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    changes.dispose();
  });

  testWidgets(
      'Surface disposal during transfer validation releases pending bytes',
      (tester) async {
    final source = FileReaderPageSource(
        identity: const ReaderPageIdentity(
            sourceKey: 'first-raster-test',
            workId: 'pending-transfer',
            downloadId: 'test',
            sourceVersion: 'v1',
            episode: 1,
            page: 0),
        file: file);
    final backend = _Backend();
    final resolved = ReaderResolvedOriginal(
        source: source,
        file: file,
        metadata: _metadata,
        fileSnapshot: snapshot);
    final transferStarted = Completer<void>();
    final transferGate = Completer<void>();
    var verifies = 0;
    final handoff = (await tester.runAsync(() async {
      final value = start(backend, ImageWorkScheduler.shared, verify: () async {
        await resolved.verifyCurrent();
        if (++verifies == 3) {
          transferStarted.complete();
          await transferGate.future;
        }
      });
      await value.ready;
      return value;
    }))!;
    final changes = ValueNotifier(0);
    final viewport = GlobalKey();
    try {
      await tester.pumpWidget(MaterialApp(
          home: SizedBox(
              key: viewport,
              width: 7,
              height: 5,
              child: ReaderImageSurface(
                  source: source,
                  sourceSize: _metadata.size,
                  metadata: _metadata,
                  backend: backend,
                  resolvedOriginal: resolved,
                  originalRasterHandoff: handoff,
                  fullOrdinaryImage: true,
                  viewportKey: viewport,
                  transformChanges: changes,
                  mode: ReaderDisplayMode.sharpFirst))));
      for (var i = 0; i < 30 && !transferStarted.isCompleted; i++) {
        await tester.pump();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 3)));
      }
      expect(transferStarted.isCompleted, isTrue);
      expect(ReaderSurfaceDiagnostics.pendingBytes, 140);
      expect(ImageWorkScheduler.shared.reservedBytes, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(ReaderSurfaceDiagnostics.pendingBytes, 0);
      transferGate.complete();
      await tester.runAsync(() => handoff.drained);
      expect(backend.created!.debugDisposed, isTrue);
      expect(ReaderSurfaceDiagnostics.residentBytes, 0);
      expect(ReaderSurfaceDiagnostics.pendingBytes, 0);
      expect(ImageWorkScheduler.shared.reservedBytes, 0);
    } finally {
      if (!transferGate.isCompleted) transferGate.complete();
      handoff.cancel();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => handoff.drained);
      changes.dispose();
    }
  });

  testWidgets('a Surface rejecting resolved identity drains its early raster',
      (tester) async {
    FileReaderPageSource source(String version) => FileReaderPageSource(
        identity: ReaderPageIdentity(
            sourceKey: 'first-raster-test',
            workId: version,
            downloadId: 'test',
            sourceVersion: version,
            episode: 1,
            page: 0),
        file: file);
    final old = source('old');
    final current = source('new');
    final backend = _Backend();
    final resolved = ReaderResolvedOriginal(
        source: old, file: file, metadata: _metadata, fileSnapshot: snapshot);
    final handoff = (await tester.runAsync(() async {
      final value = start(backend, ImageWorkScheduler.shared,
          verify: resolved.verifyCurrent);
      await value.ready;
      return value;
    }))!;
    final changes = ValueNotifier(0);
    final viewport = GlobalKey();
    await tester.pumpWidget(MaterialApp(
        home: SizedBox(
            key: viewport,
            width: 7,
            height: 5,
            child: ReaderImageSurface(
                source: current,
                sourceSize: _metadata.size,
                metadata: _metadata,
                backend: backend,
                resolvedOriginal: resolved,
                originalRasterHandoff: handoff,
                fullOrdinaryImage: true,
                viewportKey: viewport,
                transformChanges: changes,
                mode: ReaderDisplayMode.sharpFirst))));
    await tester.runAsync(() => handoff.drained);
    expect(backend.created!.debugDisposed, isTrue);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderSurfaceDiagnostics.snapshot().single['error'],
        contains('no longer matches'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    changes.dispose();
  });
}
