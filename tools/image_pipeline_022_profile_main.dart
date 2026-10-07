// Independent debug/profile benchmark entrypoint. This does not load the
// application's settings, library, account, download state, or history.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FramePhase;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:path/path.dart' as path;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_cache.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep/pages/reader/reader_page_image.dart';
import 'package:window_manager/window_manager.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

import 'image_pipeline_022_pixel_checks.dart';
import 'image_pipeline_022_original_export_checks.dart';
import 'image_pipeline_022_privileged_copy_checks.dart';
import 'image_pipeline_022_surface_quality_checks.dart';
import 'image_pipeline_022_texture_capacity_checks.dart';

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

class _Options {
  _Options(List<String> arguments) {
    for (final argument in arguments) {
      final value = argument.replaceFirst(RegExp(r'^--'), '');
      final split = value.indexOf('=');
      if (split > 0) {
        _values[value.substring(0, split)] = value.substring(split + 1);
      }
    }
  }
  final _values = <String, String>{};
  String get fixtureRoot =>
      _values['fixtures'] ??
      _values['fixture_root'] ??
      (Platform.isAndroid
          ? '/data/local/tmp/picakeep-native-022'
          : Platform.isWindows
              ? r'E:\picakeep-image-pipeline-022-fixtures'
              : 'docs/verification/image-pipeline-022/native-fixtures');
  String? get baseline => _values['baseline'];
  String? get large => _values['large'];
  String? get output => _values['output'] ?? _values['output_json'];
  String? get work => _values['work'];
  int get samples =>
      (int.tryParse(_values['samples'] ?? _values['sampleCount'] ?? '') ?? 30)
          .clamp(1, 1000);
  int get tilePixels =>
      (int.tryParse(_values['tile-pixels'] ?? '') ?? 512).clamp(128, 2048);
  bool get adaptiveNativeTiles => _values['adaptive-native-tiles'] == 'true';
  bool get preparedCover => _values['prepared-cover'] == 'true';
  bool get cachedCoverPreview => _values['cached-cover-preview'] == 'true';
  bool get fullOrdinaryImage => _values['ordinary-full'] == 'true';
  bool get viewportRegion => _values['viewport-region'] == 'true';
  bool get boundedPngFit => _values['bounded-png-fit'] == 'true';
  bool get rawSync => _values['raw-sync'] == 'true';
  bool get persistRaster => _values['persist-raster'] != 'false';
  bool get preparedRead => _values['prepared-read'] == 'true';
  bool get preparedAdmission => _values['prepared-admission'] == 'true';
  bool get nativeLargeFit => _values['native-large-fit'] == 'true';
  bool get earlyOriginalRaster => _values['early-original-raster'] == 'true';
  int _boundedOption(String name, int maximum) =>
      (int.tryParse(_values[name] ?? '') ?? 0).clamp(0, maximum);
  int get lifecycleWarmupCycles =>
      _boundedOption('lifecycle-warmup-cycles', 10);
  int get lifecycleBaselineSeconds =>
      _boundedOption('lifecycle-baseline-seconds', 60);
  int get lifecycleExitIdleSeconds =>
      _boundedOption('lifecycle-exit-idle-seconds', 30);
  int get lifecycleTailSeconds => _boundedOption('lifecycle-tail-seconds', 60);
  Set<String> get groups =>
      (_values['groups'] ?? 'quality,baseline,fit,roi,lifecycle')
          .split(',')
          .toSet();
  Set<String> get cacheModes =>
      (_values['cache-mode'] ?? _values['cache_mode'] ?? 'cold,warm')
          .split(',')
          .toSet();
  Set<String> get layouts =>
      (_values['layouts'] ?? 'single,continuous,double').split(',').toSet();
  Set<String> get modes =>
      (_values['modes'] ?? 'sharpFirst,previewFirst').split(',').toSet();
  List<String> get formatFixtures => (_values['format-fixtures'] ??
          '640x960.png,640x960-alpha.png,3000x4000-alpha.png,'
              '640x960-chroma-420.jpg,640x960-progressive.jpg,'
              '640x960-orientation-1.jpg,640x960-orientation-2.jpg,'
              '640x960-orientation-3.jpg,640x960-orientation-4.jpg,'
              '640x960-orientation-5.jpg,640x960-orientation-6.jpg,'
              '640x960-orientation-7.jpg,640x960-orientation-8.jpg,'
              '8000x12000.png,8000x12000-baseline.jpg,'
              '8000x12000-progressive.jpg,8000x12000-lossless.webp,'
              '8000x12000-lossy.webp,8000x12000-interlaced.png,'
              '800x30000.png,800x30000-baseline.jpg,'
              '800x30000-progressive.jpg')
      .split(',');
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kReleaseMode) {
    throw StateError('This benchmark supports debug/profile only');
  }
  final taskArguments = List<String>.of(arguments);
  if (Platform.isAndroid && taskArguments.isEmpty) {
    final configuration =
        File('/data/local/tmp/picakeep-native-022/profile-options.json');
    if (await configuration.exists()) {
      final values = jsonDecode(await configuration.readAsString())
          as Map<String, dynamic>;
      taskArguments.addAll(values.entries.map((entry) =>
          '--${entry.key}=${entry.value is List ? (entry.value as List).join(',') : entry.value}'));
    }
  }
  final options = _Options(taskArguments);
  final runId = DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp(r'[^0-9A-Za-z]'), '-');
  final defaultWork = Platform.isWindows
      ? r'E:\picakeep-image-pipeline-022-runtime'
      : '${(await getApplicationSupportDirectory()).path}/image-pipeline-022-profile';
  final taskDirectory = Directory('${options.work ?? defaultWork}/$runId');
  final taskCache = Platform.isAndroid
      ? Directory(
          '${(await getApplicationCacheDirectory()).path}/image-pipeline-022-profile/$runId')
      : Directory('${taskDirectory.path}/cache');
  await taskDirectory.create(recursive: true);
  await taskCache.create(recursive: true);
  // Assign each late-final once, before constructing any source/backend.
  // App.init intentionally uses the normal application cache; this isolated
  // entrypoint reserves a task-only cache on the selected verification disk.
  App.dataPath = taskDirectory.absolute.path;
  App.cachePath = taskCache.absolute.path;
  await _keepBenchmarkScreenOn(true);
  if (Platform.isWindows) await windowManager.ensureInitialized();
  runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: _Benchmark(options: options, runId: runId)));
  if (Platform.isWindows) {
    unawaited(windowManager.waitUntilReadyToShow().then((_) async {
      await windowManager.setTitle('PicaKeep 022 reader profile');
      await windowManager.show();
    }));
  }
}

class _Fixture {
  _Fixture(this.file, this.metadata, this.stat);
  final File file;
  final ReaderRasterMetadata metadata;
  final FileStat stat;
  Map<String, Object?> toJson() => {
        'path': file.path,
        'bytes': stat.size,
        'width': metadata.size.width,
        'height': metadata.size.height,
        'format': metadata.format,
        'bitDepth': metadata.bitDepth,
        'hasColorProfile': metadata.hasColorProfile,
        'animated': metadata.animated
      };
}

class _Configuration {
  _Configuration(this.generation, this.fixture, this.layout, this.mode,
      {this.baseline = false, this.cacheMode = 'cold', this.cachedCover});
  final int generation;
  final _Fixture fixture;
  final String layout;
  final ReaderDisplayMode mode;
  final bool baseline;
  final String cacheMode;
  final ImageProvider<Object>? cachedCover;
}

class _Presentation {
  _Presentation(this.parts,
      {this.native = false, this.density, this.previousSourceRect});
  final Set<String> parts;
  final bool native;
  final double? density;
  final Rect? previousSourceRect;
  final completer = Completer<Map<String, ReaderPresentedFrame>>();
  final frames = <String, ReaderPresentedFrame>{};
  final firstRasters = <String, ({int build, int postFrame})>{};
  int? presentedTimelineUs;
  int? frameBuildTimelineUs;
}

class _Interval {
  _Interval(this.sample, this.startTimelineUs, this.endTimelineUs,
      this.frameBuildTimelineUs);
  final Map<String, Object?> sample;
  final int startTimelineUs;
  final int endTimelineUs;
  final int frameBuildTimelineUs;
}

class _Benchmark extends StatefulWidget {
  const _Benchmark({required this.options, required this.runId});
  final _Options options;
  final String runId;
  @override
  State<_Benchmark> createState() => _BenchmarkState();
}

