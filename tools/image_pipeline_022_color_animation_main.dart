// Isolated debug/profile evidence for the production color/animation reader.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_cache.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep/pages/reader/reader_page_image.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart' as native;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:window_manager/window_manager.dart';

import 'image_pipeline_022_exact_readback.dart';
import 'image_pipeline_022_color_precision_probe.dart';
import 'image_pipeline_022_task_storage.dart';

const _staticFixtures = [
  '640x960-16bit-icc.png',
  '640x960-gray-16bit-icc.png',
  '640x960-p3-icc.png',
  '640x960-adobe-rgb-icc.png',
];
const _animationFixtures = ['16x16-two-frame.gif', '16x16-two-frame.webp'];
const _benchmarkScreenChannel = MethodChannel('lingxue.picakeep/keepScreenOn');

Future<void> _keepBenchmarkScreenOn(bool enabled) async {
  if (!Platform.isAndroid) return;
  try {
    await _benchmarkScreenChannel.invokeMethod(enabled ? 'set' : 'cancel');
  } catch (error) {
    print('PICAKEEP_022_SCREEN ${jsonEncode({
          'enabled': enabled,
          'error': error.toString()
        })}');
  }
}

Future<void> main(List<String> arguments) async {
  if (kReleaseMode) {
    throw StateError('Verification supports debug/profile only');
  }
  var args = List<String>.of(arguments);
  if (Platform.isAndroid && args.isEmpty) {
    final values = jsonDecode(await File(
            '/data/local/tmp/picakeep-native-022/color-animation-options.json')
        .readAsString()) as Map<String, dynamic>;
    args = values.entries.map((e) => '--${e.key}=${e.value}').toList();
  }
  final options = <String, String>{};
  for (final arg in args) {
    final separator = arg.indexOf('=');
    if (arg.startsWith('--') && separator > 2) {
      options[arg.substring(2, separator)] = arg.substring(separator + 1);
    }
  }
  final work = options['work'], fixtures = options['fixtures'];
  if (work == null || fixtures == null || !p.isAbsolute(fixtures)) {
    throw ArgumentError(
        '--work=<absolute normal-ui-022-* task> and --fixtures=<absolute synthetic fixtures> are required');
  }
  final storage = await ImagePipelineTaskStorage.prepare(work);
  await IOOverrides.runZoned(() async {
    WidgetsFlutterBinding.ensureInitialized();
    PathProviderPlatform.instance = TaskPathProvider(storage);
    SharedPreferencesStorePlatform.instance =
        await TaskSharedPreferencesStore.open(storage);
    SharedPreferences.setPrefix('picakeep022.colorAnimation.');
    await App.init(
        dataPathOverride: storage.support,
        cachePathOverride: storage.cache,
        migrateExistingData: false);
    if (Platform.isWindows) await windowManager.ensureInitialized();
    runApp(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(),
        home: _ColorAnimationRun(
            storage: storage,
            fixtures: p.normalize(fixtures),
            precisionProbe: options['precision-probe'] == 'true',
            closeWindow: options['close-window'] == 'true')));
    if (Platform.isWindows) {
      await windowManager.waitUntilReadyToShow(
          const WindowOptions(
              title: 'PicaKeep 022 color and animation',
              size: Size(900, 900),
              center: true), () async {
        await windowManager.show();
        await windowManager.focus();
      });
    }
  }, getSystemTempDirectory: () => Directory(storage.temporary));
}

Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Map<String, Object?> _diagnostics() => {
      'residentBytes': ReaderSurfaceDiagnostics.residentBytes,
      'pendingResidentBytes': ReaderSurfaceDiagnostics.pendingBytes,
      'activeSurfaces': ReaderSurfaceDiagnostics.activeSurfaces,
      'activeJobs': ImageWorkScheduler.shared.activeCount,
      'queuedAndRunningJobs': ImageWorkScheduler.shared.pendingCount,
      'reservedWorkingBytes': ImageWorkScheduler.shared.reservedBytes,
      'reservedTemporaryBytes': ImageTemporaryPool.shared.reservedBytes,
      'originalFileLeases': ReaderPageFileLease.activeLeaseCount,
      'pendingRasterCacheBytes': ReaderRasterCache.pendingBytes,
      'diskActiveBytes': ImageDiskQuota.shared.activeBytes,
      'diskPendingClaims': ImageDiskQuota.shared.pendingCount,
      'diskPendingOperations': ImageDiskQuota.shared.pendingOperations,
      'diskRejectedCount': ImageDiskQuota.shared.rejectedCount,
      'nativeWorkers': native.PicakeepImageEngine.workerDiagnostics,
      'imageCacheBytes': PaintingBinding.instance.imageCache.currentSizeBytes,
      'imageCacheLive': PaintingBinding.instance.imageCache.liveImageCount,
      'rssBytes': ProcessInfo.currentRss,
      'peakRssBytes': ProcessInfo.maxRss,
    };

