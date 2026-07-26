import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/balance_client.dart';

/// 15轮06号计划：余额查询纯函数测试（端点推导 / provider 分派 / 响应解析 /
/// 失败分类 / 展示格式化），不发真网络。
void main() {
  group('provider 分派与端点推导', () {
    test('DeepSeek 四种 baseUrl 形态都推出 /user/balance（不带 /v1）', () {
      for (final url in const [
        'https://api.deepseek.com',
        'https://api.deepseek.com/',
        'https://api.deepseek.com/v1',
        'https://api.deepseek.com/v1/chat/completions',
      ]) {
        final provider = AiBalanceClient.resolveProvider(url, 'deepseek');
        expect(provider, AiBalanceProvider.deepseek, reason: url);
        expect(AiBalanceClient.balanceEndpoint(provider, url),
            'https://api.deepseek.com/user/balance',
            reason: url);
      }
    });

    test('Kimi / SiliconFlow 端点', () {
      final kimi = AiBalanceClient.resolveProvider(
          'https://api.moonshot.cn/v1', 'custom');
      expect(kimi, AiBalanceProvider.kimi);
      expect(
          AiBalanceClient.balanceEndpoint(kimi, 'https://api.moonshot.cn/v1'),
          'https://api.moonshot.cn/v1/users/me/balance');

      final sf = AiBalanceClient.resolveProvider(
          'https://api.siliconflow.cn/v1', 'custom');
      expect(sf, AiBalanceProvider.siliconflow);
      expect(
          AiBalanceClient.balanceEndpoint(sf, 'https://api.siliconflow.cn/v1'),
          'https://api.siliconflow.cn/v1/user/info');
    });

    test('不支持域名短路为 unsupported（连端点都不给）', () {
      for (final url in const [
        'https://api.openai.com/v1',
        'https://open.bigmodel.cn/api/paas/v4',
        'https://dashscope.aliyuncs.com/compatible-mode/v1',
      ]) {
        final provider = AiBalanceClient.resolveProvider(url, 'openai');
        expect(provider, AiBalanceProvider.unsupported, reason: url);
        expect(AiBalanceClient.balanceEndpoint(provider, url), isEmpty);
      }
    });

    test('未知域名走中转站兜底', () {
      final provider = AiBalanceClient.resolveProvider(
          'https://relay.example.com/v1', 'custom');
      expect(provider, AiBalanceProvider.relay);
      expect(
        AiBalanceClient.balanceEndpoint(
            provider, 'https://relay.example.com/v1'),
        'https://relay.example.com/dashboard/billing/subscription',
      );
    });
  });

  group('响应解析', () {
    test('DeepSeek 字符串金额转 double', () {
      final result = AiBalanceClient.parseDeepseek(const {
        'is_available': true,
        'balance_infos': [
          {
            'currency': 'CNY',
            'total_balance': '110.00',
            'granted_balance': '0.00',
            'topped_up_balance': '110.00',
          }
        ],
      });
      expect(result.status, AiBalanceStatus.ok);
      expect(result.amount, 110.0);
      expect(result.currency, 'CNY');
    });

    test('DeepSeek balance_infos 空数组 → unsupported 不崩', () {
      final result =
          AiBalanceClient.parseDeepseek(const {'balance_infos': <Object>[]});
      expect(result.status, AiBalanceStatus.unsupported);
    });

    test('DeepSeek is_available=false 仍展示金额', () {
      final result = AiBalanceClient.parseDeepseek(const {
        'is_available': false,
        'balance_infos': [
          {'currency': 'CNY', 'total_balance': '0.00'}
        ],
      });
      expect(result.status, AiBalanceStatus.ok);
      expect(result.amount, 0.0);
    });

    test('Kimi 数字金额', () {
      final result = AiBalanceClient.parseKimi(const {
        'data': {'available_balance': 49.58894}
      });
      expect(result.status, AiBalanceStatus.ok);
      expect(result.display, '¥49.59');
    });

    test('SiliconFlow 字符串金额', () {
      final result = AiBalanceClient.parseSiliconFlow(const {
        'data': {'totalBalance': '88.88'}
      });
      expect(result.status, AiBalanceStatus.ok);
      expect(result.amount, 88.88);
      expect(result.currency, 'CNY');
    });

    test('缺字段一律 unsupported', () {
      expect(AiBalanceClient.parseKimi(const {}).status,
          AiBalanceStatus.unsupported);
      expect(AiBalanceClient.parseSiliconFlow(const {'data': {}}).status,
          AiBalanceStatus.unsupported);
      expect(AiBalanceClient.parseDeepseek('html page').status,
          AiBalanceStatus.unsupported);
    });

    test('中转站：total_usage 单位是美分', () {
      final result = AiBalanceClient.parseRelay(
        const {'hard_limit_usd': 10.0},
        const {'total_usage': 250.0},
      );
      expect(result.status, AiBalanceStatus.ok);
      expect(result.amount, closeTo(7.5, 1e-9));
      expect(result.currency, 'USD');
    });

    test('中转站缺字段 → unsupported', () {
      expect(
        AiBalanceClient.parseRelay(const {}, const {'total_usage': 1}).status,
        AiBalanceStatus.unsupported,
      );
      expect(
        AiBalanceClient.parseRelay(const {'hard_limit_usd': 1}, const {})
            .status,
        AiBalanceStatus.unsupported,
      );
    });
  });

  group('display 格式化', () {
    test('CNY / USD / 未知币种 / 非 ok', () {
      expect(const AiBalanceResult.ok(110.0, 'CNY').display, '¥110.00');
      expect(const AiBalanceResult.ok(7.5, 'USD').display, '\$7.50');
      expect(const AiBalanceResult.ok(110.0, 'XXX').display, '110.00 XXX');
      expect(const AiBalanceResult.ok(110.0, null).display, '110.00');
      expect(const AiBalanceResult.unsupported().display, isEmpty);
      expect(const AiBalanceResult.error('x').display, isEmpty);
    });
  });

  group('失败分类', () {
    test('200 → null（继续解析）', () {
      expect(AiBalanceClient.classifyFailure(200, const {}), isNull);
    });

    test('401/403 → error；含 session key 字样 → unsupported', () {
      expect(AiBalanceClient.classifyFailure(401, const {})?.status,
          AiBalanceStatus.error);
      expect(AiBalanceClient.classifyFailure(403, null)?.status,
          AiBalanceStatus.error);
      expect(
        AiBalanceClient.classifyFailure(401, const {
          'error': {'message': 'You must provide a session key'}
        })?.status,
        AiBalanceStatus.unsupported,
      );
    });

    test('404/405 → unsupported', () {
      expect(AiBalanceClient.classifyFailure(404, null)?.status,
          AiBalanceStatus.unsupported);
      expect(AiBalanceClient.classifyFailure(405, null)?.status,
          AiBalanceStatus.unsupported);
    });

    test('5xx / 无状态码（超时）→ error', () {
      expect(AiBalanceClient.classifyFailure(500, null)?.status,
          AiBalanceStatus.error);
      expect(AiBalanceClient.classifyFailure(null, null)?.status,
          AiBalanceStatus.error);
    });

    test('200 但返回 HTML → asJsonMap 为 null（调用方按 unsupported 处理）', () {
      expect(AiBalanceClient.asJsonMap('<html>login</html>'), isNull);
      expect(AiBalanceClient.asJsonMap('{"a":1}'), {'a': 1});
      expect(AiBalanceClient.asJsonMap(const {'a': 1}), {'a': 1});
    });
  });

  group('parseAmount', () {
    test('字符串 / 数字 / 脏值', () {
      expect(AiBalanceClient.parseAmount('110.00'), 110.0);
      expect(AiBalanceClient.parseAmount(49.58894), closeTo(49.58894, 1e-9));
      expect(AiBalanceClient.parseAmount(7), 7.0);
      expect(AiBalanceClient.parseAmount('abc'), isNull);
      expect(AiBalanceClient.parseAmount(null), isNull);
    });
  });
}
