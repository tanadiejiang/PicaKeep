/// Pixiv 缩略图 URL 改写的契约（36 号）。
///
/// ## 为什么需要改写
///
/// 作者页要改成瀑布流，而响应给的封面是**方形裁切**缩略图
/// （`/c/250x250_80_a2/…_square1200.jpg`）。方图排进瀑布流只有两种结果：
/// 每格都按 1:1（退化成方格墙），或者按真实比例画再 `cover` 裁掉一部分。
///
/// 改写规则是**实测**出来的（宿主机直连 `i.pximg.net`）：
///
/// | URL | 输出 | 比例 |
/// |---|---|---|
/// | `c/250x250_80_a2/…_square1200.jpg` | 250×250 | 1.00 |
/// | `c/250x250_80_a2/…_master1200.jpg` | 250×250 | 1.00（前缀强制方框） |
/// | `c/480x960/…_square1200.jpg` | 480×480 | 1.00 |
/// | **`c/360x360_70/…_master1200.jpg`** | **270×360** | **0.75** |
///
/// 所以**前缀与文件名必须一起换** —— 这条用例把"两处都换"钉住：
/// 只换其一是最容易出现的半成品，而且症状只是"图比例还是不对"，
/// 不会报错。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';

const String _squareUrl = 'https://i.pximg.net/c/250x250_80_a2/img-master/img/'
    '2026/09/26/11/42/32/150120670_p0_square1200.jpg';

void main() {
  group('方图缩略图 → 保持比例的缩略图', () {
    test('前缀与文件名一起换掉', () {
      final result = pixivProportionalThumbUrl(_squareUrl);
      expect(result, contains('/c/$kPixivProportionalThumbFrame/'));
      expect(result, contains('_p0_master1200.jpg'));
      expect(result, isNot(contains('_square1200')));
      expect(result, isNot(contains('250x250_80_a2')));
    });

    test('只换文件名不够（回归守卫：前缀必须也换）', () {
      // 实测过 `c/250x250_80_a2/…_master1200.jpg` 仍是 250×250：
      // 那个前缀会把任何内容强制成方框。所以断言前缀被换掉了。
      final result = pixivProportionalThumbUrl(_squareUrl);
      expect(
        result.contains('250x250'),
        isFalse,
        reason: '只换 `_square1200` 拿不到正确比例，两个部分必须一起换',
      );
    });

    test('`_custom1200`（作者自定义裁切）同样换成 master1200', () {
      final result = pixivProportionalThumbUrl(
        'https://i.pximg.net/c/250x250_80_a2/img-master/img/2025/09/26/22/32/41/'
        '135567360_p0_custom1200.jpg',
      );
      expect(result, contains('_p0_master1200.jpg'));
      expect(result, isNot(contains('_custom1200')));
    });

    test('custom-thumb asset directory changes together with its filename', () {
      // Public example in Ocrosoft/PixivPreviewer, commit 6142d321, line 1179.
      const custom = 'https://i.pximg.net/c/128x128/custom-thumb/img/'
          '2021/01/31/20/35/53/87426718_p0_custom1200.jpg';
      expect(
        pixivProportionalThumbUrl(custom),
        'https://i.pximg.net/c/$kPixivProportionalThumbFrame/img-master/img/'
        '2021/01/31/20/35/53/87426718_p0_master1200.jpg',
      );
    });

    test('已经是 master1200 的只换前缀，文件名不动', () {
      final result = pixivProportionalThumbUrl(
        'https://i.pximg.net/c/480x960/img-master/img/2026/09/21/12/02/19/'
        '149921452_p0_master1200.jpg',
      );
      expect(result, contains('/c/$kPixivProportionalThumbFrame/'));
      expect(result, contains('_p0_master1200.jpg'));
    });
  });

  group('不该动的输入原样返回', () {
    test('没有 `/c/` 的（已经是原图 / 别的形态）', () {
      const raw = 'https://i.pximg.net/img-master/img/2026/09/26/11/42/32/'
          '150120670_p0_master1200.jpg';
      expect(pixivProportionalThumbUrl(raw), raw);
    });

    test('空串与非 pixiv 域', () {
      expect(pixivProportionalThumbUrl(''), '');
      expect(pixivProportionalThumbUrl('   '), '');
      const other = 'https://example.com/a.jpg';
      expect(pixivProportionalThumbUrl(other), other);
    });

    test('首尾空白被去掉（db / 响应里可能带脏值）', () {
      expect(pixivProportionalThumbUrl('  $_squareUrl  '),
          pixivProportionalThumbUrl(_squareUrl));
    });
  });
}
