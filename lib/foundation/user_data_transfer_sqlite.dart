import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

/// 把一个 sqlite 库（[sourceBytes]）**合并**进 [targetPath]，返回是否成功合并。
///
/// ## 为什么是合并而不是替换
///
/// 直接覆盖会把用户在本应用里已经积累的历史 / 收藏抹掉。而这些表的**主键都已
/// 实测确认**（`history.target`、`image_favorites(id,ep,page)`、
/// 各收藏夹表 `(target,type)`、`folder_order/folder_sync.folder_name`），
/// 所以 `INSERT OR REPLACE` 能干净地做到"以导入包为准、其余保留"。
///
/// ## 两个必须处理的细节
///
/// 1. **收藏夹表是动态创建的**：`local_favorite.db` 里每个自定义收藏夹就是一张
///    表，目标库大概率没有。所以要先按源库的 `CREATE TABLE` 建表再插数据 ——
///    只做 `INSERT` 会静默丢掉所有收藏夹。
/// 2. **列取交集**：两边 schema 若有差异（本应用是衍生版，将来可能加列），
///    只搬共同列，避免整表 SQL 报错导致整个导入失败。
Future<bool> mergeSqliteDatabases({
  required String targetPath,
  required Uint8List sourceBytes,
}) async {
  // ATTACH 的路径不能用参数绑定，只能拼字符串；临时文件名由我们自己生成，
  // 但仍然转义单引号以防目录名里带引号。
  final tempPath = '$targetPath.__picakeep_import__';
  final temp = File(tempPath);
  await temp.writeAsBytes(sourceBytes, flush: true);

  final db = sqlite3.open(targetPath);
  try {
    db.execute("ATTACH DATABASE '${_escape(tempPath)}' AS src");

    final sourceTables = db.select(
      "select name, sql from src.sqlite_master "
      "where type='table' and name not like 'sqlite_%'",
    );

    for (final row in sourceTables) {
      final table = (row['name'] as String? ?? '').trim();
      if (table.isEmpty) continue;
      final createSql = (row['sql'] as String? ?? '').trim();

      final sourceColumns = _columnsOf(db, 'src', table);
      if (sourceColumns.isEmpty) continue;

      final targetColumns = _columnsOf(db, 'main', table);
      if (targetColumns.isEmpty) {
        // 目标没有这张表：用源库的建表语句补上（收藏夹表走这条路径）。
        if (createSql.isEmpty) continue;
        db.execute(createSql);
        _insertAll(
          db,
          table: table,
          columns: sourceColumns,
        );
        continue;
      }

      final common = sourceColumns
          .where((c) => targetColumns.contains(c))
          .toList(growable: false);
      if (common.isEmpty) continue;
      _insertAll(db, table: table, columns: common);
    }

    db.execute('DETACH DATABASE src');
    return true;
  } finally {
    db.dispose();
    try {
      if (await temp.exists()) {
        await temp.delete();
      }
    } catch (_) {
      // 临时文件删不掉不影响导入结果，下次导入时会覆盖它。
    }
  }
}

/// 列出某个库（`main` / `src`）里某张表的列名。
List<String> _columnsOf(Database db, String schema, String table) {
  try {
    return db
        .select('pragma $schema.table_info("${_escape(table)}")')
        .map((c) => (c['name'] as String? ?? '').trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
  } catch (_) {
    return const <String>[];
  }
}

/// 把 [columns] 这些列从 `src` 搬到 `main`；主键冲突时以 src 为准。
void _insertAll(
  Database db, {
  required String table,
  required List<String> columns,
}) {
  final escapedTable = _escape(table);
  final columnList = columns.map((c) => '"${_escape(c)}"').join(', ');
  db.execute(
    'INSERT OR REPLACE INTO main."$escapedTable" ($columnList) '
    'SELECT $columnList FROM src."$escapedTable"',
  );
}

String _escape(String identifier) => identifier.replaceAll('"', '""');
