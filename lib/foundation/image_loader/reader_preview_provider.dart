import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:picakeep/network/managed_image_retry.dart';

import 'base_image_provider.dart';
import 'reader_image_retry.dart';
import 'reader_image_limits.dart';
import 'reader_image_observation.dart';
import 'reader_image_stream_completer.dart';
export 'reader_image_limits.dart' show ReaderImageLimit;
export 'reader_image_observation.dart'
    show
        ReaderImageStage,
        ReaderImageFacts,
        ReaderImageReason,
        ReaderHttpStatusClass,
        ReaderEncodingContract,
        ReaderImageObservation,
        ReaderImageObservedFailure,
        observeReaderImageFailure,
        observeReaderImageFacts,
        observeReaderImageReason,
        observeReaderImageStage,
        forwardReaderImageFacts,
        forwardReaderImageStage;
import 'stream_image_provider.dart';

typedef ReaderPreviewProviderLoader = FutureOr<ImageProvider> Function(
    StreamImageAbortSignal abort);

class ReaderPreviewPreloadRejected implements Exception {
  const ReaderPreviewPreloadRejected(this.reason);
  final String reason;
  @override
  String toString() => 'Reader preview preload skipped: $reason';
}

class ReaderPreviewRetryEvent {
  const ReaderPreviewRetryEvent(this.retry, this.delay, this.error, this.stack,
      {this.stage = ReaderImageStage.unknown,
      this.executionId = 0,
      this.facts = const ReaderImageFacts()});
  final int retry;
  final Duration delay;
  final Object error;
  final StackTrace stack;
  final ReaderImageStage stage;
  final int executionId;
  final ReaderImageFacts facts;
}

// One process-wide allocator, not one budget per reader route. Unknown input
// acquisition stays serial until descriptor admission, preventing two full
// input reservations from deadlocking each other's decode upgrade.
class _PreviewBudget {
  static final instance = _PreviewBudget();
  static const maximumWork = 256 << 20, maximumPixels = 128 << 20;
  final pools = <ReaderPreviewImagePool>{};
  final loans = <_PreviewEntry>{};
  final waiting = <_PreviewEntry>[];
  _PreviewEntry? inputOwner, speculativeOwner;
  var work = 0, pixels = 0;
  var pulse = Completer<void>();

  void changed() {
    final previous = pulse;
    pulse = Completer<void>();
    previous.complete();
    for (final pool in pools.toList()) {
      pool._notify();
    }
  }

  void setLoan(_PreviewEntry entry, int decoded, int working) {
    work += working - entry.admittedWork;
    pixels += decoded - entry.admittedPixels;
    entry.admittedWork = working;
    entry.admittedPixels = decoded;
    if (working == 0 && decoded == 0) {
      loans.remove(entry);
    } else {
      loans.add(entry);
    }
    changed();
  }

  void releaseInput(_PreviewEntry entry) {
    if (identical(inputOwner, entry)) {
      inputOwner = null;
      changed();
    }
  }

  Future<void> reserveInput(_PreviewEntry entry) async {
    if (waiting.length >= 64) throw const ReaderImageLimit('queue');
    waiting.add(entry);
    Timer? timer;
    var timedOut = false;
    final deadline = Completer<void>();
    try {
      while (true) {
        if (entry.abort.isAborted) throw const ReaderImageCancelled();
        final firstVisible = waiting.where((e) => e.visible > 0).firstOrNull;
        final first = firstVisible ?? waiting.first;
        final requested = entry.pool.maximumInputBytes * 2;
        if (inputOwner == null &&
            identical(first, entry) &&
            (entry.visible > 0 || speculativeOwner == null) &&
            work + requested <= maximumWork) {
          inputOwner = entry;
          if (entry.visible == 0) speculativeOwner = entry;
          setLoan(entry, 0, requested);
          return;
        }
        // An ongoing read is cancellable/transport-bounded, not a permanent
        // budget error. Only stable residency pressure gets a short grace
        // period for a normal page-turn/retiring frame to release its loan.
        if (inputOwner == null &&
            identical(first, entry) &&
            work + requested > maximumWork) {
          timer ??= Timer(const Duration(seconds: 1), () {
            timedOut = true;
            deadline.complete();
          });
        }
        if (timedOut) throw const ReaderImageLimit('input-residency');
        await Future.any([pulse.future, entry.abort.aborted, deadline.future]);
      }
    } finally {
      timer?.cancel();
      waiting.remove(entry);
      changed();
    }
  }

