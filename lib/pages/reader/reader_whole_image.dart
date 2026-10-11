import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_failure_diagnostics.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';

class ReaderWholeImageLimit implements Exception {
  const ReaderWholeImageLimit(this.kind, this.message);
  final String kind;
  final String message;
  @override
  String toString() => message;
}

/// Every demand made by this policy covers exactly the full original rectangle.
/// It is independent of the visible viewport and of zoom/drag transforms.
class ReaderWholeImagePlan {
  const ReaderWholeImagePlan._(this.demand);
  final ReaderTileDemand demand;
  bool get downsampled => demand.density < 1;
  int get rasterBytes => demand.outputWidth * demand.outputHeight * 4;

  factory ReaderWholeImagePlan.create({
    required Size sourceSize,
    required ReaderLargeImagePolicy policy,
    int textureEdge = 4096,
    int rasterBudgetBytes = 64 << 20,
  }) {
    if (!sourceSize.width.isFinite ||
        !sourceSize.height.isFinite ||
        sourceSize.width <= 0 ||
        sourceSize.height <= 0 ||
        sourceSize.width != sourceSize.width.roundToDouble() ||
        sourceSize.height != sourceSize.height.roundToDouble() ||
        textureEdge <= 0 ||
        rasterBudgetBytes < 4) {
      throw const ReaderWholeImageLimit('dimensions', '图片尺寸无效，无法安全整图显示');
    }
    final bounds = Offset.zero & sourceSize;
    ReaderTileDemand make(double density) =>
        ReaderTileDemand(bounds, density, -1, -1);
    bool fits(ReaderTileDemand demand) =>
        demand.outputWidth <= textureEdge &&
        demand.outputHeight <= textureEdge &&
        demand.outputWidth * demand.outputHeight * 4 <= rasterBudgetBytes;
    final original = make(1);
    if (fits(original)) return ReaderWholeImagePlan._(original);
    if (policy == ReaderLargeImagePolicy.strictOriginal) {
      throw const ReaderWholeImageLimit(
          'original-limit', '原尺寸超出当前整图安全上限，可在阅读设置改为安全整图显示');
    }
    var low = 0.0;
    var high = math.min(
        1.0,
        math.min(
            textureEdge / sourceSize.width, textureEdge / sourceSize.height));
    // Binary search includes ceil-to-pixel rounding, including very thin pages.
    for (var i = 0; i < 40; i++) {
      final middle = (low + high) / 2;
      if (fits(make(middle))) {
        low = middle;
      } else {
        high = middle;
      }
    }
    if (low <= 0 || !fits(make(low))) {
      throw const ReaderWholeImageLimit('raster-limit', '当前预算无法容纳完整图片');
    }
    return ReaderWholeImagePlan._(make(low));
  }

  ReaderWholeImagePlan atDensity(double density) {
    if (!density.isFinite || density <= 0 || density > demand.density) {
      throw ArgumentError.value(density, 'density');
    }
    return ReaderWholeImagePlan._(
        ReaderTileDemand(demand.sourceRect, density, -1, -1));
  }
}

/// Resident output is charged until actual image disposal, not until its job's
/// Future completes. The scheduler separately accounts for decoder working sets.
class ReaderWholeImageResidency {
  ReaderWholeImageResidency({this.maximumBytes = 192 << 20});
  static final shared = ReaderWholeImageResidency();
  final int maximumBytes;
  int _bytes = 0;
  int get bytes => _bytes;

  VoidCallback reserve(int bytes) {
    if (bytes < 0 || _bytes + bytes > maximumBytes) {
      throw ImageWorkBudgetExceeded(bytes, maximumBytes - _bytes);
    }
    _bytes += bytes;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _bytes -= bytes;
    };
  }
}

class _WholeRaster {
  _WholeRaster(this.image, this.plan, this.release);
  final ui.Image image;
  final ReaderWholeImagePlan plan;
  final VoidCallback release;
  bool _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    image.dispose();
    release();
  }
}

/// The sharp reader's single-raster renderer. It never constructs a viewport
/// demand, requests a partial source rectangle, or falls back to a tile surface.
class ReaderWholeImage extends StatefulWidget {
  const ReaderWholeImage(
      {super.key,
      required this.file,
      required this.resourceKey,
      required this.metadata,
      required this.backend,
      required this.policy,
      this.fit = BoxFit.contain,
      this.alignment = Alignment.center,
      this.textureEdge = 4096,
      this.maximumWorkingBytes = 256 << 20,
      this.scheduler,
      this.residency,
      this.verifyOriginal,
      this.failureAttempt,
      this.onUseSafeWhole,
      this.reloadSource,
      this.onFailure,
      this.onFirstRasterPresented});