Future<void> _drain() async {
  await ReaderRasterCache.drain();
  await ImageDiskQuota.shared.drain();
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (ReaderSurfaceDiagnostics.activeSurfaces != 0 ||
      ReaderSurfaceDiagnostics.residentBytes != 0 ||
      ReaderSurfaceDiagnostics.pendingBytes != 0 ||
      ImageWorkScheduler.shared.hasWork ||
      ReaderPageFileLease.activeLeaseCount != 0 ||
      ImageTemporaryPool.shared.reservedBytes != 0 ||
      ReaderRasterCache.pendingBytes != 0 ||
      ImageDiskQuota.shared.activeBytes != 0 ||
      ImageDiskQuota.shared.pendingCount != 0 ||
      ImageDiskQuota.shared.pendingOperations != 0) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError(
          'Reader exit did not drain: ${jsonEncode(_diagnostics())}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _ColorAnimationRun extends StatefulWidget {
  const _ColorAnimationRun(
      {required this.storage,
      required this.fixtures,
      required this.precisionProbe,
      required this.closeWindow});
  final ImagePipelineTaskStorage storage;
  final String fixtures;
  final bool precisionProbe;
  final bool closeWindow;
  @override
  State<_ColorAnimationRun> createState() => _ColorAnimationRunState();
}

class _ColorAnimationRunState extends State<_ColorAnimationRun> {
  final cases = <Map<String, Object?>>[];
  final errors = <Map<String, Object?>>[];
  String label = '022';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  Future<void> _run() async {
    final started = DateTime.now().toUtc();
    await _keepBenchmarkScreenOn(true);
    print('PICAKEEP_022_COLOR_ANIMATION_START ${started.toIso8601String()}');
    try {
      if (!native.PicakeepImageEngine.isAvailable) {
        throw StateError('The production native metadata path is unavailable');
      }
      for (final name in [..._staticFixtures, ..._animationFixtures]) {
        final file = File(p.join(widget.fixtures, name));
        FileStat? before;
        String? beforeSha;
        try {
          before = await file.stat();
          beforeSha = await _digest(file);
          if (before.type != FileSystemEntityType.file ||
              before.size <= 0 ||
              before.size > 64 << 20) {
            throw StateError('Fixture is missing or exceeds the encoded cap');
          }
          final expectedAnimation = _animationFixtures.contains(name);
          final extension = p.extension(name).substring(1).toLowerCase();
          late final Map<String, Object?> sourceMetadata;
          try {
            final metadata =
                await const native.PicakeepImageEngine().probe(file.path);
            sourceMetadata = {
              'format': metadata.format,
              'width': metadata.width,
              'height': metadata.height,
              'bitDepth': metadata.bitDepth,
              'hasColorProfile': metadata.hasColorProfile,
              'animated': metadata.animated,
              'source': 'native metadata probe',
            };
          } on native.ImageEngineException catch (error) {
            if (error.code != 4 || extension != 'gif') rethrow;
            final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
            ui.ImageDescriptor? descriptor;
            try {
              descriptor = await ui.ImageDescriptor.encoded(buffer);
              sourceMetadata = {
                'format': extension,
                'width': descriptor.width,
                'height': descriptor.height,
                'bitDepth': null,
                'hasColorProfile': false,
                'animated': true,
                'source': 'Flutter codec; native region probe unsupported',
              };
            } finally {
              descriptor?.dispose();
              buffer.dispose();
            }
          }
          final expectedBitDepth = name.contains('16bit') ? 16 : 8;
          final metadataMatches = expectedAnimation
              ? sourceMetadata['animated'] == true &&
                  sourceMetadata['format'] == extension
              : sourceMetadata['format'] == 'png' &&
                  sourceMetadata['bitDepth'] == expectedBitDepth &&
                  sourceMetadata['hasColorProfile'] == true &&
                  sourceMetadata['animated'] == false;
          if (!metadataMatches) {
            errors.add({
              'fixture': name,
              'stage': 'native-metadata',
              'expected': expectedAnimation
                  ? {
                      'format': p.extension(name).substring(1).toLowerCase(),
                      'animated': true
                    }
                  : {
                      'format': 'png',
                      'bitDepth': expectedBitDepth,
                      'hasColorProfile': true,
                      'animated': false
                    },
              'actual': {
                ...sourceMetadata,
              },
            });
          }
          for (final layout in ['single', 'continuous', 'double']) {
            for (final mode in ReaderDisplayMode.values) {
              if (mounted) setState(() => label = '$name $layout ${mode.name}');
              final record = <String, Object?>{
                'fixture': name,
                'layout': layout,
                'mode': mode.name,
                'sourceSha256Before': beforeSha,
                'sourceBytes': before.size,
                'animation': _animationFixtures.contains(name),
                'sourceMetadata': sourceMetadata,
                'fixtureExpectationMatches': metadataMatches,
              };
              cases.add(record);
              try {
                final key = '${cases.length}:$beforeSha:$layout:${mode.name}';
                final ticket = ImageWorkScheduler.shared.submit<void>(
                    key: '022-color-animation:$key',
                    priority: ImageWorkPriority.visible,
                    estimatedBytes: (128 << 20) + before.size * 2,
                    run: (cancellation) async {
                      cancellation.throwIfCancelled();
                      final release = ReaderPageFileLease.acquire(file);
                      _OriginalFrames? originals;
                      try {
                        originals = await _OriginalFrames.open(file);
                        record.addAll(originals.facts);
                        if (originals.frameCount !=
                            (_animationFixtures.contains(name) ? 2 : 1)) {
                          throw StateError(
                              'Unexpected original codec frame count');
                        }
                        if (!mounted) {
                          throw StateError('Task route is unmounted');
                        }
                        ReaderRasterDiagnostics.drainSamples();
                        final captured = await _capture(
                            Navigator.of(context),
                            widget.storage,
                            file,
                            before!,
                            originals,
                            layout,
                            mode,
                            key);
                        record.addAll(captured);
                      } finally {
                        originals?.dispose();
                        release();
                      }
                    });
                try {
                  await ticket.future;
                } finally {
                  ticket.cancel();
                }
                record['status'] = 'measured';
              } catch (error, stack) {
                record.addAll(
                    {'status': 'error', 'error': '$error', 'stack': '$stack'});
                errors.add({
                  'fixture': name,
                  'layout': layout,
                  'mode': mode.name,
                  'error': '$error'
                });
              } finally {
                try {
                  PaintingBinding.instance.imageCache.clear();
                  PaintingBinding.instance.imageCache.clearLiveImages();
                  await _drain();
                  record['afterExit'] = _diagnostics();
                } catch (error) {
                  record['exitError'] = '$error';
                  errors.add(
                      {'stage': 'exit', 'fixture': name, 'error': '$error'});
                }
              }
              print('PICAKEEP_022_COLOR_ANIMATION_CASE ${jsonEncode(record)}');
            }
          }
        } catch (error, stack) {
          errors.add({
            'fixture': name,
            'stage': 'fixture',
            'error': '$error',
            'stack': '$stack'
          });
        } finally {
          if (before != null && beforeSha != null) {
            try {
              final after = await file.stat();
              final afterSha = await _digest(file);
              final unchanged = before.size == after.size &&
                  before.modified == after.modified &&
                  beforeSha == afterSha;
              for (final item
                  in cases.where((item) => item['fixture'] == name)) {
                item['sourceSha256After'] = afterSha;
                item['sourceUnchanged'] = unchanged;
              }
              if (!unchanged) throw StateError('Original fixture changed');
            } catch (error) {
              errors.add(
                  {'fixture': name, 'stage': 'original', 'error': '$error'});
            }
          }
        }
      }
      if (widget.precisionProbe) {
        // Diagnostic-only bounded original/crop/mosaic controls. The production
        // reference above stays intact; this does not apply a quality threshold.
        final precision = await runImagePipeline022ColorPrecisionProbe(
            widget.fixtures,
            artifactsPath: p.join(widget.storage.root, 'precision-artifacts'));
        final output =
            p.join(widget.storage.root, 'color-precision-results.json');
        await widget.storage.checkPath(output);
        await File(output).writeAsString(
            const JsonEncoder.withIndent('  ').convert(precision),
            flush: true);
        print('PICAKEEP_022_COLOR_PRECISION_REPORT $output');
        if ((precision['errors'] as List).isNotEmpty) {
          errors.add(
              {'stage': 'precision-controls', 'errors': precision['errors']});
        }
      }
    } catch (error, stack) {
      errors.add({'stage': 'run', 'error': '$error', 'stack': '$stack'});
    } finally {
      await _keepBenchmarkScreenOn(false);
      try {
        await _drain();
        await native.PicakeepImageEngine.shutdownIdleWorkers();
      } catch (error) {
        errors.add({'stage': 'final-drain', 'error': '$error'});
      }
      final report = <String, Object?>{
        'schema': 'image-pipeline-022-color-animation-v1',
        'buildMode': kProfileMode ? 'profile' : 'debug',
        'platform': Platform.operatingSystem,
        'startedUtc': started.toIso8601String(),
        'finishedUtc': DateTime.now().toUtc().toIso8601String(),
        'taskRoot': widget.storage.root,
        'production':
            'ReaderPageImage; single PhotoView / continuous PhotoView+scroll / double PhotoViewGallery',
        'reference':
            'Independent Flutter original-file encoded codec -> same observed original-coordinate Canvas projection',
        'thresholdApplied': false,
        'colorScope':
            'RGBA8 canvas and available float readback facts; matching sRGB8 does not prove HDR or OS display gamut',
        'animationScope':
            'Real Image.file compatibility player RawImage handles, paint Timeline contained in matched FrameTiming; at least two distinct original frames',
        'animationBudgetBoundary':
            'Production compatibility branch checks decoded size <=64MiB but bypasses Surface resident/job counters; tool reference/capture is separately scheduler-reserved',
        'expectedCases': 36,
        'caseCount': cases.length,
        'status':
            errors.isEmpty && cases.length == 36 ? 'measured' : 'incomplete',
        'automaticQualityAcceptance': false,
        'precisionControlsRequested': widget.precisionProbe,
        'cases': cases,
        'errors': errors,
        'finalDiagnostics': _diagnostics(),
      };
      final output =
          p.join(widget.storage.root, 'color-animation-results.json');
      await widget.storage.checkPath(output);
      await File(output).writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
          flush: true);
      print('PICAKEEP_022_COLOR_ANIMATION_REPORT $output');
      print('PICAKEEP_022_COLOR_ANIMATION_STATUS ${report['status']}');
      if (mounted) setState(() => label = output);
      if (widget.closeWindow && Platform.isWindows) await windowManager.close();
    }
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text(label)));
}

