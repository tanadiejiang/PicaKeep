part of 'local_favorites.dart';

extension LocalFavoritesManagerFolders on LocalFavoritesManager {
  List<_FolderRecord> _getFolderRecords(Database db) {
    return [
      for (final table in _getUserTables(db))
        _FolderRecord(folderName: table, tableName: table),
    ];
  }

  String? _folderTableNameInDb(String folder, Database db) {
    for (final table in _getUserTables(db)) {
      if (table == folder) {
        return table;
      }
    }
    return null;
  }

  void _migrateFolderMetaToLegacy(Database db) {
    final tables = _getTablesWithDB(db).toSet();
    if (!tables.contains('folder_meta')) {
      return;
    }

    String? findTableNameIgnoreCase(String name) {
      final normalized = name.trim().toLowerCase();
      for (final table in tables) {
        if (table.trim().toLowerCase() == normalized) {
          return table;
        }
      }
      return null;
    }

    final info = db.select('PRAGMA table_info("folder_meta");');
    final columns = <String>{
      for (final row in info) _asText(row['name']),
    };
    if (!columns.contains('folder_name') || !columns.contains('table_name')) {
      db.execute('drop table if exists folder_meta;');
      return;
    }
    final rows = db.select('select folder_name, table_name from folder_meta;');
    for (final row in rows) {
      final folderName = _asText(row['folder_name']);
      final tableName = _asText(row['table_name']);
      if (folderName.isEmpty ||
          tableName.isEmpty ||
          folderName == tableName ||
          folderName.contains('"')) {
        continue;
      }
      if (!tables.contains(tableName)) {
        continue;
      }
      final existingFolderTableName = findTableNameIgnoreCase(folderName);
      if (existingFolderTableName != null) {
        if (existingFolderTableName.toLowerCase() == tableName.toLowerCase()) {
          continue;
        }
        _ensureFolderTableSchema(db, existingFolderTableName);
        _ensureFolderTableSchema(db, tableName);
        final existingKeys = <String>{};
        final existingRows = db.select("""
            select target, type from "$existingFolderTableName";
          """);
        for (final existingRow in existingRows) {
          final target = _asText(existingRow['target']);
          if (target.isEmpty) {
            continue;
          }
          existingKeys.add('$target|${_asInt(existingRow['type'])}');
        }
        var nextOrder = db.select("""
            SELECT MAX(display_order) AS max_value
            FROM "$existingFolderTableName";
          """).firstOrNull?['max_value'] as int? ?? 0;
        final sourceRows = db.select("""
            select * from "$tableName"
            order by display_order, rowid;
          """);
        for (final sourceRow in sourceRows) {
          final target = _asText(sourceRow['target']);
          final type = _asInt(sourceRow['type']);
          if (target.isEmpty) {
            continue;
          }
          final key = '$target|$type';
          if (existingKeys.contains(key)) {
            continue;
          }
          nextOrder++;
          db.execute("""
              insert into "$existingFolderTableName"
                (target, name, author, type, tags, cover_path, time, display_order)
              values (?, ?, ?, ?, ?, ?, ?, ?);
            """, [
            target,
            _asText(sourceRow['name']),
            _asText(sourceRow['author']),
            type,
            _asText(sourceRow['tags']),
            _asText(sourceRow['cover_path']),
            _asText(sourceRow['time'], getCurTime()),
            nextOrder,
          ]);
          existingKeys.add(key);
        }
        db.execute('drop table if exists "$tableName";');
        tables.remove(tableName);
        continue;
      }
      db.execute('alter table "$tableName" rename to "$folderName";');
      tables.remove(tableName);
      tables.add(folderName);
    }
    db.execute('drop table if exists folder_meta;');
  }

  List<String> _getTablesWithDB([Database? db]) {
    final target = db ?? _db;
    return target
        .select("SELECT name FROM sqlite_master WHERE type='table';")
        .map((element) => element["name"] as String)
        .toList();
  }

  List<String> _getUserTables(Database db) {
    final tables = _getTablesWithDB(db);
    tables.remove('folder_sync');
    tables.remove('folder_order');
    tables.remove('folder_meta');
    return tables;
  }

  bool _folderExistsInDb(String folder, Database db) {
    return _folderTableNameInDb(folder, db) != null;
  }

