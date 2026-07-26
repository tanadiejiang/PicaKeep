import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/model_list_client.dart';

/// 15轮06号计划：模型列表客户端纯函数测试（端点推导 + 响应解析，不发网络）。
void main() {
  group('modelsEndpoint', () {
    test('裸域名', () {
      expect(ModelListClient.modelsEndpoint('https://api.deepseek.com'),
          'https://api.deepseek.com/models');
    });

    test('带 /v1', () {
      expect(ModelListClient.modelsEndpoint('https://api.openai.com/v1'),
          'https://api.openai.com/v1/models');
    });

    test('带尾斜杠（多个也吃掉）', () {
      expect(ModelListClient.modelsEndpoint('http://localhost:11434/v1//'),
          'http://localhost:11434/v1/models');
    });

    test('误填完整 chat 端点也能推导', () {
      expect(
        ModelListClient.modelsEndpoint(
            'https://api.deepseek.com/v1/chat/completions'),
        'https://api.deepseek.com/v1/models',
      );
    });

    test('已含 /models 原样返回', () {
      expect(ModelListClient.modelsEndpoint('https://api.deepseek.com/models'),
          'https://api.deepseek.com/models');
    });
  });

  group('parseModels', () {
    test('标准响应（DeepSeek 无 created 字段）', () {
      final models = ModelListClient.parseModels(const {
        'object': 'list',
        'data': [
          {
            'id': 'deepseek-v4-flash',
            'object': 'model',
            'owned_by': 'deepseek'
          },
          {'id': 'deepseek-v4-pro', 'object': 'model', 'owned_by': 'deepseek'},
        ],
      });
      expect(models, ['deepseek-v4-flash', 'deepseek-v4-pro']);
    });

    test('data 缺失 / data 非 List / 根非 Map → 空列表', () {
      expect(ModelListClient.parseModels(const {'object': 'list'}), isEmpty);
      expect(ModelListClient.parseModels(const {'data': 'oops'}), isEmpty);
      expect(ModelListClient.parseModels('not a map'), isEmpty);
      expect(ModelListClient.parseModels(null), isEmpty);
    });

    test('data 为空数组 → 空列表', () {
      expect(ModelListClient.parseModels(const {'data': []}), isEmpty);
    });

    test('非 Map 元素与空 id 被跳过', () {
      final models = ModelListClient.parseModels(const {
        'data': [
          'oops',
          {'id': ''},
          {'object': 'model'},
          {'id': 'ok'},
        ],
      });
      expect(models, ['ok']);
    });

    test('重复 id 保序去重', () {
      final models = ModelListClient.parseModels(const {
        'data': [
          {'id': 'b'},
          {'id': 'a'},
          {'id': 'b'},
        ],
      });
      expect(models, ['b', 'a']);
    });
  });
}
