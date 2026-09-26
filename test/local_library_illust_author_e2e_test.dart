/// **端到端**：一条真实形态的 Pixiv 下载记录 → 本地库扫描 → 插画卡片底部信息。
///
/// ## 为什么必须有这个文件（33 号用户症状的完整复现）
///
/// 用户真机反馈「已下载的插画貌似没有作者字段，我勾选后也显示不了」。
/// 那条链是：
///
/// ```text
/// download.db 一行
///   → parseDownloadedItemRecordJson        （得到 CustomDownloadedItem）
///   → _metadataAuthorForDownloadedRow      ← **bug 就在这里**
///   → LocalLibraryComicItem.subTitle
///   → buildIllustEntries
///   → illustrateCardInfoSpansFor
/// ```
///
/// 单测 `download_author_resolver_test.dart` 只覆盖链中间那一环，
/// 卡片渲染由 `local_library_illust_card_test.dart` 用手造的条目覆盖 ——
/// **两头都测了，中间"真实 db 行 → 扫描结果"这一跳没人测**，而 bug 恰恰在那里。
/// 所以这里用真实的 `download.db` + 真实目录，走一遍完整链路。
///
/// ## 为什么是普通 `test()` 而不是 `testWidgets()`
///
/// 扫描与页数统计都是**真实文件 IO**。`testWidgets` 跑在 fake-async 时钟里，
/// 真实 IO 的完成时机不可控（实测：带 download.db 的扫描在 `pumpAndSettle` 下
/// 会一直等不到收敛）。这里不需要渲染控件（渲染已由卡片测试覆盖），
/// 用普通 `test()` 就避开了整个问题。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/illust_card_info_config.dart';
import 'package:picakeep/foundation/illust_cover_size.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/privileged_storage_access.dart';
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