  List<Database> _dbsForFolder(String folder) {
    return _dbs.where((db) => _folderExistsInDb(folder, db)).toList();
  }

  bool get canCreateInOriginalDatabase => _secondaryDb != null;

  Database _dbForFolderCreation(FavoriteFolderCreateTarget target) {
    if (target == FavoriteFolderCreateTarget.original && _secondaryDb != null) {
      return _secondaryDb!;
    }
    return _db;
  }

  Database _dbForFolderWrite(String folder) {
    if (_folderExistsInDb(folder, _db)) {
      return _db;
    }
    if (_secondaryDb != null && _folderExistsInDb(folder, _secondaryDb!)) {
      return _secondaryDb!;
    }
    return _db;
  }

  void _createFolderTable(Database db, String name) {
    _favoritedTargetsDirty = true;
    db.execute("""
        create table "$name"(
          target text,
          name TEXT,
          author TEXT,
          type int,
          tags TEXT,
          cover_path TEXT,
          time TEXT,
          display_order int,
          primary key (target, type)
        );
      """);
  }

  void _dropFolder(Database db, String folderName) {
    _favoritedTargetsDirty = true;
    final tableName = _folderTableNameInDb(folderName, db) ?? folderName;
    db.execute('drop table if exists "$tableName";');
    db.execute("""
        delete from folder_order
        where folder_name == ?;
      """, [folderName]);
  }

  List<String> _getFolderNameStrings() {
    final folders = <String>{};
    final folderToOrder = <String, int>{};
    for (final db in _dbs) {
      for (final folder in _getFolderRecords(db)) {
        folders.add(folder.folderName);
        final res = db.select("""
            select * from folder_order
            where folder_name == ?;
          """, [folder.folderName]);
        final order =
            res.isNotEmpty ? (res.first["order_value"] as int? ?? 0) : 0;
        folderToOrder.putIfAbsent(folder.folderName, () => order);
        if (db == _db) {
          folderToOrder[folder.folderName] = order;
        }
      }
    }
    final result = folders.toList();
    result.sort((a, b) {
      final diff = (folderToOrder[a] ?? 0).compareTo(folderToOrder[b] ?? 0);
      if (diff != 0) {
        return diff;
      }
      return a.compareTo(b);
    });
    return result;
  }

  List<String> get folderNames => _getFolderNameStrings();

  String createFolder(
    String name, [
    FavoriteFolderCreateTarget target = FavoriteFolderCreateTarget.current,
  ]) {
    if (name.isEmpty) {
      throw "name is empty!";
    }
    if (name.contains('"')) {
      throw "Invalid name";
    }
    if (_getFolderNameStrings().contains(name)) {
      throw Exception("Folder is existing");
    }
    _createFolderTable(_dbForFolderCreation(target), name);
    _emitFolders();
    return name;
  }

  void deleteFolder(String name) {
    for (final db in _dbsForFolder(name)) {
      _dropFolder(db, name);
    }
    _emitFolders();
  }

  void rename(String oldName, String newName) {
    if (_getFolderNameStrings().contains(newName)) {
      throw "Name already exists!";
    }
    if (newName.contains('"')) {
      throw "Invalid name";
    }
    final dbs = _dbsForFolder(oldName);
    if (dbs.isEmpty) {
      throw Exception("Folder does not exist");
    }
    for (final db in dbs) {
      final tableName = _folderTableNameInDb(oldName, db);
      if (tableName == null) {
        continue;
      }
      db.execute("""
          ALTER TABLE "$tableName"
          RENAME TO "$newName";
        """);
      final syncRows = db.select("""
          select 1 from folder_sync
          where folder_name == ?
          limit 1;
        """, [oldName]);
      if (syncRows.isNotEmpty) {
        db.execute("""
            UPDATE folder_sync
            set folder_name = ?
            where folder_name == ?
          """, [newName, oldName]);
      }
      final orderRows = db.select("""
          select * from folder_order
          where folder_name == ?;
        """, [oldName]);
      if (orderRows.isNotEmpty) {
        final order = orderRows.first["order_value"];
        db.execute(
            "delete from folder_order where folder_name == ?;", [oldName]);
        db.execute("""
            insert or replace into folder_order (folder_name, order_value)
            values (?, ?);
          """, [newName, order]);
      }
    }
    _emitFolders();
  }
}
