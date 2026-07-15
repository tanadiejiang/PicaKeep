import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/tools/display_result_list_tool.dart';

List<Map<String, dynamic>> _items({
  int count = 12,
  Object? availability = '7页，汉化',
}) =>
    List<Map<String, dynamic>>.generate(
      count,
      (index) => {
        'id': '$index',
        'title': '脱敏标题 $index',
        'author': '作者 $index',
        'coverUrl': '',
        'source': index < 2 ? 'ehentai' : 'nhentai',
        'tags': <String>['fixture'],
        'availability': availability,
      },
    );

void main() {
  const tool = DisplayResultListTool();

  test('schema 完整声明清单条目字段和可用性状态', () {
    final properties = tool.parametersSchema['properties'] as Map;
    final itemSchema = (properties['items'] as Map)['items'] as Map;
    final itemProperties = itemSchema['properties'] as Map;
    final availability = itemProperties['availability'] as Map;

    expect(itemProperties['id'], containsPair('type', 'string'));
    expect(itemProperties['title'], containsPair('type', 'string'));
    expect(itemProperties['tags'], containsPair('type', 'array'));
    expect(availability, containsPair('type', 'object'));
    expect(
        (availability['properties'] as Map).keys,
        containsAll([
          'remoteDownloaded',
          'localDownloaded',
          'favorited',
          'summary',
          'states'
        ]));
    expect(itemSchema['required'], containsAll(['id', 'title']));
  });

  test('字符串 availability、数字 id 和字符串 tags 会成功规范化', () async {
    final result = await tool.execute({
      'items': _items().map((item) {
        final copy = Map<String, dynamic>.from(item);
        copy['id'] = int.parse(copy['id'] as String);
        copy['tags'] = 'fixture';
        return copy;
      }).toList(),
    });

    expect(result.ok, isTrue);
    final data = result.data as Map;
    expect(data['count'], 12);
    expect(data['normalizedCount'], greaterThan(0));
    final output = data['items'] as List;
    expect(output, hasLength(12));
    expect((output.first as Map)['availability'], {'summary': '7页，汉化'});
    expect((output.first as Map)['tags'], ['fixture']);
    expect(jsonEncode(output), isNot(contains('normalizedFields')));
  });

  test('items 为空是非重试零结果', () async {
    final result = await tool.execute({'items': <dynamic>[]});
    expect(result.ok, isTrue);
    final data = result.data as Map;
    expect(data['count'], 0);
    expect(data['noItems'], isTrue);
    expect(data['retryable'], isFalse);
  });

  test('顶层类型错误返回 retryable 脱敏失败', () async {
    final result = await tool.execute({'items': 'not-an-array'});
    expect(result.ok, isFalse);
    final data = result.data as Map;
    expect(data['code'], 'invalid_result_list_items');
    expect(data['retryable'], isTrue);
    expect(data['issues'], isA<List>());
    expect(result.message, isNot(contains('not-an-array')));
  });

  test('关键条目不可恢复时整批失败且不回显原始内容', () async {
    final result = await tool.execute({
      'items': [
        ..._items(count: 1),
        {
          'id': null,
          'title': '敏感原始标题不应回显',
          'coverUrl': 'https://secret.invalid/cover.jpg',
          'tags': ['secret-tag'],
        },
      ],
    });
    expect(result.ok, isFalse);
    final encoded = jsonEncode(result.toJson());
    expect(encoded, isNot(contains('敏感原始标题不应回显')));
    expect(encoded, isNot(contains('secret.invalid')));
    expect(encoded, isNot(contains('secret-tag')));
    expect(encoded, contains('actualType'));
  });
}
