// Opt-in debug/profile evidence for the real tile painter at original density.
// This reads only the named synthetic fixtures and writes task-owned artifacts.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/native_disk_work.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_cache.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart' as native;

import 'image_pipeline_022_exact_readback.dart';

/// Returns exact differences; no tolerance or automatic quality acceptance.
/// The reference is one broad original-file ROI, never a tile mosaic. Both
/// candidates use the same Flutter Canvas/black background so this isolates
/// original-density stitching/rendering. Codec/color fidelity is a separate
/// check; native sRGB8 alone does not prove wide-gamut/HDR preservation.
Future<Map<String, Object?>> runImagePipeline022SurfaceQualityChecks(
    BuildContext context, String fixtureRoot,
    {bool verifyPersistence = false,
    bool preferRawSync = false,
    bool preferPreparedRead = false}) async {
  final cases = <Map<String, Object?>>[];
  final errors = <Map<String, Object?>>[];
  final report = <String, Object?>{
    'schema': 1,
    'measurement':
        'actual ReaderImageSurface CustomPaint -> engine RepaintBoundary readback; OS display scanout is not measured',
    'reference':
        'one independent native original-file region decode -> single Flutter Canvas image on opaque black; reusable original backing may be shared',
    'candidate': 'real native ReaderImageSurface; sharpFirst; tilePixels=512',
    'persistenceEnabled': verifyPersistence,
    'rawSyncCandidate': preferRawSync,
    'preparedBackingReadCandidate': preferPreparedRead,
    'thresholdApplied': false,
    'nativeDensityRequired': 1,
    'maximumCapturePixels': [1024, 1024],
    'fullOriginalFlutterBitmapCreated': false,
    'colorScope': 'sRGB8/premultiplied alpha on black; not wide-gamut/HDR',
    'cases': cases,
    'errors': errors,
    'nativeAvailable': native.PicakeepImageEngine.isAvailable,
  };
  if (!native.PicakeepImageEngine.isAvailable) {
    errors.add({'stage': 'availability', 'error': 'Native engine unavailable'});
    return report;
  }
  if (!context.mounted) {
    throw StateError('Surface quality context is unmounted');
  }
  final navigator = Navigator.of(context, rootNavigator: true);
  final dpr = View.of(context).devicePixelRatio;
  final physicalSize = View.of(context).physicalSize;
  if (dpr <= 0 || physicalSize.shortestSide < 512) {
    errors
        .add({'stage': 'viewport', 'error': '512 physical pixels unavailable'});
    return report;
  }
  final availableEdge = physicalSize.shortestSide >= 1024 ? 1024 : 512;
  final root = Directory(p.join(App.cachePath, 'surface-quality-022'));
  await root.create(recursive: true);
  final workspace = await root.createTemp('run-');
  report.addAll({
    'devicePixelRatio': dpr,
    'viewPhysicalPixels': [physicalSize.width, physicalSize.height],
    'availableCaptureEdge': availableEdge,
    'artifactRoot': workspace.path,
  });
  const fixtures = <(String, int)>[
    ('640x960.png', 512),
    ('640x960-alpha.png', 512),
    ('3000x4000-alpha.png', 512),
    ('640x960-chroma-420.jpg', 512),
    ('640x960-progressive.jpg', 512),
    ('640x960-orientation-1.jpg', 512),
    ('640x960-orientation-2.jpg', 512),
    ('640x960-orientation-3.jpg', 512),
    ('640x960-orientation-4.jpg', 512),
    ('640x960-orientation-5.jpg', 512),
    ('640x960-orientation-6.jpg', 512),
    ('640x960-orientation-7.jpg', 512),
    ('640x960-orientation-8.jpg', 512),
    ('8000x12000.png', 1024),
    ('8000x12000-baseline.jpg', 1024),
    ('8000x12000-progressive.jpg', 1024),
    ('8000x12000-lossless.webp', 1024),
    ('8000x12000-lossy.webp', 1024),
    ('8000x12000-interlaced.png', 1024),
    ('800x30000.png', 1024),
    ('800x30000-baseline.jpg', 1024),
    ('800x30000-progressive.jpg', 1024),
  ];
  const engine = native.PicakeepImageEngine();
  for (final fixture in fixtures) {
    final name = fixture.$1;
    final file = File(p.join(fixtureRoot, name));
    FileReaderPageSource? source;
    Directory? working;
    VoidCallback? releaseOwnedBacking;
    var drained = false;
    try {
      final before = await file.stat();
      if (before.type != FileSystemEntityType.file || before.size <= 0) {
        throw StateError('Synthetic fixture is missing');
      }
      final beforeSha = (await sha256.bind(file.openRead()).first).toString();
      final meta = await engine.probe(file.path);
      final metadata = ReaderRasterMetadata(
          size: Size(meta.width.toDouble(), meta.height.toDouble()),
          animated: meta.animated,
          format: meta.format,
          workingBytes: meta.estimatedWorkingBytes,
          bitDepth: meta.bitDepth,
          hasColorProfile: meta.hasColorProfile);
      if (meta.animated) throw StateError('Static quality fixture is animated');
      working = await workspace.createTemp('backing-');
      final backing = p.join(working.path, 'original.rgba');
      releaseOwnedBacking = DerivedImageStore.protectTemporaryPath(backing);
      source = FileReaderPageSource(
          identity: ReaderPageIdentity(
              sourceKey: '022-synthetic-surface',
              workId: name,
              downloadId: 'surface-quality',
              episode: 0,
              page: 0,
              sourceVersion:
                  '${before.size}:${before.modified.microsecondsSinceEpoch}'),
          file: file,
          byteLength: before.size,
          modifiedMillis: before.modified.millisecondsSinceEpoch,
          width: meta.width,
          height: meta.height);
      final edge = math.min(fixture.$2, availableEdge);
      final width = math.min(edge, meta.width);
      final height = math.min(edge, meta.height);
      final regions = <(String, Rect)>[
        (
          'center-cross-tile',
          Rect.fromLTWH(
              ((meta.width - width) / 2).floorToDouble(),
              ((meta.height - height) / 2).floorToDouble(),
              width.toDouble(),
              height.toDouble())
        ),
        (
          'bottom-right-partial-tile',
          Rect.fromLTWH(
              (meta.width - width).toDouble(),
              (meta.height - height).toDouble(),
              width.toDouble(),
              height.toDouble())
        ),
      ];
      if (verifyPersistence) {
        regions.add(('center-disk-cache-repeat', regions.first.$2));
      }
      for (final region in regions) {
        final entry = <String, Object?>{
          'fixture': name,
          'case': region.$1,
          'originalSize': [meta.width, meta.height],
          'encodedSize': [meta.encodedWidth, meta.encodedHeight],
          'orientation': meta.orientation,
          'format': meta.format,
          'bitDepth': meta.bitDepth,
          'hasColorProfile': meta.hasColorProfile,
          'sourceSha256': beforeSha,
          'sourceBytes': before.size,
          'captureEdgeRequested': fixture.$2,
          'sourceRect': _rect(region.$2),
        };
        cases.add(entry);
        ui.Image? captured;
        ui.Image? reference;
        try {
          if (region.$1 == 'center-disk-cache-repeat') {
            await ReaderRasterCache.drain();
          }
          final backend = _ObservedNativeBackend(backing,
              persistRaster: verifyPersistence,
              preferRawSync: preferRawSync,
              preferPreparedRead: preferPreparedRead);
          ReaderRasterDiagnostics.drainSamples();
          final capture = await _captureSurface(
              navigator, source, metadata, backend, region.$2, dpr);
          captured = capture.image;
          entry.addAll({
            'presentedSourceRect': _rect(capture.frame.sourceRect),
            'presentedDensity': capture.frame.density,
            'complete': capture.frame.complete,
            'nativePixels': capture.frame.nativePixels,
            'frameBuildTimelineUs': capture.frame.frameBuildTimelineUs,
            'matchedRasterFinishUs': capture.rasterFinishUs,
            'capturePixels': [captured.width, captured.height],
            'actualRasterImages': backend.images,
            'surfaceSnapshot': capture.snapshot,
            'rasterStages': ReaderRasterDiagnostics.drainSamples(),
          });
          reference = await _reference(file, region.$2, backing);
          entry['referencePixels'] = [reference.width, reference.height];
          if (captured.width != width ||
              captured.height != height ||
              reference.width != width ||
              reference.height != height) {
            throw StateError(
                'Capture/reference did not preserve original pixels');
          }
          final candidateBytes = await _readback(captured);
          final referenceBytes = await _readback(reference);
          final diff = _compare(
              candidateBytes, referenceBytes, width, height, region.$2);
          entry.addAll(diff);
          if (diff['differentPixels'] != 0) {
            final artifactName = '${p.basenameWithoutExtension(name)}-'
                '${p.extension(name).substring(1)}-${region.$1}';
            entry['artifacts'] = await _saveDifference(workspace, artifactName,
                captured, reference, candidateBytes, referenceBytes);
          }
        } catch (error, stack) {
          entry['error'] = '$error';
          entry['stack'] = '$stack';
          entry['surfaceSnapshotAtError'] = ReaderSurfaceDiagnostics.snapshot();
          errors.add({'fixture': name, 'case': region.$1, 'error': '$error'});
          final artifacts = <String, String>{};
          for (final item in [('actual', captured), ('reference', reference)]) {
            if (item.$2 == null) continue;
            try {
              final png =
                  await item.$2!.toByteData(format: ui.ImageByteFormat.png);
              if (png == null) continue;
              final output = File(p.join(
                  workspace.path,
                  '${p.basenameWithoutExtension(name)}-${p.extension(name).substring(1)}-'
                  '${region.$1}-error-${item.$1}.png'));
              await output.writeAsBytes(
                  png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
              artifacts[item.$1] = output.path;
            } catch (saveError) {
              entry['artifactError'] = '$saveError';
            }
          }
          if (artifacts.isNotEmpty) entry['artifacts'] = artifacts;
        } finally {
          captured?.dispose();
          reference?.dispose();
        }
      }
      final after = await file.stat();
      final afterSha = (await sha256.bind(file.openRead()).first).toString();
      if (before.size != after.size ||
          before.modified != after.modified ||
          beforeSha != afterSha) {
        throw StateError('Synthetic original changed during surface checks');
      }
      for (final entry in cases.where((entry) => entry['fixture'] == name)) {
        entry['sourceUnchanged'] = true;
        entry['sourceAfterSha256'] = afterSha;
      }
    } catch (error, stack) {
      errors.add({
        'fixture': name,
        'stage': 'fixture',
        'error': '$error',
        'stack': '$stack'
      });
    } finally {
      try {
        await source?.dispose().timeout(const Duration(seconds: 30));
        drained = true;
      } catch (error) {
        errors
            .add({'fixture': name, 'stage': 'sourceDrain', 'error': '$error'});
      }
      // Delete only this helper's resolved child directory, after actual
      // source consumers drain. Never delete original input or active backing.
      if (working != null &&
          drained &&
          p.isWithin(p.absolute(workspace.path), p.absolute(working.path))) {
        try {
          await working.delete(recursive: true);
        } catch (error) {
          errors.add(
              {'fixture': name, 'stage': 'backingCleanup', 'error': '$error'});
        }
      }
      if (drained || source == null) {
        releaseOwnedBacking?.call();
      } else {
        // A timed-out actual consumer still owns the backing. Do not unprotect
        // it until eventual drain, even though this report continues.
        final release = releaseOwnedBacking;
        unawaited(source.dispose().then((_) => release?.call()));
      }
    }
  }
  report['caseCount'] = cases.length;
  await ImageDiskQuota.shared.drain();
  report['exactCaseCount'] = cases
      .where((entry) =>
          entry['error'] == null &&
          entry['differentPixels'] == 0 &&
          entry['nativePixels'] == true &&
          entry['sourceUnchanged'] == true)
      .length;
  report['finalDiagnostics'] = {
    'residentBytes': ReaderSurfaceDiagnostics.residentBytes,
    'activeSurfaces': ReaderSurfaceDiagnostics.activeSurfaces,
    'workingReservedBytes': ImageWorkScheduler.shared.reservedBytes,
    'temporaryReservedBytes': ImageTemporaryPool.shared.reservedBytes,
    'sourceLeases': ReaderPageFileLease.activeLeaseCount,
    'diskQuotaActiveBytes': ImageDiskQuota.shared.activeBytes,
    'diskQuotaPendingClaims': ImageDiskQuota.shared.pendingCount,
    'diskQuotaPendingOperations': ImageDiskQuota.shared.pendingOperations,
  };
  return report;
}

List<num> _rect(Rect rect) => [rect.left, rect.top, rect.width, rect.height];

class _ObservedNativeBackend extends ReaderRasterBackend {
  _ObservedNativeBackend(this.ownBacking,
      {required bool persistRaster,
      required bool preferRawSync,
      required bool preferPreparedRead})
      : delegate = NativeReaderRasterBackend(
            persistRaster: persistRaster,
            preferRawSync: preferRawSync,
            preferPreparedRead: preferPreparedRead);
  final String ownBacking;
  final images = <Map<String, Object?>>[];
  final NativeReaderRasterBackend delegate;
  @override
  Future<ReaderRasterMetadata> probe(File file) => delegate.probe(file);
  @override
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
          {required String backingPath}) =>
      delegate.estimateWorkingBytes(file, demand, backingPath: ownBacking);
  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    final image = await delegate.decode(file, demand,
        backingPath: ownBacking,
        memoryBudgetBytes: memoryBudgetBytes,
        isCancelled: isCancelled,
        cancelled: cancelled);
    images.add({
      'sourceRect': _rect(demand.sourceRect),
      'density': demand.density,
      'column': demand.column,
      'row': demand.row,
      'requestedPixels': [demand.outputWidth, demand.outputHeight],
      'actualPixels': [image.width, image.height],
      'workingBudgetBytes': memoryBudgetBytes,
    });
    return image;
  }
}

