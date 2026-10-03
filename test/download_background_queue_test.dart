import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/foundation/pixiv_library.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:sqlite3/open.dart';

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
      'network restoration resumes the same destination task but respects a separately paused copy',
      () async {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows,
          () => DynamicLibrary.open(
              p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
    }
    final dir = await Directory.systemTemp.createTemp('pk44_network_queue_');
    final provider = PathProviderPlatform.instance;
    final settings = List<String>.from(appdata.settings);
    PathProviderPlatform.instance = _Paths(dir.path);
    await App.init(dataPathOverride: p.join(dir.path, 'app'));
    final library = PixivLibrary(p.join(dir.path, 'pixiv'));
    await library.initialize();
    final a = await library.createFolder('A');
    final b = await library.createFolder('B');
    // Existing validated artifacts let this exercise the real scheduler without
    // a live Pixiv account or any network request.
    for (final folder in [a, b]) {
      await File(p.join(folder.path, 'work.png')).writeAsBytes([1, 2, 3]);
      final db = PixivLibrary.openDownloads(folder.path);
      try {
        db.execute('INSERT INTO download VALUES(?,?,?,?,?,?,?)', [
          'pixiv44',
          'Work',
          'Author',
          1,
          'work.png',
          1.0,
          jsonEncode({'sourceKey': 'pixiv', 'id': '44'})
        ]);
      } finally {
        db.dispose();
      }
    }
    const info = PixivComicInfo(
        id: '44',
        title: 'Work',
        author: 'Author',
        authorId: '1',
        coverUrl: '',
        tags: [],
        description: '',
        pageCount: 1,
        illustType: 0,
        likeCount: 0,
        viewCount: 0,
        width: 1,
        height: 1,
        isOriginal: true,
        createDate: '',
        uploadDate: '',
        userId: '1');
    final manager = OnlineDownloadManager.instance;
    try {
      manager.handleDownloadNetworkChanged(false);
      await manager.enqueuePixiv(info, target: a);
      await manager.enqueuePixiv(info, target: b);
      final first = manager.tasks.first;
      final second = manager.tasks.last;
      final ids = manager.tasks.map((t) => t.id).toSet();
      expect(first.completed, isFalse);
      expect(second.completed, isFalse);
      expect(ids.length, 2);
      manager.pauseOne(second.id);
      final completed = Completer<void>();
      void changed() {
        if (first.completed && !completed.isCompleted) completed.complete();
      }

      manager.version.addListener(changed);
      manager.handleDownloadNetworkChanged(true);
      await completed.future.timeout(const Duration(seconds: 5));
      manager.version.removeListener(changed);
      await manager.persistQueue();
      expect(first.completed, isTrue);
      expect(second.paused, isTrue);
      expect(second.completed, isFalse);
      expect(manager.tasks.map((t) => t.id).toSet(), ids);
      expect(first.pixivTarget!['folderId'], a.id);
      expect(second.pixivTarget!['folderId'], b.id);
      // Cold-start recovery must still require an explicit user resume.
      await manager.loadQueue();
      expect(manager.tasks.where((t) => !t.completed).every((t) => t.paused),
          isTrue);
    } finally {
      manager.removeAll(manager.tasks.map((t) => t.id).toList());
      await manager.persistQueue();
      appdata.settings
        ..clear()
        ..addAll(settings);
      PathProviderPlatform.instance = provider;
      PixivLibrary.hasPendingDownloads = null;
      await dir.delete(recursive: true);
    }
  });
}
