import 'dart:collection';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/pages/online_comic/local_favorite_actions.dart';
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

FavoriteItem item(String id,
        {FavoriteType type = const FavoriteType(2), String name = 'Fixture'}) =>
    FavoriteItem(
        target: id,
        name: name,
        coverPath: '',
        author: 'Author',
        type: type,
        tags: []);

class _FailingTags extends ListBase<String> {
  @override
  int get length => 0;
  @override
  set length(int value) {}
  @override
  String operator [](int index) => throw RangeError.index(index, this);
  @override
  void operator []=(int index, String value) =>
      throw RangeError.index(index, this);
  @override
  String join([String separator = '']) =>
      throw StateError('fixture metadata failure');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
      OperatingSystem.windows,
      () =>
          DynamicLibrary.open('${Directory.current.path}/windows/sqlite3.dll'));
  final manager = LocalFavoritesManager();
  final savedPaths = PathProviderPlatform.instance;
  final savedMode = managedDataSourceMode;
  late Directory workspace;
  late Directory root;
  var serial = 0;
  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('pk04_batch_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
  });
  setUp(() async {
    root = await Directory('${workspace.path}/${serial++}').create();
    setManagedDataRootOverride(root.path);
    await manager.init();
  });
  tearDown(manager.dispose);
  tearDownAll(() async {
    setManagedDataRootOverride(null);
    setManagedDataSourceMode(savedMode);
    PathProviderPlatform.instance = savedPaths;
    await workspace.delete(recursive: true);
  });

  test(
      'two comics/two folders deduplicate inputs, preserve metadata and emit once',
      () async {
    manager.createFolder('A');
    manager.createFolder('B');
    await Future<void>.delayed(Duration.zero);
    var events = 0;
    final subscription = manager.allFoldersStream.listen((_) => events++);
    final result = await manager.addComicsToFolders(['A', 'B', 'A'],
        [item('123'), item('123'), item('123', type: FavoriteType.nhentai)]);
    await Future<void>.delayed(Duration.zero);
    expect(result.addedRelations, 4);
    expect(result.addedComics, 2);
    expect(result.completedComics, 2);
    expect(result.allCompleted, isTrue);
    expect(events, 1);
    final repeated = await manager.addComicsToFolders([
      'A',
      'B'
    ], [
      item('123', name: 'Overwrite'),
      item('123', type: FavoriteType.nhentai)
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(repeated.alreadyPresentRelations, 4);
    expect(repeated.allCompleted, isTrue);
    expect(events, 1);
    expect(
        manager.getAllComics('A').map((c) => c.name), everyElement('Fixture'));
    await subscription.cancel();
  });

  test('partial SQL failure preserves successes and retry is idempotent',
      () async {
    manager.createFolder('A');
    manager.createFolder('B');
    final db = sqlite3.open('${root.path}/local_favorite.db');
    db.execute(
        'CREATE TRIGGER reject BEFORE INSERT ON "B" WHEN NEW.target = \'2\' BEGIN SELECT RAISE(ABORT, \'fixture failure\'); END;');
    final result =
        await manager.addComicsToFolders(['A', 'B'], [item('1'), item('2')]);
    expect(result.addedRelations, 3);
    expect(result.failedRelations, 1);
    expect(result.addedComics, 2);
    expect(result.completedComics, 1);
    expect(result.allCompleted, isFalse);
    db.execute('DROP TRIGGER reject');
    db.dispose();
    final retry =
        await manager.addComicsToFolders(['A', 'B'], [item('1'), item('2')]);
    expect(retry.addedRelations, 1);
    expect(retry.alreadyPresentRelations, 3);
    expect(retry.allCompleted, isTrue);
  });

  test(
      'writes use actual primary/secondary folder routing, not merged existence',
      () async {
    final secondary = await Directory('${root.path}/secondary').create();
    await manager.init(dataRoots: [secondary.path]);
    manager.createFolder('Shared');
    manager.createFolder('Original');
    manager.addComic('Shared', item('123'));
    await manager.init(dataRoots: [root.path]);
    manager.createFolder('Shared');
    await manager.init(dataRoots: [root.path, secondary.path]);
    expect(manager.comicExists('Shared', '123', 2), isTrue);
    final result =
        await manager.addComicsToFolders(['Shared', 'Original'], [item('123')]);
    expect(result.addedRelations, 2);
    for (final pair in [(root.path, 'Shared'), (secondary.path, 'Original')]) {
      final db = sqlite3.open('${pair.$1}/local_favorite.db');
      expect(db.select('SELECT * FROM "${pair.$2}"'), hasLength(1));
      db.dispose();
    }
  });

  test('re-init during a yield fails remainder and never writes into new store',
      () async {
    manager.createFolder('A');
    final next = await Directory('${root.path}/next').create();
    Future<void>? switchStore;
    final result = await manager
        .addComicsToFolders(['A'], List.generate(100, (i) => item('$i')),
            onProgress: (done, total) {
      if (done == 32) switchStore = manager.init(dataRoots: [next.path]);
    });
    await switchStore;
    expect(result.addedRelations, 32);
    expect(result.failedRelations, 68);
    expect(manager.folderNames, isEmpty);
    final old = sqlite3.open('${root.path}/local_favorite.db');
    expect(old.select('SELECT * FROM A'), hasLength(32));
    old.dispose();
  });

  Future<void> launch(WidgetTester tester,
      {List<FavoriteItem>? items,
      void Function(LocalFavoriteBatchResult?)? result}) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      onPressed: () async {
                        result?.call(await showAddToLocalFavoriteFolders(
                            context, items ?? [item('1'), item('2')]));
                      },
                      child: const Text('Open'),
                    )))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('cancel staged folder creates nothing; zero targets shows error',
      (tester) async {
    LocalFavoriteBatchResult? result;
    await launch(tester, result: (r) => result = r);
    await tester.tap(find.text('添加到所选收藏夹'));
    await tester.pumpAndSettle();
    expect(find.text('请至少选择一个收藏夹'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Staged');
    await tester.tap(find.text('新建并选中'));
    await tester.pumpAndSettle();
    expect(manager.folderNames, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(manager.folderNames, isEmpty);
  });

  testWidgets(
      'multi-folder submit creates staged folder and returns real counts',
      (tester) async {
    manager.createFolder('A');
    LocalFavoriteBatchResult? result;
    await launch(tester, result: (r) => result = r);
    await tester.tap(find.text('A'));
    await tester.enterText(find.byType(TextField), 'B');
    await tester.tap(find.text('新建并选中'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加到所选收藏夹'));
    await tester.pumpAndSettle();
    expect(result?.addedRelations, 4);
    expect(result?.addedComics, 2);
    expect(result?.createdFolders, ['B']);
    expect(manager.getAllComics('A'), hasLength(2));
    expect(manager.getAllComics('B'), hasLength(2));
  });

  testWidgets(
      'SQLite case conflict reports failed relations while valid folder succeeds',
      (tester) async {
    manager.createFolder('A');
    LocalFavoriteBatchResult? result;
    await launch(tester, result: (r) => result = r);
    await tester.tap(find.text('A'));
    await tester.enterText(find.byType(TextField), 'a');
    await tester.tap(find.text('新建并选中'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加到所选收藏夹'));
    await tester.pumpAndSettle();
    expect(result?.addedRelations, 2);
    expect(result?.failedRelations, 2);
    expect(result?.folderCreationFailures.keys, ['a']);
    expect(result?.allCompleted, isFalse);
  });

  testWidgets(
      'new single folder survives insert failure without a success Snackbar',
      (tester) async {
    final broken = FavoriteItem(
        target: '123',
        name: 'Broken',
        coverPath: '',
        author: '',
        type: FavoriteType.jm,
        tags: _FailingTags());
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () =>
                        showLocalFavoriteFoldersWithFeedback(context, broken),
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Empty');
    await tester.tap(find.text('新建并选中'));
    await tester.pumpAndSettle();
    expect(find.text('待新建'), findsOneWidget);
    expect(manager.folderNames, isEmpty);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(manager.folderNames, ['Empty']);
    expect(manager.getAllComics('Empty'), isEmpty);
    expect(find.textContaining('空夹已保留'), findsOneWidget);
  });

  testWidgets(
      'partial merged-store removal keeps actual checkbox and reports error',
      (tester) async {
    final secondary = await tester
        .runAsync(() => Directory('${root.path}/secondary').create());
    await tester.runAsync(() async {
      await manager.init(dataRoots: [secondary!.path]);
      manager.createFolder('A');
      manager.addComic('A', item('123'));
      await manager.init(dataRoots: [root.path]);
      manager.createFolder('A');
      manager.addComic('A', item('123'));
      await manager.init(dataRoots: [root.path, secondary.path]);
    });
    final db = sqlite3.open('${secondary!.path}/local_favorite.db');
    db.execute(
        "CREATE TRIGGER reject_delete BEFORE DELETE ON A BEGIN SELECT RAISE(ABORT,'fixture delete failure'); END;");
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () =>
                        showLocalFavoriteFolders(context, item('123')),
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    // 取消勾选只进入暂存，主库此时不应发生删除。
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse);
    final primary = sqlite3.open('${root.path}/local_favorite.db');
    expect(primary.select('SELECT * FROM A'), hasLength(1));

    // 提交时删除被副库触发器拒绝：主库已删、副库仍在，且停留在对话框并报错。
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('部分收藏取消失败，请重试'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(primary.select('SELECT * FROM A'), isEmpty);
    primary.dispose();
    expect(db.select('SELECT * FROM A'), hasLength(1));
    db.dispose();
  });

  testWidgets('batch reports created empty folder when all inserts fail',
      (tester) async {
    LocalFavoriteBatchResult? result;
    final broken = FavoriteItem(
        target: '123',
        name: 'Broken',
        coverPath: '',
        author: '',
        type: FavoriteType.jm,
        tags: _FailingTags());
    await launch(tester, items: [broken], result: (r) => result = r);
    await tester.enterText(find.byType(TextField), 'Empty');
    await tester.tap(find.text('新建并选中'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加到所选收藏夹'));
    await tester.pumpAndSettle();
    expect(result?.createdFolders, ['Empty']);
    expect(result?.failedRelations, 1);
    expect(result?.allCompleted, isFalse);
    expect(localFavoriteBatchMessage(result!), contains('空夹已保留'));
    expect(manager.getAllComics('Empty'), isEmpty);
  });

  test('dispose during yield fails remainder safely', () async {
    manager.createFolder('A');
    final result = await manager.addComicsToFolders(
        ['A'], List.generate(65, (i) => item('$i')), onProgress: (done, total) {
      if (done == 32) manager.dispose();
    });
    expect(result.addedRelations, 32);
    expect(result.failedRelations, 33);
  });

  testWidgets(
      'large submission exposes progress and blocks duplicate/close actions',
      (tester) async {
    manager.createFolder('A');
    LocalFavoriteBatchResult? result;
    var returns = 0;
    await launch(tester, items: List.generate(160, (i) => item('$i')),
        result: (r) {
      result = r;
      returns++;
    });
    await tester.tap(find.text('A'));
    final button = find.widgetWithText(FilledButton, '添加到所选收藏夹');
    final submit = tester.widget<FilledButton>(button).onPressed!;
    submit();
    submit();
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final pops = tester.widgetList<PopScope>(find.byType(PopScope));
    expect(pops.any((p) => !p.canPop), isTrue);
    await tester.binding.handlePopRoute();
    expect(result, isNull);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.pumpAndSettle();
    expect(result?.addedRelations, 160);
    expect(returns, 1);
    expect(manager.getAllComics('A'), hasLength(160));
  });

  testWidgets('320px large text long folders keyboard keeps actions reachable',
      (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (var i = 0; i < 20; i++) {
      manager.createFolder('Long folder name repeated repeated $i');
    }
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!),
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () =>
                        showAddToLocalFavoriteFolders(context, [item('1')]),
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byType(TextField));
    await tester.tap(find.byType(TextField));
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('取消').hitTestable(), findsOneWidget);
    expect(find.text('添加到所选收藏夹').hitTestable(), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
}