class _SurfaceCapture {
  _SurfaceCapture(this.image, this.frame, this.rasterFinishUs, this.snapshot);
  final ui.Image image;
  final ReaderPresentedFrame frame;
  final int rasterFinishUs;
  final List<Map<String, Object?>> snapshot;
}

Future<_SurfaceCapture> _captureSurface(
    NavigatorState navigator,
    ReaderPageSource source,
    ReaderRasterMetadata metadata,
    ReaderRasterBackend backend,
    Rect crop,
    double dpr) async {
  final result = Completer<_SurfaceCapture>();
  final route = PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => _QualityRoute(
          source: source,
          metadata: metadata,
          backend: backend,
          crop: crop,
          dpr: dpr,
          result: result));
  unawaited(navigator.push(route).then((_) {
    if (!result.isCompleted) {
      result.completeError(StateError('Quality route closed'));
    }
  }));
  try {
    return await result.future.timeout(const Duration(seconds: 120));
  } finally {
    if (route.isActive) navigator.removeRoute(route);
    SchedulerBinding.instance.ensureVisualUpdate();
    await WidgetsBinding.instance.endOfFrame;
  }
}

class _QualityRoute extends StatefulWidget {
  const _QualityRoute(
      {required this.source,
      required this.metadata,
      required this.backend,
      required this.crop,
      required this.dpr,
      required this.result});
  final ReaderPageSource source;
  final ReaderRasterMetadata metadata;
  final ReaderRasterBackend backend;
  final Rect crop;
  final double dpr;
  final Completer<_SurfaceCapture> result;
  @override
  State<_QualityRoute> createState() => _QualityRouteState();
}

