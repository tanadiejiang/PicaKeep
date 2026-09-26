/// 「已下载」页不再显示 Pixiv 内容（36 号）—— 过滤判据的边界用例。
///
/// ## 背景
///
/// 用户要求「Pixiv 的已下载内容就不用显示在这里了」。过滤点放在
/// `pages/download_page_logic_loading.dart` 的 `_reloadContent()` ——
/// 那里是**三个档位（本地 / 聚合 / 远程）的公共出口**，所以过滤口径天然一致
/// （用户切档时不会突然冒出一批 Pixiv 记录）。
///
/// 过滤点本身要真实环境（sqlite + 目录扫描）才能跑到，这里守的是**判据函数**
/// [isPixivDownloadedItem]：它认错一次，用户就会看到"过滤没生效"或者
/// "别的源被误杀"。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_model.dart';

/// 一条最小可用的自定义源下载记录。
CustomDownloadedItem _item({
  required String id,
  String sourceKey = '',
  String sourceName = '',
}) =>
    CustomDownloadedItem(
      downloadedEps: const <int>[1],
      id: id,
      name: '作品名',
      subTitle: '作者名',
      tags: const <String>[],
      sourceKey: sourceKey,
      sourceName: sourceName,
      cover: '',
      comicId: id,
    );

void main() {
  group('认得出 Pixiv', () {
    test('sourceKey 为 pixiv（真机取证里的形态）', () {
      expect(
        isPixivDownloadedItem(_item(id: '150034783', sourceKey: 'pixiv')),
        isTrue,
      );
    });

    test('大小写与空白不敏感（来源标识不是枚举，写入侧可能带脏值）', () {
      expect(
        isPixivDownloadedItem(_item(id: '1', sourceKey: ' Pixiv ')),
        isTrue,
      );
      expect(
        isPixivDownloadedItem(_item(id: '1', sourceKey: '', sourceName: 'PIXIV')),
        isTrue,
      );
    });

    test('sourceName 为 pixiv 而 sourceKey 缺失 → 仍认得出', () {
      expect(
        isPixivDownloadedItem(_item(id: '150034783', sourceName: 'pixiv')),
        isTrue,
      );
    });

    test('老式行（json 解析不出、没有 sourceKey）靠 id 前缀兜住', () {
      // `OnlineDownloadManager` 写入的 Pixiv 记录 id 形如 `pixiv150034783`；
      // 这类行会被构造成 `ScannedDownloadedComic`（没有 sourceKey 字段），
      // 只认 sourceKey 会让它漏网 = 用户看到"过滤没生效"。
      expect(
        isPixivDownloadedItem(_item(id: 'pixiv150034783')),
        isTrue,
      );
    });
  });

  group('不误杀别的来源', () {
    test('其它在线源一律不动', () {
      for (final key in <String>[
        'nhentai',
        'ehentai',
        'jm',
        'Komiic',
        'copy_manga',
        'picacg',
      ]) {
        expect(
          isPixivDownloadedItem(_item(id: '123456', sourceKey: key)),
          isFalse,
          reason: '$key 不该被当成 Pixiv 过滤掉',
        );
      }
    });

    test('没有来源标识的本地记录不动', () {
      expect(isPixivDownloadedItem(_item(id: '123456')), isFalse);
      expect(isPixivDownloadedItem(_item(id: 'some-dir-name')), isFalse);
    });

    test('id 中间含 pixiv 但不在开头 → 不是（前缀判据不能放宽）', () {
      // `startsWith` 一旦被改成 `contains`，任何标题/路径里带 pixiv 的本地目录
      // 都会被误杀。
      expect(
        isPixivDownloadedItem(_item(id: 'abc-pixiv-1')),
        isFalse,
      );
      expect(
        isPixivDownloadedItem(_item(id: '[Pixiv] 合集')),
        isFalse,
      );
    });

    test('空 id 不误判', () {
      expect(isPixivDownloadedItem(_item(id: '')), isFalse);
    });
  });
}
