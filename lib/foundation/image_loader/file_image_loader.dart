import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'package:picakeep/foundation/download.dart';
import 'reader_image_limits.dart';
import 'reader_image_observation.dart';

class FileImageProvider extends BaseImageProvider<FileImageProvider> {
  final String downloadId;
  final int ep;
  final int page;

  const FileImageProvider(this.downloadId, this.ep, this.page);

  @override
  bool get supportsReaderInputLimits => true;

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
    // A known local downloaded original file read is a fetch boundary.
    return await observeReaderImageStage(
        ReaderImageStage.fetch, () => readReaderImageFile(file));
  }
}
