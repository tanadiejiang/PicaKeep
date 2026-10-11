// 066 / R3 / F4: actual LocalPathReadingData -> production buildComicView ->
// preview FileImage/provider OR sharp ReaderWholeImage -> real ui.Image bytes.
// No raster/backend/provider resolver substitute, no external/user fixtures.
// The independent Pillow reference and predeclared tolerances are committed in
// fixtures/reader_066; this test NEVER generates its oracle with Flutter.
//
// Cross-product mapping: all 11 fixtures use layout=1; JPEG EXIF 6, PNG alpha,
// lossless WebP alpha and lossy WebP ALSO use production layout=5 (double) and
// layout=4 (continuous). Each cell runs both modes, both sharp policies, warm
// rebuild/reopen, PhotoView scale/rotation (including the outer continuous owner),
// and viewport rotation. The established generic
// reader_production_whole_routes_test / reader_full_workflow_022_test cover the
// wider per-source/layout/selection/export UI matrix; no claim that eight EXIF
// orientations times every layout or platform memory/GPU have been measured.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:picakeep/pages/reader/reader_page_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/reader_preview_provider.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_cache.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart' as reader;
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep/pages/reader/reader_whole_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

import 'support/image_disk_quota_fixture.dart';

const _assetRoot = 'test/fixtures/reader_066';
const _extraLayoutFixtures = {
  'jpeg_exif_6',
  'png_alpha',
  'webp_lossless_alpha',
  'webp_lossy',
};

class _Fixture {
  _Fixture(this.info, this.encoded, this.reference);
  final Map<String, dynamic> info;
  final Uint8List encoded, reference;
  String get id => info['id'] as String;
  String get filename => info['file'] as String;
  String get format => info['format'] as String;
  String get digest => info['sha256'] as String;
  int get width => (info['normalized_size'] as List)[0] as int;
  int get height => (info['normalized_size'] as List)[1] as int;
  bool get lossless => format == 'png' || format == 'webp_lossless';
  int get maximumError => lossless ? 0 : (format == 'jpeg' ? 3 : 2);
  double get meanError => lossless ? 0 : (format == 'jpeg' ? 0.75 : 0.25);
}

// Count entry points only. Source identity, original IO, provider and backend
// remain the unmodified production implementations.
class _FormatData extends LocalPathReadingData {
  _FormatData(String id, List<String> paths)
      : super(
          title: '066 synthetic local format',
          id: id,
          downloadId: id,
          sourceKey: 'local_album',
          directoryPath: '',
          hasEp: false,
          comicType: ComicType.other,
          episodeFiles: {0: paths},
          downloadedEpisodeIndexes: const [0],
        );
  int providers = 0, resolutions = 0;
  final providersByPage = <int, int>{};

  @override
  ImageProvider createImageProvider(int ep, int page, String url,
      {StreamImageAbortSignal? abortSignal}) {
    providers++;
    providersByPage.update(page, (count) => count + 1, ifAbsent: () => 1);
    return super.createImageProvider(ep, page, url, abortSignal: abortSignal);
  }

  @override
  Future<ReaderPageSource> resolvePageSource(int ep, int page, String url) {
    resolutions++;
    return super.resolvePageSource(ep, page, url);
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
    WidgetTester tester, bool Function() ready, String reason) async {
  for (var i = 0; i < 300 && !ready(); i++) {
    await _flush(tester);
  }
  expect(ready(), isTrue, reason: reason);
}

// Real IO/native frame futures can meet a FakeAsync-zone post-frame future.
// Start them in the widget lifecycle, then drive BOTH clocks, not runAsync-only
// or pumpAndSettle-only. See the production routes/full workflow/JM fixtures.
Future<T?> _drive<T>(
    WidgetTester tester, Future<T> Function() operation, String phase) async {
  var done = false;
  T? result;
  Object? error;
  StackTrace? stack;
  unawaited(operation().then<void>((value) {
    result = value;
    done = true;
  }, onError: (Object failure, StackTrace trace) {
    error = failure;
    stack = trace;
    done = true;
  }));
  await _until(tester, () => done, '$phase must finish actual IO/frame work');
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return result;
}

void _mode(ReaderDisplayMode mode, ReaderLargeImagePolicy policy) {
  appdata.settings[readerImagePipelineSettingIndex] =
      ReaderImagePipelineSettings(
              comic: mode, illust: mode, largeImagePolicy: policy)
          .encode();
}

Finder _renderer(ReaderDisplayMode mode) =>
    mode == ReaderDisplayMode.previewFirst
        ? find.byType(reader.ReaderPreviewPageImage)
        : find.byType(ReaderWholeImage);

List<Element> _visibleRaws(WidgetTester tester, ReaderDisplayMode mode) {
  final viewport =
      Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);
  final candidates = find.descendant(
      of: _renderer(mode),
      matching: find.byWidgetPredicate(
          (widget) => widget is RawImage && widget.image != null));
  return candidates.evaluate().where((element) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    final bounds = MatrixUtils.transformRect(
        box.getTransformTo(null), Offset.zero & box.size);
    return bounds.overlaps(viewport) && !bounds.isEmpty;
  }).toList();
}