class _OriginalFrames {
  _OriginalFrames(this.images, this.durationMs, this.frameCount,
      this.repetitions, this.descriptorSize, this.frameHashes);
  final List<ui.Image> images;
  final List<int> durationMs;
  final int frameCount, repetitions;
  final List<int> descriptorSize;
  final List<String> frameHashes;
  Size get size =>
      Size(images.first.width.toDouble(), images.first.height.toDouble());
  Map<String, Object?> get facts => {
        'originalDescriptorPixels': descriptorSize,
        'originalImagePixels': [images.first.width, images.first.height],
        'originalImageColorSpace': images.first.colorSpace.name,
        'originalCodecFrameCount': frameCount,
        'originalCodecRepetitionCount': repetitions,
        'originalCodecDurationMs': durationMs,
        'originalFrameRgbaSha256': frameHashes,
      };
  static Future<_OriginalFrames> open(File file) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    final images = <ui.Image>[];
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width * descriptor.height > 4 * 1024 * 1024 ||
          descriptor.width > 4096 ||
          descriptor.height > 4096) {
        throw StateError('Reference exceeds the bounded small-original scope');
      }
      codec = await descriptor.instantiateCodec();
      if (codec.frameCount > 2) {
        throw StateError('Reference accepts at most two frames');
      }
      final durations = <int>[], hashes = <String>[];
      for (var i = 0; i < codec.frameCount; i++) {
        final frame = await codec.getNextFrame();
        images.add(frame.image);
        durations.add(frame.duration.inMilliseconds);
        hashes.add(sha256.convert(await _rgba(frame.image)).toString());
      }
      return _OriginalFrames(images, durations, codec.frameCount,
          codec.repetitionCount, [descriptor.width, descriptor.height], hashes);
    } catch (_) {
      for (final image in images) {
        image.dispose();
      }
      rethrow;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  void dispose() {
    for (final image in images) {
      image.dispose();
    }
  }
}

