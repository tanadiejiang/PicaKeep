/// 临时验收脚本（验证完删除）：检查第十八轮两个新源的注册完整性。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/comic_source/comic_source.dart';

void main() {
  /// `ComicSource.require` 依赖 `init()` 填充静态 `sources`；测试里不做完整
  /// App 初始化，故直接从 `builtIn` 里查找，语义等价。
  ComicSource find(String key) =>
      ComicSource.builtIn.firstWhere((source) => source.key == key);

  test('内置源含 pixiv 与 komiic，且各扩展点齐备', () {
    final keys = ComicSource.builtIn.map((source) => source.key).toList();
    expect(keys, contains('pixiv'));
    expect(keys, contains('komiic'));

    for (final key in <String>['pixiv', 'komiic']) {
      final source = find(key);
      expect(source.comicPageBuilder, isNotNull, reason: '$key 缺详情页构造器');
      expect(source.imageHeadersBuilder, isNotNull, reason: '$key 缺封面鉴权头');
      expect(source.searchPageData, isNotNull, reason: '$key 缺搜索');
      expect(source.idMatcher, isNotNull, reason: '$key 缺 ID 直跳正则');
      expect(source.account, isNotNull, reason: '$key 缺账号配置');
    }
  });

  test('ID 正则行为：带前缀精确单命中，裸数字多源并列', () {
    final matchers = <String, RegExp>{
      for (final source in ComicSource.builtIn)
        if (source.idMatcher != null) source.key: source.idMatcher!,
    };

    List<String> hits(String input) => matchers.entries
        .where((entry) => entry.value.hasMatch(input))
        .map((entry) => entry.key)
        .toList();

    // 带前缀：各自只命中一个，这是最好用的形态。
    expect(hits('pixiv123456'), <String>['pixiv']);
    expect(hits('komiic123456'), <String>['komiic']);
    expect(hits('nh123456'), <String>['nhentai']);
    expect(hits('jm123456'), <String>['jm']);

    // 裸数字：四源并列。这是 03/04 号计划已预判并接受的取舍
    // （搜索页会并排给出四个「打开漫画」chip，用户在 UI 上自行区分）。
    // Komiic 的 ID 形态实测为纯数字（站点 URL 形如 komiic.com/comic/1），
    // 用户已确认「能打开详情页就保留」，故保留纯数字匹配。
    // 第十八轮 34 号补充：Pixiv 在这四个「打开漫画」chip 之外**另外**并排一个
    // 「打开作者页」chip（纯数字无法区分作品 id 与作者 uid，由用户自己选）；
    // 其余三个源的 chip 数量与显示条件不变。
    expect(
      hits('123456'),
      containsAll(<String>['jm', 'nhentai', 'pixiv', 'komiic']),
    );
  });

  test('Pixiv 搜索固定 safe 档，Komiic 无排序选项', () {
    final pixiv = find('pixiv');
    expect(pixiv.searchPageData!.defaultOption, 'date_d');
    expect(
      pixiv.searchPageData!.searchOptions.map((option) => option.value),
      <String>['date_d', 'date'],
    );

    final komiic = find('komiic');
    // Komiic 搜索接口不接受分页/排序参数，故不提供排序选项。
    expect(komiic.searchPageData!.searchOptions, isEmpty);
  });

  test('Komiic 是多收藏夹源，Pixiv 是单收藏夹源', () {
    expect(find('komiic').favoriteData!.multiFolder, isTrue);
    expect(find('pixiv').favoriteData!.multiFolder, isFalse);
  });
}
