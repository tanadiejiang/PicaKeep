import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_attachments.dart';
import 'package:picakeep/foundation/ai/llm_client.dart';
import 'package:picakeep/foundation/app.dart';

/// 15轮03号计划步骤 19：LlmMessage.toRequestJson()（请求出口）与
/// stripImagesToPlaceholder()（决策B 瘦身）的形状断言。
///
/// 真实 1×1 透明 PNG（67 字节），落到临时附件目录供 toRequestJson 现场读取。
const _png1x1 = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
];

void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('llm_request_json_test_');
    App.dataPath = tempDir.path;
    final file = File(resolveAiAttachmentPath('conv-req/img.png'));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(_png1x1);
  });

  tearDownAll(() {
    tempDir.deleteSync(recursive: true);
  });

  test('imagePaths 空 → toRequestJson 与 toJson 完全相等', () async {
    final user = LlmMessage.user('纯文本');
    expect(await user.toRequestJson(), user.toJson());
    final tool = LlmMessage.tool(
      toolCallId: 'id1',
      name: 'tool',
      content: '{}',
    );
    expect(await tool.toRequestJson(), tool.toJson());
    final system = LlmMessage.system('系统');
    expect(await system.toRequestJson(), system.toJson());
  });

  test('imagePaths 非空 → content 展开为 parts 数组，图片为 base64 data URI',
      () async {
    final msg = LlmMessage.user('看图', imagePaths: const ['conv-req/img.png']);
    final json = await msg.toRequestJson();
    expect(json['role'], 'user');
    final parts = json['content'] as List;
    expect(parts, hasLength(2));
    expect(parts[0], {'type': 'text', 'text': '看图'});
    final imagePart = parts[1] as Map;
    expect(imagePart['type'], 'image_url');
    final url = (imagePart['image_url'] as Map)['url'] as String;
    expect(url, startsWith('data:image/png;base64,'));
    expect(url, 'data:image/png;base64,${base64Encode(_png1x1)}');
  });

  test('文件缺失 → 产出占位文本 part，不抛异常', () async {
    final msg =
        LlmMessage.user('看图', imagePaths: const ['conv-req/missing.png']);
    final json = await msg.toRequestJson();
    final parts = json['content'] as List;
    expect(parts, hasLength(2));
    expect((parts[1] as Map)['type'], 'text');
    expect((parts[1] as Map)['text'], contains('图片文件缺失'));
  });

  test('stripImagesToPlaceholder 幂等稳定；无图消息返回同一实例', () {
    final msg = LlmMessage.user(
      '看图',
      imagePaths: const ['a/x.jpg', 'a/y.jpg'],
    );
    final first = msg.stripImagesToPlaceholder();
    final second = msg.stripImagesToPlaceholder();
    // 同一消息调两次产出逐字节相同 content（决策B 契约：占位符必须稳定，
    // 否则破坏 DeepSeek 前缀缓存）。
    expect(first.content, second.content);
    expect(first.content, '看图${LlmMessage.imagePlaceholder(2)}');
    expect(first.imagePaths, isEmpty);
    expect(first.role, 'user');

    final plain = LlmMessage.user('纯文本');
    expect(identical(plain.stripImagesToPlaceholder(), plain), isTrue);
  });
}
