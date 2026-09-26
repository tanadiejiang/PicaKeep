/// Pixiv 下载内容迁移的**端到端**契约（36 号）。
///
/// ## 为什么必须真跑文件系统与 sqlite
///
/// 迁移要做三件事，且**缺一不可**：移动实体、在新根 db 写入记录、从旧根 db 删除记录。
/// 少任何一步的症状都是"文件在、但列表打不开"或者"列表指向不存在的路径"，
/// 而这三种做法在纯函数测试里长得一模一样。所以这里建真实的临时目录 +
/// 真实的 `download.db`（sqlite3），跑完整流程再逐项断言。
///
/// 覆盖的关键性质：
/// 1. **只搬 Pixiv**，其它来源的实体与记录一个都不动；
/// 2. 记录跟着实体走（新根有、旧根没有）；
/// 3. **可重入** —— 再跑一次不重复搬，也不报错；
/// 4. 目标已存在同名实体时**不覆盖**；
/// 5. 源实体已消失时记录照搬（否则旧 db 留下永远打不开的记录）。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/pixiv_download_migration.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

/// 一条 Pixiv 记录的 json（字段与真机取证一致：带 `sourceKey`）。
String _pixivJson(String id, {String name = '作品'}) => jsonEncode(<String, dynamic>{
      'id': id,
      'name': name,
      'subTitle': '作者',
      'tags': <String>['tag'],
      'sourceKey': 'pixiv',
      'sourceName': 'pixiv',
      'cover': '',
      'comicId': id.split('pixiv').last,
      'downloadedEps': <int>[1],
    });

