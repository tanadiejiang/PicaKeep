import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/komiic_network/komiic_network.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
}

JmComicInfo _jm({int count = 150}) => JmComicInfo(
      id: '41',
      title: 'Resume Book',
      authors: const [],
      description: '',
      likes: 0,
      views: 0,
      comments: 0,
      tags: const [],
      works: const [],
      actors: const [],
      series: {for (var i = 0; i < count; i++) i + 1: '${501 + i}'},
      epNames: List.generate(count, (i) => 'Chapter ${i + 1}'),
      isFavourite: false,
      isLiked: false,
      coverUrl: '',
      relatedComics: const [],
    );

PicacgComicItem _picacg() => PicacgComicItem.fromApi(
      json: {'_id': '0123456789abcdef01234567', 'title': 'Resume Book'},
      eps: List.generate(150, (i) => 'Chapter ${i + 1}'),
      recommendation: const [],
    );

KomiicComicInfo _komiic() => KomiicComicInfo(
      id: '41',
      title: 'Resume Book',
      coverUrl: '',
      authors: const [],
      tags: const [],
      description: '',
      status: '',
      year: '',
      updateTime: '',
      views: 0,
      monthViews: 0,
      favoriteCount: 0,
      recommendations: const [],
      chapters: List.generate(
          150,
          (i) => KomiicChapter(
              id: '${701 + i}',
              serial: '${i + 1}',
              type: 'chapter',
              dateUpdated: '')),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open(
            p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
  }
  late Directory workspace;
  late Directory root;
  late OnlineDownloadManager manager;
  final managers = <OnlineDownloadManager>[];
  final reads = <int>[];
  final scans = <int>[];
  final writes = <String>[];
  final originalPaths = PathProviderPlatform.instance;
  final savedSettings = List<String>.of(appdata.settings);
  final savedRecording = LogManager.recordingEnabled;
  var failureIndex = 19;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('chapter_resume_010_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: p.join(workspace.path, 'app'));
    LogManager.recordingEnabled = false;
  });

  Future<Res<List<String>>> loader(
      String source, String id, int index, String chapterId) async {
    reads.add(index);
    if (index == failureIndex) return const Res.error('offline stop');
    return Res([
      'https://offline.invalid/$source/$chapterId/1.jpg',
      'https://offline.invalid/$source/$chapterId/2.jpg'
    ]);
  }

  Future<void> writer(String source, String url, File target,
      Map<String, String> headers) async {
    writes.add(target.path);
    await target.writeAsBytes(utf8.encode(url), flush: true);
  }

  OnlineDownloadManager makeManager({
    Future<Res<List<String>>> Function(String, String, int, String)? load,
    Future<void> Function(String, String, File, Map<String, String>)? write,
    void Function(int)? scan,
  }) {
    final value = OnlineDownloadManager.forTesting(
        downloadRoot: root.path,
        chapterLoader: load ?? loader,
        chapterFileWriter: write ?? writer,
        chapterScanObserver: (path, index) {
          scans.add(index);
          scan?.call(index);
        });
    managers.add(value);
    return value;
  }

  setUp(() async {
    root = await Directory(p.join(
            workspace.path, 'case-${DateTime.now().microsecondsSinceEpoch}'))
        .create();
    managers.clear();
    reads.clear();
    scans.clear();
    writes.clear();
    failureIndex = 19;
    appdata.settings[22] = root.path;
    manager = makeManager();
  });

  tearDown(() async {
    for (final value in managers) {
      value.pauseAll();
      value.removeAll(value.tasks.map((task) => task.id).toList());
      await value.persistQueue();
      value.version.dispose();
    }
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    LogManager.recordingEnabled = savedRecording;
    await workspace.delete(recursive: true);
  });

  Future<void> waitTask(OnlineDownloadTask task) async {
    if (task.completed || task.error != null) return;
    final done = Completer<void>();
    void changed() {
      if ((task.completed || task.error != null) && !done.isCompleted) {
        done.complete();
      }
    }

    for (final value in managers) {
      value.version.addListener(changed);
    }
    try {
      await done.future.timeout(const Duration(seconds: 30));
    } finally {
      for (final value in managers) {
        value.version.removeListener(changed);
      }
    }
  }

  Future<Map<String, dynamic>> queueItem() async => Map<String, dynamic>.from(
      (jsonDecode(await File(p.join(root.path, 'download_queue.json'))
              .readAsString()) as List)
          .single);

  Future<void> rewriteQueue(void Function(Map<String, dynamic>) change) async {
    final item = await queueItem();
    change(item);
    await File(p.join(root.path, 'download_queue.json'))
        .writeAsString(jsonEncode([item]), flush: true);
  }

  Future<void> enqueueSource(String source) async {
    final result = source == 'jm'
        ? await manager.enqueueJm(_jm())
        : source == 'picacg'
            ? await manager.enqueuePicacg(_picacg())
            : await manager.enqueueKomiic(_komiic());
    expect(result.success, isTrue);
    await waitTask(manager.tasks.single);
    expect(manager.tasks.single.currentEp, 20);
    expect(manager.tasks.single.completedChapters,
        List.generate(19, (i) => i).toSet());
    await manager.persistQueue();
  }

  for (final source in ['jm', 'picacg', 'komiic']) {
    test('$source 20/150失败续传只请求/扫描问题章，保存时不递归扫前19章', () async {
      await enqueueSource(source);
      final task = manager.tasks.single;
      reads.clear();
      scans.clear();
      writes.clear();
      failureIndex = 20;
      manager.retry(task.id);
      await waitTask(task);
      expect(reads, [19, 20]);
      expect(scans, isNotEmpty);
      expect(scans.every((index) => index == 19), isTrue);
      expect(writes, hasLength(2));
      expect(task.completedChapters.contains(19), isTrue);
      final checkpoint = (await queueItem())['chapterResume'] as Map;
      expect(checkpoint['version'], 1);
      expect(checkpoint['nextIndex'], 20);
      expect(checkpoint['verified'], List.generate(20, (i) => i));
      expect(checkpoint['pageBytes'], hasLength(20));
    });
  }

  test('新版进程重开从20/150检查点开始，不遍历前19章', () async {
    await enqueueSource('jm');
    final restored = makeManager();
    await restored.loadQueue(strict: true);
    reads.clear();
    scans.clear();
    writes.clear();
    failureIndex = 20;
    final task = restored.tasks.single;
    restored.retry(task.id);
    await waitTask(task);
    expect(reads, [19, 20]);
    expect(scans.every((index) => index == 19), isTrue);
    expect(task.completedChapters, List.generate(20, (i) => i).toSet());
  });

  test('暂停后快速恢复也复用完成检查点，旧请求退出前不启动另一执行体', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var attempts = 0;
    manager = makeManager(load: (source, id, index, chapterId) async {
      if (index == 19 && attempts++ == 0) {
        entered.complete();
        await release.future;
        throw StateError('retired pause request');
      }
      return loader(source, id, index, chapterId);
    });
    await manager.enqueueJm(_jm());
    await entered.future.timeout(const Duration(seconds: 30));
    final task = manager.tasks.single;
    manager.pauseOne(task.id);
    reads.clear();
    scans.clear();
    writes.clear();
    failureIndex = 20;
    manager.resumeOne(task.id);
    expect(attempts, 1);
    release.complete();
    await waitTask(task);
    expect(reads, [19, 20]);
    expect(scans.every((index) => index == 19), isTrue);
    expect(task.error, contains('offline stop'));
  });

  test('稀疏2/20/81章恢复保留原序号，currentEp不推导未选章节完成', () async {
    await manager.enqueueJm(_jm(), chapterIndexes: [1, 19, 80]);
    final task = manager.tasks.single;
    await waitTask(task);
    expect(task.completedChapters, {1});
    reads.clear();
    scans.clear();
    failureIndex = 80;
    manager.retry(task.id);
    await waitTask(task);
    expect(reads, [19, 80]);
    expect(scans.every((index) => index == 19), isTrue);
    expect(task.completedChapters, {1, 19});
    expect(task.progress, closeTo(2 / 3, 0.00001));
  });

  test('旧008队列先处理第20章，再补验历史；迁移被打断后不从头重验', () async {
    await enqueueSource('jm');
    await rewriteQueue((item) {
      item.remove('chapterResume');
    });
    final restored = makeManager();
    await restored.loadQueue(strict: true);
    reads.clear();
    scans.clear();
    writes.clear();
    failureIndex = 20;
    restored.retry(restored.tasks.single.id);
    await waitTask(restored.tasks.single);
    expect(reads, [19, 20], reason: '前19章已知页数可本地补验，无页表重取');
    expect(scans.first, 19);
    expect(scans.where((index) => index < 19), List.generate(19, (i) => i));
    expect(restored.tasks.single.completedChapters,
        List.generate(20, (i) => i).toSet());
    await restored.persistQueue();
    final reopened = makeManager();
    await reopened.loadQueue(strict: true);
    reads.clear();
    scans.clear();
    failureIndex = 21;
    reopened.retry(reopened.tasks.single.id);
    await waitTask(reopened.tasks.single);
    expect(reads, [20, 21]);
    expect(scans.every((index) => index == 20), isTrue);
  });

  test('旧无页数的历史章先问题章再获取历史页表，不凭currentEp假完成', () async {
    await manager.enqueueJm(_jm(), chapterIndexes: [1, 19, 80]);
    await waitTask(manager.tasks.single);
    await manager.persistQueue();
    await rewriteQueue((item) {
      item.remove('chapterResume');
      item.remove('chapterPageCounts');
      item.remove('completedChapters');
    });
    final db = sqlite3.open(p.join(root.path, 'download.db'));
    try {
      final row =
          db.select('select json from download where id=?', ['jm41']).single;
      final json = Map<String, dynamic>.from(jsonDecode(row['json'] as String));
      json.remove('chapterPageCounts');
      json.remove('chapterPageBytes');
      db.execute(
          'update download set json=? where id=?', [jsonEncode(json), 'jm41']);
    } finally {
      db.dispose();
    }
    final restored = makeManager();
    await restored.loadQueue(strict: true);
    reads.clear();
    scans.clear();
    writes.clear();
    failureIndex = 80;
    restored.retry(restored.tasks.single.id);
    await waitTask(restored.tasks.single);
    expect(reads, [19, 1, 80]);
    expect(scans.first, 19);
    expect(writes, hasLength(2), reason: '历史第2章复用已有页');
    expect(restored.tasks.single.completedChapters, {1, 19});
  });

  test('旧历史补验中途暂停并重开，只验证剩余历史章不再回首章', () async {
    await manager.enqueueJm(_jm(), chapterIndexes: [0, 1, 19, 80]);
    await waitTask(manager.tasks.single);
    await manager.persistQueue();
    await rewriteQueue((item) {
      item.remove('chapterResume');
    });
    final paused = Completer<void>();
    var pauseVersion = 0;
    var armed = true;
    late OnlineDownloadManager migrating;
    migrating = makeManager(scan: (index) {
      if (armed && index == 1) {
        armed = false;
        migrating.pauseAll();
        pauseVersion = migrating.version.value;
        paused.complete();
      }
    });
    await migrating.loadQueue(strict: true);
    reads.clear();
    scans.clear();
    failureIndex = 80;
    migrating.retry(migrating.tasks.single.id);
    await paused.future.timeout(const Duration(seconds: 30));
    final exited = Completer<void>();
    void changed() {
      if (migrating.version.value > pauseVersion && !exited.isCompleted) {
        exited.complete();
      }
    }

    migrating.version.addListener(changed);
    changed();
    try {
      await exited.future.timeout(const Duration(seconds: 10));
    } finally {
      migrating.version.removeListener(changed);
    }
    await migrating.persistQueue();
    expect(reads, [19]);
    expect(migrating.tasks.single.completedChapters, {0, 19});
    final checkpoint = (await queueItem())['chapterResume'] as Map;
    expect(checkpoint['verificationPending'], [1]);
    expect(checkpoint['nextIndex'], 1);
    final reopened = makeManager();
    await reopened.loadQueue(strict: true);
    reads.clear();
    scans.clear();
    reopened.retry(reopened.tasks.single.id);
    await waitTask(reopened.tasks.single);
    expect(reads, [80]);
    expect(scans, [1]);
    expect(reopened.tasks.single.completedChapters, {0, 1, 19});
  });

  test('只有旧currentEp没有完成证据，先问题章但此前缺章仍全部补齐', () async {
    failureIndex = 2;
    manager.pauseAll();
    await manager.enqueueJm(_jm(count: 3));
    manager.tasks.single.currentEp = 3;
    await manager.persistQueue();
    final restored = makeManager();
    await restored.loadQueue(strict: true);
    failureIndex = -1;
    restored.retry(restored.tasks.single.id);
    await waitTask(restored.tasks.single);
    expect(reads, [2, 0, 1]);
    expect(restored.tasks.single.completedChapters, {0, 1, 2});
    expect(restored.tasks.single.completed, isTrue);
  });

  test('主动状态检查发现手删尾页后撤销检查点，续传优先修复并只补缺页', () async {
    await enqueueSource('jm');
    final missing = File(p.join(root.path, 'Resume Book', '1', '2.jpg'));
    await missing.delete();
    final status = await manager.chapterStatuses(
        sourceKey: 'jm', candidateIds: ['jm41'], chapterCount: 150);
    expect(status[0], ChapterDownloadStatus.failed);
    expect(manager.tasks.single.completedChapters.contains(0), isFalse);
    reads.clear();
    scans.clear();
    writes.clear();
    manager.retry(manager.tasks.single.id);
    await waitTask(manager.tasks.single);
    expect(reads, [0, 19]);
    expect(writes, [missing.path]);
    expect(await missing.exists(), isTrue);
    expect(manager.tasks.single.completedChapters.contains(0), isTrue);
  });

  test('主动核验撤销检查点同步落盘，随即重开也从被删章节修复', () async {
    await enqueueSource('jm');
    final missing = File(p.join(root.path, 'Resume Book', '1', '2.jpg'));
    await missing.delete();
    await manager.chapterStatuses(
        sourceKey: 'jm', candidateIds: ['jm41'], chapterCount: 150);
    final checkpoint = (await queueItem())['chapterResume'] as Map;
    expect(checkpoint['verified'], isNot(contains(0)));
    expect(checkpoint['nextIndex'], 0);
    final restored = makeManager();
    await restored.loadQueue(strict: true);
    reads.clear();
    scans.clear();
    writes.clear();
    restored.retry(restored.tasks.single.id);
    await waitTask(restored.tasks.single);
    expect(reads, [0, 19]);
    expect(writes, [missing.path]);
    expect(restored.tasks.single.completedChapters.contains(0), isTrue);
  });

  test('整章写完但队列提交失败不得保存可信完成点，修复后重试该章', () async {
    var blockCommit = true;
    manager = makeManager(write: (source, url, target, headers) async {
      await writer(source, url, target, headers);
      if (blockCommit && p.basename(target.path) == '2.jpg') {
        blockCommit = false;
        final queue = File(p.join(root.path, 'download_queue.json'));
        await queue.delete();
        await Directory(queue.path).create();
      }
    });
    failureIndex = -1;
    await manager.enqueueJm(_jm(count: 1));
    final task = manager.tasks.single;
    await waitTask(task);
    expect(task.completedChapters, isEmpty);
    expect(task.error, isNotNull);
    await Directory(p.join(root.path, 'download_queue.json')).delete();
    await manager.persistQueue();
    final checkpoint = (await queueItem())['chapterResume'] as Map;
    expect(checkpoint['verified'], isEmpty);
    expect(checkpoint['nextIndex'], 0);
    final restored = makeManager();
    await restored.loadQueue(strict: true);
    reads.clear();
    scans.clear();
    writes.clear();
    restored.retry(restored.tasks.single.id);
    await waitTask(restored.tasks.single);
    expect(restored.tasks.single.completed, isTrue);
    expect(reads, [0]);
    expect(writes, isEmpty, reason: '未提交的完整文件仍逐页复用');
    await restored.persistQueue();
    expect(
        jsonDecode(await File(p.join(root.path, 'download_queue.json'))
            .readAsString()),
        isEmpty,
        reason: '完成任务已移出持久队列');
  });

  test('缺页数或路径不匹配的新版检查点明确拒绝，不能跳章', () async {
    await enqueueSource('jm');
    await rewriteQueue((item) {
      (item['chapterResume'] as Map)['directory'] = 'other';
    });
    final badPath = makeManager();
    await expectLater(
        badPath.loadQueue(strict: true), throwsA(isA<FormatException>()));
    await rewriteQueue((item) {
      (item['chapterResume'] as Map)['directory'] = item['chapterDirectory'];
      (item['chapterPageCounts'] as Map).remove('0');
    });
    final badCount = makeManager();
    await expectLater(
        badCount.loadQueue(strict: true), throwsA(isA<FormatException>()));
  });
}
