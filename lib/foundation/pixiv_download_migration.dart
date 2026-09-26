/// 把 Pixiv 的下载内容从旧根搬到 Pixiv 专属根（36 号）。
///
/// ## 为什么需要它
///
/// 36 号之前 Pixiv 跟随默认下载根，所以老内容都躺在 `<数据目录>/download` 里
/// —— 用户真机截图看到的就是「Pixiv 的目录 / 单图 / zip 裸露在 download 里」。
/// 把默认根改成 `<数据目录>/download_pixiv` 只影响**新**下载，
/// 已经落盘的那些必须显式搬一次，否则"裸露"的问题一点没解决。
///
/// ## 与 `download_directory_migration.dart` 的区别
///
/// 那个是"**整目录**换位置"（用户换「本应用下载目录」时把所有内容都搬走），
/// 最小单位是"根目录下的每一个条目"，没有来源过滤。
/// 本文件只挑出 **Pixiv 的那几条**搬走，其余原样留在原处 —— 两者不能互相替代。
///
/// ## 实体与记录必须成对搬
///
/// 每个下载根各有自己的 `download.db`（`OnlineDownloadManager._openDownloadDb`），
/// 记录里的 `directory` 列是**绝对路径**。所以一次搬迁要做三件事：
///
/// 1. 把实体（目录 / 单图 / zip）移到新根；
/// 2. 在新根的 db 里 upsert 该记录（`directory` 指向新路径）；
/// 3. 从旧根的 db 里删除该记录。
///
/// 只搬文件不改记录 → 列表还指向旧路径（打不开）；
/// 只改记录不搬文件 → 列表指向不存在的路径（同样打不开）。
///
/// ## 可重入
///
/// 目标已存在同名实体的直接跳过（但记录照搬）。中断后重跑不会重复搬运，
/// 也不会把已经搬过去的内容再搬一次。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/download_model.dart';
import 'package:sqlite3/sqlite3.dart';

/// 下载根里的数据库文件名（与 `OnlineDownloadManager` 一致）。
const String kPixivMigrationDownloadDbName = 'download.db';

/// 迁移结果。
class PixivMigrationResult {
  const PixivMigrationResult({
    required this.movedEntries,
    required this.skippedEntries,
    required this.failures,
  });

  /// 实际移动了实体的条数。
  final int movedEntries;

  /// 只搬了记录、没动实体的条数（目标已存在，或源实体已不在）。
  final int skippedEntries;

  /// 出错的条目描述（每条一句话）。
  final List<String> failures;

  /// 这次有没有需要搬的东西。
  bool get hasWork => movedEntries > 0 || skippedEntries > 0;
}

class _PixivRow {
  _PixivRow({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.time,
    required this.directory,
    required this.size,
    required this.json,
  });

  final String id;
  final String title;
  final String subtitle;
  final Object? time;
  final String directory;
  final Object? size;
  final String json;
}