class _QualityRouteState extends State<_QualityRoute> {
  final boundary = GlobalKey();
  final viewport = GlobalKey();
  final changes = ValueNotifier<int>(0);
  Timer? failureWatch;
  ReaderPresentedFrame? frame;
  bool capturing = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addTimingsCallback(_timings);
    failureWatch = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (widget.result.isCompleted || !mounted) return;
      final failures = ReaderSurfaceDiagnostics.snapshot()
          .where((surface) => surface['error'] != null)
          .toList();
      if (failures.isNotEmpty) {
        widget.result
            .completeError(StateError('Native surface failed: $failures'));
      }
    });
  }

  void _presented(ReaderPresentedFrame value) {
    if (widget.result.isCompleted || capturing) return;
    final actual = value.sourceRect;
    final target = widget.crop;
    final maxError = [
      actual.left - target.left,
      actual.top - target.top,
      actual.width - target.width,
      actual.height - target.height
    ].map((value) => value.abs()).reduce(math.max);
    // This tolerance validates floating-point layout projection only. Pixel
    // comparison below is exact and never applies a color/error tolerance.
    if (!value.complete ||
        !value.nativePixels ||
        value.density != 1 ||
        maxError > 0.000001 ||
        value.frameBuildTimelineUs == null) {
      widget.result
          .completeError(StateError('Native viewport geometry incomplete: '
              '${_rect(actual)} density=${value.density} error=$maxError'));
      return;
    }
    frame = value;
  }

  void _timings(List<ui.FrameTiming> timings) {
    final presented = frame;
    if (presented == null || capturing || widget.result.isCompleted) return;
    for (final timing in timings) {
      final build = presented.frameBuildTimelineUs!;
      if (build < timing.timestampInMicroseconds(ui.FramePhase.buildStart) ||
          build > timing.timestampInMicroseconds(ui.FramePhase.buildFinish)) {
        continue;
      }
      capturing = true;
      unawaited(_read(
          timing.timestampInMicroseconds(ui.FramePhase.rasterFinish),
          presented));
      return;
    }
  }

  Future<void> _read(int rasterFinish, ReaderPresentedFrame presented) async {
    ui.Image? image;
    try {
      if (!mounted) throw StateError('Quality viewport was unmounted');
      final render = boundary.currentContext?.findRenderObject();
      if (render is! ImagePipeline022ReadbackRenderObject) {
        throw StateError('Quality boundary is not ready for actual readback');
      }
      // debugNeedsPaint is intentionally undefined outside debug mode. The
      // profile path already waits for this image's matched rasterFinish.
      assert(!render.debugNeedsPaint);
      image = await render.capturePixels(
          width: widget.crop.width.round(),
          height: widget.crop.height.round(),
          pixelRatio: widget.dpr);
      if (!mounted || widget.result.isCompleted) {
        image.dispose();
        return;
      }
      widget.result.complete(_SurfaceCapture(
          image, presented, rasterFinish, ReaderSurfaceDiagnostics.snapshot()));
    } catch (error, stack) {
      image?.dispose();
      if (!widget.result.isCompleted) widget.result.completeError(error, stack);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeTimingsCallback(_timings);
    failureWatch?.cancel();
    changes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: Colors.black,
      body: Center(
          child: ImagePipeline022ReadbackBoundary(
              key: boundary,
              child: SizedBox(
                  width: widget.crop.width / widget.dpr,
                  height: widget.crop.height / widget.dpr,
                  child: ColoredBox(
                      color: Colors.black,
                      child: ClipRect(
                          key: viewport,
                          child: OverflowBox(
                              alignment: Alignment.topLeft,
                              minWidth: widget.metadata.size.width / widget.dpr,
                              maxWidth: widget.metadata.size.width / widget.dpr,
                              minHeight:
                                  widget.metadata.size.height / widget.dpr,
                              maxHeight:
                                  widget.metadata.size.height / widget.dpr,
                              child: Transform.translate(
                                  offset: Offset(-widget.crop.left / widget.dpr,
                                      -widget.crop.top / widget.dpr),
                                  child: ReaderImageSurface(
                                      source: widget.source,
                                      sourceSize: widget.metadata.size,
                                      metadata: widget.metadata,
                                      viewportKey: viewport,
                                      mode: ReaderDisplayMode.sharpFirst,
                                      transformChanges: changes,
                                      backend: widget.backend,
                                      fit: BoxFit.fill,
                                      onPresented: _presented)))))))));
}

