part of 'local_favorites.dart';

extension LocalFavoritesManagerComics on LocalFavoritesManager {
  void _insertComic(Database db, String folder, FavoriteItem comic, int order) {
    final tableName = _folderTableNameInDb(folder, db);
    if (tableName == null) {
      throw Exception('Folder does not exist');
    }
    final storageTypeKey = _preferredStorageTypeKey(comic.type.key);
    db.execute("""
        insert into "$tableName" (target, name, author, type, tags, cover_path, time, display_order)
        values (?, ?, ?, ?, ?, ?, ?, ?);
      """, [
      comic.target,
      comic.name,
      comic.author,
      storageTypeKey,
      comic.tags.join(','),
      comic.coverPath,
      comic.time,
      order,
    ]);
  }

  bool _hasComicInDb(
    Database db,
    String folder,
    String target,
    Iterable<int> typeKeys,
  ) {
    final keys = typeKeys.toList(growable: false);
    final tableName = _folderTableNameInDb(folder, db);
    if (target.isEmpty || keys.isEmpty || tableName == null) {
      return false;
    }
    final placeholders = List.filled(keys.length, '?').join(', ');
    final res = db.select("""
        select 1 from "$tableName"
        where target == ? and type in ($placeholders)
        limit 1;
      """, [target, ...keys]);
    return res.isNotEmpty;
  }

  void _deleteComicInDb(
    Database db,
    String folder,
    String target,
    Iterable<int> typeKeys,
  ) {
    final keys = typeKeys.toList(growable: false);
    final tableName = _folderTableNameInDb(folder, db);
    if (target.isEmpty || keys.isEmpty || tableName == null) {
      return;
    }
    final placeholders = List.filled(keys.length, '?').join(', ');
    db.execute("""
        delete from "$tableName"
        where target == ? and type in ($placeholders);
      """, [target, ...keys]);
  }

  bool comicExists(String folder, String target, int type) {
    final typeKeys = _equivalentTypeList(type);
    for (final db in _dbsForFolder(folder)) {
      if (_hasComicInDb(db, folder, target, typeKeys)) {
        return true;
      }
    }
    return false;
  }

  void addComic(String folder, FavoriteItem comic, [int? order]) {
    addComicWithResult(folder, comic, order);
  }

  LocalFavoriteAddStatus addComicWithResult(String folder, FavoriteItem comic,
      [int? order]) {
    final result = _addComicWithoutNotification(folder, comic, order);
    if (result == LocalFavoriteAddStatus.added) _emitFolders();
    return result;
  }

  LocalFavoriteAddStatus _addComicWithoutNotification(
      String folder, FavoriteItem comic,
      [int? order]) {
    if (!_getFolderNameStrings().contains(folder)) {
      throw Exception("Folder does not exists");
    }
    final db = _dbForFolderWrite(folder);
    final typeKeys = _equivalentTypeList(comic.type.key);
    if (_hasComicInDb(db, folder, comic.target, typeKeys)) {
      return LocalFavoriteAddStatus.alreadyPresent;
    }
    _insertComic(db, folder, comic, order ?? (_maxValueInDb(db, folder) + 1));
    return LocalFavoriteAddStatus.added;
  }

  /// Each relation commits independently. Yielding never changes its target store.
  Future<LocalFavoriteBatchResult> addComicsToFolders(
    Iterable<String> folders,
    Iterable<FavoriteItem> comics, {
    Iterable<String> createdFolders = const [],
    Map<String, String> folderCreationFailures = const {},
    void Function(int completed, int total)? onProgress,
  }) async {
    final targets = folders.toSet();
    final unique = <(String, String), FavoriteItem>{};
    for (final item in comics) {
      unique.putIfAbsent(
          (item.target, _canonicalFavoriteTypeIdentity(item.type.key)),
          () => item);
    }
    final generation = _storageGeneration;
    final mode = managedDataSourceMode;
    final results = <LocalFavoriteRelationResult>[];
    final total = targets.length * unique.length;
    var storageChanged = !_storageReady;
    for (final folder in targets) {
      for (final item in unique.values) {
        storageChanged |= generation != _storageGeneration ||
            mode != managedDataSourceMode ||
            !_storageReady;
        var status = LocalFavoriteAddStatus.failed;
        String? error =
            storageChanged ? '收藏数据源已变化，请重试' : folderCreationFailures[folder];
        if (error == null) {
          try {
            status = _addComicWithoutNotification(folder, item);
          } catch (e) {
            error = e.toString();
          }
        }
        results.add(LocalFavoriteRelationResult(
            folder, item.target, item.type, status,
            error: error));
        if (results.length % 32 == 0 && results.length < total) {
          onProgress?.call(results.length, total);
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }
    }
    final result = LocalFavoriteBatchResult(results,
        createdFolders: createdFolders,
        folderCreationFailures: folderCreationFailures);
    if (result.addedRelations > 0 && _storageReady) _emitFolders();
    onProgress?.call(total, total);
    return result;
  }

  void deleteComic(String folder, FavoriteItem comic) {
    final typeKeys = _equivalentTypeList(comic.type.key);
    for (final db in _dbsForFolder(folder)) {
      _deleteComicInDb(db, folder, comic.target, typeKeys);
    }
    _emitFolders();
  }

  void deleteComicWithTarget(String folder, String target, FavoriteType type) {
    final typeKeys = _equivalentTypeList(type.key);
    try {
      for (final db in _dbsForFolder(folder)) {
        _deleteComicInDb(db, folder, target, typeKeys);
      }
    } finally {
      // A later store may fail after an earlier deletion already committed.
      _emitFolders();
    }
  }

  void editTags(String target, String folder, List<String> tags) {
    for (final db in _dbsForFolder(folder)) {
      final tableName = _folderTableNameInDb(folder, db);
      if (tableName == null) {
        continue;
      }
      db.execute("""
          update "$tableName"
          set tags = ?
          where target == ?;
        """, [tags.join(','), target]);
    }
  }

  Future<void> clearAll() async {
    for (final folder in _getUserTables(_db)) {
      _db.execute('drop table "$folder";');
    }
    _db.execute('drop table if exists folder_order;');
    _db.dispose();
    File(_dbPath).deleteSync();
    await init();
    _emitFolders();
  }

  void reorder(List<FavoriteItem> newFolder, String folder) {
    if (!_getFolderNameStrings().contains(folder)) {
      throw Exception("Failed to reorder: folder not found");
    }
    final targetDb = _dbForFolderWrite(folder);
    final tableName = _folderTableNameInDb(folder, targetDb);
    if (tableName == null) {
      throw Exception("Failed to reorder: folder storage not found");
    }
    for (final db in _dbsForFolder(folder)) {
      _dropFolder(db, folder);
    }
    _createFolderTable(targetDb, tableName);
    for (int i = 0; i < newFolder.length; i++) {
      _insertComic(targetDb, folder, newFolder[i], i);
    }
    _emitFolders();
  }

  void updateOrder(Map<String, int> order) {
    for (final folder in order.keys) {
      final targetDbs = _dbsForFolder(folder);
      if (targetDbs.isEmpty) {
        _db.execute("""
            insert or replace into folder_order (folder_name, order_value)
            values (?, ?);
          """, [folder, order[folder]]);
        continue;
      }
      for (final db in targetDbs) {
        db.execute("""
            insert or replace into folder_order (folder_name, order_value)
            values (?, ?);
          """, [folder, order[folder]]);
      }
    }
    _emitFolders();
  }

  void onReadEnd(String favoriteId, FavoriteType favoriteType) {}
}
