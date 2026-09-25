import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/settings/settings_page.dart';

String _repeat(String unit, int count) => List.filled(count, unit).join();

void main() {
  group('validateNewDirectoryName 合法名称', () {
    test('普通英文名通过', () {
      expect(validateNewDirectoryName('PicaKeep'), isNull);
    });

    test('中文名通过', () {
      expect(validateNewDirectoryName('我的漫画'), isNull);
    });

    test('含空格与连字符通过', () {
      expect(validateNewDirectoryName('my comics-2026'), isNull);
    });

    test('内部含点号通过（不是单独的 . 或 ..）', () {
      expect(validateNewDirectoryName('v1.2'), isNull);
      expect(validateNewDirectoryName('...'), isNull);
    });

    test('首尾空白会被 trim，仍视为合法', () {
      expect(validateNewDirectoryName('  comics  '), isNull);
    });

    test('恰好 255 字节通过（ASCII）', () {
      expect(validateNewDirectoryName(_repeat('a', 255)), isNull);
    });

    test('恰好 255 字节通过（中文，85 字 × 3 字节）', () {
      expect(validateNewDirectoryName(_repeat('中', 85)), isNull);
    });
  });

  group('validateNewDirectoryName 非法名称', () {
    test('空字符串被拒绝', () {
      expect(validateNewDirectoryName(''), '文件夹名称不能为空');
    });

    test('纯空白被拒绝', () {
      expect(validateNewDirectoryName('   '), '文件夹名称不能为空');
    });

    test('. 被拒绝', () {
      expect(validateNewDirectoryName('.'), '文件夹名称不能是 . 或 ..');
    });

    test('.. 被拒绝', () {
      expect(validateNewDirectoryName('..'), '文件夹名称不能是 . 或 ..');
    });

    test('正斜杠被拒绝', () {
      expect(validateNewDirectoryName('a/b'), '文件夹名称不能包含 / 或 \\');
      expect(validateNewDirectoryName('/'), '文件夹名称不能包含 / 或 \\');
    });

    test('反斜杠被拒绝', () {
      expect(validateNewDirectoryName('a\\b'), '文件夹名称不能包含 / 或 \\');
    });

    test('换行与制表符等控制字符被拒绝', () {
      for (final name in ['a\nb', 'a\tb', 'a\rb', 'a\u0000b', 'a\u007fb']) {
        expect(
          validateNewDirectoryName(name),
          '文件夹名称不能包含控制字符',
          reason: '名称 ${name.codeUnits} 应被拒绝',
        );
      }
    });

    test('超过 255 字节被拒绝（ASCII）', () {
      expect(validateNewDirectoryName(_repeat('a', 256)), '文件夹名称过长');
    });

    test('超过 255 字节被拒绝（中文，86 字 × 3 字节）', () {
      expect(validateNewDirectoryName(_repeat('中', 86)), '文件夹名称过长');
    });
  });

  group('resolveNewDirectoryPath', () {
    test('普通父目录拼接', () {
      expect(
        resolveNewDirectoryPath('/storage/emulated/0', 'comics'),
        '/storage/emulated/0/comics',
      );
    });

    test('根目录拼接不产生双斜杠', () {
      expect(resolveNewDirectoryPath('/', 'comics'), '/comics');
    });

    test('父目录尾随斜杠被规整', () {
      expect(
        resolveNewDirectoryPath('/storage/emulated/0/', 'comics'),
        '/storage/emulated/0/comics',
      );
    });

    test('空父目录按根目录处理', () {
      expect(resolveNewDirectoryPath('', 'comics'), '/comics');
    });

    test('父目录与名称的首尾空白被清理', () {
      expect(
        resolveNewDirectoryPath('  /sdcard  ', '  comics  '),
        '/sdcard/comics',
      );
    });

    test('深层应用私有目录拼接', () {
      expect(
        resolveNewDirectoryPath(
          '/data/user/0/lingxue.picakeep/files',
          'download',
        ),
        '/data/user/0/lingxue.picakeep/files/download',
      );
    });

    test('反斜杠父目录被归一化为正斜杠', () {
      expect(resolveNewDirectoryPath('/sdcard\\sub', 'comics'),
          '/sdcard/sub/comics');
    });
  });

  group('校验与拼接的组合行为', () {
    test('中文目录名拼接后保持原样', () {
      const name = '我的漫画';
      expect(validateNewDirectoryName(name), isNull);
      expect(resolveNewDirectoryPath('/sdcard', name), '/sdcard/我的漫画');
    });

    test('名称内部的点号不会污染路径', () {
      expect(
        resolveNewDirectoryPath('/sdcard', 'v1.2'),
        '/sdcard/v1.2',
      );
    });
  });
}
