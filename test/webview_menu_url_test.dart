import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/online_comic/webview.dart';

void main() {
  group('webviewFullUrl', () {
    test('返回完整 URL 而非 path 分量', () {
      final url = WebUri('https://soutubot.moe/search?q=1');
      expect(webviewFullUrl(url), 'https://soutubot.moe/search?q=1');
      // 回归守卫：历史 bug 是取 .path，只会得到 "/search"
      expect(url.path, isNot(equals(webviewFullUrl(url))));
    });

    test('站点根路径不退化成斜杠', () {
      expect(
        webviewFullUrl(WebUri('https://soutubot.moe/')),
        'https://soutubot.moe/',
      );
    });

    test('null 与空串返回 null', () {
      expect(webviewFullUrl(null), isNull);
      expect(webviewFullUrl(WebUri('')), isNull);
    });
  });
}
