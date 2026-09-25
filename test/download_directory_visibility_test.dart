import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/archive/archive_models.dart';
import 'package:picakeep/foundation/archive/archive_registry.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/local_trash_store.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/foundation/pixiv_artifact.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

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
          p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
  late Directory workspace;
  late Directory root;
  late List<String> savedSettings;
  late String savedMode;
  late PathProviderPlatform savedPaths;
  final manager = LocalLibraryManager();
  var fixture = 0;

  setUpAll(() async {
    savedSettings = List.of(appdata.settings);
    savedMode = managedDataSourceMode;
    savedPaths = PathProviderPlatform.instance;
    workspace = await Directory.systemTemp.createTemp('picakeep_pk02_');
    PathProviderPlatform.instance = _Paths(workspace);
    await App.init(dataPathOverride: p.join(workspace.path, 'data'));
  });

  setUp(() async {
    root = await Directory(p.join(workspace.path, 'fixture_${fixture++}'))
        .create();
    appdata.settings[22] = root.path;
    appdata.settings[localLibraryShowAllDatabaseRecordsSettingIndex] = '0';
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
    await manager.refresh();
  });

  tearDown(() {
    downloadManager.dispose();
  });

  tearDownAll(() async {
    LocalTrashStore.instance.dispose();
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    setManagedDataSourceMode(savedMode);
    PathProviderPlatform.instance = savedPaths;
    await workspace.delete(recursive: true);
  });

  Future<void> record(String directory,
      {String id = '123-abc', String title = 'Fixture'}) async {
    final db = sqlite3.open(p.join(root.path, 'download.db'));
    try {
      db.execute(
          'CREATE TABLE IF NOT EXISTS download (id TEXT PRIMARY KEY, title TEXT, subtitle TEXT, time INT, directory TEXT, size REAL, json TEXT)');
      db.execute('INSERT INTO download VALUES (?,?,?,?,?,?,?)', [
        id,
        title,
        '',
        1710000000000,
        directory,
        1.0,
        jsonEncode(id.startsWith('jm')
            ? DownloadedJmComic(
                comicId: id.substring(2),
                name: title,
                downloadedChapters: [0],
                epNames: ['First'],
              ).toJson()
            : {
                'galleryTitle': title,
                'link': 'https://e-hentai.org/g/123/abc/',
                'pageCount': 1
              }),
      ]);
    } finally {
      db.dispose();
    }
  }

  Future<String> content(String name) async {
    final dir =
        await Directory(p.join(root.path, name)).create(recursive: true);
    await File(p.join(dir.path, '1.jpg')).writeAsBytes([1, 2, 3]);
    return dir.path;
  }

  List<int> png(int width) =>
      image.encodePng(image.Image(width: width, height: 2));

  Future<String> readableContent(String name,
      {int width = 3, bool chapter = true}) async {
    final dir =
        await Directory(p.join(root.path, name)).create(recursive: true);
    // Read back the actual filesystem name, not merely Directory.path.
    expect(
        root.listSync().whereType<Directory>().map((e) => p.basename(e.path)),
        contains(name));
    final pages =
        chapter ? await Directory(p.join(dir.path, '1')).create() : dir;
    await File(p.join(pages.path, '1.png')).writeAsBytes(png(width));
    await File(p.join(pages.path, '2.png')).writeAsBytes(png(width + 1));
    if (chapter) {
      await File(p.join(dir.path, 'cover.png')).writeAsBytes(png(width));
    }
    return dir.path;
  }

  Future<void> expectReadable(LocalLibraryComicItem item, String directory,
      {int width = 3, bool realPage = false}) async {
    final data = realPage
        ? (item.createReadingPage() as ComicReadingPage).readingData
        : LocalPathReadingData(
            title: item.name,
            id: item.id,
            downloadId: item.id,
            sourceKey: 'jm',
            directoryPath: item.fileSystemPath!,
            hasEp: item.hasMultipleEpisodes,
            comicType: comicTypeForDownloadType(item.type),
            episodeFiles: item.episodeFiles,
            downloadedEpisodeIndexes: item.downloadedEps);
    try {
      final ep = data.hasEp ? 1 : 0;
      final pages = await data.loadEp(ep);
      expect(pages, hasLength(2));
      for (var i = 0; i < pages.length; i++) {
        expect(p.isWithin(directory, pages[i]), isTrue);
        final bytes = await data.loadImage(ep, i, pages[i]).first;
        expect(bytes, png(width + i));
        final decoded = image.decodePng(Uint8List.fromList(bytes));
        expect(decoded?.width, width + i);
        expect(decoded?.height, 2);
      }
    } finally {
      if (realPage) {
        StateController.find<ComicReadingPageLogic>().pageController.dispose();
        StateController.remove<ComicReadingPageLogic>();
      }
    }
  }

  List<Map<String, Object?>> rows() {
    final db = sqlite3.open(p.join(root.path, 'download.db'));
    try {
      return db
          .select('SELECT id, directory, json FROM download ORDER BY id')
          .map((row) => Map<String, Object?>.from(row))
          .toList();
    } finally {
      db.dispose();
    }
  }

  for (final fullScan in [false, true]) {
    group(fullScan ? '完整本地库扫描' : '已下载元数据加载', () {
      Future<List<LocalLibraryComicItem>> load() async {
        if (fullScan) {
          await manager.refresh();
          return manager.getAll();
        }
        return manager.getManagedDownloads();
      }

      for (final name in [
        ' Book',
        'Book ',
        ' Book\nName ',
        '   ',
        'Normal',
        'Two  Spaces',
        'Non\u00a0Breaking'
      ]) {
        test('原值目录可见且图片可解码 ${jsonEncode(name)}', () async {
          final expected = await readableContent(name);
          await record(name, id: 'jm1459920');
          final item = (await load()).single;
          expect(item.originalId, 'jm1459920');
          expect(item.fileSystemPath, expected);
          expect(item.sourceDirectory, name);
          expect(item.localStorageExists, isTrue);
          await expectReadable(item, expected, realPage: name == ' Book');
          final cover = await manager.resolveCoverPathForItem(item);
          expect(cover, isNotNull);
          expect(await File(cover!).readAsBytes(), png(3));
        },
            skip: Platform.isWindows &&
                    (name.endsWith(' ') || name.contains('\n'))
                ? 'Windows cannot faithfully create trailing-space/control-character names'
                : false);
      }

      test('原值优先于 trim、sanitize 和 ID 候选，阅读与封面不串目录', () async {
        const name = ' Book【Name】';
        final expected = await readableContent(name);
        for (final alternative in ['Book【Name】', 'Book_Name_', 'jm1459920']) {
          await readableContent(alternative, width: 8);
        }
        await record(name, id: 'jm1459920');
        final item = (await load()).single;
        expect(item.fileSystemPath, expected);
        await expectReadable(item, expected);
        expect(
            await File((await manager.resolveCoverPathForItem(item))!)
                .readAsBytes(),
            png(3));
      });

      test('原值缺失仍兼容 trim 目录且保留数据库原值', () async {
        final expected = await readableContent('Book', chapter: false);
        await record(' Book');
        final before = rows();
        final item = (await load()).single;
        expect(item.fileSystemPath, expected);
        expect(item.sourceDirectory, ' Book');
        await expectReadable(item, expected);
        expect(rows(), before);
      });

      test('原值缺失仍兼容 trim 后的 sanitize 候选', () async {
        final expected = await readableContent('Book_Name', chapter: false);
        await record(' Book:Name');
        final item = (await load()).single;
        expect(item.fileSystemPath, expected);
        await expectReadable(item, expected);
      });

      test('原值与 trim 双目录保留完整 ID 和路径集合', () async {
        final raw = await readableContent(' Book');
        final trimmed = await readableContent('Book', width: 8);
        await record(' Book', id: 'jm1459920');
        await record('Book', id: 'jm558624');
        final items = await load();
        expect({for (final item in items) item.originalId: item.fileSystemPath},
            {'jm1459920': raw, 'jm558624': trimmed});
        for (final item in items) {
          await expectReadable(item, item.fileSystemPath!,
              width: item.originalId == 'jm1459920' ? 3 : 8);
        }
      });

      for (final sentinel in [false, true]) {
        for (final name in [' Book', 'Book ']) {
          test('v1 缓存自动失效并重新加载 ${jsonEncode(name)} sentinel=$sentinel',
              () async {
            final expected = await readableContent(name);
            final wrong = await readableContent('Book', width: 8);
            await record(name, id: 'jm1459920');
            final cacheRoot = Directory(
                p.join(workspace.path, 'support', 'local_library_cache'));
            await cacheRoot.create(recursive: true);
            final oldKey = 'id::jm1459920::path::${expected.trim()}';
            var hash = 1469598103934665603;
            for (final unit in utf8.encode(oldKey)) {
              hash = ((hash ^ unit) * 1099511628211) & 0x7fffffffffffffff;
            }
            final oldCover = File(p.join(cacheRoot.path,
                'managed_download_covers', '${hash.toRadixString(16)}.png'));
            await oldCover.parent.create(recursive: true);
            await oldCover.writeAsBytes(png(8));
            final cacheFile =
                File(p.join(cacheRoot.path, 'current_download.json'));
            await cacheFile.writeAsString(jsonEncode({
              'version': 1,
              'items': {
                oldKey: {
                  'coverPath': sentinel
                      ? LocalLibraryManager.noCoverSentinel
                      : oldCover.path,
                  'episodeFiles': {
                    '0': [p.join(wrong, '1', '1.png')],
                    '1': [p.join(wrong, '1', '1.png')]
                  }
                }
              }
            }));
            for (var reload = 0; reload < 2; reload++) {
              final item = (await load()).single;
              await expectReadable(item, expected);
              // Persist episode metadata, then preserve it when saving the cover.
              // The next load must consume both newly persisted cache fields.
              if (reload == 0) {
                final metadata =
                    await manager.buildRestoredFileMetadata(expected);
                await manager.persistRestoredFileMetadataCache(
                    sourceDbPath: p.join(root.path, 'download.db'),
                    sourceDbId: 'jm1459920',
                    itemDirectory: expected,
                    metadata: metadata);
              }
              final cover = (await manager.resolveCoverPathForItem(item))!;
              expect(cover, isNot(oldCover.path));
              expect(await File(cover).readAsBytes(), png(3));
              final saved = jsonDecode(await cacheFile.readAsString()) as Map;
              expect(saved['version'], 2);
              expect((saved['items'] as Map).keys,
                  contains('id::jm1459920::path::$expected'));
              expect(
                  saved['items']['id::jm1459920::path::$expected']['coverPath'],
                  cover);
              if (reload == 1) expect(item.localCoverPath, cover);
            }
          },
              skip: Platform.isWindows && name.endsWith(' ')
                  ? 'Requires a filesystem supporting trailing spaces'
                  : false);
        }
      }

      test('旧目录字段失效时找到 ID 目录且不修改数据库', () async {
        final expected = await content('123-abc');
        await record('old-directory');
        final items = await load();
        expect(items, hasLength(1));
        expect(
            p.normalize(items.single.fileSystemPath!), p.normalize(expected));
        expect(items.single.localStorageExists, isTrue);
        final db = sqlite3.open(p.join(root.path, 'download.db'));
        try {
          expect(
              db.select('SELECT directory FROM download').single['directory'],
              'old-directory');
        } finally {
          db.dispose();
        }
      });

      test('尝试清理过非法字符的历史目录名', () async {
        final expected = await content('Book_Name');
        await record('Book:Name');
        final items = await load();
        expect(items, hasLength(1));
        expect(
            p.normalize(items.single.fileSystemPath!), p.normalize(expected));
      });

      test('已有显式目录优先于 ID 目录', () async {
        final expected = await content('explicit');
        await content('123-abc');
        await record('explicit');
        expect(p.normalize((await load()).single.fileSystemPath!),
            p.normalize(expected));
      });

      test('绝对目录不重复拼接下载根目录', () async {
        final expected = await content('absolute');
        await record(expected);
        expect(p.normalize((await load()).single.fileSystemPath!),
            p.normalize(expected));
      });

      test('父目录存在不能证明缺失的嵌套目录存在', () async {
        await content('parent');
        await record('parent/missing');
        expect(await load(), isEmpty);
      });

      test('真实嵌套目录仍可读取', () async {
        final expected = await content('parent/chapter');
        await record('parent/chapter');
        expect(p.normalize((await load()).single.fileSystemPath!),
            p.normalize(expected));
      });

      test('旧字段与 ID 都失效时可回退标题目录', () async {
        final expected = await content('Fixture');
        await record('missing');
        expect(p.normalize((await load()).single.fileSystemPath!),
            p.normalize(expected));
      });

      test('同一真实目录的别名记录只展示一次', () async {
        await content('shared');
        await record('shared');
        await record('shared', id: '124-def');
        expect(await load(), hasLength(1));
      });

      test('回收站继续隐藏，清空后的历史索引不隐藏新下载', () async {
        final expected = await content('123-abc');
        await record('old-directory');
        Future<void> trash(String state) => LocalTrashStore.instance.upsert(
              LocalTrashRecordData(
                id: 'trash_${fixture}_$fullScan',
                state: state,
                itemKind: 'managed_download',
                itemId: 'old-id',
                title: 'Fixture',
                subtitle: '',
                cover: '',
                sourceLabel: '',
                originalPath: expected,
                trashedPath: '',
                deletedAtMillis: 0,
                sizeBytes: 0,
                snapshotJson: '{}',
                sourceDbPath: p.join(root.path, 'download.db'),
                sourceDbId: '123-abc',
                sourceDirectory: 'old-directory',
              ),
            );
        await trash(localTrashStateTrashed);
        expect(await load(), isEmpty);
        await trash(localTrashStatePurged);
        expect(await load(), hasLength(1));
      });

      test('真实缺失记录继续过滤，显示全部时保留占位', () async {
        await record('missing');
        expect(await load(), isEmpty);
        appdata.settings[localLibraryShowAllDatabaseRecordsSettingIndex] = '1';
        final items = await load();
        expect(items, hasLength(1));
        expect(items.single.localStorageExists, isFalse);
      });
    });
  }

  group('DownloadManager 公共读取和补录', () {
    for (final name in ['Book ', ' Book\nName ', '   ']) {
      test('旧读取链路保留特殊目录 ${jsonEncode(name)}', () async {
        await readableContent(name);
        await record(name, id: 'jm1459920');
        await downloadManager.init();
        final before = rows();
        expect(downloadManager.getDirectory('jm1459920'), name);
        expect(downloadManager.getAll().single.directory, name);
        expect(downloadManager.getComicLength('jm1459920'), 2);
        expect(
            await downloadManager.getCover('jm1459920').readAsBytes(), png(3));
        expect(await downloadManager.getImage('jm1459920', 0, 0).readAsBytes(),
            png(3));
        expect(downloadManager.scanDirectoryForComics(), 0);
        expect(await manager.rescan(), 0);
        expect(rows(), before);
      },
          skip: Platform.isWindows
              ? 'Requires a filesystem supporting these names'
              : false);
    }

    test('原值与 trim 双目录均保留且读取各自图片', () async {
      await readableContent(' Book');
      await readableContent('Book', width: 8);
      await record(' Book', id: 'jm1459920');
      await record('Book', id: 'jm558624');
      await downloadManager.init();
      expect(downloadManager.getAll().map((e) => e.id).toSet(),
          {'jm1459920', 'jm558624'});
      for (final pair in [('jm1459920', ' Book', 3), ('jm558624', 'Book', 8)]) {
        expect(downloadManager.getDirectory(pair.$1), pair.$2);
        expect(await downloadManager.getCover(pair.$1).readAsBytes(),
            png(pair.$3));
        expect(downloadManager.getComicLength(pair.$1), 2);
        for (var page = 0; page < 2; page++) {
          expect(await downloadManager.getImage(pair.$1, 0, page).readAsBytes(),
              png(pair.$3 + page));
          expect(await downloadManager.getImage(pair.$1, 1, page).readAsBytes(),
              png(pair.$3 + page));
        }
      }
    });

    test('原值优先于 sanitize，失效时兼容历史 trim/sanitize', () async {
      await readableContent(' Book【Name】');
      await readableContent('Book_Name_', width: 8);
      await record(' Book【Name】', id: 'jm1459920');
      await readableContent('Fallback');
      await record(' Fallback', id: 'jm558624');
      await readableContent('Bad_Name');
      await record('Bad:Name', id: 'jm100');
      await downloadManager.init();
      expect(downloadManager.getDirectory('jm1459920'), ' Book【Name】');
      expect(await downloadManager.getImage('jm1459920', 0, 0).readAsBytes(),
          png(3));
      expect(downloadManager.getDirectory('jm558624'), 'Fallback');
      expect(downloadManager.getDirectory('jm100'), 'Bad_Name');
    });

    for (final legacy in [false, true]) {
      test('${legacy ? '旧管理器' : '本地库'}重扫原值查重且真孤儿可以补录', () async {
        await readableContent(' Book');
        await record(' Book', id: 'jm1459920');
        await downloadManager.init();
        Future<int> rescan() async => legacy
            ? downloadManager.scanDirectoryForComics()
            : await manager.rescan();
        final before = rows();
        expect(await rescan(), 0);
        expect(rows(), before);
        await readableContent('Orphan');
        expect(await rescan(), 1);
        expect(await rescan(), 0);
        final after = rows();
        expect(after, hasLength(2));
        expect(after.singleWhere((row) => row['id'] == 'jm1459920'),
            before.single);
        final orphan = await downloadManager.getComicOrNull('Orphan');
        expect(orphan?.directory, 'Orphan');
        expect(orphan?.eps, ['1']);
      });
    }
  });

  group('Pixiv 产物形态：压缩包 / 单图（settings[154]）', () {
    // 28 号计划：开关打开后，一个作品的产物是**一个文件**，download.db 的
    // `directory` 列里存的就是那个**文件名**（含扩展名）。
    //
    // 这一组盯的是"文件形态的记录会不会从列表里消失"：老的扫描逻辑只把
    // **根下的目录名**当索引用，文件不在其中，记录会被判成"本地已删除"而整条
    // 消失 —— 症状是**下载成功、但任何列表里都看不到**，不报错、最难排查。
    // 同时也把"封面 / 页面 / 字节"这条完整阅读链路走一遍。
    setUpAll(ArchiveRegistry.initDefaults);

    /// 造一个"多图打包"产物：staging 目录 → store zip，staging 随即删掉
    /// （与下载器里"校验通过才删原目录"的顺序一致）。
    Future<String> archiveProduct(
      String baseName, {
      int pages = 3,
      int coverWidth = 9,
    }) async {
      final staging =
          await Directory(p.join(root.path, '$baseName.staging')).create();
      await File(p.join(staging.path, 'cover.png')).writeAsBytes(png(coverWidth));
      for (var i = 1; i <= pages; i++) {
        await File(p.join(staging.path, '$i.png')).writeAsBytes(png(100 + i));
      }
      final zip = File(p.join(root.path, '$baseName.zip'));
      await packagePixivDirectoryToStoreZip(sourceDir: staging, target: zip);
      await staging.delete(recursive: true);
      return zip.path;
    }

    Future<List<LocalLibraryComicItem>> loadFullScan() async {
      await manager.refresh();
      return manager.getAll();
    }

    /// 两条加载路径都要认文件形态：完整扫描（refresh）与"只看已下载元数据"。
    Future<List<List<LocalLibraryComicItem>>> loadBothWays() async => [
          await loadFullScan(),
          await manager.getManagedDownloads(),
        ];

    test('压缩包产物：列表里可见，封面与逐页字节都能读出来', () async {
      final zipPath = await archiveProduct('電瘋扇_シグニット_82074457_p3');
      await record(p.basename(zipPath), id: 'pixiv-82074457');

      for (final items in await loadBothWays()) {
        final item = items.single;
        expect(item.localStorageExists, isTrue);
        expect(item.fileSystemPath, zipPath);

        // 封面走"从包里取 cover 条目"这条路（包内的封面不在磁盘上）
        final cover = await manager.resolveCoverPathForItem(item);
        expect(cover, isNotNull);
        expect(await File(cover!).readAsBytes(), png(9));

        final data = LocalPathReadingData(
          title: item.name,
          id: item.id,
          downloadId: item.id,
          sourceKey: 'pixiv',
          directoryPath: zipPath,
          hasEp: item.hasMultipleEpisodes,
          comicType: ComicType.pixiv,
          episodeFiles: item.episodeFiles,
          downloadedEpisodeIndexes: item.downloadedEps,
        );
        final pages = await data.loadEp(0);
        expect(pages, hasLength(3));
        for (var i = 0; i < pages.length; i++) {
          expect(isArchiveUri(pages[i]), isTrue);
          expect(
            await data.loadImage(0, i, pages[i]).first,
            png(101 + i),
            reason: '第 ${i + 1} 页',
          );
        }
      }
    });

    test('单图产物：列表里可见，封面与页面就是这个文件', () async {
      final file = File(p.join(root.path, '電瘋扇_シグニット_82074457_p1.png'));
      await file.writeAsBytes(png(21));
      await record(p.basename(file.path), id: 'pixiv-single');

      for (final items in await loadBothWays()) {
        final item = items.single;
        expect(item.localStorageExists, isTrue);
        expect(item.fileSystemPath, file.path);

        final cover = await manager.resolveCoverPathForItem(item);
        expect(cover, isNotNull);
        expect(await File(cover!).readAsBytes(), png(21));

        final data = LocalPathReadingData(
          title: item.name,
          id: item.id,
          downloadId: item.id,
          sourceKey: 'pixiv',
          directoryPath: file.path,
          hasEp: item.hasMultipleEpisodes,
          comicType: ComicType.pixiv,
          episodeFiles: item.episodeFiles,
          downloadedEpisodeIndexes: item.downloadedEps,
        );
        final pages = await data.loadEp(0);
        expect(pages, <String>[file.path]);
        expect(await data.loadImage(0, 0, pages.single).first, png(21));
      }
    });

    test('两种形态能在同一个列表里共存（老目录 + 新 zip + 新单图）', () async {
      await readableContent('old-dir', chapter: false);
      await record('old-dir', id: 'e-1');
      final zipPath = await archiveProduct('new-zip');
      await record(p.basename(zipPath), id: 'pixiv-zip');
      final single = File(p.join(root.path, 'new-single.png'));
      await single.writeAsBytes(png(21));
      await record('new-single.png', id: 'pixiv-single');

      final items = await loadFullScan();

      expect(
        items.map((item) => item.originalId).toSet(),
        <String>{'e-1', 'pixiv-zip', 'pixiv-single'},
      );
      expect(items.every((item) => item.localStorageExists), isTrue);
    });

    test('产物文件被删掉后记录不再可见（与现实一致，不做假阳性）', () async {
      final zipPath = await archiveProduct('gone');
      await record(p.basename(zipPath), id: 'pixiv-gone');
      await File(zipPath).delete();

      expect(await loadFullScan(), isEmpty);
    });

    test('压缩包产物：从条目自己的入口（createReadingPage）也能列页读页', () async {
      // 上面那条测的是"手动构造 LocalPathReadingData"；
      // 这一条走**条目自己的入口**（`LocalLibraryComicItem.createReadingPage`
      // → `LocalPathReadingData`），也就是"我/已下载"点进去真正会走的那条路。
      final zipPath = await archiveProduct('entry');
      await record(p.basename(zipPath), id: 'pixiv-entry');
      final item = (await loadFullScan()).single;

      final data = (item.createReadingPage() as ComicReadingPage).readingData;
      try {
        final pages = await data.loadEp(0);
        expect(pages, hasLength(3));
        expect(await data.loadImage(0, 0, pages.first).first, png(101));
      } finally {
        StateController.find<ComicReadingPageLogic>().pageController.dispose();
        StateController.remove<ComicReadingPageLogic>();
      }
    });

    test('「修正已下载文件夹名」不会把文件产物的记录改成不存在的路径', () async {
      // 这个工具是"把旧的纯 ID 文件夹改成标题名"，它按 `Directory(路径)` 判断存在性 ——
      // 文件不是目录，压缩包/单图产物会掉进"源不存在就只改 DB"那条老分支，
      // 记录被指到一个不存在的路径后**永远补不回来**（目录扫描不会补录文件产物）。
      final zipPath = await archiveProduct('fixme');
      final zipName = p.basename(zipPath);
      await record(zipName, id: 'pixiv-fixme');

      final result = await OnlineDownloadManager.instance.fixDirectoryNames();

      expect(result.fixed, 0);
      expect(rows().single['directory'], zipName);
      expect((await loadFullScan()).single.fileSystemPath, zipPath);
    });
  });
}
