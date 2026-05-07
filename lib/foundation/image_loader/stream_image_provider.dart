import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';

class StreamImageProvider extends BaseImageProvider<StreamImageProvider> {
  final FutureOr<Stream<List<int>>> Function() loader;
  final String imageKey;

  StreamImageProvider(this.loader, this.imageKey);

  @override
  String get key => imageKey;

  @override
  Future<StreamImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<StreamImageProvider>(this);
  }

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) async {
    final stream = await loader();
    final bytesBuilder = BytesBuilder(copy: false);
    var cumulativeBytesLoaded = 0;
    await for (final chunk in stream) {
      bytesBuilder.add(chunk);
      cumulativeBytesLoaded += chunk.length;
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: cumulativeBytesLoaded,
          expectedTotalBytes: null,
        ),
      );
    }
    return bytesBuilder.takeBytes();
  }
}