Future<Map<String, Object?>> _capture(
    NavigatorState navigator,
    ImagePipelineTaskStorage storage,
    File file,
    FileStat stat,
    _OriginalFrames originals,
    String layout,
    ReaderDisplayMode mode,
    String key) async {
  final result = Completer<Map<String, Object?>>();
  final captureKey = GlobalKey<_ReaderCaptureState>();
  final route = PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => _ReaderCapture(
          key: captureKey,
          storage: storage,
          file: file,
          stat: stat,
          originals: originals,
          layout: layout,
          mode: mode,
          identity: key,
          result: result));
  unawaited(navigator.push(route).then((_) {
    if (!result.isCompleted) {
      result.completeError(StateError('Capture route closed'));
    }
  }));
  try {
    return await result.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException(
          'Reader capture timeout: ${jsonEncode(captureKey.currentState?._debugSnapshot())}',
          const Duration(seconds: 15)),
    );
  } finally {
    final captureState = captureKey.currentState;
    if (route.isActive) navigator.removeRoute(route);
    SchedulerBinding.instance.ensureVisualUpdate();
    await WidgetsBinding.instance.endOfFrame;
    final pending = List<Future<void>>.of(captureState?.pending ?? []);
    await Future.wait<void>(
        pending.map((future) => future.catchError((Object _) {})));
  }
}

class _ReaderCapture extends StatefulWidget {
  const _ReaderCapture(
      {super.key,
      required this.storage,
      required this.file,
      required this.stat,
      required this.originals,
      required this.layout,
      required this.mode,
      required this.identity,
      required this.result});
  final ImagePipelineTaskStorage storage;
  final File file;
  final FileStat stat;
  final _OriginalFrames originals;
  final String layout, identity;
  final ReaderDisplayMode mode;
  final Completer<Map<String, Object?>> result;
  @override
  State<_ReaderCapture> createState() => _ReaderCaptureState();
}

class _ReaderCaptureState extends State<_ReaderCapture> {
  final boundary = GlobalKey(),
      viewport = GlobalKey(),
      paintObserver = GlobalKey();
  final pageKeys = <String, GlobalKey>{};
  final changes = ValueNotifier<int>(0);
  final controller = PhotoViewController();
  final scroll = ScrollController();
  final presented = <String, ReaderPresentedFrame>{};
  final frames = <Map<String, Object?>>[];
  final pending = <Future<void>>[];
  final marks = <int>[];
  final recorded = <int>{};
  final timings = <ui.FrameTiming>[];
  final previousImages = <String, ui.Image>{};
  StreamSubscription<PhotoViewControllerValue>? subscription;
  Timer? watch;
  double? nativeScale;
  bool configured = false, capturedStatic = false, finishing = false;
  int lastPaintUs = 0, scheduled = 0;
  bool get animated => widget.originals.frameCount == 2;
  List<String> get parts =>
      widget.layout == 'double' ? ['left', 'right'] : ['left'];
  int get width => animated ? (widget.layout == 'double' ? 32 : 16) : 512;
  int get height => animated ? 16 : 512;
  double get dpr => View.of(context).devicePixelRatio;