/// 真机三条记录里的这一条（`subTitle` = 作者 `電瘋扇`）。
const String _pixivId = 'pixiv79837313';
const String _pixivTitle = '是色兔子peko';
const String _pixivAuthor = '電瘋扇';

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
  /// **每个用例一个全新的下载根路径**。
  ///
  /// 不能所有用例共用 `workspace/root`：`LocalLibraryManager` 按**路径**缓存扫描
  /// 结果，路径不变就会把上一个用例的数据当成本次的（症状是"这条记录明明没写，
  /// 却扫出来了"）。既有测试（`download_directory_visibility_test.dart`）也是这么
  /// 做的（`fixture_N`）。
  var fixture = 0;

  setUpAll(() async {
    savedSettings = List.of(appdata.settings);
    savedMode = managedDataSourceMode;
    savedPaths = PathProviderPlatform.instance;
    workspace = await Directory.systemTemp.createTemp('picakeep_pk33_e2e_');
    PathProviderPlatform.instance = _Paths(workspace);
    await App.init(dataPathOverride: p.join(workspace.path, 'data'));
  });

  setUp(() async {
    root = await Directory(p.join(workspace.path, 'root_${fixture++}')).create();
    appdata.settings[22] = root.path;
    appdata.settings[localLibraryShowAllDatabaseRecordsSettingIndex] = '0';
    appdata.settings[localLibraryAlbumOnlySettingIndex] = '1';
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
  });

  tearDownAll(() async {
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    setManagedDataSourceMode(savedMode);
    PathProviderPlatform.instance = savedPaths;
    try {
      await workspace.delete(recursive: true);
    } catch (_) {}
  });

  /// 造一条**与真机同形**的 Pixiv 记录：`download.db` 一行 + 作品目录。
  ///
  /// [pages] 张页图 + 一张 `cover.jpg`（封面不算页数，见 `countIllustPageImages`）。
  Future<void> writePixivRecord({int pages = 3, String? author}) async {
    const dirName = 'pixiv_fixture';
    final dir = await Directory(p.join(root.path, dirName)).create();
    final png = image.encodePng(image.Image(width: 4, height: 6));
    await File(p.join(dir.path, 'cover.jpg')).writeAsBytes(png);
    for (var i = 1; i <= pages; i++) {
      await File(p.join(dir.path, '$i.jpg')).writeAsBytes(png);
    }
    final db = sqlite3.open(p.join(root.path, 'download.db'));
    try {
      db.execute(
          'CREATE TABLE IF NOT EXISTS download (id TEXT PRIMARY KEY, '
          'title TEXT, subtitle TEXT, time INT, directory TEXT, '
          'size REAL, json TEXT)');
      db.execute('INSERT INTO download VALUES (?,?,?,?,?,?,?)', <Object?>[
        _pixivId,
        _pixivTitle,
        author ?? _pixivAuthor,
        1710000000000,
        dirName,
        1.0,
        jsonEncode(<String, dynamic>{
          'comicSize': 1.0,
          'downloadedEps': <int>[0],
          'chapters': null,
          'id': _pixivId,
          'name': _pixivTitle,
          'subTitle': author ?? _pixivAuthor,
          'tags': <String>[],
          'sourceKey': 'pixiv',
          'sourceName': 'Pixiv',
          'cover': p.join(dir.path, 'cover.jpg'),
          'comicId': '79837313',
          'width': 4,
          'height': 6,
        }),
      ]);
    } finally {
      db.dispose();
    }
  }

  /// 扫一遍本地库。
  ///
  /// **必须先 `refresh()` 再 `getAll()`**：`getAll()` 走 `ensureLoaded()`，
  /// 一旦本进程里已经加载过就直接返回缓存（`local_library_scan.dart:30-35`），
  /// 而这里每个用例都是"先建根、再写记录"，不 refresh 就永远扫不到刚写的数据
  /// （症状是"记录明明在，items 却是空的"）。
  Future<List<LocalLibraryComicItem>> loadItems() async {
    await manager.refresh();
    return manager.getAll();
  }

  /// 扫一遍本地库，拿到那一条插画条目的**卡片底部文本**。
  Future<String> cardInfoText({
    required List<String> fields,
    bool resolvePageCount = false,
  }) async {
    final items = await loadItems();
    final entries = buildIllustEntries(items.whereType<LocalLibraryComicItem>());
    expect(entries, hasLength(1),
        reason: '前置条件：那条 Pixiv 记录应该被认成插画条目');
    var entry = entries.single;
    if (resolvePageCount) {
      final resolved = await resolveIllustEntryInfo(
        entries: <IllustLibraryEntry>[entry],
        // 封面路径在测试里直接给 null（卡片允许没有封面，宽度用 db 里的作品级尺寸）。
        resolveCoverPath: (item) async => null,
        needPageCount: true,
        // 页数用真实目录列举（生产走特权通道，这里等价地走 dart:io）。
        listDirectory: (path) async {
          final dir = Directory(path);
          if (!dir.existsSync()) {
            return const <LocalDirectoryEntry>[];
          }
          return <LocalDirectoryEntry>[
            for (final entity in dir.listSync())
              LocalDirectoryEntry(
                name: p.basename(entity.path),
                path: entity.path,
                isDirectory: entity is Directory,
              ),
          ];
        },
        cache: IllustCoverSizeCache.inMemory(),
      );
      entry = applyIllustResolvedInfo(
        <IllustLibraryEntry>[entry],
        resolved,
      ).single;
    }
    return illustrateCardInfoTextFor(
      entry: entry,
      fields: fields,
      separator: kDefaultIllustCardInfoSeparator,
    );
  }

  group('33 号端到端：真实 db 行 → 扫描 → 卡片作者', () {
    test('扫描出来的 subTitle 就是作者（bug 的落点）', () async {
      await writePixivRecord();
      final items = await loadItems();
      expect(items, hasLength(1));
      final item = items.single;
      expect(item.name, _pixivTitle);
      expect(
        item.subTitle,
        _pixivAuthor,
        reason: '33 号真机症状的根因行：`_metadataAuthorForDownloadedRow` '
            '绕了为 EH/NH 建的解析链，自定义源在那里恒为空，'
            '于是 subTitle 为空 → 卡片侧空值跳过 → 作者不显示',
      );
    });

    test('卡片底部信息（作者 + 页数）两段都在', () async {
      await writePixivRecord(pages: 3);
      expect(
        await cardInfoText(
          fields: <String>['author', 'pages'],
          resolvePageCount: true,
        ),
        '$_pixivAuthor\np3',
        reason: '用户勾了「作者」却看不到 → 这里必须两段都出来：'
            '作者 = subTitle，页数 = p{N} 口径',
      );
    });

    test('单图作品是 `p0`（不是 p1、也不是"1 页"）', () async {
      await writePixivRecord(pages: 1);
      expect(
        await cardInfoText(
          fields: <String>['title', 'pages'],
          resolvePageCount: true,
        ),
        '$_pixivTitle\np0',
      );
    });

    test('subTitle 为空（合法状态）→ 作者段整项跳过，不留尾巴', () async {
      await writePixivRecord(author: '');
      expect(
        await cardInfoText(fields: <String>['title', 'author']),
        _pixivTitle,
        reason: '空的作者不能变成占位文案，也不能在标题后留一个换行',
      );
    });

    test('Komiic 形态（多作者）也直取 subTitle', () async {
      const dirName = 'komiic_fixture';
      await Directory(p.join(root.path, dirName)).create();
      final db = sqlite3.open(p.join(root.path, 'download.db'));
      try {
        db.execute(
            'CREATE TABLE IF NOT EXISTS download (id TEXT PRIMARY KEY, '
            'title TEXT, subtitle TEXT, time INT, directory TEXT, '
            'size REAL, json TEXT)');
        db.execute('INSERT INTO download VALUES (?,?,?,?,?,?,?)', <Object?>[
          'komiic123',
          'Komiic 标题',
          '作者A, 作者B',
          1710000000000,
          dirName,
          1.0,
          jsonEncode(<String, dynamic>{
            'id': 'komiic123',
            'name': 'Komiic 标题',
            'subTitle': '作者A, 作者B',
            'tags': <String>[],
            'sourceKey': 'Komiic',
            'sourceName': 'Komiic',
            'cover': '',
            'comicId': '123',
            'downloadedEps': <int>[0],
          }),
        ]);
      } finally {
        db.dispose();
      }
      final items = await loadItems();
      final item = items.whereType<LocalLibraryComicItem>().single;
      expect(item.subTitle, '作者A, 作者B');
    });
  });

  group('33 号端到端回归：EH / NH 的作者语义一点没变', () {
    /// 造一条 EH 记录：`json` 里只有 uploader 与 group，**没有** artist 标签。
    Future<void> writeEhRecord({bool withArtist = false}) async {
      const dirName = 'eh_fixture';
      await Directory(p.join(root.path, dirName)).create();
      final db = sqlite3.open(p.join(root.path, 'download.db'));
      try {
        db.execute(
            'CREATE TABLE IF NOT EXISTS download (id TEXT PRIMARY KEY, '
            'title TEXT, subtitle TEXT, time INT, directory TEXT, '
            'size REAL, json TEXT)');
        db.execute('INSERT INTO download VALUES (?,?,?,?,?,?,?)', <Object?>[
          '123-abc',
          'EH 标题',
          // 真机上 EH 行的 subtitle 列写的是 `resolveDownloadedAuthors(item)`，
          // 拿不到 artist 时就是空串（不用 uploader 冒充）。
          withArtist ? 'konomi' : '',
          1710000000000,
          dirName,
          1.0,
          jsonEncode(<String, dynamic>{
            'galleryTitle': 'EH 标题',
            'uploader': '8476411',
            'link': 'https://e-hentai.org/g/123/abc/',
            'tagList': <String>[
              if (withArtist) 'artist:konomi',
              'group:きのこのみ',
            ],
          }),
        ]);
      } finally {
        db.dispose();
      }
    }

    test('EH 有 artist 标签 → 作者是 artist（不是 uploader）', () async {
      await writeEhRecord(withArtist: true);
      final items = await loadItems();
      final item = items.whereType<LocalLibraryComicItem>().single;
      expect(item.subTitle, 'konomi');
    });

    test('EH 只有 uploader / group → **空串**（铁律：不拿 uploader 冒充作者）',
        () async {
      await writeEhRecord();
      final items = await loadItems();
      final item = items.whereType<LocalLibraryComicItem>().single;
      expect(
        item.subTitle,
        isEmpty,
        reason: 'EH 的 uploader 是上传者。改动前返回空串，改动后必须还是空串 —— '
            '新加的"自定义源直取 subTitle"分支不能碰到 EH',
      );
    });
  });
}
