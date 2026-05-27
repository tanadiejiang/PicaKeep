import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../image_loader/base_image_provider.dart';
import 'archive_reading_service.dart';

class ArchiveImageProvider extends BaseImageProvider<ArchiveImageProvider> {
  const ArchiveImageProvider({
    required this.archivePath,
    required this.entryPath,
    required this.fileSize,
    required this.mtimeMillis,
  });

  final String archivePath;
  final String entryPath;
  final int fileSize;
  final int mtimeMillis;

  @override
  String get key =>
      'archive::${fileSize}_$mtimeMillis::$archivePath::$entryPath';

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) async {
    return ArchiveReadingService.instance
        .readEntryBytes(archivePath, entryPath);
  }

  @override
  Future<ArchiveImageProvider> obtainKey(ImageConfiguration configuration) async => this;
}
