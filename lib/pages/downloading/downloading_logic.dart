import 'package:picakeep/foundation/online_download_manager.dart';

class DownloadingLogic {
  DownloadingLogic({OnlineDownloadManager? manager})
      : manager = manager ?? OnlineDownloadManager.instance;

  final OnlineDownloadManager manager;

  List<OnlineDownloadTask> get tasks => manager.tasks;
}
