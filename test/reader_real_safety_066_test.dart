// 066 F5 offline safety evidence, NOT device RSS/native/GPU peak evidence.
// Actual valid streaming-generated PNGs; no forged headers or fake rasters.
// F4 separately covers the production buildComicView factory. This file adds
// narrow guarded preview/whole renderer boundaries with the real ReadingData
// adapter and an observation-only delegate to FlutterReaderRasterBackend.
// The selected sharp backend is explicitly Flutter compatibility, not native.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart' show ComicType;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/reader_preview_provider.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/image_disk_quota_fixture.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_cache.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart' as reader;
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep/pages/reader/reader_whole_image.dart';
import 'package:sqlite3/open.dart';

class _RealBackendObservation extends ReaderRasterBackend {
  _RealBackendObservation(ReaderRasterMetadata metadata)
      : real = FlutterReaderRasterBackend(metadata);
  final FlutterReaderRasterBackend real;
  final estimates = <ReaderTileDemand>[];
  final decodes = <ReaderTileDemand>[];

  @override
  bool get requiresFileBacking => real.requiresFileBacking;
  @override
  Future<ReaderRasterMetadata> probe(File file) => real.probe(file);
  @override
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
      {required String backingPath}) {
    estimates.add(demand);
    return real.estimateWorkingBytes(file, demand, backingPath: backingPath);
  }

  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) {
    decodes.add(demand);
    // No alternate raster, injected error, changed budget or changed demand.
    return real.decode(file, demand,
        backingPath: backingPath,
        memoryBudgetBytes: memoryBudgetBytes,
        isCancelled: isCancelled,
        cancelled: cancelled);
  }
}

