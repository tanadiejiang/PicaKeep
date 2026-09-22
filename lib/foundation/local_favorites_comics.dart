part of 'local_favorites.dart';

extension LocalFavoritesManagerComics on LocalFavoritesManager {
  void _insertComic(Database db, String folder, FavoriteItem comic, int order) {
    _favoritedTargetsDirty = true;
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
    _favoritedTargetsDirty = true;
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

  /// 按 `(target, type)` 把网络详情回写进本地收藏记录。
  ///
  /// 与 [editTags] 的关键区别：**`where` 必须同时匹配 target 与 type**。
  /// `editTags` 只按 target 过滤，同一 id 存在于多个源（例如 picacg 与 jm 都有
  /// 该 id）时会串改另一条记录；本方法用于"按来源更新"，必须带上 type。
  ///
  /// 只更新来源元数据（name / author / tags / cover_path）：
  /// - **不碰 `time`**（收藏时间语义，不能被在线的上传时间覆盖）；
  /// - **不碰 `display_order`**（用户手动排序）；
  /// - 找不到记录时返回 false，**不静默新建**（新建会让"更新"变成"加条目"）。
  ///
  /// [tags] 为 null 表示本次没拿到该源的列表口径标签 → **保留原值**
  /// （详情接口的全量标签口径不同，写进去会把卡片填满并稀释搜索命中）。
  bool updateComicInfo(
    String folder,
    String target,
    int type, {
    String? name,
    String? author,
    List<String>? tags,
    String? coverPath,
  }) {
    if (target.isEmpty) return false;
    final db = _dbForFolderWrite(folder);
    final tableName = _folderTableNameInDb(folder, db);
    if (tableName == null) return false;
    final typeKeys = _equivalentTypeList(type);
    if (typeKeys.isEmpty) return false;
    final placeholders = List.filled(typeKeys.length, '?').join(', ');

    final sets = <String>[];
    final args = <Object?>[];
    if (name != null && name.trim().isNotEmpty) {
      sets.add('name = ?');
      args.add(name.trim());
    }
    if (author != null && author.trim().isNotEmpty) {
      sets.add('author = ?');
      args.add(author.trim());
    }
    if (tags != null && tags.isNotEmpty) {
      sets.add('tags = ?');
      args.add(tags.join(','));
    }
    if (coverPath != null && coverPath.trim().isNotEmpty) {
      sets.add('cover_path = ?');
      args.add(coverPath.trim());
    }
    if (sets.isEmpty) return false;

    // 先确认记录存在（同时拿到"到底改的是哪一条"的证据），再执行更新。
    // `Database` 上没有 updatedRows，用存在性判定等价表达"没找到就不算更新"。
    final existing = db.select(
      'select 1 from "$tableName" '
      'where target == ? and type in ($placeholders) limit 1;',
      [target, ...typeKeys],
    );
    if (existing.isEmpty) return false;

    db.execute(
      'update "$tableName" set ${sets.join(', ')} '
      'where target == ? and type in ($placeholders);',
      [...args, target, ...typeKeys],
    );
    return true;
  }

  Future<void> clearAll() async {
    _favoritedTargetsDirty = true;
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
