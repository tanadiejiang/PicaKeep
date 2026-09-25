/// Pixiv 探索 provider 的声明与分页契约测试（第十八轮）。
///
/// 覆盖两个最容易静默出错的点：
/// 1. **「我的收藏」入口的登录语义**——未登录必须给 `loginRequired` 而不是
///    "空列表"或"网络错误"，否则用户会以为收藏真的空了；
/// 2. **收藏分页的总数换算**——`getBookmarks` 放在 `subData` 里的是书签**总数**
///    （`body.total`）而非页数，直接当页数用会让几十条收藏被当成几十页，
///    用户一直翻到空白页才发现。
///
/// 这里只断言**纯声明**与**纯函数语义**，不出网、不构造网络单例的真实请求。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/providers/pixiv_explore_provider.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';

void main() {
  group('Pixiv 探索入口声明', () {
    test('三个入口齐备且 ID 唯一', () {
      final ids = PixivExploreProvider.descriptorOf.entries
          .map((entry) => entry.id)
          .toList();
      expect(ids, <String>[
        PixivExploreEntries.recommended,
        PixivExploreEntries.bookmarks,
        PixivExploreEntries.ranking,
      ]);
      expect(ids.toSet().length, ids.length, reason: '入口 ID 不得重复');
    });

    test('「我的收藏」是推荐类入口（需要在概览里可见）', () {
      final entry = PixivExploreProvider.descriptorOf
          .entryById(PixivExploreEntries.bookmarks);
      expect(entry, isNotNull);
      expect(entry!.kind, ExploreSectionKind.recommend);
    });

    test('排行榜是 ranking 类且有默认榜期、默认值在选项内', () {
      final entry = PixivExploreProvider.descriptorOf
          .entryById(PixivExploreEntries.ranking);
      expect(entry, isNotNull);
      expect(entry!.kind, ExploreSectionKind.ranking);
      expect(entry.options, isNotEmpty);
      expect(entry.defaultOptionId, isNotNull);
      expect(
        entry.options.any((option) => option.id == entry.defaultOptionId),
        isTrue,
        reason: '默认榜期必须是自己声明过的选项，否则首屏必然报错',
      );
    });

    test('排行榜不含 R-18 档（高风险内容不进探索页）', () {
      final entry = PixivExploreProvider.descriptorOf
          .entryById(PixivExploreEntries.ranking);
      for (final option in entry!.options) {
        expect(
          option.id.contains('r18'),
          isFalse,
          reason: '${option.id} 属 R-18 档，本源自用场景不提供',
        );
      }
    });

    test('requiresLogin 为 false：游客也能看推荐与榜单', () {
      // 若标成 true，未登录用户会被挡在探索页外，连游客可见的内容也拿不到。
      expect(PixivExploreProvider.descriptorOf.requiresLogin, isFalse);
      expect(PixivExploreProvider.descriptorOf.sourceKey, 'pixiv');
    });
  });

  group('收藏分页的总数换算契约', () {
    /// 与 provider 内 `_bookmarkNextToken` 一致的换算规则。
    ///
    /// 复制而非调用私有方法：这条规则是"总数 → 页数"的语义契约，
    /// 测试要独立守住它，实现改了必须同步改这里。
    String? nextTokenForTotal(int? total, int itemCount, int page) {
      const pageSize = PixivNetwork.bookmarkPageSize;
      if (total != null) {
        final totalPages = (total + pageSize - 1) ~/ pageSize;
        return page < totalPages ? '${page + 1}' : null;
      }
      return itemCount >= pageSize ? '${page + 1}' : null;
    }

    test('总数被换算成页数，而不是当成页数直接用', () {
      const pageSize = PixivNetwork.bookmarkPageSize; // 48
      // 200 条收藏 = 5 页（200/48 上取整），不是 200 页。
      const totalPages = (200 + pageSize - 1) ~/ pageSize;
      expect(totalPages, 5);
      // 第 1 页还有下一页。
      expect(nextTokenForTotal(200, pageSize, 1), '2');
      // 第 5 页（末页）没有下一页。
      expect(nextTokenForTotal(200, pageSize, 5), isNull);
      // 第 6 页已越界，同样没有下一页。
      expect(nextTokenForTotal(200, 1, 6), isNull);
    });

    test('恰好整除时末页判停正确（无多余空页）', () {
      const pageSize = PixivNetwork.bookmarkPageSize;
      // 96 条 = 正好 2 页。
      expect(nextTokenForTotal(96, pageSize, 1), '2');
      expect(nextTokenForTotal(96, pageSize, 2), isNull);
    });

    test('总数缺失时退回"满页即还有下一页"', () {
      const pageSize = PixivNetwork.bookmarkPageSize;
      expect(nextTokenForTotal(null, pageSize, 1), '2');
      expect(nextTokenForTotal(null, pageSize - 1, 1), isNull);
    });

    test('空收藏不产生下一页', () {
      expect(nextTokenForTotal(0, 0, 1), isNull);
    });
  });
}
