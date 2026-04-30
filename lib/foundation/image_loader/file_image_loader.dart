// ignore_for_file: unused_element, unused_import

import 'dart:io';
import 'dart:ui' show Codec, ImmutableBuffer;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'package:picakeep/foundation/download.dart';

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
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
    );
  }

  Future<Codec> _loadAsync(
      FileImageProvider key, ImageDecoderCallback decode) async {
    final manager = DownloadManager();
    await manager.init();
    final file = manager.getImage(downloadId, ep, page);
    final bytes = await file.readAsBytes();
    final buffer = await ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }
}
