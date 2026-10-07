import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_session_raster_cache.dart';
import 'package:picakeep/foundation/image_pipeline/reader_original_raster_handoff.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';

class _ReaderLayer {
  _ReaderLayer(this.demand, this.image, [this.sessionKey])
      : variant = demand.variant;
  final ReaderTileDemand demand;
  // Geometry is immutable. Compute its string key once rather than rebuilding
  // it for every comparison while newly decoded tiles repaint the surface.
  final String variant;
  final ui.Image image;
  final ReaderSessionRasterKey? sessionKey;
  int get bytes => image.width * image.height * 4;
}

class ReaderPresentedFrame {
  const ReaderPresentedFrame(
      {required this.sourceRect,
      required this.density,
      required this.complete,
      required this.nativePixels,
      this.frameBuildTimelineUs});
  final Rect sourceRect;
  final double density;
  final bool complete;
  final bool nativePixels;
  final int? frameBuildTimelineUs;
}

class ReaderSurfaceDiagnostics {
  static int Function()? _resident;
  static int Function()? _pending;
  static int Function()? _active;
  static List<Map<String, Object?>> Function()? _details;
  static int get residentBytes => _resident?.call() ?? 0;
  static int get retainedBytes => ReaderSessionRasterCache.totalRetainedBytes;
  static int get pendingBytes => _pending?.call() ?? 0;
  static int get activeSurfaces => _active?.call() ?? 0;
  static List<Map<String, Object?>> snapshot() => _details?.call() ?? const [];
}

/// One already-opened original and its metadata from the same selected source.
/// Raster/remote placeholders never represent an original file here.
class ReaderResolvedOriginal {
  ReaderResolvedOriginal(
      {required this.source,
      required this.file,
      required this.metadata,
      required this.fileSnapshot})
      : sourceIdentity = source.identity.stableKey {
    if (source is RasterReaderPageSource) {
      throw ArgumentError('A remote raster locator is not an opened original');
    }
  }
  final ReaderPageSource source;
  final String sourceIdentity;
  final File file;
  final ReaderRasterMetadata metadata;
  final FileStat fileSnapshot;

  Future<void> verifyCurrent() async {
    final current = await file.stat();
    if (current.type != FileSystemEntityType.file ||
        current.size != fileSnapshot.size ||
        current.modified != fileSnapshot.modified ||
        current.changed != fileSnapshot.changed ||
        source.identity.stableKey != sourceIdentity) {
      throw StateError(
          'Original source changed after its metadata was resolved');
    }
  }
}

/// This widget never owns pan or zoom. Its ancestors keep the stable original
/// geometry; the render transform supplies the complete viewport projection.
class ReaderImageSurface extends StatefulWidget {
  const ReaderImageSurface({
    super.key,
    required this.source,
    required this.sourceSize,
    required this.viewportKey,
    required this.mode,
    required this.transformChanges,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.backend = const NativeReaderRasterBackend(),
    this.semanticLabel,
    this.reloadSource,
    this.onPresented,
    this.onFirstRasterPresented,
    this.loadCachedPreview,
    this.metadata,
    this.tilePixels = 512,
    this.nativeTilePixels,
    this.fullOrdinaryImage = false,
    this.viewportRegion = false,
    this.resolvedOriginal,
    this.originalRasterHandoff,
    this.nativeLargeFit = false,
    this.preparedReadAdmission = false,
    this.textureEdgeLowerBound = 0,
    this.sessionRasterCache,
  })  : assert(tilePixels >= 128 && tilePixels <= 2048),
        assert(nativeTilePixels == null ||
            nativeTilePixels >= 128 && nativeTilePixels <= 2048);
  final ReaderPageSource source;
  final Size sourceSize;
  final GlobalKey viewportKey;
  final ReaderDisplayMode mode;
  final Listenable transformChanges;
  final BoxFit fit;
  final Alignment alignment;
  final ReaderRasterBackend backend;
  final String? semanticLabel;
  final VoidCallback? reloadSource;
  final ValueChanged<ReaderPresentedFrame>? onPresented;
  final ValueChanged<int>? onFirstRasterPresented;

  /// Returns an owned, already decoded thumbnail, or null without decoding
  /// the original. It is display-only and never satisfies original demands.
  final Future<ui.Image?> Function(ReaderResolvedOriginal)? loadCachedPreview;
  final ReaderRasterMetadata? metadata;
  final int tilePixels;
  final int? nativeTilePixels;
  final bool fullOrdinaryImage;
  final bool viewportRegion;
  final ReaderResolvedOriginal? resolvedOriginal;
  final ReaderOriginalRasterHandoff? originalRasterHandoff;
  final bool nativeLargeFit;
  final bool preparedReadAdmission;
  final int textureEdgeLowerBound;
  final ReaderSessionRasterCache? sessionRasterCache;
  @override
  State<ReaderImageSurface> createState() => _ReaderImageSurfaceState();
}

