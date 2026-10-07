// Opt-in debug/profile evidence for actual engine texture edge capacity.
// Thin strips bound input memory; they do not model a full 2D decode peak.
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';

import 'image_pipeline_022_exact_readback.dart';

/// Proves only a measured edge lower bound and exact endpoint rendering.
/// This does not expose a driver's advertised maximum or admit large 2D images.
Future<Map<String, Object?>> runImagePipeline022TextureCapacityChecks(
    BuildContext context) async {
  if (kReleaseMode) {
    throw UnsupportedError('Texture capacity checks require debug/profile');
  }
  final cases = <Map<String, Object?>>[];
  final errors = <Map<String, Object?>>[];
  final report = <String, Object?>{
    'schema': 1,
    'buildMode': kDebugMode ? 'debug' : 'profile',
    'platform': Platform.operatingSystem,
    'measurement':
        'raw RGBA8 strip -> ImageDescriptor codec -> actual ui.Image dimensions -> matched engine raster -> Canvas endpoint clip readback',
    'scope':
        'edge lower bound only; neither full 2D source GPU memory peak nor encoded PNG working set is established',
    'maximumSourceBytesPerCase': 65536,
    'requestedCapturePixels': [128, 64],
    'requestedPixelFormat': 'rgba8888 opaque sRGB8',
    'thresholdApplied': false,
    'cases': cases,
    'errors': errors,
  };
  if (!context.mounted) throw StateError('Texture capacity context unmounted');
  final dpr = View.of(context).devicePixelRatio;
  final physical = View.of(context).physicalSize;
  report['devicePixelRatio'] = dpr;
  report['viewPhysicalPixels'] = [physical.width, physical.height];
  if (dpr <= 0 || physical.width < 128 || physical.height < 64) {
    errors
        .add({'stage': 'viewport', 'error': '128x64 physical pixels required'});
    return report;
  }
  final navigator = Navigator.of(context, rootNavigator: true);
  final root = Directory(p.join(App.cachePath, 'texture-capacity-022'));
  await root.create(recursive: true);
  final workspace = await root.createTemp('run-');
  report['artifactRoot'] = workspace.path;
  final runId = developer.Timeline.now;
  var verifiedWidth = 0, verifiedHeight = 0;
  for (final edge in const [6000, 8192, 16384]) {
    for (final horizontal in const [true, false]) {
      final width = horizontal ? edge : 1;
      final height = horizontal ? 1 : edge;
      final label = '${width}x$height';
      final entry = <String, Object?>{
        'case': label,
        'requestedImagePixels': [width, height],
        'sourceBytes': width * height * 4,
        'firstSourceIndices': [0, 63],
        'lastSourceIndices': [edge - 64, edge - 1],
        'dimensionsPreserved': false,
        'endpointPixelsExact': false,
        'edgeVerified': false,
      };
      cases.add(entry);
      try {
        if (!context.mounted) throw StateError('Texture context unmounted');
        final ticket = ImageWorkScheduler.shared.submit<void>(
            key: 'texture-capacity-022:$runId:$label',
            priority: ImageWorkPriority.visible,
            // Source/staging/mips/readbacks are tiny and sequential. This
            // reservation includes headroom, not a claim about 2D memory.
            estimatedBytes: 4 << 20,
            run: (cancel) async {
              ui.ImmutableBuffer? buffer;
              ui.ImageDescriptor? descriptor;
              ui.Codec? codec;
              ui.Image? image;
              ui.Image? capture;
              try {
                cancel.throwIfCancelled();
                final raw = Uint8List(edge * 4);
                for (var i = 0; i < edge; i++) {
                  raw.setRange(i * 4, i * 4 + 4, _rgba(i));
                }
                buffer = await ui.ImmutableBuffer.fromUint8List(raw);
                descriptor = ui.ImageDescriptor.raw(buffer,
                    width: width,
                    height: height,
                    rowBytes: width * 4,
                    pixelFormat: ui.PixelFormat.rgba8888);
                final decodeClock = Stopwatch()..start();
                codec = await descriptor.instantiateCodec();
                image = (await codec.getNextFrame()).image;
                cancel.throwIfCancelled();
                entry.addAll({
                  'decodeWallUs': decodeClock.elapsedMicroseconds,
                  'actualImagePixels': [image.width, image.height],
                  'actualImageColorSpace': image.colorSpace.name,
                  'dimensionsPreserved':
                      image.width == width && image.height == height,
                });
                final raster = await _captureEndpoints(
                    navigator, image, edge, horizontal, dpr);
                capture = raster.image;
                entry.addAll({
                  'matchedFrameBuildTimelineUs': raster.buildUs,
                  'matchedRasterFinishUs': raster.rasterFinishUs,
                  'actualCapturePixels': [capture.width, capture.height],
                  'actualCaptureColorSpace': capture.colorSpace.name,
                });
                final data = await capture.toByteData(
                    format: ui.ImageByteFormat.rawRgba);
                if (data == null) {
                  throw StateError('Canvas readback unavailable');
                }
                final bytes = data.buffer
                    .asUint8List(data.offsetInBytes, data.lengthInBytes);
                final differences = _compareEndpoints(
                    bytes, capture.width, capture.height, edge, horizontal);
                entry['endpointPixelComparison'] = differences;
                entry['endpointPixelsExact'] =
                    differences['pixelDifferences'] == 0 &&
                        capture.width == 128 &&
                        capture.height == 64;
                entry['edgeVerified'] = entry['dimensionsPreserved'] == true &&
                    entry['endpointPixelsExact'] == true;
                if (entry['edgeVerified'] != true) {
                  final png =
                      await capture.toByteData(format: ui.ImageByteFormat.png);
                  if (png != null) {
                    final path = p.join(workspace.path, '$label-endpoints.png');
                    await File(path).writeAsBytes(png.buffer
                        .asUint8List(png.offsetInBytes, png.lengthInBytes));
                    entry['endpointCaptureArtifact'] = path;
                  }
                }
              } finally {
                capture?.dispose();
                image?.dispose();
                codec?.dispose();
                descriptor?.dispose();
                buffer?.dispose();
              }
            });
        await ticket.future;
        if (entry['edgeVerified'] == true) {
          if (horizontal) {
            verifiedWidth = edge;
          } else {
            verifiedHeight = edge;
          }
        }
      } catch (error) {
        entry['error'] = error.toString();
        errors.add({'case': label, 'error': error.toString()});
      }
    }
  }
  report.addAll({
    'verifiedWidthEdgeLowerBound': verifiedWidth,
    'verifiedHeightEdgeLowerBound': verifiedHeight,
    'verifiedBothAxesEdgeLowerBound':
        verifiedWidth < verifiedHeight ? verifiedWidth : verifiedHeight,
    'largeTwoDimensionalImageAdmitted': false,
  });
  return report;
}