  Future<void> reserveOverhead(_PreviewEntry entry, int overhead) async {
    if (overhead < 0) throw const ReaderImageLimit('provider-overhead');
    if (overhead == 0) return;
    final requested = entry.admittedWork + overhead;
    if (requested > maximumWork) {
      throw const ReaderImageLimit('provider-overhead');
    }
    final deadline = Completer<void>();
    Timer? timer;
    var timedOut = false;
    try {
      while (work - entry.admittedWork + requested > maximumWork) {
        if (entry.abort.isAborted) throw const ReaderImageCancelled();
        timer ??= Timer(const Duration(seconds: 1), () {
          timedOut = true;
          deadline.complete();
        });
        if (timedOut) throw const ReaderImageLimit('input-metadata-residency');
        await Future.any([pulse.future, entry.abort.aborted, deadline.future]);
      }
      if (entry.abort.isAborted) throw const ReaderImageCancelled();
      setLoan(entry, 0, requested);
    } finally {
      timer?.cancel();
    }
  }

  Future<void> admit(_PreviewEntry entry, int decoded, int encoded) async {
    final pool = entry.pool;
    if (decoded <= 0 || decoded > pool.maximumVisibleDecodedBytes) {
      throw const ReaderImageLimit('source-pixels');
    }
    final working = decoded * 3 + encoded * 2;
    if (working > maximumWork) throw const ReaderImageLimit('codec-work');
    Timer? timer;
    var timedOut = false;
    final deadline = Completer<void>();
    try {
      while (true) {
        if (entry.abort.isAborted) throw const ReaderImageCancelled();
        if (entry.visible == 0) {
          final speculative = loans.where((e) => e.visible == 0 && e != entry);
          final usedPixels =
              speculative.fold(0, (int n, e) => n + e.admittedPixels);
          final usedWork =
              speculative.fold(0, (int n, e) => n + e.admittedWork);
          if (decoded > entry.preloadLimit ||
              usedPixels + decoded > pool.maximumPreloadDecodedBytes ||
              usedWork + working > pool.maximumPreloadWorkingBytes) {
            throw const ReaderPreviewPreloadRejected('decoded-work-budget');
          }
        }
        if (pixels - entry.admittedPixels + decoded <= maximumPixels &&
            work - entry.admittedWork + working <= maximumWork) {
          setLoan(entry, decoded, working);
          releaseInput(entry);
          return;
        }
        if (entry.visible == 0) {
          throw const ReaderPreviewPreloadRejected('shared-work-budget');
        }
        timer ??= Timer(const Duration(seconds: 1), () {
          timedOut = true;
          deadline.complete();
        });
        if (timedOut) throw const ReaderImageLimit('shared-residency');
        await Future.any([pulse.future, entry.abort.aborted, deadline.future]);
      }
    } finally {
      timer?.cancel();
    }
  }
}

/// Consumers own leases, never the shared operation's abort signal. In
/// particular a preloader that leaves the window cannot cancel a visible page.
class ReaderPreviewImagePool extends ChangeNotifier {
  ReaderPreviewImagePool({
    Future<void> Function(Duration, StreamImageAbortSignal)? waitForRetry,
    this.maximumPreloadDecodedBytes = 64 << 20,
    this.maximumPreloadWorkingBytes = 128 << 20,
    this.maximumInputBytes = 64 << 20,
    this.maximumVisibleDecodedBytes = 64 << 20,
    @visibleForTesting this.onDecodeStarted,
    @visibleForTesting this.onFrameDecodeStarted,
  }) : _wait = waitForRetry ?? waitForReaderImageRetry {
    if (maximumInputBytes <= 0 ||
        maximumInputBytes > 64 << 20 ||
        maximumVisibleDecodedBytes <= 0 ||
        maximumVisibleDecodedBytes > 64 << 20) {
      throw ArgumentError('Invalid original preview input/pixel limits');
    }
    _PreviewBudget.instance.pools.add(this);
  }

