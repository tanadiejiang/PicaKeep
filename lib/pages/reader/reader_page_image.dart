import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/reader_image_retry.dart';
import 'package:picakeep/foundation/image_loader/reader_image_limits.dart';
import 'package:picakeep/network/managed_image_retry.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_failure_diagnostics.dart';
import 'package:picakeep/foundation/image_pipeline/reader_original_raster_handoff.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_session_raster_cache.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

import 'reader_image_surface.dart';
import 'reader_whole_image.dart';
import 'reader_photo_view_owner.dart';

/// Some external filesystems refresh cached ctime on the first actual read.
/// Establish the baseline before probing; later source checks stay strict.
Future<FileStat> captureReaderOriginalSnapshot(File file) async {
  final before = await file.stat();
  final handle = await file.open(mode: FileMode.read);
  try {
    final firstByte = await handle.read(1);
    if (firstByte.length != 1) {
      throw const FileSystemException('Original did not yield its first byte');
    }
    final opened = await file.stat();
    if (before.type != FileSystemEntityType.file ||
        opened.type != FileSystemEntityType.file ||
        before.size != opened.size ||
        before.modified != opened.modified) {
      throw ReaderSourceSnapshotMismatch(
          expected: before, current: opened, sourceIdentityMatches: true);
    }
    return opened;
  } finally {
    await handle.close();
  }
}

/// A normal local page keeps one original raster while zooming and panning.
/// Larger pages retain the region renderer instead of allocating an unbounded
/// source texture. The limits leave room for neighbouring pages and the codec's
/// temporary buffers within the reader's shared resident budget.
class ReaderWholeImagePolicy {
  ReaderWholeImagePolicy._();

  static const maximumRasterBytes = 16 << 20;
  static const maximumEncodedBytes = 16 << 20;
  static const maximumTextureEdge = 4096;

  static bool isEligible({
    required ReaderPageSource source,
    required ReaderRasterMetadata metadata,
    required FileStat snapshot,
    required ReaderRasterBackend backend,
    int textureEdgeLowerBound = 0,
  }) {
    final size = metadata.size;
    final edge = textureEdgeLowerBound > 0
        ? math.min(maximumTextureEdge, textureEdgeLowerBound)
        : maximumTextureEdge;
    return source is FileReaderPageSource &&
        source is! RasterReaderPageSource &&
        source.isAuthoritativeOriginal &&
        !source.isPreviewOnly &&
        backend is FlutterReaderRasterBackend &&
        snapshot.type == FileSystemEntityType.file &&
        snapshot.size > 0 &&
        snapshot.size <= maximumEncodedBytes &&
        const ['jpeg', 'png', 'webp'].contains(metadata.format) &&
        !metadata.animated &&
        metadata.bitDepth == 8 &&
        !metadata.hasColorProfile &&
        size.width.isFinite &&
        size.height.isFinite &&
        size.width > 0 &&
        size.height > 0 &&
        size.width == size.width.roundToDouble() &&
        size.height == size.height.roundToDouble() &&
        size.width <= edge &&
        size.height <= edge &&
        size.width * size.height * 4 <= maximumRasterBytes;
  }

