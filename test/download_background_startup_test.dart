import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/online_download_manager.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'startup network events and a fast background transition cannot overwrite the unread disk queue',
      () async {
    final dir = await Directory.systemTemp.createTemp('pk44_unread_queue_');
    final provider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(dir.path);
    await App.init(dataPathOverride: p.join(dir.path, 'app'));
    final queue = File(p.join(dir.path, 'download', 'download_queue.json'));
    await queue.parent.create(recursive: true);
    final target = <String, String>{
      'root': p.join(dir.path, 'pixiv'),
      'libraryId': 'saved-library',
      'folderId': 'saved-folder',
    };
    final original = jsonEncode([
      {
        'sourceKey': 'pixiv',
        'pixivJson': {'id': '7788', 'title': 'Pending work', 'pageCount': 3},
        'target': target,
        'baseName': 'Pending work-7788',
        'operationId': 'saved-operation',
        'currentPage': 1,
        'paused': false,
      }
    ]);
    await queue.writeAsString(original, flush: true);
    final manager = OnlineDownloadManager.instance;
    try {
      manager.handleDownloadNetworkChanged(false);
      manager.handleDownloadNetworkChanged(true);
      await manager.persistQueue();
      expect(await queue.readAsString(), original);
      await manager.loadQueue();
      final task = manager.tasks.single;
      expect(task.pixivTarget, target);
      expect(task.pixivOperationId, 'saved-operation');
      expect(task.pixivBaseName, 'Pending work-7788');
      expect(task.paused, isTrue);
      expect(await queue.readAsString(), original);
      manager.removeAll([task.id]);
      await manager.persistQueue();
      expect(jsonDecode(await queue.readAsString()), isEmpty,
          reason: 'After loading, an intentional clear must still persist');
    } finally {
      manager.removeAll(manager.tasks.map((t) => t.id).toList());
      await manager.persistQueue();
      PathProviderPlatform.instance = provider;
      await dir.delete(recursive: true);
    }
  });
}