  final int maximumPreloadDecodedBytes, maximumPreloadWorkingBytes;
  final int maximumInputBytes, maximumVisibleDecodedBytes;
  final VoidCallback? onDecodeStarted, onFrameDecodeStarted;
  int get reservedPreloadBytes => _PreviewBudget.instance.loans
      .where((e) => identical(e.pool, this) && e.visible == 0)
      .fold(0, (n, e) => n + e.admittedWork);
  int get reservedWorkingBytes => _PreviewBudget.instance.loans
      .where((e) => identical(e.pool, this))
      .fold(0, (n, e) => n + e.admittedWork);
  @visibleForTesting
  static int get globalReservedWorkingBytes => _PreviewBudget.instance.work;
  @visibleForTesting
  static int get globalReservedDecodedBytes => _PreviewBudget.instance.pixels;

  static final shared = ReaderPreviewImagePool();
  final Future<void> Function(Duration, StreamImageAbortSignal) _wait;
  final _entries = <String, _PreviewEntry>{};
  final _active = <_PreviewEntry>{};
  bool _disposed = false, _notificationQueued = false;

  bool get hasPendingVisible => _PreviewBudget.instance.pools
      .any((pool) => pool._active.any((e) => e.visible > 0 && !e.settled));
  int get activeEntryCount => _active.length;

  /// A real consumer has acquired this operation, not just a projected viewport.
  bool hasVisibleLease(String resourceKey) =>
      (_entries[resourceKey]?.visible ?? 0) > 0;

  ReaderPreviewImageLease acquire({
    required String resourceKey,
    required ReaderPreviewProviderLoader loadProvider,
    bool visible = true,
    int? maximumPreloadBytes,
  }) {
    if (_disposed) throw StateError('Reader preview pool disposed');
    if (visible && _entries[resourceKey]?.preloadRejected == true) {
      _entries.remove(resourceKey);
    }
    final entry = _entries.putIfAbsent(resourceKey, () {
      final value = _PreviewEntry(this, resourceKey, loadProvider,
          maximumPreloadBytes ?? maximumPreloadDecodedBytes);
      _active.add(value);
      return value;
    });
    entry.references++;
    if (visible) entry.visible++;
    _changed();
    return ReaderPreviewImageLease._(entry, visible);
  }

  /// Only this resource's failed provider/raw in-memory entry is invalidated.
  /// Source-owned disk/processed caches must be invalidated by onInvalidate at
  /// the reader adapter boundary, respecting any existing source file leases.
  Future<void> invalidate(String resourceKey) async {
    final old = _entries.remove(resourceKey);
    if (old == null) return;
    final source = old.source;
    if (source != null && _ReaderPreviewProvider.boundedProvider(source)) {
      if (source is BaseImageProvider) BaseImageProvider.evictKey(source.key);
      await source.evict();
    }
    await old.provider.evict();
  }