Future<void> _flush(WidgetTester tester, [int turns = 1]) async {
  for (var i = 0; i < turns; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _until(
    WidgetTester tester, bool Function() ready, String phase) async {
  for (var i = 0; i < 300 && !ready(); i++) {
    await _flush(tester);
  }
  expect(ready(), isTrue, reason: phase);
}

Future<T?> _drive<T>(
    WidgetTester tester, Future<T> Function() operation, String phase) async {
  var done = false;
  T? result;
  Object? error;
  StackTrace? trace;
  unawaited(operation().then<void>((value) {
    result = value;
    done = true;
  }, onError: (Object failure, StackTrace stack) {
    error = failure;
    trace = stack;
    done = true;
  }));
  await _until(tester, () => done, phase);
  if (error != null) Error.throwWithStackTrace(error!, trace!);
  return result;
}

// Real encoded descriptor only; no instantiateCodec/getNextFrame for the huge
// fixture. This mirrors the compatibility metadata boundary without making a
// claim about descriptor-internal allocations or engine/native process memory.
Future<ReaderRasterMetadata> _descriptorMetadata(File file) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return ReaderRasterMetadata(
        size: Size(descriptor.width.toDouble(), descriptor.height.toDouble()),
        animated: false,
        format: 'compatibility',
        hasColorProfile: true,
        workingBytes: descriptor.width * descriptor.height * 4);
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

List<RawImage> _frames(WidgetTester tester) => tester
    .widgetList<RawImage>(find.byType(RawImage))
    .where((raw) => raw.image != null)
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late List<Map<String, dynamic>> manifest;
  late File longFile, largeFile;
  final previousLog = LogManager.recordingEnabled;
  final previousQuota = ImageDiskQuota.overrideForTesting;
  late ImageDiskQuota quota;
  setUpAll(() async {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows,
          () => DynamicLibrary.open(
              '${Directory.current.path}/windows/sqlite3.dll'));
    }
    root = await Directory.systemTemp.createTemp('reader_real_safety_066_');
    App.dataPath = '${root.path}/data';
    App.cachePath = '${root.path}/cache';
    await Directory(App.dataPath).create();
    await Directory(App.cachePath).create();
    quota =
        installTaskDiskQuota(() => [App.cachePath, '${App.dataPath}/cache']);
    SharedPreferences.setMockInitialValues({});
    LogManager.recordingEnabled = false;
    const assets = 'test/fixtures/reader_066';
    final json =
        jsonDecode(await File('$assets/safety_manifest.json').readAsString())
            as Map;
    manifest = (json['fixtures'] as List).cast<Map<String, dynamic>>();
    final files = <File>[];
    for (final item in manifest) {
      final input = File('$assets/${item['file']}');
      expect(
          sha256.convert(await input.readAsBytes()).toString(), item['sha256']);
      files.add(await input.copy('${root.path}/${item['file']}'));
    }
    longFile = files[0];
    largeFile = files[1];
  });
  tearDownAll(() async {
    await quota.refresh();
    await quota.drain();
    ImageDiskQuota.overrideForTesting = previousQuota;
    LogManager.recordingEnabled = previousLog;
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    expect(root.absolute.path.split(Platform.pathSeparator).last,
        startsWith('reader_real_safety_066_'));
    await root.delete(recursive: true);
  });

  test('066 safety assets pin a small long image and stream-valid large PNG',
      () {
    expect(manifest, hasLength(2));
    expect(manifest[0]['decoded_rgba_bytes'], 24 * 6000 * 4);
    expect(manifest[1]['decoded_rgba_bytes'], 8192 * 8192 * 4);
    expect(manifest[1]['inflated_scanline_bytes'], (8192 * 4 + 1) * 8192);
    expect(manifest[1]['encoded_bytes'], lessThan(1 << 20));
    expect(manifest[1]['inflated_scanline_sha256'],
        matches(RegExp(r'^[a-f0-9]{64}$')));
    // Full zlib+CRC/inflated-SHA validity is checked by generate_safety.py
    // --check in bounded chunks, never by expanding 256MiB in this process.
  });

  testWidgets(
      '066 real long whole pixels and compressed-large pre-frame guards',
      (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    ReaderPreviewImagePool? pool;
    ReaderPageSource? source;
    var serial = 0;

    LocalPathReadingData dataFor(File file) => LocalPathReadingData(
            title: '066 generated safety',
            id: 'safety-${serial++}',
            downloadId: 'none',
            sourceKey: 'local_album',
            directoryPath: '',
            hasEp: false,
            comicType: ComicType.other,
            episodeFiles: {
              0: [file.path]
            },
            downloadedEpisodeIndexes: const [
              0
            ]);

    Future<void> host(Widget child) => tester.pumpWidget(MaterialApp(
        home:
            Scaffold(body: Stack(children: [Positioned.fill(child: child)]))));

    Future<void> close() async {
      await tester.pumpWidget(const SizedBox());
      pool?.dispose();
      pool = null;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      final previous = source;
      source = null;
      var sourceDone = previous == null;
      final disposal = previous?.dispose().then((_) {
        sourceDone = true;
      });
      await tester.pump(const Duration(seconds: 6));
      await _until(
          tester,
          () =>
              sourceDone &&
              ReaderPageFileLease.activeLeaseCount == 0 &&
              ReaderWholeImageResidency.shared.bytes == 0 &&
              ReaderPreviewImagePool.globalReservedWorkingBytes == 0 &&
              ReaderPreviewImagePool.globalReservedDecodedBytes == 0 &&
              ReaderRasterCache.pendingBytes == 0 &&
              !ImageWorkScheduler.shared.hasWork &&
              ImageWorkScheduler.shared.reservedBytes == 0 &&
              ImageTemporaryPool.shared.reservedBytes == 0 &&
              quota.pendingOperations == 0 &&
              quota.activeBytes == 0,
          '066 safety closes actual frame/codec/source ownership before counting zero');
      await disposal;
      await tester.runAsync(() async {
        await quota.refresh();
        await quota.drain();
      });
      expect(ReaderSurfaceDiagnostics.activeSurfaces, 0);
      expect(ReaderSurfaceDiagnostics.residentBytes, 0);
      expect(tester.takeException(), isNull);
    }

    Future<void> preview(File file, {required bool rejects}) async {
      var decodeStarted = 0, framesStarted = 0;
      pool = ReaderPreviewImagePool(
          onDecodeStarted: () => decodeStarted++,
          onFrameDecodeStarted: () => framesStarted++);
      final data = dataFor(file);
      await host(reader.ReaderPreviewPageImage(
          resourceKey: data.id,
          pool: pool,
          loadProvider: (abort) =>
              data.createImageProvider(0, 0, file.path, abortSignal: abort)));
      if (rejects) {
        await _until(
            tester,
            () => find.textContaining('当前图片无法在安全预算').evaluate().isNotEmpty,
            'large real PNG must fail preview admission before requesting a codec frame');
        expect(decodeStarted, 0);
        expect(framesStarted, 0);
        expect(_frames(tester), isEmpty);
      } else {
        await _until(tester, () => _frames(tester).isNotEmpty,
            'long preview actual original frame');
        final image = _frames(tester).single.image!;
        expect((image.width, image.height), (24, 6000));
        expect(decodeStarted, 1);
        expect(framesStarted, greaterThanOrEqualTo(1));
        final pixels = await _drive(
            tester,
            () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
            'long preview pixels');
        expect(pixels, isNotNull);
        final bytes = pixels!.buffer
            .asUint8List(pixels.offsetInBytes, pixels.lengthInBytes);
        for (var y = 0; y < 6000; y++) {
          for (var x = 0; x < 24; x++) {
            final expected = x < 8
                ? const [240, 208, 32, 255]
                : (y < 2000
                    ? const [224, 32, 48, 255]
                    : (y < 4000
                        ? const [32, 192, 64, 255]
                        : const [32, 64, 224, 255]));
            final offset = (y * 24 + x) * 4;
            for (var c = 0; c < 4; c++) {
              if (bytes[offset + c] != expected[c]) {
                fail('original long preview differs at $x,$y channel$c');
              }
            }
          }
        }
      }
      expect(find.byType(ReaderImageSurface), findsNothing);
      await close();
    }

    Future<void> whole(File file, ReaderLargeImagePolicy policy,
        {required bool rejects, required bool large}) async {
      final data = dataFor(file);
      source = await _drive(
          tester,
          () => data.resolvePageSource(0, 0, file.path),
          'resolve authoritative safety source');
      expect(source!.isAuthoritativeOriginal, isTrue);
      final original = await _drive(tester, () => source!.openOriginalFile(),
          'open authoritative safety file');
      final metadata = await _drive(tester,
          () => _descriptorMetadata(original!), 'actual PNG descriptor');
      expect(metadata!.size,
          large ? const Size(8192, 8192) : const Size(24, 6000));
      final backend = _RealBackendObservation(metadata);
      Object? failure;
      await host(ReaderWholeImage(
          key: ValueKey('${file.path}:${policy.name}'),
          file: original!,
          resourceKey: data.id,
          metadata: metadata,
          backend: backend,
          policy: policy,
          onFailure: (error) => failure = error));
      if (rejects) {
        await _until(tester, () => failure != null,
            'whole admission must explicitly refuse before decode');
        if (policy == ReaderLargeImagePolicy.strictOriginal) {
          expect(
              failure,
              isA<ReaderWholeImageLimit>()
                  .having((e) => e.kind, 'kind', 'original-limit'));
          expect(backend.estimates, isEmpty,
              reason: 'strict texture guard runs before decoder estimate');
        } else {
          expect(failure, isA<ImageWorkBudgetExceeded>());
          expect(backend.estimates, isNotEmpty);
        }
        expect(backend.decodes, isEmpty,
            reason:
                'real backend.decode was never invoked, not just no visible image');
        expect(_frames(tester), isEmpty);
        expect(ReaderWholeImageResidency.shared.bytes, 0);
      } else {
        await _until(tester, () => _frames(tester).isNotEmpty,
            'safe long actual ui.Image frame');
        expect(failure, isNull);
        expect(backend.decodes, hasLength(1));
        final demand = backend.decodes.single;
        expect(demand.sourceRect, const Rect.fromLTWH(0, 0, 24, 6000));
        expect(demand.rasterRect, demand.sourceRect);
        expect((demand.column, demand.row), (-1, -1));
        expect(demand.density, lessThan(1));
        final image = _frames(tester).single.image!;
        expect((image.width, image.height),
            (demand.outputWidth, demand.outputHeight));
        expect(image.width, lessThanOrEqualTo(4096));
        expect(image.height, 4096);
        final box = tester.renderObject<RenderBox>(find.byType(RawImage));
        expect(
            box.size.width / box.size.height, closeTo(24 / 6000, 0.000000001));
        final pixels = await _drive(
            tester,
            () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
            'safe long actual frame pixels');
        final bytes = pixels!.buffer
            .asUint8List(pixels.offsetInBytes, pixels.lengthInBytes);
        // Fixed solid interiors avoid resampling-kernel differences at band
        // boundaries. Top/middle/bottom AND both sides prove full-page output.
        final xs = [1, image.width - 2];
        final ys = [
          image.height ~/ 10,
          image.height ~/ 2,
          image.height * 9 ~/ 10
        ];
        const bands = [
          [224, 32, 48, 255],
          [32, 192, 64, 255],
          [32, 64, 224, 255]
        ];
        for (var row = 0; row < ys.length; row++) {
          for (final x in xs) {
            final expected = x == 1 ? const [240, 208, 32, 255] : bands[row];
            final offset = (ys[row] * image.width + x) * 4;
            expect(bytes.sublist(offset, offset + 4), expected,
                reason:
                    'safe long whole source, x=$x band=$row; exact interior colors');
          }
        }
        expect(find.byTooltip('已按安全上限整图显示，原文件未修改'), findsOneWidget);
      }
      for (final demand in backend.estimates) {
        expect(demand.sourceRect, Offset.zero & metadata.size);
        expect(demand.rasterRect, demand.sourceRect);
        expect((demand.column, demand.row), (-1, -1));
      }
      expect(find.byType(ReaderImageSurface), findsNothing);
      await close();
    }

    try {
      await preview(longFile, rejects: false);
      await whole(longFile, ReaderLargeImagePolicy.safeWhole,
          rejects: false, large: false);
      await whole(longFile, ReaderLargeImagePolicy.strictOriginal,
          rejects: true, large: false);
      await preview(largeFile, rejects: true);
      await whole(largeFile, ReaderLargeImagePolicy.safeWhole,
          rejects: true, large: true);
      await whole(largeFile, ReaderLargeImagePolicy.strictOriginal,
          rejects: true, large: true);
      await tester.runAsync(() async {
        for (final item in manifest) {
          expect(
              sha256
                  .convert(
                      await File('${root.path}/${item['file']}').readAsBytes())
                  .toString(),
              item['sha256']);
          expect(
              sha256
                  .convert(
                      await File('test/fixtures/reader_066/${item['file']}')
                          .readAsBytes())
                  .toString(),
              item['sha256']);
        }
      });
    } finally {
      await close();
    }
  });
}
