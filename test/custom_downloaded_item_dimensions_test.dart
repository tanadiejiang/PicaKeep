import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_model.dart';

CustomDownloadedItem _item({int? width, int? height}) => CustomDownloadedItem(
      id: 'pixiv79837313',
      name: '标题',
      subTitle: '作者',
      tags: const <String>['tagA', 'tagB'],
      sourceKey: 'pixiv',
      sourceName: 'Pixiv',
      cover: '/tmp/cover.jpg',
      comicId: '79837313',
      downloadedEps: const <int>[0],
      width: width,
      height: height,
    );

void main() {
  group('CustomDownloadedItem · 宽高序列化', () {
    test('toJson 含 width / height 键', () {
      final json = _item(width: 1200, height: 1600).toJson();
      expect(json.containsKey('width'), isTrue);
      expect(json.containsKey('height'), isTrue);
      expect(json['width'], 1200);
      expect(json['height'], 1600);
    });

    test('fromJson 能读回宽高', () {
      final back = CustomDownloadedItem.fromJson(
        _item(width: 1200, height: 1600).toJson(),
      );
      expect(back.width, 1200);
      expect(back.height, 1600);
    });

    test('老记录缺这两个键时是 null，而不是 0', () {
      // 0 会被列表当成"比例为 0"算出错误高度；null 才能让消费侧走占位分支。
      final json = _item().toJson();
      json.remove('width');
      json.remove('height');
      final back = CustomDownloadedItem.fromJson(json);
      expect(back.width, isNull);
      expect(back.height, isNull);
    });

    test('值为 null 时写出的键也是 null，读回仍是 null', () {
      final json = _item(width: null, height: null).toJson();
      expect(json['width'], isNull);
      expect(json['height'], isNull);
      expect(CustomDownloadedItem.fromJson(json).width, isNull);
    });

    test('经 JSON 字符串往返后仍是整数（不退化成 double）', () {
      final encoded = jsonEncode(_item(width: 1200, height: 1600).toJson());
      final back = CustomDownloadedItem.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );
      expect(back.width, isA<int>());
      expect(back.height, isA<int>());
      expect(back.width, 1200);
      expect(back.height, 1600);
    });

    test('整型以 double 形态传入时也能读回整数（JSON 往返的常见退化）', () {
      final json = _item(width: 100, height: 200).toJson();
      json['width'] = 100.0;
      json['height'] = 200.0;
      final back = CustomDownloadedItem.fromJson(json);
      expect(back.width, 100);
      expect(back.height, 200);
    });

    test('完整往返后其它字段不受新增键影响', () {
      final original = _item(width: 800, height: 600);
      final back = CustomDownloadedItem.fromJson(original.toJson());
      expect(back.id, original.id);
      expect(back.name, original.name);
      expect(back.subTitle, original.subTitle);
      expect(back.tags, original.tags);
      expect(back.sourceKey, original.sourceKey);
      expect(back.sourceName, original.sourceName);
      expect(back.comicId, original.comicId);
      expect(back.downloadedEps, original.downloadedEps);
      expect(back.width, original.width);
      expect(back.height, original.height);
    });

    test('只给宽度不给高度时互不影响', () {
      final back = CustomDownloadedItem.fromJson(_item(width: 640).toJson());
      expect(back.width, 640);
      expect(back.height, isNull);
    });
  });
}