  void _releasePreloadBudget(_PreviewEntry entry) {
    // The source completer may request its animation look-ahead immediately
    // after delivering a frame. Observe it after this callback stack unwinds.
    if (identical(_PreviewBudget.instance.speculativeOwner, entry)) {
      scheduleMicrotask(() {
        final budget = _PreviewBudget.instance;
        if (identical(budget.speculativeOwner, entry) &&
            entry.pendingDecodeOperations == 0 &&
            entry.pendingStarts == 0 &&
            entry.retiringSources == 0 &&
            (entry.failedWithoutPixels ||
                entry.abort.isAborted ||
                (entry.settled &&
                    (entry.activeCodecs == 0 ||
                        entry.visible > 0 ||
                        entry.completer?._sourceListening == false)))) {
          budget.speculativeOwner = null;
          budget.changed();
        }
      });
    }
    if (entry.pendingDecodeOperations > 0 ||
        entry.pendingStarts > 0 ||
        entry.retiringSources > 0 ||
        entry.cacheEvictions > 0 ||
        entry.activeCodecs > 0) {
      return;
    }
    final budget = _PreviewBudget.instance;
    if ((_disposed || entry.references == 0 || entry.failedWithoutPixels)) {
      if (entry.decodedBytes > 0 && !entry.wrapperDisposed) return;
      if (_disposed || entry.references == 0) {
        entry.source = null;
        entry.retainedEncodedBytes = 0;
      }
      budget.releaseInput(entry);
      if (entry.admittedWork != 0 || entry.admittedPixels != 0) {
        budget.setLoan(entry, 0, 0);
      }
    } else if (entry.decodedBytes > 0 &&
        entry.admittedWork !=
            entry.admittedPixels + entry.retainedEncodedBytes) {
      // Only an ACTUALLY disposed static codec can shed encoded/native work.
      // MemoryImage's own bytes stay pinned; animations retain all codec work.
      budget.setLoan(entry, entry.admittedPixels,
          entry.admittedPixels + entry.retainedEncodedBytes);
    }
  }

  void _retireCache(_PreviewEntry entry) {
    if (entry.cacheRetired) return;
    entry.cacheRetired = true;
    entry.cacheEvictions++;
    unawaited(entry.provider.evict().whenComplete(() {
      entry.cacheEvictions--;
      _releasePreloadBudget(entry);
    }));
  }

  void _release(_PreviewEntry entry, bool visible) {
    entry.references--;
    if (visible) entry.visible--;
    if (entry.references == 0) {
      if (identical(_entries[entry.resourceKey], entry)) {
        _entries.remove(entry.resourceKey);
      }
      _active.remove(entry);
      _retireCache(entry);
      entry.abort.abort();
      entry.completer?.close();
      entry.observation.close();
      _releasePreloadBudget(entry);
      if (!entry.retryEvents.isClosed) unawaited(entry.retryEvents.close());
      // Our key is per-operation, not an underlying account/file ImageCache
      // key. This evicts pending work and decoded pixels without harming any
      // unrelated reader or cover consumers.
      // _retireCache owns the targeted asynchronous eviction.
    }
    _changed();
  }

  void _changed() => _PreviewBudget.instance.changed();

  void _notify() {
    if (_disposed || _notificationQueued) return;
    _notificationQueued = true;
    scheduleMicrotask(() {
      _notificationQueued = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _active.toList()) {
      _retireCache(entry);
      entry.abort.abort();
      entry.completer?.close();
      entry.observation.close();
      _releasePreloadBudget(entry);
      if (!entry.retryEvents.isClosed) unawaited(entry.retryEvents.close());
      // _retireCache owns the targeted asynchronous eviction.
    }
    _entries.clear();
    _active.clear();
    _PreviewBudget.instance.pools.remove(this);
    _PreviewBudget.instance.changed();
    super.dispose();
  }
}

class ReaderPreviewImageLease {
  ReaderPreviewImageLease._(this._entry, this._visible);
  final _PreviewEntry _entry;
  final bool _visible;
  bool _released = false;
  ImageProvider get provider => _entry.provider;
  Future<Size> get firstFrame => _entry.firstFrame.future;
  Stream<ReaderPreviewRetryEvent> get retries => _entry.retryEvents.stream;
  int get decodedBytes => _entry.decodedBytes;

