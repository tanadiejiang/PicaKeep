import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/archive/archive_models.dart';
import 'package:picakeep/foundation/archive/archive_registry.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/foundation/pixiv_artifact.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

/// 18-31 号计划 A 部分：**自定义源（Pixiv / Komiic）的已下载条目点进去打不开**。
///
/// 根因是从 `OnlineDownloadManager.loadCompletedDownloads()` 取回的条目里，
/// JM / picacg / ehentai / nhentai **各自都有** `Online*` 包装类，只有自定义源
/// 没有 —— 于是它落到 `CustomDownloadedItem.createReadingPage`（老体系
/// `LocalReadingData`，没有目录路径）→ `loadEp` 退化成 `List.filled(1, "")`。
///
/// 这一组盯两件事：
/// 1. 新包装类 `OnlineDownloadedCustom` 的存在性与字段搬运（含 `canDelete`、
///    本地封面这类"接错就静默出问题"的部分）；
/// 2. `createReadingPage` 出来的阅读数据**带正确的绝对路径**，并且对
///    **三种产物形态**（目录 / 压缩包 / 单图，28 号引入）都能列页读页 ——
///    不是只断言"路径字段等于某字符串"。
class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final Directory root;

  Future<String> directory(String name) async =>
      (await Directory(p.join(root.path, name)).create(recursive: true)).path;

  @override
  Future<String?> getApplicationCachePath() => directory('cache');

  @override
  Future<String?> getApplicationSupportPath() => directory('support');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  open.overrideFor(
    OperatingSystem.windows,
    () => DynamicLibrary.open(
      p.join(Directory.current.path, 'windows', 'sqlite3.dll'),
    ),
  );

  late Directory workspace;
  late Directory root;
  late PathProviderPlatform savedPaths;
  late List<String> savedSettings;

  setUpAll(() async {
    ArchiveRegistry.initDefaults();
    savedPaths = PathProviderPlatform.instance;
    savedSettings = List.of(appdata.settings);
    workspace = await Directory.systemTemp.createTemp('pk_online_custom_');
    PathProviderPlatform.instance = _Paths(workspace);
    await App.init(dataPathOverride: p.join(workspace.path, 'data'));
  });

  setUp(() async {
    root = await Directory(
      p.join(workspace.path, 'fixture_${DateTime.now().microsecondsSinceEpoch}'),
    ).create(recursive: true);
  });

  tearDownAll(() async {
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    PathProviderPlatform.instance = savedPaths;
    try {
      await workspace.delete(recursive: true);
    } catch (_) {}
  });

  /// 阅读页的构造有全局状态（`StateController`），且 `ComicReadingPage`
  /// 构造时会注册 logic —— 取完数据必须清掉，否则会污染同一进程里的后续用例。
  T readDataOf<T>(Widget page) {
    final data = (page as ComicReadingPage).readingData;
    expect(data, isA<T>());
    return data as T;
  }

  void releaseReadingPage() {
    final logic = StateController.findOrNull<ComicReadingPageLogic>();
    if (logic != null) {
      logic.pageController.dispose();
      StateController.remove<ComicReadingPageLogic>();
    }
  }

  CustomDownloadedItem pixivItem({
    String id = 'pixiv82074457',
    String name = '電瘋扇',
    Map<String, String>? chapters,
    List<int> downloadedEps = const <int>[0],
  }) {
    return CustomDownloadedItem(
      id: id,
      name: name,
      subTitle: 'シグニット',
      tags: const <String>['tag'],
      sourceKey: 'pixiv',
      sourceName: 'Pixiv',
      // 与下载器一致：`cover` 存的是**网络 URL**（i.pximg.net 有防盗链），
      // 所以本地封面绝不能指望这个字段。
      cover: 'https://i.pximg.net/c/240x480/img/cover.jpg',
      comicId: id.replaceFirst('pixiv', ''),
      downloadedEps: downloadedEps,
      chapters: chapters,
      comicSize: 3.44,
      width: 1200,
      height: 1600,
      pageCount: 2,
      authorId: '12345',
    );
  }

  OnlineDownloadedCustom wrap(CustomDownloadedItem item, String directoryName) {
    return OnlineDownloadedCustom.fromCustomDownloadedItem(
      item,
      rootPath: root.path,
      directoryName: directoryName,
    );
  }

  /// 目录形态：封面与页图**平铺在同一层**（Pixiv 目录产物的真实布局）。
  Future<Directory> flatWork(String dirName, {List<int> pages = const [1, 2]}) async {
    final dir = Directory(p.join(root.path, dirName));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'cover.jpg')).writeAsBytes(<int>[0, 0, 0]);
    for (final page in pages) {
      await File(p.join(dir.path, '$page.jpg')).writeAsBytes(<int>[page]);
    }
    return dir;
  }

  List<String> namesOf(List<String> paths) =>
      paths.map((path) => p.basename(path)).toList();

  group('OnlineDownloadedCustom · 字段搬运与同类契约', () {
    test('携带 rootPath/directoryName，并与其它 Online* 类同构', () async {
      final item = pixivItem();
      final wrapped = wrap(item, '電瘋扇_p3');

      expect(wrapped.rootPath, root.path);
      expect(wrapped.directoryName, '電瘋扇_p3');
      expect(
        wrapped.rootDirectoryPath,
        p.join(root.path, '電瘋扇_p3'),
      );
      // fileSystemPath 与其它 Online* 类一致地指向作品绝对路径：
      // 列表长按"路径"、详情页定位都靠它。
      expect(wrapped.fileSystemPath, wrapped.rootDirectoryPath);
      expect(wrapped.directory, '電瘋扇_p3');
      expect(wrapped.time, item.time);
      // 元数据必须原样带过来，否则列表的源标签/大小/宽高会集体变空。
      expect(wrapped.sourceKey, 'pixiv');
      expect(wrapped.sourceDisplayName, 'Pixiv');
      expect(wrapped.comicId, '82074457');
      expect(wrapped.comicSize, 3.44);
      expect(wrapped.width, 1200);
      expect(wrapped.height, 1600);
      expect(wrapped.pageCount, 2);
      expect(wrapped.authorId, '12345');
      expect(wrapped.tags, item.tags);
    });

    test('canDelete 为 false（与其余 Online* 类一致，删除链路不分叉）', () {
      final wrapped = wrap(pixivItem(), 'work');
      expect(wrapped.canDelete, isFalse);
    });

    test('本地封面走作品目录里的 cover.*，而不是 cover 字段的网络 URL', () async {
      final dir = await flatWork('with-cover');
      final wrapped = wrap(pixivItem(), p.basename(dir.path));

      expect(wrapped.localCoverPath, p.join(dir.path, 'cover.jpg'));
    });

    test('本地没有封面文件时回退父类行为（不会凭空造出路径）', () async {
      final dir = Directory(p.join(root.path, 'no-cover'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, '1.jpg')).writeAsBytes(<int>[1]);
      final wrapped = wrap(pixivItem(), p.basename(dir.path));

      expect(wrapped.localCoverPath, isNull);
    });

    test('Pixiv 无章节：eps/hasEp 与老入口逐字一致（不额外改阅读器语义）', () {
      final wrapped = wrap(pixivItem(), 'work');
      expect(wrapped.eps, <String>['EP 1']);
    });

    test('Komiic 有章节：章节名原样保留', () {
      final komiic = CustomDownloadedItem(
        id: 'komiic1234',
        name: 'Komiic Work',
        subTitle: 'author',
        tags: const <String>[],
        sourceKey: 'Komiic',
        sourceName: 'Komiic',
        cover: 'https://komiic.com/cover.jpg',
        comicId: '1234',
        chapters: const <String, String>{'1': '第1话', '2': '第2话'},
        downloadedEps: const <int>[0, 1],
      );
      final wrapped = wrap(komiic, 'komiic-work');

      expect(wrapped.eps, <String>['第1话', '第2话']);
      expect(wrapped.downloadedEps, <int>[0, 1]);
    });
  });

  group('OnlineDownloadedCustom · createReadingPage 带正确的绝对路径', () {
    test('返回的 ReadingData 是带 directoryPath 的本地路径阅读数据', () {
      final wrapped = wrap(pixivItem(), 'work');
      try {
        final data = readDataOf<LocalPathReadingData>(
          wrapped.createReadingPage(ep: 1, page: 1),
        );
        // 这条断言就是本次缺陷的**判据本身**：老实现拿到的是 `LocalReadingData`
        // （没有 directoryPath，`loadEp` 只能问老 DownloadManager 要章节长度，
        // 而这条下载根本不在那套体系里）。
        expect(data.directoryPath, wrapped.rootDirectoryPath);
        expect(data.id, wrapped.id);
        expect(data.downloadId, wrapped.id);
        expect(data.sourceKey, 'pixiv');
      } finally {
        releaseReadingPage();
      }
    });

    test('目录形态：按页序列出页图，且封面不会被当成第 1 页', () async {
      final dir = await flatWork('flat', pages: <int>[1, 2, 10]);
      final wrapped = wrap(pixivItem(), p.basename(dir.path));
      try {
        final data = readDataOf<LocalPathReadingData>(
          wrapped.createReadingPage(ep: 1, page: 1),
        );
        final pages = await data.loadEp(1);

        // 自然序（10 不能排到 2 前面）+ 剔除 cover.jpg。
        // 剔除封面这条是"只要路径传对就行"最容易漏掉的一半：把根目录整段丢给
        // 阅读器而不剔封面，用户看到的会是"封面当第一页、整本后移一页"。
        expect(namesOf(pages), <String>['1.jpg', '2.jpg', '10.jpg']);
        expect(await data.loadImage(1, 0, pages.first).first, <int>[1]);
      } finally {
        releaseReadingPage();
      }
    });

    test('压缩包形态：按页序列出包内页，不混入封面条目', () async {
      final staging = await flatWork('zip-src', pages: <int>[1, 2]);
      final zip = File(p.join(root.path, '電瘋扇_p2.zip'));
      await packagePixivDirectoryToStoreZip(sourceDir: staging, target: zip);
      await staging.delete(recursive: true);

      final wrapped = wrap(pixivItem(), p.basename(zip.path));
      try {
        final data = readDataOf<LocalPathReadingData>(
          wrapped.createReadingPage(ep: 1, page: 1),
        );
        final pages = await data.loadEp(1);

        expect(pages, hasLength(2));
        for (final uri in pages) {
          expect(isArchiveUri(uri), isTrue);
          expect(parseArchiveUri(uri)!.archivePath, zip.path);
        }
        expect(
          pages
              .map((uri) => parseArchiveUri(uri)!.entryPath)
              .toList(growable: false),
          <String>['1.jpg', '2.jpg'],
        );
        expect(await data.loadImage(1, 0, pages.first).first, <int>[1]);
      } finally {
        releaseReadingPage();
      }
    });

    test('单图形态：一个作品就是一个图片文件，列页就是它本身', () async {
      final file = File(p.join(root.path, '電瘋扇_p1.jpg'));
      await file.writeAsBytes(<int>[7]);

      final wrapped = wrap(pixivItem(), p.basename(file.path));
      try {
        final data = readDataOf<LocalPathReadingData>(
          wrapped.createReadingPage(ep: 1, page: 1),
        );
        final pages = await data.loadEp(1);

        expect(pages, <String>[file.path]);
        expect(await data.loadImage(1, 0, pages.single).first, <int>[7]);
      } finally {
        releaseReadingPage();
      }
    });

    test('Komiic 多章节：ep 取到对应章节目录，超界为空', () async {
      for (final ep in <int>[1, 2]) {
        final dir = Directory(p.join(root.path, 'komiic', '$ep'));
        await dir.create(recursive: true);
        await File(p.join(dir.path, '1.jpg')).writeAsBytes(<int>[ep]);
      }
      final item = CustomDownloadedItem(
        id: 'komiic1234',
        name: 'Komiic Work',
        subTitle: 'author',
        tags: const <String>[],
        sourceKey: 'Komiic',
        sourceName: 'Komiic',
        cover: '',
        comicId: '1234',
        chapters: const <String, String>{'1': '第1话', '2': '第2话'},
        downloadedEps: const <int>[0, 1],
      );
      final wrapped = wrap(item, 'komiic');
      try {
        final data = readDataOf<LocalPathReadingData>(
          wrapped.createReadingPage(ep: 1, page: 1),
        );

        expect(await data.loadImage(1, 0, (await data.loadEp(1)).single).first,
            <int>[1]);
        expect(await data.loadImage(2, 0, (await data.loadEp(2)).single).first,
            <int>[2]);
        expect(await data.loadEp(9), isEmpty);
      } finally {
        releaseReadingPage();
      }
    });
  });

  group('回归 · 其它包装类与老入口不受影响', () {
    test('CustomDownloadedItem.createReadingPage 仍是老体系（未被顺手改掉）', () {
      final item = pixivItem();
      try {
        final data = readDataOf<LocalReadingData>(item.createReadingPage());
        expect(data, isNot(isA<LocalPathReadingData>()));
        expect(data.hasEp, isTrue);
        expect(data.eps, <String, String>{'1': 'EP 1'});
      } finally {
        releaseReadingPage();
      }
      // 老类仍然允许删除（删除链路的行为不能被新包装类顺带改掉）。
      expect(item.canDelete, isTrue);
    });

    test('收藏类型：新旧两条链路得出同一个值（抽函数时不许悄悄改口径）', () {
      // `customDownloadedFavoriteType` 是从 `CustomDownloadedItem.createReadingPage`
      // 里抽出来的，目的只是让新包装类共用同一份口径；这里把"抽出来之后两边
      // 仍然一致"钉住，否则会出现"同一个作品在两条链路上收藏态不同"。
      final komiic = CustomDownloadedItem(
        id: 'komiic1234',
        name: 'Komiic Work',
        subTitle: '',
        tags: const <String>[],
        sourceKey: 'Komiic',
        sourceName: 'Komiic',
        cover: '',
        comicId: '1234',
        chapters: const <String, String>{'1': '第1话'},
        downloadedEps: const <int>[0],
      );
      try {
        final old =
            (komiic.createReadingPage() as ComicReadingPage).readingData;
        expect(old.favoriteType, FavoriteType.komiic);
        releaseReadingPage();

        final wrapped = wrap(komiic, 'komiic');
        final fresh =
            (wrapped.createReadingPage() as ComicReadingPage).readingData;
        expect(fresh.favoriteType, old.favoriteType);
      } finally {
        releaseReadingPage();
      }

      // 其余自定义源沿用 `FavoriteType(0)`（老行为，不动）。
      expect(customDownloadedFavoriteType('pixiv'), const FavoriteType(0));
      expect(customDownloadedFavoriteType('copy_manga'), FavoriteType.copyManga);
    });

    test('其余 Online* 包装类的 canDelete 与阅读数据形态不变', () {
      final picacg = OnlineDownloadedComic.fromDownloadedComic(
        DownloadedComic(
          comicId: 'abcdefabcdefabcdefabcdef',
          title: 'Pica',
          author: 'author',
          chapters: const <String>['EP 1'],
          downloadedChapters: const <int>[0],
        ),
        rootPath: root.path,
        directoryName: 'pica',
      );
      final jm = OnlineDownloadedJmComic.fromDownloadedJmComic(
        DownloadedJmComic(
          comicId: '1228705',
          name: 'JM',
          downloadedChapters: const <int>[0],
        ),
        rootPath: root.path,
        directoryName: 'jm1228705',
      );
      final eh = OnlineDownloadedGallery.fromDownloadedGallery(
        DownloadedGallery(
          galleryTitle: 'EH',
          link: 'https://e-hentai.org/g/220980/abc123def/',
        ),
        rootPath: root.path,
        directoryName: '220980-abc123def',
      );
      final nh = OnlineDownloadedNhentai.fromNhentaiDownloadedComic(
        NhentaiDownloadedComic(comicID: '123456', title: 'NH'),
        rootPath: root.path,
        directoryName: '123456',
      );

      for (final item in <DownloadedItem>[picacg, jm, eh, nh]) {
        expect(item.canDelete, isFalse);
        expect(item.fileSystemPath, isNotEmpty);
      }

      try {
        for (final item in <DownloadedItem>[picacg, jm, eh, nh]) {
          final data =
              (item.createReadingPage() as ComicReadingPage).readingData;
          expect(data, isA<OnlineLocalReadingData>());
        }
      } finally {
        // 四个页面各注册过一次 logic，逐个清掉。
        for (var i = 0; i < 4; i++) {
          releaseReadingPage();
        }
      }
    });
  });

  group('接线 · loadCompletedDownloads 真的会包装自定义源条目', () {
    test('Pixiv 的 zip 产物：从 db 行一路走到能列页读页', () async {
      // 这一条是"这次到底修没修好"的判据：不再手工 new 包装类，而是把一条
      // **真实的 download.db 记录**放进下载根，走 `loadCompletedDownloads()`
      // —— 用户点开条目时拿到的就是这条路径上的对象。
      final staging = await flatWork('wiring-src', pages: <int>[1, 2]);
      final zip = File(p.join(root.path, '電瘋扇_p2.zip'));
      await packagePixivDirectoryToStoreZip(sourceDir: staging, target: zip);
      await staging.delete(recursive: true);

      final item = pixivItem(name: '電瘋扇');
      final db = sqlite3.open(p.join(root.path, 'download.db'));
      try {
        db.execute('''
          create table download(
            id text primary key,
            title text,
            subtitle text,
            time int,
            directory text,
            size int,
            json text
          )
        ''');
        db.execute('insert into download values (?,?,?,?,?,?,?)', <Object?>[
          item.id,
          item.name,
          item.subTitle,
          1710000000000,
          p.basename(zip.path),
          item.comicSize,
          jsonEncode(item.toJson()),
        ]);
      } finally {
        db.dispose();
      }

      final previousRoot = appdata.settings[22];
      final previousPixivRoot = appdata.settings[152];
      appdata.settings[22] = root.path;
      appdata.settings[152] = '';
      try {
        final items =
            await OnlineDownloadManager.instance.loadCompletedDownloads();

        final wrapped = items.single;
        expect(wrapped, isA<OnlineDownloadedCustom>());
        expect(wrapped.fileSystemPath, zip.path);
        expect(wrapped.name, '電瘋扇');
        expect(wrapped.sourceDisplayName, 'Pixiv');

        final data = readDataOf<LocalPathReadingData>(
          wrapped.createReadingPage(ep: 1, page: 1),
        );
        try {
          final pages = await data.loadEp(1);
          expect(pages, hasLength(2));
          expect(await data.loadImage(1, 0, pages.first).first, <int>[1]);
        } finally {
          releaseReadingPage();
        }
      } finally {
        appdata.settings[22] = previousRoot;
        appdata.settings[152] = previousPixivRoot;
      }
    });
  });
}
