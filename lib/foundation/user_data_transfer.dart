/// 用户数据导入 / 导出，**格式与原项目 PicaComic 的 `.picadata` 互通**。
///
/// ## 包格式
///
/// `.picadata` 就是一个 zip，内含（不含下载时）：
///
/// ```text
/// appdata               设置的 JSON —— 磁盘上叫 `settings`，打包时改名（与原项目一致）
/// history.db            阅读历史
/// local_favorite.db     本地收藏（含自定义收藏夹，每个收藏夹是一张表）
/// cookies.db            共用 cookie 库（nhentai 等走 SingleInstanceCookieJar）
/// comic_source/<name>   各源账号数据与各源独立 cookie 库
/// ```
///
/// ## 与原项目的差异（导入时必须转换，否则"数据在但显示未登录"）
///
/// 1. **cookie 库布局**
///    原项目共用一个 `cookies.db`；PicaKeep 各源独立。导入时要把那一份分发到：
///    `eh_cookies.db`、`jm_cookies.db`、`komiic/cookies.db`，以及共用的
///    `cookies.db`。分发是安全的 —— `loadForRequest(Uri)` 按域过滤，
///    某个库里多存了别的域的 cookie 不会被发出去。
///
/// 2. **账号字段**
///    - JM：原项目写 `id`，PicaKeep 要 `uid`，并需要 `token: 'logged_in'`
///      这个字面量标记（`ComicSource.isLoggedIn` 只看 `token` 非空）。
///    - nhentai：原数据常常只有 `{"account":"ok"}`，需要补 `token` 与 `name`。
///    - Komiic：文件名大小写不同（原项目 `Komiic.data` → `komiic.data`）。
///
/// 3. **settings 数组**
///    两边都是按索引存值的数组。实测前 95 项**含义一一对应**（PicaKeep 从原项目
///    派生，之后纯追加到 121 项），所以导入时只覆盖 `min(导入长度, 95)` 项，
///    **保留 PicaKeep 自己新增的那些**，避免把新功能的设置抹掉。
///
/// 4. **不含下载**
///    按需求不打包 `download.db` 与漫画文件。导入时若包里意外带了下载数据，
///    也只取其中的 `comic_source/`（原项目的打包逻辑会把非源目录塞进 download/）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/user_data_transfer_sqlite.dart';

/// 原项目 settings 数组里与 PicaKeep **含义一致**的前缀长度。
///
/// 实测依据：原项目 settings 默认 95 项且带含义注释，PicaKeep 121 项；
/// 抽查 index 8（代理）、22（下载目录）、27（颜色）、32（深色模式）、
/// 45/46（webdav）、50（语言）用法完全一致，说明是纯追加关系。
/// 导入时只覆盖这个前缀，PicaKeep 新增的设置项保持不动。
const int kPicacomicSettingsPrefixLength = 95;

/// 导出包名（与原项目一致）。
const String kUserDataFileExtension = 'picadata';
const String kUserDataDefaultFileName = 'userData.$kUserDataFileExtension';

/// 导入 / 导出的结果。
class UserDataTransferResult {
  const UserDataTransferResult({
    required this.ok,
    required this.message,
    this.details = const <String>[],
  });

  final bool ok;
  final String message;

  /// 逐项结果，用于让用户看清到底搬了什么、跳过了什么。
  final List<String> details;
}

/// 用户数据导入 / 导出。
///
/// 所有路径都基于 [App.dataPath]，与 `ComicSource.filePath`、各 manager 的
/// 存放位置保持一致。
class UserDataTransfer {
  UserDataTransfer._();

  static String get _dataPath => App.dataPath;
  static String get _comicSourceDir => p.join(_dataPath, 'comic_source');

  /// 需要打进包里的**共用**文件（相对 [App.dataPath]）。
  static const List<String> _sharedFiles = <String>[
    'settings',
    'history.db',
    'local_favorite.db',
    'cookies.db',
  ];

  // ── 导出 ─────────────────────────────────────────────────────────────────