  /// The shared operation's bounded failure relay. A consumer that joined after
  /// a prefetch reads the real stage here instead of guessing at the UI.
  ReaderImageObservation get observation => _entry.observation;
  ReaderImageFacts get facts => _entry.observation.facts;
  int get operationId => _entry.operationId;
  ReaderImageObservedFailure? get lastFailure => _entry.lastFailure;
  List<ReaderPreviewRetryEvent> get retryHistory =>
      List.unmodifiable(_entry.retryHistory);
  ReaderImageStage? stageFor(Object error) =>
      identical(_entry.lastFailure?.error, error)
          ? _entry.lastFailure!.stage
          : _entry.observation.stageFor(error);
  void release() {
    if (_released) return;
    _released = true;
    _entry.pool._release(_entry, _visible);
  }
}

class _PreviewEntry {
  _PreviewEntry(
      this.pool, this.resourceKey, this.loadProvider, this.preloadLimit) {
    provider = _ReaderPreviewProvider(this);
    operationId = observation.executionId;
    unawaited(firstFrame.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }
  final ReaderPreviewImagePool pool;
  final String resourceKey;
  final ReaderPreviewProviderLoader loadProvider;
  final abort = StreamImageAbortSignal();

  /// Operation-scoped, bounded observation relay shared by every consumer of
  /// this pool entry (a prefetch consumer that leaves, a visible joiner).
  late ReaderImageObservation observation =
      ReaderImageObservation(isCancelled: () => abort.isAborted);
  late final int operationId;
  ReaderImageObservedFailure? lastFailure;
  final retryHistory = <ReaderPreviewRetryEvent>[]; // at most three retries
  final firstFrame = Completer<Size>();
  final retryEvents = StreamController<ReaderPreviewRetryEvent>.broadcast();
  late final _ReaderPreviewProvider provider;
  ImageProvider? source;
  _ReaderPreviewCompleter? completer;
  final int preloadLimit;
  int admittedPixels = 0, admittedWork = 0, pendingDecodeOperations = 0;
  int retiringSources = 0, pendingStarts = 0, activeCodecs = 0;
  int cacheEvictions = 0;
  int references = 0, visible = 0, decodedBytes = 0, retainedEncodedBytes = 0;
  bool settled = false, preloadRejected = false;
  bool failedWithoutPixels = false,
      cacheRetired = false,
      wrapperDisposed = false;
}

/// Its identity belongs to one pool operation; retries never resurrect an
/// ImageCache completer carrying a previous consumer's one-shot cancellation.
class _ReaderPreviewProvider extends ImageProvider<_ReaderPreviewProvider> {
  _ReaderPreviewProvider(this.entry);
  final _PreviewEntry entry;
  ImageConfiguration configuration = ImageConfiguration.empty;

