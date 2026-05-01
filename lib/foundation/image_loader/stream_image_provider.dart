import 'dart:async';
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
    final bytes =
        Uint8List.fromList(await stream.expand((chunk) => chunk).toList());
    return bytes;
  }
}