class _ReaderImageSurfaceState extends State<ReaderImageSurface>
    with WidgetsBindingObserver {
  static final _surfaces = <_ReaderImageSurfaceState>{};
  static int _residentBytes = 0;
  static int _pendingResidentBytes = 0;
  static final _backingTouches = <String, DateTime>{};
  static const _globalResidentLimit = 192 << 20;
  final _layers = <String, _ReaderLayer>{};
  final _tickets = <String, ImageWorkTicket<ui.Image>>{};
  final _estimating = <String>{};
  final _firstRasterQueue = <String,
      ({ReaderTileDemand tile, ImageWorkPriority priority, bool forceFull})>{};
  final _tileFailures = <String, Object>{};
  final _queueRetryCounts = <String, int>{};
  final _retryTimers = <String, Timer>{};
  final _retired = <ui.Image>[];
  final _pendingImages = <ui.Image, int>{};
  final _pendingHandoffs = <Object, int>{};
  final _backingHolds = <String, Future<ImageDiskReservation>>{};
  ReaderPageCancellation _sourceCancellation = ReaderPageCancellation();
  File? _file;
  VoidCallback? _releaseResolvedOriginal;
  ReaderOriginalRasterHandoff? _pendingOriginalRaster;
  ReaderRasterMetadata? _metadata;
  Object? _error;
  bool _scheduled = false;
  int _generation = 0;
  Rect _paintRect = Rect.zero;
  ReaderViewportDemand? _demand;
  Set<String> _desired = {};
  int _bytes = 0;
  int _pendingBytes = 0;
  String? _reportedFrame;
  String? _initialPreviewVariant;
  bool _firstRasterReported = false;
  bool _firstRasterPresented = false;
  Size? _layoutSize;
  Offset _physicalSourceX = Offset.zero;
  Offset _physicalSourceY = Offset.zero;
  Timer? _idleTimer;
  Timer? _loadingTimer;
  bool _showLoading = false;
  ImageWorkTicket<void>? _idleBacking;
  bool _backingPrepared = false;
  int _idleEpoch = 0;
  static const _residentLimit = 64 * 1024 * 1024;

  Object? get _visibleTileFailure => _desired
      .map((variant) => _tileFailures[variant])
      .whereType<Object>()
      .firstOrNull;

  @override
  void initState() {
    super.initState();
    _surfaces.add(this);
    ReaderSurfaceDiagnostics._resident =
        () => _residentBytes + ReaderSessionRasterCache.totalRetainedBytes;
    ReaderSurfaceDiagnostics._pending = () => _pendingResidentBytes;
    ReaderSurfaceDiagnostics._active = () => _surfaces.length;
    ReaderSurfaceDiagnostics._details = () => _surfaces
        .map((surface) => {
              'sourceRect': surface._demand == null
                  ? null
                  : [
                      surface._demand!.visibleSourceRect.left,
                      surface._demand!.visibleSourceRect.top,
                      surface._demand!.visibleSourceRect.right,
                      surface._demand!.visibleSourceRect.bottom,
                    ],
              'density': surface._demand?.density,
              'desired': surface._desired.toList(),
              'residentVariants': surface._layers.keys.toList(),
              'localResidentBytes': surface._bytes,
              'globalResidentBytes': _residentBytes,
              'sessionRetainedBytes':
                  surface.widget.sessionRasterCache?.retainedBytes ?? 0,
              'globalRetainedBytes':
                  ReaderSessionRasterCache.totalRetainedBytes,
              'globalPendingResidentBytes': _pendingResidentBytes,
              'pendingBytes': surface._pendingBytes,
              'ticketVariants': surface._tickets.keys.toList(),
              'estimating': surface._estimating.toList(),
              'tileQueueRetries': Map.of(surface._queueRetryCounts),
              'retryVariants': surface._retryTimers.keys.toList(),
              'tileFailures': {
                for (final entry in surface._tileFailures.entries)
                  entry.key: entry.value is ImageWorkBudgetExceeded
                      ? '${entry.value} requested=${(entry.value as ImageWorkBudgetExceeded).requestedBytes} budget=${(entry.value as ImageWorkBudgetExceeded).budgetBytes}'
                      : entry.value.toString(),
              },
              'error': surface._error?.toString() ??
                  surface._visibleTileFailure?.toString(),
              'reportedFrame': surface._reportedFrame,
            })
        .toList();
    WidgetsBinding.instance.addObserver(this);
    widget.transformChanges.addListener(_scheduleViewport);
    _initialiseOriginal();
  }

  @override
  void didUpdateWidget(ReaderImageSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transformChanges != widget.transformChanges) {
      oldWidget.transformChanges.removeListener(_scheduleViewport);
      widget.transformChanges.addListener(_scheduleViewport);
    }
    if (oldWidget.source != widget.source ||
        oldWidget.resolvedOriginal != widget.resolvedOriginal ||
        oldWidget.originalRasterHandoff != widget.originalRasterHandoff) {
      _sourceCancellation.cancel();
      _sourceCancellation = ReaderPageCancellation();
      _clear();
      _releaseResolvedOriginal?.call();
      _releaseResolvedOriginal = null;
      _file = null;
      _metadata = null;
      _error = null;
      _initialiseOriginal();
    } else if (oldWidget.tilePixels != widget.tilePixels ||
        oldWidget.nativeTilePixels != widget.nativeTilePixels ||
        oldWidget.fullOrdinaryImage != widget.fullOrdinaryImage ||
        oldWidget.nativeLargeFit != widget.nativeLargeFit ||
        oldWidget.textureEdgeLowerBound != widget.textureEdgeLowerBound ||
        oldWidget.viewportRegion != widget.viewportRegion) {
      _clear(resetFirstRaster: false);
    }
    if (oldWidget.mode != widget.mode &&
        widget.mode != ReaderDisplayMode.previewFirst) {
      final preview = _initialPreviewVariant;
      _initialPreviewVariant = null;
      if (preview != null && !_desired.contains(preview)) {
        _firstRasterQueue.remove(preview);
        _tickets.remove(preview)?.cancel();
      }
      _drainFirstRasterQueue();
    }
    _scheduleViewport();
  }

  void _initialiseOriginal() {
    final resolved = widget.resolvedOriginal;
    if (resolved == null) {
      widget.originalRasterHandoff?.cancel();
      unawaited(_open());
      return;
    }
    if (widget.source is RasterReaderPageSource ||
        !identical(resolved.source, widget.source) ||
        resolved.sourceIdentity != widget.source.identity.stableKey ||
        resolved.fileSnapshot.type != FileSystemEntityType.file ||
        resolved.metadata.size != widget.sourceSize ||
        resolved.metadata.animated ||
        widget.metadata != null &&
            !identical(widget.metadata, resolved.metadata)) {
      widget.originalRasterHandoff?.cancel();
      _error =
          StateError('Resolved original no longer matches the selected page');
      _scheduleViewport();
      return;
    }
    // The parent opened/verified this snapshot. Retain its file from this
    // synchronous handoff until surface disposal/source replacement, including
    // frames before any scheduled decoder has acquired its own run lease.
    _releaseResolvedOriginal = ReaderPageFileLease.acquire(resolved.file);
    _file = resolved.file;
    _metadata = resolved.metadata;
    final cachedPreview = widget.loadCachedPreview;
    if (cachedPreview != null) {
      unawaited(_consumeCachedPreview(resolved, cachedPreview, _generation));
    }
    final handoff = widget.originalRasterHandoff;
    if (handoff != null) {
      if (!widget.fullOrdinaryImage ||
          !identical(handoff.file, resolved.file) ||
          !identical(handoff.metadata, resolved.metadata) ||
          !identical(handoff.backend, widget.backend)) {
        handoff.cancel();
        _error =
            StateError('Early original raster does not match this surface');
      } else {
        _pendingOriginalRaster = handoff;
        unawaited(_consumeOriginalRaster(
            handoff, _generation, _sessionKey(handoff.demand)));
      }
    }
    _scheduleViewport();
  }

  Future<void> _consumeCachedPreview(
      ReaderResolvedOriginal resolved,
      Future<ui.Image?> Function(ReaderResolvedOriginal) loader,
      int generation) async {
    ui.Image? image;
    final reservation = Object();
    try {
      await resolved.verifyCurrent();
      if (!mounted || generation != _generation) return;
      image = await loader(resolved);
      if (image == null || !mounted || generation != _generation) return;
      final bytes = image.width * image.height * 4;
      final size = resolved.metadata.size;
      if (image.width > 4096 ||
          image.height > 4096 ||
          bytes > (16 << 20) ||
          (image.width - image.height * size.width / size.height).abs() > 2 ||
          !_hasImageSpace(bytes)) {
        return;
      }
      _pendingHandoffs[reservation] = bytes;
      _pendingBytes += bytes;
      _pendingResidentBytes += bytes;
      await resolved.verifyCurrent();
      if (!mounted ||
          generation != _generation ||
          _desired.isNotEmpty && _desired.every(_layers.containsKey)) {
        return;
      }
      final density =
          math.min(image.width / size.width, image.height / size.height);
      final tile = ReaderTileDemand(Offset.zero & size, density, -3, -3);
      _releasePendingHandoff(reservation);
      _residentBytes += bytes;
      final ownedImage = image;
      image = null;
      setState(() {
        _layers[tile.variant] = _ReaderLayer(tile, ownedImage);
        _bytes += bytes;
      });
      ReaderRasterDiagnostics.record({'cachedCoverPreviewRestored': 1});
      _trim();
      _updateLoadingFeedback();
    } catch (_) {
      // A thumbnail cache miss or invalidated source must keep original work
      // moving; this optional display layer is not a reader error.
    } finally {
      image?.dispose();
      _releasePendingHandoff(reservation);
    }
  }

  Future<void> _consumeOriginalRaster(ReaderOriginalRasterHandoff handoff,
      int generation, ReaderSessionRasterKey? sessionKey) async {
    final reservation = Object();
    try {
      await handoff.ready;
      if (!mounted || generation != _generation) {
        handoff.cancel();
        return;
      }
      final bytes = handoff.outputBytes;
      if (!_hasImageSpace(bytes)) {
        for (final surface in _surfaces.toList()) {
          surface._evictUnneeded();
        }
        SchedulerBinding.instance.ensureVisualUpdate();
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || generation != _generation) {
          handoff.cancel();
          return;
        }
      }
      if (!_hasImageSpace(bytes)) {
        throw const ImageWorkBudgetExceeded(
            _globalResidentLimit + 1, _globalResidentLimit);
      }
      _pendingHandoffs[reservation] = bytes;
      _pendingBytes += bytes;
      _pendingResidentBytes += bytes;
      await handoff.verifyForTransfer();
      if (!mounted || generation != _generation) {
        handoff.cancel();
        return;
      }
      // No await between the final resident check, ownership transfer and
      // resident charge: another surface cannot consume that space meanwhile.
      if (!_hasImageSpace(0)) {
        throw const ImageWorkBudgetExceeded(
            _globalResidentLimit + 1, _globalResidentLimit);
      }
      final image = handoff.take();
      _releasePendingHandoff(reservation);
      _residentBytes += bytes;
      setState(() {
        _layers[handoff.demand.variant] =
            _ReaderLayer(handoff.demand, image, sessionKey);
        _bytes += bytes;
        _error = null;
        _pendingOriginalRaster = null;
      });
      ReaderRasterDiagnostics.record({
        'earlyOriginalRasterConsumedUs': developer.Timeline.now,
      });
      _trim();
      _updateLoadingFeedback();
      _scheduleIdleBacking();
    } catch (error) {
      handoff.cancel();
      if (mounted &&
          generation == _generation &&
          error is! ImageWorkCancelled) {
        setState(() {
          _pendingOriginalRaster = null;
          _error = error;
        });
      }
    } finally {
      _releasePendingHandoff(reservation);
      if (generation == _generation) _drainFirstRasterQueue();
    }
  }

  Future<void> _open() async {
    final ownGeneration = _generation;
    void Function()? releaseMetadata;
    try {
      final source = widget.source;
      final file = source is RasterReaderPageSource
          ? source.rasterLocator
          : await source.openOriginalFile(cancellation: _sourceCancellation);
      if (!mounted || ownGeneration != _generation) return;
      releaseMetadata = ReaderPageFileLease.acquire(file);
      final metadata = widget.metadata ??
          (source is RasterReaderPageSource
              ? await source.openRasterMetadata()
              : await widget.backend.probe(file));
      if (metadata.size != widget.sourceSize) {
        throw StateError('原图尺寸已变化，请刷新此页');
      }
      if (!mounted || ownGeneration != _generation) return;
      if (metadata.animated) {
        throw StateError('Animated resource requires the animation renderer');
      }
      _file = file;
      _metadata = metadata;
      _scheduleViewport();
    } catch (error) {
      if (mounted && ownGeneration == _generation) {
        setState(() => _error = error);
      }
    } finally {
      releaseMetadata?.call();
    }
  }

  void _scheduleViewport() {
    if (!mounted || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _updateViewport();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _updateViewport() {
    final render = context.findRenderObject();
    final viewport = widget.viewportKey.currentContext?.findRenderObject();
    if (render is! RenderBox ||
        !render.hasSize ||
        viewport is! RenderBox ||
        !viewport.hasSize) {
      return;
    }
    final fit = applyBoxFit(widget.fit, widget.sourceSize, render.size);
    final destination =
        widget.alignment.inscribe(fit.destination, Offset.zero & render.size);
    final oldPaintRect = _paintRect;
    final oldDemand = _demand;
    _paintRect = destination;
    final viewportOrigin = viewport.localToGlobal(Offset.zero);
    final globalViewport = viewportOrigin & viewport.size;
    final projected = [
      globalViewport.topLeft,
      globalViewport.topRight,
      globalViewport.bottomLeft,
      globalViewport.bottomRight
    ].map(render.globalToLocal).toList();
    final localView = Rect.fromLTRB(
        projected.map((p) => p.dx).reduce(math.min),
        projected.map((p) => p.dy).reduce(math.min),
        projected.map((p) => p.dx).reduce(math.max),
        projected.map((p) => p.dy).reduce(math.max));
    final scaleX = destination.width / widget.sourceSize.width;
    final scaleY = destination.height / widget.sourceSize.height;
    if (scaleX <= 0 || scaleY <= 0) return;
    final visible = localView.intersect(destination);
    final sourceRect = Rect.fromLTRB(
            (visible.left - destination.left) / scaleX,
            (visible.top - destination.top) / scaleY,
            (visible.right - destination.left) / scaleX,
            (visible.bottom - destination.top) / scaleY)
        .intersect(Offset.zero & widget.sourceSize);
    final p0 = render.localToGlobal(destination.topLeft);
    final px = render.localToGlobal(destination.topLeft + Offset(scaleX, 0));
    final py = render.localToGlobal(destination.topLeft + Offset(0, scaleY));
    final dpr = View.of(context).devicePixelRatio;
    // Largest singular value of the local source-to-screen Jacobian. This
    // also covers rotated non-uniform scaling, where column lengths alone
    // can understate the sampling requirement.
    final xAxis = px - p0;
    final yAxis = py - p0;
    _physicalSourceX = xAxis * dpr;
    _physicalSourceY = yAxis * dpr;
    const axisRoundoff = 0.000001;
    bool nearZero(double value) => value.abs() <= axisRoundoff;
    final axisAligned = nearZero(xAxis.dy) && nearZero(yAxis.dx) ||
        nearZero(xAxis.dx) && nearZero(yAxis.dy);
    final nativePixelAxes = axisAligned &&
        _physicalSourceX.distance >= 1 - axisRoundoff &&
        _physicalSourceY.distance >= 1 - axisRoundoff;
    final xx = xAxis.distanceSquared;
    final yy = yAxis.distanceSquared;
    final xy = xAxis.dx * yAxis.dx + xAxis.dy * yAxis.dy;
    final density = math.sqrt(
            (xx + yy + math.sqrt((xx - yy) * (xx - yy) + 4 * xy * xy)) / 2) *
        dpr;
    var requiredDensity = density;
    if (_metadata?.format == 'jpeg' &&
        density < 0.125 &&
        widget.sourceSize.width * widget.sourceSize.height / 64 * 4 <=
            16 << 20) {
      requiredDensity = 0.125;
    }
    final demand = ReaderViewportDemand(
        visibleSourceRect: sourceRect,
        physicalPixelsPerSourcePixel: requiredDensity);
    _demand = demand;
    if (oldDemand?.visibleSourceRect != sourceRect ||
        oldDemand?.density != demand.density) {
      _cancelIdleBacking();
    }
    final wholeTile = ReaderTileDemand(
        Offset.zero & widget.sourceSize, demand.density, -1, -1);
    final wholeBytes = wholeTile.outputWidth * wholeTile.outputHeight * 4;
    final fitTextureEdge = widget.textureEdgeLowerBound > 0
        ? math.min(4096, widget.textureEdgeLowerBound)
        : 4096;
    // A bounded whole layer is stable as a continuous reader scrolls through
    // only part of a page. Visibility must not turn that same page into a new
    // tile grid; output bytes and texture dimensions govern this decision.
    final wholeFits = demand.density < 1 &&
        wholeBytes <= 16 << 20 &&
        wholeTile.outputWidth <= fitTextureEdge &&
        wholeTile.outputHeight <= fitTextureEdge &&
        (widget.source is! RasterReaderPageSource ||
            sourceRect.width * sourceRect.height >=
                widget.sourceSize.width * widget.sourceSize.height * 0.75);
    final backend = widget.backend;
    // Native JPEG scaled IDCT can produce a bounded whole fit without a full
    // source GPU image. Only an observed texture bound admits the larger fit.
    final nativeJpegWhole = widget.nativeLargeFit &&
        backend is NativeReaderRasterBackend &&
        widget.source is! RasterReaderPageSource &&
        _metadata?.format == 'jpeg' &&
        _metadata?.animated == false &&
        _metadata?.bitDepth == 8 &&
        _metadata?.hasColorProfile == false &&
        demand.density < 1 &&
        sourceRect.width * sourceRect.height >=
            widget.sourceSize.width * widget.sourceSize.height * 0.75 &&
        wholeTile.outputWidth * wholeTile.outputHeight * 4 <= 32 << 20 &&
        widget.textureEdgeLowerBound > 0 &&
        wholeTile.outputWidth <= widget.textureEdgeLowerBound &&
        wholeTile.outputHeight <= widget.textureEdgeLowerBound;
    final boundedPngWhole = backend is BoundedPngFitReaderRasterBackend &&
        widget.source is! RasterReaderPageSource &&
        backend.supportsWholeFit(ReaderTileDemand(
            Offset.zero & widget.sourceSize, demand.density, -1, -1));
    // Profile candidate: a bounded ordinary original can avoid a full PNG
    // decode followed by a resize. Huge/remote images retain the ROI path.
    final originalWhole = widget.fullOrdinaryImage &&
        widget.backend is FlutterReaderRasterBackend &&
        widget.sourceSize.width * widget.sourceSize.height * 4 <=
            _residentLimit;
    final cropUnit = 1 / math.max(demand.density, 0.000001);
    final viewportCrop = Rect.fromLTRB(
            (sourceRect.left / cropUnit).floor() * cropUnit,
            (sourceRect.top / cropUnit).floor() * cropUnit,
            (sourceRect.right / cropUnit).ceil() * cropUnit,
            (sourceRect.bottom / cropUnit).ceil() * cropUnit)
        .intersect(Offset.zero & widget.sourceSize);
    // Profile candidate: one bounded visible ROI can avoid many independent
    // Flutter image creations. Remote manifests keep their negotiated grid.
    final viewportTile = ReaderTileDemand(viewportCrop, demand.density, -2, -2);
    final useViewportCrop = widget.viewportRegion &&
        demand.density == 1 &&
        widget.source is! RasterReaderPageSource &&
        widget.backend is! FlutterReaderRasterBackend &&
        !viewportCrop.isEmpty &&
        viewportTile.outputWidth <= 16384 &&
        viewportTile.outputHeight <= 16384 &&
        viewportTile.outputWidth * viewportTile.outputHeight <= 4 * 1024 * 1024;
    final tiles = originalWhole
        ? [ReaderTileDemand(Offset.zero & widget.sourceSize, 1, -1, -1)]
        : wholeFits || boundedPngWhole || nativeJpegWhole
            ? [
                ReaderTileDemand(
                    Offset.zero & widget.sourceSize, demand.density, -1, -1)
              ]
            : useViewportCrop
                ? [viewportTile]
                : demand.tiles(widget.sourceSize,
                    tilePixels: demand.density == 1
                        ? widget.nativeTilePixels ?? widget.tilePixels
                        : widget.tilePixels,
                    samplingGutterPixels:
                        widget.source is RasterReaderPageSource ||
                                nativePixelAxes
                            ? 0
                            : 2);
    _desired = tiles.map((t) => t.variant).toSet();
    _firstRasterQueue.removeWhere(
        (key, _) => !_desired.contains(key) && key != _initialPreviewVariant);
    _tileFailures.removeWhere((variant, _) => !_desired.contains(variant));
    _queueRetryCounts.removeWhere((variant, _) => !_desired.contains(variant));
    for (final variant in _retryTimers.keys.toList()) {
      if (!_desired.contains(variant)) {
        _retryTimers.remove(variant)?.cancel();
      }
    }
    for (final key in _tickets.keys.toList()) {
      if (!_desired.contains(key) && key != _initialPreviewVariant) {
        _tickets.remove(key)?.cancel();
      }
    }
    if (mounted &&
        (oldPaintRect != destination ||
            oldDemand?.visibleSourceRect != sourceRect ||
            oldDemand?.density != demand.density)) {
      setState(() {});
    }
    if (_file == null || _metadata == null) return;
    // A preview is still derived from the same authoritative file.
    if (widget.mode == ReaderDisplayMode.previewFirst &&
        _initialPreviewVariant == null &&
        !_firstRasterPresented &&
        _layers.isEmpty &&
        tiles.isNotEmpty) {
      final previewDensity = ReaderViewportDemand(
              visibleSourceRect: Offset.zero & widget.sourceSize,
              physicalPixelsPerSourcePixel: math.min(
                  1.0,
                  1024 /
                      math.max(
                          widget.sourceSize.width, widget.sourceSize.height)))
          .density;
      final preview = ReaderTileDemand(
          Offset.zero & widget.sourceSize, previewDensity, -1, -1);
      _initialPreviewVariant = preview.variant;
      _request(preview, ImageWorkPriority.visible);
    }
    for (final tile in tiles) {
      _request(tile, ImageWorkPriority.visible);
    }
    _trim();
    _updateLoadingFeedback();
  }

  bool get _hasVisibleRaster {
    final visible = _demand?.visibleSourceRect;
    return visible != null &&
        _layers.values.any(
            (layer) => !visible.intersect(layer.demand.sourceRect).isEmpty);
  }

  void _updateLoadingFeedback() {
    final waiting = _desired.isNotEmpty &&
        !_desired.every(_layers.containsKey) &&
        !_hasVisibleRaster &&
        _error == null &&
        _visibleTileFailure == null;
    if (!waiting) {
      _loadingTimer?.cancel();
      _loadingTimer = null;
      if (_showLoading && mounted) setState(() => _showLoading = false);
      return;
    }
    if (_loadingTimer != null || _showLoading) return;
    final generation = _generation;
    _loadingTimer = Timer(const Duration(milliseconds: 500), () {
      _loadingTimer = null;
      if (mounted &&
          generation == _generation &&
          !_hasVisibleRaster &&
          _desired.isNotEmpty &&
          !_desired.every(_layers.containsKey) &&
          _error == null &&
          _visibleTileFailure == null) {
        setState(() => _showLoading = true);
      }
    });
  }

  void _request(ReaderTileDemand tile, ImageWorkPriority priority,
      {bool forceFullAdmission = false}) {
    if (_layers.containsKey(tile.variant) ||
        _pendingOriginalRaster?.demand.variant == tile.variant ||
        _tickets.containsKey(tile.variant) ||
        _estimating.contains(tile.variant) ||
        _retryTimers.containsKey(tile.variant) ||
        _tileFailures.containsKey(tile.variant) ||
        _file == null) {
      return;
    }
    // Before the first raster paints, do not fill both native workers with
    // whole-viewport estimates ahead of the first actual decode.
    if (!_firstRasterPresented &&
        (_estimating.isNotEmpty ||
            _tickets.isNotEmpty ||
            _pendingOriginalRaster != null ||
            _hasVisibleRaster)) {
      _firstRasterQueue[tile.variant] =
          (tile: tile, priority: priority, forceFull: forceFullAdmission);
      return;
    }
    final ownGeneration = _generation;
    final source = widget.source;
    final sourceKey =
        sha256.convert(utf8.encode(source.identity.stableKey)).toString();
    final backing =
        '${App.cachePath}/image_pipeline/native_backing/$sourceKey.rgba';
    final backend = widget.backend;
    final file = _file!;
    final sessionKey = _sessionKey(tile);
    _estimating.add(tile.variant);
    unawaited(() async {
      final releaseEstimate = ReaderPageFileLease.acquire(file);
      try {
        int? preparedWorking;
        final resolved = widget.resolvedOriginal;
        if (resolved != null && sessionKey != null) {
          // A new page widget must still open and verify the authoritative
          // original. Only its already decoded pixels cross widget lifetimes.
          await resolved.verifyCurrent();
          if (!mounted ||
              ownGeneration != _generation ||
              (!_desired.contains(tile.variant) &&
                  widget.mode != ReaderDisplayMode.previewFirst)) {
            return;
          }
          final image = widget.sessionRasterCache?.take(sessionKey);
          if (image != null) {
            final bytes = image.width * image.height * 4;
            // Transfer cache ownership and charge the surface synchronously;
            // there is no unaccounted image across an asynchronous boundary.
            if (_hasImageSpace(bytes)) {
              _residentBytes += bytes;
              setState(() {
                _layers[tile.variant] = _ReaderLayer(tile, image, sessionKey);
                _bytes += bytes;
              });
              ReaderRasterDiagnostics.record({'sessionRasterRestored': 1});
              _trim();
              _updateLoadingFeedback();
              _scheduleIdleBacking();
              return;
            }
            widget.sessionRasterCache?.put(sessionKey, image);
            image.dispose();
          }
        }
        if (resolved != null &&
            (widget.preparedReadAdmission || forceFullAdmission)) {
          await resolved.verifyCurrent();
          if (!forceFullAdmission) {
            preparedWorking =
                backend.preparedWorkingBytes(resolved.metadata, tile);
          }
        }
        final working = math.max(
            2 << 20,
            preparedWorking ??
                await backend.estimateWorkingBytes(file, tile,
                    backingPath: backing));
        if (preparedWorking != null) {
          ReaderRasterDiagnostics.record({
            'preparedAdmissionEstimateSkipped': 1,
            'preparedAdmissionWorkingBytes': working,
          });
        }
        if (!mounted ||
            ownGeneration != _generation ||
            (!_desired.contains(tile.variant) &&
                widget.mode != ReaderDisplayMode.previewFirst)) {
          return;
        }
        _submit(tile, priority, sourceKey, backing, file, backend, working,
            ownGeneration,
            preparedAdmission: preparedWorking != null, sessionKey: sessionKey);
      } catch (error) {
        if (mounted &&
            ownGeneration == _generation &&
            _desired.contains(tile.variant)) {
          _recordTileFailure(tile, priority, error);
        }
      } finally {
        releaseEstimate();
        if (ownGeneration == _generation) {
          _estimating.remove(tile.variant);
          _drainFirstRasterQueue();
        }
      }
    }());
  }

  void _drainFirstRasterQueue() {
    if (!mounted || _firstRasterQueue.isEmpty) return;
    if (!_firstRasterPresented &&
        (_estimating.isNotEmpty ||
            _tickets.isNotEmpty ||
            _pendingOriginalRaster != null ||
            _hasVisibleRaster)) {
      return;
    }
    final requests = _firstRasterPresented
        ? _firstRasterQueue.values.toList()
        : [_firstRasterQueue.values.first];
    for (final request in requests) {
      _firstRasterQueue.remove(request.tile.variant);
      _request(request.tile, request.priority,
          forceFullAdmission: request.forceFull);
    }
  }

  ReaderSessionRasterKey? _sessionKey(ReaderTileDemand tile) {
    final resolved = widget.resolvedOriginal;
    if (resolved == null || widget.source is! FileReaderPageSource) return null;
    final metadata = resolved.metadata;
    return widget.sessionRasterCache?.keyForSnapshot(
        file: resolved.file,
        snapshot: resolved.fileSnapshot,
        sourceIdentity: resolved.sourceIdentity,
        demand: tile,
        pixelIdentity: '${widget.backend.runtimeType}:reader-pixels-v2:'
            '${metadata.size.width}:${metadata.size.height}:${metadata.format}:'
            '${metadata.bitDepth}:${metadata.hasColorProfile}');
  }

  void _submit(
      ReaderTileDemand tile,
      ImageWorkPriority priority,
      String sourceKey,
      String backing,
      File file,
      ReaderRasterBackend backend,
      int working,
      int ownGeneration,
      {bool preparedAdmission = false,
      ReaderSessionRasterKey? sessionKey}) {
    final bytes = tile.outputWidth * tile.outputHeight * 4;
    final resolved = widget.resolvedOriginal;
    final ticket = ImageWorkScheduler.shared.submit<ui.Image>(
        lane: backend.executionLane,
        // Images are not shared between surfaces because each surface owns disposal.
        key: 'reader:${identityHashCode(this)}:$sourceKey:${tile.variant}',
        priority: priority,
        estimatedBytes: working + bytes * 3,
        disposeResult: _discardPendingImage,
        run: (cancel) async {
          final release = DerivedImageStore.protectTemporaryPath(backing);
          final releaseOriginal = ReaderPageFileLease.acquire(file);
          ui.Image? ownedImage;
          try {
            if (backend.executionLane == ImageWorkLane.execution &&
                (backend.requiresFileBacking ||
                    backend.supportsIdlePreparation)) {
              await _holdBacking(backing);
            }
            await Directory(File(backing).parent.path).create(recursive: true);
            if (resolved != null) await resolved.verifyCurrent();
            final decode =
                preparedAdmission ? backend.decodePrepared : backend.decode;
            final image = await decode(file, tile,
                backingPath: backing,
                memoryBudgetBytes: working,
                cancelled: cancel.cancelled,
                isCancelled: () =>
                    cancel.isCancelled ||
                    !mounted ||
                    ownGeneration != _generation);
            ownedImage = image;
            if (backend.requiresFileBacking) {
              DerivedImageStore.scheduleMaintenance(backing);
            }
            if (backend.requiresFileBacking &&
                DateTime.now()
                        .difference(_backingTouches[backing] ?? DateTime(1970))
                        .inSeconds >=
                    5) {
              _backingTouches[backing] = DateTime.now();
              final backingFile = File(backing);
              if (await backingFile.exists()) {
                await backingFile.setLastModified(DateTime.now());
              }
              if (_backingTouches.length > 256) {
                _backingTouches.remove(_backingTouches.keys.first);
              }
            }
            await _reservePendingImage(image, tile, cancel, ownGeneration,
                resolved: resolved);
            ownedImage = null;
            return image;
          } catch (_) {
            // Once decode returns, this run owns the image until it either
            // returns it to the scheduler or disposes it on a later failure.
            // This covers backing-file maintenance errors after a successful
            // decode; the scheduler cannot dispose a result it never receives.
            ownedImage?.dispose();
            rethrow;
          } finally {
            release();
            releaseOriginal();
          }
        });
    _tickets[tile.variant] = ticket;
    unawaited(ticket.future.then((image) {
      if (!mounted || ownGeneration != _generation) {
        _discardPendingImage(image);
        return;
      }
      final actualBytes = _releasePendingImage(image);
      if (actualBytes == null) return;
      _residentBytes += actualBytes;
      if (identical(_tickets[tile.variant], ticket)) {
        _tickets.remove(tile.variant);
      }
      setState(() {
        _layers[tile.variant] = _ReaderLayer(tile, image, sessionKey);
        _bytes += actualBytes;
        _tileFailures.remove(tile.variant);
        _queueRetryCounts.remove(tile.variant);
      });
      _trim();
      _updateLoadingFeedback();
      _scheduleIdleBacking();
    }, onError: (Object error, StackTrace stack) {
      if (ownGeneration == _generation &&
          identical(_tickets[tile.variant], ticket)) {
        _tickets.remove(tile.variant);
        if (preparedAdmission &&
            error is ReaderPreparedReadMiss &&
            mounted &&
            _desired.contains(tile.variant)) {
          // The scheduler completes listeners asynchronously, after its
          // finally releases the read-only job's working reservation. Native
          // has already released every buffer/token/source/backing hold.
          // Re-estimation and resubmission own a separate cold reservation.
          ReaderRasterDiagnostics.record({'preparedAdmissionColdRequeue': 1});
          _request(tile, priority, forceFullAdmission: true);
          return;
        }
        if (error is! ImageWorkCancelled &&
            mounted &&
            _desired.contains(tile.variant)) {
          _recordTileFailure(tile, priority, error);
        }
      }
      if (!mounted ||
          ownGeneration != _generation ||
          error is ImageWorkCancelled) {
        return;
      }
    }).whenComplete(() {
      if (ownGeneration == _generation) _drainFirstRasterQueue();
    }));
  }

  void _recordTileFailure(
      ReaderTileDemand tile, ImageWorkPriority priority, Object error) {
    final attempts = _queueRetryCounts[tile.variant] ?? 0;
    // A full shared queue is not a broken original. Give this still-visible
    // request two delayed admission attempts, without looping on decode,
    // source identity, or memory-budget failures.
    if (error is ImageWorkQueueExceeded && attempts < 2) {
      final generation = _generation;
      setState(() {
        _queueRetryCounts[tile.variant] = attempts + 1;
        _tileFailures.remove(tile.variant);
        _retryTimers[tile.variant] =
            Timer(Duration(milliseconds: attempts == 0 ? 150 : 450), () {
          _retryTimers.remove(tile.variant);
          if (!mounted ||
              generation != _generation ||
              !_desired.contains(tile.variant)) {
            return;
          }
          _request(tile, priority);
        });
      });
      ReaderRasterDiagnostics.record({
        'queueRetryScheduled': 1,
        'queueRetryAttempt': attempts + 1,
      });
      return;
    }
    setState(() => _tileFailures[tile.variant] = error);
  }

  bool _hasImageSpace(int bytes) {
    // Inactive pages yield their cache budget before visible work is evicted.
    return ReaderSessionRasterCache.trimToCombinedBudget(
            activeAndPendingBytes: _residentBytes + _pendingResidentBytes,
            requiredBytes: bytes,
            limitBytes: _globalResidentLimit) &&
        _bytes + _pendingBytes + bytes <= _residentLimit;
  }

  Future<void> _reservePendingImage(ui.Image image, ReaderTileDemand tile,
      ImageWorkCancellation cancel, int generation,
      {ReaderResolvedOriginal? resolved}) async {
    if (image.width != tile.outputWidth || image.height != tile.outputHeight) {
      throw StateError('解码未达到请求的原像素尺寸');
    }
    final bytes = image.width * image.height * 4;
    cancel.throwIfCancelled();
    if (!mounted || generation != _generation) {
      throw const ImageWorkCancelled();
    }
    if (resolved != null) await resolved.verifyCurrent();
    cancel.throwIfCancelled();
    if (!mounted || generation != _generation) {
      throw const ImageWorkCancelled();
    }
    for (var attempt = 0; attempt < 2 && !_hasImageSpace(bytes); attempt++) {
      for (final surface in _surfaces.toList()) {
        surface._evictUnneeded();
      }
      SchedulerBinding.instance.ensureVisualUpdate();
      await Future.any<void>(
          [WidgetsBinding.instance.endOfFrame, cancel.cancelled]);
      cancel.throwIfCancelled();
      if (!mounted || generation != _generation) {
        throw const ImageWorkCancelled();
      }
      if (resolved != null) await resolved.verifyCurrent();
      cancel.throwIfCancelled();
      if (!mounted || generation != _generation) {
        throw const ImageWorkCancelled();
      }
    }
    if (!_hasImageSpace(bytes)) {
      throw const ImageWorkBudgetExceeded(
          _globalResidentLimit + 1, _globalResidentLimit);
    }
    _pendingImages[image] = bytes;
    _pendingBytes += bytes;
    _pendingResidentBytes += bytes;
  }

  int? _releasePendingImage(ui.Image image) {
    final bytes = _pendingImages.remove(image);
    if (bytes != null) {
      _pendingBytes -= bytes;
      _pendingResidentBytes -= bytes;
    }
    return bytes;
  }

  void _discardPendingImage(ui.Image image) {
    if (_releasePendingImage(image) != null) image.dispose();
  }

  void _releasePendingHandoff(Object reservation) {
    final bytes = _pendingHandoffs.remove(reservation);
    if (bytes != null) {
      _pendingBytes -= bytes;
      _pendingResidentBytes -= bytes;
    }
  }

  void _evictUnneeded() {
    for (final key in _layers.keys.toList()) {
      if (_desired.contains(key)) continue;
      final layer = _layers.remove(key)!;
      _bytes -= layer.bytes;
      _retire(layer.image, sessionKey: layer.sessionKey, retainCache: false);
    }
    if (mounted) setState(() {});
  }

  void _trim() {
    for (final key in _layers.keys.toList()) {
      if (_bytes <= _residentLimit) break;
      if (_desired.contains(key)) continue;
      final layer = _layers.remove(key)!;
      _bytes -= layer.bytes;
      _retire(layer.image, sessionKey: layer.sessionKey);
    }
  }

  void _retire(ui.Image image,
      {ReaderSessionRasterKey? sessionKey, bool retainCache = true}) {
    if (retainCache && sessionKey != null) {
      final bytes = image.width * image.height * 4;
      if (ReaderSessionRasterCache.trimToCombinedBudget(
          activeAndPendingBytes: _residentBytes + _pendingResidentBytes,
          requiredBytes: bytes,
          limitBytes: _globalResidentLimit)) {
        widget.sessionRasterCache?.put(sessionKey, image,
            availableBytes: _globalResidentLimit -
                _residentBytes -
                _pendingResidentBytes -
                ReaderSessionRasterCache.totalRetainedBytes);
      }
    }
    _retired.add(image);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_retired.remove(image)) {
        _residentBytes -= image.width * image.height * 4;
        image.dispose();
      }
    });
  }

  Future<void> _holdBacking(String backing) async {
    final hold = _backingHolds.putIfAbsent(backing, () async {
      final file = File(backing);
      final existing = await file.exists() ? await file.length() : 0;
      final value = await ImageDiskQuota.shared
          .admitWorkspace(backing, peakBytes: math.max(1, existing));
      await value.finishWorkspace();
      return value;
    });
    try {
      await hold;
    } catch (_) {
      if (identical(_backingHolds[backing], hold)) {
        _backingHolds.remove(backing);
      }
      rethrow;
    }
  }

  void _clear({bool retainCache = true, bool resetFirstRaster = true}) {
    _generation++;
    _loadingTimer?.cancel();
    _loadingTimer = null;
    _showLoading = false;
    _pendingOriginalRaster?.cancel();
    _pendingOriginalRaster = null;
    _cancelIdleBacking();
    _backingPrepared = false;
    for (final ticket in _tickets.values) {
      ticket.cancel();
    }
    _tickets.clear();
    _estimating.clear();
    _firstRasterQueue.clear();
    _initialPreviewVariant = null;
    if (resetFirstRaster || !_firstRasterPresented) {
      _firstRasterReported = false;
      _firstRasterPresented = false;
    }
    _tileFailures.clear();
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _queueRetryCounts.clear();
    for (final image in _pendingImages.keys.toList()) {
      _discardPendingImage(image);
    }
    for (final reservation in _pendingHandoffs.keys.toList()) {
      _releasePendingHandoff(reservation);
    }
    for (final hold in _backingHolds.values) {
      unawaited(hold.then((value) => value.abort(), onError: (_) {}));
    }
    _backingHolds.clear();
    for (final layer in _layers.values) {
      _retire(layer.image,
          sessionKey: layer.sessionKey, retainCache: retainCache);
    }
    _layers.clear();
    _bytes = 0;
  }

  void _cancelIdleBacking() {
    _idleEpoch++;
    _idleTimer?.cancel();
    _idleTimer = null;
    _idleBacking?.cancel();
    _idleBacking = null;
  }

  // Baseline JPEG can display a scaled/cropped image without creating its
  // complete disk layer. Prepare that layer after the visible frame so later
  // pans read exact pixels directly. New viewport work cancels this idle job.
  void _scheduleIdleBacking() {
    if (_backingPrepared ||
        _idleTimer != null ||
        _idleBacking != null ||
        !widget.backend.supportsIdlePreparation ||
        (_metadata?.format != 'jpeg' &&
            widget.backend is! FlutterReaderRasterBackend) ||
        _file == null ||
        _desired.isEmpty ||
        !_desired.every(_layers.containsKey)) {
      return;
    }
    final generation = _generation;
    final epoch = _idleEpoch;
    final file = _file!;
    final backend = widget.backend;
    final sourceKey = sha256
        .convert(utf8.encode(widget.source.identity.stableKey))
        .toString();
    final backing =
        '${App.cachePath}/image_pipeline/native_backing/$sourceKey.rgba';
    _idleTimer = Timer(const Duration(milliseconds: 750), () {
      _idleTimer = null;
      unawaited(() async {
        final releaseEstimate = ReaderPageFileLease.acquire(file);
        try {
          final working = math.max(
              2 << 20,
              await backend.estimateBackingWorkingBytes(file,
                  backingPath: backing));
          if (!mounted || generation != _generation || epoch != _idleEpoch) {
            return;
          }
          final ticket = ImageWorkScheduler.shared.submit<void>(
              key: 'reader-backing:$sourceKey',
              priority: ImageWorkPriority.background,
              estimatedBytes: working,
              run: (cancel) async {
                cancel.throwIfCancelled();
                final releaseBacking =
                    DerivedImageStore.protectTemporaryPath(backing);
                final releaseOriginal = ReaderPageFileLease.acquire(file);
                try {
                  await _holdBacking(backing);
                  await Directory(File(backing).parent.path)
                      .create(recursive: true);
                  cancel.throwIfCancelled();
                  await backend.prepareBacking(file,
                      backingPath: backing,
                      memoryBudgetBytes: working,
                      cancelled: cancel.cancelled);
                  DerivedImageStore.scheduleMaintenance(backing);
                } finally {
                  releaseOriginal();
                  releaseBacking();
                }
              });
          _idleBacking = ticket;
          await ticket.future;
          if (mounted &&
              generation == _generation &&
              identical(_idleBacking, ticket)) {
            _backingPrepared = true;
          }
          if (identical(_idleBacking, ticket)) _idleBacking = null;
        } catch (_) {
          // Idle preparation is optional. The visible decoder retains its
          // normal bounded cold path if disk space or cancellation prevents it.
          if (generation == _generation && epoch == _idleEpoch) {
            _idleBacking = null;
          }
        } finally {
          releaseEstimate();
        }
      }());
    });
  }

  @override
  void didHaveMemoryPressure() {
    _clear(retainCache: false);
    if (_file == null) unawaited(_open());
    _scheduleViewport();
  }

  @override
  void didChangeMetrics() => _scheduleViewport();

  @override
  void dispose() {
    widget.transformChanges.removeListener(_scheduleViewport);
    _sourceCancellation.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _surfaces.remove(this);
    _clear();
    _releaseResolvedOriginal?.call();
    _releaseResolvedOriginal = null;
    for (final image in _retired) {
      _residentBytes -= image.width * image.height * 4;
      image.dispose();
    }
    _retired.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final complete = _desired.isNotEmpty && _desired.every(_layers.containsKey);
    if (!_firstRasterReported && _hasVisibleRaster) {
      _firstRasterReported = true;
      final buildAt = developer.Timeline.now;
      final generation = _generation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _generation) return;
        if (!_hasVisibleRaster) {
          _firstRasterReported = false;
          _drainFirstRasterQueue();
          return;
        }
        _firstRasterPresented = true;
        widget.onFirstRasterPresented?.call(buildAt);
        _drainFirstRasterQueue();
      });
    }
    final visibleError = _error ?? _visibleTileFailure;
    final rect = _demand?.visibleSourceRect;
    // Geometry.toString is diagnostic-only in dart:ui: profile builds return
    // "Instance of 'Rect'". Numeric coordinates keep different pans distinct.
    final stamp = '$_generation:${widget.source.identity.stableKey}:'
        '${rect?.left}:${rect?.top}:${rect?.right}:${rect?.bottom}:'
        '${_demand?.density}:$complete';
    if (complete &&
        _demand != null &&
        widget.onPresented != null &&
        _reportedFrame != stamp) {
      _reportedFrame = stamp;
      final frame = ReaderPresentedFrame(
          sourceRect: _demand!.visibleSourceRect,
          density: _demand!.density,
          complete: true,
          nativePixels: _demand!.density == 1,
          frameBuildTimelineUs: developer.Timeline.now);
      final generation = _generation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _generation == generation) {
          widget.onPresented?.call(frame);
        }
      });
    }
    return Semantics(
        label: widget.semanticLabel,
        image: true,
        child: LayoutBuilder(builder: (context, constraints) {
          if (_layoutSize != constraints.biggest) {
            _layoutSize = constraints.biggest;
            _scheduleViewport();
          }
          return Stack(fit: StackFit.expand, children: [
            CustomPaint(
                painter: _ReaderPainter(
                    widget.sourceSize,
                    _paintRect,
                    List.of(_layers.values),
                    _physicalSourceX,
                    _physicalSourceY,
                    _desired,
                    _demand?.visibleSourceRect ?? Rect.zero)),
            if (!complete && (visibleError != null || _showLoading))
              Align(
                  alignment: Alignment.center,
                  child: visibleError == null
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Material(
                          color: Theme.of(context)
                              .colorScheme
                              .surface
                              .withValues(alpha: 0.9),
                          child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text('图片暂时无法显示，请重试或重新打开此页',
                                        maxLines: 3),
                                    TextButton(
                                        onPressed: () {
                                          if (widget.reloadSource != null) {
                                            widget.reloadSource!();
                                            return;
                                          }
                                          setState(() {
                                            _error = null;
                                            for (final variant in _desired) {
                                              _tileFailures.remove(variant);
                                              _queueRetryCounts.remove(variant);
                                              _retryTimers
                                                  .remove(variant)
                                                  ?.cancel();
                                            }
                                          });
                                          _scheduleViewport();
                                        },
                                        child: const Text('重试')),
                                  ])))),
            if (!widget.source.isAuthoritativeOriginal)
              Align(
                  alignment: Alignment.bottomCenter,
                  child: Material(
                      color: Colors.black54,
                      child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Text('当前来源最高可用画质',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: Colors.white))))),
          ]);
        }));
  }
}

