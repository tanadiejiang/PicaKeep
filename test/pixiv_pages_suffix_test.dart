import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart';

/// `{pages}` 后缀的三分支是**用户拍板的命名约定**，单独成组守住。
///
/// 背景：真机反馈里单图产物形如 `..._p0.jpg`、多图形如 `..._p3.zip`。
/// 两套记号刻意不统一（`p0` = "只有第 0 页"，`p{n}` = "共 n 页"），
/// 所以**不要"顺手统一"成 `p$pages`** —— 那会把单图变成 `p1`。
void main() {
  String render(int? pages, {String template = '{title}_{pages}'}) {
    return renderPixivDirectoryName(
      template: template,
      title: 'T',
      author: 'A',
      id: '1',
      pages: pages,
    );
  }

  group('{pages} · 单图给 p0', () {
    test('1 页渲染成 p0（不是 p1）', () {
      expect(render(1), 'T_p0');
    });

    test('多图渲染成 p{页数}', () {
      expect(render(2), 'T_p2');
      expect(render(3), 'T_p3');
      expect(render(26), 'T_p26');
    });

    test('页数未知（0 / null）渲染成空串，并吃掉相邻分隔符', () {
      expect(render(0), 'T');
      expect(render(null), 'T');
    });

    test('页数为负（异常输入）按未知处理', () {
      expect(render(-1), 'T');
    });
  });

  group('{pages} · 在模板中的位置', () {
    test('放在末尾（用户截图里的形态）', () {
      expect(
        renderPixivDirectoryName(
          template: '{author}_{title}_{id}_{pages}',
          title: 'シグニット',
          author: '電瘋扇',
          id: '82074457',
          pages: 3,
        ),
        '電瘋扇_シグニット_82074457_p3',
      );
    });

    test('单图的同形模板', () {
      expect(
        renderPixivDirectoryName(
          template: '{author}_{title}_{id}_{pages}',
          title: 'タイトル',
          author: '作者',
          id: '79751361',
          pages: 1,
        ),
        '作者_タイトル_79751361_p0',
      );
    });

    test('放在行首时，未知页数吃掉的是后一段分隔符', () {
      expect(render(0, template: '{pages}_{title}'), 'T');
    });

    test('单独成模板时，未知页数会退回 fallback（不会得到空名）', () {
      expect(
        renderPixivDirectoryName(
          template: '{pages}',
          title: 'T',
          author: 'A',
          id: '1',
          pages: 0,
          fallback: '1',
        ),
        '1',
      );
    });
  });
}