  Map<String, Object?> _debugSnapshot() {
    Map<String, Object?> imageState(String part) {
      final root = pageKeys[part]?.currentContext;
      ui.Image? image;
      if (root is Element) {
        void visit(Element element) {
          if (element.widget case RawImage(image: final candidate?)) {
            image = candidate;
          }
          element.visitChildren(visit);
        }

        visit(root);
      }
      final frame = presented[part];
      return {
        'rawImage': image == null
            ? null
            : {
                'identity': identityHashCode(image),
                'width': image!.width,
                'height': image!.height,
              },
        'presented': frame == null
            ? null
            : {
                'density': frame.density,
                'complete': frame.complete,
                'nativePixels': frame.nativePixels,
              },
      };
    }

    return {
      'layout': widget.layout,
      'animated': animated,
      'configured': configured,
      'nativeScale': nativeScale,
      'controllerScale': controller.value.scale,
      'parts': {for (final part in parts) part: imageState(part)},
      'surfaceDiagnostics': ReaderSurfaceDiagnostics.snapshot(),
      'scheduled': scheduled,
      'recorded': recorded.toList()..sort(),
      'pendingReads': pending.length,
      'paintMarks': marks.length,
      'frameTimingCount': timings.length,
      'matchedFrameTimingCount':
          marks.where((mark) => _match(mark) != null).length,
    };
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addTimingsCallback(_onTimings);
    subscription = controller.outputStateStream.listen((_) => changes.value++);
    watch = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted || widget.result.isCompleted) return;
      final failures = ReaderSurfaceDiagnostics.snapshot()
          .where((s) => s['error'] != null)
          .toList();
      if (failures.isNotEmpty) {
        widget.result
            .completeError(StateError('Reader surface error: $failures'));
      }
      paintObserver.currentContext?.findRenderObject()?.markNeedsPaint();
      SchedulerBinding.instance.ensureVisualUpdate();
      _maybeFinish();
    });
  }

  void _onTimings(List<ui.FrameTiming> values) {
    timings.addAll(values);
    _maybeFinish();
  }

  ui.FrameTiming? _match(int paint) {
    for (final timing in timings) {
      if (paint >= timing.timestampInMicroseconds(ui.FramePhase.buildStart) &&
          paint <= timing.timestampInMicroseconds(ui.FramePhase.buildFinish)) {
        return timing;
      }
    }
    return null;
  }

  void _maybeFinish() {
    if (finishing ||
        widget.result.isCompleted ||
        pending.isNotEmpty ||
        recorded.length != scheduled ||
        scheduled < (animated ? 2 : 1)) {
      return;
    }
    if (marks.any((mark) => _match(mark) == null)) return;
    final displayedByPart = <String, Set<int>>{
      for (final part in parts) part: <int>{}
    };
    for (final frame in frames) {
      final byPart = frame['originalFrameByPart'] as Map?;
      for (final part in parts) {
        final index = byPart?[part];
        if (index is int) displayedByPart[part]!.add(index);
      }
    }
    if (animated && displayedByPart.values.any((values) => values.length < 2)) {
      if (scheduled >= 8) {
        widget.result.completeError(StateError(
            'Each player did not present two distinct original frames after 8 observations'));
      }
      return;
    }
    finishing = true;
    for (var i = 0; i < frames.length; i++) {
      final timing = _match(marks[i])!;
      frames[i]['matchedFrameTiming'] = {
        'paintTimelineUs': marks[i],
        'buildStartUs':
            timing.timestampInMicroseconds(ui.FramePhase.buildStart),
        'buildFinishUs':
            timing.timestampInMicroseconds(ui.FramePhase.buildFinish),
        'rasterStartUs':
            timing.timestampInMicroseconds(ui.FramePhase.rasterStart),
        'rasterFinishUs':
            timing.timestampInMicroseconds(ui.FramePhase.rasterFinish),
        'rasterDurationUs': timing.rasterDuration.inMicroseconds,
      };
    }
    widget.result.complete({
      'devicePixelRatio': dpr,
      'capturePixels': [width, height],
      'controllerScale': controller.value.scale,
      'frames': frames,
      'distinctOriginalFramesByPart': {
        for (final entry in displayedByPart.entries)
          entry.key: entry.value.toList()..sort()
      },
      'rasterStages': ReaderRasterDiagnostics.drainSamples(),
      'observedPaintIntervalsMs': [
        for (var i = 1; i < marks.length; i++) (marks[i] - marks[i - 1]) / 1000
      ],
      'surfaceSnapshot': ReaderSurfaceDiagnostics.snapshot(),
      'resourceDiagnosticsWhileMounted': _diagnostics(),
      'originalPixelProjectionRequested': true,
      'frameTimingScope':
          'Paint timestamp contained in engine build interval; compositor display scan-out not measured',
    });
  }

  Widget _page(String part,
          {PhotoViewController? pageController,
          double? continuousWidth,
          Alignment alignment = Alignment.center}) =>
      ReaderPageImage(
          key: pageKeys.putIfAbsent(part, () => GlobalKey()),
          resourceKey: '${widget.identity}:$part',
          loadSource: () async => FileReaderPageSource(
              file: widget.file,
              identity: ReaderPageIdentity(
                  sourceKey: '022-color-animation',
                  workId: p.basename(widget.file.path),
                  downloadId: widget.identity,
                  episode: 0,
                  page: part == 'left' ? 0 : 1,
                  sourceVersion:
                      '${widget.stat.size}:${widget.stat.modified.microsecondsSinceEpoch}'),
              byteLength: widget.stat.size,
              modifiedMillis: widget.stat.modified.millisecondsSinceEpoch),
          viewportKey: viewport,
          transformChanges: changes,
          mode: widget.mode,
          controller: pageController,
          continuousWidth: continuousWidth,
          alignment: alignment,
          nativeScaleChanged: (value) {
            nativeScale = widget.layout == 'double'
                ? math.max(nativeScale ?? 0, value)
                : value;
          },
          onPresented: (value) {
            if (configured &&
                value.complete &&
                value.nativePixels &&
                value.density == 1) {
              presented[part] = value;
              if (!animated && lastPaintUs > 0) {
                SchedulerBinding.instance.ensureVisualUpdate();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() {});
                });
              }
            }
          },
          persistRaster: false);

  Widget _reader(BoxConstraints constraints) {
    if (widget.layout == 'continuous') {
      return PhotoView.customChild(
          controller: controller,
          childSize: constraints.biggest,
          minScale: 1.0,
          initialScale: 1.0,
          maxScale: 64.0,
          strictScale: true,
          child: SingleChildScrollView(
              controller: scroll,
              child: _page('left', continuousWidth: constraints.maxWidth)));
    }
    if (widget.layout == 'double') {
      return PhotoViewGallery.builder(
          itemCount: 1,
          backgroundDecoration: const BoxDecoration(color: Colors.black),
          builder: (_, __) => PhotoViewGalleryPageOptions.customChild(
              controller: controller,
              childSize: constraints.biggest,
              minScale: 1.0,
              initialScale: 1.0,
              maxScale: 64.0,
              child: Row(children: [
                Expanded(
                    child: _page('left', alignment: Alignment.centerRight)),
                Expanded(
                    child: _page('right', alignment: Alignment.centerLeft)),
              ])));
    }
    return _page('left', pageController: controller);
  }

  void _paint() {
    if (finishing || widget.result.isCompleted) return;
    lastPaintUs = developer.Timeline.now;
    if (!configured) {
      if (nativeScale == null) return;
      configured = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        controller.updateMultiple(scale: nativeScale, position: Offset.zero);
        changes.value++;
      });
      return;
    }
    if (!animated) {
      _static(lastPaintUs);
      return;
    }
    if (scheduled >= 8) return;
    final raws = _rawImages();
    if (raws.length != parts.length) return;
    if (parts.every((part) =>
        previousImages[part] != null &&
        raws[part]!.$1.image!.isCloneOf(previousImages[part]!))) {
      return;
    }
    final images = <String, ui.Image>{};
    for (final part in parts) {
      final image = raws[part]!.$1.image!;
      previousImages.remove(part)?.dispose();
      previousImages[part] = image.clone();
      images[part] = image.clone();
    }
    _schedule(lastPaintUs, images);
  }

  void _static(int paint) {
    if (!configured || capturedStatic || !parts.every(presented.containsKey)) {
      return;
    }
    capturedStatic = true;
    _schedule(paint, const {});
  }

  void _schedule(int paint, Map<String, ui.Image> images) {
    final index = scheduled++;
    marks.add(paint);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.result.isCompleted) {
        for (final image in images.values) {
          image.dispose();
        }
        return;
      }
      final future = _read(index, paint, images);
      pending.add(future);
      unawaited(future.then<void>(
        (_) {
          pending.remove(future);
          _maybeFinish();
        },
        onError: (Object error, StackTrace stack) {
          pending.remove(future);
          if (!widget.result.isCompleted) {
            widget.result.completeError(error, stack);
          }
        },
      ));
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  Map<String, (RawImage, RenderBox)> _rawImages() {
    final result = <String, (RawImage, RenderBox)>{};
    for (final part in parts) {
      final root = pageKeys[part]?.currentContext;
      if (root is! Element) continue;
      void visit(Element e) {
        final widget = e.widget;
        if (widget is RawImage && widget.image != null) {
          final render = e.findRenderObject();
          if (render is RenderBox) result[part] = (widget, render);
        }
        e.visitChildren(visit);
      }

      visit(root);
    }
    return result;
  }

  RenderBox _surface(String part) {
    final root = pageKeys[part]!.currentContext as Element;
    RenderBox? result;
    void visitPainter(Element e) {
      if (e.widget is CustomPaint) {
        final render = e.findRenderObject();
        if (render is RenderBox) result = render;
        return;
      }
      e.visitChildren(visitPainter);
    }

    void visit(Element e) {
      if (e.widget is ReaderImageSurface) {
        e.visitChildren(visitPainter);
        return;
      }
      e.visitChildren(visit);
    }

    visit(root);
    if (result == null) throw StateError('Production surface was not mounted');
    return result!;
  }

  Future<void> _read(int index, int paint, Map<String, ui.Image> images) async {
    final textDirection = Directionality.of(context);
    ui.Image? actual, reference, noAntiAliasReference;
    try {
      final render = boundary.currentContext!.findRenderObject()
          as ImagePipeline022ReadbackRenderObject;
      final capture =
          render.capturePixels(width: width, height: height, pixelRatio: dpr);
      final raw =
          animated ? _rawImages() : const <String, (RawImage, RenderBox)>{};
      final scene = {
        for (final part in parts)
          part: (
            size: (animated ? raw[part]!.$2 : _surface(part)).size,
            transform: Float64List.fromList(
                (animated ? raw[part]!.$2 : _surface(part))
                    .getTransformTo(render)
                    .storage),
            alignment: animated
                ? raw[part]!.$1.alignment
                : (part == 'left' && widget.layout == 'double'
                    ? Alignment.centerRight
                    : part == 'right'
                        ? Alignment.centerLeft
                        : Alignment.center),
            fit: animated
                ? raw[part]!.$1.fit ?? BoxFit.scaleDown
                : BoxFit.contain,
            filter: animated ? raw[part]!.$1.filterQuality : FilterQuality.none,
          )
      };
      final frameIndex = <String, int>{};
      final geometries = <String, Object?>{};
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..drawColor(Colors.black, BlendMode.src);
      final controlRecorder = ui.PictureRecorder();
      final controlCanvas = Canvas(controlRecorder)
        ..drawColor(Colors.black, BlendMode.src);
      for (final part in parts) {
        var originalIndex = 0;
        if (animated) {
          final hash = sha256.convert(await _rgba(images[part]!)).toString();
          originalIndex = widget.originals.frameHashes.indexOf(hash);
          if (originalIndex < 0) {
            throw StateError(
                'Player frame differs from both independent original frames');
          }
          frameIndex[part] = originalIndex;
        }
        final image = widget.originals.images[originalIndex];
        final geometry = scene[part]!;
        final transform = geometry.transform;
        final alignment = geometry.alignment;
        final fit = geometry.fit;
        final fitted = applyBoxFit(fit, widget.originals.size, geometry.size);
        final scaleX = Offset(transform[0], transform[1]).distance *
            fitted.destination.width /
            fitted.source.width *
            dpr;
        final scaleY = Offset(transform[4], transform[5]).distance *
            fitted.destination.height /
            fitted.source.height *
            dpr;
        const pixelScaleTolerance = 0.0001;
        if ((scaleX - 1).abs() > pixelScaleTolerance ||
            (scaleY - 1).abs() > pixelScaleTolerance) {
          throw StateError(
              'Original-pixel projection is not 1:1: physical source scale $scaleX x $scaleY');
        }
        final destination = alignment
            .resolve(textDirection)
            .inscribe(fitted.destination, Offset.zero & geometry.size);
        final source = alignment
            .resolve(textDirection)
            .inscribe(fitted.source, Offset.zero & widget.originals.size);
        for (final target in [(canvas, true), (controlCanvas, false)]) {
          target.$1.save();
          target.$1.scale(dpr);
          target.$1.transform(transform);
          target.$1.clipRect(Offset.zero & geometry.size);
          target.$1.drawImageRect(
              image,
              source,
              destination,
              Paint()
                ..isAntiAlias = target.$2
                ..filterQuality = geometry.filter);
          target.$1.restore();
        }
        geometries[part] = {
          'renderBoxLogical': [geometry.size.width, geometry.size.height],
          'sourceRect': [source.left, source.top, source.width, source.height],
          'destinationLogical': [
            destination.left,
            destination.top,
            destination.width,
            destination.height
          ],
          'transformToCapture': transform,
          'physicalPixelsPerOriginalPixel': [scaleX, scaleY],
          'originalPixelScaleTolerance': pixelScaleTolerance,
          'originalImageColorSpace': image.colorSpace.name,
        };
      }
      final picture = recorder.endRecording();
      try {
        reference = await picture.toImage(width, height);
      } finally {
        picture.dispose();
      }
      final controlPicture = controlRecorder.endRecording();
      try {
        noAntiAliasReference = await controlPicture.toImage(width, height);
      } finally {
        controlPicture.dispose();
      }
      actual = await capture;
      if (actual.width != width || actual.height != height) {
        throw StateError('Actual readback dimensions changed');
      }
      final diff =
          _compare(await _rgba(actual), await _rgba(reference), width, height);
      final item = <String, Object?>{
        'index': index,
        'paintTimelineUs': paint,
        'originalFrameByPart': frameIndex,
        'actualPixels': [actual.width, actual.height],
        'actualColorSpace': actual.colorSpace.name,
        'referenceColorSpace': reference.colorSpace.name,
        'geometry': geometries,
        ...diff,
        'floatReadback': await _floatCompare(actual, reference),
        'referencePaint': {'isAntiAlias': true},
        'antiAliasControl': {
          'referenceIsAntiAlias': false,
          'scope': 'Same original image, geometry, clip, filter and background; '
              'only Paint.isAntiAlias differs; original reference is retained',
          'actualVsControl': _compare(await _rgba(actual),
              await _rgba(noAntiAliasReference), width, height),
          'defaultReferenceVsControl': _compare(await _rgba(reference),
              await _rgba(noAntiAliasReference), width, height),
          'actualVsControlFloat':
              await _floatCompare(actual, noAntiAliasReference),
        },
      };
      if (diff['differentPixels'] != 0) {
        final root = p.join(widget.storage.root, 'artifacts');
        await widget.storage.checkPath(root);
        await Directory(root).create(recursive: true);
        final prefix =
            '${widget.identity.split(':').first}-${widget.layout}-${widget.mode.name}-$index';
        final artifacts = <String, String>{};
        for (final pair in [('actual', actual), ('reference', reference)]) {
          final png = await pair.$2.toByteData(format: ui.ImageByteFormat.png);
          if (png == null) continue;
          final path = p.join(root, '$prefix-${pair.$1}.png');
          await File(path).writeAsBytes(
              png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
          artifacts[pair.$1] = path;
        }
        item['artifacts'] = artifacts;
      }
      while (frames.length <= index) {
        frames.add(<String, Object?>{});
      }
      frames[index] = item;
      recorded.add(index);
      _maybeFinish();
    } finally {
      for (final image in images.values) {
        image.dispose();
      }
      actual?.dispose();
      reference?.dispose();
      noAntiAliasReference?.dispose();
    }
  }

  @override
  void dispose() {
    watch?.cancel();
    WidgetsBinding.instance.removeTimingsCallback(_onTimings);
    unawaited(subscription?.cancel());
    controller.dispose();
    scroll.dispose();
    changes.dispose();
    for (final image in previousImages.values) {
      image.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: Colors.black,
      body: Center(
          child: SizedBox(
              width: width / dpr,
              height: height / dpr,
              child: ImagePipeline022ReadbackBoundary(
                  key: boundary,
                  child: ColoredBox(
                      color: Colors.black,
                      child: _PaintObserver(
                          key: paintObserver,
                          onPaint: _paint,
                          child: SizedBox.expand(
                              key: viewport,
                              child: LayoutBuilder(
                                  builder: (_, c) => _reader(c)))))))));
}

class _PaintObserver extends SingleChildRenderObjectWidget {
  const _PaintObserver(
      {super.key, required this.onPaint, required super.child});
  final VoidCallback onPaint;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ObservedRender(onPaint);
  @override
  void updateRenderObject(BuildContext context, _ObservedRender renderObject) {
    renderObject.onPaint = onPaint;
  }
}

class _ObservedRender extends RenderProxyBox {
  _ObservedRender(this.onPaint);
  VoidCallback onPaint;
  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onPaint();
  }
}

