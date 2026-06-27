part of 'local_favorites.dart';

extension LocalFavoritesManagerDb on LocalFavoritesManager {
  void _checkAndCreate(Database db) {
    var tables = _getTablesWithDB(db);
    if (!tables.contains('folder_sync')) {
      db.execute("""
          create table folder_sync (
            folder_name text primary key,
            time TEXT,
            key TEXT,
            sync_data TEXT
          );
        """);
    }
    if (!tables.contains('folder_order')) {
      db.execute("""
          create table folder_order (
            folder_name text primary key,
            order_value int
          );
        """);
    }
    _migrateFolderMetaToLegacy(db);
    tables = _getTablesWithDB(db);
    tables.remove('folder_sync');
    tables.remove('folder_order');
    tables.remove('folder_meta');
    for (final table in tables) {
      _ensureFolderTableSchema(db, table);
    }
  }

  int _asInt(Object? value, [int fallback = 0]) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  String _asText(Object? value, [String fallback = '']) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  void _ensureFolderTableSchema(Database db, String table) {
    final info = db.select("""
        PRAGMA table_info("$table");
      """);
    if (info.isEmpty) {
      return;
    }
    var hasDisplayOrder = false;
    var targetPk = 0;
    var typePk = 0;
    final requiredColumns = <String>{
      'target',
      'name',
      'author',
      'type',
      'tags',
      'cover_path',
      'time'
    };
    final columns = <String>{};
    for (final row in info) {
      final name = row["name"] as String? ?? '';
      final pk = row["pk"] as int? ?? 0;
      columns.add(name);
      if (name == 'display_order') {
        hasDisplayOrder = true;
      }
      if (name == 'target') {
        targetPk = pk;
      }
      if (name == 'type') {
        typePk = pk;
      }
    }
    final needsMigration = !hasDisplayOrder ||
        targetPk != 1 ||
        typePk != 2 ||
        requiredColumns.difference(columns).isNotEmpty;
    if (!needsMigration) {
      return;
    }

    final rows = db.select("""
        select rowid as __rowid__, *
        from "$table"
        order by rowid;
      """);
    final tempName = "${table}_dw5d8g2_temp";
    db.execute('drop table if exists "$tempName";');
    _createFolderTable(db, tempName);

    var fallbackOrder = 0;
    for (final row in rows) {
      final order = hasDisplayOrder
          ? _asInt(row["display_order"], fallbackOrder)
          : fallbackOrder;
      db.execute("""
          insert or replace into "$tempName"
            (target, name, author, type, tags, cover_path, time, display_order)
          values (?, ?, ?, ?, ?, ?, ?, ?);
        """, [
        _asText(columns.contains('target') ? row["target"] : null),
        _asText(columns.contains('name') ? row["name"] : null),
        _asText(columns.contains('author') ? row["author"] : null),
        _asInt(columns.contains('type') ? row["type"] : null),
        _asText(columns.contains('tags') ? row["tags"] : null),
        _asText(columns.contains('cover_path') ? row["cover_path"] : null),
        _asText(columns.contains('time') ? row["time"] : null, getCurTime()),
        order,
      ]);
      fallbackOrder++;
    }

    db.execute('drop table "$table";');
    db.execute('alter table "$tempName" rename to "$table";');
  }
}
