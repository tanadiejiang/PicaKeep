part of 'local_favorites.dart';

extension LocalFavoritesManagerQuery on LocalFavoritesManager {
  Stream<List<FavGroup>> get allFoldersStream => _foldersController.stream;

  List<Database> get _dbs => [
        _db,
        if (_secondaryDb != null) _secondaryDb!,
      ];

  void _emitFolders() {
    _favoritedTargetsDirty = true;
    final names = _getFolderNameStrings();
    _foldersController.add(names.map((e) => FavGroup(e, order: 0)).toList());
  }

  /// 让收藏页重新读取列表。
  ///
  /// [_emitFolders] 是本 part 的私有实现；批量更新（`local_favorites_update.dart`
  /// 是独立库）改完库后需要通知界面，这里给一个公开入口，避免把它改成公共 API。
  void notifyFoldersChanged() => _emitFolders();

  Future<void> readData() async {
    final file = File("$_dbPath.localFavorite");
    if (file.existsSync()) {
      final allComics = <String, List<FavoriteItem>>{};
      try {
        final data = (const JsonDecoder().convert(file.readAsStringSync()))
            as Map<String, dynamic>;
        for (final key in data.keys.toList()) {
          final comics = <FavoriteItem>{};
          for (final comic in data[key]!) {
            comics.add(FavoriteItem.fromJson(comic));
          }
          if (allComics.containsKey(key)) {
            comics.addAll(allComics[key]!);
          }
          allComics[key] = comics.toList();
        }
        await clearAll();
        for (final folder in allComics.keys) {
          createFolder(folder);
          final comics = allComics[folder]!;
          for (int i = 0; i < comics.length; i++) {
            addComic(folder, comics[i], i);
          }
        }
      } catch (_) {
        // ignore migration errors
      } finally {
        file.deleteSync();
      }
    }
  }

  bool _matchesFavoriteKeyword(FavoriteItem comic, String keyword) {
    final normalized = keyword.trim().toLowerCase();
    if (normalized.isEmpty) {
      return true;
    }
    final fields = <String>[
      comic.name,
      comic.author,
      comic.target,
      ...comic.tags,
      ...comic.candidateDownloadIds(),
    ];
    return fields.any((field) => field.toLowerCase().contains(normalized));
  }

  void updateUI() {
    _emitFolders();
  }

  bool isExist(String target) {
    final normalized = target.trim();
    if (normalized.isEmpty) {
      return false;
    }
    if (_favoritedTargetsDirty) {
      _cacheFavoritedTargets();
    }
    return _cachedFavoritedTargets.containsKey(normalized);
  }

  Map<String, bool> existsMany(Iterable<String> targets) {
    if (_favoritedTargetsDirty) {
      _cacheFavoritedTargets();
    }
    final result = <String, bool>{};
    for (final target in targets) {
      final normalized = target.trim();
      if (normalized.isEmpty) {
        continue;
      }
      result[normalized] = _cachedFavoritedTargets.containsKey(normalized);
    }
    return result;
  }

  void _cacheFavoritedTargets() {
    _favoritedTargetsDirty = false;
    _cachedFavoritedTargets.clear();
    for (final db in _dbs) {
      for (final folder in _getFolderRecords(db)) {
        final rows = db.select("""
            select * from "${folder.tableName}";
          """);
        for (final row in rows) {
          final item = FavoriteItem.fromRow(row);
          final candidates = <String>{
            item.target,
            ...item.candidateDownloadIds(),
          };
          for (final candidate in candidates) {
            final normalized = candidate.trim();
            if (normalized.isEmpty) {
              continue;
            }
            _cachedFavoritedTargets[normalized] = true;
            _cachedFavoritedTargets[
                'local_download::current_download::$normalized'] = true;
            _cachedFavoritedTargets[
                'local_download::original_download::$normalized'] = true;
          }
        }
      }
    }
  }

  List<int> _equivalentTypeList(int type) =>
      _equivalentFavoriteTypeKeys(type).toList(growable: false);

