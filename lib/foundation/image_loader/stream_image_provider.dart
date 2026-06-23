import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';

class StreamImageLoadResult {
  const StreamImageLoadResult({
    required this.stream,
    this.expectedTotalBytes,
  });

  final Stream<List<int>> stream;
  final int? expectedTotalBytes;
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
    final result = loadWithProgress == null
        ? StreamImageLoadResult(stream: await loader!())
        : await loadWithProgress!();
    final bytesBuilder = BytesBuilder(copy: false);
    var cumulativeBytesLoaded = 0;
    StreamSubscription<List<int>>? subscription;
    final loadCompleter = Completer<Uint8List>();
    void completeError(Object error, StackTrace stackTrace) {
      if (!loadCompleter.isCompleted) {
        loadCompleter.completeError(error, stackTrace);
      }
    }

    subscription = result.stream.listen(
      (chunk) {
        if (abortSignal?.isAborted == true) {
          unawaited(subscription?.cancel());
          completeError(StateError('Image load aborted'), StackTrace.current);
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
        completeError(error, stackTrace);
      },
      onDone: () {
        if (!loadCompleter.isCompleted) {
          loadCompleter.complete(bytesBuilder.takeBytes());
        }
      },
      cancelOnError: true,
    );

    if (abortSignal != null) {
      unawaited(abortSignal!.aborted.then((_) async {
        try {
          await subscription?.cancel();
        } catch (_) {}
        completeError(StateError('Image load aborted'), StackTrace.current);
      }));
    }

    return loadCompleter.future;
  }
}