Future<ui.Image> _reference(File file, Rect rect, String backing) async {
  const engine = native.PicakeepImageEngine();
  final width = rect.width.round(), height = rect.height.round();
  if (width > 1024 || height > 1024) {
    throw StateError('ROI capture budget exceeded');
  }
  final estimate = await engine.estimateWorkingBytes(file.path,
      backingPath: backing, outputWidth: width, outputHeight: height);
  final ticket = ImageWorkScheduler.shared.submit<ui.Image>(
      key: 'surface-quality-reference:${file.path}:${_rect(rect)}',
      priority: ImageWorkPriority.visible,
      estimatedBytes: estimate + width * height * 12,
      disposeResult: (image) => image.dispose(),
      run: (cancel) async {
        final releaseSource = ReaderPageFileLease.acquire(file);
        final releaseBacking = DerivedImageStore.protectTemporaryPath(backing);
        final token = native.NativeCancellationToken();
        var complete = false;
        unawaited(cancel.cancelled.then((_) {
          if (!complete) token.cancel();
        }));
        native.NativePixelBuffer? pixels;
        ui.Image? original;
        try {
          cancel.throwIfCancelled();
          final region = native.NativeImageRect(
              rect.left.round(), rect.top.round(), width, height);
          final decoded = await withNativeDiskWork(file, backing,
              region: region,
              outputWidth: width,
              outputHeight: height,
              run: (diskBudget) => engine.decodeRegion(file.path, region,
                  backingPath: backing,
                  outputWidth: width,
                  outputHeight: height,
                  memoryBudgetBytes: estimate,
                  diskBudgetBytes: diskBudget,
                  premultiplyAlpha: true,
                  cancelToken: token));
          pixels = decoded;
          original = await _rawImage(
              decoded.bytes, decoded.width, decoded.height,
              rowBytes: decoded.stride);
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawColor(Colors.black, BlendMode.src);
          canvas.drawImage(original, Offset.zero,
              Paint()..filterQuality = FilterQuality.none);
          final picture = recorder.endRecording();
          try {
            return await picture.toImage(width, height);
          } finally {
            picture.dispose();
          }
        } finally {
          complete = true;
          token.dispose();
          pixels?.dispose();
          original?.dispose();
          releaseBacking();
          releaseSource();
        }
      });
  return ticket.future;
}