void _comparePixels(_Fixture fixture, Uint8List actual, String phase) {
  final expected = fixture.reference;
  expect(actual.length, expected.length, reason: '$phase full RGBA extent');
  var sum = 0, maximum = 0, alphaMismatch = 0, exactMismatch = 0;
  var firstMismatch = '';
  for (var i = 0; i < expected.length; i += 4) {
    final alpha = expected[i + 3];
    if (actual[i + 3] != alpha) alphaMismatch++;
    for (var channel = 0; channel < 3; channel++) {
      final delta = (actual[i + channel] - expected[i + channel]).abs();
      sum += delta;
      if (delta > maximum) maximum = delta;
      final limit = fixture.lossless
          ? (alpha > 0 && alpha < 255 ? 1 : 0)
          : fixture.maximumError;
      if (delta > limit) {
        exactMismatch++;
        if (firstMismatch.isEmpty) {
          final pixel = i ~/ 4;
          firstMismatch = 'x=${pixel % fixture.width}, '
              'y=${pixel ~/ fixture.width}, channel=$channel: '
              '${actual[i + channel]} != ${expected[i + channel]}';
        }
      }
    }
  }
  expect(alphaMismatch, 0, reason: '$phase alpha is exact (not +/- RGB error)');
  expect(exactMismatch, 0,
      reason: '$phase fixed max error; $firstMismatch; measured max=$maximum');
  if (!fixture.lossless) {
    expect(sum / (fixture.width * fixture.height * 3),
        lessThanOrEqualTo(fixture.meanError),
        reason:
            '$phase fixed mean error, relative to encoded Pillow reference');
  }
  for (final rawSample in fixture.info['samples'] as List) {
    final sample = rawSample as Map<String, dynamic>;
    final xy = sample['normalized_xy'] as List;
    final offset = ((xy[1] as int) * fixture.width + (xy[0] as int)) * 4;
    final reference = (sample['premultiplied_rgba'] as List).cast<int>();
    expect(expected.sublist(offset, offset + 4), reference,
        reason: '$phase independent EXIF marker ${sample['name']}');
    for (var channel = 0; channel < 4; channel++) {
      final alpha = reference[3];
      final limit = channel == 3
          ? 0
          : (fixture.lossless
              ? (alpha > 0 && alpha < 255 ? 1 : 0)
              : fixture.maximumError);
      expect((actual[offset + channel] - reference[channel]).abs(),
          lessThanOrEqualTo(limit),
          reason:
              '$phase ${sample['name']} normalized position=$xy ch=$channel');
    }
  }
}

