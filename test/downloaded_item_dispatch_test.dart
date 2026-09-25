/// 已下载记录的**反序列化分派**契约测试。
///
/// 真机反馈：本地已下载列表里 Pixiv 的条目**源标签错成别的源、大小显示"未知"**，
/// 但把 download.db 拉下来逐字段看过 —— 数据其实是**完全正确**的
/// （`sourceKey: "pixiv"`、`sourceName: "Pixiv"`、`comicSize: 3.44`、作者也在）。
/// 问题出在读取时的分派：`parseDownloadedItemRecordData` 按 **id 前缀枚举**具体类，
/// 而 Pixiv 的 id 是 `pixiv79837313`（不含 `-`、不匹配任何前缀、不是纯数字、
/// 不是 24 位 hex），一路落到最后的 `ScannedDownloadedComic`（"扫描到的本地漫画"）
/// —— 那个类**不读** `sourceName` / `comicSize`。
///
/// 修法是**优先信数据自带的 `sourceKey`**：它只由 `CustomDownloadedItem.toJson`
/// 写入，其余类的 toJson 都不写这个键。
///
/// 本文件锁两件事：
/// 1. 带 `sourceKey` 的记录（Pixiv / Komiic）必须被解析成自定义源条目**且字段完整**；
/// 2. **不能误伤**其它源 —— 它们的记录里没有 `sourceKey`，必须仍然走各自的分支。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_model.dart';

/// 造一条 `CustomDownloadedItem` 形态的记录（键与 `toJson` 一致）。
Map<String, dynamic> customItemData({
  required String sourceKey,
  required String sourceName,
  double? comicSize = 3.44,
}) =>
    <String, dynamic>{
      'comicSize': comicSize,
      'downloadedEps': <int>[0],
      'chapters': null,
      'id': '${sourceKey}1',
      'name': '标题',
      'subTitle': '作者',
      'tags': <String>[],
      'sourceKey': sourceKey,
      'sourceName': sourceName,
      'cover': '',
      'comicId': '1',
    };

void main() {
  group('带 sourceKey 的记录走自定义源分支', () {
    test('Pixiv 记录被解析成自定义源条目，且名称与大小完整', () {
      const id = 'pixiv79837313';
      final item = parseDownloadedItemRecordData(
        id,
        customItemData(sourceKey: 'pixiv', sourceName: 'Pixiv'),
      );

      expect(item, isA<CustomDownloadedItem>(), reason: '不该落到本地扫描类');
      expect(item!.sourceDisplayName, 'Pixiv', reason: '源标签必须是 Pixiv');
      expect(item.comicSize, closeTo(3.44, 1e-9), reason: '大小不能丢');
      expect(item.subTitle, '作者');
    });

    test('Komiic 记录同样命中（它的 id 前缀也没被枚举过）', () {
      final item = parseDownloadedItemRecordData(
        'komiic12345',
        customItemData(sourceKey: 'Komiic', sourceName: 'Komiic'),
      );

      expect(item, isA<CustomDownloadedItem>());
      expect(item!.sourceDisplayName, 'Komiic');
    });

    test('大写下划线的自定义源也命中', () {
      final item = parseDownloadedItemRecordData(
        'copy_manga123',
        customItemData(sourceKey: 'copy_manga', sourceName: '拷贝漫画'),
      );
      expect(item, isA<CustomDownloadedItem>());
      expect(item!.sourceDisplayName, '拷贝漫画');
    });

    test('comicSize 缺失时保留为 null（让界面显示"未知大小"，而不是伪造 0）', () {
      final item = parseDownloadedItemRecordData(
        'pixiv1',
        customItemData(sourceKey: 'pixiv', sourceName: 'Pixiv', comicSize: null),
      );
      expect(item, isA<CustomDownloadedItem>());
      expect(item!.comicSize, isNull);
    });
  });

  // 这一组是**回归保护**：新分支加在分派最前面，必须确认它不会把别的源抢过来。
  group('没有 sourceKey 的记录仍走原有分支', () {
    test('picacg（24 位 hex + comicId）仍是 DownloadedComic', () {
      final item = parseDownloadedItemRecordData(
        '0123456789abcdef01234567',
        <String, dynamic>{
          'comicId': '0123456789abcdef01234567',
          'title': '哔咔作品',
          'author': '作者',
          'description': '',
          'thumbUrl': '',
          'chapters': <String>[],
          'size': 1.0,
          'downloadedChapters': <int>[],
          'tagList': <String>[],
          'chineseTeam': '',
          'categories': <String>[],
          'sourceTime': '',
        },
      );

      expect(item, isA<DownloadedComic>());
      expect(item, isNot(isA<CustomDownloadedItem>()));
    });

    test('jm 前缀仍是 DownloadedJmComic', () {
      final item = parseDownloadedItemRecordData(
        'jm123456',
        <String, dynamic>{
          'id': 'jm123456',
          'title': '禁漫作品',
          'author': <String>['作者'],
          'chapters': <String, String>{},
          'cover': '',
          'tags': <String>[],
          'eps': <String>[],
          'seriesId': '',
        },
      );
      expect(item, isA<DownloadedJmComic>());
    });

    test('ehentai 画廊 id（含连字符 + galleryTitle）仍是 DownloadedGallery', () {
      final item = parseDownloadedItemRecordData(
        '123456-abc',
        <String, dynamic>{
          'galleryTitle': '画廊',
          'gallery': <String, dynamic>{},
          'id': '123456-abc',
        },
      );
      expect(item, isA<DownloadedGallery>());
      expect(item, isNot(isA<CustomDownloadedItem>()));
    });

    test('无任何特征的 id 仍是本地扫描类（兜底行为不变）', () {
      final item = parseDownloadedItemRecordData(
        '扫到的目录名',
        <String, dynamic>{
          'comicId': '扫到的目录名',
          'title': '本地漫画',
          'author': '',
          'description': '',
          'thumbUrl': '',
          'chapters': <String>[],
          'size': 1.0,
          'downloadedChapters': <int>[],
          'tagList': <String>[],
          'chineseTeam': '',
          'categories': <String>[],
          'sourceTime': '',
        },
      );
      expect(item, isA<ScannedDownloadedComic>());
    });
  });
}