Future<ui.Image> _rawImage(Uint8List bytes, int width, int height,
    {int? rowBytes}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = ui.ImageDescriptor.raw(buffer,
        width: width,
        height: height,
        rowBytes: rowBytes ?? width * 4,
        pixelFormat: ui.PixelFormat.rgba8888);
    codec = await descriptor.instantiateCodec();
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

Future<Uint8List> _readback(ui.Image image) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bytes == null) throw StateError('Engine returned no RGBA readback');
  return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
}

Map<String, Object?> _compare(
    Uint8List actual, Uint8List reference, int width, int height, Rect crop) {
  if (actual.length != width * height * 4 ||
      actual.length != reference.length) {
    throw StateError('Readback strides/dimensions differ');
  }
  var channels = 0, pixels = 0, seamPixels = 0;
  final maxChannel = List.filled(4, 0);
  final first = <Map<String, Object?>>[];
  final seamX = <int>[], seamY = <int>[];
  for (var x = 1; x < width; x++) {
    if ((crop.left.toInt() + x) % 512 == 0) seamX.add(x);
  }
  for (var y = 1; y < height; y++) {
    if ((crop.top.toInt() + y) % 512 == 0) seamY.add(y);
  }
  for (var pixel = 0; pixel < width * height; pixel++) {
    var different = false;
    for (var c = 0; c < 4; c++) {
      final index = pixel * 4 + c;
      final delta = (actual[index] - reference[index]).abs();
      maxChannel[c] = math.max(maxChannel[c], delta);
      if (delta > 0) {
        channels++;
        different = true;
      }
    }
    if (!different) continue;
    pixels++;
    final x = pixel % width, y = pixel ~/ width;
    if (seamX.any((seam) => (x - seam).abs() <= 1) ||
        seamY.any((seam) => (y - seam).abs() <= 1)) {
      seamPixels++;
    }
    if (first.length < 16) {
      first.add({
        'x': x,
        'y': y,
        'actual': actual.sublist(pixel * 4, pixel * 4 + 4),
        'reference': reference.sublist(pixel * 4, pixel * 4 + 4)
      });
    }
  }
  return {
    'differentPixels': pixels,
    'differentChannels': channels,
    'maxChannelDifferenceRGBA': maxChannel,
    'differentPixelsAtTileSeams': seamPixels,
    'tileSeamColumns': seamX,
    'tileSeamRows': seamY,
    'firstDifferentPixels': first,
    'exactPixels': pixels == 0
  };
}

Future<Map<String, String>> _saveDifference(
    Directory workspace,
    String name,
    ui.Image actual,
    ui.Image reference,
    Uint8List actualBytes,
    Uint8List referenceBytes) async {
  final output = <String, String>{};
  for (final image in [('actual', actual), ('reference', reference)]) {
    final png = await image.$2.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw StateError('Failed to encode diagnostic capture');
    final file = File(p.join(workspace.path, '$name-${image.$1}.png'));
    await file.writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
    output[image.$1] = file.path;
  }
  final bytes = Uint8List(actualBytes.length);
  for (var i = 0; i < bytes.length; i += 4) {
    for (var c = 0; c < 3; c++) {
      bytes[i + c] = math.min(
          255, (actualBytes[i + c] - referenceBytes[i + c]).abs() * 16);
    }
    bytes[i + 3] = 255;
  }
  final image = await _rawImage(bytes, actual.width, actual.height);
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw StateError('Failed to encode diagnostic difference');
    final file =
        File(p.join(workspace.path, '$name-rgb-difference-amplified16.png'));
    await file.writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
    output['rgbDifferenceAmplified16'] = file.path;
  } finally {
    image.dispose();
  }
  return output;
}
