import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/http_image_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
}

JmComicInfo _jm() => const JmComicInfo(
    id: '41',
    title: 'HTTP Fixture',
    authors: [],
    description: '',
    likes: 0,
    views: 0,
    comments: 0,
    tags: [],
    works: [],
    actors: [],
    series: {1: '501'},
    epNames: ['One'],
    isFavourite: false,
    isLiked: false,
    coverUrl: '',
    relatedComics: []);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open(
            p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
  }
  final png = syntheticHttpPng();
  final smallWire = gzip.encode(png);
  final largeWire = GZipCodec(level: 0).encode(png);
  final originalPaths = PathProviderPlatform.instance;
  final savedSettings = List<String>.of(appdata.settings);
  final savedRecording = LogManager.recordingEnabled;
  late Directory workspace;
  late Directory root;
  final managers = <OnlineDownloadManager>[];

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('jm_http_download_056_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: p.join(workspace.path, 'app'));
    LogManager.recordingEnabled = false;
  });
  setUp(() async {
    root = await workspace.createTemp('case-');
    appdata.settings[22] = root.path;
    managers.clear();
  });
  tearDown(() async {
    for (final manager in managers) {
      manager.pauseAll();
      manager.removeAll(manager.tasks.map((e) => e.id).toList());
      await manager.persistQueue();
      manager.version.dispose();
    }
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    LogManager.recordingEnabled = savedRecording;
    // Ordinary downloads instantiate the EH slot gate even for non-EH URLs.
    // Its cookie DB belongs to this suite's isolated App.dataPath.
    EhNetwork().cookieJar.dispose();
    await workspace.delete(recursive: true);
  });

  Future<HttpImageFixture> serve(
      HttpImageReply Function(Uri, String) handler) async {
    final fixture = await HttpImageFixture.start(handler);
    addTearDown(fixture.close);
    return fixture;
  }

  Dio dio() {
    final value = directImageDio();
    addTearDown(() => value.close(force: true));
    return value;
  }

  Future<void> waitTask(
      OnlineDownloadManager manager, OnlineDownloadTask task) async {
    if (task.completed || task.error != null) return;
    final done = Completer<void>();
    void changed() {
      if ((task.completed || task.error != null) && !done.isCompleted) {
        done.complete();
      }
    }

    manager.version.addListener(changed);
    try {
      await done.future.timeout(const Duration(seconds: 20));
    } finally {
      manager.version.removeListener(changed);
    }
  }

  Map<String, dynamic> record(String id) {
    final db = sqlite3.open(p.join(root.path, 'download.db'));
    try {
      return Map<String, dynamic>.from(jsonDecode(
          db.select('select json from download where id=?', [id]).single['json']
              as String));
    } finally {
      db.dispose();
    }
  }

  for (final missing in [2, 3]) {
    test(
        'JM production HTTP missing page $missing retries only gap, then DB/queue complete',
        () async {
      var fail = true;
      final fixture = await serve((uri, headers) {
        expect(headers.toLowerCase(), contains('accept-encoding: gzip\r\n'));
        if (fail && uri.path == '/$missing.png') return HttpImageReply([]);
        return HttpImageReply(missing == 2 ? smallWire : largeWire,
            encoding: 'gzip');
      });
      final manager = OnlineDownloadManager.forTesting(
          downloadRoot: root.path,
          imageDio: dio(),
          chapterLoader: (_, __, ___, ____) async =>
              Res([for (var i = 1; i <= 3; i++) fixture.url('/$i.png')]));
      managers.add(manager);
      expect((await manager.enqueueJm(_jm())).success, isTrue);
      final task = manager.tasks.single;
      await waitTask(manager, task);
      expect(task.completed, isFalse);
      expect(task.error, isNotNull);
      expect(task.completedChapters, isEmpty);
      final chapter = p.join(root.path, 'HTTP Fixture', '1');
      expect(await File(p.join(chapter, '$missing.png')).exists(), isFalse);
      final preserved = <int, Digest>{};
      for (var i = 1; i <= 3; i++) {
        if (i == missing) continue;
        final file = File(p.join(chapter, '$i.png'));
        expect(await file.readAsBytes(), png);
        preserved[i] = sha256.convert(await file.readAsBytes());
      }
      await manager.persistQueue();
      expect(
          jsonDecode(await File(p.join(root.path, 'download_queue.json'))
              .readAsString()),
          isNotEmpty);
      fixture.requests.clear();
      fail = false;
      var sawCompleted = false;
      void verifyCommitOrder() {
        if (!task.completed) return;
        sawCompleted = true;
        expect(record('jm41')['downloadedChapters'], [0]);
        expect(
            jsonDecode(File(p.join(root.path, 'download_queue.json'))
                .readAsStringSync()),
            isEmpty);
        expect(File(p.join(chapter, '$missing.png')).readAsBytesSync(), png);
      }

      manager.version.addListener(verifyCommitOrder);
      try {
        manager.retry(task.id);
        await waitTask(manager, task);
      } finally {
        manager.version.removeListener(verifyCommitOrder);
      }
      expect(task.error, isNull);
      expect(task.completed, isTrue);
      expect(sawCompleted, isTrue);
      expect(fixture.requests.map((u) => u.path), ['/$missing.png']);
      for (final entry in preserved.entries) {
        expect(
            sha256.convert(
                await File(p.join(chapter, '${entry.key}.png')).readAsBytes()),
            entry.value);
      }
      expect(record('jm41')['chapterPageCounts'], {'0': 3});
      expect(
          await Directory(chapter)
              .list()
              .where((f) => f.path.endsWith('.part'))
              .toList(),
          isEmpty);
    });
  }

  for (final entry
      in {'small-wire': smallWire, 'large-wire': largeWire}.entries) {
    test(
        'local JM missing-page repair ${entry.key} uses same production HTTP bytes',
        () async {
      final fixture =
          await serve((_, __) => HttpImageReply(entry.value, encoding: 'gzip'));
      final chapter = await Directory(p.join(root.path, 'book', '1'))
          .create(recursive: true);
      final target = File(p.join(chapter.path, '1.png'));
      final neighbor = File(p.join(chapter.path, '1.jpg'));
      await neighbor.writeAsBytes([8, 9, 10]);
      final data = OnlineLocalReadingData(
          title: 'Local',
          id: 'jm41',
          rootDirectoryPath: chapter.parent.path,
          chapters: const {'1': 'One'},
          isJm: true,
          jmComicId: '41',
          imageDio: dio(),
          jmChapterLoader: (_) async =>
              (chapterId: '501', urls: [fixture.url('/1.png')]));
      expect(
          await data
              .loadImageNetwork(1, 1, target.path)
              .expand((e) => e)
              .toList(),
          png);
      expect(await target.readAsBytes(), png);
      expect(await neighbor.readAsBytes(), [8, 9, 10]);
      expect(await File('${target.path}.part').exists(), isFalse);
      expect(
          await data
              .loadImageNetwork(1, 1, target.path)
              .expand((e) => e)
              .toList(),
          png);
      expect(fixture.requests, hasLength(1));
    });
  }

  test(
      'local JM genuine truncated gzip never replaces old file; next retry works',
      () async {
    var fail = true;
    final fixture = await serve((_, __) => fail
        ? HttpImageReply(smallWire.sublist(0, smallWire.length - 5),
            encoding: 'gzip', declaredLength: smallWire.length)
        : HttpImageReply(smallWire, encoding: 'gzip'));
    final chapter =
        await Directory(p.join(root.path, 'book', '1')).create(recursive: true);
    final target = File(p.join(chapter.path, '1.png'));
    await target.writeAsBytes([]);
    final neighbor = File(p.join(chapter.path, '1.jpg'));
    await neighbor.writeAsBytes([7, 8]);
    final data = OnlineLocalReadingData(
        title: 'Local',
        id: 'jm41',
        rootDirectoryPath: chapter.parent.path,
        chapters: const {'1': 'One'},
        isJm: true,
        jmComicId: '41',
        imageDio: dio(),
        jmChapterLoader: (_) async =>
            (chapterId: '501', urls: [fixture.url('/1.png')]));
    await expectLater(
        data.loadImageNetwork(1, 1, target.path).toList(), throwsA(anything));
    expect(await target.readAsBytes(), isEmpty);
    expect(await neighbor.readAsBytes(), [7, 8]);
    expect(await File('${target.path}.part').exists(), isFalse);
    fail = false;
    expect(
        await data
            .loadImageNetwork(1, 1, target.path)
            .expand((e) => e)
            .toList(),
        png);
    expect(await neighbor.readAsBytes(), [7, 8]);
    expect(fixture.requests, hasLength(4));
  });

  test('ordinary picacg production stream still writes decoded gzip exactly',
      () async {
    final fixture =
        await serve((_, __) => HttpImageReply(largeWire, encoding: 'gzip'));
    final manager = OnlineDownloadManager.forTesting(
        downloadRoot: root.path,
        imageDio: dio(),
        chapterLoader: (_, __, ___, ____) async =>
            Res([fixture.url('/1.png')]));
    managers.add(manager);
    final comic = PicacgComicItem.fromApi(
        json: {'_id': '0123456789abcdef01234567', 'title': 'Ordinary'},
        eps: const ['One'],
        recommendation: const []);
    expect((await manager.enqueuePicacg(comic)).success, isTrue);
    final task = manager.tasks.single;
    await waitTask(manager, task);
    expect(task.error, isNull);
    expect(task.completed, isTrue);
    expect(
        await File(p.join(root.path, 'Ordinary', '1', '1.png')).readAsBytes(),
        png);
  });
}
