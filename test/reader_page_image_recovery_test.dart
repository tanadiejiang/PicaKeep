import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep/pages/reader/reader_page_image.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

class _Backend extends ReaderRasterBackend {
  const _Backend();
  static const metadata = ReaderRasterMetadata(
      size: Size(400, 600),
      animated: false,
      format: 'fixture',
      workingBytes: 1);
  @override
  bool get requiresFileBacking => false;
  @override
  Future<ReaderRasterMetadata> probe(File file) async => metadata;
  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    if (isCancelled()) throw const ImageWorkCancelled();
    final picture = ui.PictureRecorder();
    Canvas(picture).drawColor(Colors.blue, BlendMode.src);
    final recording = picture.endRecording();
    try {
      return recording.toImageSync(demand.outputWidth, demand.outputHeight);
    } finally {
      recording.dispose();
    }
  }
}

class _Source extends FileReaderPageSource implements RasterReaderPageSource {
  _Source(String name,
      {this.metadataError, this.metadataGate, this.disposalGate})
      : super(
            identity: ReaderPageIdentity(
                sourceKey: 'fixture',
                workId: name,
                downloadId: name,
                episode: 1,
                page: 0,
                sourceVersion: '1'),
            file: File('unused-$name'));
  final Object? metadataError;
  final Completer<void>? metadataGate;
  final Completer<void>? disposalGate;
  int disposals = 0;
  @override
  ReaderRasterBackend get rasterBackend => const _Backend();
  @override
  File get rasterLocator => File('unused-${identity.workId}');
  @override
  Future<ReaderRasterMetadata> openRasterMetadata() async {
    await metadataGate?.future;
    if (metadataError != null) throw metadataError!;
    return _Backend.metadata;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await disposalGate?.future;
    await super.dispose();
  }
}

class _Harness {
  final changes = ChangeNotifier();
  // An unattached viewport keeps these source-resolution tests independent of
  // native raster/cache IO. The Surface still opens the fake raster metadata.
  final viewport = GlobalKey();
  Future<void> mount(
          WidgetTester tester, Future<ReaderPageSource> Function() load,
          {String resource = 'first'}) =>
      tester.pumpWidget(MaterialApp(
          home: SizedBox(
              width: 400,
              height: 600,
              child: ReaderPageImage(
                  key: const ValueKey('same-state'),
                  loadSource: load,
                  resourceKey: resource,
                  viewportKey: viewport,
                  transformChanges: changes,
                  mode: ReaderDisplayMode.sharpFirst))));
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump();
  }
}

Future<void> _advance(WidgetTester tester, int milliseconds) async {
  await tester.pump(Duration(milliseconds: milliseconds));
  await _flush(tester);
}

