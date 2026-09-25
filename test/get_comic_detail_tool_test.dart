import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_sources.dart';
import 'package:picakeep/foundation/ai/tools/get_comic_detail_tool.dart';

void main() {
  group('GetComicDetailTool', () {
    const tool = GetComicDetailTool();

    test('name 与 description 符合只读语义', () {
      expect(tool.name, 'get_comic_detail');
      expect(tool.description, contains('不下载'));
    });

    test('parametersSchema 声明全部在线源 enum 与必填 source/id', () {
      final schema = tool.parametersSchema;
      final properties = schema['properties'] as Map;
      final source = properties['source'] as Map;
      // 第十八轮起为六源（追加 pixiv / komiic）。顺序也一并锁住：
      // 顺序会直接体现在模型看到的 enum 里，改动应当是有意的。
      expect(
        source['enum'],
        ['picacg', 'jm', 'ehentai', 'nhentai', 'pixiv', 'komiic'],
      );
      expect(schema['required'], ['source', 'id']);
    });

    test('schema enum 必须覆盖 aiSources 全集（新增源时同步，防漏加）', () {
      // 这条是防"加了源却忘了进 schema"的护栏：两者不一致时模型无法选择新源。
      final source =
          (tool.parametersSchema['properties'] as Map)['source'] as Map;
      expect((source['enum'] as List).toSet(), aiSources);
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
