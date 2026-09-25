import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/pages/local_comic_detail_page.dart';
import 'package:picakeep/pages/online_comic/komiic_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/pixiv_comic_page_v2.dart';

/// 18-31 号计划 B 部分：**本地详情页缺「在线详情」入口**（Pixiv / Komiic）。
///
/// `_onVisitOnline()` 原来只处理 JM / picacg / nhentai / EH 四种来源，可见性判据
/// 又是 `supportsUpdateInfo(DownloadType)` —— 而自定义源的 `DownloadType` 恒为
/// `other`（见 `CustomDownloadedItem.type`），**类型上根本区分不出 Pixiv/Komiic**。
///
/// 所以这一组盯的是"身份从哪来"：只能来自数据自带的 `sourceKey`（21 号计划
/// 同款结论），并且跳转**统一走源注册的 `ComicSource.comicPageBuilder`**，
/// 不为每个源各写一套。
CustomDownloadedItem _customItem({
  String id = 'pixiv82074457',
  String sourceKey = 'pixiv',
  String sourceName = 'Pixiv',
  String comicId = '82074457',
  String name = '電瘋扇',
}) {
  return CustomDownloadedItem(
    id: id,
    name: name,
    subTitle: 'シグニット',
    tags: const <String>['tag'],
    sourceKey: sourceKey,
    sourceName: sourceName,
    cover: 'https://i.pximg.net/cover.jpg',
    comicId: comicId,
    downloadedEps: const <int>[0],
    chapters: null,
  );
}

LocalLibraryComicItem _localItem({
  required String originalId,
  DownloadType type = DownloadType.other,
  String? sourceRowJson,
}) {
  return LocalLibraryComicItem(
    itemId: 'local_download::current_download::$originalId',
    originalId: originalId,
    type: type,
    name: 'name',
    subTitle: '',
    tags: const <String>[],
    sourceDisplayName: 'Pixiv',
    fileSystemPath: '',
    episodeFiles: const <int, List<String>>{},
    downloadedEps: const <int>[0],
    eps: const <String>['EP 1'],
    localCoverPath: null,
    localStorageExists: true,
    canDelete: false,
    aliases: const <String>[],
    sourceRowJson: sourceRowJson,
  );
}

