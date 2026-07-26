import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/network/soutubot_network/soutubot_signature.dart';

void main() {
  group('calcSoutubotApiKey', () {
    // 5 组期望值由主会话 node/dart 交叉实测锁定（JS 正确基准），逐字节断言。
    // 严禁修改期望值凑答案；实现不符时按计划「跨语言数值格式化」实测表排查。
    test('实测锁定的 5 组签名向量逐字节一致', () {
      expect(
        calcSoutubotApiKey(1785060000, 111, 1234567),
        'AMwcjN0ITMwYzMwITOzQjN4EzM',
      );
      expect(
        calcSoutubotApiKey(1785060000, 120, 0),
        'AMwMDNxADMwYzMwITOzQjN4EzM',
      );
      expect(
        calcSoutubotApiKey(1700000000, 105, 987654321),
        'AMwQTN2YzN4kDMwADMwADM5gjM',
      );
      expect(calcSoutubotApiKey(1, 1, 1), 'wM');
      expect(
        calcSoutubotApiKey(1785060123, 131, 55555),
        'AMwADO0gDNycjM0YTOzQjN4EzM',
      );
    });
  });

  group('jsNumberToString', () {
    test('整数值去掉 .0 后缀', () {
      expect(jsNumberToString(3.0), '3');
      expect(jsNumberToString(0.0), '0');
    });

    test('大数走最短往返（与 JS Number.toString 同族）', () {
      expect(
        jsNumberToString(
            1785060000.0 * 1785060000.0 + 111.0 * 111.0 + 1234567.0),
        '3186439203601246700',
      );
    });

    test('非整数值原样输出', () {
      expect(jsNumberToString(1.5), '1.5');
    });
  });

  group('extractSoutubotGlobalM', () {
    test('从 GLOBAL 对象字面量中抠出 m', () {
      const html = '<script>window.GLOBAL = { foo: "bar", '
          'm: 1234567, other: 1 };</script>';
      expect(extractSoutubotGlobalM(html), 1234567);
    });

    test('无 m 时返回 null', () {
      expect(
        extractSoutubotGlobalM('<html><body>hello world</body></html>'),
        isNull,
      );
    });

    test('GLOBAL 外的干扰 m 不会盖过 GLOBAL 内的值', () {
      const html = '<script>var other = { m: 999 };'
          'window.GLOBAL = { a: 1, m: 42 };</script>';
      expect(extractSoutubotGlobalM(html), 42);
    });

    test('无 GLOBAL 时退回宽松匹配', () {
      const html = '<script>var config = { m: 7, x: 2 };</script>';
      expect(extractSoutubotGlobalM(html), 7);
    });
  });

  group('randomWebKitBoundary', () {
    test('形状为 ----WebKitFormBoundary + 16 位字母数字', () {
      expect(
        randomWebKitBoundary(),
        matches(RegExp(r'^----WebKitFormBoundary[A-Za-z0-9]{16}$')),
      );
    });

    test('可注入 Random(seed) 得到确定产物', () {
      final a = randomWebKitBoundary(Random(42));
      final b = randomWebKitBoundary(Random(42));
      expect(a, b);
      expect(a, matches(RegExp(r'^----WebKitFormBoundary[A-Za-z0-9]{16}$')));
    });
  });

  group('buildSoutubotMultipartBody', () {
    test('产物包含完整的 part 头、factor 字段与结束线', () {
      const boundary = '----WebKitFormBoundaryAAAABBBBCCCCDDDD';
      final imageBytes = [0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x0D, 0x0A];
      final body = buildSoutubotMultipartBody(
        imageBytes: imageBytes,
        boundary: boundary,
      );
      // latin1 逐字节 1:1 解码，二进制图片字节不会被破坏。
      final text = latin1.decode(body);
      expect(text, startsWith('--$boundary\r\n'));
      expect(
        text,
        contains(
            'Content-Disposition: form-data; name="file"; filename="image"\r\n'),
      );
      expect(text, contains('Content-Type: application/octet-stream\r\n\r\n'));
      expect(
        text,
        contains('Content-Disposition: form-data; name="factor"\r\n\r\n1.2\r\n'),
      );
      expect(text, endsWith('--$boundary--\r\n'));
    });

    test('图片字节原样嵌入请求体', () {
      const boundary = '----WebKitFormBoundaryAAAABBBBCCCCDDDD';
      final imageBytes = [0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x0D, 0x0A];
      final body = buildSoutubotMultipartBody(
        imageBytes: imageBytes,
        boundary: boundary,
      );
      // 图片字节紧跟在头部空行之后。
      final headerLength = latin1
          .encode('--$boundary\r\n'
              'Content-Disposition: form-data; name="file"; filename="image"\r\n'
              'Content-Type: application/octet-stream\r\n'
              '\r\n')
          .length;
      expect(
        body.sublist(headerLength, headerLength + imageBytes.length),
        imageBytes,
      );
    });

    test('factor 可覆盖', () {
      const boundary = '----WebKitFormBoundaryAAAABBBBCCCCDDDD';
      final body = buildSoutubotMultipartBody(
        imageBytes: const [1, 2, 3],
        boundary: boundary,
        factor: '2.0',
      );
      expect(latin1.decode(body), contains('\r\n\r\n2.0\r\n'));
    });
  });
}