/// 一条其它来源的 json。
String _otherJson(String id) => jsonEncode(<String, dynamic>{
      'id': id,
      'name': '别处的作品',
      'subTitle': '别的作者',
      'tags': <String>[],
      'sourceKey': 'nhentai',
      'sourceName': 'nhentai',
      'cover': '',
      'comicId': id,
      'downloadedEps': <int>[1],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
    OperatingSystem.windows,
    () => DynamicLibrary.open(
      p.join(Directory.current.path, 'windows', 'sqlite3.dll'),
    ),
  );

  late Directory workspace;
  late String fromRoot;
  late String toRoot;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_pixiv_mig_');
    fromRoot = p.join(workspace.path, 'download');
    toRoot = p.join(workspace.path, 'download_pixiv');
    await Directory(fromRoot).create(recursive: true);
  });

  tearDown(() async {
    try {
      await workspace.delete(recursive: true);
    } catch (_) {
      // Windows 上 sqlite 句柄可能还被缓存持着；删不掉就留在临时目录里。
    }
  });

  void writeRow(
    String root, {
    required String id,
    required String title,
    required String directory,
    required String json,
  }) {
    final db = sqlite3.open(p.join(root, 'download.db'));
    db.execute('''
      create table if not exists download (
        id text primary key,
        title text,
        subtitle text,
        time int,
        directory text,
        size int,
        json text
      )
    ''');
    db.execute(
      'insert or replace into download '
      '(id, title, subtitle, time, directory, size, json) values (?,?,?,?,?,?,?)',
      <Object?>[id, title, '', 0, directory, 0, json],
    );
    db.dispose();
  }

  List<String> idsIn(String root) {
    final file = File(p.join(root, kPixivMigrationDownloadDbName));
    if (!file.existsSync()) {
      return const <String>[];
    }
    final db = sqlite3.open(file.path);
    final rows = db.select('select id from download order by id');
    final ids = rows.map((row) => row['id'].toString()).toList();
    db.dispose();
    return ids;
  }

  String? directoryOf(String root, String id) {
    final file = File(p.join(root, kPixivMigrationDownloadDbName));
    if (!file.existsSync()) {
      return null;
    }
    final db = sqlite3.open(file.path);
    final rows = db.select('select directory from download where id = ?', [id]);
    final value = rows.isEmpty ? null : rows.first['directory']?.toString();
    db.dispose();
    return value;
  }

  /// 造一条"目录形态"的作品：`<root>/<name>/1.jpg`。
  Future<String> makeDirectoryEntry(String root, String name) async {
    final dir = Directory(p.join(root, name));
    await dir.create(recursive: true);
    await File(p.join(dir.path, '1.jpg')).writeAsString('x');
    return dir.path;
  }

  /// 造一条"单图/压缩包形态"的作品文件。
  Future<String> makeFileEntry(String root, String name) async {
    final file = File(p.join(root, name));
    await file.writeAsString('x');
    return file.path;
  }

  group('只搬 Pixiv，其余原样不动', () {
    test('目录形态 + 单文件形态都搬走，记录的 directory 指向新根', () async {
      final dirPath = await makeDirectoryEntry(fromRoot, 'Vodyanitsa');
      final filePath = await makeFileEntry(fromRoot, '稿件_148954915_p0.jpg');
      final otherPath = await makeDirectoryEntry(fromRoot, 'nhentai-123');
      writeRow(fromRoot,
          id: 'pixiv150034783',
          title: 'Vodyanitsa',
          directory: dirPath,
          json: _pixivJson('pixiv150034783'));
      writeRow(fromRoot,
          id: 'pixiv148954915',
          title: '稿件',
          directory: filePath,
          json: _pixivJson('pixiv148954915'));
      writeRow(fromRoot,
          id: 'nhentai123',
          title: '别处的作品',
          directory: otherPath,
          json: _otherJson('nhentai123'));

      final result = await migratePixivDownloadEntries(
        fromRoot: fromRoot,
        toRoot: toRoot,
      );

      expect(result.movedEntries, 2);
      expect(result.skippedEntries, 0);
      expect(result.failures, isEmpty);

      // 实体：Pixiv 的到了新根，旧的没了；别的来源原样留着。
      expect(Directory(p.join(toRoot, 'Vodyanitsa')).existsSync(), isTrue);
      expect(
        File(p.join(toRoot, '稿件_148954915_p0.jpg')).existsSync(),
        isTrue,
      );
      expect(Directory(dirPath).existsSync(), isFalse);
      expect(File(filePath).existsSync(), isFalse);
      expect(Directory(otherPath).existsSync(), isTrue);

      // 记录：旧根只剩 nhentai，新根拿到两条 Pixiv。
      expect(idsIn(fromRoot), <String>['nhentai123']);
      expect(idsIn(toRoot), <String>['pixiv148954915', 'pixiv150034783']);
      // 记录里的路径必须指向新位置（否则列表打不开）。
      expect(
        directoryOf(toRoot, 'pixiv150034783'),
        p.join(toRoot, 'Vodyanitsa'),
      );
    });

    test('内容也跟着搬（不是只挪了个空目录）', () async {
      final dirPath = await makeDirectoryEntry(fromRoot, '完全で瀟洒な従者');
      writeRow(fromRoot,
          id: 'pixiv150033282',
          title: '完全で瀟洒な従者',
          directory: dirPath,
          json: _pixivJson('pixiv150033282'));

      await migratePixivDownloadEntries(fromRoot: fromRoot, toRoot: toRoot);

      expect(
        File(p.join(toRoot, '完全で瀟洒な従者', '1.jpg')).existsSync(),
        isTrue,
      );
    });

    test('没有可解析 json 的老式行：靠 id 前缀也能搬', () async {
      final dirPath = await makeDirectoryEntry(fromRoot, '老记录');
      writeRow(fromRoot,
          id: 'pixiv150000001',
          title: '老记录',
          directory: dirPath,
          json: '{}');

      final result = await migratePixivDownloadEntries(
        fromRoot: fromRoot,
        toRoot: toRoot,
      );

      expect(result.movedEntries, 1);
      expect(idsIn(toRoot), <String>['pixiv150000001']);
    });
  });

  group('可重入与冲突处理', () {
    test('再跑一次：一条都不重复搬，也不报错', () async {
      final dirPath = await makeDirectoryEntry(fromRoot, 'A');
      writeRow(fromRoot,
          id: 'pixiv1',
          title: 'A',
          directory: dirPath,
          json: _pixivJson('pixiv1'));

      final first = await migratePixivDownloadEntries(
        fromRoot: fromRoot,
        toRoot: toRoot,
      );
      expect(first.movedEntries, 1);

      final second = await migratePixivDownloadEntries(
        fromRoot: fromRoot,
        toRoot: toRoot,
      );
      expect(second.movedEntries, 0);
      expect(second.skippedEntries, 0,
          reason: '记录已经从旧 db 删掉了，旧根里没有可搬的东西');
      expect(second.failures, isEmpty);
      expect(idsIn(fromRoot), isEmpty);
    });

    test('目标已存在同名实体 → 跳过实体但记录照搬，绝不覆盖', () async {
      final dirPath = await makeDirectoryEntry(fromRoot, 'dup');
      await File(p.join(dirPath, '1.jpg')).writeAsString('旧');
      final existing = await makeDirectoryEntry(toRoot, 'dup');
      await File(p.join(existing, '1.jpg')).writeAsString('新');
      writeRow(fromRoot,
          id: 'pixiv2',
          title: 'dup',
          directory: dirPath,
          json: _pixivJson('pixiv2'));

      final result = await migratePixivDownloadEntries(
        fromRoot: fromRoot,
        toRoot: toRoot,
      );

      expect(result.movedEntries, 0);
      expect(result.skippedEntries, 1);
      // 新根的内容**没被覆盖**。
      expect(File(p.join(existing, '1.jpg')).readAsStringSync(), '新');
      // 旧根的实体还在（跳过不等于删除）。
      expect(Directory(dirPath).existsSync(), isTrue);
      // 记录仍然搬过去了，指向新根那个同名目录。
      expect(idsIn(toRoot), <String>['pixiv2']);
      expect(directoryOf(toRoot, 'pixiv2'), existing);
    });

    test('源实体已经不在了 → 只搬记录（旧 db 不留打不开的记录）', () async {
      writeRow(fromRoot,
          id: 'pixiv3',
          title: '已删除的作品',
          directory: p.join(fromRoot, '不存在的目录'),
          json: _pixivJson('pixiv3'));

      final result = await migratePixivDownloadEntries(
        fromRoot: fromRoot,
        toRoot: toRoot,
      );

      expect(result.movedEntries, 0);
      expect(result.skippedEntries, 1);
      expect(idsIn(toRoot), <String>['pixiv3']);
      expect(idsIn(fromRoot), isEmpty);
    });
  });

  group('不该干活的时候不干活', () {
    test('源与目标是同一个目录 → 直接空结果', () async {
      final dirPath = await makeDirectoryEntry(fromRoot, 'A');
      writeRow(fromRoot,
          id: 'pixiv1',
          title: 'A',
          directory: dirPath,
          json: _pixivJson('pixiv1'));

      final result = await migratePixivDownloadEntries(
        fromRoot: fromRoot,
        toRoot: fromRoot,
      );

      expect(result.movedEntries, 0);
      expect(result.skippedEntries, 0);
      expect(idsIn(fromRoot), <String>['pixiv1']);
    });

    test('源根没有 download.db → 空结果且不创建目标目录', () async {
      final result = await migratePixivDownloadEntries(
        fromRoot: fromRoot,
        toRoot: toRoot,
      );

      expect(result.hasWork, isFalse);
      expect(Directory(toRoot).existsSync(), isFalse);
    });

    test('源里一条 Pixiv 记录都没有 → 空结果', () async {
      final otherPath = await makeDirectoryEntry(fromRoot, 'other');
      writeRow(fromRoot,
          id: 'nhentai1',
          title: 'x',
          directory: otherPath,
          json: _otherJson('nhentai1'));

      final result = await migratePixivDownloadEntries(
        fromRoot: fromRoot,
        toRoot: toRoot,
      );

      expect(result.hasWork, isFalse);
      expect(idsIn(fromRoot), <String>['nhentai1']);
    });
  });

  group('countPixivEntriesInRoot（决定要不要显示迁移入口）', () {
    test('数得对，且不修改任何东西', () async {
      final a = await makeDirectoryEntry(fromRoot, 'A');
      final b = await makeDirectoryEntry(fromRoot, 'B');
      writeRow(fromRoot,
          id: 'pixiv1', title: 'A', directory: a, json: _pixivJson('pixiv1'));
      writeRow(fromRoot,
          id: 'pixiv2', title: 'B', directory: b, json: _pixivJson('pixiv2'));
      writeRow(fromRoot,
          id: 'nhentai1', title: 'C', directory: b, json: _otherJson('nhentai1'));

      expect(await countPixivEntriesInRoot(fromRoot), 2);
      expect(Directory(a).existsSync(), isTrue, reason: '只读，不搬东西');
      expect(idsIn(fromRoot), hasLength(3));
    });

    test('目录不存在 / 没有 db → 0（不抛）', () async {
      expect(await countPixivEntriesInRoot(p.join(workspace.path, 'nope')), 0);
      expect(await countPixivEntriesInRoot(''), 0);
    });
  });
}
