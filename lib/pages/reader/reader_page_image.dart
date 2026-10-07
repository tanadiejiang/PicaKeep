import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_original_raster_handoff.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_session_raster_cache.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

import 'reader_image_surface.dart';

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
  Timer? _resolutionRetry;
  Timer? _sourceLoadingTimer;
  bool _showSourceLoading = false;
  Size? _pendingSourceSize;
  int _resolutionRetries = 0;
  static const _maximumResolutionRetries = 2;

  @override
  void initState() {
    super.initState();
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
    if (widget.resourceKey != oldWidget.resourceKey ||
        widget.fullOrdinaryImage != oldWidget.fullOrdinaryImage ||
        widget.earlyOriginalRaster != oldWidget.earlyOriginalRaster ||
        widget.nativeLargeFit != oldWidget.nativeLargeFit ||
        widget.boundedPngFit != oldWidget.boundedPngFit ||
        widget.textureEdgeLowerBound != oldWidget.textureEdgeLowerBound ||
        widget.preferRawSync != oldWidget.preferRawSync ||
        widget.preferPreparedRead != oldWidget.preferPreparedRead ||
        widget.preparedReadAdmission != oldWidget.preparedReadAdmission ||
        widget.persistRaster != oldWidget.persistRaster) {
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
    _resolutionRetry?.cancel();
    _resolutionRetry = null;
    _resolutionRetries = 0;
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
      _pendingSourceSize = null;
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
    final next = () async {
      await previous;
      await _sourceDrain;
      if (_isCurrent(generation)) await _resolveAttempt(generation);
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
    var retryQueueFailure = false;
    try {
      source = await widget.loadSource();
      sourceResolveUs = resolveClock.elapsedMicroseconds;
      if (!mounted || generation != _generation) {
        await _disposeSource(source);
        return;
      }
      _source = source;
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
      if (source is RasterReaderPageSource) {
        backend = source.rasterBackend;
        file = source.rasterLocator;
        final metadataClock = Stopwatch()..start();
        metadata = await source.openRasterMetadata();
        metadataUs = metadataClock.elapsedMicroseconds;
      } else {
        final sourceFileClock = Stopwatch()..start();
        file = await source.openOriginalFile();
        sourceFileUs = sourceFileClock.elapsedMicroseconds;
        if (!mounted || generation != _generation) return;
        releaseMetadata = ReaderPageFileLease.acquire(file);
        originalSnapshot = await file.stat();
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
    } catch (error) {
      if (_isCurrent(generation)) {
        _disposeSelectedSource();
        retryQueueFailure = (error is ImageEngineQueueExceeded ||
                error is ImageWorkQueueExceeded) &&
            _resolutionRetries < _maximumResolutionRetries;
        // Only bounded queue admission failures recover automatically. Native
        // status 3 also covers hard budgets, so its generic form must not retry.
        if (!retryQueueFailure) {
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
    if (retryQueueFailure) {
      await _sourceDrain;
      if (!_isCurrent(generation)) return;
      _resolutionRetries++;
      _resolutionRetry =
          Timer(Duration(milliseconds: 120 * _resolutionRetries), () {
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
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      return ReaderRasterMetadata(
          size: Size(descriptor.width.toDouble(), descriptor.height.toDouble()),
          animated: true,
          format: 'compatibility',
          workingBytes: descriptor.width * descriptor.height * 4);
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Widget _pixels() {
    if (_compatibility) {
      return Image.file(_file!,
          fit: widget.fit,
          alignment: widget.alignment,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true);
    }
    return ReaderImageSurface(
        source: _source!,
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
    if (_metadata == null) {
      final pending = Center(
          child: _error == null
              ? _showSourceLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const SizedBox.shrink()
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('图片暂时无法打开，请重试', maxLines: 3)),
                  TextButton(
                      onPressed: _restartResolution, child: Text('重试'.tl)),
                ]));
      return widget.continuousWidth == null
          ? pending
          : SizedBox(
              width: widget.continuousWidth,
              height: widget.continuousWidth! *
                  (_pendingSourceSize == null
                      ? 1.4
                      : _pendingSourceSize!.height / _pendingSourceSize!.width),
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
      return PhotoView.customChild(
          controller: widget.controller,
          childSize: sourceSize,
          backgroundDecoration: widget.backgroundDecoration,
          minScale: contained,
          initialScale: initial,
          maxScale: math.max(initial * 8, native * 4),
          basePosition: widget.fit == BoxFit.fitWidth &&
                  sourceSize.height * initial > constraints.maxHeight
              ? Alignment.topCenter
              : Alignment.center,
          child: _pixels());
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
    super.dispose();
  }
}
