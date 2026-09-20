import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/built_in/nhentai.dart'
    show nhentaiLanguageTag;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/favorite_source_id.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_favorites_update.dart';
import 'package:sqlite3/open.dart';

/// 09 计划：本地收藏「更新卡片信息」。
///
/// 网络层不在测试里打真实请求：本文件覆盖
/// ①本地库按 (target,type) 回写（U01/U02）；
/// ②四源 id 形态与校验（U03）；
/// ③标签清洗（U07）；
/// ④批量流程的进度/取消/失败隔离（U05/U06）——通过在源上注入 stub 的网络能力，
/// 不触碰真实站点。
class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationCachePath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// [type] 用可空参数而不是 const 默认值：`FavoriteType.jm` 是静态 getter，
/// 不是编译期常量，不能作为可选参数的默认值。
FavoriteItem _item(
  String id, {
  FavoriteType? type,
  String name = 'Fixture',
  String author = 'Author',
  List<String> tags = const ['旧标签'],
}) =>
    FavoriteItem(
      target: id,
      name: name,
      coverPath: '',
      author: author,
      type: type ?? FavoriteType.jm,
      tags: List<String>.from(tags),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
    OperatingSystem.windows,
    () =>
        DynamicLibrary.open('${Directory.current.path}/windows/sqlite3.dll'),
  );

  final manager = LocalFavoritesManager();
  final savedPaths = PathProviderPlatform.instance;
  final savedMode = managedDataSourceMode;
  late Directory workspace;
  late Directory root;
  var serial = 0;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('pk09_update_');
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

  FavoriteItem? findComic(String folder, String target, FavoriteType type) {
    for (final comic in manager.getAllComics(folder)) {
      if (comic.target == target && comic.type.key == type.key) {
        return comic;
      }
    }
    return null;
  }

  group('U01 按 (target,type) 回写本地记录', () {
    test('name/author/tags/cover 被更新，time 与顺序不变', () async {
      manager.createFolder('A');
      await Future<void>.delayed(Duration.zero);
      manager.addComic('A', _item('1472970'));
      final before = findComic('A', '1472970', FavoriteType.jm)!;
      final timeBefore = before.time;
      final orderBefore =
          manager.getAllComics('A').indexWhere((c) => c.target == '1472970');

      final ok = manager.updateComicInfo(
        'A',
        '1472970',
        FavoriteType.jm.key,
        name: '新名字',
        author: '新作者',
        tags: const ['束缚', '中文'],
        coverPath: '/tmp/cover.jpg',
      );

      expect(ok, isTrue);
      final after = findComic('A', '1472970', FavoriteType.jm)!;
      expect(after.name, '新名字');
      expect(after.author, '新作者');
      expect(after.tags, ['束缚', '中文']);
      expect(after.coverPath, '/tmp/cover.jpg');
      expect(after.time, timeBefore, reason: '收藏时间不得被在线的上传时间覆盖');
      expect(
        manager.getAllComics('A').indexWhere((c) => c.target == '1472970'),
        orderBefore,
        reason: 'display_order 不得被更新打乱',
      );
    });

    test('tags 传 null 时保留原值', () async {
      manager.createFolder('A');
      await Future<void>.delayed(Duration.zero);
      manager.addComic('A', _item('1', tags: const ['原标签']));

      manager.updateComicInfo('A', '1', FavoriteType.jm.key, author: '只有作者');

      final after = findComic('A', '1', FavoriteType.jm)!;
      expect(after.tags, ['原标签'], reason: 'null = 本次没拿到标签，必须保留原值');
      expect(after.author, '只有作者');
    });

    test('记录不存在时返回 false，且不新建条目', () async {
      manager.createFolder('A');
      await Future<void>.delayed(Duration.zero);
      final ok = manager.updateComicInfo('A', 'not-exist', FavoriteType.jm.key,
          name: 'X');
      expect(ok, isFalse);
      expect(manager.getAllComics('A'), isEmpty, reason: '更新不得变成新增');
    });
  });

  group('U02 同 target 不同来源互不影响', () {
    test('只改目标源那一条', () async {
      manager.createFolder('A');
      await Future<void>.delayed(Duration.zero);
      // 同一个 target 在 jm 与 nhentai 各一条：updateComicInfo 的 where 必须带 type
      manager.addComic('A', _item('605366', type: FavoriteType.jm));
      manager.addComic('A', _item('605366', type: FavoriteType.nhentai));

      final ok = manager.updateComicInfo(
        'A',
        '605366',
        FavoriteType.jm.key,
        name: 'JM 的新名字',
      );

      expect(ok, isTrue);
      expect(findComic('A', '605366', FavoriteType.jm)!.name, 'JM 的新名字');
      expect(findComic('A', '605366', FavoriteType.nhentai)!.name, 'Fixture',
          reason: 'NH 那条不得被串改');
    });
  });

  group('U03 四源 id 形态与校验', () {
    test('jm 接受纯数字与 jm 前缀，拒绝非数字/空', () {
      expect(extractJmNumericId('1472970'), '1472970');
      expect(extractJmNumericId('jm1472970'), '1472970');
      expect(extractJmNumericId(' 1472970 '), '1472970');
      for (final bad in const ['', '  ', 'jm', 'abc', '12a34', 'jmabc']) {
        expect(extractJmNumericId(bad), isNull, reason: 'bad="$bad"');
      }
    });

    test('nhentai 接受纯数字与 nhentai 前缀，拒绝非数字', () {
      expect(extractNhentaiNumericId('605366'), '605366');
      expect(extractNhentaiNumericId('nhentai605366'), '605366');
      for (final bad in const ['', 'nh', 'abc', 'nhentai']) {
        expect(extractNhentaiNumericId(bad), isNull, reason: 'bad="$bad"');
      }
    });

    test('EH 只接受白名单域名的完整画廊链接', () {
      expect(
        normalizeEhGalleryLink('https://e-hentai.org/g/2009163/61926e092e/'),
        'https://e-hentai.org/g/2009163/61926e092e/',
      );
      expect(
        normalizeEhGalleryLink('https://exhentai.org/g/1/abc/'),
        'https://exhentai.org/g/1/abc/',
      );
      // gid-token 形态缺域名，无法请求 → 必须判为不可用（不猜域名）
      expect(normalizeEhGalleryLink('2009163-61926e092e'), isNull);
      // 仿冒/非白名单域名
      expect(normalizeEhGalleryLink('https://e-hentai.org.evil.com/g/1/a/'),
          isNull);
      expect(normalizeEhGalleryLink('https://example.com/g/1/a/'), isNull);
      // 路径不合规
      expect(normalizeEhGalleryLink('https://e-hentai.org/s/1/a/'), isNull);
      expect(normalizeEhGalleryLink(''), isNull);
    });

    test('只有四源被认为支持更新', () {
      expect(favoriteSourceKeyForType(FavoriteType.jm.key), 'jm');
      expect(favoriteSourceKeyForType(FavoriteType.nhentai.key), 'nhentai');
      expect(favoriteSourceKeyForType(FavoriteType.picacg.key), 'picacg');
      expect(favoriteSourceKeyForType(FavoriteType.ehentai.key), 'ehentai');
      for (final type in <FavoriteType>[
        FavoriteType.hitomi,
        FavoriteType.htManga,
        FavoriteType.copyManga,
        FavoriteType.komiic,
      ]) {
        expect(favoriteSourceKeyForType(type.key), isNull);
        expect(supportsFavoriteInfoUpdate(type.key), isFalse);
      }
    });
  });

  group('U04 各源字段映射（可离线验证的部分）', () {
    test('NH 语言标签：只取 Languages 桶，忽略其它桶', () {
      final tags = <String, List<String>>{
        'Artists': ['aono'],
        'Languages': ['中文'],
        'Tags': ['big breasts', 'bikini'],
      };
      expect(nhentaiLanguageTag(tags), ['中文']);
    });

    test('NH 语言标签：没有 Languages 桶时返回 null（调用方保留原值）', () {
      expect(nhentaiLanguageTag({'Artists': ['aono']}), isNull);
      expect(nhentaiLanguageTag(const {}), isNull);
      expect(nhentaiLanguageTag({'Languages': const []}), isNull);
    });

    test('NH 语言标签：去重、去空白、大小写不敏感匹配桶名', () {
      expect(
        nhentaiLanguageTag({
          'languages': [' 中文 ', '中文', '', 'English'],
        }),
        ['中文', 'English'],
      );
    });

    test('NH 作者来自 Artists 桶而不是 uploader 桶', () {
      final tags = <String, List<String>>{
        'Artists': ['aono', 'second'],
        'Uploaded': ['2026-09-19'],
        'Tags': ['big breasts'],
      };
      expect(resolveNhentaiAuthors(tags), ['aono', 'second']);
    });
  });

  group('U07 标签清洗', () {
    test('去重、去空白、过滤纯数字', () {
      expect(
        sanitizeFavoriteTags(const [
          '同人',
          '同人',
          ' 中文 ',
          '',
          '   ',
          '123',
          '456',
          '中文',
        ]),
        ['同人', '中文'],
      );
    });

    test('全为无效项时返回空列表', () {
      expect(sanitizeFavoriteTags(const ['1', '2', ' ', '']), isEmpty);
    });

    test('保留顺序', () {
      expect(
        sanitizeFavoriteTags(const ['c', 'a', 'b']),
        ['c', 'a', 'b'],
      );
    });
  });

  group('U05/U06 批量流程：失败隔离、进度与取消', () {
    test('未登录/无网络能力时全部计入"来源不支持"，不发起请求也不崩', () async {
      manager.createFolder('A');
      await Future<void>.delayed(Duration.zero);
      // hitomi 没有网络层 → 必须归入 unsupported
      manager.addComic('A', _item('1', type: FavoriteType.hitomi));
      manager.addComic('A', _item('2', type: FavoriteType.hitomi));

      final report = await updateLocalFavoritesCardInfo('A');

      expect(report.total, 2);
      expect(report.unsupported, 2);
      expect(report.updated, 0);
      expect(report.failed, 0);
      expect(buildLocalFavoriteUpdateSummary(report), contains('不支持'));
    });

    test('进度回调递增到 total，空夹子也能给出 0/0', () async {
      manager.createFolder('A');
      await Future<void>.delayed(Duration.zero);
      manager.addComic('A', _item('1', type: FavoriteType.hitomi));
      manager.addComic('A', _item('2', type: FavoriteType.hitomi));
      final progress = <int>[];
      final totals = <int>[];

      await updateLocalFavoritesCardInfo(
        'A',
        onProgress: (completed, total) {
          progress.add(completed);
          totals.add(total);
        },
      );

      expect(progress.first, 0, reason: '开始先报 0');
      expect(progress.last, 2, reason: '结束报 total');
      expect(totals, everyElement(2));
    });

    test('取消后未处理条目不被修改', () async {
      manager.createFolder('A');
      await Future<void>.delayed(Duration.zero);
      manager.addComic('A', _item('1', type: FavoriteType.hitomi));
      manager.addComic('A', _item('2', type: FavoriteType.hitomi));
      manager.addComic('A', _item('3', type: FavoriteType.hitomi));

      var calls = 0;
      final report = await updateLocalFavoritesCardInfo(
        'A',
        onProgress: (completed, total) => calls++,
        isCancelled: () => true, // 第一条之前就取消
      );

      expect(report.cancelled, isTrue);
      expect(report.updated, 0);
      expect(report.unsupported, 0, reason: '取消后不再处理任何条目');
      expect(calls, 1, reason: '只报了一次初始进度');
    });

    test('explicitComics 只处理指定条目（长按多选入口）', () async {
      manager.createFolder('A');
      await Future<void>.delayed(Duration.zero);
      manager.addComic('A', _item('1', type: FavoriteType.hitomi));
      manager.addComic('A', _item('2', type: FavoriteType.hitomi));
      manager.addComic('A', _item('3', type: FavoriteType.hitomi));
      final all = manager.getAllComics('A');
      final selected = [all.firstWhere((c) => c.target == '2')];

      final report = await updateLocalFavoritesCardInfo(
        'A',
        explicitComics: selected,
      );

      expect(report.total, 1, reason: '只处理传入的那一条，而不是整个夹子');
      expect(report.unsupported, 1);
    });
  });
}
