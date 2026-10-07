import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show FrameTiming, FramePhase;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/archive/backends/dart_zip_backend.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart' as native;

/// A separate debug/profile entrypoint. It only creates its own temporary
/// fixture/cache/report and does not initialise or change the user's library.
class _CoverOptions {
  _CoverOptions(List<String> arguments) {
    for (final argument in arguments) {
      final value = argument.replaceFirst(RegExp(r'^--'), '');
      final separator = value.indexOf('=');
      if (separator > 0) {
        values[value.substring(0, separator)] = value.substring(separator + 1);
      }
    }
  }
  final values = <String, String>{};
  String? get source =>
      values['source'] ?? values['fixture'] ?? values['fixtures'];
  String? get fixtureName => values['fixture-name'];
  int get memberIndex =>
      (int.tryParse(values['member-index'] ?? '') ?? 0).clamp(0, 10000);
  int get requestedWidth =>
      (int.tryParse(values['requested-width'] ?? '') ?? 384).clamp(1, 4096);
  int get samples =>
      (int.tryParse(values['samples'] ?? '') ?? 30).clamp(1, 1000);
  double get logicalWidth =>
      (double.tryParse(values['logical-width'] ?? '') ?? 128).clamp(1, 1024);
  double get logicalHeight =>
      (double.tryParse(values['logical-height'] ?? '') ?? 128).clamp(1, 1024);
  int? get physicalWidth =>
      int.tryParse(values['physical-width'] ?? values['physical'] ?? '')
          ?.clamp(1, 1024);
  int? get physicalHeight =>
      int.tryParse(values['physical-height'] ?? values['physical'] ?? '')
          ?.clamp(1, 1024);
  String get label =>
      values['label'] ??
      (source == null ? 'generated4096-fixed384' : 'external-task-copy');
  bool get quality => values['quality'] == 'true' || values['quality'] == '1';
  bool get nativeEncodedFit =>
      values['native-encoded-fit'] == 'true' ||
      values['native-encoded-fit'] == '1';
  String get baselineMode =>
      source == null ? 'baselineFull4K' : 'baselineOriginal';
  String get coldMode => 'optimizedCold$requestedWidth';
  String get warmMode => 'optimizedWarm$requestedWidth';
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kReleaseMode) {
    throw StateError('Cover verification supports debug/profile only');
  }
  final configured = List<String>.of(arguments);
  if (Platform.isAndroid && configured.isEmpty) {
    final optionsFile =
        File('/data/local/tmp/picakeep-native-022/cover-profile-options.json');
    if (await optionsFile.exists()) {
      final values =
          jsonDecode(await optionsFile.readAsString()) as Map<String, dynamic>;
      configured.addAll(
          values.entries.map((entry) => '--${entry.key}=${entry.value}'));
    }
  }
  final options = _CoverOptions(configured);
  if (Platform.isAndroid) {
    await const MethodChannel('lingxue.picakeep/keepScreenOn')
        .invokeMethod<void>('set');
  }
  if (Platform.isWindows) await windowManager.ensureInitialized();
  runApp(MaterialApp(home: _CoverBenchmark(options: options)));
  if (Platform.isWindows) {
    await windowManager.waitUntilReadyToShow(
        WindowOptions(
            title: 'PicaKeep 022 cover profile',
            size: options.physicalWidth != null || options.logicalWidth > 400
                ? const Size(1100, 1100)
                : const Size(640, 480),
            center: true), () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
}

class _CoverBenchmark extends StatefulWidget {
  const _CoverBenchmark({required this.options});
  final _CoverOptions options;
  @override
  State<_CoverBenchmark> createState() => _CoverBenchmarkState();
}

class _CoverBenchmarkState extends State<_CoverBenchmark> {
  ImageProvider<Object>? _provider;
  Completer<Map<String, int>>? _presented;
  int _started = 0, _paintEligible = 0, _paintFrameVsyncMicros = 0;
  int _serial = 0;
  String _status = 'Preparing identical 4096 × 4096 cover fixture';
  final _samples = <Map<String, Object>>[];
  final _timingDiagnostics = <Map<String, int>>[];
  final _configuration = <String, Object?>{};
  int _decodedWidth = 0, _decodedHeight = 0;
  int _sourceWidth = 0, _sourceHeight = 0;
  final _cardBoundary = GlobalKey();
  bool _qualityCapture = false;
  File? _externalInput;
  FileStat? _externalBefore;
  String? _externalBeforeSha;
  late Directory _workspace;
  _CoverOptions get options => widget.options;
  double get _dpr => MediaQuery.devicePixelRatioOf(context);
  double get _cardWidth => options.physicalWidth == null
      ? options.logicalWidth
      : options.physicalWidth! / _dpr;
  double get _cardHeight => options.physicalHeight == null
      ? options.logicalHeight
      : options.physicalHeight! / _dpr;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    final presented = _presented;
    if (presented == null || presented.isCompleted || _paintEligible == 0) {
      return;
    }
    for (final timing in timings) {
      final rasterFinish =
          timing.timestampInMicroseconds(FramePhase.rasterFinish);
      final buildStart = timing.timestampInMicroseconds(FramePhase.buildStart);
      final buildFinish =
          timing.timestampInMicroseconds(FramePhase.buildFinish);
      if (_timingDiagnostics.length < 20) {
        _timingDiagnostics.add({
          'requestTimeline': _started,
          'imageBuildTimeline': _paintEligible,
          'currentSystemFrame': _paintFrameVsyncMicros,
          'frameVsync': timing.timestampInMicroseconds(FramePhase.vsyncStart),
          'frameBuildStart': buildStart,
          'frameBuildFinish': buildFinish,
          'frameRasterFinish': rasterFinish
        });
      }
      // Image.frameBuilder runs within this exact build interval. The engine
      // frame timestamps and currentSystemFrame need not share an epoch.
      if (_paintEligible < buildStart || _paintEligible > buildFinish) {
        continue;
      }
      final elapsed = rasterFinish - _started;
      if (elapsed <= 0 || elapsed > 30000000) {
        presented.completeError(
            StateError('Frame/timeline clocks cannot be compared'));
      } else {
        presented.complete({
          'requestTimelineUs': _started,
          'imageBuildTimelineUs': _paintEligible,
          'frameBuildStartUs': buildStart,
          'frameBuildFinishUs': buildFinish,
          'frameRasterStartUs':
              timing.timestampInMicroseconds(FramePhase.rasterStart),
          'frameRasterFinishUs': rasterFinish,
          'firstPresentedUs': elapsed,
          'buildUs': timing.buildDuration.inMicroseconds,
          'rasterUs': timing.rasterDuration.inMicroseconds
        });
      }
      return;
    }
  }

  Future<void> _run() async {
    try {
      // ignore: avoid_print
      print('PICAKEEP_COVER_022_START ${jsonEncode({
            'platform': Platform.operatingSystem,
            'timeline': developer.Timeline.now
          })}');
      if (Platform.isWindows) {
        final root = Directory(r'E:\picakeep-image-pipeline-022-cover-profile');
        await root.create(recursive: true);
        _workspace = await root.createTemp('run-');
      } else {
        _workspace =
            await Directory.systemTemp.createTemp('pk022-cover-profile-');
      }
      App.dataPath = p.join(_workspace.path, 'app');
      App.cachePath = p.join(_workspace.path, 'cache');
      late File source;
      if (options.source != null) {
        var path = options.source!;
        if (await FileSystemEntity.isDirectory(path)) {
          if (options.fixtureName == null) {
            throw ArgumentError('Directory fixtures requires fixture-name');
          }
          path = p.join(path, options.fixtureName!);
        }
        _externalInput = File(path);
        _externalBefore = await _externalInput!.stat();
        if (_externalBefore!.type != FileSystemEntityType.file ||
            _externalBefore!.size <= 0 ||
            _externalBefore!.size > 512 << 20) {
          throw StateError('Input missing or exceeds 512 MiB task copy cap');
        }
        _externalBeforeSha = await _digest(_externalInput!);
        if (path.toLowerCase().endsWith('.zip') ||
            path.toLowerCase().endsWith('.cbz')) {
          final backend = DartZipBackend();
          final index = await backend.openIndex(path);
          final members = index.imageEntries;
          if (options.memberIndex >= members.length) {
            throw StateError('Image member index unavailable');
          }
          final member = members[options.memberIndex];
          if (member.isEncrypted) {
            throw StateError('Cover input encrypted; no password configured');
          }
          source = File(p.join(
              _workspace.path, 'input-member${p.extension(member.path)}'));
          await backend.materializeEntry(path, member.path, source,
              maxBytes: 64 << 20);
          _configuration.addAll({
            'inputKind': 'archive-image-member',
            'archiveSha256': _externalBeforeSha,
            'archiveBytes': _externalBefore!.size,
            'memberIndex': options.memberIndex,
            'memberBytes': member.size,
            'memberNameSha256':
                sha256.convert(utf8.encode(member.path)).toString(),
            'archiveCopyMethod':
                'DartZipBackend bounded streaming/CRC materialization'
          });
        } else {
          source = File(
              p.join(_workspace.path, 'input-original${p.extension(path)}'));
          await _externalInput!.copy(source.path);
          if (await _digest(source) != _externalBeforeSha) {
            throw StateError('Source copy hash differs');
          }
          _configuration['inputKind'] = 'read-only-external-file-copied';
        }
        _configuration.addAll({
          'externalInputBytes': _externalBefore!.size,
          'externalInputSha256Before': _externalBeforeSha,
          'externalSourceCopiedBeforeStamping': true
        });
      } else {
        source = File(p.join(_workspace.path, 'identical-4k.png'));
        final encoded = await Isolate.run(() {
          final image = img.Image(width: 4096, height: 4096);
          for (var y = 0; y < image.height; y++) {
            for (var x = 0; x < image.width; x++) {
              image.setPixelRgb(x, y, x % 256, y % 256, (x + y) % 256);
            }
          }
          return img.encodePng(image, level: 3);
        });
        await source.writeAsBytes(encoded, flush: true);
        _configuration['inputKind'] = 'generated-identical4096';
      }
      final nativeAvailable = native.PicakeepImageEngine.isAvailable;
      final sourceSha256 =
          (await sha256.bind(source.openRead()).first).toString();
      native.ImageMetadata? metadata;
      String? metadataError;
      if (nativeAvailable) {
        try {
          metadata =
              await const native.PicakeepImageEngine().probe(source.path);
        } catch (error) {
          metadataError = '$error';
        }
      }
      if (metadata != null) {
        _sourceWidth = metadata.width;
        _sourceHeight = metadata.height;
      } else {
        final buffer = await ui.ImmutableBuffer.fromFilePath(source.path);
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        _sourceWidth = descriptor.width;
        _sourceHeight = descriptor.height;
        descriptor.dispose();
        buffer.dispose();
      }
      // The baseline and the optional independent reference decode originals.
      // This cover tool must not create a whole 96MP Flutter image by accident.
      if (_sourceWidth * _sourceHeight * 4 > 64 << 20) {
        throw StateError(
            'Full original cover baseline exceeds bounded 64 MiB RGBA limit');
      }
      _configuration.addAll({
        'platform': Platform.operatingSystem,
        'coverNativeThresholdBytes': CoverThumbnailCache.nativeThresholdBytes,
        'nativeEncodedFitCandidate': options.nativeEncodedFit,
        'coverUnsupportedPlatformThresholdBytes':
            CoverThumbnailCache.fallbackThresholdBytes,
        'coverDerivativeAlgorithm': CoverThumbnailCache.derivativeAlgorithm,
        'requestedCoverWidth': options.requestedWidth,
        'modeNamesReferToRequestedWidth': true,
        'label': options.label,
        'qualityRequested': options.quality,
        'configuredOptions': {
          for (final option in options.values.entries)
            if (!['source', 'fixture', 'fixtures', 'fixture-name']
                .contains(option.key))
              option.key: option.value,
        },
        'nativeSupported': native.PicakeepImageEngine.isSupported,
        'nativeAvailable': nativeAvailable,
        'sourceSha256': sourceSha256,
        'nativeMetadata': metadata == null
            ? null
            : {
                'width': metadata.width,
                'height': metadata.height,
                'encodedWidth': metadata.encodedWidth,
                'encodedHeight': metadata.encodedHeight,
                'format': metadata.format,
                'orientation': metadata.orientation,
                'animated': metadata.animated,
                'bitDepth': metadata.bitDepth,
                'hasColorProfile': metadata.hasColorProfile,
                'estimatedWorkingBytes': metadata.estimatedWorkingBytes
              },
        'nativeMetadataError': metadataError,
        'cacheIsolation': 'all cache roots belong to this benchmark workspace',
        'dataRoot': App.dataPath,
        'cacheRoot': App.cachePath,
        'persistenceScheduling':
            'production consumed-provider postFrame plus next event; background encoder; UI postFrame does not prove GPU presentation',
        'quotaMaintenance':
            'production maintenance retained and may overlap timed frames',
        'qualityScope': options.source == null
            ? 'identical gradient/periodic color edges; no claim of artwork visual acceptance'
            : 'explicit task copy of actual source; exact pixel differences are evidence, not automatic subjective acceptance'
      });
      // Configuration probe and file hash are outside every measured sample.
      // ignore: avoid_print
      print('PICAKEEP_COVER_022_CONFIG ${jsonEncode(_configuration)}');
      if (!mounted) throw StateError('Cover benchmark was unmounted');
      final viewport = MediaQuery.sizeOf(context);
      if (_cardWidth > viewport.width || _cardHeight + 80 > viewport.height) {
        throw StateError(
            'Requested card does not fit available benchmark viewport');
      }
      // Warm engine/shader/IO once; this sample is intentionally excluded.
      await _sample(source, 'baselineWarmup', -1);
      for (var index = 0; index < options.samples; index++) {
        await _sample(source, options.baselineMode, index);
        // New source stamp forces a truly cold derivative key while keeping
        // the encoded image and visible pixels identical across all samples.
        await source
            .setLastModified(DateTime.now().add(Duration(seconds: index + 1)));
        await _sample(source, options.coldMode, index);
        // ignore: invalid_use_of_visible_for_testing_member
        await CoverThumbnailCache.waitForProviderPersistenceForTesting();
        await _sample(source, options.warmMode, index);
      }
      Map<String, Object?>? quality;
      if (options.quality) {
        try {
          quality = await _quality(source);
        } catch (error, stack) {
          quality = {
            'error': '$error',
            'stack': '$stack',
            'thresholdApplied': false
          };
        }
      }
      final externalUnchanged = await _verifyExternalSource();
      final report = <String, Object?>{
        'schema': 5,
        ..._configuration,
        'mode': const bool.fromEnvironment('dart.vm.product')
            ? 'invalid-release'
            : const bool.fromEnvironment('dart.vm.profile')
                ? 'profile'
                : 'debug',
        'measurement':
            'engine rasterFinish after first image paint; compositor display is not measured',
        'sourceWidth': _sourceWidth,
        'sourceHeight': _sourceHeight,
        'sourceBytes': await source.length(),
        'logicalCard': [_cardWidth, _cardHeight],
        'devicePixelRatio':
            mounted ? MediaQuery.devicePixelRatioOf(context) : 0,
        'physicalCardPixels':
            mounted ? [_cardWidth * _dpr, _cardHeight * _dpr] : [0, 0],
        'samplesPerMode': options.samples,
        'externalSourceUnchanged': externalUnchanged,
        'quality': quality,
        'firstPaintWaitsForPersistence': false,
        'modeRecordsAreRequestedWidthsNotDecodedDimensions': true,
        'summary': {
          for (final mode in [
            options.baselineMode,
            options.coldMode,
            options.warmMode
          ])
            mode: _summary(mode)
        },
        'samples': _samples,
        'timingDiagnostics': _timingDiagnostics,
      };
      final destination = File(
          p.join(_workspace.path, 'cover-profile-${options.samples}.json'));
      await destination.writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
          flush: true);
      developer.log(jsonEncode(report), name: 'PicaKeepCover022');
      // stdout stays visible in a profile runner / Android logcat.
      // ignore: avoid_print
      print('PICAKEEP_COVER_022 ${jsonEncode({
            'summary': report['summary'],
            'reportPath': destination.path
          })}');
      if (mounted) {
        setState(() {
          _provider = null;
          _status =
              'Completed ${options.samples} samples per mode\n${destination.path}';
        });
      }
    } catch (error, stack) {
      developer.log('Cover benchmark failed',
          name: 'PicaKeepCover022', error: error, stackTrace: stack);
      final reportPath = p.join(_workspace.path, 'cover-profile-failed.json');
      await File(reportPath).writeAsString(jsonEncode({
        'error': '$error',
        'stack': '$stack',
        'configuration': _configuration,
        'samples': _samples,
        'timingDiagnostics': _timingDiagnostics
      }));
      // ignore: avoid_print
      print('PICAKEEP_COVER_022_FAILED ${jsonEncode({
            'error': '$error',
            'stack': '$stack',
            'reportPath': reportPath,
            'timingDiagnostics': _timingDiagnostics
          })}');
      if (mounted) setState(() => _status = 'Benchmark failed: $error');
    } finally {
      try {
        await _verifyExternalSource();
      } catch (error) {
        print('PICAKEEP_COVER_022_INPUT_VERIFY_FAILED $error');
      }
      if (Platform.isAndroid) {
        await const MethodChannel('lingxue.picakeep/keepScreenOn')
            .invokeMethod<void>('cancel');
      }
    }
  }

  Map<String, Object> _summary(String mode) {
    final sorted = _samples
        .where((sample) => sample['mode'] == mode)
        .map((sample) => sample['firstPresentedUs'] as int)
        .toList()
      ..sort();
    return {
      'count': sorted.length,
      'p50Us': sorted[(sorted.length * .5).ceil() - 1],
      'p95Us': sorted[(sorted.length * .95).ceil() - 1]
    };
  }

  Future<void> _sample(File source, String mode, int index) async {
    // ignore: invalid_use_of_visible_for_testing_member
    await CoverThumbnailCache.waitForProviderPersistenceForTesting();
    if (!mounted) return;
    setState(() {
      _provider = null;
      _serial++;
      _status = '$mode ${index + 1}/${options.samples}';
    });
    await WidgetsBinding.instance.endOfFrame;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    final rssBefore = ProcessInfo.currentRss;
    _paintEligible = 0;
    _decodedWidth = 0;
    _decodedHeight = 0;
    final presented = _presented = Completer<Map<String, int>>();
    final trace = CoverThumbnailTrace();
    _started = developer.Timeline.now;
    final provider = mode.startsWith('baseline')
        ? FileImage(source)
        : await CoverThumbnailCache.prepareProvider(
            source.path, options.requestedWidth,
            canContinue: () => mounted,
            nativeEncodedFit: options.nativeEncodedFit,
            trace: trace);
    final providerReadyUs = developer.Timeline.now - _started;
    if (provider == null) throw StateError('Cover provider was not prepared');
    setState(() => _provider = provider);
    final metrics = await presented.future.timeout(const Duration(seconds: 30));
    _presented = null;
    if (!mounted) throw StateError('Benchmark was unmounted during sample');
    if (index >= 0) {
      _samples.add({
        'mode': mode,
        'sample': index,
        ...metrics,
        'decodedWidth': _decodedWidth,
        'decodedHeight': _decodedHeight,
        'physicalCardPixels': [_cardWidth * _dpr, _cardHeight * _dpr],
        'displayedPhysicalImagePixels':
            _physicalFit(_decodedWidth, _decodedHeight),
        'displayUpscaleFactor': _upscale(_decodedWidth, _decodedHeight),
        'displayNeedsUpscale': _upscale(_decodedWidth, _decodedHeight) > 1,
        'providerReadyUs': providerReadyUs,
        'coverDetails': Map<String, Object>.of(trace.details),
        'stagesObservedAtRasterTiming':
            List<Map<String, Object>>.of(trace.stages),
        'rssBeforeBytes': rssBefore,
        'rssAfterBytes': ProcessInfo.currentRss,
        'processPeakRssBytes': ProcessInfo.maxRss
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = _buildCard(context);
    return Scaffold(
        body: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
      _qualityCapture
          ? RepaintBoundary(
              key: _cardBoundary,
              child: ColoredBox(color: Colors.black, child: card))
          : card,
      const SizedBox(height: 16),
      Text(_status, textAlign: TextAlign.center)
    ])));
  }

  Widget _buildCard(BuildContext context) => SizedBox(
      width: _cardWidth,
      height: _cardHeight,
      child: _provider == null
          ? const SizedBox.shrink()
          : Image(
              key: ValueKey(_serial),
              image: _provider!,
              fit: BoxFit.contain,
              frameBuilder: (context, child, frame, synchronous) {
                if (frame != null && _paintEligible == 0) {
                  Widget current = child;
                  // Image's default Semantics surrounds RawImage before
                  // invoking frameBuilder. Keep normal semantics/raster.
                  while (current is SingleChildRenderObjectWidget &&
                      current.child != null) {
                    current = current.child!;
                  }
                  if (current is! RawImage || current.image == null) {
                    _presented?.completeError(
                        StateError('Presented image dimensions missing'));
                    return child;
                  }
                  _decodedWidth = current.image!.width;
                  _decodedHeight = current.image!.height;
                  _paintEligible = developer.Timeline.now;
                  _paintFrameVsyncMicros = WidgetsBinding
                      .instance.currentSystemFrameTimeStamp.inMicroseconds;
                }
                return child;
              },
              errorBuilder: (context, error, stack) {
                if (_presented?.isCompleted == false) {
                  _presented!.completeError(error, stack);
                }
                return const Text('Image error');
              }));

  List<double> _physicalFit(int width, int height) {
    final fitting = applyBoxFit(
        BoxFit.contain,
        Size(width.toDouble(), height.toDouble()),
        Size(_cardWidth * _dpr, _cardHeight * _dpr));
    return [fitting.destination.width, fitting.destination.height];
  }

  double _upscale(int width, int height) {
    if (width <= 0 || height <= 0) return 0;
    final fit = _physicalFit(width, height);
    return math.max(fit[0] / width, fit[1] / height);
  }

  Future<String> _digest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<bool?> _verifyExternalSource() async {
    final external = _externalInput;
    final before = _externalBefore;
    final digest = _externalBeforeSha;
    if (external == null || before == null || digest == null) return null;
    final after = await external.stat();
    final afterSha = await _digest(external);
    final unchanged = before.size == after.size &&
        before.modified == after.modified &&
        digest == afterSha;
    _configuration.addAll({
      'externalInputSha256After': afterSha,
      'externalInputSizeAfter': after.size,
      'externalInputMtimeUnchanged': before.modified == after.modified
    });
    if (!unchanged) {
      throw StateError('External source changed during benchmark');
    }
    return true;
  }

  Future<Map<String, Object?>> _quality(File source) async {
    final report = <String, Object?>{
      'thresholdApplied': false,
      'measurement':
          'actual cover widget readback after matched raster frame; performance samples unaffected',
      'reference':
          'independent Flutter full original codec, original dimensions -> Canvas contain/center/FilterQuality.low on black',
      'candidate':
          'production prepared cover provider -> Image contain/center/default low on black',
      'sourceSha256': await _digest(source),
      'colorScope': 'rawRgba8 engine readback; not wide-gamut/HDR preservation',
      'originalReferenceRgbaLimitBytes': 64 << 20,
      'artifactScope': 'task-only reduced cover images, no original export',
    };
    if (_sourceWidth * _sourceHeight * 4 > 64 << 20) {
      report['error'] =
          'Full original reference exceeds bounded 64 MiB RGBA limit';
      return report;
    }
    final physicalWidth = (_cardWidth * _dpr).ceil();
    final physicalHeight = (_cardHeight * _dpr).ceil();
    if (physicalWidth > 1024 || physicalHeight > 1024) {
      report['error'] = 'Quality capture exceeds 1024 physical pixels per axis';
      return report;
    }
    _qualityCapture = true;
    await _sample(source, 'qualityWarm${options.requestedWidth}', -1);
    final render = _cardBoundary.currentContext?.findRenderObject();
    if (render is! RenderRepaintBoundary) {
      throw StateError('Cover quality boundary absent');
    }
    final candidate = await render.toImage(pixelRatio: _dpr);
    ui.Image? original;
    ui.Image? reference;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(source.path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      codec = await descriptor.instantiateCodec();
      original = (await codec.getNextFrame()).image;
      final target =
          Size(candidate.width.toDouble(), candidate.height.toDouble());
      final fitted = applyBoxFit(BoxFit.contain,
          Size(original.width.toDouble(), original.height.toDouble()), target);
      final destination =
          Alignment.center.inscribe(fitted.destination, Offset.zero & target);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(Colors.black, BlendMode.src);
      canvas.drawImageRect(
          original,
          Rect.fromLTWH(
              0, 0, original.width.toDouble(), original.height.toDouble()),
          destination,
          Paint()..filterQuality = FilterQuality.low);
      final picture = recorder.endRecording();
      try {
        reference = await picture.toImage(candidate.width, candidate.height);
      } finally {
        picture.dispose();
      }
      final actual = await _rgba(candidate);
      final expected = await _rgba(reference);
      final maxChannel = List.filled(4, 0);
      var differentPixels = 0, differentChannels = 0;
      var absoluteDifference = 0;
      var candidateEdges = 0, referenceEdges = 0;
      final first = <Map<String, Object?>>[];
      for (var pixel = 0; pixel < candidate.width * candidate.height; pixel++) {
        final offset = pixel * 4;
        var different = false;
        for (var c = 0; c < 4; c++) {
          final delta = (actual[offset + c] - expected[offset + c]).abs();
          maxChannel[c] = math.max(maxChannel[c], delta);
          absoluteDifference += delta;
          if (delta != 0) {
            differentChannels++;
            different = true;
          }
        }
        if (different) {
          differentPixels++;
          if (first.length < 16) {
            first.add({
              'x': pixel % candidate.width,
              'y': pixel ~/ candidate.width,
              'actual': actual.sublist(offset, offset + 4),
              'reference': expected.sublist(offset, offset + 4)
            });
          }
        }
        if (pixel % candidate.width > 0) {
          for (var c = 0; c < 3; c++) {
            candidateEdges +=
                (actual[offset + c] - actual[offset - 4 + c]).abs();
            referenceEdges +=
                (expected[offset + c] - expected[offset - 4 + c]).abs();
          }
        }
        if (pixel >= candidate.width) {
          for (var c = 0; c < 3; c++) {
            candidateEdges +=
                (actual[offset + c] - actual[offset - candidate.width * 4 + c])
                    .abs();
            referenceEdges += (expected[offset + c] -
                    expected[offset - candidate.width * 4 + c])
                .abs();
          }
        }
      }
      report.addAll({
        'capturePixels': [candidate.width, candidate.height],
        'referenceOriginalPixels': [original.width, original.height],
        'preparedCoverPixels': [_decodedWidth, _decodedHeight],
        'physicalCardPixels': [_cardWidth * _dpr, _cardHeight * _dpr],
        'displayUpscaleFactor': _upscale(_decodedWidth, _decodedHeight),
        'displayNeedsUpscale': _upscale(_decodedWidth, _decodedHeight) > 1,
        'differentPixels': differentPixels,
        'differentChannels': differentChannels,
        'maxChannelDifferenceRGBA': maxChannel,
        'sumAbsoluteChannelDifference': absoluteDifference,
        'edgeMagnitudeRGBAdjacentPixels': {
          'candidate': candidateEdges,
          'reference': referenceEdges
        },
        'edgeMetricInterpretation':
            'diagnostic only; no acceptance tolerance or assumption that larger magnitude is sharper',
        'firstDifferentPixels': first
      });
      final artifacts = <String, String>{};
      for (final image in [('actual', candidate), ('reference', reference)]) {
        final png = await image.$2.toByteData(format: ui.ImageByteFormat.png);
        if (png == null) throw StateError('Cover artifact PNG unavailable');
        final destination =
            File(p.join(_workspace.path, 'cover-quality-${image.$1}.png'));
        await destination.writeAsBytes(
            png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
        artifacts[image.$1] = destination.path;
      }
      report['artifacts'] = artifacts;
      return report;
    } finally {
      candidate.dispose();
      reference?.dispose();
      original?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
      _qualityCapture = false;
    }
  }

  Future<Uint8List> _rgba(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) throw StateError('Cover RGBA readback unavailable');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}
