import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'reader_image_limits.dart';

class StreamImageLoadResult {
  const StreamImageLoadResult({
    required this.stream,
    this.expectedTotalBytes,
    this.cancel,
  });

  final Stream<List<int>> stream;
  final int? expectedTotalBytes;

  /// Discard a response whose headers arrived before a consumer was admitted.
  final Future<void> Function()? cancel;
}

class StreamImageAbortSignal {
  final _completer = Completer<void>();

  bool get isAborted => _completer.isCompleted;

  Future<void> get aborted => _completer.future;

  void abort() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}

class StreamImageProvider extends BaseImageProvider<StreamImageProvider> {
  final FutureOr<Stream<List<int>>> Function()? loader;
  final FutureOr<StreamImageLoadResult> Function()? loadWithProgress;
  final String imageKey;
  final StreamImageAbortSignal? abortSignal;

  StreamImageProvider(this.loader, this.imageKey, {this.abortSignal})
      : loadWithProgress = null;

  StreamImageProvider.withProgress(this.loadWithProgress, this.imageKey,
      {this.abortSignal})
      : loader = null;

  @override
  bool get supportsReaderInputLimits => true;

  @override
  String get key => imageKey;

  @override
  Future<StreamImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<StreamImageProvider>(this);
  }

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) async {
    if (abortSignal?.isAborted == true) {
      throw StateError('Image load aborted');
    }
    final limits = ReaderImageReadLimits.current;
    limits?.check(0);
    final result = loadWithProgress == null
        ? StreamImageLoadResult(stream: await loader!())
        : await loadWithProgress!();
    try {
      limits?.check(result.expectedTotalBytes ?? 0);
    } catch (_) {
      if (result.cancel != null) {
        await result.cancel!();
      } else {
        await result.stream.listen((_) {}, onError: (Object _) {}).cancel();
      }
      rethrow;
    }
    final bytesBuilder = BytesBuilder(copy: false);
    var cumulativeBytesLoaded = 0;
    StreamSubscription<List<int>>? subscription;
    final loadCompleter = Completer<Uint8List>();
    var stopping = false;
    Future<void> stop(Object error, StackTrace stack) async {
      if (stopping || loadCompleter.isCompleted) return;
      stopping = true;
      await Future<void>.value();
      try { await subscription?.cancel(); } catch (_) {}
      bytesBuilder.clear();
      if (!loadCompleter.isCompleted) loadCompleter.completeError(error, stack);
    }
    void completeError(Object error, StackTrace stackTrace) {
      bytesBuilder.clear();
      if (!loadCompleter.isCompleted) {
        loadCompleter.completeError(error, stackTrace);
      }
    }

    subscription = result.stream.listen(
      (chunk) {
        if (abortSignal?.isAborted == true) {
          unawaited(stop(StateError('Image load aborted'), StackTrace.current));
          return;
        }
        if (stopping || loadCompleter.isCompleted) return;
        try {
          limits?.check(cumulativeBytesLoaded + chunk.length);
        } catch (error, stack) {
          // Do not complete the load (and release its reservation) until the
          // underlying subscription has really finished cancelling.
          unawaited(stop(error, stack));
          return;
        }
        bytesBuilder.add(chunk);
        cumulativeBytesLoaded += chunk.length;
        chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: cumulativeBytesLoaded,
            expectedTotalBytes: result.expectedTotalBytes,
          ),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        unawaited(stop(error, stackTrace));
      },
      onDone: () {
        if (!stopping && !loadCompleter.isCompleted) {
          try {
            limits?.check(cumulativeBytesLoaded);
            loadCompleter.complete(bytesBuilder.takeBytes());
          } catch (error, stack) { completeError(error, stack); }
        }
      },
      cancelOnError: true,
    );

    if (abortSignal != null) {
      unawaited(abortSignal!.aborted.then((_) =>
          stop(StateError('Image load aborted'), StackTrace.current)));
    }

    final cancelled = limits?.cancelled;
    if (cancelled != null && !identical(cancelled, abortSignal?.aborted)) {
      unawaited(cancelled.then((_) =>
          stop(StateError('Reader image input cancelled'), StackTrace.current)));
    }
    return loadCompleter.future;
  }
}
