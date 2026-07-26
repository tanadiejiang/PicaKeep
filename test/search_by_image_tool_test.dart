import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_tool.dart';
import 'package:picakeep/foundation/ai/tools/search_by_image_tool.dart';

/// 15轮05号计划步骤 17：search_by_image 工具的非网络分支。
/// 网络/CF 过盾分支不进单测（依赖真实 soutubot 接口与 webview），转人工验收。
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
      expect(properties.keys, ['image_ref']);
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
}