Future<Uint8List> _rgba(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) throw StateError('RGBA readback unavailable');
  return Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
}

Map<String, Object?> _compare(
    Uint8List actual, Uint8List expected, int width, int height) {
  if (actual.length != expected.length || actual.length != width * height * 4) {
    throw StateError('RGBA dimensions differ');
  }
  var different = 0;
  final maxDelta = List<int>.filled(4, 0), sums = List<int>.filled(4, 0);
  final first = <Map<String, Object>>[];
  for (var i = 0; i < width * height; i++) {
    var mismatch = false;
    for (var c = 0; c < 4; c++) {
      final delta = (actual[i * 4 + c] - expected[i * 4 + c]).abs();
      maxDelta[c] = math.max(maxDelta[c], delta);
      sums[c] += delta;
      mismatch |= delta != 0;
    }
    if (mismatch) {
      different++;
      if (first.length < 12) {
        first.add({
          'xy': [i % width, i ~/ width],
          'actual': actual.sublist(i * 4, i * 4 + 4),
          'reference': expected.sublist(i * 4, i * 4 + 4)
        });
      }
    }
  }
  return {
    'comparedPixels': width * height,
    'differentPixels': different,
    'maxChannelDifferenceRGBA': maxDelta,
    'sumAbsoluteChannelDifferenceRGBA': sums,
    'firstDifferentPixels': first,
    'thresholdApplied': false
  };
}

