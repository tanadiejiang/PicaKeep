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

class StreamImageProvider extends BaseImageProvider<StreamImageProvider> {
  final FutureOr<Stream<List<int>>> Function()? loader;
  final FutureOr<StreamImageLoadResult> Function()? loadWithProgress;
  final String imageKey;

  StreamImageProvider(
    this.loader,
    this.imageKey,
  ) : loadWithProgress = null;

  StreamImageProvider.withProgress(
    this.loadWithProgress,
    this.imageKey,
  ) : loader = null;

  @override
  String get key => imageKey;

  @override
  Future<StreamImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<StreamImageProvider>(this);
  }

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) async {
    final result = loadWithProgress == null
        ? StreamImageLoadResult(stream: await loader!())
        : await loadWithProgress!();
    final bytesBuilder = BytesBuilder(copy: false);
    var cumulativeBytesLoaded = 0;
    await for (final chunk in result.stream) {
      bytesBuilder.add(chunk);
      cumulativeBytesLoaded += chunk.length;
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: cumulativeBytesLoaded,
          expectedTotalBytes: result.expectedTotalBytes,
        ),
      );
    }
    return bytesBuilder.takeBytes();
  }
}
