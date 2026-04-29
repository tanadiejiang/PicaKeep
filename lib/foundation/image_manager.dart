import 'dart:async';

import 'package:picakeep/network/download.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/hitomi_network/hitomi_models.dart';

class ImageManager {
  static void clearTasks() {}
  bool get isDownloading => false;
  static bool get haveTask => false;

  Stream<DownloadProgress> getImage(String url) async* {
    yield DownloadProgress(1, 1, url, '');
  }

  Stream<DownloadProgress> getEhImageNew(Gallery gallery, int index) async* {
    yield DownloadProgress(1, 1, gallery.link, '');
  }

  Stream<DownloadProgress> getJmImage(String url, String? something,
      {required String epsId,
      required String scrambleId,
      required String bookId}) async* {
    yield DownloadProgress(1, 1, url, '');
  }

  Stream<DownloadProgress> getHitomiImage(HitomiFile file, String id) async* {
    yield DownloadProgress(1, 1, file.hash, '');
  }

  Stream<DownloadProgress> getCustomImage(
      String url, String id, String epId, String sourceKey) async* {
    yield DownloadProgress(1, 1, url, '');
  }
}
