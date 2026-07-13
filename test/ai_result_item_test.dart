import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_result_item.dart';

void main() {
  group('AiResultItem.fromJson source 归一化', () {
    test('别名 source 会被归一化为标准值', () {
      final eh = AiResultItem.fromJson(const {
        'id': '1',
        'title': 't',
        'author': 'a',
        'coverUrl': '',
        'source': 'eh',
        'tags': <String>[],
      });
      expect(eh.source, 'ehentai');

      final ehUpper = AiResultItem.fromJson(const {
        'id': '2',
        'title': 't',
        'author': 'a',
        'coverUrl': '',
        'source': 'E-Hentai',
        'tags': <String>[],
      });
      expect(ehUpper.source, 'ehentai');

      final nh = AiResultItem.fromJson(const {
        'id': '3',
        'title': 't',
        'author': 'a',
        'coverUrl': '',
        'source': 'nh',
        'tags': <String>[],
      });
      expect(nh.source, 'nhentai');
    });

    test('缺失 source 字段时归一化为空字符串，不抛异常', () {
      final item = AiResultItem.fromJson(const {
        'id': '1',
        'title': 't',
        'author': 'a',
        'coverUrl': '',
        'tags': <String>[],
      });
      expect(item.source, '');
    });

    test('非法 source 值归一化为空字符串', () {
      final item = AiResultItem.fromJson(const {
        'id': '1',
        'title': 't',
        'author': 'a',
        'coverUrl': '',
        'source': 'not-a-real-source',
        'tags': <String>[],
      });
      expect(item.source, '');
    });

    test('合法标准值原样保留', () {
      final item = AiResultItem.fromJson(const {
        'id': '1',
        'title': 't',
        'author': 'a',
        'coverUrl': '',
        'source': 'picacg',
        'tags': <String>[],
      });
      expect(item.source, 'picacg');
    });
  });
}