/// 去掉首尾空白与**结尾的分隔符**。
///
/// ⚠️ **不要把路径里的 `\` 统一换成 `/`**：那样 `p.join(target, name)` 在 Windows 上
/// 会拼出 `C:/...\name` 这种混合分隔符的路径，写进 db 的 `directory` 就不再是
/// 规范的绝对路径（真机上表现为"列表里点不开"）。
/// 归一只用于**比较与拼接**，不改变分隔符本身。
String _normalize(String path) {
  var value = path.trim();
  while (value.length > 1 &&
      (value.endsWith('/') || value.endsWith('\\'))) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

Database _openDb(String rootPath) {
  final db = sqlite3.open(p.join(rootPath, kPixivMigrationDownloadDbName));
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
  return db;
}

/// 这是不是一条 Pixiv 记录。
///
/// 判据与「已下载」页的过滤**共用** [isPixivDownloadedItem]：两处口径一旦分叉，
/// 就会出现"页面上过滤掉了、迁移却漏掉一条"（或反过来）这种对不上的现象。
bool _rowIsPixiv(String id, String rawJson) {
  if (rawJson.isNotEmpty) {
    final parsed = parseDownloadedItemRecordJson(id, rawJson);
    if (parsed != null && isPixivDownloadedItem(parsed)) {
      return true;
    }
  }
  // json 解析不出来（老式行）时只能靠 id 前缀。
  return isPixivDownloadId(id);
}

List<_PixivRow> _readPixivRows(Database db) {
  final result = db.select(
    'select id, title, subtitle, time, directory, size, json from download',
  );
  final rows = <_PixivRow>[];
  for (final row in result) {
    final id = row['id']?.toString() ?? '';
    if (id.isEmpty) {
      continue;
    }
    final json = row['json']?.toString() ?? '';
    if (!_rowIsPixiv(id, json)) {
      continue;
    }
    rows.add(
      _PixivRow(
        id: id,
        title: row['title']?.toString() ?? '',
        subtitle: row['subtitle']?.toString() ?? '',
        time: row['time'],
        directory: row['directory']?.toString() ?? '',
        size: row['size'],
        json: json,
      ),
    );
  }
  return rows;
}

bool _entityExists(String path) {
  if (path.isEmpty) {
    return false;
  }
  return File(path).existsSync() || Directory(path).existsSync();
}

Future<void> _moveEntity(String from, String to) async {
  final directory = Directory(from);
  if (directory.existsSync()) {
    await directory.rename(to);
    return;
  }
  await File(from).rename(to);
}

void _upsertRow(Database db, _PixivRow row, String newDirectory) {
  db.execute(
    'insert or replace into download '
    '(id, title, subtitle, time, directory, size, json) values (?,?,?,?,?,?,?)',
    <Object?>[
      row.id,
      row.title,
      row.subtitle,
      row.time,
      newDirectory,
      row.size,
      row.json,
    ],
  );
}

/// 旧根里有多少条 Pixiv 记录（用于决定"要不要给用户看迁移入口"）。
///
/// 只读，不改任何东西。根目录或 db 不存在时返回 0。
Future<int> countPixivEntriesInRoot(String rootPath) async {
  final root = _normalize(rootPath);
  if (root.isEmpty) {
    return 0;
  }
  final dbFile = File(p.join(root, kPixivMigrationDownloadDbName));
  if (!dbFile.existsSync()) {
    return 0;
  }
  Database? db;
  try {
    db = _openDb(root);
    return _readPixivRows(db).length;
  } catch (_) {
    return 0;
  } finally {
    db?.dispose();
  }
}

/// 把 Pixiv 的内容从 [fromRoot] 搬到 [toRoot]。
///
/// [onProgress] 每条回调一次（`current` 从 1 开始，`label` 是作品名）。
/// 单个条目出错只记进 [PixivMigrationResult.failures]，**不中断**其余条目 ——
/// 一条坏记录不该让用户剩下几十条都搬不动。
Future<PixivMigrationResult> migratePixivDownloadEntries({
  required String fromRoot,
  required String toRoot,
  void Function(int current, int total, String label)? onProgress,
}) async {
  const empty = PixivMigrationResult(
    movedEntries: 0,
    skippedEntries: 0,
    failures: <String>[],
  );
  final source = _normalize(fromRoot);
  final target = _normalize(toRoot);
  if (source.isEmpty || target.isEmpty || source == target) {
    return empty;
  }
  if (!File(p.join(source, kPixivMigrationDownloadDbName)).existsSync()) {
    return empty;
  }
  await Directory(target).create(recursive: true);

  Database? sourceDb;
  Database? targetDb;
  var moved = 0;
  var skipped = 0;
  final failures = <String>[];
  try {
    sourceDb = _openDb(source);
    targetDb = _openDb(target);
    final rows = _readPixivRows(sourceDb);
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      onProgress?.call(i + 1, rows.length, row.title);
      // 让出事件循环：几百条记录时进度条才有机会刷新。
      await Future<void>.delayed(Duration.zero);
      final baseName = p.basename(_normalize(row.directory));
      if (baseName.isEmpty) {
        failures.add('${row.title}（记录里的目录为空）');
        continue;
      }
      final targetPath = p.join(target, baseName);
      try {
        if (!_entityExists(row.directory)) {
          // 内容已经不在了（被删或进了回收站）：记录照搬并指向新路径，
          // 否则旧 db 里会永远留着一条打不开的记录。
          skipped++;
        } else if (_entityExists(targetPath)) {
          // 目标已有同名实体：**不覆盖**，只把记录指过去（可重入的基础）。
          skipped++;
        } else {
          await _moveEntity(row.directory, targetPath);
          moved++;
        }
        _upsertRow(targetDb, row, targetPath);
        sourceDb.execute('delete from download where id = ?', <Object?>[row.id]);
      } catch (e) {
        failures.add('${row.title}：$e');
      }
    }
  } catch (e) {
    failures.add('迁移失败：$e');
  } finally {
    sourceDb?.dispose();
    targetDb?.dispose();
  }
  return PixivMigrationResult(
    movedEntries: moved,
    skippedEntries: skipped,
    failures: failures,
  );
}