List<int> _rgba(int index) => [
      (index * 37 + 17) & 255,
      (index * 61 + 29) & 255,
      (index ^ (index >> 8) ^ 90) & 255,
      255
    ];

Map<String, Object?> _compareEndpoints(
    Uint8List actual, int width, int height, int edge, bool horizontal) {
  var pixels = 0, channels = 0, maxDifference = 0;
  final first = <Map<String, Object?>>[];
  final endpoints = <Map<String, Object?>>[];
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final tile = x ~/ 64;
      final sourceIndex =
          (tile == 0 ? 0 : edge - 64) + (horizontal ? x % 64 : y);
      final expected = _rgba(sourceIndex);
      final offset = (y * width + x) * 4;
      var different = false;
      for (var c = 0; c < 4; c++) {
        final difference = (actual[offset + c] - expected[c]).abs();
        if (difference == 0) continue;
        different = true;
        channels++;
        if (difference > maxDifference) maxDifference = difference;
      }
      if (different) {
        pixels++;
        if (first.length < 16) {
          first.add({
            'capturePixel': [x, y],
            'sourceIndex': sourceIndex,
            'expected': expected,
            'actual': actual.sublist(offset, offset + 4),
          });
        }
      }
    }
  }
  for (final point in horizontal
      ? const [Offset(0, 0), Offset(63, 0), Offset(64, 0), Offset(127, 0)]
      : const [Offset(0, 0), Offset(0, 63), Offset(64, 0), Offset(64, 63)]) {
    final x = point.dx.toInt(), y = point.dy.toInt();
    if (x >= width || y >= height) continue;
    final sourceIndex = (x < 64 ? 0 : edge - 64) + (horizontal ? x % 64 : y);
    final offset = (y * width + x) * 4;
    endpoints.add({
      'sourceIndex': sourceIndex,
      'expected': _rgba(sourceIndex),
      'actual': actual.sublist(offset, offset + 4),
    });
  }
  return {
    'pixelDifferences': pixels,
    'channelDifferences': channels,
    'maximumChannelDifference': maxDifference,
    'comparedPixels': width * height,
    'firstDifferences': first,
    'endpoints': endpoints,
    'toleranceApplied': false,
  };
}