Future<int> _expectFrame(WidgetTester tester, _Fixture fixture,
    ReaderDisplayMode mode, ReaderLargeImagePolicy policy, String phase,
    {bool transformed = false}) async {
  await _until(tester, () => _visibleRaws(tester, mode).isNotEmpty,
      '$phase needs a painted current-route ui.Image, not an old/loading widget');
  final images = _visibleRaws(tester, mode);
  for (final element in images) {
    final image = (element.widget as RawImage).image!;
    expect((image.width, image.height), (fixture.width, fixture.height),
        reason: '$phase original/EXIF-normalized extent must not downsample');
    expect(image.width / image.height, fixture.width / fixture.height,
        reason: '$phase original aspect ratio');
    if (!transformed) {
      final raw = element.widget as RawImage;
      final box = element.renderObject! as RenderBox;
      expect(box.hasSize && !box.size.isEmpty, isTrue);
      // Double-page preview intentionally fills the available Image box and
      // letterboxes via fit; test its painted destination, not that outer box.
      // These are the exact RawImage fit/scale arguments passed to RenderImage.
      final inputSize = Size(image.width / raw.scale, image.height / raw.scale);
      final fitted =
          applyBoxFit(raw.fit ?? BoxFit.scaleDown, inputSize, box.size);
      expect(fitted.source, inputSize,
          reason: '$phase painting must include the complete source image');
      expect(fitted.destination.width / fitted.destination.height,
          closeTo(fixture.width / fixture.height, 0.000001),
          reason: '$phase actual fit destination preserves normalized ratio');
    }
    final clone = image.clone();
    try {
      final data = await _drive(tester,
          () => clone.toByteData(format: ui.ImageByteFormat.rawRgba), phase);
      expect(data, isNotNull);
      _comparePixels(
          fixture,
          data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          phase);
    } finally {
      clone.dispose();
    }
  }
  expect(find.byType(ReaderImageSurface), findsNothing,
      reason: '$phase has no tile/ROI surface');
  expect(ReaderSurfaceDiagnostics.activeSurfaces, 0);
  expect(ReaderSurfaceDiagnostics.residentBytes, 0);
  if (mode == ReaderDisplayMode.previewFirst) {
    expect(find.byType(ReaderWholeImage), findsNothing);
    expect(find.byType(ReaderPageImage), findsNothing);
    for (final widget in tester.widgetList<PhotoView>(find.byType(PhotoView))) {
      expect(widget.imageProvider, isNot(isA<ResizeImage>()));
    }
  } else {
    expect(find.byType(reader.ReaderPreviewPageImage), findsNothing);
    final wholes =
        tester.widgetList<ReaderWholeImage>(find.byType(ReaderWholeImage));
    expect(wholes, isNotEmpty);
    for (final whole in wholes) {
      expect(whole.policy, policy, reason: '$phase actual production policy');
      expect(whole.backend, isA<FlutterReaderRasterBackend>(),
          reason: '$phase uses real bounded small-image backend, not a fake');
      expect(whole.metadata.size,
          Size(fixture.width.toDouble(), fixture.height.toDouble()));
      final plan = ReaderWholeImagePlan.create(
          sourceSize: whole.metadata.size,
          policy: whole.policy,
          textureEdge: whole.textureEdge);
      expect(plan.demand.sourceRect, Offset.zero & whole.metadata.size);
      expect(plan.demand.rasterRect, plan.demand.sourceRect);
      expect((plan.demand.column, plan.demand.row), (-1, -1));
      expect(plan.demand.density, 1);
      expect(plan.downsampled, isFalse);
    }
  }
  expect(tester.takeException(), isNull, reason: phase);
  return images.length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousSettings = List<String>.of(appdata.settings);
  final previousImplicit = List<String>.of(appdata.implicitData);
  final previousLog = LogManager.recordingEnabled;
  final previousQuota = ImageDiskQuota.overrideForTesting;
  late Directory root;
  late ImageDiskQuota quota;
  late List<_Fixture> fixtures;

  setUpAll(() async {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows,
          () => DynamicLibrary.open(
              '${Directory.current.path}/windows/sqlite3.dll'));
    }
    root = await Directory.systemTemp.createTemp('reader_real_formats_066_');
    App.dataPath = '${root.path}/data';
    App.cachePath = '${root.path}/cache';
    await Directory(App.dataPath).create();
    await Directory(App.cachePath).create();
    quota =
        installTaskDiskQuota(() => [App.cachePath, '${App.dataPath}/cache']);
    LogManager.recordingEnabled = false;
    SharedPreferences.setMockInitialValues({});
    final manifest =
        jsonDecode(await File('$_assetRoot/manifest.json').readAsString())
            as Map<String, dynamic>;
    expect(manifest['schema'], 1);
    expect((manifest['reference_decoder'] as Map)['Pillow'], '12.3.0');
    fixtures = [];
    for (final entry in manifest['fixtures'] as List) {
      final info = entry as Map<String, dynamic>;
      fixtures.add(_Fixture(
          info,
          await File('$_assetRoot/${info['file']}').readAsBytes(),
          await File('$_assetRoot/${info['reference']}').readAsBytes()));
    }
  });

  tearDownAll(() async {
    await quota.refresh();
    await quota.drain();
    ImageDiskQuota.overrideForTesting = previousQuota;
    appdata.settings = previousSettings;
    appdata.implicitData = previousImplicit;
    LogManager.recordingEnabled = previousLog;
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    expect(root.absolute.path.split(Platform.pathSeparator).last,
        startsWith('reader_real_formats_066_'));
    await root.delete(recursive: true);
  });

  test('066 references are complete, independently fixed and byte-pinned', () {
    expect(fixtures, hasLength(11));
    expect(fixtures.map((f) => f.id).toSet(), {
      for (var orientation = 1; orientation <= 8; orientation++)
        'jpeg_exif_$orientation',
      'png_alpha',
      'webp_lossless_alpha',
      'webp_lossy',
    });
    for (final fixture in fixtures) {
      expect(sha256.convert(fixture.encoded).toString(), fixture.digest);
      expect(sha256.convert(fixture.reference).toString(),
          fixture.info['reference_sha256']);
      expect(fixture.reference.length, fixture.width * fixture.height * 4);
      expect(fixture.info['encoded_size'], [96, 64]);
      final orientation = fixture.info['orientation'] as int;
      expect((fixture.width, fixture.height),
          orientation >= 5 ? (64, 96) : (96, 64));
      final tolerance = fixture.info['tolerance'] as Map;
      expect(tolerance['max_rgb_error'], fixture.maximumError);
      expect(tolerance['mean_rgb_error'], fixture.meanError);
      if (fixture.lossless) {
        expect(tolerance['translucent_premultiply_max_error'], 1);
        expect(fixture.info['samples'], hasLength(9));
      } else {
        expect(fixture.info['samples'], hasLength(6));
      }
      // Encoding magic is an additional guard, NOT frame quality evidence.
      if (fixture.format == 'jpeg') {
        expect(fixture.encoded.take(2), [0xff, 0xd8]);
      } else if (fixture.format == 'png') {
        expect(fixture.encoded.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      } else {
        expect(ascii.decode(fixture.encoded.sublist(0, 4)), 'RIFF');
        expect(ascii.decode(fixture.encoded.sublist(8, 12)), 'WEBP');
      }
    }
  });

  // One live widget clock deliberately owns every iteration, including static
  // work/quota tails. Splitting this into independent FakeAsync cases would
  // strand callbacks on closed clocks (the existing JM fixture documents it).
  testWidgets(
      '066 real JPEG EXIF1-8 PNG alpha WebP cold warm and hot whole routes',
      (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appdata.settings[28] = '0'; // Isolate visible format, not speculative IO.
    appdata.settings[43] = '0';
    appdata.settings[49] = '0';
    appdata.settings[50] = 'zh';
    appdata.implicitData[1] = '0';
    reader.ComicReadingPageLogic? mounted;
    final operationSources = <ReaderPageSource>[];
    var presentedFrames = 0, completedCells = 0;

    Future<void> unmount() async {
      final logic = mounted;
      mounted = null;
      await tester.pumpWidget(const SizedBox());
      await _flush(tester, 3);
      if (logic != null) {
        logic.clearPhotoViewControllers();
        logic.pageController.dispose();
        logic.scrollController.dispose();
        logic.focusNode.dispose();
        logic.viewportChanges.dispose();
        logic.dispose();
      }
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      // Start all disposals before waiting: they can share the displayed file.
      var originalsDisposed = false;
      final sources = List<ReaderPageSource>.of(operationSources);
      operationSources.clear();
      final disposals =
          Future.wait(sources.map((source) => source.dispose())).then((_) {
        originalsDisposed = true;
      });
      await tester.pump(const Duration(seconds: 6));
      await _until(
          tester,
          () =>
              originalsDisposed &&
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
          '066 exit must release real frames/codecs/writers/file leases/budgets');
      await disposals;
      await tester.runAsync(() async {
        await quota.refresh();
        await quota.drain();
      });
      expect(ReaderSurfaceDiagnostics.activeSurfaces, 0);
      expect(ReaderSurfaceDiagnostics.residentBytes, 0);
      expect(tester.takeException(), isNull);
    }

    Future<reader.ComicReadingPageLogic> mount(
        _FormatData data, List<String> paths, int layout) async {
      _mode(ReaderDisplayMode.previewFirst, ReaderLargeImagePolicy.safeWhole);
      appdata.settings[9] = '$layout';
      final page = reader.ComicReadingPage(data, 1, 1);
      // local_album constructor selects single; model the user's later choice.
      appdata.settings[9] = '$layout';
      final logic = StateController.find<reader.ComicReadingPageLogic>();
      mounted = logic;
      logic.urls = paths;
      logic.isLoading = false;
      logic.scrollManager = reader.ScrollManager(logic);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Stack(children: [
        Builder(
            builder: (context) => StateBuilder<reader.ComicReadingPageLogic>(
                builder: (logic) =>
                    page.buildComicView(logic, context, '066-format'))),
      ]))));
      return logic;
    }

    try {
      for (final fixture in fixtures) {
        final layouts = [
          1,
          if (_extraLayoutFixtures.contains(fixture.id)) ...[5, 4]
        ];
        for (final layout in layouts) {
          final cell = '${fixture.id}/layout=$layout';
          final file =
              File('${root.path}/${fixture.id}-$layout-${fixture.filename}');
          await tester.runAsync(() => file.writeAsBytes(fixture.encoded));
          final paths = List<String>.filled(layout == 1 ? 1 : 4, file.path);
          final data = _FormatData('066-${fixture.id}-$layout', paths);
          for (final warm in [false, true]) {
            ReaderRasterDiagnostics.drainSamples();
            final label = '$cell/${warm ? 'warm-reopen' : 'cold'}';
            final beforeResolution = data.resolutions;
            final entryProviderBaseline =
                Map<int, int>.of(data.providersByPage);
            final logic = await mount(data, paths, layout);
            presentedFrames += await _expectFrame(
                tester,
                fixture,
                ReaderDisplayMode.previewFirst,
                ReaderLargeImagePolicy.safeWhole,
                '$label/preview');
            expect(data.providers, greaterThan(0));
            expect(data.resolutions, beforeResolution,
                reason: 'preview must not pre-resolve sharp metadata');
            expect(ReaderRasterDiagnostics.drainSamples(), isEmpty);
            final providerPages = Map<int, int>.of(data.providersByPage);
            logic.update();
            await _flush(tester, 3);
            presentedFrames += await _expectFrame(
                tester,
                fixture,
                ReaderDisplayMode.previewFirst,
                ReaderLargeImagePolicy.safeWhole,
                '$label/preview-resident-warm');
            debugPrintSynchronously(
                '$label FACTORY entry=$entryProviderBaseline '
                'resident=$providerPages after=${data.providersByPage}');
            for (final entry in data.providersByPage.entries) {
              final baseline = entryProviderBaseline[entry.key] ?? 0;
              final resident = providerPages[entry.key] ?? baseline;
              if (resident > baseline) {
                expect(resident - baseline, 1,
                    reason: 'each page has one initial factory in this entry');
                expect(entry.value, resident,
                    reason:
                        'already acquired page ${entry.key} keeps its exact provider lease on warm rebuild');
              } else {
                expect(entry.value - baseline, inInclusiveRange(0, 1),
                    reason:
                        'newly laid-out page ${entry.key} may acquire only its first provider in this entry');
              }
            }
            final providerCalls = data.providers;
            final order = logic.order, pageIndex = logic.index;
            for (final policy in ReaderLargeImagePolicy.values) {
              ReaderRasterDiagnostics.drainSamples();
              _mode(ReaderDisplayMode.sharpFirst, policy);
              logic.update();
              await _flush(tester);
              presentedFrames += await _expectFrame(
                  tester,
                  fixture,
                  ReaderDisplayMode.sharpFirst,
                  policy,
                  '$label/sharp-${policy.name}');
              expect(data.resolutions, greaterThan(beforeResolution));
              expect(data.providers, providerCalls,
                  reason: 'sharp must not call the preview provider factory');
              expect(logic.order, order);
              expect(logic.index, pageIndex,
                  reason:
                      'same-session mode/policy changes retain page anchor');
              final samples = ReaderRasterDiagnostics.drainSamples();
              expect(
                  samples.any((sample) =>
                      sample.containsKey('flutterCodecWallUs') ||
                      sample['diskRasterHit'] == 1),
                  isTrue,
                  reason:
                      'real whole codec or verified warm disk raster must run');
              // Native-unavailable compatibility conservatively marks unknown
              // profiles, so persistent raster caching is intentionally disabled.
              // Reopen is real warm source IO, NOT a fabricated cache-hit claim.
            }
            logic.photoViewController.updateMultiple(
                scale: 2, rotation: 0.15, position: const Offset(10, 15));
            await _flush(tester, 3);
            presentedFrames += await _expectFrame(
                tester,
                fixture,
                ReaderDisplayMode.sharpFirst,
                ReaderLargeImagePolicy.strictOriginal,
                '$label/sharp-transform',
                transformed: true);
            tester.view.physicalSize = const Size(600, 400);
            await _flush(tester, 3);
            presentedFrames += await _expectFrame(
                tester,
                fixture,
                ReaderDisplayMode.sharpFirst,
                ReaderLargeImagePolicy.strictOriginal,
                '$label/viewport-rotate',
                transformed: true);
            expect(logic.order, order);
            expect(logic.index, pageIndex);
            logic.photoViewController
                .updateMultiple(scale: 1, rotation: 0, position: Offset.zero);
            tester.view.physicalSize = const Size(400, 600);
            _mode(ReaderDisplayMode.previewFirst,
                ReaderLargeImagePolicy.strictOriginal);
            logic.update();
            await _flush(tester, 3);
            presentedFrames += await _expectFrame(
                tester,
                fixture,
                ReaderDisplayMode.previewFirst,
                ReaderLargeImagePolicy.strictOriginal,
                '$label/back-to-preview');
            expect(logic.order, order);
            expect(logic.index, pageIndex);

            // Same production source channel consumed by save/share. Copy the
            // authoritative encoded stream, never this test's display raster.
            final source = await _drive(
                tester,
                () => data.resolvePageSource(0, 0, file.path),
                '$label/original-source');
            operationSources.add(source!);
            expect(source.isAuthoritativeOriginal, isTrue);
            expect(source.isPreviewOnly, isFalse);
            final output =
                File('${root.path}/export-${fixture.id}-$layout-$warm.bin');
            await _drive(
                tester,
                () => source.openOriginal().pipe(output.openWrite()),
                '$label/authoritative-export');
            await tester.runAsync(() async {
              expect(sha256.convert(await output.readAsBytes()).toString(),
                  fixture.digest);
              expect(sha256.convert(await file.readAsBytes()).toString(),
                  fixture.digest);
              expect(
                  sha256
                      .convert(await File('$_assetRoot/${fixture.filename}')
                          .readAsBytes())
                      .toString(),
                  fixture.digest,
                  reason: 'committed original must remain unchanged');
            });
            await unmount();
          }
          completedCells++;
          debugPrintSynchronously('066 real format passed $cell cold+warm; '
              'preview -> sharp safe -> sharp strict -> preview; original SHA stable; exit=0');
        }
      }
      expect(completedCells, 19);
      expect(presentedFrames, greaterThanOrEqualTo(19 * 2 * 7));
      debugPrintSynchronously('066 matrix complete: $completedCells cells, '
          '$presentedFrames actual frame pixel comparisons; no device/RSS/GPU claim');
    } finally {
      await unmount();
    }
  });
}
