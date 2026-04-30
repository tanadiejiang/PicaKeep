import 'dart:async';
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Codec, ImmutableBuffer;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

class StreamImageProvider extends ImageProvider<StreamImageProvider> {
  final FutureOr<Stream<List<int>>> Function() loader;
  final String imageKey;

  StreamImageProvider(this.loader, this.imageKey);

  @override
  Future<StreamImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<StreamImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
      StreamImageProvider key, ImageDecoderCallback decode) {
    final chunkStreamController = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode, chunkStreamController),
      scale: 1.0,
      chunkEvents: chunkStreamController.stream,
    );
  }

  Future<Codec> _loadAsync(StreamImageProvider key, ImageDecoderCallback decode,
      StreamController<ImageChunkEvent> chunkEvents) async {
    try {
      final stream = await loader();
      final bytes =
          Uint8List.fromList(await stream.expand((chunk) => chunk).toList());
      final buffer = await ImmutableBuffer.fromUint8List(bytes);
      return decode(buffer);
    } catch (e) {
      throw Exception('Failed to load stream image: $e');
    }
  }
}
