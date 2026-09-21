import 'dart:ffi';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/jm_network/jm_models.dart';
import 'package:picakeep/network/nhentai_network/models.dart';
import 'package:picakeep/network/picacg_network/models.dart';
import 'package:picakeep/pages/online_comic/base_online_comic_page.dart';
import 'package:picakeep/pages/online_comic/online_comic_page_logic.dart';
import 'package:picakeep/pages/online_comic/local_favorite_actions.dart';
import 'package:picakeep/pages/online_comic/picacg_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/jm_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/eh_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/nhentai_comic_page_v2.dart';
import 'package:sqlite3/open.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
      OperatingSystem.windows,
      () =>
          DynamicLibrary.open('${Directory.current.path}/windows/sqlite3.dll'));
  late Directory workspace;
  late String oldMode;
  final manager = LocalFavoritesManager();
  final originalPaths = PathProviderPlatform.instance;
  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_pk04_');
    oldMode = managedDataSourceMode;
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
    oldMode = managedDataSourceMode;
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
  });
  setUp(() async {
    final root = await Directory(
            '${workspace.path}/${DateTime.now().microsecondsSinceEpoch}')
        .create();
    setManagedDataRootOverride(root.path);
    await manager.init();
    for (final folder in manager.folderNames) {
      manager.deleteFolder(folder);
    }
  });
  tearDown(() => manager.dispose());
  tearDownAll(() {
    PathProviderPlatform.instance = originalPaths;
    setManagedDataRootOverride(null);
    setManagedDataSourceMode(oldMode);
    // EH singleton owns its cookie DB until the test process exits.
  });

  Future<void> launch<T>(
      WidgetTester tester, BaseOnlineComicPage<T> page, T data) async {
    StateController.put(
        OnlineComicPageLogic<T>(loadData: () async => Res(data)),
        tag: page.tag);
    addTearDown(
        () => StateController.remove<OnlineComicPageLogic<T>>(page.tag));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
      builder: (context) => TextButton(
          onPressed: () => page.onFavorite(context, data),
          child: const Text('打开收藏')),
    ))));
    await tester.tap(find.text('打开收藏'));
    await tester.pumpAndSettle();
    // 收藏面板已改为「网络 / 本地」选项卡形态：先切到「本地」页，
    // 才能进到本地收藏夹的复选框列表（面板底部按钮即原来的「完成」）。
    await tester.tap(find.text('本地'));
    await tester.pumpAndSettle();
  }

  void sourceTest<T>(String name, BaseOnlineComicPage<T> page, T data,
      FavoriteType type, String target, String author) {
    testWidgets('$name 新建收藏夹为暂存，点完成后才写库且重开数据库仍可读', (tester) async {
      await launch(tester, page, data);
      expect(find.text('暂无收藏夹，请先新建'), findsOneWidget);

      // 新建仅进入暂存：此时未建夹、未收藏，也不应有成功提示。
      await tester.enterText(find.byType(TextField), '我的收藏');
      await tester.tap(find.text('新建并选中'));
      await tester.pumpAndSettle();
      expect(find.text('待新建'), findsOneWidget);
      expect(manager.folderNames, isEmpty);
      expect(manager.comicExists('我的收藏', target, type.key), isFalse);
      expect(find.byType(SnackBar), findsNothing);

      // 点「完成」才真正提交。
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(manager.folderNames, ['我的收藏']);
      final saved = manager.getAllComics('我的收藏').single;
      expect(saved.target, target);
      expect(saved.type, type);
      expect(saved.author, author);
      expect(saved.name, 'Fixture');
      expect(find.text('已添加到本地收藏').hitTestable(), findsOneWidget);

      // 重开数据库仍可读。
      await tester.runAsync(() async {
        manager.dispose();
        await manager.init();
      });
      expect(manager.comicExists('我的收藏', target, type.key), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  sourceTest(
      'Pica',
      const PicacgComicPageV2('abc'),
      PicacgComicItem.fromApi(
        json: {'_id': 'abc', 'title': 'Fixture', 'author': 'Author'},
        eps: [],
        recommendation: [],
      ),
      FavoriteType.picacg,
      'abc',
      'Author');
  sourceTest(
      'JM',
      const JmComicPageV2('123'),
      const JmComicInfo(
        id: '123',
        title: 'Fixture',
        authors: ['Author'],
        description: '',
        likes: 0,
        views: 0,
        comments: 0,
        tags: [],
        works: [],
        actors: [],
        series: {},
        epNames: [],
        isFavourite: false,
        isLiked: false,
        coverUrl: '',
        relatedComics: [],
      ),
      FavoriteType.jm,
      '123',
      'Author');
  sourceTest(
      'EH',
      const EhentaiComicPageV2('https://exhentai.org/g/123/abc/'),
      Gallery(
        'Fixture',
        '',
        '',
        'Uploader',
        0,
        null,
        '',
        {
          'artist': ['Author']
        },
        [],
        {},
        false,
        'https://exhentai.org/g/123/abc/',
        '1',
        1,
        [],
        '',
        0,
        null,
      ),
      FavoriteType.ehentai,
      'https://exhentai.org/g/123/abc/',
      'Author');
  sourceTest(
      'NH',
      const NhentaiComicPageV2('123'),
      NhentaiComic(
        '123',
        'Fixture',
        '',
        '',
        {
          'Artists': ['Author']
        },
        false,
        [],
        [],
        '',
      ),
      FavoriteType.nhentai,
      '123',
      'Author');

  testWidgets('多收藏夹取消只影响选中夹，同 ID 不同源互不影响', (tester) async {
    final item = FavoriteItem(
        target: '123',
        name: 'Fixture',
        coverPath: '',
        author: '',
        type: FavoriteType.jm,
        tags: []);
    final other = FavoriteItem(
        target: '123',
        name: 'Other',
        coverPath: '',
        author: '',
        type: FavoriteType.nhentai,
        tags: []);
    manager.createFolder('A');
    manager.createFolder('B');
    manager.addComic('A', item);
    manager.addComic('A', other);
    manager.addComic('B', item);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      onPressed: () => showLocalFavoriteFolders(context, item),
                      child: const Text('打开'),
                    )))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    // 取消勾选 A 只进入暂存，尚未写库。
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(manager.comicExists('A', '123', FavoriteType.jm.key), isTrue);
    expect(manager.comicExists('B', '123', FavoriteType.jm.key), isTrue);

    // 选中已存在的 B，同样只暂存。
    await tester.enterText(find.byType(TextField), 'B');
    await tester.tap(find.text('新建并选中'));
    await tester.pumpAndSettle();

    // 提交后：A 中的本项被移除，同 ID 不同源保留，B 仍保留。
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(manager.comicExists('A', '123', FavoriteType.jm.key), isFalse);
    expect(manager.comicExists('A', '123', FavoriteType.nhentai.key), isTrue);
    expect(manager.comicExists('B', '123', FavoriteType.jm.key), isTrue);
    expect(manager.getAllComics('B'), hasLength(1));
    expect(manager.folderNames, isNot(contains('local')));
  });

  testWidgets('关闭收藏选择不写入；无效新夹名反馈失败且不假成功', (tester) async {
    final item = FavoriteItem(
        target: '123',
        name: 'Fixture',
        coverPath: '',
        author: '',
        type: FavoriteType.jm,
        tags: []);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      onPressed: () => choosePlatformFavorite(context, item),
                      child: const Text('打开'),
                    )))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(manager.folderNames, isEmpty);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地收藏夹'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'bad"folder');
    await tester.tap(find.text('新建并选中'));
    await tester.pumpAndSettle();
    expect(find.text('收藏夹名称不合法'), findsOneWidget);
    expect(manager.folderNames, isEmpty);
  });
}
