import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_tool.dart';
import 'package:picakeep/foundation/ai/tools/search_by_image_tool.dart';
import 'package:picakeep/network/soutubot_network/soutubot_models.dart';

/// 15轮05号计划步骤 17：search_by_image 工具的非网络分支。
/// 网络/CF 过盾分支不进单测（依赖真实 soutubot 接口与 webview），转人工验收。
///
/// 15轮08号计划：新增阈值(15)/fallback/include_all_results/hidden_count 的
/// 结果构造分支，走 `buildResult`（网络之后的纯函数段）直接断言。
void main() {
  group('SearchByImageTool', () {
    const tool = SearchByImageTool();

    test('name/description/schema 符合协议', () {
      expect(tool.name, 'search_by_image');
      expect(tool.description, contains('以图搜源'));
      expect(tool.description, contains('soutubot'));
      final schema = tool.parametersSchema;
      expect(schema['required'], ['image_ref']);
      final properties = schema['properties'] as Map;
      expect(properties.keys, ['image_ref', 'include_all_results']);
      final includeAll = properties['include_all_results'] as Map;
      expect(includeAll['type'], 'boolean');
      expect(includeAll['description'], contains('15%'));
    });

    test('execute({})：image_ref 缺失直接失败', () async {
      final result = await tool.execute({});
      expect(result.ok, isFalse);
      expect(result.message, contains('image_ref is required'));
    });

    test('image_ref 为空白字符串同样失败', () async {
      final result = await tool.execute({'image_ref': '   '});
      expect(result.ok, isFalse);
      expect(result.message, contains('image_ref is required'));
    });

    test('无 resolver（调试页直连语境）：失败且提示附件语境', () async {
      final result = await tool.executeWithContext(
        {'image_ref': 'x'},
        const AiToolExecutionContext(operationId: 't'),
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('附件'));
    });

    test('resolver 返回 null（白名单外 ref）：失败且提示不存在或已过期', () async {
      final result = await tool.executeWithContext(
        {'image_ref': 'other-conversation/x.jpg'},
        AiToolExecutionContext(
          operationId: 't',
          resolveAttachmentPath: (_) => null,
        ),
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('不存在或已过期'));
    });

    test('resolver 指向不存在文件：失败（不发网络请求）', () async {
      final missingPath =
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'picakeep_search_by_image_missing_${DateTime.now().microsecondsSinceEpoch}.jpg';
      final result = await tool.executeWithContext(
        {'image_ref': 'conv/x.jpg'},
        AiToolExecutionContext(
          operationId: 't',
          resolveAttachmentPath: (_) => missingPath,
        ),
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('已被清理'));
    });
  });

  group('SearchByImageTool.buildResult（15轮08号计划）', () {
    const tool = SearchByImageTool();

    SoutubotSearchItem item(double similarity, {String title = 't'}) {
      return SoutubotSearchItem(
        source: 'nhentai',
        page: 1,
        title: title,
        language: 'jp',
        pagePath: '/g/1/1',
        subjectPath: '/g/480041',
        previewImageUrl: 'https://example.com/p.jpg',
        similarity: similarity,
      );
    }

    SoutubotSearchResult resultOf(List<SoutubotSearchItem> items) {
      return SoutubotSearchResult(
        items: items,
        id: '2025102006392555',
        factor: 1,
        imageUrl: 'https://example.com/q.jpg',
        searchOption: null,
        executionTime: 1,
      );
    }

    Map<String, Object?> dataOf(AiToolResult r) =>
        r.data! as Map<String, Object?>;

    List<Object?> itemsOf(AiToolResult r) => dataOf(r)['items']! as List;

    test('零条目：success + 空列表 + hidden_count 0', () {
      final r = tool.buildResult(resultOf(const []));
      expect(r.ok, isTrue);
      expect(itemsOf(r), isEmpty);
      expect(dataOf(r)['hidden_count'], 0);
      expect(dataOf(r)['search_id'], '2025102006392555');
      expect(r.message, contains('未找到任何相似结果'));
    });

    test('阈值降到 15：20% 条目不再被过滤', () {
      final r = tool.buildResult(resultOf([item(20)]));
      expect(r.ok, isTrue);
      expect(itemsOf(r), hasLength(1));
      expect(dataOf(r)['hidden_count'], 0);
      expect(dataOf(r)['top_similarity'], 20);
      // 20 < 45，low_confidence 仍生效（_lowConfidenceBelow 未变）。
      expect(dataOf(r)['low_confidence'], isTrue);
      expect(r.message, contains('最高相似度仅 20%'));
    });

    test('恰好 15% 计入展示（边界含等号）', () {
      final r = tool.buildResult(resultOf([item(15)]));
      expect(itemsOf(r), hasLength(1));
      expect(dataOf(r)['hidden_count'], 0);
    });

    test('全部 <15%：fallback 自动展示全部，hidden_count 0', () {
      final r = tool.buildResult(resultOf([item(10), item(3)]));
      expect(r.ok, isTrue);
      expect(itemsOf(r), hasLength(2));
      expect(dataOf(r)['hidden_count'], 0);
      expect(dataOf(r)['top_similarity'], 10);
      expect(dataOf(r)['low_confidence'], isTrue);
      expect(r.message, contains('已自动展示全部 2 条'));
      expect(r.message, contains('可靠性极低'));
      // fallback 下不得出现「另有 N 条」提示。
      expect(r.message, isNot(contains('另有')));
    });

    test('kept 非空 + 有隐藏条目：hidden_count>0 且 message 含「另有 N 条」', () {
      final r = tool.buildResult(resultOf([item(88), item(10), item(4)]));
      expect(itemsOf(r), hasLength(1));
      expect(dataOf(r)['hidden_count'], 2);
      expect(dataOf(r)['top_similarity'], 88);
      expect(dataOf(r)['low_confidence'], isFalse);
      expect(r.message, contains('另有 2 条'));
      expect(r.message, contains('include_all_results=true'));
    });

    test('低置信 + 隐藏条目：两段 message 拼接', () {
      final r = tool.buildResult(resultOf([item(30), item(9)]));
      expect(dataOf(r)['hidden_count'], 1);
      expect(r.message, contains('最高相似度仅 30%'));
      expect(r.message, contains('另有 1 条'));
    });

    test('include_all_results=true：取回全部且 hidden_count 归零', () {
      final all = resultOf([item(88), item(10), item(4)]);
      final r = tool.buildResult(all, includeAll: true);
      expect(itemsOf(r), hasLength(3));
      expect(dataOf(r)['hidden_count'], 0);
      expect(dataOf(r)['top_similarity'], 88);
      expect(dataOf(r)['low_confidence'], isFalse);
      // 置信度正常且已全量 → 无需额外说明。
      expect(r.message, isNull);
    });

    test('include_all_results=true 且低置信：仍给出 low_confidence 警告', () {
      final r = tool.buildResult(
        resultOf([item(20), item(5)]),
        includeAll: true,
      );
      expect(itemsOf(r), hasLength(2));
      expect(dataOf(r)['hidden_count'], 0);
      expect(dataOf(r)['low_confidence'], isTrue);
      expect(r.message, contains('最高相似度仅 20%'));
      expect(r.message, isNot(contains('另有')));
      // includeAll 不是 fallback，不应声明「自动展示」。
      expect(r.message, isNot(contains('自动展示')));
    });

    test('include_all_results=true 但本就零条目：仍是空列表 success', () {
      final r = tool.buildResult(resultOf(const []), includeAll: true);
      expect(r.ok, isTrue);
      expect(itemsOf(r), isEmpty);
      expect(dataOf(r)['hidden_count'], 0);
    });

    test('top_similarity 取最大值而非首条', () {
      final r = tool.buildResult(resultOf([item(20), item(70), item(50)]));
      expect(dataOf(r)['top_similarity'], 70);
      expect(dataOf(r)['low_confidence'], isFalse);
      expect(r.message, isNull);
    });
  });
}
