/// 压缩包形态的**页数**解析（36 号）。
///
/// ## 背景
///
/// 用户真机反馈：「那些多图压缩包的漫画没有显示页数需要修复」。
/// 改动前 `_resolvePageCount` 对 `.zip` / `.cbz` **直接返回 null**（当时的判断是
/// "要么解压、要么读 zip 中央目录，成本与本功能不匹配"），所以 `settings[154]`
/// 打开多图打包后，所有多图作品的卡片都不显示页数。
///
/// 现在改成读 zip 中央目录（不解压、不碰条目内容）。这条用例用**真实的 zip 文件**
/// 跑一遍，钉住两件事：
/// 1. 页数数得对；
/// 2. **封面被排除** —— 28 号打包时 `cover.jpg` 与页图平铺在同一个 zip 里，
///    不排除会把 3 页的作品数成 4 页。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/illust_cover_size.dart';

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_zip_pages_');
  });

  tearDown(() async {
    try {
      await workspace.delete(recursive: true);
    } catch (_) {}
  });

  /// 造一个内容为 [names] 的 zip。
  ///
  /// 用 `Archive` + `ZipEncoder().encode()` 直接生成字节，而不是
  /// `ZipFileEncoder`：后者的 `addFile` / `addArchiveFile` 对"条目名"的语义
  /// 与直觉不同（实测生成出来的包读不回条目），而本用例要验的正是
  /// **中央目录里的条目名**，不能在这里掺入生成侧的坑。
  Future<String> makeZip(String fileName, List<String> names) async {
    final archive = Archive();
    for (final name in names) {
      if (name.endsWith('/')) {
        archive.add(ArchiveFile.directory(name.substring(0, name.length - 1)));
        continue;
      }
      final bytes = utf8.encode('x');
      archive.add(ArchiveFile(name, bytes.length, bytes));
    }
    final zipPath = p.join(workspace.path, fileName);
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive));
    return zipPath;
  }

  group('压缩包形态：读中央目录数页数', () {
    test('3 张页图 + 1 张 cover → 3 页（封面被排除）', () async {
      final zipPath = await makeZip(
        'work_p3.zip',
        <String>['1.jpg', '2.jpg', '3.jpg', 'cover.jpg'],
      );
      expect(await countArchivePageImages(zipPath), 3);
    });

    test('封面缺失时按实际张数算', () async {
      final zipPath = await makeZip('work_p2.zip', <String>['1.jpg', '2.jpg']);
      expect(await countArchivePageImages(zipPath), 2);
    });

    test('混入非图片条目（说明文件 / 目录项）不计入', () async {
      final zipPath = await makeZip(
        'work_mixed.zip',
        <String>['1.png', '2.webp', 'readme.txt', 'sub/'],
      );
      expect(await countArchivePageImages(zipPath), 2);
    });

    test('只有封面 → 给不出页数（null，而不是 0）', () async {
      final zipPath = await makeZip('only_cover.zip', <String>['cover.jpg']);
      expect(await countArchivePageImages(zipPath), isNull);
    });

    test('不是合法 zip → null，且不抛（拿不到就只是不显示这一项）', () async {
      final broken = p.join(workspace.path, 'broken_p6.zip');
      await File(broken).writeAsString('not a zip');
      expect(await countArchivePageImages(broken), isNull);
    });

    test('zip 不存在 → null，且不抛', () async {
      expect(
        await countArchivePageImages(p.join(workspace.path, 'missing.zip')),
        isNull,
      );
    });
  });
}
