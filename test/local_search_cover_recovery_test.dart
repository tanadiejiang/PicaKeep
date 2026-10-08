import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/archive/archive_registry.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_search_data_source.dart';
import 'package:picakeep/foundation/local_search_cover.dart';
import 'package:picakeep/foundation/local_trash_store.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart';
import 'package:picakeep/pages/local_search_page.dart';
import 'package:picakeep/comic_source/built_in/pixiv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/image_disk_quota_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
}

class _RealHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..idleTimeout = Duration.zero;
}

class _Results extends LocalSearchDataSource {
  _Results(this.results);
  final List<LocalSearchResult> results;
  @override
  Future<List<String>> collectChips(LocalSearchType scope) async => [];
  @override
  Future<List<LocalSearchResult>> search(String keyword, LocalSearchType scope,
          {List<String> aliases = const []}) async =>
      results;
}

List<int> _png(int r, int g, int b, {int width = 64, int height = 96}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgba8(r, g, b, 255));
  return img.encodePng(image);
}

LocalSearchResult _favorite(String cover, {DownloadedItem? local}) =>
    LocalSearchResult(
      title: 'Favorite fixture',
      author: 'Author',
      sourceLabel: 'Pixiv',
      localItem: local,
      favoriteItem: FavoriteItemWithFolderInfo(
          FavoriteItem(
              target: '321',
              name: 'Favorite fixture',
              coverPath: cover,
              author: 'Author',
              type: FavoriteType.pixiv,
              tags: []),
          'Fixture folder'),
    );

LocalLibraryComicItem _local(String id, String path, {String? hint}) =>
    LocalLibraryComicItem(
      itemId: id,
      originalId: id,
      type: DownloadType.other,
      name: 'Local fixture',
      subTitle: 'Author',
      tags: [],
      sourceDisplayName: '图集',
      fileSystemPath: path,
      episodeFiles: {},
      downloadedEps: [0],
      eps: ['First'],
      localCoverPath: hint,
      localStorageExists: true,
      canDelete: false,
      aliases: [],
    );

LocalSearchResult _download(DownloadedItem item) => LocalSearchResult(
    title: item.name,
    author: item.subTitle,
    sourceLabel: '本地',
    downloadItem: item);

Finder _tiles() => find.byWidgetPredicate((w) => w is DownloadedComicTile);
Finder _pixels() =>
    find.descendant(of: _tiles(), matching: find.byType(RawImage));
bool _hasPixels(WidgetTester tester) =>
    _pixels().evaluate().isNotEmpty &&
    tester.renderObject<RenderImage>(_pixels().first).image != null;

Future<void> _wait(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 160 && !done(); i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 20));
    });
  }
}

