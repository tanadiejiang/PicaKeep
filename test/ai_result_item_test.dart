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

  test('非规范字段按条目隔离并生成稳定规范形状', () {
    final report = AiResultItem.decodeToolData({
      'items': [
        {
          'id': 123,
          'title': '数字 ID',
          'author': ['甲', '乙'],
          'coverUrl': null,
          'source': 'eh',
          'tags': '单个标签',
          'availability': '7页，汉化',
        },
        {
          'id': '2',
          'title': 'Map 标签',
          'tags': {
            'artist': ['a', 'b'],
            'language': ['ja'],
          },
          'availability': ['已收藏', 2],
          'source': 'unknown-source',
        },
        {'id': '', 'title': '不可展示'},
      ],
    });

    expect(report.inputCount, 3);
    expect(report.items.length, 3);
    expect(report.discardedCount, 0);
    expect(report.items[0].id, '123');
    expect(report.items[0].author, '甲 / 乙');
    expect(report.items[0].tags, ['单个标签']);
    expect(report.items[0].availability, {'summary': '7页，汉化'});
    expect(report.items[0].source, 'ehentai');
    expect(report.items[1].tags, ['artist: a', 'artist: b', 'language: ja']);
    expect(report.items[1].availability, {
      'states': ['已收藏', '2'],
    });
    expect(report.items[1].source, '');
    expect(report.normalizedFields['availability'], 2);

    final json = report.items.first.toJson();
    expect(
        json.keys,
        containsAll(<String>[
          'id',
          'title',
          'author',
          'coverUrl',
          'source',
          'tags',
          'availability'
        ]));
    expect(AiResultItem.fromJson(json).availability, {'summary': '7页，汉化'});
  });

  test('12 条字符串 availability fixture 全部可恢复', () {
    final fixture = List<Map<String, dynamic>>.generate(12, (index) {
      final isEhentai = index < 2;
      return {
        'id': isEhentai ? 'https://e-hentai.org/g/$index/hash' : '$index',
        'title': '脱敏标题 $index',
        'author': '作者 $index',
        'coverUrl': 'https://example.invalid/$index.jpg',
        'source': isEhentai ? 'ehentai' : 'nhentai',
        'tags': <String>['fixture'],
        'availability': '7页，汉化',
      };
    });

    final report = AiResultItem.decodeToolData({'items': fixture});
    expect(report.items, hasLength(12));
    expect(report.discardedCount, 0);
    expect(
        report.items.every((item) => item.availability['summary'] == '7页，汉化'),
        isTrue);
  });

  test('顶层异常返回脱敏问题而不是抛出', () {
    final report = AiResultItem.decodeToolData({'items': 'not-an-array'});
    expect(report.isValid, isFalse);
    expect(report.topLevelIssue?.field, 'items');
    expect(report.topLevelIssue?.actualType, 'string');
  });

  test('宽松历史解码保留只有 id 或 title 的部分可读条目', () {
    final report = AiResultItem.decodeToolData({
      'items': [
        {'id': 'id-only'},
        {'title': 'title-only'},
        {},
      ],
    });
    expect(report.items, hasLength(2));
    expect(report.discardedCount, 1);
    expect(report.issues, hasLength(4));
  });
}
