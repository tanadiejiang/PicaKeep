import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/pages/download_page.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

FavoriteItem favorite(String id) => FavoriteItem(
    target: id,
    name: 'Fixture $id',
    coverPath: '',
    author: 'Author',
    type: FavoriteType.jm,
    tags: []);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
      OperatingSystem.windows,
      () =>
          DynamicLibrary.open('${Directory.current.path}/windows/sqlite3.dll'));
  final manager = LocalFavoritesManager();
  final paths = PathProviderPlatform.instance;
  final mode = managedDataSourceMode;
  late List<String> settings;
  late Directory workspace;
  late Directory root;
  var serial = 0;
  setUpAll(() async {
    settings = List.of(appdata.settings);
    workspace = await Directory.systemTemp.createTemp('pk04_refresh_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
  });
  setUp(() async {
    root = await Directory('${workspace.path}/${serial++}').create();
    setManagedDataRootOverride(root.path);
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
    appdata.settings[managedDataSourceModeSettingIndex] =
        managedDataSourceModeCurrentOnly;
    appdata.settings[downloadedLibraryViewSettingIndex] = 'local';
    appdata.settings[22] = '${root.path}/downloads';
    appdata.settings[72] = '1';
    appdata.settings[73] = '0';
    await Directory(appdata.settings[22]).create();
    await manager.init();
    manager.createFolder('A');
    manager.createFolder('B');
  });
  tearDown(() {
    downloadManager.dispose();
    manager.dispose();
  });
  tearDownAll(() {
    PathProviderPlatform.instance = paths;
    setManagedDataRootOverride(null);
    setManagedDataSourceMode(mode);
    appdata.settings
      ..clear()
      ..addAll(settings);
  });
  Future<void> fixture({int count = 2}) async {
    final dir = await Directory('${appdata.settings[22]}/Fixture').create();
    await File('${dir.path}/cover.png')
        .writeAsBytes(image.encodePng(image.Image(width: 3, height: 2)));
    await File('${dir.path}/1.png')
        .writeAsBytes(image.encodePng(image.Image(width: 3, height: 2)));
    final db = sqlite3.open('${appdata.settings[22]}/download.db');
    db.execute(
        'CREATE TABLE download(id TEXT PRIMARY KEY,title TEXT,subtitle TEXT,time INT,directory TEXT,size REAL,json TEXT)');
    for (var i = 0; i < count; i++) {
      // Different directory identities let the real loader retain the whole list.
      final name = 'Fixture$i';
      await Directory('${appdata.settings[22]}/$name').create();
      await File('${dir.path}/cover.png')
          .copy('${appdata.settings[22]}/$name/cover.png');
      await File('${dir.path}/1.png')
          .copy('${appdata.settings[22]}/$name/1.png');
      db.execute('INSERT INTO download VALUES(?,?,?,?,?,?,?)', [
        'jm${123 + i}',
        'Fixture ${123 + i}',
        'Author',
        1710000000000 + i,
        name,
        1.0,
        jsonEncode({
          'comicId': '${123 + i}',
          'name': 'Fixture ${123 + i}',
          'author': 'Author',
          'downloadedChapters': [0],
          'epNames': ['First']
        })
      ]);
    }
    db.dispose();
  }

  Future<DownloadPageLogic> launch(WidgetTester tester, {int count = 2}) async {
    await tester.runAsync(() => fixture(count: count));
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: DownloadPage()));
      for (var i = 0;
          i < 500 && StateController.find<DownloadPageLogic>().loading;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    final logic = StateController.find<DownloadPageLogic>();
    expect(logic.loading, isFalse);
    expect(logic.baseComics, hasLength(count));
    return logic;
  }

  Finder tiles() => find.byWidgetPredicate((w) => w is DownloadedComicTile);
  DownloadedComicTile tile(WidgetTester tester, String id) => tester
      .widgetList<DownloadedComicTile>(tiles())
      .singleWhere((w) => w.comicID == id);
  Future<void> notify(WidgetTester tester) async {
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
  }

  testWidgets(
      'mounted real VM updates false true false without reloading or losing selection',
      (tester) async {
    final logic = await launch(tester);
    expect(tile(tester, 'jm123').isFavoriteOverride, isFalse);
    final original = tile(tester, 'jm123');
    logic.selecting = true;
    logic.selected[0] = true;
    logic.selectedNum = 1;
    logic.keyword = 'kept';
    final selected = List.of(logic.selected);
    final base = logic.baseComics;
    final comics = logic.comics;
    LogManager.clear();
    manager.addComic('A', favorite('123'));
    await notify(tester);
    expect(tile(tester, 'jm123').isFavoriteOverride, isTrue);
    expect(find.byIcon(Icons.bookmark_rounded), findsOneWidget);
    manager.addComic('B', favorite('123'));
    manager.deleteComicWithTarget('A', '123', FavoriteType.jm);
    await notify(tester);
    expect(tile(tester, 'jm123').isFavoriteOverride, isTrue);
    manager.deleteComicWithTarget('B', '123', FavoriteType.jm);
    await notify(tester);
    expect(tile(tester, 'jm123').isFavoriteOverride, isFalse);
    expect(find.byIcon(Icons.bookmark_rounded), findsNothing);
    expect(StateController.find<DownloadPageLogic>(), same(logic));
    expect(logic.baseComics, same(base));
    expect(logic.comics, same(comics));
    expect(logic.keyword, 'kept');
    expect(logic.selected, selected);
    expect(logic.selectedNum, 1);
    expect(logic.selecting, isTrue);
    final latest = tile(tester, 'jm123');
    expect(latest.author, original.author);
    expect(latest.imageProvider, same(original.imageProvider));
    expect(
        latest.readingHistoryOverride, same(original.readingHistoryOverride));
    expect(
        LogManager.logs.where((l) => l.content.startsWith('reload ')), isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    LogManager.clear();
    manager.addComic('A', favorite('123'));
    await notify(tester);
    expect(
        LogManager.logs.where((l) => l.content.startsWith('favorites.refresh')),
        isEmpty);
  });

  testWidgets('1100 items coalesce 100 changes and retain lazy list/scroll',
      (tester) async {
    final logic = await launch(tester, count: 1100);
    expect(tiles().evaluate().length, lessThan(1100));
    final scroll =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    scroll.jumpTo(400);
    await tester.pumpAndSettle();
    expect(scroll.pixels, greaterThan(0));
    final offset = scroll.pixels;
    LogManager.clear();
    for (var i = 0; i < 100; i++) {
      manager.addComic('A', favorite('${123 + i}'));
    }
    await notify(tester);
    final refreshes = LogManager.logs
        .where((l) => l.content.startsWith('favorites.refresh'))
        .toList();
    expect(refreshes, hasLength(1));
    expect(refreshes.single.content, contains('items=1100'));
    // ignore: avoid_print
    print(
        'PERF ${refreshes.single.content} mountedTiles=${tiles().evaluate().length} scroll=$offset/${scroll.pixels}');
    expect(scroll.pixels, offset);
    expect(logic.baseComics, hasLength(1100));
    expect(
        LogManager.logs.where((l) => l.content.startsWith('reload ')), isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
      'load-time changes drain after commit and binding stays idempotent',
      (tester) async {
    final logic = await launch(tester);
    logic.bindLocalDataRefresh();
    logic.bindLocalDataRefresh();
    await tester.runAsync(() async {
      final loading = logic.reload();
      manager.addComic('A', favorite('123'));
      await loading;
    });
    await notify(tester);
    expect(tile(tester, 'jm123').isFavoriteOverride, isTrue);
    LogManager.clear();
    manager.deleteComicWithTarget('A', '123', FavoriteType.jm);
    await notify(tester);
    expect(
        LogManager.logs.where((l) => l.content.startsWith('favorites.refresh')),
        hasLength(1));
    expect(tile(tester, 'jm123').isFavoriteOverride, isFalse);
    // Queue a refresh then destroy the page before the 16ms window expires.
    manager.addComic('A', favorite('123'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    LogManager.clear();
    await notify(tester);
    expect(
        LogManager.logs.where((l) => l.content.startsWith('favorites.refresh')),
        isEmpty);
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: DownloadPage()));
      for (var i = 0;
          i < 100 && StateController.find<DownloadPageLogic>().loading;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await notify(tester);
    final next = StateController.find<DownloadPageLogic>();
    expect(next, isNot(same(logic)));
    LogManager.clear();
    manager.deleteComicWithTarget('A', '123', FavoriteType.jm);
    await notify(tester);
    expect(
        LogManager.logs.where((l) => l.content.startsWith('favorites.refresh')),
        hasLength(1));
    expect(tile(tester, 'jm123').isFavoriteOverride, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
      'badge disabled skips refresh and existing settings reload restores latest state',
      (tester) async {
    appdata.settings[72] = '0';
    final logic = await launch(tester);
    LogManager.clear();
    manager.addComic('A', favorite('123'));
    await notify(tester);
    expect(find.byIcon(Icons.bookmark_rounded), findsNothing);
    expect(
        LogManager.logs.where((l) => l.content.startsWith('favorites.refresh')),
        isEmpty);
    appdata.settings[72] = '1';
    await tester.runAsync(() => logic.reload());
    await tester.pumpAndSettle();
    await notify(tester);
    expect(tile(tester, 'jm123').isFavoriteOverride, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
      'covered page receives favorites and pure remote page skips local query',
      (tester) async {
    final logic = await launch(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Detail route'))));
    await tester.pumpAndSettle();
    manager.addComic('A', favorite('123'));
    await notify(tester);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(StateController.find<DownloadPageLogic>(), same(logic));
    expect(tile(tester, 'jm123').isFavoriteOverride, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.pumpWidget(
          const MaterialApp(home: DownloadPage(remoteRootId: 'fixture-root')));
      for (var i = 0;
          i < 100 && StateController.find<DownloadPageLogic>().loading;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    LogManager.clear();
    manager.deleteComicWithTarget('A', '123', FavoriteType.jm);
    await notify(tester);
    expect(
        LogManager.logs.where((l) => l.content.startsWith('favorites.refresh')),
        isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  Future<void> openBatch(WidgetTester tester, DownloadPageLogic logic) async {
    logic.selecting = true;
    logic.selected = List.filled(logic.comics.length, true);
    logic.selectedNum = logic.comics.length;
    logic.update();
    await tester.pump();
    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加至本地收藏'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'real menu two books two folders completes selection; cancel preserves it',
      (tester) async {
    final logic = await launch(tester);
    await openBatch(tester, logic);
    await tester.enterText(find.byType(TextField), 'Staged');
    await tester.tap(find.text('新建并选中'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(logic.selecting, isTrue);
    expect(logic.selectedNum, 2);
    expect(manager.folderNames, isNot(contains('Staged')));
    await openBatch(tester, logic);
    await tester.tap(find.text('A'));
    await tester.tap(find.text('B'));
    await tester.tap(find.text('添加到所选收藏夹'));
    await tester.pumpAndSettle();
    expect(logic.selecting, isFalse);
    expect(logic.selectedNum, 0);
    expect(logic.selected, everyElement(false));
    expect(find.byType(DownloadPage), findsOneWidget);
    expect(manager.getAllComics('A'), hasLength(2));
    expect(manager.getAllComics('B'), hasLength(2));
    expect(find.text('已添加 2 本到本地收藏（2 个收藏夹）').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets(
      'real menu partial failure keeps selection; retry and all-existing finish it',
      (tester) async {
    final logic = await launch(tester);
    final db = sqlite3.open('${root.path}/local_favorite.db');
    db.execute(
        "CREATE TRIGGER reject BEFORE INSERT ON B WHEN NEW.target = '123' BEGIN SELECT RAISE(ABORT,'fixture failure'); END;");
    await openBatch(tester, logic);
    await tester.tap(find.text('A'));
    await tester.tap(find.text('B'));
    await tester.tap(find.text('添加到所选收藏夹'));
    await tester.pumpAndSettle();
    expect(logic.selecting, isTrue);
    expect(logic.selectedNum, 2);
    expect(logic.selected, everyElement(true));
    expect(find.textContaining('1 项失败').hitTestable(), findsOneWidget);
    expect(manager.getAllComics('A'), hasLength(2));
    expect(manager.getAllComics('B'), hasLength(1));
    db.execute('DROP TRIGGER reject');
    db.dispose();
    await openBatch(tester, logic);
    await tester.tap(find.text('A'));
    await tester.tap(find.text('B'));
    await tester.tap(find.text('添加到所选收藏夹'));
    await tester.pumpAndSettle();
    expect(logic.selecting, isFalse);
    expect(manager.getAllComics('B'), hasLength(2));
    await openBatch(tester, logic);
    await tester.tap(find.text('A'));
    await tester.tap(find.text('B'));
    await tester.tap(find.text('添加到所选收藏夹'));
    await tester.pumpAndSettle();
    expect(logic.selecting, isFalse);
    expect(logic.selectedNum, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets(
      'selection replaced while dialog is open does not clear a new session',
      (tester) async {
    final logic = await launch(tester);
    await openBatch(tester, logic);
    logic.selected = List.filled(logic.comics.length, false);
    logic.selected[0] = true;
    logic.selectedNum = 1;
    await tester.tap(find.text('A'));
    await tester.tap(find.text('添加到所选收藏夹'));
    await tester.pumpAndSettle();
    expect(manager.getAllComics('A'), hasLength(2));
    expect(logic.selecting, isTrue);
    expect(logic.selectedNum, 1);
    expect(logic.selected.where((s) => s), hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
      'destroying page while dialog awaits does not update old logic or pop new root',
      (tester) async {
    final logic = await launch(tester);
    await openBatch(tester, logic);
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Replacement'))));
    await tester.pumpAndSettle();
    expect(find.text('Replacement'), findsOneWidget);
    expect(logic.selecting, isTrue);
    expect(logic.selectedNum, 2);
    expect(tester.takeException(), isNull);
  });
}
