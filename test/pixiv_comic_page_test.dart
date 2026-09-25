/// Pixiv 详情页的三项改动契约测试（第十八轮，真机反馈驱动）。
///
/// 覆盖用户实测后提出的三点：
/// 1. **预览区位置**：从「标签之后、简介之前」移到**简介之后**。
///    判据是钩子归属——必须走 `buildSectionAfterDescription`，
///    `buildCustomSection` 必须返回 null（否则又跑回简介前面去）。
/// 2. **信息区补 ID**：`extractTags` 必须包含 `ID` 桶且值为裸数字。
/// 3. **ID 行不可拿去搜索**：ID 是纯数字，当关键词搜只会得到无关结果。
///    （该行为由 `onTagTap` 的 `category == 'ID'` 分支实现，本文件锁"ID 在
///    extractTags 里"这一前置事实，点击行为由人工真机确认。）
///
/// 纯声明 / 纯函数断言，不出网、不加载真实数据。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/pages/online_comic/pixiv_comic_page_v2.dart';

PixivComicInfo _info({
  String id = '100412238',
  String author = 'SSSSOLD',
  List<String> tags = const <String>['R-18', 'Arknights'],
  String description = '简介文本',
  int pageCount = 3,
  int illustType = pixivIllustTypeIllust,
}) =>
    PixivComicInfo(
      id: id,
      title: '测试作品',
      author: author,
      authorId: 'u1',
      coverUrl: 'https://i.pximg.net/cover.jpg',
      tags: tags,
      description: description,
      pageCount: pageCount,
      illustType: illustType,
      likeCount: 1,
      viewCount: 2,
      width: 100,
      height: 200,
      isOriginal: true,
      createDate: '2026-01-01',
      uploadDate: '2026-01-01',
      userId: 'u1',
    );

void main() {
  group('信息区：Pixiv ID 必须可见', () {
    test('extractTags 含 ID 桶，值为裸数字 ID', () {
      const page = PixivComicPageV2('100412238');
      final tags = page.extractTags(_info());
      expect(tags, isNotNull);
      expect(tags!.containsKey('ID'), isTrue, reason: '信息区要显示 Pixiv ID');
      expect(tags['ID'], <String>['100412238']);
    });

    test('ID 不带 pixiv 前缀（信息区上方已有源标识行）', () {
      const page = PixivComicPageV2('100412238');
      final id = page.extractTags(_info())!['ID']!.single;
      expect(id, '100412238');
      expect(id.toLowerCase().contains('pixiv'), isFalse);
    });

    test('ID 排在作者与标签之前（与 JM 的 ID 置顶同范式）', () {
      const page = PixivComicPageV2('100412238');
      final keys = page.extractTags(_info())!.keys.toList();
      expect(keys.first, 'ID');
      expect(keys, containsAll(<String>['作者', '标签']));
    });

    test('ID 为空时不产生空行', () {
      const page = PixivComicPageV2('');
      final tags = page.extractTags(_info(id: ''));
      expect(tags?.containsKey('ID') ?? false, isFalse);
    });

    test('作者/标签为空时对应桶消失，但 ID 仍在', () {
      const page = PixivComicPageV2('100412238');
      final tags = page.extractTags(
        _info(author: '', tags: const <String>[]),
      );
      expect(tags!.keys, <String>['ID']);
    });
  });

  group('预览区位置：必须在简介之后', () {
    testWidgets('走 after-description 钩子，且不再占用 custom 插槽', (tester) async {
      const page = PixivComicPageV2('100412238');
      final data = _info();

      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      // custom 插槽在**简介之前**：改用 after-description 后这里必须为空，
      // 否则预览会同时出现在两处（或回到简介前面）。
      expect(
        page.buildCustomSection(ctx, data),
        isNull,
        reason: 'custom 插槽在简介之前，预览不应再用它',
      );

      // after-description 插槽在**简介之后**：这里必须有内容。
      expect(
        page.buildSectionAfterDescription(ctx, data),
        isNotNull,
        reason: '预览应挂在简介之后的插槽',
      );
    });
  });

  group('无效页数时的下载拦截（既有行为不回归）', () {
    test('pageCount 为 0 时 extractPages 仍返回 0（由页面层决定是否可下载）', () {
      const page = PixivComicPageV2('100412238');
      expect(page.extractPages(_info(pageCount: 0)), 0);
    });
  });
}