  final File file;
  final String resourceKey;
  final ReaderRasterMetadata metadata;
  final ReaderRasterBackend backend;
  final ReaderLargeImagePolicy policy;
  final BoxFit fit;
  final Alignment alignment;
  final int textureEdge, maximumWorkingBytes;
  final ImageWorkScheduler? scheduler;
  final ReaderWholeImageResidency? residency;
  final Future<void> Function()? verifyOriginal;
  final ReaderFailureAttemptDiagnostics? failureAttempt;
  final VoidCallback? onUseSafeWhole, reloadSource;
  final ValueChanged<int>? onFirstRasterPresented;
  final ValueChanged<Object>? onFailure;

  @override
  State<ReaderWholeImage> createState() => _ReaderWholeImageState();
}

class _ReaderWholeImageState extends State<ReaderWholeImage> {
  static int _nextInstance = 0;
  final _instance = _nextInstance++;
  int _generation = 0;
  ImageWorkTicket<_WholeRaster>? _ticket;
  _WholeRaster? _raster;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(ReaderWholeImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resourceKey != widget.resourceKey ||
        oldWidget.file.path != widget.file.path ||
        oldWidget.policy != widget.policy ||
        oldWidget.metadata.size != widget.metadata.size ||
        oldWidget.backend != widget.backend ||
        oldWidget.textureEdge != widget.textureEdge) {
      _retire();
      _start();
    }
  }

  void _retire() {
    _generation++;
    _ticket?.cancel();
    _ticket = null;
    final old = _raster;
    _raster = null;
    // The previous frame can still reference its RawImage until frame end.
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    _error = null;
  }

  void _start() {
    final generation = ++_generation;
    unawaited(_load(generation));
  }

  bool _current(int generation) => mounted && generation == _generation;

  Future<({ReaderWholeImagePlan plan, int working})> _admit(
      ReaderWholeImagePlan initial,
      File file,
      ReaderRasterBackend backend,
      String backing,
      int budget,
      int generation) async {
    Future<int> estimate(ReaderWholeImagePlan plan) async {
      final result = await backend.estimateWorkingBytes(file, plan.demand,
          backingPath: backing);
      if (!_current(generation)) throw const ImageWorkCancelled();
      return math.max(2 << 20, result);
    }

    final originalEstimate = await estimate(initial);
    if (originalEstimate <= budget) {
      return (plan: initial, working: originalEstimate);
    }
    if (widget.policy == ReaderLargeImagePolicy.strictOriginal) {
      throw ImageWorkBudgetExceeded(originalEstimate, budget);
    }
    // A smaller target is only accepted if the backend's real codec working-set
    // estimate also fits. A source-sized PNG/WebP allocation cannot be hidden by
    // asking for a tiny result. No pixels are decoded during this search.
    var low = 0.0, high = initial.demand.density;
    ReaderWholeImagePlan? accepted;
    var acceptedWorking = 0;
    for (var i = 0; i < 12; i++) {
      final density = (low + high) / 2;
      final candidate = initial.atDensity(density);
      final working = await estimate(candidate);
      if (working <= budget) {
        accepted = candidate;
        acceptedWorking = working;
        low = density;
      } else {
        high = density;
      }
    }
    if (accepted == null) {
      throw ImageWorkBudgetExceeded(originalEstimate, budget);
    }
    return (plan: accepted, working: acceptedWorking);
  }

  Future<void> _load(int generation) async {
    final file = widget.file;
    final backend = widget.backend;
    final verify = widget.verifyOriginal;
    final diagnostics = widget.failureAttempt;
    final scheduler = widget.scheduler ?? ImageWorkScheduler.shared;
    final residency = widget.residency ?? ReaderWholeImageResidency.shared;
    final releaseEstimate = ReaderPageFileLease.acquire(file);
    var stage = 'wholeAdmission';
    try {
      await verify?.call();
      if (!_current(generation)) return;
      if (widget.metadata.animated) {
        throw const ReaderWholeImageLimit(
            'animated', '此动态图暂不支持清晰整图显示，请切换预览优先以播放完整动画');
      }
      final initial = ReaderWholeImagePlan.create(
          sourceSize: widget.metadata.size,
          policy: widget.policy,
          textureEdge: widget.textureEdge);
      final key = sha256.convert(utf8.encode('whole-v1:${widget.resourceKey}'));
      final backing =
          '${App.cachePath}/image_pipeline/native_backing/whole-$key.rgba';
      final admitted = await _admit(
          initial,
          file,
          backend,
          backing,
          math.min(scheduler.memoryBudgetBytes, widget.maximumWorkingBytes),
          generation);
      if (!_current(generation)) return;
      final plan = admitted.plan;
      diagnostics?.rendererPath(
          widget.policy == ReaderLargeImagePolicy.strictOriginal
              ? 'strictWhole'
              : 'safeWhole');
      stage = 'wholeDecode';
      final ticket = scheduler.submit<_WholeRaster>(
        // The output has exactly one owner. Separate page widgets must not
        // dispose a shared ui.Image when another is still painting it.
        key: 'whole-v1:$key:$_instance:$generation:${widget.policy.name}',
        priority: ImageWorkPriority.visible, estimatedBytes: admitted.working,
        lane: backend.executionLane,
        disposeResult: (result) => result.dispose(),
        run: (cancellation) async {
          final releaseFile = ReaderPageFileLease.acquire(file);
          VoidCallback? releaseResident;
          ui.Image? image;
          try {
            cancellation.throwIfCancelled();
            await verify?.call();
            cancellation.throwIfCancelled();
            releaseResident = residency.reserve(plan.rasterBytes);
            image = await backend.decode(file, plan.demand,
                backingPath: backing,
                memoryBudgetBytes: admitted.working,
                isCancelled: () => cancellation.isCancelled,
                cancelled: cancellation.cancelled);
            cancellation.throwIfCancelled();
            await verify?.call();
            cancellation.throwIfCancelled();
            if (image.width != plan.demand.outputWidth ||
                image.height != plan.demand.outputHeight) {
              throw const ReaderWholeImageLimit('output', '整图解码尺寸不符合请求');
            }
            final result = _WholeRaster(image, plan, releaseResident);
            image = null;
            releaseResident = null;
            return result;
          } finally {
            image?.dispose();
            releaseResident?.call();
            // This lease follows the actual decoder, even when ticket.future
            // already completed with cancellation during a non-preemptible call.
            releaseFile();
          }
        },
      );
      _ticket = ticket;
      final result = await ticket.future;
      if (!_current(generation)) {
        result.dispose();
        return;
      }
      setState(() => _raster = result);
      widget.onFirstRasterPresented?.call(plan.rasterBytes);
    } catch (error, stack) {
      if (!_current(generation) || error is ImageWorkCancelled) return;
      diagnostics?.failure(stage: stage, error: error, stackTrace: stack);
      setState(() => _error = error);
      widget.onFailure?.call(error);
    } finally {
      releaseEstimate();
    }
  }

  @override
  Widget build(BuildContext context) {
    final raster = _raster;
    if (raster != null) {
      return Stack(fit: StackFit.expand, children: [
        FittedBox(
            fit: widget.fit,
            alignment: widget.alignment,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
                width: widget.metadata.size.width,
                height: widget.metadata.size.height,
                // Integer target rounding must not change the original aspect
                // ratio (especially for extremely thin, long source images).
                child: RawImage(
                    image: raster.image,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.high))),
        if (raster.plan.downsampled)
          Positioned(
              right: 8,
              bottom: 8,
              child: Tooltip(
                message: '已按安全上限整图显示，原文件未修改',
                child: Semantics(
                    label: '已按安全上限整图显示，原文件未修改',
                    child: DecoratedBox(
                        decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surface
                                .withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(12)),
                        child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.photo_size_select_large,
                                size: 16)))),
              )),
      ]);
    }
    final error = _error;
    if (error == null) return const Center(child: CircularProgressIndicator());
    final explanation = error is ReaderWholeImageLimit
        ? error.message
        : error is ImageWorkBudgetExceeded
            ? '当前整图解码超出安全内存预算；可改为安全整图显示，或重试'
            : '图片暂时无法打开，请重试';
    return Center(
        child: SingleChildScrollView(
            child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(explanation, textAlign: TextAlign.center),
        TextButton(
            onPressed: () {
              if (widget.reloadSource != null) {
                widget.reloadSource!();
              } else {
                setState(_retire);
                _start();
              }
            },
            child: const Text('重试')),
        if (widget.policy == ReaderLargeImagePolicy.strictOriginal &&
            widget.onUseSafeWhole != null)
          TextButton(
              onPressed: widget.onUseSafeWhole, child: const Text('改为安全整图显示')),
      ]),
    )));
  }

  @override
  void dispose() {
    _retire();
    super.dispose();
  }
}
