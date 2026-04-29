// ignore_for_file: unused_element

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';

class FileImageLoader extends BaseImageProvider {}

class _FileImageLoader extends FileImageLoader {}

class FileImageProvider extends ImageProvider<FileImageProvider> {
  final String downloadId;
  final int ep;
  final int page;

  FileImageProvider(this.downloadId, this.ep, this.page);

  @override
  Future<FileImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<FileImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
      FileImageProvider key, ImageDecoderCallback decode) {
    throw UnimplementedError('FileImageProvider.loadImage not implemented');
  }
}