  @override
  Future<_ReaderPreviewProvider> obtainKey(ImageConfiguration configuration) {
    this.configuration = configuration;
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(
      _ReaderPreviewProvider key, ImageDecoderCallback decode) {
    return entry.completer ??=
        _ReaderPreviewCompleter(entry, configuration, decode);
  }

  static bool boundedProvider(ImageProvider source) =>
      source is BaseImageProvider && source.supportsReaderInputLimits ||
      source.runtimeType == MemoryImage ||
      source.runtimeType == FileImage;

  ImageStreamCompleter openSource(
      ImageProvider source, Object key, ImageDecoderCallback decode) {
    Future<ui.Codec> guarded(ui.ImmutableBuffer buffer,
        {ui.TargetImageSizeCallback? getTargetSize}) async {
      var delegated = false;
      entry.pendingDecodeOperations++;
      ui.ImageDescriptor? descriptor;
      try {
        if (entry.abort.isAborted) throw const ReaderImageCancelled();
        ReaderImageReadLimits.current!.check(buffer.length);
        descriptor = await observeReaderImageStage<ui.ImageDescriptor>(
            ReaderImageStage.decode, () => ui.ImageDescriptor.encoded(buffer));
        if (entry.abort.isAborted) throw const ReaderImageCancelled();
        final dimensions = descriptor;
        final bpp = dimensions.bytesPerPixel < 4 ? 4 : dimensions.bytesPerPixel;
        await observeReaderImageStage<void>(
            ReaderImageStage.decode,
            () => _PreviewBudget.instance.admit(entry,
                dimensions.width * dimensions.height * bpp, buffer.length));
        descriptor.dispose();
        descriptor = null;
        entry.pool.onDecodeStarted?.call();
        delegated = true;
        // This remains the provider's original full-resolution decoder. The
        // safety descriptor is not a native probe, ROI, or resize policy.
        final codec = await observeReaderImageStage(ReaderImageStage.decode,
            () => decode(buffer, getTargetSize: getTargetSize));
        if (entry.abort.isAborted) {
          codec.dispose();
          throw const ReaderImageCancelled();
        }
        return _PreviewTrackedCodec(codec, entry);
      } finally {
        descriptor?.dispose();
        if (!delegated) buffer.dispose();
        entry.pendingDecodeOperations--;
        entry.pool._releasePreloadBudget(entry);
      }
    }

    if (source is MemoryImage) {
      ReaderImageReadLimits.current!.check(source.bytes.length);
      Future<ui.Codec> loadMemory() async {
        final buffer = await observeReaderImageStage(ReaderImageStage.decode,
            () => ui.ImmutableBuffer.fromUint8List(source.bytes));
        return guarded(buffer);
      }

      return readerAwareImageCompleter(
          codec: loadMemory(), scale: source.scale);
    }
    if (source.runtimeType == FileImage) {
      final file = source as FileImage;
      // Flutter's FileImage reads into ImmutableBuffer before calling decode;
      // checking only buffer.length there would be too late. Preserve its file,
      // scale and original decoder, but bound the actual stream before copying.
      Future<ui.Codec> loadFile() async {
        final bytes = await observeReaderImageStage(
            ReaderImageStage.fetch, () => readReaderImageFile(file.file));
        ReaderImageReadLimits.current!.check(bytes.length);
        final buffer = await observeReaderImageStage(ReaderImageStage.decode,
            () => ui.ImmutableBuffer.fromUint8List(bytes));
        return guarded(buffer);
      }

      return readerAwareImageCompleter(codec: loadFile(), scale: file.scale);
    }
    return source.loadImage(key, guarded);
  }

  @override
  String toString() => 'ReaderPreviewProvider';
}

/// Track uninterruptible frame work so cancellation does not release a
/// speculative work reservation before the actual codec future has unwound.
class _PreviewTrackedCodec implements ui.Codec {
  _PreviewTrackedCodec(this.codec, this.entry)
      : observation = entry.observation {
    entry.activeCodecs++;
  }
  bool _disposed = false;
  final ui.Codec codec;
  final _PreviewEntry entry;
  final ReaderImageObservation observation;
  @override
  int get frameCount => codec.frameCount;
  @override
  int get repetitionCount => codec.repetitionCount;
  @override
  Future<ui.FrameInfo> getNextFrame() async {
    entry.pendingDecodeOperations++;
    try {
      if (entry.abort.isAborted) throw const ReaderImageCancelled();
      entry.pool.onFrameDecodeStarted?.call();
      late final ui.FrameInfo frame;
      try {
        frame = await codec.getNextFrame();
      } catch (error, stack) {
        // Framework animation callbacks need not run in the loader's Zone.
        try {
          observation.record(ReaderImageStage.decode, error, stack);
        } catch (_) {} // Diagnostics cannot replace the original frame failure.
        rethrow;
      }
      if (entry.abort.isAborted) {
        frame.image.dispose();
        throw const ReaderImageCancelled();
      }
      return frame;
    } finally {
      entry.pendingDecodeOperations--;
      entry.pool._releasePreloadBudget(entry);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    codec.dispose();
    entry.activeCodecs--;
    entry.pool._releasePreloadBudget(entry);
  }
}

class _ReaderPreviewCompleter extends ImageStreamCompleter {
  _ReaderPreviewCompleter(this.entry, this.configuration, this.decode) {
    _ownerHandle = keepAlive();
    unawaited(_start());
  }
  final _PreviewEntry entry;
  final ImageConfiguration configuration;
  final ImageDecoderCallback decode;
  ImageStreamCompleter? _sourceStream;
  ImageStreamListener? _listener;
  late final ImageStreamCompleterHandle _ownerHandle;
  ImageStreamCompleterHandle? _sourceHandle;
  bool _closed = false, _sourceListening = false;
  int _attempt = 0;
  ReaderImageObservation? _handledFailure;

  @override
  void addListener(ImageStreamListener listener) {
    super.addListener(listener);
    if (hasListeners &&
        !_sourceListening &&
        !_closed &&
        _sourceStream != null) {
      _sourceListening = true;
      _sourceStream!.addListener(_listener!);
    }
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    if (!hasListeners && entry.settled) _pauseSource();
  }

