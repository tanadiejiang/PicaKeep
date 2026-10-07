/// Pixiv / Komiic 阅读数据契约测试（第十八轮）。
///
/// 这两个源的关键差异是「有章节 / 无章节」：
/// - Pixiv：单本多图，`hasEp == false`，缓存键只按 id + 页码
/// - Komiic：章节制，`hasEp == true`，缓存键**必须含章节维度**
///
/// 这里只用纯 getter 断言（不触发任何网络请求），因为 `loadEpNetwork`
/// 会真的出网。同时校验 `downloadId` 前缀 —— 它是「已下载」状态、阅读历史
/// 与本地收藏三者能否命中的唯一纽带，前缀写错会**静默**变成"总是未下载"。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/def.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/network/komiic_network/komiic_models.dart';
import 'package:picakeep/network/pixiv_network/pixiv_models.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

PixivComicInfo _pixivInfo({String id = '100412238'}) => PixivComicInfo(
      id: id,
      title: '标题',
      author: '作者',
      authorId: 'u1',
      coverUrl: 'https://i.pximg.net/cover.jpg',
      tags: const <String>['a'],
      description: '',
      pageCount: 3,
      illustType: pixivIllustTypeIllust,
      likeCount: 1,
      viewCount: 2,
      width: 100,
      height: 200,
      isOriginal: true,
      createDate: '2026-01-01',
      uploadDate: '2026-01-01',
      userId: 'u1',
    );

KomiicComicInfo _komiicInfo({String id = '12345'}) => KomiicComicInfo(
      id: id,
      title: '标题',
      coverUrl: 'https://komiic.com/cover.jpg',
      authors: const <String>['作者'],
      tags: const <String>['熱血'],
      description: '',
      status: 'ONGOING',
      year: '2024',
      updateTime: '2026-01-02',
      views: 10,
      monthViews: 5,
      favoriteCount: 3,
      chapters: const <KomiicChapter>[
        KomiicChapter(
          id: 'c1',
          serial: '1',
          type: 'chapter',
          dateUpdated: '2026-01-01',
        ),
        KomiicChapter(
          id: 'c2',
          serial: '2',
          type: 'book',
          dateUpdated: '2026-01-02',
        ),
      ],
      recommendations: const <KomiicComicBrief>[],
    );

void main() {
  group('PixivReadingData 契约', () {
    test('无章节：hasEp=false、eps=null', () {
      final data = PixivReadingData(comic: _pixivInfo());
      expect(data.hasEp, isFalse);
      expect(data.eps, isNull);
    });

    test('downloadId 前缀为 pixiv（决定"已下载"能否命中）', () {
      final data = PixivReadingData(comic: _pixivInfo());
      expect(data.downloadId, 'pixiv100412238');
      expect(data.id, '100412238');
      expect(data.sourceKey, 'pixiv');
      expect(data.comicType, ComicType.pixiv);
      expect(data.favoriteType, FavoriteType.pixiv);
    });

    test('缓存键隔离页、来源档位与内容版本', () {
      final data = PixivReadingData(comic: _pixivInfo());
      final original = data.buildImageKey(1, 0, 'original');
      expect(original, isNot(data.buildImageKey(1, 0, 'regular')));
      expect(original, isNot(data.buildImageKey(1, 1, 'original')));
      expect(original, contains('pixiv'));
      expect(original, contains('100412238'));
    });
  });

  group('KomiicReadingData 契约', () {
    test('有章节：hasEp=true、eps 按 1-based 序号给出章节名', () {
      final data = KomiicReadingData(comic: _komiicInfo());
      expect(data.hasEp, isTrue);
      final eps = data.eps;
      expect(eps, isNotNull);
      expect(eps['1'], '1');
      // type == book 的章节显示为「卷N」。
      expect(eps['2'], '卷2');
    });

    test('downloadId 前缀为 komiic', () {
      final data = KomiicReadingData(comic: _komiicInfo());
      expect(data.downloadId, 'komiic12345');
    });

    test('sourceKey 用大写 Komiic（与下载/历史侧的既有约定一致）', () {
      final data = KomiicReadingData(comic: _komiicInfo());
      // 这条断言是刻意写死的：改成小写会让已下载记录与本地收藏静默命不中，
      // 而两者都不报错，只会表现为"下载完还是显示未下载"。
      expect(data.sourceKey, 'Komiic');
      expect(data.comicType, ComicType.komiic);
      expect(data.favoriteType, FavoriteType.komiic);
    });

    test('缓存键含章节维度，避免跨章串图', () {
      final data = KomiicReadingData(comic: _komiicInfo());
      final keyEp1 = data.buildImageKey(1, 0, 'u');
      final keyEp2 = data.buildImageKey(2, 0, 'u');
      expect(keyEp1, isNot(keyEp2));
      expect(keyEp1, contains('Komiic'));
      expect(keyEp1, isNot(data.buildImageKey(1, 0, 'updated')));
    });

    test('章节越界时 loadEpNetwork 抛出明确错误而非静默返回空', () async {
      final data = KomiicReadingData(comic: _komiicInfo());
      await expectLater(
        data.loadEpNetwork(99),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('两源标识互不串台', () {
    test('Pixiv 与 Komiic 的 downloadId 前缀不同', () {
      final pixiv = PixivReadingData(comic: _pixivInfo(id: '1'));
      final komiic = KomiicReadingData(comic: _komiicInfo(id: '1'));
      expect(pixiv.downloadId, isNot(komiic.downloadId));
    });

    test(
      '枚举扩展后 FavoriteType/ComicType 取到专属值而非 other',
      () {
        expect(ComicType.pixiv, isNot(ComicType.other));
        expect(ComicType.komiic, isNot(ComicType.other));
        expect(FavoriteType.pixiv.key, 9);
        expect(FavoriteType.komiic.key, 8);
        expect(FavoriteType.pixiv.name, 'Pixiv');
        expect(FavoriteType.komiic.name, 'Komiic');
      },
    );
  });
}
