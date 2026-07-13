import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/tools/get_comic_detail_tool.dart';

void main() {
  group('GetComicDetailTool', () {
    const tool = GetComicDetailTool();

    test('name 与 description 符合只读语义', () {
      expect(tool.name, 'get_comic_detail');
      expect(tool.description, contains('不下载'));
    });

    test('parametersSchema 声明四源 enum 与必填 source/id', () {
      final schema = tool.parametersSchema;
      final properties = schema['properties'] as Map;
      final source = properties['source'] as Map;
      expect(source['enum'], ['picacg', 'jm', 'ehentai', 'nhentai']);
      expect(schema['required'], ['source', 'id']);
    });

    test('execute：非法 source 直接失败，不发起网络请求', () async {
      final result = await tool.execute({'source': 'not-a-source', 'id': '1'});
      expect(result.ok, isFalse);
      expect(result.message, 'unsupported source');
    });

    test('execute：source 缺失时失败', () async {
      final result = await tool.execute({'id': '1'});
      expect(result.ok, isFalse);
      expect(result.message, 'unsupported source');
    });

    test('execute：id 为空时失败，即使 source 合法', () async {
      final result = await tool.execute({'source': 'jm', 'id': '   '});
      expect(result.ok, isFalse);
      expect(result.message, 'id is required');
    });

    test('execute：id 缺失时失败', () async {
      final result = await tool.execute({'source': 'picacg'});
      expect(result.ok, isFalse);
      expect(result.message, 'id is required');
    });
  });

  group('flattenEhTags', () {
    test('按 namespace:tag 拍平，与 Gallery._generateTags 同一约定', () {
      final flattened = flattenEhTags(const {
        'female': ['big breasts'],
        'male': ['glasses'],
      });
      expect(flattened, ['female:big breasts', 'male:glasses']);
    });

    test('空 Map 返回空列表', () {
      expect(flattenEhTags(const {}), isEmpty);
    });

    test('单 namespace 多值全部保留顺序', () {
      final flattened = flattenEhTags(const {
        'artist': ['a', 'b', 'c'],
      });
      expect(flattened, ['artist:a', 'artist:b', 'artist:c']);
    });
  });
}
