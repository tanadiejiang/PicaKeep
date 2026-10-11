part of pica_reader;

/// Original full-provider display, with a page-scoped lifecycle around it.
/// There is no ReaderPageSource materialization, native probe, ROI or resize.
class ReaderPreviewPageImage extends StatefulWidget {
  const ReaderPreviewPageImage({
    super.key,
    required this.resourceKey,
    required this.loadProvider,
    this.pool,
    this.onInvalidate,
    this.onUseSafeWhole,
    this.controller,
    this.continuousWidth,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.backgroundDecoration,
    this.nativeScaleChanged,
    this.sizeHint,
    this.onSourceSize,
    this.failureDiagnostics,
  });

  final String resourceKey;
  final FutureOr<ImageProvider> Function(StreamImageAbortSignal) loadProvider;
  final ReaderPreviewImagePool? pool;
  final Future<void> Function()? onInvalidate;
  final VoidCallback? onUseSafeWhole;
  final PhotoViewController? controller;
  final double? continuousWidth;
  final BoxFit fit;
  final Alignment alignment;
  final BoxDecoration? backgroundDecoration;
  final ValueChanged<double>? nativeScaleChanged;
  final Size? sizeHint;
  final ValueChanged<Size>? onSourceSize;
  final ReaderFailurePageDiagnostics? failureDiagnostics;

  @override
  State<ReaderPreviewPageImage> createState() => _ReaderPreviewPageImageState();
}

class _ReaderPreviewPageImageState extends State<ReaderPreviewPageImage> {
  ReaderPreviewImageLease? _lease;
  StreamSubscription<ReaderPreviewRetryEvent>? _retryEvents;
  ReaderFailureAttemptDiagnostics? _diagnostics;
  ReaderPreviewImagePool get _pool =>
      widget.pool ?? ReaderPreviewImagePool.shared;
  Size? _size;
  int _generation = 0;
  bool _error = false, _failureQueued = false;
  String? _limitMessage;
  bool _canUseSafeWhole = false;

  // The real innermost boundary recorded by the shared operation, or unknown
  // when only an opaque/generic provider was actually involved.
  String _stageFor(Object error) =>
      (_lease?.stageFor(error) ?? ReaderImageStage.unknown).token;

  @override
  void initState() {
    super.initState();
    _size = widget.sizeHint;
    _start();
  }

  void _start(
      {bool explicitRetry = false,
      int? generation,
      ReaderFailureAttemptDiagnostics? attempt}) {
    final currentGeneration = generation ?? (_generation + 1);
    _generation = currentGeneration;
    _error = false;
    _failureQueued = false;
    _limitMessage = null;
    _canUseSafeWhole = false;
    if (attempt != null) {
      // The explicit-retry attempt was already begun before invalidation so a
      // cache-stage invalidation failure belongs to the user's new retry.
      _diagnostics = attempt;
    } else {
      _diagnostics?.close();
      _diagnostics = widget.failureDiagnostics?.beginAttempt(
          generation: currentGeneration,
          qualityMode: 'previewFirst',
          explicitRetry: explicitRetry);
    }
    _diagnostics?.rendererPath('providerWhole');
    final lease = _pool.acquire(
        resourceKey: widget.resourceKey, loadProvider: widget.loadProvider);
    _lease = lease;
    unawaited(_retryEvents?.cancel());
    final seenRetries = <int>{}; // physical retry ownership remains in the pool
    void reportRetry(ReaderPreviewRetryEvent event, {bool replayed = false}) {
      if (!mounted ||
          currentGeneration != _generation ||
          !seenRetries.add(event.retry)) {
        return;
      }
      final snapshot = <String, Object?>{
        ...event.facts.toSnapshot(),
        'operationId': lease.operationId,
        'executionId': event.executionId,
        'replayed': replayed,
      };
      _diagnostics?.failure(
          stage: event.stage.token,
          error: event.error,
          stackTrace: event.stack,
          terminal: false,
          reasonHint: event.facts.reasonHint,
          snapshot: snapshot);
      _diagnostics?.retry(
          stage: event.stage.token, retry: event.retry, snapshot: snapshot);
    }

    _retryEvents = lease.retries.listen(reportRetry);
    // A prefetched operation can already be waiting for a retry. Replaying its
    // bounded diagnostics never schedules work or transfers cancellation rights.
    for (final event in lease.retryHistory) {
      reportRetry(event, replayed: true);
    }
    unawaited(lease.firstFrame.then((size) {
      if (!mounted || currentGeneration != _generation) return;
      _reportSize(size);
      _diagnostics?.recovered(snapshot: lease.facts.toSnapshot());
    }, onError: (Object error, StackTrace stack) {
      _failed(error, stack, currentGeneration);
    }));
  }