  /// The native metadata uses orientation-normalized dimensions. Check that
  /// Flutter's original codec agrees before selecting its whole-image path;
  /// unsupported descriptors and dimension/rotation differences stay on ROI.
  /// This opens the encoded descriptor without decoding another full raster.
  static Future<bool> canUseOriginal({
    required ReaderPageSource source,
    required File file,
    required ReaderRasterMetadata metadata,
    required FileStat snapshot,
    required ReaderRasterBackend backend,
    int textureEdgeLowerBound = 0,
  }) async {
    if (!isEligible(
        source: source,
        metadata: metadata,
        snapshot: snapshot,
        backend: backend,
        textureEdgeLowerBound: textureEdgeLowerBound)) {
      return false;
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      return descriptor.width == metadata.size.width &&
          descriptor.height == metadata.size.height;
    } catch (_) {
      // Native format support is wider than Flutter's. Failure of this optional
      // admission check must not turn a readable original into a page error.
      return false;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}

/// Resolves the original once. The pixel layers may change, but childSize and
/// PhotoView's original coordinate system remain fixed for this page.
class ReaderPageImage extends StatefulWidget {
  const ReaderPageImage({
    super.key,
    required this.loadSource,
    required this.resourceKey,
    required this.viewportKey,
    required this.transformChanges,
    required this.mode,
    this.controller,
    this.continuousWidth,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.backgroundDecoration,
    this.nativeScaleChanged,
    this.onPresented,
    this.onFirstRasterPresented,
    this.loadCachedPreview,
    this.tilePixels,
    this.fullOrdinaryImage = false,
    this.earlyOriginalRaster = false,
    this.nativeLargeFit = false,
    this.viewportRegion = false,
    this.boundedPngFit = false,
    this.textureEdgeLowerBound = 0,
    this.preferRawSync = false,
    this.preferPreparedRead = false,
    this.preparedReadAdmission = false,
    this.persistRaster = true,
    this.sessionRasterCache,
    this.failureDiagnostics,
    this.sizeHint,
    this.onSourceSize,
    this.largeImagePolicy,
    this.onUseSafeWhole,
    this.onInvalidate,
  });

  final Future<ReaderPageSource> Function() loadSource;
  final String resourceKey;
  final GlobalKey viewportKey;
  final Listenable transformChanges;
  final ReaderDisplayMode mode;
  final PhotoViewController? controller;
  final double? continuousWidth;
  final BoxFit fit;
  final Alignment alignment;
  final BoxDecoration? backgroundDecoration;
  final void Function(double scale)? nativeScaleChanged;
  final ValueChanged<ReaderPresentedFrame>? onPresented;
  final ValueChanged<int>? onFirstRasterPresented;
  final Future<ui.Image?> Function(ReaderResolvedOriginal)? loadCachedPreview;

  /// Local rasters group pixels into fewer uploads. Remote negotiated tiles
  /// keep their existing grid; a profile/test caller can select either size.
  final int? tilePixels;
  final bool fullOrdinaryImage;
  final bool earlyOriginalRaster;
  final bool nativeLargeFit;
  final bool viewportRegion;
  final bool boundedPngFit;
  final int textureEdgeLowerBound;
  final bool preferRawSync;
  final bool preferPreparedRead;
  final bool preparedReadAdmission;
  final bool persistRaster;
  final ReaderSessionRasterCache? sessionRasterCache;
  final ReaderFailurePageDiagnostics? failureDiagnostics;

  /// Source size already known to the reading session (053). A continuous
  /// page rebuilt above the viewport must lay out at its real height on the
  /// first frame; a 1.4 placeholder that later shrinks shifts every visible
  /// page and snaps upward drags back.
  final Size? sizeHint;

  /// Reports the resolved source size so the session can provide [sizeHint].
  final ValueChanged<Size>? onSourceSize;

  /// Non-null for production sharp reading. No partial/ROI surface is reachable.
  final ReaderLargeImagePolicy? largeImagePolicy;
  final VoidCallback? onUseSafeWhole;
  final Future<void> Function()? onInvalidate;

  @override
  State<ReaderPageImage> createState() => _ReaderPageImageState();
}

class _ReaderPageImageState extends State<ReaderPageImage> {
  ReaderPageSource? _source;
  File? _file;
  ReaderRasterMetadata? _metadata;
  ReaderResolvedOriginal? _resolvedOriginal;
  ReaderOriginalRasterHandoff? _originalRasterHandoff;
  VoidCallback? _releaseResolvedHandoff;
  Object? _error;
  bool _compatibility = false;
  bool _fullOrdinaryImage = false;
  ReaderRasterBackend _backend = const NativeReaderRasterBackend();
  int _generation = 0;
  Future<void> _resolutionTail = Future<void>.value();
  Future<void> _sourceDrain = Future<void>.value();
  Future<({Object error, StackTrace stack})?> _invalidationDrain =
      Future.value(null);
  Timer? _resolutionRetry;
  Timer? _sourceLoadingTimer;
  bool _showSourceLoading = false;
  Size? _pendingSourceSize;
  int _resolutionRetries = 0;
  static const _maximumResolutionRetries = 2;
  ReaderFailureDiagnosticsSession? _standaloneDiagnostics;
  late ReaderFailurePageDiagnostics _failurePage;
  late ReaderFailureAttemptDiagnostics _failureAttempt;
  int _standalonePage = 0;

  void _selectFailurePage() {
    _failurePage = widget.failureDiagnostics ??
        (_standaloneDiagnostics ??= ReaderFailureDiagnosticsSession()).page(
            logicalIdentity: 'standalone:${_standalonePage++}',
            chapter: 0,
            page: 0,
            readingMode: 'standalone');
  }

  void _beginFailureAttempt({bool explicitRetry = false}) {
    _failureAttempt = _failurePage.beginAttempt(
        generation: _generation,
        qualityMode: widget.mode.name,
        explicitRetry: explicitRetry);
  }

  @override
  void initState() {
    super.initState();
    _pendingSourceSize = widget.sizeHint;
    _selectFailurePage();
    _beginFailureAttempt();
    _startSourceLoadingFeedback();
    unawaited(_resolve());
  }

  void _startSourceLoadingFeedback() {
    _sourceLoadingTimer?.cancel();
    final generation = _generation;
    _sourceLoadingTimer = Timer(const Duration(milliseconds: 500), () {
      _sourceLoadingTimer = null;
      if (_isCurrent(generation) && _metadata == null && _error == null) {
        setState(() => _showSourceLoading = true);
      }
    });
  }

  @override
  void didUpdateWidget(ReaderPageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _failureAttempt.updateQualityMode(widget.mode.name);
    if (widget.resourceKey != oldWidget.resourceKey ||
        (widget.mode != oldWidget.mode &&
            (widget.largeImagePolicy != null || oldWidget.largeImagePolicy != null)) ||
        widget.largeImagePolicy != oldWidget.largeImagePolicy ||
        widget.failureDiagnostics != oldWidget.failureDiagnostics ||
        widget.fullOrdinaryImage != oldWidget.fullOrdinaryImage ||
        widget.earlyOriginalRaster != oldWidget.earlyOriginalRaster ||
        widget.nativeLargeFit != oldWidget.nativeLargeFit ||
        widget.boundedPngFit != oldWidget.boundedPngFit ||
        widget.textureEdgeLowerBound != oldWidget.textureEdgeLowerBound ||
        widget.preferRawSync != oldWidget.preferRawSync ||
        widget.preferPreparedRead != oldWidget.preferPreparedRead ||
        widget.preparedReadAdmission != oldWidget.preparedReadAdmission ||
        widget.persistRaster != oldWidget.persistRaster) {
      if (widget.resourceKey != oldWidget.resourceKey ||
          widget.failureDiagnostics != oldWidget.failureDiagnostics) {
        _selectFailurePage();
      }
      _restartResolution(rebuild: false);
    }
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  void _disposeSelectedSource() {
    final source = _source;
    _source = null;
    if (source == null) return;
    _sourceDrain =
        Future.wait<void>([_sourceDrain, _disposeSource(source)]).then((_) {});
  }

  Future<void> _disposeSource(ReaderPageSource source) {
    // Start cancellation immediately. A plain user/download file owns no
    // cleanup resource: its global path drain can include another still-visible
    // page, which must not block this page's reload. Keep that drain protected in
    // the background; temporary and custom sources retain their wait contract.
    final disposing = Future<void>.sync(source.dispose).catchError((_) {});
    return source.runtimeType == FileReaderPageSource
        ? Future<void>.value()
        : disposing;
  }

  void _restartResolution({bool rebuild = true}) {
    _generation++;
    _beginFailureAttempt(explicitRetry: rebuild);
    _resolutionRetry?.cancel();
    _resolutionRetry = null;
    _resolutionRetries = 0;
    final invalidate = rebuild ? widget.onInvalidate : null;
    _invalidationDrain = invalidate == null ? Future.value(null)
        : Future<void>.sync(invalidate).then<({Object error, StackTrace stack})?>(
            (_) => null,
            onError: (Object error, StackTrace stack) => (error: error, stack: stack));
    _originalRasterHandoff?.cancel();
    _originalRasterHandoff = null;
    _releaseResolvedHandoff?.call();
    _releaseResolvedHandoff = null;
    if (rebuild && _source != null) {
      widget.sessionRasterCache?.invalidateSource(_source!.identity.stableKey);
    }
    _disposeSelectedSource();
    void reset() {
      _file = null;
      _metadata = null;
      _resolvedOriginal = null;
      _fullOrdinaryImage = false;
      _showSourceLoading = false;
      _pendingSourceSize = widget.sizeHint;
      _error = null;
    }

    if (rebuild) {
      setState(reset);
    } else {
      reset();
    }
    _startSourceLoadingFeedback();
    unawaited(_resolve());
  }

  Future<void> _resolve() {
    final generation = _generation;
    final previous = _resolutionTail;
    final invalidation = _invalidationDrain;
    final next = () async {
      await previous;
      await _sourceDrain;
      final failure = await invalidation;
      if (!_isCurrent(generation)) return;
      if (failure != null) {
        _failureAttempt.failure(stage: 'invalidate', error: failure.error,
            stackTrace: failure.stack);
        setState(() => _error = failure.error);
        return;
      }
      if (widget.largeImagePolicy != null) {
        await runWithManagedImageRetry(() => _resolveAttempt(generation));
      } else {
        await _resolveAttempt(generation);
      }
    }();
    _resolutionTail = next;
    return next;
  }

  Future<void> _resolveAttempt(int generation) async {
    final resolveClock = Stopwatch()..start();
    var sourceResolveUs = 0, sourceFileUs = 0, metadataUs = 0;
    var metadataCacheHit = false, metadataProbed = false;
    var policyDescriptorChecked = false;
    ReaderSessionSourceMetadata? rememberedMetadata;
    ReaderSessionSourceKey? metadataGuard;
    ReaderPageSource? source;
    void Function()? releaseMetadata;
    var retryResolution = false;
    Duration? retryDelay;
    var stage = 'loadSource';
    final failureAttempt = _failureAttempt;
    try {
      source = await widget.loadSource();
      sourceResolveUs = resolveClock.elapsedMicroseconds;
      if (!mounted || generation != _generation) {
        await _disposeSource(source);
        return;
      }
      _source = source;
      failureAttempt.updateSource(
          sourceVersion: source.identity.sourceVersion,
          sourceType: source.runtimeType.toString());
      if (source is FileReaderPageSource && source is! RasterReaderPageSource) {
        final rememberedSize = widget.sessionRasterCache
            ?.peekSourceMetadata(source.identity.stableKey)
            ?.metadata
            .size;
        if (rememberedSize != null) {
          setState(() => _pendingSourceSize = rememberedSize);
        }
      }
      final File file;
      FileStat? originalSnapshot;
      ReaderRasterMetadata metadata;
      late ReaderRasterBackend backend;
      var compatibility = false;
      if (source is RasterReaderPageSource && widget.largeImagePolicy == null) {
        backend = source.rasterBackend;
        file = source.rasterLocator;
        final metadataClock = Stopwatch()..start();
        stage = 'probe';
        metadata = await source.openRasterMetadata();
        metadataUs = metadataClock.elapsedMicroseconds;
      } else {
        final sourceFileClock = Stopwatch()..start();
        stage = 'openOriginal';
        file = await source.openOriginalFile();
        if (!mounted || generation != _generation) return;
        releaseMetadata = ReaderPageFileLease.acquire(file);
        originalSnapshot = await captureReaderOriginalSnapshot(file);
        sourceFileUs = sourceFileClock.elapsedMicroseconds;
        if (!mounted || generation != _generation) return;
        failureAttempt.updateSource(
            fileLength: originalSnapshot.size,
            fileModifiedMillis:
                originalSnapshot.modified.millisecondsSinceEpoch);
        final nativeBackend = NativeReaderRasterBackend(
            preferRawSync: widget.preferRawSync,
            preferPreparedRead: widget.preferPreparedRead,
            persistRaster: widget.persistRaster);
        backend = nativeBackend;
        compatibility = !PicakeepImageEngine.isAvailable;
        if (!compatibility && source is FileReaderPageSource) {
          final cache = widget.sessionRasterCache;
          metadataGuard = cache?.sourceKeyForSnapshot(
              file: file,
              snapshot: originalSnapshot,
              sourceIdentity: source.identity.stableKey);
          rememberedMetadata = cache?.sourceMetadata(
              file: file,
              snapshot: originalSnapshot,
              sourceIdentity: source.identity.stableKey);
        }
        final metadataClock = Stopwatch()..start();
        stage = 'probe';
        if (!compatibility) {
          try {
            if (rememberedMetadata != null) {
              metadata = rememberedMetadata.metadata;
              metadataCacheHit = true;
            } else {
              metadataProbed = true;
              metadata = await const NativeReaderRasterBackend().probe(file);
            }
            compatibility = metadata.animated;
            if (!metadata.animated &&
                metadata.size.width * metadata.size.height * 4 <= 64 << 20 &&
                originalSnapshot.size <= 64 << 20) {
              backend = FlutterReaderRasterBackend(metadata,
                  preferRawSync: widget.preferRawSync,
                  preferPreparedRead: widget.preferPreparedRead,
                  persistRaster: widget.persistRaster);
            }
            if (widget.boundedPngFit && originalSnapshot.size <= 64 << 20) {
              final bounded = BoundedPngFitReaderRasterBackend(metadata,
                  textureEdgeLowerBound: widget.textureEdgeLowerBound,
                  persistRaster: widget.persistRaster,
                  nativeBackend: nativeBackend);
              if (bounded.sourceEligible) backend = bounded;
            }
          } on ImageEngineException catch (error) {
            if (error.code != 4) rethrow;
            compatibility = true;
            metadata = await _probeCompatibility(file);
          }
        } else {
          metadata = await _probeCompatibility(file);
        }
        metadataUs = metadataClock.elapsedMicroseconds;
      }
      failureAttempt.updateSource(
          backendType: backend.runtimeType.toString(),
          width: metadata.size.width,
          height: metadata.size.height,
          format: metadata.format);
      if (widget.largeImagePolicy != null) {
        if (compatibility) {
          // This backend only receives a complete source rect from the whole
          // renderer. It cannot silently ask native code for partial regions.
          backend = FlutterReaderRasterBackend(metadata,
              persistRaster: widget.persistRaster);
        }
        final resolved = ReaderResolvedOriginal(source: source, file: file,
            metadata: metadata, fileSnapshot: originalSnapshot!);
        if (!_isCurrent(generation)) return;
        _originalRasterHandoff?.cancel();
        _originalRasterHandoff = null;
        _releaseResolvedHandoff?.call();
        _releaseResolvedHandoff = ReaderPageFileLease.acquire(file);
        _sourceLoadingTimer?.cancel();
        _sourceLoadingTimer = null;
        failureAttempt.rendererPath('whole');
        setState(() {
          _backend = backend;
          _compatibility = false;
          _file = file;
          _metadata = metadata;
          _resolvedOriginal = resolved;
          _fullOrdinaryImage = true;
          _showSourceLoading = false;
          _pendingSourceSize = metadata.size;
          _error = null;
        });
        widget.onSourceSize?.call(metadata.size);
        return;
      }
      failureAttempt.rendererPath(compatibility ? 'compatibility' : 'surface');
      // The legacy renderer is restricted to a bounded decoded working set.
      // A huge unsupported file must not trigger a whole-image allocation.
      if (compatibility &&
          metadata.size.width * metadata.size.height * 4 > 64 << 20) {
        throw StateError('此平台或格式暂不支持这张大图的分块阅读');
      }
      if (!mounted || generation != _generation) return;
      final resolved = !compatibility && source is! RasterReaderPageSource
          ? ReaderResolvedOriginal(
              source: source,
              file: file,
              metadata: metadata,
              fileSnapshot: originalSnapshot!)
          : null;
      policyDescriptorChecked = !compatibility &&
          originalSnapshot != null &&
          rememberedMetadata == null &&
          !widget.fullOrdinaryImage &&
          ReaderWholeImagePolicy.isEligible(
              source: source,
              metadata: metadata,
              snapshot: originalSnapshot,
              backend: backend);
      final policyOriginalCodec = !compatibility &&
          originalSnapshot != null &&
          (rememberedMetadata != null
              ? rememberedMetadata.fullOrdinaryImage
              : !widget.fullOrdinaryImage &&
                  await ReaderWholeImagePolicy.canUseOriginal(
                      source: source,
                      file: file,
                      metadata: metadata,
                      snapshot: originalSnapshot,
                      backend: backend));
      // Cache original codec agreement independently of the current texture
      // setting. A later verified smaller endpoint still gates its admission.
      final policyFullOrdinaryImage = policyOriginalCodec &&
          ReaderWholeImagePolicy.isEligible(
              source: source,
              metadata: metadata,
              snapshot: originalSnapshot,
              backend: backend,
              textureEdgeLowerBound: widget.textureEdgeLowerBound);
      final fullOrdinaryImage =
          widget.fullOrdinaryImage || policyFullOrdinaryImage;
      if (!mounted || generation != _generation) return;
      if (metadataGuard != null &&
          !compatibility &&
          !widget.fullOrdinaryImage &&
          !widget.boundedPngFit) {
        widget.sessionRasterCache?.rememberSourceMetadata(
            file: file,
            snapshot: originalSnapshot!,
            sourceIdentity: source.identity.stableKey,
            metadata: metadata,
            fullOrdinaryImage: policyOriginalCodec,
            guard: metadataGuard);
      }
      _originalRasterHandoff?.cancel();
      _originalRasterHandoff = null;
      if (widget.earlyOriginalRaster &&
          widget.fullOrdinaryImage &&
          resolved != null &&
          ReaderOriginalRasterHandoff.isEligible(
              metadata, resolved.fileSnapshot, backend)) {
        final sourceKey =
            sha256.convert(utf8.encode(source.identity.stableKey)).toString();
        _originalRasterHandoff = ReaderOriginalRasterHandoff.start(
            file: file,
            metadata: metadata,
            fileSnapshot: resolved.fileSnapshot,
            backend: backend,
            backingPath:
                '${App.cachePath}/image_pipeline/native_backing/$sourceKey.rgba',
            verifyOriginal: resolved.verifyCurrent);
      }
      // Keep the just-opened source alive between this setState and the first
      // child surface build. The surface acquires its own lifetime lease.
      _releaseResolvedHandoff?.call();
      _releaseResolvedHandoff =
          resolved == null ? null : ReaderPageFileLease.acquire(file);
      _sourceLoadingTimer?.cancel();
      _sourceLoadingTimer = null;
      setState(() {
        _backend = backend;
        _compatibility = compatibility;
        _file = file;
        _metadata = metadata;
        _resolvedOriginal = resolved;
        _fullOrdinaryImage = fullOrdinaryImage;
        _showSourceLoading = false;
        _pendingSourceSize = metadata.size;
        _error = null;
      });
      widget.onSourceSize?.call(metadata.size);
    } catch (error, stack) {
      if (_isCurrent(generation) && !readerFailureIsCancellation(error)) {
        _disposeSelectedSource();
        retryResolution = (error is ImageEngineQueueExceeded ||
                error is ImageWorkQueueExceeded) &&
            _resolutionRetries < _maximumResolutionRetries;
        if (!retryResolution && widget.largeImagePolicy != null &&
            (stage == 'loadSource' || stage == 'openOriginal')) {
          retryDelay = readerImageRetryDelay(error, _resolutionRetries + 1);
          retryResolution = retryDelay != null;
        }
        failureAttempt.failure(
            stage: stage,
            error: error,
            stackTrace: stack,
            terminal: !retryResolution,
            snapshot: {
              'generation': generation,
              'retry': _resolutionRetries,
              'active': ImageWorkScheduler.shared.activeCount,
              'pending': ImageWorkScheduler.shared.pendingCount,
              'reservedBytes': ImageWorkScheduler.shared.reservedBytes,
            });
        // Queue pressure and classified transient transfers can retry; native
        // hard budgets, format failures and authentication are never hidden.
        if (!retryResolution) {
          _sourceLoadingTimer?.cancel();
          _sourceLoadingTimer = null;
          setState(() => _error = error);
        }
      }
    } finally {
      ReaderRasterDiagnostics.record({
        'sourceResolveUs': sourceResolveUs,
        'sourceFileUs': sourceFileUs,
        'sourceMetadataUs': metadataUs,
        if (metadataCacheHit) 'sourceMetadataCacheHit': 1,
        if (metadataProbed) 'sourceMetadataProbe': 1,
        if (policyDescriptorChecked) 'sourcePolicyDescriptorCheck': 1,
        'pageResolveUs': resolveClock.elapsedMicroseconds,
      });
      releaseMetadata?.call();
    }
    if (retryResolution) {
      await _sourceDrain;
      if (!_isCurrent(generation)) return;
      _resolutionRetries++;
      failureAttempt.retry(stage: stage, retry: _resolutionRetries);
      _resolutionRetry =
          Timer(retryDelay ?? Duration(milliseconds: 120 * _resolutionRetries), () {
        _resolutionRetry = null;
        if (_isCurrent(generation)) unawaited(_resolve());
      });
    }
  }

  Future<ReaderRasterMetadata> _probeCompatibility(File file) async {
    if (await file.length() > 64 << 20) {
      throw StateError('此格式需要原生大图解码支持');
    }
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      var animated = true;
      if (widget.largeImagePolicy != null) {
        final sourceBytes = descriptor.width * descriptor.height * 4;
        if (sourceBytes > 64 << 20) {
          throw const ReaderWholeImageLimit('codec-peak',
              '当前平台缺少此格式的安全整图解码支持，无法仅靠缩小输出避免大图内存开销');
        }
        codec = await descriptor.instantiateCodec(targetWidth: 1, targetHeight: 1);
        animated = codec.frameCount > 1;
      }
      return ReaderRasterMetadata(
          size: Size(descriptor.width.toDouble(), descriptor.height.toDouble()),
          animated: animated,
          format: 'compatibility',
          // Without native metadata a profile cannot be ruled out. Preserve
          // Flutter colour handling and do not persist an assumed sRGB raster.
          hasColorProfile: widget.largeImagePolicy != null,
          workingBytes: descriptor.width * descriptor.height * 4);
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Widget _pixels() {
    final wholePolicy = widget.largeImagePolicy;
    if (wholePolicy != null) {
      final generation = _generation;
      return ReaderWholeImage(
          key: ValueKey('whole:${widget.resourceKey}:${wholePolicy.name}'),
          file: _file!, resourceKey: widget.resourceKey,
          metadata: _metadata!, backend: _backend, policy: wholePolicy,
          textureEdge: widget.textureEdgeLowerBound > 0
              ? math.min(4096, widget.textureEdgeLowerBound) : 4096,
          verifyOriginal: _resolvedOriginal?.verifyCurrent,
          failureAttempt: _failureAttempt,
          onUseSafeWhole: widget.onUseSafeWhole,
          reloadSource: _restartResolution,
          onFailure: (error) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_isCurrent(generation)) setState(() => _error = error);
            });
            WidgetsBinding.instance.scheduleFrame();
          },
          onFirstRasterPresented: widget.onFirstRasterPresented,
          fit: widget.fit, alignment: widget.alignment);
    }
    if (_compatibility) {
      return Image.file(_file!,
          fit: widget.fit,
          alignment: widget.alignment,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true);
    }
    return ReaderImageSurface(
        source: _source!,
        failureDiagnostics: _failureAttempt,
        sourceSize: _metadata!.size,
        viewportKey: widget.viewportKey,
        mode: widget.mode,
        transformChanges: widget.transformChanges,
        backend: _backend,
        metadata: _metadata,
        resolvedOriginal: _resolvedOriginal,
        originalRasterHandoff: _originalRasterHandoff,
        sessionRasterCache: widget.sessionRasterCache,
        nativeLargeFit: widget.nativeLargeFit,
        preparedReadAdmission: widget.preparedReadAdmission,
        textureEdgeLowerBound: widget.textureEdgeLowerBound,
        tilePixels: widget.tilePixels ??
            (_source is! RasterReaderPageSource &&
                    (_metadata!.format == 'png' ||
                        _metadata!.format == 'jpeg' &&
                            _metadata!.baselineJpeg == true)
                ? 1024
                : 512),
        nativeTilePixels: widget.tilePixels == null ? 512 : null,
        fullOrdinaryImage: _fullOrdinaryImage,
        viewportRegion: widget.viewportRegion,
        onPresented: widget.onPresented,
        onFirstRasterPresented: widget.onFirstRasterPresented,
        loadCachedPreview: widget.loadCachedPreview,
        reloadSource: _restartResolution,
        fit: widget.fit,
        alignment: widget.alignment);
  }

