import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/komiic_network/komiic_network.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/tools/download_notification_controller.dart';
import 'package:picakeep/tools/tags_translation.dart';
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

JmComicInfo _jm({int count = 4}) => JmComicInfo(
      id: '41',
      title: 'Chapter Book',
      authors: const ['author'],
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
      json: {'_id': '0123456789abcdef01234567', 'title': 'Chapter Book'},
      eps: const ['one', 'two', 'three', 'four'],
      recommendation: const [],
    );

KomiicComicInfo _komiic() => KomiicComicInfo(
      id: '41',
      title: 'Chapter Book',
      coverUrl: '',
      authors: const ['author'],
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
          4,
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
  final reads = <(String, int, String)>[];
  final writes = <String>[];
  final managers = <OnlineDownloadManager>[];
  final originalPaths = PathProviderPlatform.instance;
  final savedSettings = List<String>.of(appdata.settings);
  final savedRecording = LogManager.recordingEnabled;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('chapter_download_008_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: p.join(workspace.path, 'app'));
    LogManager.recordingEnabled = false;
  });

  Future<Res<List<String>>> loader(
      String source, String comicId, int index, String chapterId) async {
    reads.add((source, index, chapterId));
    return Res(List.generate(
        2,
        (page) =>
            'https://offline.invalid/$source/$chapterId/${page + 1}.jpg'));
  }

  Future<void> writer(String source, String url, File target,
      Map<String, String> headers) async {
    writes.add(target.path);
    await target.writeAsBytes(utf8.encode(url), flush: true);
  }

  OnlineDownloadManager makeManager({
    Future<Res<List<String>>> Function(String, String, int, String)? load,
    Future<void> Function(String, String, File, Map<String, String>)? write,
    void Function(DownloadNoticeSnapshot)? notice,
  }) {
    final value = OnlineDownloadManager.forTesting(
        downloadRoot: root.path,
        chapterLoader: load ?? loader,
        chapterFileWriter: write ?? writer,
        noticeObserver: notice);
    managers.add(value);
    return value;
  }

  setUp(() async {
    root = await Directory(p.join(
            workspace.path, 'case-${DateTime.now().microsecondsSinceEpoch}'))
        .create();
    reads.clear();
    writes.clear();
    managers.clear();
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

  Future<void> waitUntil(bool Function() done) async {
    if (done()) return;
    final complete = Completer<void>();
    void changed() {
      if (done() && !complete.isCompleted) complete.complete();
    }

    for (final value in managers) {
      value.version.addListener(changed);
    }
    try {
      await complete.future.timeout(const Duration(seconds: 10));
    } finally {
      for (final value in managers) {
        value.version.removeListener(changed);
      }
    }
  }

  Future<Map<String, dynamic>> record(String id) async {
    final db = sqlite3.open(p.join(root.path, 'download.db'));
    try {
      return Map<String, dynamic>.from(jsonDecode(
          db.select('select json from download where id=?', [id]).single['json']
              as String));
    } finally {
      db.dispose();
    }
  }

  Future<void> waitTask(OnlineDownloadTask task) =>
      waitUntil(() => task.completed || task.error != null);

  test('选择排序去重和边界；显式空选择拒绝，不入队', () async {
    expect(normalizeChapterIndexes([3, 1, 3], 4), [1, 3]);
    expect(normalizeChapterIndexes(null, 4), [0, 1, 2, 3]);
    for (final selection in [
      <int>[],
      [-1],
      [4]
    ]) {
      expect((await manager.enqueueJm(_jm(), chapterIndexes: selection)).error,
          isTrue);
    }
    expect(manager.tasks, isEmpty);
    expect(reads, isEmpty);
  });

  for (final source in ['jm', 'picacg', 'komiic']) {
    test('$source 仅下载第2/4章，目录/记录/原始章节ID一致且保留全标题', () async {
      final Res<bool> result;
      final String id;
      if (source == 'jm') {
        result = await manager.enqueueJm(_jm(), chapterIndexes: [3, 1, 3]);
        id = 'jm41';
      } else if (source == 'picacg') {
        result = await manager.enqueuePicacg(_picacg(), chapterIndexes: [3, 1]);
        id = _picacg().id;
      } else {
        result = await manager.enqueueKomiic(_komiic(), chapterIndexes: [3, 1]);
        id = 'komiic41';
      }
      expect(result.success, isTrue);
      final task = manager.tasks.single;
      await waitTask(task);
      expect(task.error, isNull);
      expect(task.completed, isTrue);
      expect(reads.map((entry) => entry.$2), [1, 3]);
      if (source == 'jm') {
        expect(reads.map((entry) => entry.$3), ['502', '504']);
      }
      if (source == 'picacg') {
        expect(reads.map((entry) => entry.$3), ['2', '4']);
      }
      if (source == 'komiic') {
        expect(reads.map((entry) => entry.$3), ['702', '704']);
      }
      final path = p.join(root.path, 'Chapter Book');
      expect(await Directory(p.join(path, '1')).exists(), isFalse);
      expect(await Directory(p.join(path, '3')).exists(), isFalse);
      for (final index in [2, 4]) {
        expect(await File(p.join(path, '$index', '1.jpg')).exists(), isTrue);
        expect(await File(p.join(path, '$index', '2.jpg')).exists(), isTrue);
      }
      final json = await record(id);
      expect(json[source == 'komiic' ? 'downloadedEps' : 'downloadedChapters'],
          [1, 3]);
      expect(json['chapterPageCounts'], {'1': 2, '3': 2});
      final parsed = parseDownloadedItemRecordData(id, json)!;
      expect(parsed.eps, hasLength(4));
      expect(task.progress, 1);
      final statuses = await manager.chapterStatuses(
          sourceKey: source, candidateIds: [id], chapterCount: 4);
      expect(statuses[1], ChapterDownloadStatus.downloaded);
      expect(statuses[3], ChapterDownloadStatus.downloaded);
      expect(statuses[0], isNull);
    });
  }

  test('Komiic完成不等待翻译资产，文件/记录/通知终态一致', () async {
    resetTagTranslationsForTesting();
    final assetRelease = Completer<ByteData?>();
    var translationRequests = 0;
    final binding = TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger.setMockMessageHandler('flutter/assets',
        (message) async {
      final key = utf8.decode(message!.buffer
          .asUint8List(message.offsetInBytes, message.lengthInBytes));
      if (key == 'assets/tags.json') {
        translationRequests++;
        return assetRelease.future;
      }
      return null;
    });
    final notices = <DownloadNoticeSnapshot>[];
    try {
      manager = makeManager(notice: notices.add);
      await manager.enqueueKomiic(_komiic(), chapterIndexes: [0, 1]);
      final task = manager.tasks.single;
      await waitTask(task);
      await manager.persistQueue();
      expect(task.completed, isTrue);
      expect(task.error, isNull);
      expect((await record('komiic41'))['downloadedEps'], [0, 1]);
      expect(
          await File(p.join(root.path, 'Chapter Book', '2', '2.jpg')).exists(),
          isTrue);
      expect(translationRequests, 0, reason: 'Komiic无缺失标签收集，不应进入翻译资产队列');
      expect(notices.last.state, DownloadNoticeState.finished);
      expect(notices.last.completed, 1);
      expect(notices.last.total, 1);
      expect(notices.last.percent, 100);
      expect(
          jsonDecode(await File(p.join(root.path, 'download_queue.json'))
              .readAsString()),
          isEmpty);
    } finally {
      assetRelease.complete(
          ByteData.sublistView(Uint8List.fromList(utf8.encode('{}'))));
      await Future<void>.delayed(Duration.zero);
      binding.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', null);
      resetTagTranslationsForTesting();
    }
  });

  test('最后一章队列提交失败显示错误，修复后复用落盘文件完成通知', () async {
    final notices = <DownloadNoticeSnapshot>[];
    final queue = File(p.join(root.path, 'download_queue.json'));
    var blocked = false;
    manager = makeManager(
        notice: notices.add,
        write: (source, url, target, headers) async {
          await writer(source, url, target, headers);
          if (url.endsWith('/2.jpg') && !blocked) {
            blocked = true;
            await queue.delete();
            await Directory(queue.path).create();
          }
        });
    try {
      await manager.enqueueKomiic(_komiic(), chapterIndexes: [0]);
      final task = manager.tasks.single;
      await waitTask(task);
      expect(task.completed, isFalse);
      expect(task.error, isNotNull);
      expect(notices.last.state, DownloadNoticeState.failed);
      expect((await record('komiic41'))['downloadedEps'], [0]);
      final written = writes.length;
      await Directory(queue.path).delete();
      manager.retry(task.id);
      await waitTask(task);
      expect(task.completed, isTrue);
      expect(task.error, isNull);
      expect(writes.length, written, reason: '提交失败重试复用已落盘页');
      expect(notices.last.state, DownloadNoticeState.finished);
      expect(notices.last.completed, 1);
    } finally {
      if (await Directory(queue.path).exists()) {
        await Directory(queue.path).delete();
      }
    }
  });

  test('同目录补章复用旧路径/联合完成集合，不覆盖旧页，完成队列不挡新章', () async {
    expect(
        (await manager.enqueueJm(_jm(), chapterIndexes: [0])).success, isTrue);
    final old = manager.tasks.single;
    await waitTask(old);
    final oldFile = File(p.join(root.path, 'Chapter Book', '1', '1.jpg'));
    final before = await oldFile.readAsBytes();
    // Source title changes must not relocate an existing downloaded book.
    final refreshed = JmComicInfo(
      id: '41',
      title: 'Renamed',
      authors: const [],
      description: '',
      likes: 0,
      views: 0,
      comments: 0,
      tags: const [],
      works: const [],
      actors: const [],
      series: _jm().series,
      epNames: _jm().epNames,
      isFavourite: false,
      isLiked: false,
      coverUrl: '',
      relatedComics: const [],
    );
    expect((await manager.enqueueJm(refreshed, chapterIndexes: [0, 2])).success,
        isTrue);
    final fresh = manager.tasks.single;
    expect(identical(fresh, old), isFalse);
    await waitTask(fresh);
    expect(fresh.error, isNull);
    expect(fresh.chapterDirectory, 'Chapter Book');
    expect(await oldFile.readAsBytes(), before);
    expect(await Directory(p.join(root.path, 'Renamed')).exists(), isFalse);
    expect((await record('jm41'))['downloadedChapters'], [0, 2]);
    expect(reads.map((entry) => entry.$2), [0, 2]);
    expect(
        (await manager.enqueueJm(_jm(), chapterIndexes: [0, 2])).error, isTrue);
  });

  test('活动任务追加保留同一实例，只执行新增章节，无双执行', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    manager = makeManager(load: (source, id, index, chapterId) async {
      if (index == 1 && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
      return loader(source, id, index, chapterId);
    });
    expect(
        (await manager.enqueueJm(_jm(), chapterIndexes: [1])).success, isTrue);
    await entered.future.timeout(const Duration(seconds: 5));
    final task = manager.tasks.single;
    final state = await manager.chapterStatuses(
        sourceKey: 'jm', candidateIds: ['jm41'], chapterCount: 4);
    expect(state[1], ChapterDownloadStatus.downloading);
    expect((await manager.enqueueJm(_jm(), chapterIndexes: [1, 3])).success,
        isTrue);
    expect(identical(manager.tasks.single, task), isTrue);
    expect(task.requestedChapters, [1, 3]);
    release.complete();
    await waitTask(task);
    expect(task.error, isNull);
    expect(reads.map((entry) => entry.$2), [1, 3]);
    expect((await record('jm41'))['downloadedChapters'], [1, 3]);
  });

  test('并发入队串行合并，重复请求没有第二个执行体', () async {
    manager.pauseAll();
    final results = await Future.wait([
      manager.enqueueJm(_jm(), chapterIndexes: [1]),
      manager.enqueueJm(_jm(), chapterIndexes: [3]),
      manager.enqueueJm(_jm(), chapterIndexes: [1]),
    ]);
    expect(results.map((result) => result.success), [true, true, false]);
    expect(manager.tasks, hasLength(1));
    expect(manager.tasks.single.requestedChapters, [1, 3]);
    manager.resumeAll();
    await waitTask(manager.tasks.single);
    expect(reads.map((entry) => entry.$2), [1, 3]);
  });

  test('部分失败不标整章，前一完整章即时落库；重试保留已存在页', () async {
    var fail = true;
    manager = makeManager(write: (source, url, target, headers) async {
      if (fail &&
          target.parent.path.endsWith('${p.separator}2') &&
          p.basename(target.path) == '2.jpg') {
        throw StateError('offline page rejected');
      }
      await writer(source, url, target, headers);
    });
    expect(
        (await manager.enqueuePicacg(_picacg(), chapterIndexes: [0, 1]))
            .success,
        isTrue);
    final task = manager.tasks.single;
    await waitTask(task);
    expect(task.completed, isFalse);
    expect(task.error, isNotNull);
    expect((await record(_picacg().id))['downloadedChapters'], [0]);
    final state = await manager.chapterStatuses(
        sourceKey: 'picacg', candidateIds: [_picacg().id], chapterCount: 4);
    expect(state[0], ChapterDownloadStatus.downloaded);
    expect(state[1], ChapterDownloadStatus.failed);
    final oldBytes = await File(p.join(root.path, 'Chapter Book', '1', '1.jpg'))
        .readAsBytes();
    final written = writes.length;
    fail = false;
    manager.retry(task.id);
    await waitTask(task);
    expect(task.completed, isTrue);
    expect((await record(_picacg().id))['downloadedChapters'], [0, 1]);
    expect(writes.length, written + 1, reason: '只补失败页');
    expect(
        await File(p.join(root.path, 'Chapter Book', '1', '1.jpg'))
            .readAsBytes(),
        oldBytes);
  });

  test('Komiic部分失败同样不能标整章完成', () async {
    manager = makeManager(write: (source, url, target, headers) async {
      if (p.basename(target.path) == '2.jpg') {
        throw StateError('offline failure');
      }
      await writer(source, url, target, headers);
    });
    await manager.enqueueKomiic(_komiic(), chapterIndexes: [1]);
    final task = manager.tasks.single;
    await waitTask(task);
    expect(task.error, isNotNull);
    expect(task.completedChapters, isEmpty);
    expect(await File(p.join(root.path, 'download.db')).exists(), isTrue);
    final db = sqlite3.open(p.join(root.path, 'download.db'));
    try {
      expect(db.select('select * from download'), isEmpty);
    } finally {
      db.dispose();
    }
  });

  test('完成记录结合已知页数检测丢失尾页与零字节文件', () async {
    await manager.enqueueJm(_jm(), chapterIndexes: [0]);
    await waitTask(manager.tasks.single);
    final page = File(p.join(root.path, 'Chapter Book', '1', '2.jpg'));
    await page.delete();
    expect(
        (await manager.chapterStatuses(
            sourceKey: 'jm', candidateIds: ['jm41'], chapterCount: 4))[0],
        isNull);
    await page.writeAsBytes([]);
    expect(
        (await manager.chapterStatuses(
            sourceKey: 'jm', candidateIds: ['jm41'], chapterCount: 4))[0],
        isNull);
    await page.writeAsBytes([1]);
    expect(
        (await manager.chapterStatuses(
            sourceKey: 'jm', candidateIds: ['jm41'], chapterCount: 4))[0],
        ChapterDownloadStatus.downloaded);
  });

  test('队列恢复保留选择/完成/路径，旧missing选择兼容全章并暂停', () async {
    manager.pauseAll();
    await manager.enqueueJm(_jm(), chapterIndexes: [1, 3]);
    manager.tasks.single.completedChapters.add(1);
    manager.tasks.single.chapterRoot = root.path;
    manager.tasks.single.chapterDirectory = 'original';
    await manager.persistQueue();
    final restored = makeManager();
    await restored.loadQueue(strict: true);
    expect(restored.tasks.single.requestedChapters, [1, 3]);
    expect(restored.tasks.single.completedChapters, {1});
    expect(restored.tasks.single.chapterDirectory, 'original');
    expect(restored.tasks.single.paused, isTrue);
    final queue = File(p.join(root.path, 'download_queue.json'));
    final list = jsonDecode(await queue.readAsString()) as List;
    final item = list.single as Map;
    item.remove('chapterIndexes');
    item.remove('completedChapters');
    await queue.writeAsString(jsonEncode(list));
    final old = makeManager();
    await old.loadQueue(strict: true);
    expect(old.tasks.single.requestedChapters, [0, 1, 2, 3]);
    expect(old.tasks.single.completedChapters, isEmpty);
    expect(old.tasks.single.paused, isTrue);
  });

  test('队列或已下载DB错误明确抛出，修复后可重试，不当全部可下载', () async {
    final queue = File(p.join(root.path, 'download_queue.json'));
    await queue.writeAsString('{bad json');
    await expectLater(
        manager.chapterStatuses(
            sourceKey: 'jm', candidateIds: ['jm41'], chapterCount: 4),
        throwsA(isA<FormatException>()));
    await queue.writeAsString('[]');
    expect(
        await manager.chapterStatuses(
            sourceKey: 'jm', candidateIds: ['jm41'], chapterCount: 4),
        isEmpty);
    await File(p.join(root.path, 'download.db')).writeAsString('bad database');
    await expectLater(
        manager.chapterStatuses(
            sourceKey: 'jm', candidateIds: ['jm41'], chapterCount: 4),
        throwsA(anything));
  });

  test('持久化失败回滚旧全章metadata，不允许失败追加执行', () async {
    manager.pauseAll();
    await manager.enqueueJm(_jm(count: 2));
    final task = manager.tasks.single;
    task.chapterIndexes = null; // Old whole-book task semantics.
    final queue = File(p.join(root.path, 'download_queue.json'));
    await queue.delete();
    await Directory(queue.path).create();
    final result = await manager.enqueueJm(_jm(), chapterIndexes: [3]);
    expect(result.error, isTrue);
    expect(identical(manager.tasks.single, task), isTrue);
    expect(task.totalEps, 2);
    expect(task.requestedChapters, [0, 1]);
    expect(reads, isEmpty);
    await Directory(queue.path).delete();
  });

  test('暂停后立即恢复，旧请求取消错误不会覆盖新一轮状态或双执行', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var attempts = 0;
    manager = makeManager(load: (source, id, index, chapterId) async {
      attempts++;
      if (attempts == 1) {
        entered.complete();
        await release.future;
        throw StateError('old request cancelled while unwinding');
      }
      return loader(source, id, index, chapterId);
    });
    await manager.enqueueJm(_jm(), chapterIndexes: [0]);
    await entered.future.timeout(const Duration(seconds: 5));
    final task = manager.tasks.single;
    manager.pauseOne(task.id);
    manager.resumeOne(task.id);
    expect(task.paused, isFalse);
    expect(attempts, 1, reason: '旧执行体退出前不启动第二个执行体');
    release.complete();
    await waitTask(task);
    expect(task.completed, isTrue);
    expect(task.cancelled, isFalse);
    expect(task.error, isNull);
    expect(attempts, 2);
    expect(reads.map((entry) => entry.$2), [0]);
    expect((await record('jm41'))['downloadedChapters'], [0]);
  });
}
