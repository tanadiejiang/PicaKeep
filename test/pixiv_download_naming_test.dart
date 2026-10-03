import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart';

void main() {
  group('renderPixivDirectoryName · 变量替换', () {
    test('单变量 {title}', () {
      expect(
        renderPixivDirectoryName(
          template: '{title}',
          title: '夜の海',
          author: '久蒼穹',
          id: '150033282',
          pages: null,
        ),
        '夜の海',
      );
    });

    test('三变量组合，字面量分隔符原样保留', () {
      expect(
        renderPixivDirectoryName(
          template: '{title}-{author}-{id}',
          title: '夜の海',
          author: '久蒼穹',
          id: '150033282',
          pages: null,
        ),
        '夜の海-久蒼穹-150033282',
      );
    });

    test('同一变量可在模板里重复出现', () {
      expect(
        renderPixivDirectoryName(
          template: '{id}_{title}_{id}',
          title: 'T',
          author: 'A',
          id: '42',
          pages: null,
        ),
        '42_T_42',
      );
    });

    test('模板里的未知占位符原样保留（不当成变量）', () {
      expect(
        renderPixivDirectoryName(
          template: '{title}{unknown}',
          title: 'T',
          author: 'A',
          id: '1',
          pages: null,
        ),
        'T{unknown}',
      );
    });

    test('空模板等同于标题加 ID 的默认模板', () {
      final withEmpty = renderPixivDirectoryName(
        template: '',
        title: '标题',
        author: '作者',
        id: '9',
        pages: null,
      );
      final withDefault = renderPixivDirectoryName(
        template: kDefaultPixivDirNameTemplate,
        title: '标题',
        author: '作者',
        id: '9',
        pages: null,
      );
      expect(withEmpty, withDefault);
      expect(withEmpty, '标题-9');
    });

    test('全空白模板也回落到默认模板', () {
      expect(
        renderPixivDirectoryName(
          template: '   ',
          title: '标题',
          author: '作者',
          id: '9',
          pages: null,
        ),
        '标题-9',
      );
    });
  });

  group('renderPixivDirectoryName · 单遍替换（防二次替换）', () {
    // 这组用例锁住一个真实缺陷：早期实现是"对每个变量各做一次 replaceAll"的
    // 循环，前一个变量的替换结果会被后一个变量再扫一遍。标题里含字面量花括号
    // 在同人作品名里并不罕见，出错时**不报错**，只是目录名与预期不符。
    test('标题里的字面量 {author} 不被作者值吃掉', () {
      expect(
        renderPixivDirectoryName(
          template: '{title}',
          title: 'A{author}B',
          author: 'X',
          id: '1',
          pages: null,
        ),
        'A{author}B',
      );
    });

    test('标题里的字面量 {id} 不被作品 ID 吃掉', () {
      expect(
        renderPixivDirectoryName(
          template: '{title}',
          title: '第{id}话',
          author: 'A',
          id: '999',
          pages: null,
        ),
        '第{id}话',
      );
    });

    test('作者名里的字面量 {title} 不被标题吃掉（替换顺序无关）', () {
      expect(
        renderPixivDirectoryName(
          template: '{author}',
          title: 'T',
          author: 'A{title}B',
          id: '1',
          pages: null,
        ),
        'A{title}B',
      );
    });
  });

  group('renderPixivDirectoryName · 兜底绝不返回空串', () {
    test('变量全空时退回 fallback', () {
      expect(
        renderPixivDirectoryName(
          template: '{title}',
          title: '   ',
          author: '',
          id: '',
          pages: null,
          fallback: 'pixiv12345',
        ),
        'pixiv12345',
      );
    });

    test('fallback 含非法字符时先清洗再使用', () {
      expect(
        renderPixivDirectoryName(
          template: '{title}',
          title: '',
          author: '',
          id: '',
          pages: null,
          fallback: 'a/b:c',
        ),
        'a_bc',
      );
    });

    test('连 fallback 都为空时给固定名，绝不返回空串', () {
      expect(
        renderPixivDirectoryName(
          template: '{title}',
          title: '',
          author: '',
          id: '',
          pages: null,
        ),
        'pixiv',
      );
    });

    test('模板只剩分隔符时清洗后仍有内容，不走 fallback', () {
      expect(
        renderPixivDirectoryName(
          template: '///',
          title: '',
          author: '',
          id: '777',
          pages: null,
          fallback: '777',
        ),
        '___',
      );
    });
  });

  group('renderPixivDirectoryName · 清洗与长度', () {
    test('标题里的路径分隔符不会建出额外层级', () {
      final rendered = renderPixivDirectoryName(
        template: '{title}',
        title: 'a/b\\c',
        author: '',
        id: '1',
        pages: null,
      );
      expect(rendered.contains('/'), isFalse);
      expect(rendered.contains(r'\'), isFalse);
      expect(rendered, 'a_b_c');
    });

    test('超长中文按 UTF-8 字节截断，且不切碎多字节字符', () {
      final long = '中' * 200; // 600 字节
      final rendered = renderPixivDirectoryName(
        template: '{title}',
        title: long,
        author: '',
        id: '',
        pages: null,
      );
      expect(utf8.encode(rendered).length, lessThanOrEqualTo(255));
      // 没有替换字符（U+FFFD）说明没有切碎字符
      expect(rendered.contains('\uFFFD'), isFalse);
      // 输出应当是若干个完整的中文字
      expect(rendered, '中' * rendered.length);
      expect(rendered.isNotEmpty, isTrue);
    });

    test('超长 emoji（代理对）不被劈成半个', () {
      final long = '🎨' * 200; // 每字 4 字节，共 800 字节
      final rendered = renderPixivDirectoryName(
        template: '{title}',
        title: long,
        author: '',
        id: '',
        pages: null,
      );
      expect(utf8.encode(rendered).length, lessThanOrEqualTo(255));
      // 往返一致 = 没有落单的代理项
      expect(utf8.decode(utf8.encode(rendered)), rendered);
      expect(rendered.runes.every((r) => r == 0x1F3A8), isTrue);
    });

    test('长度未超限时不做任何截断', () {
      const title = '正常长度的标题';
      expect(
        renderPixivDirectoryName(
          template: '{title}',
          title: title,
          author: '',
          id: '',
          pages: null,
        ),
        title,
      );
    });
  });

  group('sanitizeDirectorySegment', () {
    test('路径分隔符换成下划线', () {
      expect(sanitizeDirectorySegment('a/b\\c'), 'a_b_c');
    });

    test('跨平台非法字符被去掉', () {
      expect(sanitizeDirectorySegment('a:b*c?d"e<f>g|h'), 'abcdefgh');
    });

    test('控制字符被去掉', () {
      expect(sanitizeDirectorySegment('a\u0000b\u001fc\u007fd'), 'abcd');
    });

    test('连续空白压成一个空格并去掉首尾', () {
      expect(sanitizeDirectorySegment('  a   b  '), 'a b');
    });

    test('结尾的点被去掉', () {
      expect(sanitizeDirectorySegment('abc...'), 'abc');
    });

    test('单个点与双点归为空串', () {
      expect(sanitizeDirectorySegment('.'), '');
      expect(sanitizeDirectorySegment('..'), '');
    });

    test('点开头的正常名字不被破坏', () {
      expect(sanitizeDirectorySegment('.hidden'), '.hidden');
    });

    test('空串仍是空串', () {
      expect(sanitizeDirectorySegment(''), '');
    });
  });

  group('normalizePixivDirNameTemplate', () {
    test('null / 空串 / 全空白都回落到默认模板', () {
      expect(normalizePixivDirNameTemplate(null), kDefaultPixivDirNameTemplate);
      expect(normalizePixivDirNameTemplate(''), kDefaultPixivDirNameTemplate);
      expect(
        normalizePixivDirNameTemplate('   '),
        kDefaultPixivDirNameTemplate,
      );
    });

    test('非空值去掉首尾空白后原样保留', () {
      expect(normalizePixivDirNameTemplate('  {title}-{id}  '), '{title}-{id}');
    });

    test('新设置与解析默认值都勾选标题和 ID', () {
      expect(kDefaultPixivDirNameTemplate, '{title}-{id}');
      expect(appdata.settings[pixivDirNameTemplateSettingIndex],
          kDefaultPixivDirNameTemplate);
      final spec = parsePixivDirNameTemplate(kDefaultPixivDirNameTemplate);
      expect(spec.fields, <String>['title', 'id']);
      expect(spec.separator, kDefaultPixivDirNameSeparator);
      expect(normalizePixivDirNameTemplate('{title}'), '{title}',
          reason: '已经保存的单标题模板不强制改写');
    });
  });

  group('设置下标常量', () {
    test('下标固定为 152 / 153 / 154（shift 会让设置错位）', () {
      expect(pixivDownloadDirSettingIndex, 152);
      expect(pixivDirNameTemplateSettingIndex, 153);
      expect(pixivMultiPageZipSettingIndex, 154);
    });

    test('多图打包开关默认关（产物形态是兼容性变更）', () {
      expect(appdata.settings[pixivMultiPageZipSettingIndex], '0');
    });

    test('normalizePixivMultiPageZip 只认 1，其余落回 0', () {
      expect(normalizePixivMultiPageZip('1'), '1');
      expect(normalizePixivMultiPageZip('0'), '0');
      expect(normalizePixivMultiPageZip(null), '0');
      expect(normalizePixivMultiPageZip(''), '0');
      expect(normalizePixivMultiPageZip('true'), '0');
      expect(normalizePixivMultiPageZip(' 1 '), '0');
      expect(pixivMultiPageZipEnabled('1'), isTrue);
      expect(pixivMultiPageZipEnabled(null), isFalse);
    });
  });

  group('renderPixivDirectoryName · {pages} 页数字段', () {
    test('页数渲染成 p3（模板 UI 是勾选式，p 前缀只能由渲染层补）', () {
      expect(
        renderPixivDirectoryName(
          template: '{title}_{pages}',
          title: 'シグニット',
          author: '電瘋扇',
          id: '82074457',
          pages: 3,
        ),
        'シグニット_p3',
      );
    });

    test('与用户截图同形的完整模板产出基名（再拼 .zip 就是产物名）', () {
      final base = renderPixivDirectoryName(
        template: '{author}_{title}_{id}_{pages}',
        title: 'シグニット',
        author: '電瘋扇',
        id: '82074457',
        pages: 3,
      );
      expect(base, '電瘋扇_シグニット_82074457_p3');
      expect(
        buildPixivArtifactFileName(
          baseName: base,
          extension: kPixivArchiveExtension,
        ),
        '電瘋扇_シグニット_82074457_p3.zip',
      );
    });

    test('页数为 0 / null 时渲染成空串，且不留下 _p 尾巴', () {
      for (final pages in <int?>[0, null]) {
        // 不能出现 `p0` / `pnull` / `_p`
        final rendered = renderPixivDirectoryName(
          template: '{title}_{pages}',
          title: '标题',
          author: '作者',
          id: '9',
          pages: pages,
        );
        expect(rendered, '标题', reason: 'pages=$pages');
        expect(rendered.contains('_p'), isFalse, reason: 'pages=$pages');
      }
    });

    test('pages 在行首时吃掉后面的分隔符（不留前导分隔符）', () {
      expect(
        renderPixivDirectoryName(
          template: '{pages}_{title}',
          title: '标题',
          author: '作者',
          id: '9',
          pages: null,
        ),
        '标题',
      );
    });

    test('pages 单独成模板且页数未知时退回 fallback，绝不返回空串', () {
      expect(
        renderPixivDirectoryName(
          template: '{pages}',
          title: '标题',
          author: '作者',
          id: '9',
          pages: 0,
          fallback: '9',
        ),
        '9',
      );
    });

    test('pages 有值时不吃分隔符（与其它字段一视同仁）', () {
      expect(
        renderPixivDirectoryName(
          template: '{title}-{pages}-{id}',
          title: 'T',
          author: 'A',
          id: '7',
          pages: 12,
        ),
        'T-p12-7',
      );
    });

    test('回归：其它字段渲染为空时，分隔符仍原样保留（老模板行为不变）', () {
      // `pages` 的"吃分隔符"是**只给它一个字段**的特例：title/author/id 为空
      // 属于异常输入，老模板依赖"分隔符原样保留"，一个字都不能改。
      expect(
        renderPixivDirectoryName(
          template: '{title}-{author}',
          title: '标题',
          author: '',
          id: '9',
          pages: null,
        ),
        '标题-',
      );
    });
  });

  group('buildPixivArtifactFileName · 基名 + 产物扩展名', () {
    test('普通情况直接拼接', () {
      expect(
        buildPixivArtifactFileName(baseName: 'a_b_p3', extension: '.zip'),
        'a_b_p3.zip',
      );
      expect(
        buildPixivArtifactFileName(baseName: 'a_b_p1', extension: '.jpg'),
        'a_b_p1.jpg',
      );
    });

    test('加完扩展名仍不超 255 字节，且不切碎多字节字符', () {
      final longBase = '中' * 200; // 600 字节
      final name = buildPixivArtifactFileName(
        baseName: longBase,
        extension: '.zip',
      );
      expect(utf8.encode(name).length, lessThanOrEqualTo(255));
      expect(name.endsWith('.zip'), isTrue);
      expect(name.contains('\uFFFD'), isFalse);
      // 去掉扩展名后应当仍是若干个完整的中文字
      final stem = name.substring(0, name.length - 4);
      expect(stem, '中' * stem.length);
    });

    test('基名为空时给固定名，不产出只剩扩展名的隐藏文件', () {
      expect(
        buildPixivArtifactFileName(baseName: '   ', extension: '.zip'),
        'pixiv.zip',
      );
    });
  });

  group('parsePixivDirNameTemplate · 解析出勾选与顺序', () {
    test('三字段按模板顺序还原', () {
      final spec = parsePixivDirNameTemplate('{title}-{author}-{id}');
      expect(spec.fields, <String>['title', 'author', 'id']);
      expect(spec.separator, '-');
    });

    test('用户排过的顺序能被还原（不是固定顺序）', () {
      final spec = parsePixivDirNameTemplate('{author}_{id}');
      expect(spec.fields, <String>['author', 'id']);
      expect(spec.separator, '_');
    });

    test('重复字段保序去重', () {
      final spec = parsePixivDirNameTemplate('{title}_{title}');
      expect(spec.fields, <String>['title']);
      expect(spec.separator, '_');
    });

    test('单字段时用默认分隔符（此时分隔符无意义）', () {
      final spec = parsePixivDirNameTemplate('{author}');
      expect(spec.fields, <String>['author']);
      expect(spec.separator, kDefaultPixivDirNameSeparator);
    });

    test('空模板退回标题和 ID 的默认规格', () {
      expect(parsePixivDirNameTemplate('').fields, <String>['title', 'id']);
    });

    test('解析不出任何已知字段时退回默认，不抛错', () {
      expect(parsePixivDirNameTemplate('{foo}-{bar}').fields,
          <String>['title', 'id']);
    });

    test('混有未知占位符时，已知字段仍按出现顺序还原', () {
      final spec = parsePixivDirNameTemplate('{id}-{unknown}-{title}');
      expect(spec.fields, <String>['id', 'title']);
    });

    test('空格分隔符原样保留', () {
      final spec = parsePixivDirNameTemplate('{title} {author}');
      expect(spec.fields, <String>['title', 'author']);
      expect(spec.separator, ' ');
    });

    test('字段相邻（无分隔符）时解析出空分隔符', () {
      final spec = parsePixivDirNameTemplate('{title}{author}');
      expect(spec.fields, <String>['title', 'author']);
      expect(spec.separator, '');
    });

    test('能识别 {pages} 字段（勾选式 UI 的落盘与还原）', () {
      final spec =
          parsePixivDirNameTemplate('{author}_{title}_{id}_{pages}');
      expect(spec.fields, <String>['author', 'title', 'id', 'pages']);
      expect(spec.separator, '_');
    });

    test('{pages} 单独出现时也能被识别（不再退化成只含 title 的默认值）', () {
      expect(parsePixivDirNameTemplate('{pages}').fields, <String>['pages']);
    });

    test('四字段往返一致：build → parse 还原出同样的顺序与分隔符', () {
      const fields = <String>['author', 'title', 'id', 'pages'];
      final spec = parsePixivDirNameTemplate(
        buildPixivDirNameTemplate(fields, '_'),
      );
      expect(spec.fields, fields);
      expect(spec.separator, '_');
    });
  });

  group('buildPixivDirNameTemplate · 生成模板串', () {
    test('按顺序与分隔符拼接', () {
      expect(
        buildPixivDirNameTemplate(<String>['title', 'author', 'id'], '-'),
        '{title}-{author}-{id}',
      );
    });

    test('空分隔符时字段相邻', () {
      expect(
        buildPixivDirNameTemplate(<String>['title', 'id'], ''),
        '{title}{id}',
      );
    });

    test('单字段不带分隔符', () {
      expect(buildPixivDirNameTemplate(<String>['author'], '-'), '{author}');
    });

    test('空字段列表返回空串', () {
      expect(buildPixivDirNameTemplate(<String>[], '-'), '');
    });
  });

  group('解析与生成 · 往返一致（持久化格式不变的地基）', () {
    test('parse(build(fields, sep)) 还原出同样的 (fields, sep)', () {
      const cases = <(List<String>, String)>[
        (['title'], '-'),
        (['title', 'author'], '-'),
        (['author', 'title'], '_'),
        (['id', 'title', 'author'], ' '),
        (['title', 'id'], ''),
        (['id', 'author', 'title'], '-'),
      ];
      for (final (fields, sep) in cases) {
        final spec = parsePixivDirNameTemplate(
          buildPixivDirNameTemplate(fields, sep),
        );
        expect(spec.fields, fields, reason: 'fields=$fields sep="$sep"');
        expect(spec.separator, sep, reason: 'fields=$fields sep="$sep"');
      }
    });

    test('生成的结果经渲染后与直接渲染等价', () {
      final built = buildPixivDirNameTemplate(<String>['author', 'title'], '_');
      expect(
        renderPixivDirectoryName(
          template: built,
          title: 'T',
          author: 'A',
          id: '1',
          pages: null,
        ),
        renderPixivDirectoryName(
          template: '{author}_{title}',
          title: 'T',
          author: 'A',
          id: '1',
          pages: null,
        ),
      );
    });
  });

  group('字段表与标签表', () {
    test('字段表与变量表是同一批字段（加第四个变量时两处要一起改）', () {
      expect(kPixivDirNameFieldKeys.toSet(), kPixivDirNameVariables.toSet());
    });

    test('每个字段都有展示名', () {
      for (final key in kPixivDirNameFieldKeys) {
        expect(kPixivDirNameFieldLabels[key], isNotNull, reason: key);
      }
    });

    test('默认分隔符在候选表内', () {
      expect(
        kPixivDirNameSeparators.contains(kDefaultPixivDirNameSeparator),
        isTrue,
      );
    });
  });
}
