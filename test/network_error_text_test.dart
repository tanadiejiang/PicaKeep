/// 网络错误文案的契约测试。
///
/// 真机反馈：Komiic 登录失败时界面直接显示了 dio 的原始英文异常
/// （"The connection errored: Connection reset by peer / This indicates an
/// error which most likely cannot be solved by the library."），用户既看不懂
/// 也不知道下一步该做什么。
///
/// 这里锁两件事：
/// 1. 每种常见网络故障都要翻成**中文且带行动建议**的提示；
/// 2. 认不出的异常要**保留原始信息**兜底，绝不能变成一句没有信息量的套话。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/network/network_error_text.dart';

/// 构造一个与 dio 实际抛出形态一致的连接错误。
DioException _connectionError(String message) => DioException(
      requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.connectionError,
      error: const SocketException('Connection reset by peer'),
      message: 'The connection errored: $message',
    );

void main() {
  group('常见网络故障翻成可操作的中文', () {
    test('连接被重置 → 提到网络阻断/代理，并给出设置入口', () {
      final text = describeNetworkError(
        _connectionError('Connection reset by peer'),
        host: 'komiic.com',
      );
      expect(text, contains('连接被中断'));
      expect(text, contains('komiic.com'));
      expect(text, contains('代理'));
      expect(text, contains('设置'));
      // 不能把 dio 的英文原文直接丢给用户。
      expect(text.contains('most likely cannot be solved'), isFalse);
    });

    test('连接超时', () {
      final text = describeNetworkError(
        DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.connectionTimeout,
          message: 'The request connection took longer than 0:00:15',
        ),
        host: 'example.com',
      );
      expect(text, contains('超时'));
      expect(text, contains('example.com'));
    });

    test('域名解析失败', () {
      final text = describeNetworkError(
        const SocketException('Failed host lookup: \'komiic.com\''),
        host: 'komiic.com',
      );
      expect(text, contains('域名解析失败'));
    });

    test('TLS 握手失败', () {
      final text = describeNetworkError(
        const HandshakeException('Handshake error in client'),
        host: 'komiic.com',
      );
      expect(text, contains('TLS 握手'));
    });

    test('连接被拒绝 → 提示代理地址或端口可能填错', () {
      final text = describeNetworkError(
        const SocketException('Connection refused'),
        host: '192.168.1.2',
      );
      expect(text, contains('连接被拒绝'));
      expect(text, contains('端口'));
    });

    test('网络不可达', () {
      final text = describeNetworkError(
        const SocketException('Network is unreachable'),
        host: 'komiic.com',
      );
      expect(text, contains('网络不可达'));
    });
  });

  group('兜底行为', () {
    test('认不出的异常保留原始信息，不退化成套话', () {
      final text = describeNetworkError(
        StateError('some unexpected failure'),
        host: 'example.com',
      );
      expect(text, contains('some unexpected failure'));
    });

    test('未提供 host 时用中性说法，不出现空字符串', () {
      final text = describeNetworkError(
        _connectionError('Connection reset by peer'),
      );
      expect(text, contains('目标站点'));
      expect(text.contains('到 的'), isFalse);
    });
  });

  group('原始信息提取', () {
    test('优先取内层 SocketException，而不是 dio 的包装文案', () {
      final raw = networkErrorRawMessage(
        _connectionError('Connection reset by peer'),
      );
      expect(raw, contains('Connection reset by peer'));
      // dio 的包装前缀不该出现在"原始信息"里。
      expect(raw.startsWith('The connection errored'), isFalse);
    });

    test('没有内层异常时退回 message', () {
      final raw = networkErrorRawMessage(
        DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.badResponse,
          message: 'bad response',
        ),
      );
      expect(raw, 'bad response');
    });

    test('普通异常直接用 toString', () {
      expect(networkErrorRawMessage(StateError('boom')), contains('boom'));
    });
  });
}
