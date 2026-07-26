import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/foundation/ai/ocr_client.dart';

/// 15轮03号计划步骤 19：OCR 纯函数测试（不发网络）——
/// extractByOcrPath 取值路径解析、AiOcrConfig 防御式读取与 usable 判定、
/// checkGenericOcrBizCode 业务码前置校验（决策F 修订项）。
void main() {
  group('extractByOcrPath', () {
    test('Umi-OCR 模板：data 直取字符串', () {
      expect(
        extractByOcrPath({'code': 100, 'data': '第一行\n第二行'}, 'data'),
        '第一行\n第二行',
      );
    });

    test('PaddleOCR hub 模板：results[0][*].text 多行 join', () {
      final json = {
        'status': '000',
        'results': [
          [
            {'text': '行1', 'confidence': 0.99},
            {'text': '行2', 'confidence': 0.98},
          ],
        ],
      };
      expect(extractByOcrPath(json, 'results[0][*].text'), '行1\n行2');
    });

    test('PaddleX 模板：result.ocrResults[0].prunedResult.rec_texts[*] 列表 join',
        () {
      final json = {
        'result': {
          'ocrResults': [
            {
              'prunedResult': {
                'rec_texts': ['a', 'b', 'c'],
              },
            },
          ],
        },
      };
      expect(
        extractByOcrPath(
          json,
          'result.ocrResults[0].prunedResult.rec_texts[*]',
        ),
        'a\nb\nc',
      );
    });

    test('路径取不到 / 中途类型不符 / 结果为空 → null', () {
      expect(extractByOcrPath({'data': '文字'}, 'missing'), isNull);
      // String 上取下标：类型不符
      expect(extractByOcrPath({'data': '文字'}, 'data[0]'), isNull);
      // Map 上用 [*]：类型不符
      expect(extractByOcrPath({'data': {'inner': 1}}, 'data[*]'), isNull);
      // 通配展开为空列表
      expect(extractByOcrPath({'items': <Object?>[]}, 'items[*]'), isNull);
      // 下标越界
      expect(extractByOcrPath({'items': ['a']}, 'items[3]'), isNull);
      expect(extractByOcrPath(null, 'data'), isNull);
      expect(extractByOcrPath({'a': 1}, ''), isNull);
    });

    test('非 String 叶子用 toString', () {
      expect(extractByOcrPath({'data': 123}, 'data'), '123');
    });
  });

  group('AiOcrConfig.fromSettings', () {
    tearDown(() {
      appdata.settings[aiOcrConfigSettingIndex] = '{}';
    });

    test("默认 '{}' → 全默认值且不可用", () {
      appdata.settings[aiOcrConfigSettingIndex] = '{}';
      final config = AiOcrConfig.fromSettings();
      expect(config.enabled, isFalse);
      expect(config.type, 'vision');
      expect(config.template, '');
      expect(config.baseUrl, '');
      expect(config.apiKey, '');
      expect(config.modelId, '');
      expect(config.authHeader, '');
      expect(config.imageField, 'base64');
      expect(config.imageEncoding, 'b64');
      expect(config.extraBody, isEmpty);
      expect(config.resultPath, '');
      expect(config.usable, isFalse);
    });

    test('坏 JSON → 防御式回退默认值，不抛异常', () {
      appdata.settings[aiOcrConfigSettingIndex] = 'not-json{{';
      final config = AiOcrConfig.fromSettings();
      expect(config.enabled, isFalse);
      expect(config.type, 'vision');
      expect(config.usable, isFalse);
    });

    test('usable：vision 需 baseUrl+apiKey+modelId；generic 需 baseUrl+imageField+resultPath',
        () {
      appdata.settings[aiOcrConfigSettingIndex] = jsonEncode({
        'enabled': true,
        'type': 'vision',
        'baseUrl': 'http://x',
        'apiKey': 'k',
        'modelId': 'm',
      });
      expect(AiOcrConfig.fromSettings().usable, isTrue);

      appdata.settings[aiOcrConfigSettingIndex] = jsonEncode({
        'enabled': true,
        'type': 'vision',
        'baseUrl': 'http://x',
        'modelId': 'm',
      });
      expect(AiOcrConfig.fromSettings().usable, isFalse); // 缺 apiKey

      appdata.settings[aiOcrConfigSettingIndex] = jsonEncode({
        'enabled': true,
        'type': 'generic',
        'baseUrl': 'http://x',
        'resultPath': 'data',
      });
      // imageField 缺省回退 'base64'，generic 三要素齐 → 可用
      expect(AiOcrConfig.fromSettings().usable, isTrue);

      appdata.settings[aiOcrConfigSettingIndex] = jsonEncode({
        'enabled': true,
        'type': 'generic',
        'baseUrl': 'http://x',
      });
      expect(AiOcrConfig.fromSettings().usable, isFalse); // 缺 resultPath

      appdata.settings[aiOcrConfigSettingIndex] = jsonEncode({
        'enabled': false,
        'type': 'generic',
        'baseUrl': 'http://x',
        'resultPath': 'data',
      });
      expect(AiOcrConfig.fromSettings().usable, isFalse); // 未启用
    });
  });

  group('checkGenericOcrBizCode（决策F 修订）', () {
    test("{'code': 100, 'data': '文字'} → null 放行", () {
      expect(checkGenericOcrBizCode({'code': 100, 'data': '文字'}), isNull);
    });

    test("{'code': 101, 'data': '图中未识别到文字'} → 空结果非错误（关键回归守卫）", () {
      final result =
          checkGenericOcrBizCode({'code': 101, 'data': '图中未识别到文字'});
      expect(result, isNotNull);
      // 关键断言：这段错误描述没有被当成识别文字（text 是空串而不是 data 值）。
      expect(result!.text, '');
      expect(result.error, isNull);
    });

    test("{'code': 102, 'message': '图片格式不支持'} → error 含 102 与 message", () {
      final result =
          checkGenericOcrBizCode({'code': 102, 'message': '图片格式不支持'});
      expect(result, isNotNull);
      expect(result!.error, contains('102'));
      expect(result.error, contains('图片格式不支持'));
      expect(result.text, isNull);
    });

    test("{'code': 102}（无 message）→ 带 error，不抛异常", () {
      final result = checkGenericOcrBizCode({'code': 102});
      expect(result, isNotNull);
      expect(result!.error, contains('102'));
    });

    test('顶层无整型 code（PaddleOCR hub 形态）→ null 放行（兼容性守卫）', () {
      expect(
        checkGenericOcrBizCode({'status': '000', 'results': <Object?>[]}),
        isNull,
      );
    });
  });
}