  void _pauseSource() {
    if (!_sourceListening || _sourceStream == null || _listener == null) return;
    _sourceListening = false;
    _sourceStream!.removeListener(_listener!);
  }

  Future<void> _start() async {
    Object? failure;
    StackTrace? failureStack;
    entry.failedWithoutPixels = false;
    // Retrying reuses the physical pool entry, NOT its failure deduplication.
    // Existing source work has retired before _start is called again.
    entry.observation.close();
    entry.observation =
        ReaderImageObservation(isCancelled: () => entry.abort.isAborted);
    final observation = entry.observation;
    entry.lastFailure = null;
    entry.pendingStarts++;
    try {
      await _PreviewBudget.instance.reserveInput(entry);
      final limits = ReaderImageReadLimits(
          maximumBytes: entry.pool.maximumInputBytes,
          isCancelled: () => entry.abort.isAborted,
          cancelled: entry.abort.aborted);
      await ReaderImageObservation.run(
          entry.observation,
          () => runWithReaderImageReadLimits(
              limits,
              () => runWithManagedImageRetry(() async {
                    if (_closed || entry.abort.isAborted) {
                      throw const ReaderImageCancelled();
                    }
                    final source = await entry.loadProvider(entry.abort);
                    entry.source = source;
                    entry.retainedEncodedBytes =
                        source is MemoryImage ? source.bytes.length : 0;
                    if (_closed || entry.abort.isAborted) {
                      throw const ReaderImageCancelled();
                    }
                    if (!_ReaderPreviewProvider.boundedProvider(source)) {
                      if (entry.visible == 0) {
                        throw const ReaderPreviewPreloadRejected(
                            'opaque-provider');
                      }
                      throw const ReaderImageLimit('unbounded-provider');
                    }
                    if (source is BaseImageProvider) {
                      await _PreviewBudget.instance.reserveOverhead(
                          entry, source.readerInputOverheadBytes);
                    }
                    final key = await source.obtainKey(configuration);
                    if (_closed || entry.abort.isAborted) {
                      throw const ReaderImageCancelled();
                    }
                    // Directly delegate the existing provider's full-resolution decoder.
                    // Resolving it through global ImageCache would inherit the abort owner
                    // of whichever provider instance happened to create that shared key.
                    final stream =
                        entry.provider.openSource(source, key, decode);
                    _sourceStream = stream;
                    _sourceHandle = stream.keepAlive();
                    final listener = ImageStreamListener((info, synchronous) {
                      if (_closed) {
                        info.dispose();
                        return;
                      }
                      final firstFrame = !entry.settled;
                      entry.settled = true;
                      final actualPixels =
                          info.image.width * info.image.height * 4;
                      entry.decodedBytes = entry.admittedPixels > actualPixels
                          ? entry.admittedPixels
                          : actualPixels;
                      if (!entry.firstFrame.isCompleted) {
                        entry.firstFrame.complete(Size(
                            info.image.width.toDouble(),
                            info.image.height.toDouble()));
                      }
                      setImage(info);
                      entry.pool._releasePreloadBudget(entry);
                      if (firstFrame) entry.pool._changed();
                      if (!hasListeners) _pauseSource();
                    }, onChunk: (chunk) {
                      if (!_closed) reportImageChunkEvent(chunk);
                    }, onError: (Object error, StackTrace? stack) {
                      unawaited(_failed(
                          error, stack ?? StackTrace.current, observation));
                    });
                    _listener = listener;
                    _sourceListening = true;
                    stream.addListener(listener);
                  })));
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      entry.pendingStarts--;
      entry.pool._releasePreloadBudget(entry);
    }
    if (failure != null) await _failed(failure, failureStack!, observation);
  }

