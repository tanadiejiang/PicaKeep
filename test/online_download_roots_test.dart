import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/online_download_manager.dart';

CustomDownloadedItem _item(String id, {String name = '标题'}) =>
    CustomDownloadedItem(
      id: id,
      name: name,
      subTitle: '作者',
      tags: const <String>[],
      sourceKey: 'pixiv',
      sourceName: 'Pixiv',
      cover: '',
      comicId: id,
      downloadedEps: const <int>[0],
    );

void main() {
  group('effectiveDownloadRootsFrom · 有效下载根集合', () {
    const def = '/data/app/download';

    test('Pixiv 专属目录为空时不额外加根', () {
      final roots = OnlineDownloadManager.effectiveDownloadRootsFrom(
        defaultRoot: def,
        configuredRoot: '/data/main',
        pixivRoot: '',
      );
      expect(roots, <String>{def, '/data/main'});
    });

    test('Pixiv 专属目录非空时纳入集合', () {
      final roots = OnlineDownloadManager.effectiveDownloadRootsFrom(
        defaultRoot: def,
        configuredRoot: '/data/main',
        pixivRoot: '/data/pixiv',
      );
      expect(roots, <String>{def, '/data/main', '/data/pixiv'});
    });

    test('两个配置都未设置时只剩默认根', () {
      final roots = OnlineDownloadManager.effectiveDownloadRootsFrom(
        defaultRoot: def,
        configuredRoot: '',
        pixivRoot: '   ',
      );
      expect(roots, <String>{def});
    });

    test('三个根指向同一目录时合并成一条（不产生重复条目）', () {
      final roots = OnlineDownloadManager.effectiveDownloadRootsFrom(
        defaultRoot: def,
        configuredRoot: def,
        pixivRoot: def,
      );
      expect(roots.length, 1);
      expect(roots, <String>{def});
    });

    test('首尾空白被去掉后再入集合', () {
      final roots = OnlineDownloadManager.effectiveDownloadRootsFrom(
        defaultRoot: def,
        configuredRoot: '  /data/main  ',
        pixivRoot: '  /data/pixiv  ',
      );
      expect(roots, <String>{def, '/data/main', '/data/pixiv'});
    });

    test('默认根恒在，即便两个配置都指向别处', () {
      final roots = OnlineDownloadManager.effectiveDownloadRootsFrom(
        defaultRoot: def,
        configuredRoot: '/a',
        pixivRoot: '/b',
      );
      expect(roots.contains(def), isTrue);
    });
  });

  group('dedupeDownloadItemsById · 跨根同 id 去重', () {
    test('同 id 只保留先出现的那个', () {
      final out = OnlineDownloadManager.dedupeDownloadItemsById(<DownloadedItem>[
        _item('pixiv1', name: '先出现的'),
        _item('pixiv1', name: '后出现的'),
      ]);
      expect(out.length, 1);
      expect(out.single.name, '先出现的');
    });

    test('同 id 出现三次仍只留一条', () {
      final out = OnlineDownloadManager.dedupeDownloadItemsById(<DownloadedItem>[
        _item('pixiv1'),
        _item('pixiv1'),
        _item('pixiv1'),
      ]);
      expect(out.length, 1);
    });

    test('不同 id 全部保留，且顺序不变', () {
      final out = OnlineDownloadManager.dedupeDownloadItemsById(<DownloadedItem>[
        _item('pixiv3'),
        _item('pixiv1'),
        _item('pixiv2'),
      ]);
      expect(
        out.map((e) => e.id).toList(),
        <String>['pixiv3', 'pixiv1', 'pixiv2'],
      );
    });

    test('空列表返回空列表', () {
      expect(
        OnlineDownloadManager.dedupeDownloadItemsById(<DownloadedItem>[]),
        isEmpty,
      );
    });

    test('无重复时原样返回（长度与内容都不变）', () {
      final input = <DownloadedItem>[_item('a'), _item('b')];
      final out = OnlineDownloadManager.dedupeDownloadItemsById(input);
      expect(out.length, 2);
      expect(out.map((e) => e.id).toList(), <String>['a', 'b']);
    });
  });
}