  /// 打包用户数据到 [outFile]。
  ///
  /// [includeDownloads] 目前恒为 false 的效果（按需求不含下载）；保留参数是为了
  /// 与原项目的两个导出选项对齐，将来若要支持下载数据可直接复用。
  static Future<UserDataTransferResult> export({
    required String outFile,
    bool includeDownloads = false,
  }) async {
    final details = <String>[];
    try {
      final archive = Archive();

      void addBytes(String name, List<int> bytes) {
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      // settings 打包时**改名为 appdata**，与原项目导出一致 ——
      // 这样产出的文件能被原项目直接导入，反之亦然。
      for (final relative in _sharedFiles) {
        final file = File(p.join(_dataPath, relative));
        if (!await file.exists()) {
          details.add('跳过 $relative（不存在）');
          continue;
        }
        final bytes = await file.readAsBytes();
        final entryName = relative == 'settings' ? 'appdata' : relative;
        addBytes(entryName, bytes);
        details.add('$entryName（${_kb(bytes.length)}）');
      }

      // 各源账号数据 + 各源独立 cookie 库，保持 comic_source/ 下的相对结构。
      final sourceDir = Directory(_comicSourceDir);
      if (await sourceDir.exists()) {
        await for (final entity in sourceDir.list(recursive: true)) {
          if (entity is! File) continue;
          final relative =
              p.relative(entity.path, from: _dataPath).replaceAll('\\', '/');
          // 日志与缓存不属于用户数据。
          if (relative.contains('/logs/') || relative.contains('/cache/')) {
            continue;
          }
          final bytes = await entity.readAsBytes();
          addBytes(relative, bytes);
          details.add('$relative（${_kb(bytes.length)}）');
        }
      }

      if (includeDownloads) {
        // 明确不做：下载数据量大（实测原始库 507 MB），且按需求排除。
        details.add('已按设置排除下载数据');
      }

      final encoded = ZipEncoder().encode(archive);
      final out = File(outFile);
      await out.parent.create(recursive: true);
      await out.writeAsBytes(encoded, flush: true);
      details.add('输出：${out.path}（${_kb(encoded.length)}）');
      return UserDataTransferResult(
        ok: true,
        message: '已导出 ${details.length - 1} 项',
        details: details,
      );
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, 'UserDataTransfer', 'export failed: $e\n$s');
      return UserDataTransferResult(
        ok: false,
        message: '导出失败：$e',
        details: details,
      );
    }
  }

  // ── 导入 ─────────────────────────────────────────────────────────────────

