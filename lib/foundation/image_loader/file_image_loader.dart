import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'package:picakeep/foundation/download.dart';

class FileImageProvider extends BaseImageProvider<FileImageProvider> {
  final String downloadId;
  final int ep;
  final int page;

  const FileImageProvider(this.downloadId, this.ep, this.page);

  @override
  String get key => 'FileImageProvider:$downloadId:$ep:$page';

  @override
  Future<FileImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<FileImageProvider>(this);
  }

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) async {
    final manager = DownloadManager();
    await manager.init();
    final file = manager.getImage(downloadId, ep, page);
    return await file.readAsBytes();
  }
}