void main() {
  for (final error in <Object>[
    const ImageEngineQueueExceeded(128),
    const ImageWorkQueueExceeded(ImageWorkLane.execution, 128),
  ]) {
    testWidgets('${error.runtimeType} recovers without a manual page reload',
        (tester) async {
      final harness = _Harness();
      addTearDown(harness.changes.dispose);
      final recovered = _Source('recovered');
      var loads = 0;
      await harness.mount(tester, () async {
        if (++loads == 1) throw error;
        return recovered;
      });
      await _flush(tester);
      expect(loads, 1);
      expect(find.byType(TextButton), findsNothing);
      await _advance(tester, 120);
      expect(loads, 2);
      expect(
          tester
              .widget<ReaderImageSurface>(find.byType(ReaderImageSurface))
              .source,
          same(recovered));
      await tester.pumpWidget(const SizedBox());
      await _flush(tester);
      expect(recovered.disposals, 1);
      expect(ReaderPageFileLease.activeLeaseCount, 0);
    });
  }

  testWidgets('a failed metadata source drains before automatic reselection',
      (tester) async {
    final harness = _Harness();
    addTearDown(harness.changes.dispose);
    final drain = Completer<void>();
    final failed = _Source('failed',
        metadataError: const ImageEngineQueueExceeded(128),
        disposalGate: drain);
    final recovered = _Source('recovered');
    var loads = 0;
    await harness.mount(tester, () async => ++loads == 1 ? failed : recovered);
    await _flush(tester);
    expect(failed.disposals, 1);
    await _advance(tester, 1000);
    expect(loads, 1, reason: 'cleanup has not released the previous source');
    drain.complete();
    await _flush(tester);
    await _advance(tester, 120);
    expect(loads, 2);
    expect(find.byType(ReaderImageSurface), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    expect(failed.disposals, 1);
    expect(recovered.disposals, 1);
  });

  testWidgets('two retries are bounded and explicit retry starts a new budget',
      (tester) async {
    final harness = _Harness();
    addTearDown(harness.changes.dispose);
    var loads = 0;
    final recovered = _Source('recovered');
    await harness.mount(tester, () async {
      if (++loads < 5) throw const ImageEngineQueueExceeded(128);
      return recovered;
    });
    await _flush(tester);
    await _advance(tester, 120);
    await _advance(tester, 240);
    expect(loads, 3);
    expect(find.byType(TextButton), findsOneWidget);
    await _advance(tester, 3000);
    expect(loads, 3);
    await tester.tap(find.byType(TextButton));
    await _flush(tester);
    expect(loads, 4);
    await _advance(tester, 120);
    expect(loads, 5);
    expect(find.byType(ReaderImageSurface), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
  });

  for (final error in <Object>[
    const ImageEngineException(3, 'Native memory budget is insufficient'),
    const FileSystemException('Original file is unavailable', 'missing.png'),
  ]) {
    testWidgets(
        '${error.runtimeType} stays manual rather than retrying forever',
        (tester) async {
      final harness = _Harness();
      addTearDown(harness.changes.dispose);
      var loads = 0;
      await harness.mount(tester, () async {
        loads++;
        throw error;
      });
      await _flush(tester);
      expect(find.byType(TextButton), findsOneWidget);
      await _advance(tester, 3000);
      expect(loads, 1);
      await tester.pumpWidget(const SizedBox());
      await _flush(tester);
    });
  }

  testWidgets('resource replacement cancels the old delayed retry',
      (tester) async {
    final harness = _Harness();
    addTearDown(harness.changes.dispose);
    var oldLoads = 0, newLoads = 0;
    await harness.mount(tester, () async {
      oldLoads++;
      throw const ImageEngineQueueExceeded(128);
    });
    await _flush(tester);
    final selected = _Source('new');
    await harness.mount(tester, () async {
      newLoads++;
      return selected;
    }, resource: 'new');
    await _flush(tester);
    await _advance(tester, 3000);
    expect(oldLoads, 1);
    expect(newLoads, 1);
    expect(
        tester
            .widget<ReaderImageSurface>(find.byType(ReaderImageSurface))
            .source,
        same(selected));
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
  });

  testWidgets('dispose cancels a pending automatic retry', (tester) async {
    final harness = _Harness();
    addTearDown(harness.changes.dispose);
    var loads = 0;
    await harness.mount(tester, () async {
      loads++;
      throw const ImageEngineQueueExceeded(128);
    });
    await _flush(tester);
    await tester.pumpWidget(const SizedBox());
    await _advance(tester, 3000);
    expect(loads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'replacing an unresolved source waits for its result and disposal',
      (tester) async {
    final harness = _Harness();
    addTearDown(harness.changes.dispose);
    final pending = Completer<ReaderPageSource>();
    final drain = Completer<void>();
    final stale = _Source('stale', disposalGate: drain);
    final selected = _Source('new');
    var newLoads = 0;
    await harness.mount(tester, () => pending.future);
    await _flush(tester);
    await harness.mount(tester, () async {
      newLoads++;
      return selected;
    }, resource: 'new');
    await _flush(tester);
    expect(newLoads, 0, reason: 'old source selection is still in flight');
    pending.complete(stale);
    await _flush(tester);
    expect(stale.disposals, 1);
    expect(newLoads, 0, reason: 'old source disposal has not drained');
    drain.complete();
    await _flush(tester);
    expect(newLoads, 1);
    expect(
        tester
            .widget<ReaderImageSurface>(find.byType(ReaderImageSurface))
            .source,
        same(selected));
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    expect(stale.disposals, 1);
    expect(selected.disposals, 1);
  });

  testWidgets(
      'an obsolete metadata queue failure cannot retry the new resource',
      (tester) async {
    final harness = _Harness();
    addTearDown(harness.changes.dispose);
    final metadata = Completer<void>();
    final stale = _Source('stale',
        metadataGate: metadata,
        metadataError: const ImageEngineQueueExceeded(128));
    final selected = _Source('new');
    var newLoads = 0;
    await harness.mount(tester, () async => stale);
    await _flush(tester);
    await harness.mount(tester, () async {
      newLoads++;
      return selected;
    }, resource: 'new');
    await _flush(tester);
    expect(stale.disposals, 1,
        reason: 'source cancellation begins immediately');
    expect(newLoads, 0, reason: 'old metadata work is still in flight');
    metadata.complete();
    await _flush(tester);
    await _advance(tester, 3000);
    expect(newLoads, 1);
    expect(
        tester
            .widget<ReaderImageSurface>(find.byType(ReaderImageSurface))
            .source,
        same(selected));
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    expect(stale.disposals, 1);
  });

  testWidgets('a source returned after dispose is cleaned without publication',
      (tester) async {
    final harness = _Harness();
    addTearDown(harness.changes.dispose);
    final pending = Completer<ReaderPageSource>();
    final stale = _Source('stale');
    await harness.mount(tester, () => pending.future);
    await _flush(tester);
    await tester.pumpWidget(const SizedBox());
    pending.complete(stale);
    await _flush(tester);
    await _advance(tester, 3000);
    expect(stale.disposals, 1);
    expect(find.byType(ReaderImageSurface), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a peer file lease does not block a plain file page reload',
      (tester) async {
    final harness = _Harness();
    addTearDown(harness.changes.dispose);
    final folder = Directory.systemTemp.createTempSync('reader-shared-lease-');
    final original = File('${folder.path}/original.bin')
      ..writeAsBytesSync([1, 2, 3]);
    final peerRelease = ReaderPageFileLease.acquire(original);
    var peerReleased = false;
    addTearDown(() {
      if (!peerReleased) peerRelease();
      folder.deleteSync(recursive: true);
    });
    // The stale snapshot refuses the original before any native/Flutter codec
    // is reached. A separate visible peer keeps its path lease throughout the
    // failed page's manual reload; this exercises the global drain contract.
    final failed = FileReaderPageSource(
        identity: const ReaderPageIdentity(
            sourceKey: 'fixture',
            workId: 'shared-original',
            downloadId: 'shared-original',
            episode: 1,
            page: 0,
            sourceVersion: 'stale'),
        file: original,
        byteLength: 4);
    final selected = _Source('recovered');
    var loads = 0;
    await harness.mount(tester, () async => ++loads == 1 ? failed : selected);
    // File.stat requires real filesystem progress outside the widget test's
    // fake clock. The tiny original remains byte-identical throughout.
    for (var i = 0; i < 50 && find.byType(TextButton).evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
      await _flush(tester);
    }
    expect(find.byType(TextButton), findsOneWidget);
    expect(ReaderPageFileLease.activeLeaseCount, 1);
    await tester.tap(find.byType(TextButton));
    await _flush(tester);
    expect(loads, 2, reason: 'a peer lease must not block source reselection');
    expect(
        tester
            .widget<ReaderImageSurface>(find.byType(ReaderImageSurface))
            .source,
        same(selected));
    expect(original.readAsBytesSync(), [1, 2, 3]);
    expect(ReaderPageFileLease.activeLeaseCount, 1);
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    expect(selected.disposals, 1);
    expect(original.readAsBytesSync(), [1, 2, 3]);
    peerRelease();
    peerReleased = true;
    await _flush(tester);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets(
      'a late plain file source cannot block the next resource on a peer',
      (tester) async {
    final harness = _Harness();
    addTearDown(harness.changes.dispose);
    final folder = Directory.systemTemp.createTempSync('reader-late-file-');
    final original = File('${folder.path}/original.bin')
      ..writeAsBytesSync([1, 2, 3]);
    final peerRelease = ReaderPageFileLease.acquire(original);
    var peerReleased = false;
    addTearDown(() {
      if (!peerReleased) peerRelease();
      folder.deleteSync(recursive: true);
    });
    final pending = Completer<ReaderPageSource>();
    final stale = FileReaderPageSource(
        identity: const ReaderPageIdentity(
            sourceKey: 'fixture',
            workId: 'late-shared-original',
            downloadId: 'late-shared-original',
            episode: 1,
            page: 0,
            sourceVersion: '1'),
        file: original);
    final selected = _Source('new');
    var newLoads = 0;
    await harness.mount(tester, () => pending.future);
    await _flush(tester);
    await harness.mount(tester, () async {
      newLoads++;
      return selected;
    }, resource: 'new');
    await _flush(tester);
    expect(newLoads, 0);
    pending.complete(stale);
    await _flush(tester);
    expect(newLoads, 1);
    expect(
        tester
            .widget<ReaderImageSurface>(find.byType(ReaderImageSurface))
            .source,
        same(selected));
    expect(ReaderPageFileLease.activeLeaseCount, 1);
    expect(original.readAsBytesSync(), [1, 2, 3]);
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    expect(original.readAsBytesSync(), [1, 2, 3]);
    peerRelease();
    peerReleased = true;
    await _flush(tester);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });
}