  /// 从 `.picadata` 导入。
  ///
  /// 策略：**账号 / cookie / 设置按包内内容覆盖，历史与本地收藏合并**。
  /// 合并而不是覆盖，是因为这两份数据里"多"比"少"好 —— 覆盖会把用户在本应用
  /// 里积累的记录抹掉，而合并最坏只是留下一条重复的阅读记录。
  static Future<UserDataTransferResult> import(String picadataPath) async {
    final details = <String>[];
    try {
      final file = File(picadataPath);
      if (!await file.exists()) {
        return const UserDataTransferResult(
          ok: false,
          message: '文件不存在',
        );
      }
      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());

      // 先把 zip 摊成 名字 -> 字节，后面按名字取用。
      final entries = <String, Uint8List>{};
      for (final item in archive) {
        if (!item.isFile) continue;
        final name = item.name.replaceAll('\\', '/');
        entries[name] = Uint8List.fromList(item.content as List<int>);
      }
      if (entries.isEmpty) {
        return const UserDataTransferResult(
          ok: false,
          message: '压缩包是空的',
        );
      }

      await _importSettings(entries, details);
      await _importCookies(entries, details);
      await _importComicSources(entries, details);
      await _importDatabase(entries, 'history.db', details);
      await _importDatabase(entries, 'local_favorite.db', details);

      return UserDataTransferResult(
        ok: true,
        message: '导入完成（${details.length} 项）',
        details: details,
      );
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, 'UserDataTransfer', 'import failed: $e\n$s');
      return UserDataTransferResult(
        ok: false,
        message: '导入失败：$e',
        details: details,
      );
    }
  }

  /// settings：只覆盖与原项目含义一致的前缀，保留本应用新增的项。
  static Future<void> _importSettings(
    Map<String, Uint8List> entries,
    List<String> details,
  ) async {
    // 原项目打包时把 settings 改名为 appdata；两种名字都认。
    final raw = entries['appdata'] ?? entries['settings'];
    if (raw == null) {
      details.add('跳过 设置（包里没有 appdata/settings）');
      return;
    }
    final decoded = jsonDecode(utf8.decode(raw));
    if (decoded is! List) {
      details.add('跳过 设置（内容不是数组）');
      return;
    }
    final imported = decoded.map((e) => e?.toString() ?? '').toList();

    final target = File(p.join(_dataPath, 'settings'));
    List<String> current = <String>[];
    if (await target.exists()) {
      try {
        final existing = jsonDecode(await target.readAsString());
        if (existing is List) {
          current = existing.map((e) => e?.toString() ?? '').toList();
        }
      } catch (_) {
        // 现有设置读不出来就当作空，后面按长度补齐。
      }
    }

    // 只取前缀长度内的项；包比前缀短就取包的整个长度。
    final take = imported.length < kPicacomicSettingsPrefixLength
        ? imported.length
        : kPicacomicSettingsPrefixLength;
    if (current.length < imported.length) {
      current = List<String>.of(current)
        ..addAll(List<String>.filled(imported.length - current.length, ''));
    }
    for (var i = 0; i < take; i++) {
      current[i] = imported[i];
    }
    await target.writeAsString(jsonEncode(current), flush: true);
    details.add('设置（覆盖前 $take 项，保留本应用新增的 '
        '${current.length - take} 项）');
  }

  /// 共用 cookie 库分发到各源独立库。
  static Future<void> _importCookies(
    Map<String, Uint8List> entries,
    List<String> details,
  ) async {
    final raw = entries['cookies.db'];
    if (raw == null) {
      details.add('跳过 cookie（包里没有 cookies.db）');
      return;
    }
    // 目标位置见各源的 CookieJarSql 构造：EH / JM / Komiic 各自独立，
    // nhentai 走共用库。分发是安全的：loadForRequest 按域过滤。
    final targets = <String>[
      p.join(_comicSourceDir, 'eh_cookies.db'),
      p.join(_comicSourceDir, 'jm_cookies.db'),
      p.join(_comicSourceDir, 'komiic', 'cookies.db'),
      p.join(_dataPath, 'cookies.db'),
    ];
    for (final target in targets) {
      final out = File(target);
      await out.parent.create(recursive: true);
      await out.writeAsBytes(raw, flush: true);
    }
    details.add('cookie（分发到 ${targets.length} 个源库）');
  }

  /// 各源账号数据：按目标源的字段要求做适配后写入。
  static Future<void> _importComicSources(
    Map<String, Uint8List> entries,
    List<String> details,
  ) async {
    // 源文件名映射：包里的名字 -> 本应用的文件名。
    // Komiic 在原项目里是自定义 JS 源（`Komiic.data` 大写 K），
    // 本应用是内置源（`komiic`），文件名必须改。
    const rename = <String, String>{
      'comic_source/Komiic.data': 'comic_source/komiic.data',
    };

    var count = 0;
    for (final entry in entries.entries) {
      final name = entry.key;
      if (!name.startsWith('comic_source/')) continue;
      // 只处理账号数据；cookie 库已经在上一步分发过了。
      if (!name.endsWith('.data')) continue;

      final targetName = rename[name] ?? name;
      final targetPath = p.join(_dataPath, targetName);
      final sourceKey = p.basenameWithoutExtension(targetName);

      Map<String, dynamic> data;
      try {
        final decoded = jsonDecode(utf8.decode(entry.value));
        if (decoded is! Map) {
          details.add('跳过 $targetName（不是 JSON 对象）');
          continue;
        }
        data = decoded.map((k, v) => MapEntry(k.toString(), v));
      } catch (e) {
        details.add('跳过 $targetName（解析失败）');
        continue;
      }

      data = _adaptSourceData(sourceKey, data);
      final out = File(targetPath);
      await out.parent.create(recursive: true);
      await out.writeAsString(jsonEncode(data), flush: true);
      count++;
    }
    details.add('账号数据（$count 个源）');
  }

  /// 按目标源的字段约定补齐 / 改名。
  ///
  /// 不做这步的后果是"数据明明搬过来了，界面却显示未登录" ——
  /// 因为 `ComicSource.isLoggedIn` 只看 `token` 是否非空。
  static Map<String, dynamic> _adaptSourceData(
    String sourceKey,
    Map<String, dynamic> data,
  ) {
    switch (sourceKey) {
      case 'jm':
        // 原项目：{account, name, id} → 本应用：{account, name, uid, token}
        final result = Map<String, dynamic>.of(data);
        if (!result.containsKey('uid') && result.containsKey('id')) {
          result['uid'] = result['id'];
        }
        result['token'] = 'logged_in';
        return result;
      case 'nhentai':
        // 原数据常常只有 {account:"ok"}；token 判登录、name 供显示。
        final result = Map<String, dynamic>.of(data);
        result['token'] = 'logged_in';
        final name = result['name']?.toString() ?? '';
        if (name.isEmpty) {
          // 'Nhentai' 是该源登录流程写入的固定占位（见 nhentai.dart 注释），
          // 不是真实用户名。
          result['name'] = 'Nhentai';
        }
        return result;
      default:
        return data;
    }
  }

  /// 数据库类数据（历史 / 本地收藏）：用 sqlite 的 ATTACH 做**合并**。
  ///
  /// 合并而不是替换：这两份数据里"多"比"少"好。用 `INSERT OR REPLACE` 让
  /// 同名主键以导入包为准，其余保留，最坏只是留下重复记录。
  static Future<void> _importDatabase(
    Map<String, Uint8List> entries,
    String fileName,
    List<String> details,
  ) async {
    final raw = entries[fileName];
    if (raw == null) {
      details.add('跳过 $fileName（包里没有）');
      return;
    }
    final target = File(p.join(_dataPath, fileName));
    // 目标库不存在时直接落盘即可（新装场景最常见）。
    if (!await target.exists() || await target.length() == 0) {
      await target.parent.create(recursive: true);
      await target.writeAsBytes(raw, flush: true);
      details.add('$fileName（目标为空，直接写入）');
      return;
    }
    // 合并需要 sqlite 运行时；放在这里 import 避免核心逻辑被数据库实现绑死。
    final merged = await mergeSqliteDatabases(
      targetPath: target.path,
      sourceBytes: raw,
    );
    details.add(merged ? '$fileName（已合并）' : '$fileName（目标为空，已写入）');
  }

  static String _kb(int bytes) =>
      bytes < 1024 ? '$bytes B' : '${(bytes / 1024).toStringAsFixed(1)} KB';
}
