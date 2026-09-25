/// 历史记录封面鉴权头的契约测试。
///
/// 真机反馈：历史记录里 **Pixiv 封面只有占位图**，Komiic 正常。
/// 根因是历史页与「我」页面用裸 `NetworkImage` 加载网络封面 ——
/// 没有 Referer，`i.pximg.net` 直接 403；也没有磁盘缓存。
///
/// 这里锁住"按源补头"这条链路：
/// 1. Pixiv / Komiic 等在线源必须解析出对应源并给出**非空**鉴权头；
/// 2. 本地条目与未知源必须给出空表（让调用方回退裸加载，不要塞垃圾头）。
///
/// 不断言具体头值（那是各源自己的契约，另有测试守着），
/// 只断言"这条链路把源找对了、头确实来了"。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/tools/history_cover.dart';

History _history({
  required HistoryType type,
  String cover = 'https://example.com/cover.jpg',
  String target = 'target-1',
}) =>
    History(
      type,
      DateTime(2026, 9, 25),
      '标题',
      '副标题',
      cover,
      1,
      1,
      target,
    );

void main() {
  setUpAll(() {
    // 源注册表要应用启动时才由 `ComicSource.init()` 填充。测试里手工装上
    // 内置源即可 —— 这里只用到 `imageHeadersBuilder`，它是构造期就固定的字段，
    // 不需要 `init()` 里那些 `loadData()`（会去读偏好/发网络）。
    ComicSource.sources
      ..clear()
      ..addAll(ComicSource.builtIn);
  });

  tearDownAll(() {
    ComicSource.sources.clear();
  });

  group('在线源解析', () {
    test('固定编号的历史类型能解析到对应源', () {
      expect(comicSourceForHistory(_history(type: HistoryType.pixiv))?.key,
          'pixiv');
      expect(comicSourceForHistory(_history(type: HistoryType.picacg))?.key,
          'picacg');
      expect(comicSourceForHistory(_history(type: HistoryType.ehentai))?.key,
          'ehentai');
      expect(comicSourceForHistory(_history(type: HistoryType.jmComic))?.key,
          'jm');
      expect(comicSourceForHistory(_history(type: HistoryType.nhentai))?.key,
          'nhentai');
    });

    test('自定义源按 sourceKey.hashCode 反查（Komiic 的历史侧是大写）', () {
      // read_history_helper.dart 用 `HistoryType(c.sourceKey.hashCode)`，
      // 而 Komiic 的下载/历史/收藏侧 sourceKey 是大写 `'Komiic'`，
      // 与注册表里的 `'komiic'` 不是同一个 hashCode —— 两种都要能命中。
      final source = comicSourceForHistory(
        _history(type: HistoryType('Komiic'.hashCode)),
      );
      expect(source?.key, 'komiic');
    });

    test('本地与其它类型不解析成在线源', () {
      expect(comicSourceForHistory(_history(type: HistoryType.other)), isNull);
      expect(
        comicSourceForHistory(_history(type: HistoryType.localAlbum)),
        isNull,
      );
    });

    test('未知 hashCode 不会误配到某个源', () {
      expect(
        comicSourceForHistory(_history(type: const HistoryType(987654321))),
        isNull,
      );
    });
  });

  group('封面鉴权头', () {
    test('Pixiv 条目必须拿到非空鉴权头（本次真机问题的直接断言）', () {
      final headers = historyCoverHeaders(_history(type: HistoryType.pixiv));
      expect(
        headers,
        isNotEmpty,
        reason: 'Pixiv 封面缺 Referer 会 403，头为空就等于封面加载不出来',
      );
      expect(headers.keys.map((k) => k.toLowerCase()), contains('referer'));
      expect(headers.keys.map((k) => k.toLowerCase()), contains('user-agent'));
    });

    test('Komiic 条目能拿到鉴权头', () {
      final headers = historyCoverHeaders(
        _history(type: HistoryType('Komiic'.hashCode)),
      );
      expect(headers, isNotEmpty);
      expect(headers.keys.map((k) => k.toLowerCase()), contains('referer'));
    });

    test('本地条目返回空表（调用方回退本地文件加载）', () {
      expect(historyCoverHeaders(_history(type: HistoryType.localAlbum)),
          isEmpty);
      expect(historyCoverHeaders(_history(type: HistoryType.other)), isEmpty);
    });

    test('未知源返回空表，不抛异常', () {
      expect(
        historyCoverHeaders(_history(type: const HistoryType(987654321))),
        isEmpty,
      );
    });
  });
}