  int _maxValueInDb(Database db, String folder) {
    final tableName = _folderTableNameInDb(folder, db);
    if (tableName == null) {
      return 0;
    }
    return db.select("""
        SELECT MAX(display_order) AS max_value
        FROM "$tableName";
      """).firstOrNull?["max_value"] ?? 0;
  }

  int _minValueInDb(Database db, String folder) {
    final tableName = _folderTableNameInDb(folder, db);
    if (tableName == null) {
      return 0;
    }
    return db.select("""
        SELECT MIN(display_order) AS min_value
        FROM "$tableName";
      """).firstOrNull?["min_value"] ?? 0;
  }

  int maxValue(String folder) {
    final db = _dbForFolderWrite(folder);
    return _maxValueInDb(db, folder);
  }

  int minValue(String folder) {
    final dbs = _dbsForFolder(folder);
    if (dbs.isEmpty) {
      return 0;
    }
    var result = 0;
    var initialized = false;
    for (final db in dbs) {
      final value = _minValueInDb(db, folder);
      if (!initialized || value < result) {
        result = value;
        initialized = true;
      }
    }
    return result;
  }

  int count(String folderName) {
    final keys = <String>{};
    for (final db in _dbsForFolder(folderName)) {
      final tableName = _folderTableNameInDb(folderName, db);
      if (tableName == null) {
        continue;
      }
      final rows = db.select("""
          select target, type from "$tableName";
        """);
      for (final row in rows) {
        final type = row["type"] as int? ?? 0;
        keys.add('${row["target"]}|${_canonicalFavoriteTypeIdentity(type)}');
      }
    }
    return keys.length;
  }

  List<FavoriteItem> getAllComics(String folder) {
    final merged = <String, FavoriteItem>{};
    final orders = <String, int>{};
    for (final db in _dbsForFolder(folder)) {
      final tableName = _folderTableNameInDb(folder, db);
      if (tableName == null) {
        continue;
      }
      final rows = db.select("""
          select * from "$tableName"
          ORDER BY display_order;
        """);
      for (final element in rows) {
        final item = FavoriteItem.fromRow(element);
        final key =
            '${item.target}|${_canonicalFavoriteTypeIdentity(item.type.key)}';
        final order = element["display_order"] as int? ?? 0;
        if (!merged.containsKey(key) || db == _db) {
          merged[key] = item;
          orders[key] = order;
        }
      }
    }
    final keys = merged.keys.toList()
      ..sort((a, b) {
        final diff = (orders[a] ?? 0).compareTo(orders[b] ?? 0);
        if (diff != 0) {
          return diff;
        }
        return merged[a]!.time.compareTo(merged[b]!.time);
      });
    return [for (final key in keys) merged[key]!];
  }

  List<FavoriteItemWithFolderInfo> search(String keyword,
      {List<String> aliases = const []}) {
    final keywordList = keyword.split(" ").where((e) => e.isNotEmpty).toList();
    if (keywordList.isEmpty) {
      return allComics();
    }
    bool matchAny(FavoriteItem comic, String kw) =>
        _matchesFavoriteKeyword(comic, kw) ||
        aliases.any((a) => _matchesFavoriteKeyword(comic, a));
    final comics = <FavoriteItemWithFolderInfo>[];
    for (final table in _getFolderNameStrings()) {
      for (final comic in getAllComics(table)) {
        if (matchAny(comic, keywordList.first)) {
          comics.add(FavoriteItemWithFolderInfo(comic, table));
          if (comics.length > 200) {
            break;
          }
        }
      }
      if (comics.length > 200) {
        break;
      }
    }

    for (var i = 1; i < keywordList.length; i++) {
      comics.removeWhere((element) => !matchAny(element.comic, keywordList[i]));
    }

    return comics;
  }

  List<FavoriteItemWithFolderInfo> allComics() {
    final res = <FavoriteItemWithFolderInfo>[];
    for (final folder in _getFolderNameStrings()) {
      for (final comic in getAllComics(folder)) {
        res.add(FavoriteItemWithFolderInfo(comic, folder));
      }
    }
    return res;
  }
}
