/// Komiic 详情页「信息区显示作品 ID」的契约测试。
///
/// 来自真机反馈：信息区只有作者 / 标签 / 状态 / 年份，**没有作品 ID**，
/// 而同一位置的 Pixiv、JM 详情页都能看到 ID（用于跨设备定位作品）。
///
/// 这里锁两件事：
/// 1. `extractTags` 含 `ID` 桶，值为**裸 ID**（信息区上方已有「Komiic」源标识）；
/// 2. `ID` 放在桶的最前面，与 Pixiv / JM 的信息区顺序一致。
///
/// `onTagTap` 的"点 ID = 复制而非搜索"分支需要 BuildContext 与剪贴板，
/// 本文件不做断言（与 `pixiv_comic_page_test.dart` 同一处理方式）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/network/komiic_network/komiic_models.dart';
import 'package:picakeep/pages/online_comic/komiic_comic_page_v2.dart';

KomiicComicInfo _info({
  String id = '12345',
  List<String> authors = const <String>['奇仙'],
  List<String> tags = const <String>['神鬼', '冒险'],
  String status = 'ONGOING',
  String year = '2020',
}) =>
    KomiicComicInfo(
      id: id,
      title: '魔术师们的混乱',
      coverUrl: 'https://komiic.com/api/image/abc',
      authors: authors,
      tags: tags,
      description: '简介文本',
      status: status,
      year: year,
      updateTime: '2026-01-01',
      views: 17000,
      monthViews: 100,
      favoriteCount: 50,
      chapters: const <KomiicChapter>[],
      recommendations: const <KomiicComicBrief>[],
    );

void main() {
  group('Komiic 信息区：作品 ID 必须可见', () {
    test('extractTags 含 ID 桶，值为裸 ID', () {
      const page = KomiicComicPageV2('12345');
      final tags = page.extractTags(_info());
      expect(tags, isNotNull);
      expect(tags!.containsKey('ID'), isTrue, reason: '信息区要显示 Komiic ID');
      expect(tags['ID'], <String>['12345']);
    });

    test('ID 不带 komiic 前缀（信息区上方已有源标识行）', () {
      const page = KomiicComicPageV2('12345');
      final id = page.extractTags(_info())!['ID']!.single;
      expect(id, '12345');
      expect(id.toLowerCase().contains('komiic'), isFalse);
    });

    test('ID 排在第一位，与 Pixiv / JM 的信息区顺序一致', () {
      const page = KomiicComicPageV2('12345');
      final keys = page.extractTags(_info())!.keys.toList();
      expect(keys.first, 'ID');
      expect(keys, <String>['ID', '作者', '标签', '状态', '年份']);
    });

    test('id 为空时不渲染 ID 行（避免出现空白行）', () {
      const page = KomiicComicPageV2('');
      final tags = page.extractTags(_info(id: ''));
      expect(tags, isNotNull);
      expect(tags!.containsKey('ID'), isFalse);
    });

    test('其余信息桶不受影响', () {
      const page = KomiicComicPageV2('12345');
      final tags = page.extractTags(_info())!;
      expect(tags['作者'], <String>['奇仙']);
      expect(tags['标签'], <String>['神鬼', '冒险']);
      expect(tags['状态'], <String>['ONGOING']);
      expect(tags['年份'], <String>['2020']);
    });
  });
}
