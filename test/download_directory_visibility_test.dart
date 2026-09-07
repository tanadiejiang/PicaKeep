import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/local_trash_store.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open(
          p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
  late Directory workspace;
  late Directory root;
  late List<String> savedSettings;
  late String savedMode;
  late PathProviderPlatform savedPaths;
  final manager = LocalLibraryManager();
  var fixture = 0;

  setUpAll(() async {
    savedSettings = List.of(appdata.settings);
    savedMode = managedDataSourceMode;
    savedPaths = PathProviderPlatform.instance;
    workspace = await Directory.systemTemp.createTemp('picakeep_pk02_');
    PathProviderPlatform.instance = _Paths(workspace);
    await App.init(dataPathOverride: p.join(workspace.path, 'data'));
  });

  setUp(() async {
    root = await Directory(p.join(workspace.path, 'fixture_${fixture++}'))
        .create();
    appdata.settings[22] = root.path;
    appdata.settings[localLibraryShowAllDatabaseRecordsSettingIndex] = '0';
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
    await manager.refresh();
  });

  tearDownAll(() async {
    LocalTrashStore.instance.dispose();
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    setManagedDataSourceMode(savedMode);
    PathProviderPlatform.instance = savedPaths;
    await workspace.delete(recursive: true);
  });

  Future<void> record(String directory,
      {String id = '123-abc', String title = 'Fixture'}) async {
    final db = sqlite3.open(p.join(root.path, 'download.db'));
    try {
      db.execute(
          'CREATE TABLE IF NOT EXISTS download (id TEXT PRIMARY KEY, title TEXT, subtitle TEXT, time INT, directory TEXT, size REAL, json TEXT)');
      db.execute('INSERT INTO download VALUES (?,?,?,?,?,?,?)', [
        id,
        title,
        '',
        1710000000000,
        directory,
        1.0,
        jsonEncode({
          'galleryTitle': title,
          'link': 'https://e-hentai.org/g/123/abc/',
          'pageCount': 1
        }),
      ]);
    } finally {
      db.dispose();
    }
  }

  Future<String> content(String name) async {
    final dir =
        await Directory(p.join(root.path, name)).create(recursive: true);
    await File(p.join(dir.path, '1.jpg')).writeAsBytes([1, 2, 3]);
    return dir.path;
  }

  for (final fullScan in [false, true]) {
    group(fullScan ? '完整本地库扫描' : '已下载元数据加载', () {
      Future<List<LocalLibraryComicItem>> load() async {
        if (fullScan) {
          await manager.refresh();
          return manager.getAll();
        }
        return manager.getManagedDownloads();
      }

      test('旧目录字段失效时找到 ID 目录且不修改数据库', () async {
        final expected = await content('123-abc');
        await record('old-directory');
        final items = await load();
        expect(items, hasLength(1));
        expect(
            p.normalize(items.single.fileSystemPath!), p.normalize(expected));
        expect(items.single.localStorageExists, isTrue);
        final db = sqlite3.open(p.join(root.path, 'download.db'));
        try {
          expect(
              db.select('SELECT directory FROM download').single['directory'],
              'old-directory');
        } finally {
          db.dispose();
        }
      });

      test('尝试清理过非法字符的历史目录名', () async {
        final expected = await content('Book_Name');
        await record('Book:Name');
        final items = await load();
        expect(items, hasLength(1));
        expect(
            p.normalize(items.single.fileSystemPath!), p.normalize(expected));
      });

      test('已有显式目录优先于 ID 目录', () async {
        final expected = await content('explicit');
        await content('123-abc');
        await record('explicit');
        expect(p.normalize((await load()).single.fileSystemPath!),
            p.normalize(expected));
      });

      test('绝对目录不重复拼接下载根目录', () async {
        final expected = await content('absolute');
        await record(expected);
        expect(p.normalize((await load()).single.fileSystemPath!),
            p.normalize(expected));
      });

      test('父目录存在不能证明缺失的嵌套目录存在', () async {
        await content('parent');
        await record('parent/missing');
        expect(await load(), isEmpty);
      });

      test('真实嵌套目录仍可读取', () async {
        final expected = await content('parent/chapter');
        await record('parent/chapter');
        expect(p.normalize((await load()).single.fileSystemPath!),
            p.normalize(expected));
      });

      test('旧字段与 ID 都失效时可回退标题目录', () async {
        final expected = await content('Fixture');
        await record('missing');
        expect(p.normalize((await load()).single.fileSystemPath!),
            p.normalize(expected));
      });

      test('同一真实目录的别名记录只展示一次', () async {
        await content('shared');
        await record('shared');
        await record('shared', id: '124-def');
        expect(await load(), hasLength(1));
      });

      test('回收站继续隐藏，清空后的历史索引不隐藏新下载', () async {
        final expected = await content('123-abc');
        await record('old-directory');
        Future<void> trash(String state) => LocalTrashStore.instance.upsert(
              LocalTrashRecordData(
                id: 'trash_${fixture}_$fullScan',
                state: state,
                itemKind: 'managed_download',
                itemId: 'old-id',
                title: 'Fixture',
                subtitle: '',
                cover: '',
                sourceLabel: '',
                originalPath: expected,
                trashedPath: '',
                deletedAtMillis: 0,
                sizeBytes: 0,
                snapshotJson: '{}',
                sourceDbPath: p.join(root.path, 'download.db'),
                sourceDbId: '123-abc',
                sourceDirectory: 'old-directory',
              ),
            );
        await trash(localTrashStateTrashed);
        expect(await load(), isEmpty);
        await trash(localTrashStatePurged);
        expect(await load(), hasLength(1));
      });

      test('真实缺失记录继续过滤，显示全部时保留占位', () async {
        await record('missing');
        expect(await load(), isEmpty);
        appdata.settings[localLibraryShowAllDatabaseRecordsSettingIndex] = '1';
        final items = await load();
        expect(items, hasLength(1));
        expect(items.single.localStorageExists, isFalse);
      });
    });
  }
}
