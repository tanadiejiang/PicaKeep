// ignore_for_file: depend_on_referenced_packages

import 'dart:io';
import 'dart:math';

import 'package:flutter/painting.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/background_image_preparer.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:path/path.dart' as p;

String bytesLengthToReadableSize(int length, {bool useBase2 = false}) {
  const suffixes = ["B", "KB", "MB", "GB", "TB", "PB"];
  const suffixesBase2 = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];

  if (length == 0) return "0 B";

  var i = (log(length) / (useBase2 ? log(1024) : log(1000))).floor();
  var result = length / pow(useBase2 ? 1024 : 1000, i);
  var suffix = useBase2 ? suffixesBase2[i] : suffixes[i];

  return "${result.toStringAsFixed(2)} $suffix";
}

Future<void> openUrl(String url) async {
  // Placeholder - implement with url_launcher if needed
}

Future<bool> isOnline() async {
  try {
    final result = await InternetAddress.lookup('example.com');
    return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
  } on SocketException catch (_) {
    return false;
  }
}

Future<void> safeCreateDirectory(Directory dir) async {
  if (!dir.existsSync()) {
    await dir.create(recursive: true);
  }
}

Future<void> eraseCache() async {
  final dataRoot = App.dataPath;
  final cacheRoot = App.cachePath;
  DerivedImageStore.invalidateWithin(p.join(dataRoot, 'cache'));
  DerivedImageStore.invalidateWithin(cacheRoot);
  CoverThumbnailCache.invalidatePendingPublications();
  LocalCoverCache.invalidatePendingPublications();
  RemoteLibraryDataSource.invalidateCachePublications();
  BackgroundImagePreparer.instance.invalidate();
  BaseImageProvider.clearCache();
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.clear();
  imageCache.clearLiveImages();

  final cacheDirectories = <Directory>[
    Directory(App.cachePath),
    Directory('${App.dataPath}${Platform.pathSeparator}local_library_cache'
        '${Platform.pathSeparator}covers${Platform.pathSeparator}thumbs'),
    Directory(
      '${App.dataPath}${Platform.pathSeparator}cache',
    ),
  ];

  for (final cacheDirectory in cacheDirectories) {
    if (await FileSystemEntity.type(cacheDirectory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      continue;
    }

    await for (final entity
        in cacheDirectory.list(recursive: true, followLinks: false)) {
      if (App.dataPath != dataRoot || App.cachePath != cacheRoot) return;
      if (entity is! File ||
          DerivedImageStore.isPathLeased(entity.path) ||
          RemoteLibraryDataSource.isCacheFileProtected(entity.path)) {
        continue;
      }
      final canonical = p.normalize(p.absolute(entity.path));
      if (!p.isWithin(
          p.normalize(p.absolute(cacheDirectory.path)), canonical)) {
        continue;
      }
      try {
        await entity.delete();
      } catch (_) {}
    }
  }
  final registered = await LocalCoverCache.registeredReproduciblePaths();
  final coverRoot = p.join(dataRoot, 'local_library_cache', 'covers');
  for (final path in registered) {
    if (App.dataPath != dataRoot ||
        !p.isWithin(coverRoot, path) ||
        DerivedImageStore.isPathLeased(path) ||
        RemoteLibraryDataSource.isCacheFileProtected(path)) {
      continue;
    }
    try {
      await File(path).delete();
    } catch (_) {}
  }
  App.notifyLocalDataChanged();
}
