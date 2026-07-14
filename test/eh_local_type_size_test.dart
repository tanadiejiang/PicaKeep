import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/local_trash_store.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final Directory root;

  @override
  Future<String?> getApplicationCachePath() async {
    final dir = Directory('${root.path}${Platform.pathSeparator}cache');
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String?> getApplicationSupportPath() async {
    final dir = Directory('${root.path}${Platform.pathSeparator}support');
    await dir.create(recursive: true);
    return dir.path;
  }
}

Future<void> _writeEhDownloadRecord(
  Directory root, {
  required String id,
  required String directory,
  required Map<String, dynamic> data,
}) async {
  await Directory('${root.path}${Platform.pathSeparator}$directory')
      .create(recursive: true);

  final database =
      sqlite3.open('${root.path}${Platform.pathSeparator}download.db');
  try {
    database.execute('''
      create table download(
        id text primary key,
        title text,
        subtitle text,
        time int,
        directory text,
        size real,
        json text
      )
    ''');
    database.execute(
      'insert into download values (?,?,?,?,?,?,?)',
      [
        id,
        'EH sqlite row title',
        'EH sqlite row uploader',
        1710000000000,
        directory,
        999.0,
        jsonEncode(data),
      ],
    );
  } finally {
    database.dispose();
  }
}

