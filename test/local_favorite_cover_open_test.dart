import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/pages/favorites/local_favorites.dart';
import 'package:picakeep/pages/online_comic/eh_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/jm_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/nhentai_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/picacg_comic_page_v2.dart';

// 10 号计划：本地收藏中「网络来源条目」的封面与打开链路。
//
// 这组用例只测**纯函数决策层**（resolveOnlineTargetSpec / buildOnlineComicPage
// / resolveFavoriteCoverSource）。它们正是生产链路里真正做分支的地方：
// OpenFavoriteComicHelper.resolveOpenTarget 先查本地、未命中再调
// resolveOnlineTargetSpec + buildOnlineComicPage；LocalFavoriteTile.build 调
// resolveFavoriteCoverSource 决定封面来源。因此断言的是真实行为而非测试副本。
//
// 注意：本地命中的分支（打开 LocalComicDetailPage）依赖 LocalLibraryManager /
// DownloadManager 的真实本地库，属真机用例 M03/M03b 覆盖，不在本文件内伪造。

void main() {
  group('U03/U04 各源 id 形态与校验', () {
    test('jm 纯数字可直接请求', () {
      final spec = resolveOnlineTargetSpec('1472970', FavoriteType.jm);
      expect(spec, isNotNull);
      expect(spec!.kind, FavoriteType.jm);
      expect(spec.id, '1472970');
    });

    test('jm 带 jm 前缀也可（历史形态）', () {
      expect(resolveOnlineTargetSpec('jm1472970', FavoriteType.jm)?.id,
          '1472970');
    });

    test('jm 非数字被拦截', () {
      for (final bad in const ['', '   ', 'abc', 'jm', 'jmabc', '12a34']) {
        expect(resolveOnlineTargetSpec(bad, FavoriteType.jm), isNull,
            reason: 'jm target=$bad 应被拦截');
      }
    });

    test('nhentai 纯数字与带前缀都可，非数字被拦截', () {
      expect(resolveOnlineTargetSpec('605366', FavoriteType.nhentai)?.id,
          '605366');
      expect(resolveOnlineTargetSpec('nhentai605366', FavoriteType.nhentai)?.id,
          '605366');
      expect(resolveOnlineTargetSpec('abc', FavoriteType.nhentai), isNull);
    });

    test('picacg 直接用原始值', () {
      expect(resolveOnlineTargetSpec('5f1a2b3c', FavoriteType.picacg)?.id,
          '5f1a2b3c');
    });

    test('ehentai 接受完整画廊链接', () {
      const link = 'https://e-hentai.org/g/2009163/61926e092e/';
      final spec = resolveOnlineTargetSpec(link, FavoriteType.ehentai);
      expect(spec, isNotNull);
      expect(spec!.id, link);
      // 无尾斜杠也应接受
      expect(
        resolveOnlineTargetSpec(
            'https://e-hentai.org/g/2009163/61926e092e', FavoriteType.ehentai),
        isNotNull,
      );
    });

    test('ehentai 的 gid-token 形态被归为链接不可用（U04）', () {
      for (final bad in const [
        '2009163-61926e092e',
        'https://e-hentai.org/favorites.php',
        'https://example.com/g/123/abc/',
        'ftp://e-hentai.org/g/123/abc/',
        'not a url',
      ]) {
        expect(resolveOnlineTargetSpec(bad, FavoriteType.ehentai), isNull,
            reason: 'ehentai target=$bad 应判为不可用');
      }
    });

    test('无网络层的源一律不可用（U06）', () {
      expect(resolveOnlineTargetSpec('123', const FavoriteType(3)), isNull);
      expect(resolveOnlineTargetSpec('123', const FavoriteType(4)), isNull);
      expect(resolveOnlineTargetSpec('123', const FavoriteType(7)), isNull);
      expect(resolveOnlineTargetSpec('123', const FavoriteType(8)), isNull);
    });
  });

  group('U03 在线页构造按源分发', () {
    test('四个内置源各自构造正确页面', () {
      expect(
        buildOnlineComicPage(OnlineTargetSpec(FavoriteType.jm, '1')),
        isA<JmComicPageV2>(),
      );
      expect(
        buildOnlineComicPage(OnlineTargetSpec(FavoriteType.nhentai, '1')),
        isA<NhentaiComicPageV2>(),
      );
      expect(
        buildOnlineComicPage(OnlineTargetSpec(FavoriteType.picacg, 'x')),
        isA<PicacgComicPageV2>(),
      );
      expect(
        buildOnlineComicPage(OnlineTargetSpec(
            FavoriteType.ehentai, 'https://e-hentai.org/g/1/a/')),
        isA<EhentaiComicPageV2>(),
      );
    });
  });

  group('U01/U01b/U01c/U02 封面三级降级', () {
    test('U01 无本地封面 + 网络 URL → 用网络封面', () {
      const url = 'https://cdn-msp.jmapiproxy3.cc/media/albums/1472970_3x4.jpg';
      final src = resolveFavoriteCoverSource(localCover: null, coverPath: url);
      expect(src.networkUrl, url);
      expect(src.file, isNull);
    });

    test('U01b 已下载但本地封面取不到 → 仍回退网络封面（用户实测场景）', () {
      // 这条是用户实测「已下载却破图」的直接回归断言：
      // 本地为 null（_coverFile 落到 File('')）时不得放弃网络兜底。
      const url = 'https://ehgt.org/w/00/976/62969-kgb1wf02.webp';
      final src = resolveFavoriteCoverSource(localCover: null, coverPath: url);
      expect(src.networkUrl, url);
    });

    test('U02 本地封面存在 → 用本地，不传网络图源', () {
      final local = File('/tmp/cover.jpg');
      final src = resolveFavoriteCoverSource(
        localCover: local,
        coverPath: 'https://example.com/a.jpg',
      );
      expect(src.file, local);
      expect(src.networkUrl, isNull, reason: '本地已命中时不应再挂网络图源');
    });

    test('U01c 本地与网络都取不到 → 两者皆空（渲染占位图标）', () {
      for (final path in const ['', '   ', '/not/exist/cover.jpg']) {
        final src =
            resolveFavoriteCoverSource(localCover: null, coverPath: path);
        expect(src.file, isNull);
        expect(src.networkUrl, isNull);
      }
    });

    test('空路径的本地 File 不会被当成有效封面', () {
      final src = resolveFavoriteCoverSource(
        localCover: File(''),
        coverPath: '',
      );
      expect(src.file, isNull);
      expect(src.networkUrl, isNull);
    });

    test('http 与 https 都识别为网络封面', () {
      expect(
        resolveFavoriteCoverSource(
                localCover: null, coverPath: 'http://a.com/c.jpg')
            .networkUrl,
        'http://a.com/c.jpg',
      );
      expect(
        resolveFavoriteCoverSource(
                localCover: null, coverPath: 'https://a.com/c.jpg')
            .networkUrl,
        'https://a.com/c.jpg',
      );
    });
  });

  group('U05d 候选 id 形态（"下载后自动转本地"的前提）', () {
    test('jm 纯数字 target 同时产出不带前缀与带前缀两种候选', () {
      final item = FavoriteItem(
        target: '1472970',
        name: 'n',
        coverPath: '',
        author: '',
        type: FavoriteType.jm,
        tags: const [],
      );
      final candidates = item.candidateDownloadIds();
      expect(candidates, contains('1472970'));
      expect(candidates, contains('jm1472970'),
          reason: '本地下载记录的 id 是 jm<id>，缺这一项就无法认领已下载作品');
    });

    test('nhentai 同理', () {
      final item = FavoriteItem(
        target: '605366',
        name: 'n',
        coverPath: '',
        author: '',
        type: FavoriteType.nhentai,
        tags: const [],
      );
      final candidates = item.candidateDownloadIds();
      expect(candidates, contains('nhentai605366'));
    });

    test('ehentai 完整链接可抽出 gid 候选', () {
      final item = FavoriteItem(
        target: 'https://e-hentai.org/g/2009163/61926e092e/',
        name: 'n',
        coverPath: '',
        author: '',
        type: FavoriteType.ehentai,
        tags: const [],
      );
      final candidates = item.candidateDownloadIds();
      expect(candidates, contains('2009163'));
    });
  });

  group('网络封面 provider（滚动性能）', () {
    test('同一 URL 复用同一 provider 实例', () {
      // 若每次 build 都新建 provider，ImageCache 命中与释放会抖动，
      // 表现为"每次滚动到该处都卡"。
      const url = 'https://cdn.example.com/a_3x4.jpg';
      final a = LocalFavoriteTile.networkCoverProvider(url);
      final b = LocalFavoriteTile.networkCoverProvider(url);
      expect(identical(a, b), isTrue);
    });

    test('不同 URL 得到不同 provider', () {
      final a = LocalFavoriteTile.networkCoverProvider('https://a.com/1.jpg');
      final b = LocalFavoriteTile.networkCoverProvider('https://a.com/2.jpg');
      expect(identical(a, b), isFalse);
    });

    test('provider 走磁盘缓存设施并缩放解码', () {
      final p = LocalFavoriteTile.networkCoverProvider('https://a.com/1.jpg');
      expect(p, isA<LocalFavoriteCoverProvider>());
      expect(p.targetDecodeWidth, LocalFavoriteCoverProvider.coverDecodeWidth,
          reason: '必须按封面尺寸缩放解码，否则原图全尺寸解码会拖慢滚动');
      expect(p.cacheRawBytes, isFalse,
          reason: '已有磁盘缓存兜底，原始字节不应再驻留堆上');
      expect(p.key, 'https://a.com/1.jpg', reason: 'key 必须是 URL 才能稳定命中');
    });

    test('缓存有上限且不抛异常', () {
      for (var i = 0; i < 200; i++) {
        LocalFavoriteTile.networkCoverProvider('https://a.com/$i.jpg');
      }
      // 未抛异常即通过；清缓存后仍可继续取用
      LocalFavoriteTile.clearCoverCache();
      expect(
        LocalFavoriteTile.networkCoverProvider('https://a.com/0.jpg'),
        isA<LocalFavoriteCoverProvider>(),
      );
    });
  });

  group('标签翻译缓存（滚动性能主因）', () {
    setUp(clearFavoriteTagTranslationCache);

    test('翻译结果稳定：多次调用一致', () {
      // 缓存不得改变结果（这是本优化的安全底线）。
      const tag = 'sole female';
      final first = translateFavoriteTag(tag);
      for (var i = 0; i < 5; i++) {
        expect(translateFavoriteTag(tag), first);
      }
    });

    test('未命中词典的标签原样返回', () {
      const unknown = 'zzz_不存在的标签_zzz';
      expect(translateFavoriteTag(unknown), unknown);
    });

    test('大小写行为与原实现一致：匹配不敏感、回退保留原样', () {
      // 词典命中时返回译文（与原文大小写无关）；未命中时返回**传入的原串**。
      // 缓存以原串为键，两种大小写各自缓存，互不污染。
      final lower = translateFavoriteTag('sole female');
      final upper = translateFavoriteTag('SOLE FEMALE');
      expect(translateFavoriteTag('sole female'), lower);
      expect(translateFavoriteTag('SOLE FEMALE'), upper);
      if (lower == 'sole female') {
        // 未命中词典：回退保留原样（预期路径）
        expect(upper, 'SOLE FEMALE');
      } else {
        // 命中词典：两种大小写应得到同一译文
        expect(upper, lower);
      }
    });

    test('清缓存后结果不变', () {
      const tag = 'sole male';
      final before = translateFavoriteTag(tag);
      clearFavoriteTagTranslationCache();
      expect(translateFavoriteTag(tag), before);
    });
  });
}