class _BenchmarkState extends State<_Benchmark> {
  final _viewport = GlobalKey();
  final _changes = ValueNotifier<int>(0);
  final _timings = <FrameTiming>[];
  final _intervals = <_Interval>[];
  final _samples = <Map<String, Object?>>[];
  final _errors = <Map<String, Object?>>[];
  final _lifecycle = <Map<String, Object?>>[];
  final _lifecyclePhases = <Map<String, Object?>>[];
  final _backings = <String>{};
  final _fixtures = <String, _Fixture>{};
  final _pageKeys = <String, GlobalKey>{};
  Map<String, Object?>? _pixelChecks;
  Map<String, Object?>? _originalExportChecks;
  Map<String, Object?>? _privilegedCopyChecks;
  Map<String, Object?>? _surfaceQualityChecks;
  Map<String, Object?>? _textureCapacityChecks;
  int _verifiedTextureEdgeLowerBound = 0;
  final _formatWorkflowChecks = <Map<String, Object?>>[];
  final _formatNativeSteps = <Map<String, Object?>>[];
  final _diskSpaceChecks = <Map<String, Object?>>[];
  PhotoViewController? _controller;
  ScrollController? _scroll;
  StreamSubscription<PhotoViewControllerValue>? _subscription;
  _Configuration? _configuration;
  _Presentation? _presentation;
  ReaderPresentedFrame? _lastFrame;
  int _generation = 0;
  double? _nativeScale;
  String _status = '正在检查真实基准图片';
  bool _done = false;
  int _timingDiagnostics = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_captureTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  void _captureTimings(List<FrameTiming> frames) {
    _timings.addAll(frames);
    for (final frame in frames) {
      if (_timingDiagnostics++ < 20) {
        print('PICAKEEP_022_CLOCK ${jsonEncode({
              'timelineNow': developer.Timeline.now,
              'buildStart':
                  frame.timestampInMicroseconds(FramePhase.buildStart),
              'buildFinish':
                  frame.timestampInMicroseconds(FramePhase.buildFinish),
              'rasterFinish':
                  frame.timestampInMicroseconds(FramePhase.rasterFinish)
            })}');
      }
    }
  }

  void _statusText(String status) {
    if (mounted) setState(() => _status = status);
    print('PICAKEEP_022_PROGRESS $status');
  }

  Future<_Fixture?> _findFixture(
      {required bool large, String? explicit}) async {
    final root = Directory(widget.options.fixtureRoot);
    final candidates = <File>[];
    if (explicit != null) {
      final direct = File(explicit);
      candidates
          .add(await direct.exists() ? direct : File('${root.path}/$explicit'));
    } else if (await root.exists()) {
      await for (final entry in root.list(followLinks: false)) {
        if (entry is File &&
            RegExp(r'\.(png|jpe?g|webp)$', caseSensitive: false)
                .hasMatch(entry.path)) {
          candidates.add(entry);
        }
      }
      // Prefer PNG so the baseline and tiled renderer share the exact file.
      candidates.sort((a, b) {
        final ap = a.path.toLowerCase().endsWith('.png') ? 0 : 1;
        final bp = b.path.toLowerCase().endsWith('.png') ? 0 : 1;
        return ap != bp ? ap.compareTo(bp) : a.path.compareTo(b.path);
      });
    }
    for (final file in candidates) {
      try {
        final metadata = await const NativeReaderRasterBackend().probe(file);
        final matches = large
            ? metadata.size == const Size(8000, 12000)
            : metadata.size == const Size(3000, 4000);
        if (matches || explicit != null) {
          final fixture = _Fixture(file, metadata, await file.stat());
          _fixtures[large ? 'large' : 'baseline'] = fixture;
          return fixture;
        }
      } catch (error) {
        _errors.add(
            {'stage': 'probe', 'path': file.path, 'error': error.toString()});
      }
    }
    _errors.add({
      'stage': 'fixture',
      'kind': large ? '8000x12000' : '3000x4000',
      'error':
          'No readable matching original; this group is skipped, not counted as a successful sample'
    });
    return null;
  }

  ReaderPageSource _source(_Configuration configuration, String part) {
    final fixture = configuration.fixture;
    final identity = ReaderPageIdentity(
        sourceKey: 'image-profile-022',
        workId: configuration.cacheMode == 'warm'
            ? '${widget.runId}:diskWarm:$part'
            : '${widget.runId}:${configuration.generation}:$part',
        downloadId: 'isolated-profile',
        episode: 1,
        page: part == 'right' ? 1 : 0,
        sourceVersion:
            '${fixture.file.path}:${fixture.stat.size}:${fixture.stat.modified.millisecondsSinceEpoch}');
    final hash = sha256.convert(utf8.encode(identity.stableKey));
    _backings.add('${App.cachePath}/image_pipeline/native_backing/$hash.rgba');
    return FileReaderPageSource(
        identity: identity,
        file: fixture.file,
        byteLength: fixture.stat.size,
        modifiedMillis: fixture.stat.modified.millisecondsSinceEpoch,
        width: fixture.metadata.size.width.toInt(),
        height: fixture.metadata.size.height.toInt());
  }

  void _presented(int generation, String part, ReaderPresentedFrame frame) {
    if (_configuration?.generation != generation || !frame.complete) return;
    if (part == 'left') _lastFrame = frame;
    final waiting = _presentation;
    if (waiting == null ||
        waiting.completer.isCompleted ||
        !waiting.parts.contains(part)) {
      return;
    }
    if (waiting.native && !frame.nativePixels) return;
    if (waiting.previousSourceRect == frame.sourceRect) return;
    if (waiting.density != null &&
        (frame.density - waiting.density!).abs() > .00001) {
      return;
    }
    waiting.frames[part] = frame;
    if (waiting.parts.every(waiting.frames.containsKey)) {
      waiting.presentedTimelineUs = developer.Timeline.now;
      waiting.frameBuildTimelineUs = frame.frameBuildTimelineUs;
      waiting.completer.complete(Map.of(waiting.frames));
    }
  }

  void _firstRasterPresented(int generation, String part, int build) {
    if (_configuration?.generation != generation) return;
    final waiting = _presentation;
    if (waiting == null || !waiting.parts.contains(part)) return;
    waiting.firstRasters.putIfAbsent(
        part, () => (build: build, postFrame: developer.Timeline.now));
  }

  Widget _page(_Configuration configuration, String part,
          {PhotoViewController? controller,
          double? continuousWidth,
          Alignment alignment = Alignment.center}) =>
      ReaderPageImage(
        key: _pageKeys.putIfAbsent('${configuration.generation}:$part',
            () => GlobalKey(debugLabel: 'profile-original-$part')),
        resourceKey: '${configuration.generation}:$part',
        loadSource: () async => _source(configuration, part),
        tilePixels: widget.options.adaptiveNativeTiles
            ? null
            : widget.options.tilePixels,
        fullOrdinaryImage: widget.options.fullOrdinaryImage,
        viewportRegion: widget.options.viewportRegion,
        boundedPngFit: widget.options.boundedPngFit,
        textureEdgeLowerBound: _verifiedTextureEdgeLowerBound,
        preferRawSync: widget.options.rawSync,
        preferPreparedRead: widget.options.preparedRead,
        preparedReadAdmission: widget.options.preparedAdmission,
        persistRaster: widget.options.persistRaster,
        nativeLargeFit: widget.options.nativeLargeFit,
        earlyOriginalRaster: widget.options.earlyOriginalRaster,
        loadCachedPreview: configuration.cachedCover == null ||
                !widget.options.cachedCoverPreview
            ? null
            : (original) => CoverThumbnailCache.cloneCachedReaderPreview(
                configuration.cachedCover!,
                original: original.file,
                snapshot: original.fileSnapshot,
                originalSize: original.metadata.size),
        viewportKey: _viewport,
        transformChanges: _changes,
        mode: configuration.mode,
        controller: controller,
        continuousWidth: continuousWidth,
        alignment: alignment,
        onPresented: (frame) =>
            _presented(configuration.generation, part, frame),
        onFirstRasterPresented: (build) =>
            _firstRasterPresented(configuration.generation, part, build),
        nativeScaleChanged: (scale) {
          _nativeScale = configuration.layout == 'double'
              ? math.max(_nativeScale ?? 0, scale)
              : scale;
        },
      );

  Widget _reader(_Configuration configuration) =>
      LayoutBuilder(builder: (context, constraints) {
        if (configuration.baseline) {
          return Image.file(configuration.fixture.file,
              fit: BoxFit.contain, filterQuality: FilterQuality.medium,
              errorBuilder: (context, error, stack) {
            final waiting = _presentation;
            if (waiting != null && !waiting.completer.isCompleted) {
              waiting.completer.completeError(error, stack);
            }
            return Center(child: Text(error.toString(), maxLines: 3));
          }, frameBuilder: (context, child, frame, synchronouslyLoaded) {
            if (frame != null) {
              final frameBuildTimelineUs = developer.Timeline.now;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted &&
                    _configuration?.generation == configuration.generation) {
                  _presented(
                      configuration.generation,
                      'left',
                      ReaderPresentedFrame(
                          sourceRect:
                              Offset.zero & configuration.fixture.metadata.size,
                          density: 1,
                          complete: true,
                          nativePixels: true,
                          frameBuildTimelineUs: frameBuildTimelineUs));
                }
              });
            }
            return child;
          });
        }
        if (configuration.layout == 'continuous') {
          return PhotoView.customChild(
              controller: _controller,
              childSize: constraints.biggest,
              minScale: 1.0,
              initialScale: 1.0,
              maxScale: 64.0,
              strictScale: true,
              child: SingleChildScrollView(
                  controller: _scroll,
                  child: _page(configuration, 'left',
                      continuousWidth: constraints.maxWidth)));
        }
        if (configuration.layout == 'double') {
          return PhotoViewGallery.builder(
              itemCount: 1,
              backgroundDecoration: const BoxDecoration(color: Colors.black),
              builder: (_, index) => PhotoViewGalleryPageOptions.customChild(
                  controller: _controller,
                  childSize: constraints.biggest,
                  minScale: 1.0,
                  initialScale: 1.0,
                  maxScale: 64.0,
                  child: Row(children: [
                    Expanded(
                        child: _page(configuration, 'left',
                            alignment: Alignment.centerRight)),
                    Expanded(
                        child: _page(configuration, 'right',
                            alignment: Alignment.centerLeft)),
                  ])));
        }
        return _page(configuration, 'left', controller: _controller);
      });

  Map<String, Object?> _diagnostics() => {
        'surfaces': ReaderSurfaceDiagnostics.snapshot(),
        'processCurrentRss': ProcessInfo.currentRss,
        'processPeakRss': ProcessInfo.maxRss,
        'residentBytes': ReaderSurfaceDiagnostics.residentBytes,
        'activeSurfaces': ReaderSurfaceDiagnostics.activeSurfaces,
        'activeJobs': ImageWorkScheduler.shared.activeCount,
        'queuedAndRunningJobs': ImageWorkScheduler.shared.pendingCount,
        'reservedWorkingBytes': ImageWorkScheduler.shared.reservedBytes,
        'reservedTemporaryBytes': ImageTemporaryPool.shared.reservedBytes,
        'originalFileLeases': ReaderPageFileLease.activeLeaseCount,
        'pendingRasterCacheBytes': ReaderRasterCache.pendingBytes,
        'nativeWorkers': PicakeepImageEngine.workerDiagnostics,
        'diskQuota': {
          'activeBytes': ImageDiskQuota.shared.activeBytes,
          'idleBytes': ImageDiskQuota.shared.idleBytes,
          'pendingClaims': ImageDiskQuota.shared.pendingCount,
          'pendingOperations': ImageDiskQuota.shared.pendingOperations,
          'rejectedCount': ImageDiskQuota.shared.rejectedCount,
          'lastRejection': ImageDiskQuota.shared.lastRejection,
        },
      };

  Future<void> _quiesce() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (ReaderSurfaceDiagnostics.activeSurfaces != 0 ||
        ImageWorkScheduler.shared.hasWork ||
        ReaderPageFileLease.activeLeaseCount != 0 ||
        ReaderSurfaceDiagnostics.residentBytes != 0 ||
        ImageTemporaryPool.shared.reservedBytes != 0 ||
        ImageDiskQuota.shared.pendingCount != 0 ||
        ImageDiskQuota.shared.pendingOperations != 0) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
            'Reader did not release resources after exit: ${jsonEncode(_diagnostics())}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> _close({bool clearOwnBacking = true}) async {
    _presentation = null;
    if (mounted) setState(() => _configuration = null);
    SchedulerBinding.instance.ensureVisualUpdate();
    await WidgetsBinding.instance.endOfFrame;
    await _subscription?.cancel();
    _subscription = null;
    _controller?.dispose();
    _controller = null;
    _scroll?.dispose();
    _scroll = null;
    _lastFrame = null;
    _pageKeys.clear();
    // Persisting a completed raster may retain a clone and source lease until
    // its actual encoder/write finishes, after the visible surface is gone.
    await ReaderRasterCache.drain();
    await _quiesce();
    await ImageDiskQuota.shared.drain();
    if (clearOwnBacking) {
      // Only paths derived from this isolated run's immutable identities are
      // eligible. User originals and every other cache entry remain untouched.
      for (final path in _backings.toList()) {
        final directory = File(path).parent;
        if (!await directory.exists()) continue;
        final prefix = File(path).uri.pathSegments.last;
        await for (final entry in directory.list(followLinks: false)) {
          if (entry is File && entry.uri.pathSegments.last.startsWith(prefix)) {
            await entry.delete();
          }
        }
        _backings.remove(path);
      }
      final cacheRoot = Directory(path.join(
          App.dataPath, 'cache', 'image_pipeline_v1', 'local_reader'));
      final taskRoot = path.normalize(path.absolute(App.dataPath));
      final cachePath = path.normalize(cacheRoot.absolute.path);
      if (!path.isWithin(taskRoot, cachePath)) {
        throw StateError('Refusing to clear cache outside the isolated task');
      }
      // All surface/native/persist leases are drained. Clear reader levels AND
      // tiles, so the next cold generation cannot silently load a warm PNG.
      if (await cacheRoot.exists()) await cacheRoot.delete(recursive: true);
      await ImageDiskQuota.shared.refresh();
    }
  }

  void _install(_Fixture fixture, String layout, ReaderDisplayMode mode,
      {bool baseline = false,
      String cacheMode = 'cold',
      ImageProvider<Object>? cachedCover}) {
    _controller = PhotoViewController();
    _scroll = ScrollController()..addListener(() => _changes.value++);
    _subscription =
        _controller!.outputStateStream.listen((_) => _changes.value++);
    _nativeScale = null;
    setState(() => _configuration = _Configuration(
        ++_generation, fixture, layout, mode,
        baseline: baseline, cacheMode: cacheMode, cachedCover: cachedCover));
  }

  Future<ImageProvider<Object>> _prepareDisplayedCover(_Fixture fixture) async {
    final provider = await CoverThumbnailCache.prepareProvider(
        fixture.file.path, 768,
        canContinue: () => mounted);
    if (provider == null) throw StateError('Cover preparation failed');
    final stream = provider.resolve(ImageConfiguration.empty);
    final ready = Completer<void>();
    final listener = ImageStreamListener((info, _) {
      info.dispose();
      if (!ready.isCompleted) ready.complete();
    }, onError: (Object error, StackTrace? stack) {
      if (!ready.isCompleted) ready.completeError(error, stack);
    });
    stream.addListener(listener);
    try {
      await ready.future.timeout(const Duration(seconds: 120));
      return provider;
    } finally {
      stream.removeListener(listener);
    }
  }

  Future<Map<String, ReaderPresentedFrame>> _waitForFrame() =>
      _presentation!.completer.future.timeout(const Duration(seconds: 120));

  Future<void> _fit(
      _Fixture fixture, String layout, ReaderDisplayMode mode, int index,
      {bool baseline = false,
      bool measure = true,
      String cacheMode = 'cold'}) async {
    await _close(clearOwnBacking: cacheMode == 'cold');
    if (baseline) await FileImage(fixture.file).evict();
    final cachedCover = !baseline && widget.options.preparedCover
        ? await _prepareDisplayedCover(fixture)
        : null;
    final description =
        '${baseline ? 'baseline_full' : 'surface_fit_${cacheMode == 'warm' ? 'diskWarm' : 'cold'}'}:$layout:${mode.name}:$index';
    _statusText(description);
    ReaderRasterDiagnostics.drainSamples();
    _presentation = _Presentation(
        !baseline && layout == 'double' ? {'left', 'right'} : {'left'});
    final watch = Stopwatch()..start();
    final requestedAt = developer.Timeline.now;
    _install(fixture, layout, mode,
        baseline: baseline, cacheMode: cacheMode, cachedCover: cachedCover);
    try {
      final frames = await _waitForFrame();
      watch.stop();
      final postFrameAt = _presentation!.presentedTimelineUs!;
      final frameBuildAt = _presentation!.frameBuildTimelineUs;
      if (frameBuildAt == null) {
        throw StateError('The presented frame has no build timestamp');
      }
      final sample = <String, Object?>{
        'group': baseline
            ? 'baseline_full'
            : 'surface_fit_${cacheMode == 'warm' ? 'diskWarm' : 'cold'}',
        'layout': layout,
        'mode': mode.name,
        'index': index,
        'elapsedMs': watch.elapsedMicroseconds / 1000,
        'requestTimelineUs': requestedAt,
        'postFrameTimelineUs': postFrameAt,
        'frameBuildTimelineUs': frameBuildAt,
        'cacheMode': baseline ? 'engineDecodedCold' : cacheMode,
        'preparedCover': cachedCover != null,
        'cachedCoverPreview': widget.options.cachedCoverPreview,
        'cacheState': baseline
            ? 'Flutter decoded image evicted; OS file cache uncontrolled'
            : cacheMode == 'warm'
                ? 'UI rasters disposed; same-source native backing and lossless reader levels/tiles retained after an unmeasured warmup; OS file cache uncontrolled'
                : 'UI rasters disposed; all task-owned reader levels/tiles and recorded native backings deleted after pending writes and source leases drained; OS file cache uncontrolled',
        'sourceBytes': fixture.stat.size,
        'originalWidth': fixture.metadata.size.width,
        'originalHeight': fixture.metadata.size.height,
        'presented':
            frames.map((key, frame) => MapEntry(key, _frameJson(frame))),
        'diagnostics': _diagnostics()
      };
      sample['rasterStages'] = ReaderRasterDiagnostics.drainSamples();
      if (measure) {
        _samples.add(sample);
        final interval =
            _Interval(sample, requestedAt, postFrameAt, frameBuildAt);
        _intervals.add(interval);
        await _ensureRasterMatch(interval);
        if (!baseline) {
          final firstRasters = <String, Map<String, Object?>>{};
          sample['firstRasterByPart'] = firstRasters;
          for (final part in _presentation!.parts) {
            final first = _presentation!.firstRasters[part];
            if (first == null) {
              throw StateError('No first-raster callback for $part');
            }
            final firstSample = <String, Object?>{
              'requestTimelineUs': requestedAt,
              'frameBuildTimelineUs': first.build,
              'postFrameTimelineUs': first.postFrame,
              'postFrameMs': (first.postFrame - requestedAt) / 1000,
              'meaning':
                  'First visible raster, possibly a partial tile or cached cover; not complete original coverage',
            };
            firstRasters[part] = firstSample;
            final firstInterval = _Interval(
                firstSample, requestedAt, first.postFrame, first.build);
            _intervals.add(firstInterval);
            await _ensureRasterMatch(firstInterval);
          }
        }
      }
    } catch (error) {
      print('PICAKEEP_022_ERROR ${jsonEncode({
            'stage': description,
            'error': error.toString(),
            'diagnostics': _diagnostics()
          })}');
      _errors.add({
        'stage': description,
        'elapsedMs': watch.elapsedMicroseconds / 1000,
        'error': error.toString(),
        'diagnostics': _diagnostics()
      });
      rethrow;
    } finally {
      _presentation = null;
    }
  }

  Map<String, Object> _frameJson(ReaderPresentedFrame frame) => {
        'density': frame.density,
        'complete': frame.complete,
        'nativePixels': frame.nativePixels,
        'sourceRect': [
          frame.sourceRect.left,
          frame.sourceRect.top,
          frame.sourceRect.right,
          frame.sourceRect.bottom
        ],
      };

  bool _targetIsVisible(
      Offset target, Map<String, ReaderPresentedFrame> frames) {
    final frame = frames['left'];
    return frame != null &&
        frame.complete &&
        frame.nativePixels &&
        frame.sourceRect.contains(target);
  }

  Future<Map<String, ReaderPresentedFrame>> _panToTarget(
      Offset target, double dpr,
      {bool visibleTargetAcceptance = false}) async {
    // The complete tile region is clipped to the original. Its centre is not
    // the viewport focus near image edges or between the two page surfaces.
    for (var correction = 0; correction < 4; correction++) {
      final previous = _lastFrame;
      if (previous == null) {
        throw StateError('Native pixel frame was not presented');
      }
      if (visibleTargetAcceptance &&
          _targetIsVisible(target, {
            'left': previous,
          })) {
        return Map.of(_presentation!.frames);
      }
      final geometry = _panGeometry(target);
      if (!visibleTargetAcceptance &&
          (geometry.sourceCentre - target).distance <= 2) {
        return Map.of(_presentation!.frames);
      }
      _presentation = _Presentation({'left'},
          native: true, previousSourceRect: previous.sourceRect);
      print('PICAKEEP_022_ROI_TRACE ${jsonEncode({
            'phase': 'pan-request',
            'correction': correction,
            'sourceRect': _frameJson(previous)['sourceRect'],
            'sourceCentre': [
              geometry.sourceCentre.dx,
              geometry.sourceCentre.dy
            ],
            'target': [target.dx, target.dy],
            'controllerScale': _controller!.scale,
            'controllerPosition': [
              _controller!.position.dx,
              _controller!.position.dy
            ],
            'nativeScale': _nativeScale,
            'dpr': dpr
          })}');
      _controller!.updateMultiple(
          scale: _nativeScale,
          position: _controller!.position +
              geometry.viewportCentreGlobal -
              geometry.targetGlobal);
      print('PICAKEEP_022_ROI_TRACE ${jsonEncode({
            'phase': 'pan-controller-immediate',
            'controllerPosition': [
              _controller!.position.dx,
              _controller!.position.dy
            ],
            'controllerScale': _controller!.scale,
            'target': [target.dx, target.dy]
          })}');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _configuration != null) {
          _tracePanGeometry(target);
        }
      });
      final frames = await _waitForFrame();
      print('PICAKEEP_022_ROI_TRACE ${jsonEncode({
            'phase': 'pan-completed',
            'correction': correction,
            'presented': _frameJson(frames['left']!),
            'target': [target.dx, target.dy]
          })}');
      final frameBuild = _presentation!.frameBuildTimelineUs;
      if (frameBuild == null ||
          frameBuild < (previous.frameBuildTimelineUs ?? 0)) {
        throw StateError('A stale pan frame was returned for a newer request');
      }
      if ((visibleTargetAcceptance && _targetIsVisible(target, frames)) ||
          (!visibleTargetAcceptance &&
              (_panGeometry(target).sourceCentre - target).distance <= 2)) {
        return frames;
      }
    }
    throw StateError(visibleTargetAcceptance
        ? 'Native pan did not make the requested source point visible: '
            '${jsonEncode([target.dx, target.dy])}'
        : 'Native pan did not reach the requested source centre within two pixels: '
            '${jsonEncode([
                _panGeometry(target).sourceCentre.dx,
                _panGeometry(target).sourceCentre.dy
              ])}, requested ${jsonEncode([target.dx, target.dy])}');
  }

  RenderBox _sourceRender() {
    RenderBox? sourceRender;
    void findSurface(Element element) {
      if (element.widget is ReaderImageSurface) {
        final render = element.findRenderObject();
        if (render is RenderBox) sourceRender = render;
        return;
      }
      element.visitChildElements(findSurface);
    }

    final pageContext =
        _pageKeys['${_configuration!.generation}:left']?.currentContext;
    if (pageContext is Element) findSurface(pageContext);
    final source = sourceRender;
    if (source == null) {
      throw StateError('Original image surface is not mounted');
    }
    return source;
  }

  ({Offset sourceCentre, Offset viewportCentreGlobal, Offset targetGlobal})
      _panGeometry(Offset target) {
    final source = _sourceRender();
    final viewport = _viewport.currentContext!.findRenderObject()! as RenderBox;
    final originalSize = _configuration!.fixture.metadata.size;
    final fitted = applyBoxFit(BoxFit.contain, originalSize, source.size);
    final alignment = _configuration!.layout == 'double'
        ? Alignment.centerRight
        : Alignment.center;
    final destination =
        alignment.inscribe(fitted.destination, Offset.zero & source.size);
    final sourceRect =
        alignment.inscribe(fitted.source, Offset.zero & originalSize);
    final viewportCentreGlobal =
        viewport.localToGlobal(viewport.size.center(Offset.zero));
    final localCentre = source.globalToLocal(viewportCentreGlobal);
    Offset toSource(Offset local) => Offset(
        sourceRect.left +
            (local.dx - destination.left) *
                sourceRect.width /
                destination.width,
        sourceRect.top +
            (local.dy - destination.top) *
                sourceRect.height /
                destination.height);
    final targetLocal = Offset(
        destination.left +
            (target.dx - sourceRect.left) *
                destination.width /
                sourceRect.width,
        destination.top +
            (target.dy - sourceRect.top) *
                destination.height /
                sourceRect.height);
    return (
      sourceCentre: toSource(localCentre),
      viewportCentreGlobal: viewportCentreGlobal,
      targetGlobal: source.localToGlobal(targetLocal)
    );
  }

  void _tracePanGeometry(Offset target) {
    final source = _sourceRender();
    final centre = _panGeometry(target).sourceCentre;
    print('PICAKEEP_022_ROI_TRACE ${jsonEncode({
          'phase': 'pan-post-frame-readonly',
          'controllerPosition': [
            _controller!.position.dx,
            _controller!.position.dy
          ],
          'controllerScale': _controller!.scale,
          'renderTransform': source.getTransformTo(null).storage.toList(),
          'surfaces': ReaderSurfaceDiagnostics.snapshot(),
          'renderSize': [source.size.width, source.size.height],
          'viewportCentreOriginalPixel': [centre.dx, centre.dy],
          'target': [target.dx, target.dy]
        })}');
  }

  Future<void> _roi(_Fixture fixture, String layout, ReaderDisplayMode mode,
      {bool prepareBacking = false,
      bool formatWorkflow = false,
      bool oneStep = false}) async {
    await _close();
    await _fit(fixture, layout, mode, -1, measure: false, cacheMode: 'warm');
    if (prepareBacking) {
      for (final part in layout == 'double' ? ['left', 'right'] : ['left']) {
        final source = _source(_configuration!, part);
        final hash = sha256.convert(utf8.encode(source.identity.stableKey));
        final backing =
            '${App.cachePath}/image_pipeline/native_backing/$hash.rgba';
        final releaseSource = ReaderPageFileLease.acquire(fixture.file);
        final releaseBacking = DerivedImageStore.protectTemporaryPath(backing);
        try {
          await Directory(File(backing).parent.path).create(recursive: true);
          final backend = NativeReaderRasterBackend(
              preferRawSync: widget.options.rawSync,
              preferPreparedRead: widget.options.preparedRead,
              persistRaster: widget.options.persistRaster);
          _statusText('explicit-backing:estimate:$layout:${mode.name}:$part');
          final estimate = await backend
              .estimateBackingWorkingBytes(fixture.file, backingPath: backing);
          _statusText('explicit-backing:submit:$layout:${mode.name}:$part');
          final ticket = ImageWorkScheduler.shared.submit<void>(
              key: 'profile-explicit-backing:$backing',
              priority: ImageWorkPriority.visible,
              estimatedBytes: estimate,
              run: (cancel) => backend.prepareBacking(fixture.file,
                  backingPath: backing,
                  memoryBudgetBytes: estimate,
                  cancelled: cancel.cancelled));
          await ticket.future;
          _statusText('explicit-backing:ready:$layout:${mode.name}:$part');
        } finally {
          releaseSource();
          releaseBacking();
          // The visible reader still holds the fixture's resolved-file lease;
          // awaiting this temporary source here would wait on that same lease
          // until _close(), which only runs after this group. This source owns
          // no materialized file, so releasing the two explicit holds is the
          // complete cleanup for this probe.
        }
      }
    }
    if (_nativeScale == null) {
      throw StateError('Native pixel scale was not registered');
    }
    if (!mounted) return;
    final dpr = View.of(context).devicePixelRatio;
    final viewportSize =
        (_viewport.currentContext!.findRenderObject()! as RenderBox).size;
    // Source-edge targets can be visible while PhotoView legitimately clamps
    // their viewport focus. Only format checks accept that visible point.
    final visibleTargetAcceptance = formatWorkflow;
    final fitScale = _controller!.scale ??
        (layout == 'single'
            ? math.min(viewportSize.width / fixture.metadata.size.width,
                viewportSize.height / fixture.metadata.size.height)
            : 1.0);
    final fitDensity = _lastFrame!.density;
    for (var i = 0; i < widget.options.samples; i++) {
      if (i > 0 && !formatWorkflow) {
        _presentation = _Presentation({'left'}, density: fitDensity);
        _controller!.updateMultiple(scale: fitScale, position: Offset.zero);
        await _waitForFrame();
      }
      final target = Offset(
          fixture.metadata.size.width * (0.15 + (i % 6) * 0.14),
          fixture.metadata.size.height * (0.12 + ((i ~/ 6) % 5) * 0.19));
      if (layout == 'continuous') {
        // PhotoView zooms the scroll viewport, not the full tall page. Place
        // the requested row in that viewport before zooming so the legitimate
        // PhotoView pan bound can reach it without accumulating edge errors.
        final source = _sourceRender();
        final desired =
            target.dy * source.size.height / fixture.metadata.size.height -
                viewportSize.height / 2;
        final offset = desired
            .clamp(_scroll!.position.minScrollExtent,
                _scroll!.position.maxScrollExtent)
            .toDouble();
        if ((_scroll!.offset - offset).abs() > 0.01) {
          _presentation = _Presentation({'left'},
              density: fitDensity, previousSourceRect: _lastFrame!.sourceRect);
          _scroll!.jumpTo(offset);
          await _waitForFrame();
        }
      }
      final group = (prepareBacking ? 'native_roi_prepared' : 'native_roi') +
          (oneStep ? '_onestep' : '');
      _statusText('$group:$layout:${mode.name}:$i');
      ReaderRasterDiagnostics.drainSamples();
      final watch = Stopwatch()..start();
      final requestedAt = developer.Timeline.now;
      final workersBefore = PicakeepImageEngine.workerDiagnostics;
      try {
        final existing = _lastFrame;
        final alreadyNative = formatWorkflow &&
            existing != null &&
            (existing.density - 1).abs() <= .00001 &&
            existing.complete &&
            existing.nativePixels;
        if (alreadyNative && _targetIsVisible(target, {'left': existing})) {
          final buildAt = existing.frameBuildTimelineUs;
          if (buildAt == null) {
            throw StateError('Existing native frame has no build timestamp');
          }
          // This frame predates the ROI request. Validate its real raster, but
          // keep it out of upgrade latency distributions and measured samples.
          final interval = _Interval({}, buildAt, buildAt, buildAt);
          await _ensureRasterMatch(interval);
          final timing = _matchingFrame(interval)!;
          final record = <String, Object?>{
            'index': i,
            'reusedExistingNativePresentation': true,
            'timedUpgrade': false,
            'matchedRealRasterFrame': true,
            'targetOriginalPixel': [target.dx, target.dy],
            'presented': _frameJson(existing),
            'frameBuildTimelineUs': buildAt,
            'presentingBuildStartUs':
                timing.timestampInMicroseconds(FramePhase.buildStart),
            'presentingBuildFinishUs':
                timing.timestampInMicroseconds(FramePhase.buildFinish),
            'presentingRasterFinishUs':
                timing.timestampInMicroseconds(FramePhase.rasterFinish),
            'complete': true,
          };
          _formatNativeSteps.add(record);
          print('PICAKEEP_022_FORMAT_NATIVE_STEP ${jsonEncode(record)}');
          continue;
        }
        // Include the real density upgrade and subsequent focused pan in each
        // sample. Disk backing remains warm after setup; decoded tile reuse is
        // a measured property of the production surface, not a fake result.
        _presentation = _Presentation({'left'}, native: true);
        print('PICAKEEP_022_ROI_TRACE ${jsonEncode({
              'phase': 'native-scale-request',
              'layout': layout,
              'mode': mode.name,
              'index': i,
              'nativeScale': _nativeScale,
              'currentScale': _controller!.scale,
              'target': [target.dx, target.dy]
            })}');
        if (oneStep) {
          final geometry = _panGeometry(target);
          final currentScale = _controller!.scale;
          if (currentScale == null || currentScale <= 0) {
            throw StateError('One-step ROI has no positive current scale');
          }
          final ratio = _nativeScale! / currentScale;
          // PhotoView scales around the viewport centre. Its position is a
          // translation after scale, so retain that translation while moving
          // this exact original point to the centre in the same controller
          // notification. Actual geometry is checked after the raster.
          final position = (_controller!.position +
                  geometry.viewportCentreGlobal -
                  geometry.targetGlobal) *
              ratio;
          _controller!.updateMultiple(scale: _nativeScale, position: position);
          await _waitForFrame();
        } else if (alreadyNative) {
          _presentation!.frames['left'] = existing;
        } else {
          _controller!.scale = _nativeScale;
          await _waitForFrame();
        }
        print('PICAKEEP_022_ROI_TRACE ${jsonEncode({
              'phase': 'native-scale-completed',
              'presented': _frameJson(_lastFrame!),
              'target': [target.dx, target.dy]
            })}');
        final frames = oneStep
            ? Map<String, ReaderPresentedFrame>.of(_presentation!.frames)
            : await _panToTarget(target, dpr,
                visibleTargetAcceptance: visibleTargetAcceptance);
        if (oneStep &&
            (_panGeometry(target).sourceCentre - target).distance > 2) {
          throw StateError('One-step ROI missed the original-pixel target: '
              '${_panGeometry(target).sourceCentre}, requested $target');
        }
        watch.stop();
        final postFrameAt = _presentation!.presentedTimelineUs!;
        final frameBuildAt = _presentation!.frameBuildTimelineUs;
        if (frameBuildAt == null) {
          throw StateError('The presented ROI has no build timestamp');
        }
        final sample = <String, Object?>{
          'group': group,
          'layout': layout,
          'mode': mode.name,
          'index': i,
          'targetTransform':
              oneStep ? 'scale-and-position-once' : 'scale-then-pan',
          'elapsedMs': watch.elapsedMicroseconds / 1000,
          'requestTimelineUs': requestedAt,
          'postFrameTimelineUs': postFrameAt,
          'frameBuildTimelineUs': frameBuildAt,
          'cacheState': prepareBacking
              ? 'both original backings explicitly prepared outside the timed sample; decoded tile reuse is measured; OS file cache uncontrolled'
              : 'source warmed by fit; first original backing build may occur inside sample; generated backing and resident tiles may be reused',
          'targetOriginalPixel': [target.dx, target.dy],
          if (formatWorkflow) 'timedDensityUpgrade': !alreadyNative,
          'viewportCentreOriginalPixel': [
            _panGeometry(target).sourceCentre.dx,
            _panGeometry(target).sourceCentre.dy
          ],
          'focusAcceptance': visibleTargetAcceptance
              ? 'target-visible-in-presented-source-rect'
              : 'viewport-source-centre-within-2px',
          'targetWithinPresentedSourceRect': _targetIsVisible(target, frames),
          'presented':
              frames.map((key, frame) => MapEntry(key, _frameJson(frame))),
          'diagnostics': _diagnostics()
        };
        final workersAfter = PicakeepImageEngine.workerDiagnostics;
        sample['nativeWorkerOperationDelta'] = {
          for (final entry in workersAfter.entries)
            if (entry.key.startsWith('jobsSubmitted') ||
                entry.key.startsWith('jobsCompleted') ||
                entry.key.startsWith('jobsFailed') ||
                entry.key.startsWith('jobsCancelledBeforeExecution') ||
                entry.key.startsWith('workerExecutionMicroseconds') ||
                entry.key.startsWith('workerQueueMicroseconds'))
              entry.key: entry.value - (workersBefore[entry.key] ?? 0),
        };
        sample['rasterStages'] = ReaderRasterDiagnostics.drainSamples();
        _samples.add(sample);
        final interval =
            _Interval(sample, requestedAt, postFrameAt, frameBuildAt);
        _intervals.add(interval);
        await _ensureRasterMatch(interval);
        if (formatWorkflow) {
          _formatNativeSteps.add({
            'index': i,
            'reusedExistingNativePresentation': false,
            'timedUpgrade': true,
            'timedDensityUpgrade': !alreadyNative,
            'matchedRealRasterFrame': true,
            'targetOriginalPixel': [target.dx, target.dy],
            'presented': _frameJson(frames['left']!),
            'frameBuildTimelineUs': frameBuildAt,
            'complete': true,
          });
        }
      } catch (error) {
        print('PICAKEEP_022_ERROR ${jsonEncode({
              'stage': '$group:$layout:${mode.name}:$i',
              'error': error.toString(),
              'lastFrame': _lastFrame == null ? null : _frameJson(_lastFrame!),
              'target': [target.dx, target.dy],
              'diagnostics': _diagnostics()
            })}');
        _errors.add({
          'stage': '$group:$layout:${mode.name}:$i',
          'error': error.toString(),
          'lastFrame': _lastFrame == null ? null : _frameJson(_lastFrame!),
          'targetOriginalPixel': [target.dx, target.dy],
          'diagnostics': _diagnostics()
        });
        rethrow;
      } finally {
        _presentation = null;
      }
    }
  }

  Future<void> _attempt(String group, Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      print('PICAKEEP_022_ERROR ${jsonEncode({
            'stage': 'group-aborted',
            'group': group,
            'error': error.toString()
          })}');
      _errors.add({
        'stage': 'group-aborted',
        'group': group,
        'error': error.toString()
      });
      await _close();
    }
  }

  Map<String, Object?> _lifecyclePhase(
      String phase, String event, String layout, ReaderDisplayMode mode,
      {int? index}) {
    final record = <String, Object?>{
      'phase': phase,
      'event': event,
      'layout': layout,
      'mode': mode.name,
      if (index != null) 'index': index,
      'utc': DateTime.now().toUtc().toIso8601String(),
      'timelineUs': developer.Timeline.now,
      'pid': pid,
      'diagnostics': _diagnostics(),
    };
    _lifecyclePhases.add(record);
    // Emit bounded fields for the external same-PID OS sampler. The full
    // diagnostics remain in JSON rather than exceeding Android's log limit.
    print('PICAKEEP_022_LIFECYCLE_PHASE ${jsonEncode({
          for (final entry in record.entries)
            if (entry.key != 'diagnostics') entry.key: entry.value,
        })}');
    return record;
  }

  Future<void> _lifecycleIdle(int seconds) async {
    // At most one second per await lets phase/status updates remain visible.
    for (var i = 0; i < seconds; i++) {
      if (!mounted) throw const ImageWorkCancelled();
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  FrameTiming? _matchingFrame(_Interval interval) {
    for (final frame in _timings) {
      if (frame.timestampInMicroseconds(FramePhase.buildStart) <=
              interval.frameBuildTimelineUs &&
          interval.frameBuildTimelineUs <=
              frame.timestampInMicroseconds(FramePhase.buildFinish)) {
        return frame;
      }
    }
    return null;
  }

  Future<void> _ensureRasterMatch(_Interval interval) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (_matchingFrame(interval) == null) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
            'No engine build interval contains the real image build Timeline timestamp '
            '${interval.frameBuildTimelineUs}; raster timing remains missing, not inferred from a nearby frame');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> _run() async {
    final started = DateTime.now().toUtc();
    try {
      if (widget.options.groups.contains('quality')) {
        _statusText('quality: 原文件像素与实际 Flutter 解码逐项对照');
        _pixelChecks =
            await runImagePipeline022PixelChecks(widget.options.fixtureRoot);
        if (_pixelChecks!['nativeAvailable'] != true) {
          _errors.add({
            'stage': 'quality',
            'severity': 'critical',
            'error': 'Native decoder unavailable; no pixel comparison occurred'
          });
        }
        for (final record
            in (_pixelChecks!['cases'] as List).cast<Map<String, Object?>>()) {
          if (record['status'] != 'measured') {
            _errors.add({
              'stage': 'quality',
              'severity': 'critical',
              'file': record['file'],
              'status': record['status'],
              'error': record['error'] ??
                  'A required original-pixel case was not measured'
            });
          }
          print('PICAKEEP_022_PIXEL_CHECK ${jsonEncode(record)}');
        }
        // Measured differences remain raw evidence. No tolerance is invented
        // here and a measured case is not an automatic quality acceptance.
        print('PICAKEEP_022_PIXEL_CHECK_SUMMARY ${jsonEncode({
              'allCasesMeasured': _pixelChecks!['allCasesMeasured'],
              'allMeasuredPixelsEqual': _pixelChecks!['allMeasuredPixelsEqual'],
              'thresholdApplied': false
            })}');
      }
      // Gallery verification creates one explicitly requested synthetic test
      // item. It is never included in the ordinary benchmark's default groups.
      if (widget.options.groups.contains('export')) {
        _statusText('export: 只核验本次合成原图导出的文件');
        _originalExportChecks = await runImagePipeline022OriginalExportChecks(
            widget.options.fixtureRoot);
        if (Platform.isAndroid &&
            _originalExportChecks!['status'] != 'measured') {
          _errors.add({
            'stage': 'export',
            'severity': 'critical',
            'status': _originalExportChecks!['status'],
            'error': _originalExportChecks!['error'] ??
                'The synthetic export did not preserve original bytes'
          });
        }
        print(
            'PICAKEEP_022_ORIGINAL_EXPORT ${jsonEncode(_originalExportChecks)}');
      }
      if (widget.options.groups.contains('source-copy')) {
        _statusText('source-copy: Android Root 原文件 stat 与受控复制');
        _privilegedCopyChecks = await runImagePipeline022PrivilegedCopyChecks(
            widget.options.fixtureRoot, App.cachePath);
        if (Platform.isAndroid &&
            !{'measured', 'rootUnavailable'}
                .contains(_privilegedCopyChecks!['status'])) {
          _errors.add({
            'stage': 'source-copy',
            'severity': 'critical',
            'status': _privilegedCopyChecks!['status'],
            'error': _privilegedCopyChecks!['error'] ??
                'The privileged source copy did not preserve original bytes'
          });
        }
        print(
            'PICAKEEP_022_PRIVILEGED_COPY ${jsonEncode(_privilegedCopyChecks)}');
      }
      for (final cacheMode in widget.options.cacheModes) {
        if (!{'cold', 'warm'}.contains(cacheMode)) {
          throw ArgumentError('cache-mode must be cold or warm: $cacheMode');
        }
      }
      if (widget.options.groups.contains('disk-space')) {
        _statusText('disk-space: 应用身份的只读容量核验');
        final missing = path.join(
            App.cachePath, 'disk-query-not-created-${widget.runId}', 'child');
        if (await Directory(missing).exists()) {
          throw StateError('Disk probe requires a nonexistent task child');
        }
        for (final target in [App.dataPath, App.cachePath, missing]) {
          final entry = <String, Object?>{'taskPath': target};
          _diskSpaceChecks.add(entry);
          try {
            final space =
                await const PicakeepImageEngine().availableDiskSpace(target);
            entry.addAll({
              'availableBytes': space.availableBytes,
              'logicalVolumeId': space.volumeId,
              'querySucceeded': true,
              'targetCreatedByQuery':
                  target == missing ? await Directory(missing).exists() : false,
            });
            if (entry['targetCreatedByQuery'] == true) {
              throw StateError('Read-only disk query created a task path');
            }
          } catch (error) {
            entry['error'] = '$error';
            _errors.add({
              'stage': 'disk-space',
              'severity': 'critical',
              'error': '$error'
            });
          }
        }
      }
      if (widget.options.groups.contains('texture-capacity') ||
          widget.options.boundedPngFit ||
          widget.options.nativeLargeFit) {
        await _close();
        if (!mounted) throw StateError('Texture capability page was closed');
        _statusText('texture-capacity: 纹理长边与端点像素探针');
        _textureCapacityChecks =
            await runImagePipeline022TextureCapacityChecks(context);
        _verifiedTextureEdgeLowerBound =
            _textureCapacityChecks!['verifiedBothAxesEdgeLowerBound'] as int? ??
                0;
      }
      if (widget.options.groups.contains('surface-quality')) {
        await _close();
        _statusText('surface-quality: 原像素画布、接缝与透明边缘');
        if (!mounted) throw StateError('Surface quality page was closed');
        _surfaceQualityChecks = await runImagePipeline022SurfaceQualityChecks(
            context, widget.options.fixtureRoot,
            preferRawSync: widget.options.rawSync,
            preferPreparedRead: widget.options.preparedRead,
            verifyPersistence:
                widget.options.groups.contains('surface-cache-quality'));
        if (_surfaceQualityChecks!['errors'] is List &&
            (_surfaceQualityChecks!['errors'] as List).isNotEmpty) {
          _errors.add({
            'stage': 'surface-quality',
            'severity': 'critical',
            'errors': _surfaceQualityChecks!['errors'],
          });
        }
      }
      if (widget.options.groups.contains('format-layouts')) {
        for (final name in widget.options.formatFixtures) {
          final fixture = await _findFixture(large: false, explicit: name);
          if (fixture == null) {
            throw StateError('Required format fixture is unavailable: $name');
          }
          if (fixture.metadata.animated) {
            throw StateError('format-layouts requires static source: $name');
          }
          final beforeSha =
              (await sha256.bind(fixture.file.openRead()).first).toString();
          for (final layout in widget.options.layouts) {
            for (final modeName in widget.options.modes) {
              final mode = ReaderDisplayMode.values
                  .firstWhere((value) => value.name == modeName);
              final firstSample = _samples.length;
              final firstNativeStep = _formatNativeSteps.length;
              final previousErrors = _errors.length;
              await _attempt('format-layouts:$name:$layout:$modeName',
                  () async {
                await _fit(fixture, layout, mode, 0);
                await _roi(fixture, layout, mode, formatWorkflow: true);
                await _close();
                final after = await fixture.file.stat();
                final afterSha =
                    (await sha256.bind(fixture.file.openRead()).first)
                        .toString();
                if (beforeSha != afterSha ||
                    fixture.stat.size != after.size ||
                    fixture.stat.modified != after.modified) {
                  throw StateError('Original fixture changed: $name');
                }
              });
              final measured = _samples.skip(firstSample).toList();
              final nativeSteps =
                  _formatNativeSteps.skip(firstNativeStep).toList();
              final fitMeasured = measured.any((sample) =>
                  (sample['group'] as String).startsWith('surface_fit_'));
              for (final sample in measured) {
                sample['fixture'] = name;
                sample['originalSha256'] = beforeSha;
                sample['group'] = 'format-layouts:${sample['group']}:$name';
              }
              _formatWorkflowChecks.add({
                'fixture': name,
                'layout': layout,
                'mode': modeName,
                'sourceSha256': beforeSha,
                'fitAndNativePanCompleted': _errors.length == previousErrors &&
                    fitMeasured &&
                    nativeSteps.length == widget.options.samples &&
                    nativeSteps.every((step) =>
                        step['complete'] == true &&
                        step['matchedRealRasterFrame'] == true),
                'nativeSteps': nativeSteps,
                'measuredSampleCount': measured.length,
                'afterExit': _diagnostics(),
                'qualityScope':
                    'Complete original-density geometry and actual raster frames; format samples accept a requested source point only when it is visible in the presented sourceRect and do not require an unreachable viewport centre near source edges; canonical ROI and prepared ROI samples retain the two-pixel viewport-centre requirement; exact painted pixel fidelity is assessed by the separate surface-quality checks',
              });
            }
          }
        }
      }
      final needsOrdinary = widget.options.groups
          .any((group) => ['baseline', 'fit', 'lifecycle'].contains(group));
      final ordinary = needsOrdinary
          ? await _findFixture(large: false, explicit: widget.options.baseline)
          : null;
      final large = widget.options.groups.any((group) => {
                'roi',
                'roi-prepared',
                'roi-onestep',
                'roi-prepared-onestep'
              }.contains(group))
          ? await _findFixture(large: true, explicit: widget.options.large)
          : null;
      if (ordinary != null && widget.options.groups.contains('baseline')) {
        await _attempt('baseline', () async {
          await _fit(ordinary, 'single', ReaderDisplayMode.sharpFirst, -1,
              baseline: true, measure: false);
          for (var i = 0; i < widget.options.samples; i++) {
            await _fit(ordinary, 'single', ReaderDisplayMode.sharpFirst, i,
                baseline: true);
          }
        });
      }
      for (final layout in widget.options.layouts) {
        for (final modeName in widget.options.modes) {
          final mode = ReaderDisplayMode.values
              .firstWhere((value) => value.name == modeName);
          if (ordinary != null && widget.options.groups.contains('fit')) {
            for (final cacheMode in widget.options.cacheModes) {
              await _attempt('fit:$cacheMode:$layout:$modeName', () async {
                await _close();
                await _fit(ordinary, layout, mode, -1,
                    measure: false, cacheMode: cacheMode);
                for (var i = 0; i < widget.options.samples; i++) {
                  await _fit(ordinary, layout, mode, i, cacheMode: cacheMode);
                }
              });
            }
          }
          if (large != null && widget.options.groups.contains('roi')) {
            await _attempt(
                'roi:$layout:$modeName', () => _roi(large, layout, mode));
          }
          if (large != null && widget.options.groups.contains('roi-prepared')) {
            await _attempt('roi-prepared:$layout:${mode.name}', () async {
              await _roi(large, layout, mode, prepareBacking: true);
            });
          }
          if (large != null && widget.options.groups.contains('roi-onestep')) {
            await _attempt('roi-onestep:$layout:${mode.name}',
                () => _roi(large, layout, mode, oneStep: true));
          }
          if (large != null &&
              widget.options.groups.contains('roi-prepared-onestep')) {
            await _attempt(
                'roi-prepared-onestep:$layout:${mode.name}',
                () => _roi(large, layout, mode,
                    prepareBacking: true, oneStep: true));
          }
          if (ordinary != null && widget.options.groups.contains('lifecycle')) {
            await _attempt('lifecycle:$layout:$modeName', () async {
              await _close();
              if (widget.options.lifecycleWarmupCycles > 0) {
                _lifecyclePhase('warmup', 'start', layout, mode);
                for (var i = 0; i < widget.options.lifecycleWarmupCycles; i++) {
                  await _fit(ordinary, layout, mode, i, measure: false);
                  await _close();
                }
                _lifecyclePhase('warmup', 'end', layout, mode);
              }
              if (widget.options.lifecycleBaselineSeconds > 0) {
                _statusText('lifecycle-baseline:$layout:$modeName');
                _lifecyclePhase('baseline-idle', 'start', layout, mode);
                await _lifecycleIdle(widget.options.lifecycleBaselineSeconds);
                _lifecyclePhase('baseline-idle', 'end', layout, mode);
              }
              _lifecyclePhase('measured-cycles', 'start', layout, mode);
              for (var i = 0; i < 10; i++) {
                final enter =
                    _lifecyclePhase('cycle', 'enter', layout, mode, index: i);
                await _fit(ordinary, layout, mode, i, measure: false);
                final before = _diagnostics();
                final watch = Stopwatch()..start();
                await _close();
                watch.stop();
                final exitMs = watch.elapsedMicroseconds / 1000;
                final exited =
                    _lifecyclePhase('cycle', 'closed', layout, mode, index: i);
                Map<String, Object?>? idleEnd;
                if (widget.options.lifecycleExitIdleSeconds > 0) {
                  _statusText('lifecycle-exit-idle:$layout:$modeName:$i');
                  await _lifecycleIdle(widget.options.lifecycleExitIdleSeconds);
                  idleEnd = _lifecyclePhase('cycle', 'idle-end', layout, mode,
                      index: i);
                }
                _lifecycle.add({
                  'layout': layout,
                  'mode': mode.name,
                  'index': i,
                  'exitMs': exitMs,
                  'enterUtc': enter['utc'],
                  'closedUtc': exited['utc'],
                  'closedTimelineUs': exited['timelineUs'],
                  'exitIdleSeconds': widget.options.lifecycleExitIdleSeconds,
                  if (idleEnd != null) 'idleEndUtc': idleEnd['utc'],
                  'beforeExit': before,
                  'afterExit': _diagnostics()
                });
              }
              _lifecyclePhase('measured-cycles', 'end', layout, mode);
              if (widget.options.lifecycleTailSeconds > 0) {
                _statusText('lifecycle-tail:$layout:$modeName');
                _lifecyclePhase('tail-idle', 'start', layout, mode);
                await _lifecycleIdle(widget.options.lifecycleTailSeconds);
                _lifecyclePhase('tail-idle', 'end', layout, mode);
              }
            });
          }
        }
      }
    } catch (error, stack) {
      _errors.add({
        'stage': 'run',
        'error': error.toString(),
        'stack': stack.toString()
      });
    } finally {
      try {
        await _close();
      } catch (error) {
        _errors.add({'stage': 'cleanup', 'error': error.toString()});
      }
      await _keepBenchmarkScreenOn(false);
      // FrameTiming batches arrive after presentation. Associate by the image
      // build's Timeline timestamp inside the engine's build interval.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final report = _report(started);
      final destination =
          File(widget.options.output ?? '${App.dataPath}/profile-results.json');
      await destination.parent.create(recursive: true);
      await destination.writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
          flush: true);
      print('PICAKEEP_022_REPORT_PATH ${destination.path}');
      print('PICAKEEP_022_REPORT_SUMMARY ${jsonEncode(report['summary'])}');
      // Emit one bounded JSON line per sample so Android's log line limit
      // cannot silently truncate the complete multi-sample report.
      for (final sample in _samples) {
        print('PICAKEEP_022_SAMPLE ${jsonEncode(sample)}');
      }
      print(
          'PICAKEEP_022_REPORT_STATUS ${_errors.isEmpty ? 'completed' : 'incomplete'}');
      if (mounted) {
        setState(() {
          _done = true;
          _status =
              '${_errors.isEmpty ? '测量完成' : '测量未全部完成'}\n${destination.path}';
        });
      }
    }
  }

  Map<String, Object?> _report(DateTime started) {
    final refreshRate = View.of(context).display.refreshRate;
    final hz = refreshRate > 0 ? refreshRate : 60.0;
    final frameBudget = 1000 / hz;
    for (final interval in _intervals) {
      final frames = _timings.where((frame) {
        final start = frame.timestampInMicroseconds(FramePhase.buildStart);
        final finish = frame.timestampInMicroseconds(FramePhase.buildFinish);
        return finish >= interval.startTimelineUs &&
            start <= interval.endTimelineUs;
      }).toList();
      interval.sample['frames'] = frames
          .map((frame) => {
                'vsyncUs': frame.timestampInMicroseconds(FramePhase.vsyncStart),
                'buildMs': frame.buildDuration.inMicroseconds / 1000,
                'rasterMs': frame.rasterDuration.inMicroseconds / 1000,
                'totalMs': frame.totalSpan.inMicroseconds / 1000,
              })
          .toList();
      final presentingFrame = _matchingFrame(interval);
      if (presentingFrame != null) {
        final finish =
            presentingFrame.timestampInMicroseconds(FramePhase.rasterFinish);
        final duration = finish - (interval.sample['requestTimelineUs'] as int);
        // Preserve a missing result if a host reports another clock epoch.
        interval.sample['rasterPresentationMs'] =
            duration >= 0 && duration < 180000000 ? duration / 1000 : null;
        interval.sample['presentingRasterFinishUs'] = finish;
      } else {
        interval.sample['rasterPresentationMs'] = null;
      }
    }
    final missingRaster = _samples
        .where((sample) => sample['rasterPresentationMs'] == null)
        .length;
    if (missingRaster > 0) {
      _errors.add({
        'stage': 'frame-timing',
        'missingSamples': missingRaster,
        'error':
            'No matching rasterFinish in the measured clock epoch; post-frame timings are retained separately'
      });
    }
    final missingFirstRaster = _samples
        .map((sample) => sample['firstRasterByPart'])
        .whereType<Map<String, Map<String, Object?>>>()
        .expand((parts) => parts.values)
        .where((sample) => sample['rasterPresentationMs'] == null)
        .length;
    if (missingFirstRaster > 0) {
      _errors.add({
        'stage': 'first-raster-frame-timing',
        'missingSamples': missingFirstRaster,
        'error': 'First-raster builds have no matching rasterFinish',
      });
    }
    final groups = <String, List<Map<String, Object?>>>{};
    for (final sample in _samples) {
      final key = '${sample['group']}:${sample['layout']}:${sample['mode']}';
      (groups[key] ??= []).add(sample);
    }
    final summary = <String, Object?>{};
    for (final group in groups.entries) {
      final milliseconds =
          group.value.map((sample) => sample['elapsedMs'] as double).toList();
      final rasterPresentation = group.value
          .map((sample) => sample['rasterPresentationMs'])
          .whereType<double>()
          .toList();
      final frames = group.value
          .expand((sample) =>
              (sample['frames'] as List).cast<Map<String, Object>>())
          .toList();
      final builds =
          frames.map((frame) => (frame['buildMs'] as num).toDouble()).toList();
      final rasters =
          frames.map((frame) => (frame['rasterMs'] as num).toDouble()).toList();
      final totals =
          frames.map((frame) => (frame['totalMs'] as num).toDouble()).toList();
      final overBudget = frames
          .where((frame) =>
              math.max((frame['buildMs'] as num).toDouble(),
                  (frame['rasterMs'] as num).toDouble()) >
              frameBudget)
          .length;
      final rasterStages = group.value
          .expand((sample) =>
              (sample['rasterStages'] as List).cast<Map<String, num>>())
          .toList();
      double stageTotal(String key) => rasterStages.fold(
          0.0, (total, sample) => total + (sample[key]?.toDouble() ?? 0));
      final nativeWall = stageTotal('nativeWorkerWallUs');
      final copy = stageTotal('immutableBufferUs');
      final create = stageTotal('uiImageCreationUs');
      summary[group.key] = {
        'samples': milliseconds.length,
        'presentationMs': _distribution(rasterPresentation),
        'postFrameMs': _distribution(milliseconds),
        'missingRasterPresentationSamples':
            milliseconds.length - rasterPresentation.length,
        'frames': frames.length,
        'buildMs': _distribution(builds),
        'rasterMs': _distribution(rasters),
        'totalMs': _distribution(totals),
        'overFrameBudgetCount': overBudget,
        'overFrameBudgetRate':
            frames.isEmpty ? null : overBudget / frames.length,
        'rasterStages': {
          'count': rasterStages.length,
          'nativeWorkerWallMs': nativeWall / 1000,
          'immutableBufferMs': copy / 1000,
          'uiImageCreationMs': create / 1000,
          'copyAndCreationRelativeToNativeWall':
              nativeWall > 0 ? (copy + create) / nativeWall : null,
          'copyAndCreationRelativeToSummedStages':
              nativeWall + copy + create > 0
                  ? (copy + create) / (nativeWall + copy + create)
                  : null,
          'interpretation':
              'UI image construction is not GPU presentation. Parallel stage sums are not elapsed critical-path time; FrameTiming separately records raster completion.'
        }
      };
    }
    return {
      'schema': 'image-pipeline-022-profile-v1',
      'runId': widget.runId,
      'startedUtc': started.toIso8601String(),
      'finishedUtc': DateTime.now().toUtc().toIso8601String(),
      'buildMode': kProfileMode ? 'profile' : 'debug',
      'platform': Platform.operatingSystem,
      'devicePixelRatio': View.of(context).devicePixelRatio,
      'refreshHz': hz,
      'refreshRateFallbackUsed': refreshRate <= 0,
      'frameBudgetMs': frameBudget,
      'requestedSamplesPerGroup': widget.options.samples,
      'tilePixels': widget.options.tilePixels,
      'adaptiveNativeTiles': widget.options.adaptiveNativeTiles,
      'preparedCover': widget.options.preparedCover,
      'cachedCoverPreview': widget.options.cachedCoverPreview,
      'fullOrdinaryImageCandidate': widget.options.fullOrdinaryImage,
      'viewportRegionCandidate': widget.options.viewportRegion,
      'boundedPngFitCandidate': widget.options.boundedPngFit,
      'rawSyncCandidate': widget.options.rawSync,
      'persistRaster': widget.options.persistRaster,
      'preparedBackingReadCandidate': widget.options.preparedRead,
      'preparedAdmissionCandidate': widget.options.preparedAdmission,
      'lifecycleWarmupCycles': widget.options.lifecycleWarmupCycles,
      'lifecycleBaselineSeconds': widget.options.lifecycleBaselineSeconds,
      'lifecycleExitIdleSeconds': widget.options.lifecycleExitIdleSeconds,
      'lifecycleTailSeconds': widget.options.lifecycleTailSeconds,
      'nativeLargeFitCandidate': widget.options.nativeLargeFit,
      'earlyOriginalRasterCandidate': widget.options.earlyOriginalRaster,
      'verifiedTextureEdgeLowerBound': _verifiedTextureEdgeLowerBound,
      'groups': widget.options.groups.toList(),
      'cacheModes': widget.options.cacheModes.toList(),
      'unmeasuredWarmupCountPerFitGroup': 1,
      'cacheDefinitions': {
        'cold':
            'New surface; original user file preserved; task-owned native backing and lossless reader level/tile caches cleared after actual work, persistence and file leases drain',
        'diskWarm':
            'New surface, same file/version and source identity; task-owned native backing and lossless reader level/tile cache retained from an unmeasured warmup',
        'OSFileCache': 'Uncontrolled in both modes',
        'baseline':
            'Full original Flutter Image.file at matching source dimensions; decoded image evicted before each generation; one unmeasured warmup'
      },
      'layouts': widget.options.layouts.toList(),
      'modes': widget.options.modes.toList(),
      'fixtures': _fixtures.map((key, value) => MapEntry(key, value.toJson())),
      'pixelChecks': _pixelChecks,
      'originalExportChecks': _originalExportChecks,
      'privilegedSourceCopyChecks': _privilegedCopyChecks,
      'surfaceQualityChecks': _surfaceQualityChecks,
      'textureCapacityChecks': _textureCapacityChecks,
      'formatWorkflowChecks': _formatWorkflowChecks,
      'diskSpaceChecks': _diskSpaceChecks,
      'pixelAcceptance':
          'Size mismatch, unavailable/unsupported decode or missing cases are critical errors. Measured channel differences are reported without an invented pass threshold and require explicit review.',
      'measurement':
          'Complete source-density callback; real image build Timeline timestamp contained in matching FrameTiming build interval; engine rasterFinish minus request Timeline time; compositor scan-out is not measured',
      'qualityBoundary':
          '1 physical pixel per source pixel. Magnification beyond native pixels cannot invent original detail.',
      'status': _errors.isEmpty ? 'completed' : 'incomplete',
      'summary': summary,
      'samples': _samples,
      'lifecycle': _lifecycle,
      'lifecyclePhases': _lifecyclePhases,
      'errors': _errors,
      'finalDiagnostics': _diagnostics()
    };
  }

  Map<String, Object?> _distribution(List<double> input) {
    if (input.isEmpty) {
      return {'count': 0, 'p50': null, 'p95': null, 'p99': null, 'max': null};
    }
    final values = List<double>.of(input)..sort();
    double percentile(double fraction) => values[
        ((values.length * fraction).ceil() - 1).clamp(0, values.length - 1)];
    return {
      'count': values.length,
      'p50': percentile(.50),
      'p95': percentile(.95),
      'p99': percentile(.99),
      'max': values.last
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
          body: SafeArea(
              child: Column(children: [
        SizedBox(
            height: 74,
            child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(children: [
                  Expanded(child: Text(_status, maxLines: 3)),
                  if (!_done)
                    const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                ]))),
        Expanded(
            child: SizedBox(
                key: _viewport,
                width: double.infinity,
                child: ColoredBox(
                    color: Colors.black,
                    child: _configuration == null
                        ? const SizedBox()
                        : _reader(_configuration!)))),
      ])));

  @override
  void dispose() {
    unawaited(_keepBenchmarkScreenOn(false));
    SchedulerBinding.instance.removeTimingsCallback(_captureTimings);
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    _controller?.dispose();
    _scroll?.dispose();
    _changes.dispose();
    super.dispose();
  }
}