  Future<void> _detach() {
    final stream = _sourceStream;
    final listener = _listener;
    final handle = _sourceHandle;
    final wasListening = _sourceListening;
    _sourceStream = null;
    _listener = null;
    _sourceHandle = null;
    _sourceListening = false;
    if (stream is ReaderImageStreamCompleter && handle != null) {
      if (wasListening && listener != null) stream.removeListener(listener);
      entry.retiringSources++;
      stream.retire();
      handle.dispose();
      return stream.retired.whenComplete(() {
        entry.retiringSources--;
        entry.pool._releasePreloadBudget(entry);
      });
    }
    if (stream != null && listener != null) {
      if (entry.abort.isAborted &&
          (!entry.settled || entry.pendingDecodeOperations > 0)) {
        // Disposing a Flutter completer clears ephemeral error listeners, even
        // though its byte/codec Future can still fail later. Keep exactly one
        // drain listener until that future actually emits an error or frame.
        entry.retiringSources++;
        final retired = Completer<void>();
        var finished = false;
        late final ImageStreamListener drain;
        void finish() {
          if (finished || entry.pendingDecodeOperations > 0) return;
          finished = true;
          stream.removeListener(drain);
          handle?.dispose();
          entry.retiringSources--;
          entry.pool._releasePreloadBudget(entry);
          retired.complete();
        }

        drain = ImageStreamListener((info, synchronous) {
          info.dispose();
          // An already-cached frame can be delivered synchronously while the
          // next frame is still in flight; that is not completion of the work.
          if (entry.pendingDecodeOperations == 0) finish();
        }, onError: (Object _, StackTrace? __) => finish());
        stream.addListener(drain);
        if (wasListening) stream.removeListener(listener);
        return retired.future;
      }
      if (wasListening) stream.removeListener(listener);
    }
    handle?.dispose();
    return Future<void>.value();
  }

  Future<void> _failed(Object error, StackTrace stack,
      ReaderImageObservation observation) async {
    if (!identical(entry.observation, observation) ||
        identical(_handledFailure, observation)) {
      return;
    }
    _handledFailure = observation;
    await _detach();
    entry.failedWithoutPixels = entry.decodedBytes == 0;
    if (entry.failedWithoutPixels && entry.source is MemoryImage) {
      // The caller may independently own its original bytes; this failed entry
      // must not pin another MemoryImage reference after returning its loan.
      entry.source = null;
      entry.retainedEncodedBytes = 0;
    }
    entry.pool._releasePreloadBudget(entry);
    if (_closed || entry.abort.isAborted) return;
    if (error is ReaderImageLimit && entry.visible == 0) {
      entry.preloadRejected = true;
    }
    if (error is ReaderPreviewPreloadRejected) {
      if (entry.visible > 0) {
        // A visible consumer joined between speculative admission and error
        // delivery. Restart this operation without imposing the preload policy.
        await _start();
        return;
      }
      entry.preloadRejected = true;
    }
    final observed = ReaderImageObservedFailure(
        stage: entry.observation.stageFor(error) ?? ReaderImageStage.unknown,
        error: error,
        stackTrace: stack,
        executionId: entry.observation.executionId,
        facts: entry.observation.factsFor(error));
    entry.lastFailure = observed;
    final delay = readerImageRetryDelay(error, _attempt + 1);
    if (delay != null && !entry.settled) {
      _attempt++;
      final event = ReaderPreviewRetryEvent(_attempt, delay, error, stack,
          stage: observed.stage,
          executionId: observed.executionId,
          facts: observed.facts);
      entry.retryHistory.add(event);
      entry.retryEvents.add(event);
      try {
        await entry.pool._wait(delay, entry.abort);
        if (!_closed) await _start();
      } on ReaderImageCancelled {
        // No consumer remains; never report a stale cancellation to a new page.
      }
      return;
    }
    entry.settled = true;
    if (!entry.firstFrame.isCompleted) {
      entry.firstFrame.completeError(error, stack);
    }
    entry.pool._changed();
    reportError(
        exception: error,
        stack: stack,
        context: ErrorDescription('while loading a complete reader preview'),
        silent: true);
  }

  @override
  void onDisposed() {
    entry.wrapperDisposed = true;
    entry.pool._releasePreloadBudget(entry);
    super.onDisposed();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_detach());
    if (!entry.firstFrame.isCompleted) {
      entry.firstFrame.completeError(const ReaderImageCancelled());
    }
    _ownerHandle.dispose();
  }
}