Future<Map<String, Object?>> _floatCompare(
    ui.Image actual, ui.Image expected) async {
  try {
    final a =
        await actual.toByteData(format: ui.ImageByteFormat.rawExtendedRgba128);
    final b = await expected.toByteData(
        format: ui.ImageByteFormat.rawExtendedRgba128);
    if (a == null || b == null || a.lengthInBytes != b.lengthInBytes) {
      return {'available': false};
    }
    var different = 0, outOfSrgb = 0;
    final maximum = List<double>.filled(4, 0);
    for (var i = 0; i < a.lengthInBytes ~/ 4; i++) {
      final x = a.getFloat32(i * 4, Endian.host),
          y = b.getFloat32(i * 4, Endian.host);
      final delta = (x - y).abs();
      if (delta != 0) different++;
      maximum[i % 4] = math.max(maximum[i % 4], delta);
      if (i % 4 < 3 && (y < 0 || y > 1)) outOfSrgb++;
    }
    return {
      'available': true,
      'differentComponents': different,
      'maximumAbsoluteDifferenceRGBA': maximum,
      'referenceOutOfSrgbComponents': outOfSrgb,
      'thresholdApplied': false,
      'scope': 'Canvas readback; not OS display gamut'
    };
  } catch (error) {
    return {'available': false, 'error': '$error'};
  }
}