Future<void> _expectColor(WidgetTester tester, List<int> rgba) async {
  await _wait(tester, () => _hasPixels(tester));
  expect(_hasPixels(tester), isTrue,
      reason: 'search result must display actual recovered cover pixels');
  final image = tester.renderObject<RenderImage>(_pixels().first).image!;
  final bytes = (await tester
      .runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
  expect(bytes.buffer.asUint8List().take(4), rgba);
  expect(find.byIcon(Icons.image_not_supported), findsNothing);
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final savedPaths = PathProviderPlatform.instance;
  final savedSettings = List<String>.of(appdata.settings);
  final savedQuota = ImageDiskQuota.overrideForTesting;
  final savedMode = managedDataSourceMode;
  final savedHttp = HttpOverrides.current;
  late Directory workspace;
  late File originalCover;
  late HttpServer server;
  late String coverUrl;
  var networkReads = 0;
  final requests = <({String path, Map<String, String> headers})>[];
  final heldResponses = <String, Completer<void>>{};
  final originalBytes = _png(31, 157, 83);

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _RealHttp();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    coverUrl = 'http://127.0.0.1:${server.port}/cover.png';
    server.listen((request) async {
      networkReads++;
      final headers = <String, String>{};
      request.headers
          .forEach((name, values) => headers[name] = values.join(','));
      requests.add((path: request.uri.path, headers: headers));
      try {
        await heldResponses[request.uri.path]?.future;
        request.response.persistentConnection = false;
        if (request.uri.path.contains('missing')) {
          request.response.statusCode = 404;
        } else {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(request.uri.path.contains('broken')
              ? [1, 2, 3, 4]
              : _png(209, 49, 71));
        }
        await request.response.close();
      } catch (_) {
        // A cancelled fixture client deliberately closes its held response.
      }
    });
    open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open(
            p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
    workspace = await Directory.systemTemp.createTemp('search_cover_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: p.join(workspace.path, 'app'));
    ArchiveRegistry.initDefaults();
    installTaskDiskQuota(() => [App.dataPath, App.cachePath]);
    setManagedDataRootOverride(workspace.path);
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
    appdata.settings[managedDataSourceModeSettingIndex] =
        managedDataSourceModeCurrentOnly;
    appdata.settings[22] = p.join(workspace.path, 'downloads');
    appdata.settings[72] = '0';
    appdata.settings[73] = '0';
    appdata.settings[pixivDownloadDirSettingIndex] = '';
    final directory = await Directory(p.join(appdata.settings[22], 'Fixture'))
        .create(recursive: true);
    originalCover = await File(p.join(directory.path, 'cover.png'))
        .writeAsBytes(originalBytes);
    await File(p.join(directory.path, '1.png')).writeAsBytes(originalBytes);
    final db = sqlite3.open(p.join(appdata.settings[22], 'download.db'));
    try {
      db.execute('CREATE TABLE download(id TEXT PRIMARY KEY,title TEXT,'
          'subtitle TEXT,time INT,directory TEXT,size REAL,json TEXT)');
      db.execute('INSERT INTO download VALUES(?,?,?,?,?,?,?)', [
        'jm123',
        'Recoverable fixture',
        'Author',
        1710000000000,
        'Fixture',
        1.0,
        jsonEncode({
          'comicId': '123',
          'name': 'Recoverable fixture',
          'author': 'Author',
          'downloadedChapters': [0],
          'epNames': ['First'],
        }),
      ]);
    } finally {
      db.dispose();
    }
  });

  tearDownAll(() async {
    await server.close(force: true);
    HttpOverrides.global = savedHttp;
    downloadManager.dispose();
    LocalTrashStore.instance.dispose();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    BaseImageProvider.clearCache();
    ImageDiskQuota.overrideForTesting = savedQuota;
    PathProviderPlatform.instance = savedPaths;
    setManagedDataRootOverride(null);
    setManagedDataSourceMode(savedMode);
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    await workspace.delete(recursive: true);
  });

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    var drained = ImageDiskQuota.shared.pendingOperations == 0;
    unawaited(ImageDiskQuota.shared.drain().then((_) => drained = true));
    await _wait(tester, () => drained);
    expect(drained, isTrue);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    BaseImageProvider.clearCache();
  }

  Future<void> openResults(WidgetTester tester, List<LocalSearchResult> results,
      {LocalSearchCoverResolver? covers}) async {
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(
        home: LocalSearchPage(
            initialKeyword: 'fixture',
            searchType: LocalSearchType.all,
            coverResolver: covers,
            dataSource: _Results(results)))));
  }

  testWidgets('downloads search repairs missing persisted managed cover',
      (tester) async {
    final manager = LocalLibraryManager();
    final path = (await tester.runAsync(() async {
      final items = await manager.getManagedDownloads(forceRefresh: true);
      final path = await manager.resolveCoverPathForItem(items.single);
      expect(p.isWithin(LocalCoverCache.rootDirectory().path, path!), isTrue);
      await File(path).delete();
      final reloaded = await manager.getManagedDownloads(forceRefresh: true);
      expect(reloaded.single.localCoverPath, path);
      return path;
    }))!;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    BaseImageProvider.clearCache();
    await tester.runAsync(() => tester.pumpWidget(const MaterialApp(
        home: LocalSearchPage(
            initialKeyword: 'Recoverable',
            searchType: LocalSearchType.downloadsOnly))));
    await _expectColor(tester, [31, 157, 83, 255]);
    await tester.runAsync(() async {
      expect(await File(path).readAsBytes(), originalBytes);
      expect(await originalCover.readAsBytes(), originalBytes);
    });
    await close(tester);
  });

  testWidgets('favorite search resolves valid local cover to actual pixels',
      (tester) async {
    final source = _Results([_favorite(originalCover.path)]);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(
        home: LocalSearchPage(
            initialKeyword: 'Favorite',
            searchType: LocalSearchType.favoritesOnly,
            dataSource: source))));
    await _expectColor(tester, [31, 157, 83, 255]);
    await close(tester);
  });

  testWidgets(
      'favorite search loads URL cover rather than treating URL as File',
      (tester) async {
    final before = networkReads;
    final source = _Results([_favorite(coverUrl)]);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(
        home: LocalSearchPage(
            initialKeyword: 'Favorite',
            searchType: LocalSearchType.favoritesOnly,
            dataSource: source))));
    await _expectColor(tester, [209, 49, 71, 255]);
    expect(networkReads - before, 1);
    final headers = requests.last.headers;
    expect(headers['referer'], 'https://www.pixiv.net/');
    expect(headers['user-agent'], isNotEmpty);
    await close(tester);
  });

  testWidgets('all search also repairs stale managed source and remains bound',
      (tester) async {
    final item = (await tester.runAsync(() async {
      final manager = LocalLibraryManager();
      final items = await manager.getManagedDownloads(forceRefresh: true);
      final derived = await manager.resolveCoverPathForItem(items.single);
      await File(derived!).delete();
      return (await manager.getManagedDownloads(forceRefresh: true)).single;
    }))!;
    await openResults(tester, [_download(item)]);
    await _expectColor(tester, [31, 157, 83, 255]);
    final tile = tester.widget<DownloadedComicTile>(_tiles());
    expect(tile.optimizeCoverDecode, isTrue);
    expect(tile.imagePath.path, isEmpty);
    await close(tester);
  });

  testWidgets('unresolved directory and obsolete hint resolve from real source',
      (tester) async {
    final dir = (await tester
        .runAsync(() => Directory(p.join(workspace.path, 'Album')).create()))!;
    await tester.runAsync(() =>
        File(p.join(dir.path, 'cover.png')).writeAsBytes(_png(23, 45, 210)));
    final item = _local('local_album::unresolved', dir.path,
        hint: p.join(workspace.path, 'deleted.png'));
    await openResults(tester, [_download(item)]);
    await _expectColor(tester, [23, 45, 210, 255]);
    expect(item.localCoverPath, p.join(dir.path, 'cover.png'));
    await close(tester);
  });

  testWidgets('stale favorite file falls back to associated managed download',
      (tester) async {
    final item = (await tester.runAsync(() =>
            LocalLibraryManager().getManagedDownloads(forceRefresh: true)))!
        .single;
    await openResults(tester, [
      _favorite(p.join(workspace.path, 'missing-favorite.png'), local: item)
    ]);
    await _expectColor(tester, [31, 157, 83, 255]);
    await close(tester);
  });

  testWidgets(
      'decode failure in associated local cover still falls back to URL',
      (tester) async {
    final dir = (await tester.runAsync(
        () => Directory(p.join(workspace.path, 'BrokenAlbum')).create()))!;
    // Keep IHDR and part of IDAT: Codec creation succeeds, getNextFrame fails.
    final damaged = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAYAAACbU/80AAAAm0lEQVR4nMWVMQ7AIA==');
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(damaged);
      try {
        await expectLater(codec.getNextFrame(), throwsA(isA<Exception>()));
      } finally {
        codec.dispose();
      }
    });
    final broken = (await tester.runAsync(
        () => File(p.join(dir.path, 'cover.png')).writeAsBytes(damaged)))!;
    final item = _local('local_album::broken', dir.path, hint: broken.path);
    final url = coverUrl.replaceFirst('cover.png', 'fallback.png');
    final before = networkReads;
    await openResults(tester, [_favorite(url, local: item)]);
    await _expectColor(tester, [209, 49, 71, 255]);
    expect(networkReads - before, 1);
    expect(await tester.runAsync(broken.readAsBytes), damaged);
    await close(tester);
  });

  testWidgets('deleted extracted archive cover is rematerialized by manager',
      (tester) async {
    final zip = (await tester.runAsync(() async {
      final data = ZipEncoder().encode(Archive()
        ..addFile(ArchiveFile('cover.png', originalBytes.length, originalBytes))
        ..addFile(ArchiveFile('1.png', originalBytes.length, originalBytes)));
      return File(p.join(workspace.path, 'Archive.zip')).writeAsBytes(data);
    }))!;
    final item = _local('local_archive::fixture', zip.path,
        hint: p.join(workspace.path, 'deleted-extracted.png'));
    await openResults(tester, [_download(item)]);
    await _expectColor(tester, [31, 157, 83, 255]);
    expect(item.localCoverPath, isNot(contains('://')));
    await close(tester);
  });

  testWidgets('explicit no-cover sentinel stays a stable terminal placeholder',
      (tester) async {
    final covers = LocalSearchCoverResolver();
    final item = _local('local_album::no-cover', workspace.path,
        hint: LocalLibraryManager.noCoverSentinel);
    expect(covers.providerFor(_download(item)), isNull);
    await openResults(tester, [_download(item)], covers: covers);
    await tester.pump(const Duration(seconds: 20));
    expect(_hasPixels(tester), isFalse);
    expect(covers.pendingLoadsForTesting, 0);
    expect(find.byIcon(Icons.image_not_supported), findsOneWidget);
    await close(tester);
  });

  testWidgets('very tall local cover follows actual bounded card decoder',
      (tester) async {
    final file = (await tester.runAsync(() =>
        File(p.join(workspace.path, 'Tall.png'))
            .writeAsBytes(_png(19, 99, 33, width: 2, height: 10000))))!;
    await openResults(tester, [_favorite(file.path)]);
    await _expectColor(tester, [19, 99, 33, 255]);
    final image = tester.renderObject<RenderImage>(_pixels()).image!;
    expect(image.height, lessThanOrEqualTo(4096));
    expect(image.width * image.height, lessThanOrEqualTo(4 * 1024 * 1024));
    await close(tester);
  });

  testWidgets(
      'validated cover replays GIF first frame and subsequent animation',
      (tester) async {
    img.Image frame(int red, int blue) {
      final image = img.Image(width: 2, height: 2, withPalette: true);
      image.palette!.setRgb(1, red, 0, blue);
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 2; x++) {
          image.setPixelIndex(x, y, 1);
        }
      }
      return image;
    }

    final gif = (img.GifEncoder(repeat: 3)
          ..addFrame(frame(255, 0), duration: 100)
          ..addFrame(frame(0, 255), duration: 130))
        .finish()!;
    final file = (await tester.runAsync(
        () => File(p.join(workspace.path, 'Animated.gif')).writeAsBytes(gif)))!;
    await openResults(tester, [_favorite(file.path)]);
    await _expectColor(tester, [255, 0, 0, 255]);
    final first = tester.renderObject<RenderImage>(_pixels()).image;
    await tester.pump(const Duration(milliseconds: 1100));
    await _wait(tester,
        () => tester.renderObject<RenderImage>(_pixels()).image != first);
    await _expectColor(tester, [0, 0, 255, 255]);
    final second = tester.renderObject<RenderImage>(_pixels()).image;
    await tester.pump(const Duration(milliseconds: 1400));
    await _wait(tester,
        () => tester.renderObject<RenderImage>(_pixels()).image != second);
    await _expectColor(tester, [255, 0, 0, 255]);
    await close(tester);
  });

  testWidgets('all-source 404 stops after one existing bounded retry',
      (tester) async {
    final url = coverUrl.replaceFirst('cover.png', 'missing.png');
    final covers = LocalSearchCoverResolver();
    final before = networkReads;
    await openResults(tester, [_favorite(url)], covers: covers);
    await _wait(
        tester,
        () =>
            networkReads > before &&
            covers.pendingLoadsForTesting == 0 &&
            find.byIcon(Icons.image_not_supported).evaluate().isNotEmpty);
    // Native IO is admitted outside the FakeAsync frame lifetime. The existing
    // card's one retry therefore uses its real five-second timer in this fixture.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5200)));
    await tester.pump(const Duration(seconds: 6));
    await _wait(tester,
        () => networkReads >= before + 2 && covers.pendingLoadsForTesting == 0);
    expect(networkReads - before, 2);
    await tester.pump(const Duration(seconds: 30));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    expect(networkReads - before, 2);
    expect(_hasPixels(tester), isFalse);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('leaving held HTTP cover cancels rather than publishing late',
      (tester) async {
    const path = '/held-exit.png';
    final gate = heldResponses[path] = Completer<void>();
    final covers = LocalSearchCoverResolver();
    final before = networkReads;
    await openResults(
        tester, [_favorite(coverUrl.replaceFirst('/cover.png', path))],
        covers: covers);
    await _wait(tester, () => networkReads > before);
    expect(covers.pendingLoadsForTesting, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await _wait(tester, () => covers.pendingLoadsForTesting == 0);
    expect(covers.pendingLoadsForTesting, 0);
    gate.complete();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(_hasPixels(tester), isFalse);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets(
      'clearing query cancels even when ImageCache holds pending listener',
      (tester) async {
    const path = '/held-clear.png';
    final gate = heldResponses[path] = Completer<void>();
    final covers = LocalSearchCoverResolver();
    final before = networkReads;
    await openResults(
        tester, [_favorite(coverUrl.replaceFirst('/cover.png', path))],
        covers: covers);
    await _wait(tester, () => networkReads > before);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pump();
    await _wait(tester, () => covers.pendingLoadsForTesting == 0);
    expect(covers.pendingLoadsForTesting, 0);
    gate.complete();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(_tiles(), findsNothing);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets(
      'LRU-evicted pending request remains cancellable on page disposal',
      (tester) async {
    const path = '/held-lru.png';
    final gate = heldResponses[path] = Completer<void>();
    final covers = LocalSearchCoverResolver();
    final before = networkReads;
    await openResults(
        tester, [_favorite(coverUrl.replaceFirst('/cover.png', path))],
        covers: covers);
    await _wait(tester, () => networkReads > before);
    for (var i = 0; i < 140; i++) {
      covers.providerFor(_favorite('$coverUrl?unused=$i'));
    }
    expect(covers.providerCountForTesting, 128);
    expect(covers.pendingLoadsForTesting, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await _wait(tester, () => covers.pendingLoadsForTesting == 0);
    expect(covers.pendingLoadsForTesting, 0);
    gate.complete();
    await close(tester);
  });

  testWidgets('same URL under another account gets a separate opaque image key',
      (tester) async {
    final saved = Map<String, dynamic>.of(pixiv.data);
    addTearDown(() => pixiv.data
      ..clear()
      ..addAll(saved));
    final covers = LocalSearchCoverResolver();
    final result = _favorite(coverUrl.replaceFirst('cover.png', 'account.png'));
    pixiv.data['token'] = 'synthetic-account-A';
    final first = covers.providerFor(result)!;
    expect(covers.providerFor(result), same(first));
    pixiv.data['token'] = 'synthetic-account-B';
    final second = covers.providerFor(result)!;
    expect(second, isNot(first));
    expect(first.toString(), isNot(contains('synthetic-account')));
    expect(second.toString(), isNot(contains('synthetic-account')));
    covers.dispose();
  });

  testWidgets('held cover then immediate same query gets a fresh live load',
      (tester) async {
    const path = '/held-resubmit.png';
    final gate = heldResponses[path] = Completer<void>();
    final covers = LocalSearchCoverResolver();
    final result = _favorite(coverUrl.replaceFirst('/cover.png', path));
    final before = networkReads;
    await openResults(tester, [result], covers: covers);
    await _wait(tester, () => networkReads > before);
    final first = covers.providerFor(result);
    heldResponses.remove(path);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    final second = covers.providerFor(result);
    expect(second, isNot(first));
    await _expectColor(tester, [209, 49, 71, 255]);
    expect(networkReads - before, 2);
    gate.complete();
    await close(tester);
  });
}