void main() {
  late List<ComicSource> originalSources;

  setUp(() {
    // 源表要应用启动时才由 `ComicSource.init()` 填充；测试里手工装上内置源，
    // 语义等价（`init()` 多做的一件事是读磁盘源数据，与本组无关）。
    originalSources = List<ComicSource>.of(ComicSource.sources);
    ComicSource.sources
      ..clear()
      ..addAll(ComicSource.builtIn);
  });

  tearDown(() {
    ComicSource.sources
      ..clear()
      ..addAll(originalSources);
  });

  group('resolveLocalItemComicSource · 身份只能来自 sourceKey', () {
    test('Pixiv / Komiic 都能解析到注册的源（Komiic 大小写必须容错）', () {
      expect(
        resolveLocalItemComicSource(_customItem())?.key,
        'pixiv',
      );
      // 下载/历史/收藏侧把 Komiic 写作 `'Komiic'`，注册表里是小写 `'komiic'`。
      expect(
        resolveLocalItemComicSource(_customItem(
          id: 'komiic1234',
          sourceKey: 'Komiic',
          sourceName: 'Komiic',
          comicId: '1234',
        ))?.key,
        'komiic',
      );
    });

    test('managed 链路的 LocalLibraryComicItem 从 sourceRowJson 还原身份', () {
      final item = _localItem(
        originalId: 'pixiv82074457',
        sourceRowJson: jsonEncode(_customItem().toJson()),
      );

      expect(resolveLocalItemComicSource(item)?.key, 'pixiv');
      expect(customDownloadedRecordOf(item)?.sourceKey, 'pixiv');
    });

    test('没有 sourceRowJson 的本地条目解析不出源（隐藏入口而不是猜）', () {
      expect(resolveLocalItemComicSource(_localItem(originalId: 'jm1')), isNull);
      expect(
        resolveLocalItemComicSource(_localItem(originalId: 'x', sourceRowJson: '')),
        isNull,
      );
    });

    test('未注册进源表的自定义源（如拷贝漫画）解析为 null', () {
      final item = _customItem(
        id: 'copy123',
        sourceKey: 'copy_manga',
        sourceName: '拷贝漫画',
        comicId: '123',
      );

      expect(resolveLocalItemComicSource(item), isNull);
    });

    test('非自定义源条目（picacg/jm 等具体类）不进这条路', () {
      final comic = DownloadedComic(
        comicId: 'abcdefabcdefabcdefabcdef',
        title: 'Pica',
        author: '',
        chapters: const <String>['EP 1'],
        downloadedChapters: const <int>[0],
      );

      expect(resolveLocalItemComicSource(comic), isNull);
    });
  });

  group('resolveLocalItemComicSourceId · 传给详情页的就是源站 id', () {
    test('优先用 comicId（Pixiv 是 illustId、Komiic 是站内 id）', () {
      expect(resolveLocalItemComicSourceId(_customItem()), '82074457');
      expect(
        resolveLocalItemComicSourceId(_customItem(
          id: 'komiic1234',
          sourceKey: 'Komiic',
          sourceName: 'Komiic',
          comicId: '1234',
        )),
        '1234',
      );
    });

    test('老记录缺 comicId 时从下载 id 去源前缀（大小写不敏感）', () {
      expect(
        resolveLocalItemComicSourceId(_customItem(comicId: '')),
        '82074457',
      );
      expect(
        resolveLocalItemComicSourceId(_customItem(
          id: 'komiic1234',
          sourceKey: 'Komiic',
          sourceName: 'Komiic',
          comicId: '',
        )),
        '1234',
      );
    });

    test('id 与 comicId 都取不到时返回 null（调用方必须拦截）', () {
      expect(
        resolveLocalItemComicSourceId(_customItem(id: '', comicId: '')),
        isNull,
      );
    });
  });

  group('buildLocalItemOnlineComicPage · 统一走 comicPageBuilder', () {
    test('Pixiv / Komiic 都构造出对应源的详情页，并带上正确的 id', () {
      expect(
        (buildLocalItemOnlineComicPage(_customItem()) as PixivComicPageV2)
            .comicId,
        '82074457',
      );
      expect(
        (buildLocalItemOnlineComicPage(_customItem(
          id: 'komiic1234',
          sourceKey: 'Komiic',
          sourceName: 'Komiic',
          comicId: '1234',
        )) as KomiicComicPageV2)
            .comicId,
        '1234',
      );
    });

    test('未注册源 / 缺 id 时返回 null，不会构造出打不开的页面', () {
      expect(
        buildLocalItemOnlineComicPage(_customItem(
          id: 'copy123',
          sourceKey: 'copy_manga',
          comicId: '123',
        )),
        isNull,
      );
      expect(
        buildLocalItemOnlineComicPage(_customItem(id: '', comicId: '')),
        isNull,
      );
    });

    test('源表为空（启动早期）时返回 null 而不是抛异常', () {
      ComicSource.sources.clear();
      expect(buildLocalItemOnlineComicPage(_customItem()), isNull);
    });
  });

  group('supportsVisitOnline · 入口可见性与入口行为严格一致', () {
    test('四源回归：JM / picacg / nhentai / EH 仍然可见', () {
      final jm = DownloadedJmComic(
        comicId: '1228705',
        name: 'JM',
        downloadedChapters: const <int>[0],
      );
      final picacg = DownloadedComic(
        comicId: 'abcdefabcdefabcdefabcdef',
        title: 'Pica',
        author: '',
        chapters: const <String>['EP 1'],
        downloadedChapters: const <int>[0],
      );
      final eh = DownloadedGallery(
        galleryTitle: 'EH',
        link: 'https://e-hentai.org/g/220980/abc123def/',
      );
      final nh = NhentaiDownloadedComic(comicID: '123456', title: 'NH');

      for (final comic in <DownloadedItem>[jm, picacg, eh, nh]) {
        expect(supportsVisitOnline(comic), isTrue);
      }
    });

    test('Pixiv / Komiic 的已下载条目现在可见（本次修复的现象）', () {
      expect(supportsVisitOnline(_customItem()), isTrue);
      expect(
        supportsVisitOnline(_customItem(
          id: 'komiic1234',
          sourceKey: 'Komiic',
          sourceName: 'Komiic',
          comicId: '1234',
        )),
        isTrue,
      );
      // managed 链路（LocalLibraryComicItem 包装）同样可见。
      expect(
        supportsVisitOnline(_localItem(
          originalId: 'pixiv82074457',
          sourceRowJson: jsonEncode(_customItem().toJson()),
        )),
        isTrue,
      );
    });

    test('不支持的来源仍然不可见（不做假阳性入口）', () {
      expect(
        supportsVisitOnline(_customItem(
          id: 'copy123',
          sourceKey: 'copy_manga',
          sourceName: '拷贝漫画',
          comicId: '123',
        )),
        isFalse,
      );
      expect(
        supportsVisitOnline(_localItem(originalId: 'unknown1')),
        isFalse,
      );
    });

    test('回归：supportsUpdateInfo 语义一个都没变（更新信息菜单不该被顺带放开）', () {
      // "更新信息"菜单与「在线详情」入口共用过这个判据；Pixiv/Komiic 的
      // `_onUpdateInfo` 并没有对应分支，放开它会得到一个"点了没反应"的死入口，
      // 所以本次只新增 `supportsVisitOnline`，不动这个函数。
      expect(supportsUpdateInfo(DownloadType.jm), isTrue);
      expect(supportsUpdateInfo(DownloadType.picacg), isTrue);
      expect(supportsUpdateInfo(DownloadType.nhentai), isTrue);
      expect(supportsUpdateInfo(DownloadType.ehentai), isTrue);
      expect(supportsUpdateInfo(DownloadType.pixiv), isFalse);
      expect(supportsUpdateInfo(DownloadType.komiic), isFalse);
      expect(supportsUpdateInfo(DownloadType.other), isFalse);

      // 自定义源条目的 `type` 恒为 other —— 这正是"加进 supportsUpdateInfo
      // 也命不中"的原因，用断言把它钉住，防止以后有人误改那个函数。
      expect(_customItem().type, DownloadType.other);
      expect(
        _customItem(
          id: 'komiic1234',
          sourceKey: 'Komiic',
          sourceName: 'Komiic',
          comicId: '1234',
        ).type,
        DownloadType.other,
      );
    });
  });
}