/// 10号计划验证：本地库扫描路径 (`local_library_static.dart::_parseDownloadedItem`)
/// 现已委托给权威实现 `parseDownloadedItemRecordJson`。这里聚焦验证 EH 画廊
/// 记录经该路径解析后：
///   1. 类型被正确识别为 DownloadedGallery（DownloadType.ehentai），而不是
///      被 `id.contains('-')` 分支误判成 CustomDownloadedItem（DownloadType.other）；
///   2. size 能被正确读出（DownloadedGallery 读 json["size"]，与 toJson 写入的
///      "size" 键一致），不再因字段名不匹配（CustomDownloadedItem 读 "comicSize"）
///      而显示“未知大小”。
///
/// 私有函数 `_parseDownloadedItem` 无法从测试直接访问，故断言其委托目标
/// `parseDownloadedItemRecordJson`，与计划步骤4一致。
void main() {
  open.overrideFor(
    OperatingSystem.windows,
    () => DynamicLibrary.open(
      '${Directory.current.path}${Platform.pathSeparator}windows'
      '${Platform.pathSeparator}sqlite3.dll',
    ),
  );

  group('EH 本地记录类型与大小识别（10号计划）', () {
    test('含连字符的 EH 画廊 id（123-abc）→ DownloadedGallery，size 正确读出', () {
      // DownloadedGallery.toJson 真实写入形态：size 键 + galleryTitle 键。
      final json = jsonEncode({
        'galleryTitle': 'EH 测试画廊',
        'subtitle': 'sub',
        'uploader': '上传者',
        'link': 'https://e-hentai.org/g/220980/abc123def/',
        'coverPath': '',
        'size': 123.45,
        'tagList': ['tagA'],
        'pageCount': 20,
      });

      final parsed = parseDownloadedItemRecordJson('220980-abc123def', json);

      expect(parsed, isA<DownloadedGallery>(),
          reason: '含连字符的 EH id 必须被 EH 精准拦截，不能落入 CustomDownloadedItem 分支');
      expect(parsed!.type, DownloadType.ehentai);
      expect(parsed.comicSize, 123.45,
          reason: 'DownloadedGallery.comicSize 读 json["size"]，应等于写入的真实 size 值');
      expect(parsed.comicSize, isNotNull, reason: '大小不应为 null（即不应显示“未知大小”）');
    });

    test('纯数字 EH 画廊 id（220980）→ DownloadedGallery，size 正确读出', () {
      final json = jsonEncode({
        'galleryTitle': 'EH 纯数字 id 画廊',
        'link': 'https://e-hentai.org/g/220980/xyz/',
        'size': 88.0,
        'pageCount': 5,
      });

      final parsed = parseDownloadedItemRecordJson('220980', json);

      expect(parsed, isA<DownloadedGallery>());
      expect(parsed!.type, DownloadType.ehentai);
      expect(parsed.comicSize, 88.0);
    });

    test(
        '回归防护：若同一 json 被当作 CustomDownloadedItem 解析，comicSize 读不到 size 键（=null）',
        () {
      // 说明修复前的症状根因：CustomDownloadedItem 读的是 "comicSize" 键，
      // 而 EH json 只有 "size" 键，两者不匹配 → comicSize == null → “未知大小”。
      final ehJson = {
        'galleryTitle': 'EH 画廊',
        'link': 'https://e-hentai.org/g/220980/abc/',
        'size': 55.5,
      };
      final asCustom = CustomDownloadedItem.fromJson(ehJson);
      expect(asCustom.comicSize, isNull,
          reason: '误判为 CustomDownloadedItem 时读不到 size，正是“大小未知”的根因');
      expect(asCustom.type, DownloadType.other, reason: '误判分支会把 EH 记录标成“其他”类型');
    });

    test('EH 记录不会被 _isRescannedLocalRecord 语义误伤（非 DownloadedComic 实例）', () {
      // 计划“不执行的内容”第5条：确认修复后 EH 记录是 DownloadedGallery，
      // 不会进入 picacg 专用的 `item is DownloadedComic` 退化判断分支。
      final json = jsonEncode({
        'galleryTitle': 'EH',
        'link': 'https://e-hentai.org/g/220980/abc/',
        'size': 10.0,
      });
      final parsed = parseDownloadedItemRecordJson('220980-abc', json);
      expect(parsed, isNot(isA<DownloadedComic>()));
      expect(parsed, isA<DownloadedGallery>());
    });
  });

  group('EH 本地 SQLite 扫描入口（10号计划）', () {
    late final Directory workspace;
    late final LocalLibraryManager manager;
    late final List<String> originalSettings;
    late final String originalManagedDataSourceMode;
    late final PathProviderPlatform originalPathProvider;
    Directory? fixtureRoot;
    var fixtureIndex = 0;

    setUpAll(() async {
      originalPathProvider = PathProviderPlatform.instance;
      originalSettings = List<String>.from(appdata.settings);
      originalManagedDataSourceMode = managedDataSourceMode;
      workspace =
          await Directory.systemTemp.createTemp('picakeep_eh_local_scan_');
      PathProviderPlatform.instance = _FakePathProvider(workspace);
      await App.init(
        dataPathOverride: '${workspace.path}${Platform.pathSeparator}data',
      );
      manager = LocalLibraryManager();
    });

    setUp(() async {
      fixtureRoot = Directory(
        '${workspace.path}${Platform.pathSeparator}fixture_${fixtureIndex++}',
      );
      await fixtureRoot!.create(recursive: true);
      appdata.settings[22] = fixtureRoot!.path;
      appdata.settings[localLibraryShowAllDatabaseRecordsSettingIndex] = '0';
      appdata.settings[localLibraryListSortSettingIndex] = 'time_desc';
      setManagedDataSourceMode(managedDataSourceModeCurrentOnly);

      // Clear singleton state before the fixture adds its SQLite database.
      await manager.refresh();
    });

    tearDown(() async {
      LocalTrashStore.instance.dispose();
      final root = fixtureRoot;
      if (root != null && root.existsSync()) {
        await root.delete(recursive: true);
      }
      await manager.refresh();
    });

    tearDownAll(() async {
      appdata.settings
        ..clear()
        ..addAll(originalSettings);
      setManagedDataSourceMode(originalManagedDataSourceMode);
      await manager.refresh();
      LocalTrashStore.instance.dispose();
      PathProviderPlatform.instance = originalPathProvider;
      if (workspace.existsSync()) {
        await workspace.delete(recursive: true);
      }
    });

    test('元数据加载入口保留平铺 EH 记录的字符串 size', () async {
      const id = '220980-abc123def';
      await _writeEhDownloadRecord(
        fixtureRoot!,
        id: id,
        directory: id,
        data: {
          'galleryTitle': 'EH 平铺记录',
          'subtitle': 'EH subtitle',
          'uploader': 'EH uploader',
          'link': 'https://e-hentai.org/g/220980/abc123def/',
          'coverPath': '',
          'size': '123.45',
          'tagList': ['female:fox girl'],
          'pageCount': 20,
        },
      );

      final items = await manager.getManagedDownloads();
      final item = items.singleWhere((item) => item.originalId == id);

      expect(item.type, DownloadType.ehentai);
      expect(item.sourceDisplayName, 'E-Hentai');
      expect(item.comicSize, 123.45);
    });

    test('完整刷新扫描入口保留旧 gallery 嵌套记录的字符串 size', () async {
      const id = '220981-def456abc';
      await _writeEhDownloadRecord(
        fixtureRoot!,
        id: id,
        directory: id,
        data: {
          'gallery': {
            'title': 'EH 旧嵌套记录',
            'subTitle': 'EH legacy subtitle',
            'uploader': 'EH legacy uploader',
            'link': 'https://e-hentai.org/g/220981/def456abc/',
            'cover': '',
            'tags': ['parody:azur lane'],
          },
          'size': '67.25',
          'pageCount': '28',
        },
      );

      await manager.refresh();
      final items = await manager.getAll();
      final item = items.singleWhere((item) => item.originalId == id);

      expect(item.type, DownloadType.ehentai);
      expect(item.sourceDisplayName, 'E-Hentai');
      expect(item.comicSize, 67.25);
    });
  });
}