  void _reportSize(Size size) {
    if (!mounted || size.width <= 0 || size.height <= 0 || _size == size) {
      return;
    }
    setState(() => _size = size);
    _diagnostics?.updateSource(
        sourceType: 'provider',
        backendType: 'flutterWhole',
        width: size.width,
        height: size.height);
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _generation) widget.onSourceSize?.call(size);
    });
  }

  void _failed(Object error, StackTrace? stack, int generation,
      {ReaderImageStage? stage, ReaderImageFacts? facts}) {
    if (!mounted || generation != _generation || _failureQueued || _error) {
      return;
    }
    _failureQueued = true;
    _limitMessage = error is ReaderImageLimit ? error.message : null;
    _canUseSafeWhole =
        error is ReaderImageLimit && !error.reason.startsWith('jm-recombine-');
    // One physical failure must not be counted twice when it surfaces through
    // the firstFrame future and the image errorBuilder of the same attempt.
    final failure = _lease?.lastFailure;
    final observedFacts = facts ??
        (failure != null && identical(failure.error, error) ? failure.facts : _lease?.facts);
    _diagnostics?.failure(
        stage: stage?.token ?? _stageFor(error),
        error: error,
        stackTrace: stack,
        reasonHint: observedFacts?.reasonHint,
        snapshot: {
          ...?observedFacts?.toSnapshot(),
          if (_lease != null) 'operationId': _lease!.operationId,
          if (failure != null && identical(failure.error, error))
            'executionId': failure.executionId,
        });
    void update() {
      if (mounted && generation == _generation) setState(() => _error = true);
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => update());
    } else {
      update();
    }
  }

  Future<void> _retry() async {
    final generation = _generation + 1;
    _generation = generation;
    // Own the new retry attempt BEFORE invalidation: an invalidation failure is
    // recorded against the user's new retry (cache stage), never the superseded
    // attempt/generation, and the successful restart does not begin it twice.
    final attempt = widget.failureDiagnostics?.beginAttempt(
        generation: generation,
        qualityMode: 'previewFirst',
        explicitRetry: true);
    _diagnostics?.close();
    _diagnostics = attempt;
    final pool = _pool;
    final invalidateSource = widget.onInvalidate;
    final observation = ReaderImageObservation(
        isCancelled: () => !mounted || generation != _generation);
    final invalidate = ReaderImageObservation.run(
        observation,
        () => observeReaderImageStage(
            ReaderImageStage.cache, () => pool.invalidate(widget.resourceKey)));
    _lease?.release();
    _lease = null;
    setState(() {
      _error = false;
      _failureQueued = false;
    });
    try {
      await invalidate;
      if (!mounted || generation != _generation) return;
      await ReaderImageObservation.run(
          observation,
          () => observeReaderImageStage(ReaderImageStage.cache,
              () => invalidateSource?.call() ?? Future<void>.value()));
      if (!mounted || generation != _generation) return;
      setState(() => _start(generation: generation, attempt: attempt));
    } catch (error, stack) {
      // The guarded UI entry rejects a late invalidation from an old page.
      _failed(error, stack, generation,
          stage: observation.stageFor(error) ?? ReaderImageStage.unknown,
          facts: observation.factsFor(error));
    } finally {
      observation.close();
    }
  }

  @override
  void didUpdateWidget(ReaderPreviewPageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resourceKey != widget.resourceKey ||
        oldWidget.pool != widget.pool) {
      _generation++;
      _lease?.release();
      _size = widget.sizeHint;
      _start();
    } else if (_size == null && widget.sizeHint != null) {
      _size = widget.sizeHint;
    }
  }

  Widget _pending([ImageChunkEvent? event]) {
    final total = event?.expectedTotalBytes;
    final value = total != null && total > 0
        ? (event!.cumulativeBytesLoaded / total).clamp(0.0, 1.0)
        : null;
    return Center(
        child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(value: value, strokeWidth: 2)));
  }

  Widget _failure() => Center(
      child: Material(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
                child: SingleChildScrollView(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(_limitMessage ?? '图片暂时无法打开，请重试')))),
            if (_canUseSafeWhole && widget.onUseSafeWhole != null)
              TextButton(
                  onPressed: widget.onUseSafeWhole,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: Text('改用清晰优先（安全整图）'.tl)),
            TextButton(
                onPressed: _retry,
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                child: Text('重试'.tl)),
          ])));

  @override
  Widget build(BuildContext context) {
    final width = widget.continuousWidth;
    final size = _size ?? widget.sizeHint;
    if (width != null && size != null) {
      widget.nativeScaleChanged
          ?.call(size.width / width / View.of(context).devicePixelRatio);
    }
    if (_error || _lease == null) {
      final child = _error ? _failure() : _pending();
      return width == null
          ? child
          : SizedBox(
              width: width,
              height: _error
                  ? math.max(160.0,
                      width * (size == null ? 1.45 : size.height / size.width))
                  : width * (size == null ? 1.45 : size.height / size.width),
              child: child);
    }
    final generation = _generation;
    if (width != null) {
      return ComicImage(
          key: ValueKey(generation),
          image: _lease!.provider,
          width: width,
          fit: widget.fit,
          alignment: widget.alignment,
          knownImageSize: size,
          onSourceSize: _reportSize,
          onError: (error, stack) => _failed(error, stack, generation),
          onRetry: _retry);
    }
    return LayoutBuilder(builder: (context, constraints) {
      // Double-page mode already has an outer PhotoViewGallery. Do not nest a
      // gesture owner here; only single-page mode supplies a controller.
      if (widget.controller == null) {
        if (size != null) {
          final fitScale = math.min(constraints.maxWidth / size.width,
              constraints.maxHeight / size.height);
          if (fitScale > 0 && fitScale.isFinite) {
            widget.nativeScaleChanged
                ?.call(1 / fitScale / View.of(context).devicePixelRatio);
          }
        }
        return Image(
            image: _lease!.provider,
            fit: widget.fit,
            alignment: widget.alignment,
            filterQuality: FilterQuality.medium,
            width: constraints.hasBoundedWidth ? constraints.maxWidth : null,
            height: constraints.hasBoundedHeight ? constraints.maxHeight : null,
            frameBuilder: (_, child, frame, synchronous) =>
                frame == null ? _pending() : child,
            loadingBuilder: (_, child, event) =>
                event == null ? child : _pending(event),
            errorBuilder: (_, error, stack) {
              _failed(error, stack, generation);
              return _failure();
            });
      }
      final dynamic initial = size == null
          ? PhotoViewComputedScale.contained
          : switch (widget.fit) {
              BoxFit.fitWidth => constraints.maxWidth / size.width,
              BoxFit.fitHeight => constraints.maxHeight / size.height,
              _ => PhotoViewComputedScale.contained,
            };
      widget.nativeScaleChanged?.call(1 / View.of(context).devicePixelRatio);
      return ReaderPhotoViewOwner(
          key: ValueKey(generation),
          controller: widget.controller!,
          builder: (_, controller, scaleState) => PhotoView(
          key: ValueKey(generation),
          imageProvider: _lease!.provider,
          controller: controller,
          scaleStateController: scaleState,
          backgroundDecoration: widget.backgroundDecoration,
          filterQuality: FilterQuality.medium,
          minScale: PhotoViewComputedScale.contained,
          initialScale: initial,
          maxScale: PhotoViewComputedScale.covered * 8,
          basePosition: widget.fit == BoxFit.fitWidth
              ? Alignment.topCenter
              : widget.alignment,
          loadingBuilder: (_, event) => _pending(event),
          errorBuilder: (_, error, stack, legacyRetry) {
            _failed(error, stack, generation);
            return _failure();
          }));
    });
  }

  @override
  void dispose() {
    _generation++;
    _lease?.release();
    unawaited(_retryEvents?.cancel());
    _diagnostics?.close();
    super.dispose();
  }
}