class _ReaderPainter extends CustomPainter {
  _ReaderPainter(
      this.sourceSize,
      this.destination,
      this.layers,
      this.physicalSourceX,
      this.physicalSourceY,
      this.desiredVariants,
      this.visibleSourceRect);
  final Size sourceSize;
  final Rect destination;
  final List<_ReaderLayer> layers;
  final Offset physicalSourceX, physicalSourceY;
  final Set<String> desiredVariants;
  final Rect visibleSourceRect;

  bool _nativePixelProjection(Canvas canvas) {
    // A composited ancestor transform is not necessarily part of the current
    // picture's Canvas CTM. Source-unit axes measured through localToGlobal
    // include those layers and DPR; the actual Canvas matrix is an additional
    // guard against rotation/shear/perspective during this paint.
    final matrix = canvas.getTransform();
    const roundoff = 0.000001;
    bool nearZero(double value) => value.abs() <= roundoff;
    bool axisAligned(Offset x, Offset y) =>
        nearZero(x.dy) && nearZero(y.dx) || nearZero(x.dx) && nearZero(y.dy);
    final canvasAffine = nearZero(matrix[3]) &&
        nearZero(matrix[7]) &&
        nearZero(matrix[11]) &&
        (matrix[15] - 1).abs() <= roundoff;
    return canvasAffine &&
        axisAligned(
            Offset(matrix[0], matrix[1]), Offset(matrix[4], matrix[5])) &&
        axisAligned(physicalSourceX, physicalSourceY) &&
        physicalSourceX.distance >= 1 - roundoff &&
        physicalSourceY.distance >= 1 - roundoff;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (destination.isEmpty) return;
    canvas.save();
    canvas.clipRect(destination);
    final preserveNativePixels = _nativePixelProjection(canvas);
    // An existing raster remains useful while a denser request is pending.
    // The disjoint clips below replace only the pixels that have arrived,
    // rather than blanking the old layer when zoom changes its target density.
    final sorted = layers
        .where((layer) =>
            !visibleSourceRect.intersect(layer.demand.sourceRect).isEmpty)
        .toList()
      ..sort((a, b) {
        final density = a.demand.density.compareTo(b.demand.density);
        if (density != 0) return density;
        final active = (desiredVariants.contains(a.variant) ? 1 : 0)
            .compareTo(desiredVariants.contains(b.variant) ? 1 : 0);
        if (active != 0) return active;
        final area = (b.demand.sourceRect.width * b.demand.sourceRect.height)
            .compareTo(a.demand.sourceRect.width * a.demand.sourceRect.height);
        return area != 0 ? area : a.variant.compareTo(b.variant);
      });
    Rect project(Rect rect) => Rect.fromLTRB(
        destination.left + rect.left / sourceSize.width * destination.width,
        destination.top + rect.top / sourceSize.height * destination.height,
        destination.left + rect.right / sourceSize.width * destination.width,
        destination.top + rect.bottom / sourceSize.height * destination.height);
    for (var i = 0; i < sorted.length; i++) {
      final layer = sorted[i];
      final rect = layer.demand.sourceRect;
      final dest = project(layer.demand.rasterRect);
      // A transparent pixel in the best available raster reveals the page
      // background, not a lower raster. Disjoint clips avoid double alpha
      // composition and a full-page offscreen layer while retaining previews
      // wherever a higher-density tile has not arrived.
      canvas.save();
      if (layer.demand.rasterRect != rect) {
        canvas.clipRect(project(rect), doAntiAlias: false);
      }
      for (var j = i + 1; j < sorted.length; j++) {
        final covered = rect.intersect(sorted[j].demand.sourceRect);
        if (!covered.isEmpty) {
          canvas.clipRect(project(covered),
              clipOp: ui.ClipOp.difference, doAntiAlias: false);
        }
      }
      canvas.drawImageRect(
          layer.image,
          Rect.fromLTWH(0, 0, layer.image.width.toDouble(),
              layer.image.height.toDouble()),
          dest,
          Paint()
            ..isAntiAlias = false
            ..filterQuality = layer.demand.density == 1 && preserveNativePixels
                ? FilterQuality.none
                : FilterQuality.medium);
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ReaderPainter oldDelegate) => true;
}
