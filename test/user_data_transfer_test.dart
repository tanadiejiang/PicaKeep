/// 用户数据导入 / 导出的契约测试。
///
/// 对接原项目 `.picadata` 格式，重点是四件容易出错的事：
/// 1. 导出的包里 settings 要**改名成 appdata**（否则原项目认不出来）；
/// 2. 导入 settings 时**只覆盖与原项目一致的前 95 项**，保留本应用新增项；
/// 3. JM / nhentai 的账号字段要**适配**，否则"数据在但显示未登录"；
/// 4. cookie 要**分发到四个库**，数据库要**合并且能补建收藏夹表**。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/user_data_transfer.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final Directory root;

  Future<String> directory(String name) async =>
      (await Directory(p.join(root.path, name)).create(recursive: true)).path;

  @override
  Future<String?> getApplicationCachePath() => directory('cache');
  @override
  Future<String?> getApplicationSupportPath() => directory('support');
}

/// 造一个 .picadata 包。默认内容贴近原项目导出（不含下载）。
Uint8List buildPackage({
  List<String>? settings,
  Map<String, List<int>> extraFiles = const <String, List<int>>{},
}) {
  final archive = Archive();
  void add(String name, List<int> bytes) =>
      archive.addFile(ArchiveFile(name, bytes.length, bytes));

  add('appdata', utf8.encode(jsonEncode(settings ?? <String>['1', 'dd'])));
  for (final e in extraFiles.entries) {
    add(e.key, e.value);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// 建一个只有一张表的 sqlite 库，返回字节。
Uint8List buildDb(void Function(Database db) fill) {
  final temp = File(
    p.join(Directory.systemTemp.path,
        'pk_udt_${DateTime.now().microsecondsSinceEpoch}.db'),
  );
  final db = sqlite3.open(temp.path);
  try {
    fill(db);
  } finally {
    db.dispose();
  }
  final bytes = temp.readAsBytesSync();
  temp.deleteSync();
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
    OperatingSystem.windows,
    () => DynamicLibrary.open(
      p.join(Directory.current.path, 'windows', 'sqlite3.dll'),
    ),
  );

  late Directory workspace;
  late String dataPath;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_udt_');
    PathProviderPlatform.instance = _Paths(workspace);
    await App.init(dataPathOverride: p.join(workspace.path, 'data'));
    dataPath = App.dataPath;
  });

  setUp(() async {
    final dir = Directory(dataPath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);
  });

  Future<void> writeFile(String relative, Object content) async {
    final file = File(p.join(dataPath, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(content is String ? content : jsonEncode(content));
  }

  Future<Map<String, dynamic>> readJson(String relative) async {
    final raw = await File(p.join(dataPath, relative)).readAsString();
    final decoded = jsonDecode(raw);
    return (decoded as Map).map((k, v) => MapEntry(k.toString(), v));
  }

  // ── 导出 ────────────────────────────────────────────────────────────────
  group('导出', () {
    test('settings 改名成 appdata（原项目才认）', () async {
      await writeFile('settings', ['1', 'dd', 'x']);
      final out = p.join(workspace.path, 'out.picadata');

      final result = await UserDataTransfer.export(outFile: out);

      expect(result.ok, isTrue, reason: result.message);
      final names = ZipDecoder()
          .decodeBytes(await File(out).readAsBytes())
          .files
          .map((f) => f.name)
          .toList();
      expect(names, contains('appdata'));
      expect(names, isNot(contains('settings')));
    });

    test('带上各源数据与独立 cookie 库，且不含下载', () async {
      await writeFile('settings', ['1']);
      await writeFile('history.db', 'H');
      await writeFile('comic_source/jm.data', {'token': 'logged_in'});
      await writeFile('comic_source/eh_cookies.db', 'C');
      await writeFile('download/download.db', 'D');
      await writeFile('logs/run.txt', 'L');
      final out = p.join(workspace.path, 'out2.picadata');

      await UserDataTransfer.export(outFile: out);

      final names = ZipDecoder()
          .decodeBytes(await File(out).readAsBytes())
          .files
          .map((f) => f.name)
          .toSet();
      expect(names, contains('history.db'));
      expect(names, contains('comic_source/jm.data'));
      expect(names, contains('comic_source/eh_cookies.db'));
      expect(names.any((n) => n.contains('download.db')), isFalse);
      expect(names.any((n) => n.startsWith('logs/')), isFalse);
    });
  });

  // ── 导入：settings ──────────────────────────────────────────────────────
  group('导入 settings', () {
    test('只覆盖原项目含义一致的前 95 项，保留本应用新增项', () async {
      // 本应用有 121 项，尾部是新增功能；用哨兵值确认它们没被动。
      final current = List<String>.filled(121, 'old');
      current[120] = 'KEEP-121';
      current[100] = 'KEEP-101';
      await writeFile('settings', current);

      final imported = List<String>.filled(95, 'new');
      final pkg = p.join(workspace.path, 's.picadata');
      await File(pkg).writeAsBytes(buildPackage(settings: imported));

      final result = await UserDataTransfer.import(pkg);

      expect(result.ok, isTrue, reason: result.message);
      final settings = (jsonDecode(
        await File(p.join(dataPath, 'settings')).readAsString(),
      ) as List)
          .map((e) => e.toString())
          .toList();
      expect(settings.length, 121);
      expect(settings[0], 'new');
      expect(settings[94], 'new');
      // 第 96 项之后是 PicaKeep 自己的，不能被覆盖。
      expect(settings[95], 'old');
      expect(settings[100], 'KEEP-101');
      expect(settings[120], 'KEEP-121');
    });

    test('包里有 121 项时也只取前 95 项', () async {
      await writeFile('settings', List<String>.filled(121, 'old'));
      final imported = List<String>.generate(121, (i) => 'v$i');
      final pkg = p.join(workspace.path, 's2.picadata');
      await File(pkg).writeAsBytes(buildPackage(settings: imported));

      await UserDataTransfer.import(pkg);

      final settings = (jsonDecode(
        await File(p.join(dataPath, 'settings')).readAsString(),
      ) as List)
          .map((e) => e.toString())
          .toList();
      expect(settings[94], 'v94');
      expect(settings[95], 'old', reason: '第 96 项起应保持本应用原值');
    });
  });

  // ── 导入：账号字段适配 ──────────────────────────────────────────────────
  group('导入账号数据', () {
    test('jm 的 id 转成 uid 并补 token 标记', () async {
      final pkg = p.join(workspace.path, 'jm.picadata');
      await File(pkg).writeAsBytes(buildPackage(extraFiles: {
        'comic_source/jm.data': utf8.encode(jsonEncode({
          'account': ['user', 'pass'],
          'name': '某用户',
          'id': '999888',
        })),
      }));

      await UserDataTransfer.import(pkg);

      final jm = await readJson('comic_source/jm.data');
      expect(jm['uid'], '999888', reason: 'id 必须改名成 uid');
      expect(jm['token'], 'logged_in', reason: '缺 token 会被判成未登录');
      expect(jm['account'], ['user', 'pass']);
      expect(jm['name'], '某用户');
    });

    test('nhentai 补 token 与 name 占位', () async {
      final pkg = p.join(workspace.path, 'nh.picadata');
      await File(pkg).writeAsBytes(buildPackage(extraFiles: {
        'comic_source/nhentai.data': utf8.encode('{"account":"ok"}'),
      }));

      await UserDataTransfer.import(pkg);

      final nh = await readJson('comic_source/nhentai.data');
      expect(nh['token'], 'logged_in');
      expect(nh['name'], 'Nhentai');
    });

    test('Komiic 的文件名从大写 K 改成小写内置源名', () async {
      final pkg = p.join(workspace.path, 'km.picadata');
      await File(pkg).writeAsBytes(buildPackage(extraFiles: {
        'comic_source/Komiic.data':
            utf8.encode('{"token":"t1","account":["a","b"]}'),
      }));

      await UserDataTransfer.import(pkg);

      expect(await File(p.join(dataPath, 'comic_source/komiic.data')).exists(),
          isTrue);
      final km = await readJson('comic_source/komiic.data');
      expect(km['token'], 't1');
    });

    test('结构一致的源原样保留', () async {
      final pkg = p.join(workspace.path, 'pc.picadata');
      await File(pkg).writeAsBytes(buildPackage(extraFiles: {
        'comic_source/picacg.data': utf8.encode(
          '{"token":"tok","user":{"id":1},"account":["a","b"]}',
        ),
      }));

      await UserDataTransfer.import(pkg);

      final pc = await readJson('comic_source/picacg.data');
      expect(pc['token'], 'tok');
      expect(pc['account'], ['a', 'b']);
    });
  });

  // ── 导入：cookie 分发 ───────────────────────────────────────────────────
  group('导入 cookie', () {
    test('一份 cookies.db 分发到四个库', () async {
      final cookieBytes = utf8.encode('COOKIE-DB-BYTES');
      final pkg = p.join(workspace.path, 'ck.picadata');
      await File(pkg)
          .writeAsBytes(buildPackage(extraFiles: {'cookies.db': cookieBytes}));

      await UserDataTransfer.import(pkg);

      for (final relative in <String>[
        'comic_source/eh_cookies.db',
        'comic_source/jm_cookies.db',
        'comic_source/komiic/cookies.db',
        'cookies.db',
      ]) {
        final file = File(p.join(dataPath, relative));
        expect(await file.exists(), isTrue, reason: '缺少 $relative');
        expect(await file.readAsBytes(), cookieBytes, reason: '$relative 内容不符');
      }
    });
  });

  // ── 导入：sqlite 合并 ───────────────────────────────────────────────────
  group('导入数据库', () {
    test('目标为空时直接写入', () async {
      final historyBytes = buildDb((db) {
        db.execute('CREATE TABLE history ('
            'target text primary key, title text, subtitle text, cover text, '
            'time int, type int, ep int, page int, readEpisode text, '
            'max_page int)');
        db.execute("INSERT INTO history VALUES "
            "('t1','标题','副标题','',1,0,1,1,'',NULL)");
      });
      final pkg = p.join(workspace.path, 'h1.picadata');
      await File(pkg)
          .writeAsBytes(buildPackage(extraFiles: {'history.db': historyBytes}));

      await UserDataTransfer.import(pkg);

      final db =
          sqlite3.open(p.join(dataPath, 'history.db'), mode: OpenMode.readOnly);
      final count =
          db.select('select count(*) c from history').first['c'] as int;
      db.dispose();
      expect(count, 1);
    });

    test('目标已有数据时合并，且以导入包为准', () async {
      // 目标：t1（旧标题）、t2（仅本地有）
      final targetBytes = buildDb((db) {
        db.execute('CREATE TABLE history ('
            'target text primary key, title text)');
        db.execute("INSERT INTO history VALUES ('t1','本地旧标题')");
        db.execute("INSERT INTO history VALUES ('t2','仅本地')");
      });
      await File(p.join(dataPath, 'history.db')).writeAsBytes(targetBytes);
      // 导入包：t1（新标题）、t3
      final importBytes = buildDb((db) {
        db.execute('CREATE TABLE history ('
            'target text primary key, title text)');
        db.execute("INSERT INTO history VALUES ('t1','导入新标题')");
        db.execute("INSERT INTO history VALUES ('t3','仅导入')");
      });
      final pkg = p.join(workspace.path, 'h2.picadata');
      await File(pkg)
          .writeAsBytes(buildPackage(extraFiles: {'history.db': importBytes}));

      final result = await UserDataTransfer.import(pkg);
      expect(result.ok, isTrue, reason: result.message);

      final db =
          sqlite3.open(p.join(dataPath, 'history.db'), mode: OpenMode.readOnly);
      final rows =
          db.select('select target, title from history order by target');
      db.dispose();
      final map = {
        for (final r in rows) r['target'] as String: r['title'] as String,
      };
      expect(map['t1'], '导入新标题', reason: '主键冲突时以导入包为准');
      expect(map['t2'], '仅本地', reason: '仅本地有的记录必须保留');
      expect(map['t3'], '仅导入');
    });

    test('目标缺失的收藏夹表会被自动建出来', () async {
      // 目标只有 folder_order；导入包多一张自定义收藏夹表。
      final targetBytes = buildDb((db) {
        db.execute('CREATE TABLE folder_order ('
            'folder_name text primary key, order_value int)');
      });
      await File(p.join(dataPath, 'local_favorite.db'))
          .writeAsBytes(targetBytes);
      final importBytes = buildDb((db) {
        db.execute('CREATE TABLE folder_order ('
            'folder_name text primary key, order_value int)');
        db.execute('CREATE TABLE "百合"('
            'target text, name TEXT, author TEXT, type int, tags TEXT, '
            'cover_path TEXT, time TEXT, display_order int, '
            'primary key (target, type))');
        db.execute("INSERT INTO \"百合\" VALUES "
            "('c1','本子名','作者',0,'','','',1)");
      });
      final pkg = p.join(workspace.path, 'f1.picadata');
      await File(pkg).writeAsBytes(
          buildPackage(extraFiles: {'local_favorite.db': importBytes}));

      await UserDataTransfer.import(pkg);

      final db = sqlite3.open(p.join(dataPath, 'local_favorite.db'),
          mode: OpenMode.readOnly);
      final tables = db
          .select("select name from sqlite_master where type='table'")
          .map((r) => r['name'])
          .toList();
      expect(tables, contains('百合'), reason: '动态收藏夹表必须被建出来');
      final rows = db.select('select target, name from "百合"');
      db.dispose();
      expect(rows.length, 1);
      expect(rows.first['name'], '本子名');
    });

    test('列不一致时只搬共同列，不整表失败', () async {
      final targetBytes = buildDb((db) {
        db.execute('CREATE TABLE history ('
            'target text primary key, title text, extra_new_column text)');
      });
      await File(p.join(dataPath, 'history.db')).writeAsBytes(targetBytes);
      final importBytes = buildDb((db) {
        db.execute('CREATE TABLE history ('
            'target text primary key, title text)');
        db.execute("INSERT INTO history VALUES ('t9','来自导入')");
      });
      final pkg = p.join(workspace.path, 'h3.picadata');
      await File(pkg)
          .writeAsBytes(buildPackage(extraFiles: {'history.db': importBytes}));

      final result = await UserDataTransfer.import(pkg);

      expect(result.ok, isTrue, reason: result.message);
      final db =
          sqlite3.open(p.join(dataPath, 'history.db'), mode: OpenMode.readOnly);
      final rows = db.select('select target, title from history');
      db.dispose();
      expect(rows.length, 1);
      expect(rows.first['title'], '来自导入');
    });
  });

  // ── 往返 ────────────────────────────────────────────────────────────────
  group('导出后再导入', () {
    test('账号数据与设置能原样往返', () async {
      await writeFile('settings', List<String>.generate(121, (i) => 'v$i'));
      await writeFile('comic_source/picacg.data', {
        'token': 'tok',
        'account': ['a', 'b'],
      });
      final out = p.join(workspace.path, 'round.picadata');
      expect((await UserDataTransfer.export(outFile: out)).ok, isTrue);

      // 清空后用包恢复。
      await Directory(dataPath).delete(recursive: true);
      await Directory(dataPath).create(recursive: true);

      final result = await UserDataTransfer.import(out);
      expect(result.ok, isTrue, reason: result.message);
      final pc = await readJson('comic_source/picacg.data');
      expect(pc['token'], 'tok');
      final settings = (jsonDecode(
        await File(p.join(dataPath, 'settings')).readAsString(),
      ) as List)
          .map((e) => e.toString())
          .toList();
      expect(settings.first, 'v0');
    });
  });
}
