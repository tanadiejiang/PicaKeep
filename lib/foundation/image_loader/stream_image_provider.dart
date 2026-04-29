import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:picakeep/network/download.dart';

class StreamImageProvider extends ImageProvider<StreamImageProvider> {
  final FutureOr<Stream<DownloadProgress>> Function() loader;
  final String imageKey;

  StreamImageProvider(this.loader, this.imageKey);

  @override
  Future<StreamImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<StreamImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
      StreamImageProvider key, ImageDecoderCallback decode) {
    throw UnimplementedError('StreamImageProvider.loadImage not implemented');
  }
}