class _EndpointCapture {
  const _EndpointCapture(this.image, this.buildUs, this.rasterFinishUs);
  final ui.Image image;
  final int buildUs, rasterFinishUs;
}

Future<_EndpointCapture> _captureEndpoints(NavigatorState navigator,
    ui.Image image, int edge, bool horizontal, double dpr) async {
  final result = Completer<_EndpointCapture>();
  final route = PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => _TextureRoute(
          image: image,
          edge: edge,
          horizontal: horizontal,
          dpr: dpr,
          result: result));
  unawaited(navigator.push(route).then((_) {
    if (!result.isCompleted) {
      result.completeError(StateError('Texture capacity route closed'));
    }
  }));
  try {
    return await result.future.timeout(const Duration(seconds: 30));
  } finally {
    if (route.isActive) navigator.removeRoute(route);
    SchedulerBinding.instance.ensureVisualUpdate();
    await WidgetsBinding.instance.endOfFrame;
  }
}

class _TextureRoute extends StatefulWidget {
  const _TextureRoute(
      {required this.image,
      required this.edge,
      required this.horizontal,
      required this.dpr,
      required this.result});
  final ui.Image image;
  final int edge;
  final bool horizontal;
  final double dpr;
  final Completer<_EndpointCapture> result;
  @override
  State<_TextureRoute> createState() => _TextureRouteState();
}

class _TextureRouteState extends State<_TextureRoute> {
  final boundary = GlobalKey();
  final buildTimes = <int>[];
  bool capturing = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addTimingsCallback(_timings);
  }

  void _timings(List<ui.FrameTiming> timings) {
    if (capturing || widget.result.isCompleted) return;
    for (final timing in timings) {
      final start = timing.timestampInMicroseconds(ui.FramePhase.buildStart);
      final finish = timing.timestampInMicroseconds(ui.FramePhase.buildFinish);
      for (final build in buildTimes) {
        if (build < start || build > finish) continue;
        capturing = true;
        unawaited(_read(
            build, timing.timestampInMicroseconds(ui.FramePhase.rasterFinish)));
        return;
      }
    }
  }

  Future<void> _read(int build, int rasterFinish) async {
    ui.Image? captured;
    try {
      if (!mounted) throw StateError('Texture capacity route unmounted');
      final render = boundary.currentContext?.findRenderObject();
      if (render is! ImagePipeline022ReadbackRenderObject) {
        throw StateError('Texture capacity boundary unavailable');
      }
      assert(!render.debugNeedsPaint);
      captured = await render.capturePixels(
          width: 128, height: 64, pixelRatio: widget.dpr);
      if (!mounted || widget.result.isCompleted) {
        captured.dispose();
        return;
      }
      widget.result.complete(_EndpointCapture(captured, build, rasterFinish));
    } catch (error, stack) {
      captured?.dispose();
      if (!widget.result.isCompleted) {
        widget.result.completeError(error, stack);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeTimingsCallback(_timings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    buildTimes.add(developer.Timeline.now);
    return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
            child: ImagePipeline022ReadbackBoundary(
                key: boundary,
                child: SizedBox(
                    width: 128 / widget.dpr,
                    height: 64 / widget.dpr,
                    child: CustomPaint(
                        painter: _EndpointPainter(widget.image, widget.edge,
                            widget.horizontal, widget.dpr))))));
  }
}

class _EndpointPainter extends CustomPainter {
  const _EndpointPainter(this.image, this.edge, this.horizontal, this.dpr);
  final ui.Image image;
  final int edge;
  final bool horizontal;
  final double dpr;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(1 / dpr);
    canvas.clipRect(const Rect.fromLTWH(0, 0, 128, 64));
    canvas.drawRect(
        const Rect.fromLTWH(0, 0, 128, 64), Paint()..color = Colors.black);
    final paint = Paint()
      ..isAntiAlias = false
      ..filterQuality = FilterQuality.none;
    for (var tile = 0; tile < 2; tile++) {
      final start = tile == 0 ? 0.0 : edge - 64.0;
      final source = horizontal
          ? Rect.fromLTWH(start, 0, 64, 1)
          : Rect.fromLTWH(0, start, 1, 64);
      final destination = Rect.fromLTWH(tile * 64.0, 0, 64, 64);
      canvas.drawImageRect(image, source, destination, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EndpointPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.edge != edge ||
      oldDelegate.horizontal != horizontal ||
      oldDelegate.dpr != dpr;
}
