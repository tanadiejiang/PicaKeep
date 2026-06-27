import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:sqlite3/open.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final Directory root;

  @override
  Future<String?> getApplicationCachePath() async {
    final dir = Directory('${root.path}${Platform.pathSeparator}cache');
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String?> getApplicationSupportPath() async {
    final dir = Directory('${root.path}${Platform.pathSeparator}support');
    await dir.create(recursive: true);
    return dir.path;
  }
}

void main() {
  open.overrideFor(
    OperatingSystem.windows,
    () => DynamicLibrary.open(
      '${Directory.current.path}${Platform.pathSeparator}windows'
      '${Platform.pathSeparator}sqlite3.dll',
    ),
  );

  test(
      'online source foundation persists data, cookies, image cache and aborts',
      () async {
    final root = await Directory.systemTemp.createTemp('picakeep_online_test_');
    PathProviderPlatform.instance = _FakePathProvider(root);
    await App.init(
        dataPathOverride: '${root.path}${Platform.pathSeparator}data');

    final source = ComicSource.named(
      key: 'test_source',
      name: 'Test Source',
      data: {'token': 'before'},
    );
    await source.saveData();
    source.data
      ..clear()
      ..['token'] = 'after';
    await source.loadData();
    expect(source.data['token'], 'before');

    final cookieJar = CookieJarSql(
      '${root.path}${Platform.pathSeparator}cookies.db',
    );
    cookieJar.saveFromResponseCookieHeader(
      Uri.parse('https://example.com/path/index'),
      ['session=abc; Path=/path; HttpOnly'],
    );
    expect(
      cookieJar.loadForRequestCookieHeader(
        Uri.parse('https://example.com/path/page'),
      ),
      contains('session=abc'),
    );
    cookieJar.dispose();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requestCount = 0;
    final serverDone = Completer<void>();
    unawaited(() async {
      await for (final request in server) {
        requestCount++;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      }
      serverDone.complete();
    }());
    final url = 'http://${server.address.host}:${server.port}/image.png';
    final first = await OnlineImageManager.instance.getImage(url);
    expect(await first.stream.expand((chunk) => chunk).toList(), [1, 2, 3, 4]);
    final second = await OnlineImageManager.instance.getImage(url);
    expect(await second.stream.expand((chunk) => chunk).toList(), [1, 2, 3, 4]);
    expect(requestCount, 1);

    final abortSignal = StreamImageAbortSignal()..abort();
    await expectLater(
      OnlineImageManager.instance
          .getImage('$url?abort=1', abortSignal: abortSignal),
      throwsA(isA<StateError>()),
    );

    await server.close(force: true);
    await serverDone.future.timeout(
      const Duration(seconds: 1),
      onTimeout: () {},
    );

    final supportDownloadDir = Directory(
      '${root.path}${Platform.pathSeparator}support'
      '${Platform.pathSeparator}download',
    );
    const comicId = 'abcdefabcdefabcdefabcdef';
    final comicDir = Directory(
      '${supportDownloadDir.path}${Platform.pathSeparator}$comicId'
      '${Platform.pathSeparator}1',
    );
    await comicDir.create(recursive: true);
    await File(
      '${supportDownloadDir.path}${Platform.pathSeparator}$comicId'
      '${Platform.pathSeparator}cover.jpg',
    ).writeAsBytes([9, 8, 7]);
    final pageFile = File('${comicDir.path}${Platform.pathSeparator}1.jpg');
    await pageFile.writeAsBytes([1, 2, 3]);

    final db = sqlite.sqlite3.open(
      '${supportDownloadDir.path}${Platform.pathSeparator}download.db',
    );
    try {
      db.execute('''
        create table download (
          id text primary key,
          title text,
          subtitle text,
          time int,
          directory text,
          size int,
          json text
        )
      ''');
      db.execute(
        'insert into download values (?,?,?,?,?,?,?)',
        [
          comicId,
          'Title',
          'Author',
          DateTime.now().millisecondsSinceEpoch,
          comicId,
          1,
          jsonEncode({
            'comicId': comicId,
            'title': 'Title',
            'author': 'Author',
            'description': 'Desc',
            'thumbUrl': '',
            'chapters': ['EP 1'],
            'downloadedChapters': [0],
            'tagList': ['tag'],
          }),
        ],
      );
    } finally {
      db.dispose();
    }

    final previousPath = appdata.settings[22];
    appdata.settings[22] =
        '${root.path}${Platform.pathSeparator}special-download-root';
    try {
      final items =
          await OnlineDownloadManager.instance.loadCompletedDownloads();
      expect(items, hasLength(1));
      final item = items.single as OnlineDownloadedComic;
      expect(item.name, 'Title');
      expect(item.localCoverPath, endsWith('cover.jpg'));

      final readingData = OnlineLocalReadingData(
        title: item.name,
        id: item.id,
        rootDirectoryPath: item.rootDirectoryPath,
        chapters: {'1': 'EP 1'},
      );
      expect(await readingData.loadEpNetwork(1), [pageFile.path]);
      expect(await readingData.loadImageNetwork(1, 1, pageFile.path).first,
          [1, 2, 3]);
    } finally {
      appdata.settings[22] = previousPath;
      await root.delete(recursive: true);
    }
  });
}