  @override
  Widget build(BuildContext context) {
    if (_metadata == null || (widget.largeImagePolicy != null && _error != null)) {
      final pending = Center(
          child: _error == null
              ? _showSourceLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const SizedBox.shrink()
              : Material(
                   color: Theme.of(context).colorScheme.surface,
                   child: SingleChildScrollView(
                     child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_error is ReaderWholeImageLimit
                          ? (_error! as ReaderWholeImageLimit).message
                          : _error is ReaderImageLimit
                               ? (_error! as ReaderImageLimit).message
                               : _error is ImageWorkBudgetExceeded
                                   ? '整图解码超出当前安全工作预算，原文件未修改。'
                                   : '图片暂时无法打开，请重试',
                          textAlign: TextAlign.center)),
                  TextButton(
                      onPressed: _restartResolution,
                      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      child: Text('重试'.tl)),
                   if (widget.largeImagePolicy == ReaderLargeImagePolicy.strictOriginal &&
                       widget.onUseSafeWhole != null && _metadata != null &&
                       (_error is ImageWorkBudgetExceeded ||
                           _error is ReaderWholeImageLimit &&
                           (_error! as ReaderWholeImageLimit).kind == 'original-limit'))
                     Padding(
                       padding: const EdgeInsets.only(top: 8),
                       child: TextButton(
                         onPressed: widget.onUseSafeWhole,
                         style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                         child: const Text('改为安全整图显示'))),
                ]))));
      final placeholderHeight = widget.continuousWidth == null ? 0.0
          : widget.continuousWidth! * (_pendingSourceSize == null ? 1.4
              : _pendingSourceSize!.height / _pendingSourceSize!.width);
      return widget.continuousWidth == null
          ? pending
          : SizedBox(
              width: widget.continuousWidth,
              // Error actions need a usable viewport even for extremely wide
              // source pages. Loading and successful image geometry stay exact.
              height: _error == null ? placeholderHeight
                  : math.max(160.0, placeholderHeight),
              child: pending);
    }
    final sourceSize = _metadata!.size;
    if (widget.continuousWidth != null) {
      widget.nativeScaleChanged?.call(sourceSize.width /
          widget.continuousWidth! /
          View.of(context).devicePixelRatio);
      return SizedBox(
          width: widget.continuousWidth,
          height:
              widget.continuousWidth! * sourceSize.height / sourceSize.width,
          child: _pixels());
    }
    if (widget.controller == null) {
      return LayoutBuilder(builder: (context, constraints) {
        final fitScale = math.min(constraints.maxWidth / sourceSize.width,
            constraints.maxHeight / sourceSize.height);
        if (fitScale > 0) {
          widget.nativeScaleChanged
              ?.call(1 / fitScale / View.of(context).devicePixelRatio);
        }
        return _pixels();
      });
    }
    return LayoutBuilder(builder: (context, constraints) {
      final contained = math.min(constraints.maxWidth / sourceSize.width,
          constraints.maxHeight / sourceSize.height);
      final initial = switch (widget.fit) {
        BoxFit.fitWidth => constraints.maxWidth / sourceSize.width,
        BoxFit.fitHeight => constraints.maxHeight / sourceSize.height,
        _ => contained,
      };
      final native = 1 / View.of(context).devicePixelRatio;
      widget.nativeScaleChanged?.call(native);
      return ReaderPhotoViewOwner(
          controller: widget.controller!,
          builder: (_, controller, scaleState) => PhotoView.customChild(
          controller: controller,
          scaleStateController: scaleState,
          childSize: sourceSize,
          backgroundDecoration: widget.backgroundDecoration,
          minScale: contained,
          initialScale: initial,
          maxScale: math.max(initial * 8, native * 4),
          basePosition: widget.fit == BoxFit.fitWidth &&
                  sourceSize.height * initial > constraints.maxHeight
              ? Alignment.topCenter
              : Alignment.center,
          child: _pixels()));
    });
  }

  @override
  void dispose() {
    _generation++;
    _resolutionRetry?.cancel();
    _resolutionRetry = null;
    _sourceLoadingTimer?.cancel();
    _sourceLoadingTimer = null;
    _originalRasterHandoff?.cancel();
    _originalRasterHandoff = null;
    _releaseResolvedHandoff?.call();
    _releaseResolvedHandoff = null;
    _disposeSelectedSource();
    _failureAttempt.close();
    _standaloneDiagnostics?.dispose();
    super.dispose();
  }
}
