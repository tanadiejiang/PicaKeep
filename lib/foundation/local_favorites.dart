// ignore_for_file: no_leading_underscores_for_local_identifiers

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:sqlite3/sqlite3.dart';

String getCurTime() {
  return DateTime.now()
      .toIso8601String()
      .replaceFirst("T", " ")
      .substring(0, 19);
}

const _legacyCustomFavoriteSourceKeys = <String>[
  'copy_manga',
  'Komiic',
  'ikmmh',
  'baozi',
];

String? _extractEhGalleryId(String target) {
  final index = target.indexOf('/g/');
  if (index == -1) return null;
  final start = index + 3;
  final end = target.indexOf('/', start);
  if (end == -1) return null;
  final id = target.substring(start, end).trim();
  return id.isEmpty ? null : id;
}

String? _extractHitomiId(String target) {
  final htmlMatch = RegExp(r'(\d+)(?=\.html(?:$|\?))').firstMatch(target);
  if (htmlMatch != null) {
    return htmlMatch.group(1);
  }
  final digitsOnly = RegExp(r'^\d+$').firstMatch(target.trim());
  return digitsOnly?.group(0);
}

String? _preferredCustomFavoriteSourceKey(int type) {
  final mapping = <int, String>{
    7: 'copy_manga',
    8: 'Komiic',
    'copy_manga'.hashCode: 'copy_manga',
    'Komiic'.hashCode: 'Komiic',
    'ikmmh'.hashCode: 'ikmmh',
    'baozi'.hashCode: 'baozi',
  };
  return mapping[type];
}

String? _favoriteSourceDisplayName(int type) {
  const builtInNames = <int, String>{
    7: '拷贝漫画',
    8: 'Komiic',
  };
  if (builtInNames.containsKey(type)) {
    return builtInNames[type];
  }
  final sourceKey = _preferredCustomFavoriteSourceKey(type);
  return switch (sourceKey) {
    'copy_manga' => '拷贝漫画',
    'Komiic' => 'Komiic',
    'ikmmh' => '爱看漫',
    'baozi' => '包子漫画',
    _ => null,
  };
}

void _addCandidate(Set<String> candidates, String value) {
  final v = value.trim();
  if (v.isNotEmpty) {
    candidates.add(v);
  }
}

void _addCustomFavoriteCandidates(Set<String> candidates, String target,
    [String? preferredSourceKey]) {
  if (preferredSourceKey != null && preferredSourceKey.isNotEmpty) {
    _addCandidate(candidates, '$preferredSourceKey-$target');
  }
  for (final key in _legacyCustomFavoriteSourceKeys) {
    _addCandidate(candidates, '$key-$target');
  }
}

List<String> _buildFavoriteDownloadIdCandidates(String target, int type) {
  final candidates = <String>{};
  _addCandidate(candidates, target);

  switch (type) {
    case 1:
      final ehId = _extractEhGalleryId(target);
      if (ehId != null) {
        _addCandidate(candidates, ehId);
      }
      break;
    case 2:
      _addCandidate(
          candidates, target.startsWith('jm') ? target : 'jm$target');
      break;
    case 3:
      final hitomiId = _extractHitomiId(target);
      if (target.startsWith('hitomi')) {
        _addCandidate(candidates, target);
      } else if (hitomiId != null) {
        _addCandidate(candidates, 'hitomi$hitomiId');
      }
      break;
    case 4:
      if (target.startsWith('Ht') || target.startsWith('ht')) {
        final suffix = target.substring(2);
        _addCandidate(candidates, 'Ht$suffix');
        _addCandidate(candidates, 'ht$suffix');
      } else {
        _addCandidate(candidates, 'Ht$target');
        _addCandidate(candidates, 'ht$target');
      }
      break;
    case 6:
      _addCandidate(candidates,
          target.startsWith('nhentai') ? target : 'nhentai$target');
      break;
    default:
      _addCustomFavoriteCandidates(
          candidates, target, _preferredCustomFavoriteSourceKey(type));
      break;
  }

  return candidates.toList();
}

final class FavoriteType {
  final int key;

  const FavoriteType(this.key);

  static FavoriteType get picacg => const FavoriteType(0);
  static FavoriteType get ehentai => const FavoriteType(1);
  static FavoriteType get jm => const FavoriteType(2);
  static FavoriteType get hitomi => const FavoriteType(3);
  static FavoriteType get htManga => const FavoriteType(4);
  static FavoriteType get nhentai => const FavoriteType(6);
  static FavoriteType get copyManga => const FavoriteType(7);
  static FavoriteType get komiic => const FavoriteType(8);

  String get name {
    const nameMap = {
      0: "Picacg",
      1: "E-Hentai",
      2: "禁漫",
      3: "Hitomi",
      4: "绅士漫画",
      6: "NHentai",
      7: "拷贝漫画",
      8: "Komiic",
    };
    return nameMap[key] ?? _favoriteSourceDisplayName(key) ?? "Other";
  }

  @override
  bool operator ==(Object other) =>
      other is FavoriteType && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

class FavoriteItem {
  String name;
  String author;
  FavoriteType type;
  List<String> tags;
  String target;
  String coverPath;
  String time = getCurTime();

  FavoriteItem({
    required this.target,
    required this.name,
    required this.coverPath,
    required this.author,
    required this.type,
    required this.tags,
  });

  /// Convert favorite target to download DB ID.
  /// The first candidate is the preferred local download ID; callers that need
  /// robust compatibility should use [candidateDownloadIds].
  String toDownloadId() {
    return candidateDownloadIds().first;
  }

  List<String> candidateDownloadIds() =>
      _buildFavoriteDownloadIdCandidates(target, type.key);

  Map<String, dynamic> toJson() => {
        "name": name,
        "author": author,
        "type": type.key,
        "tags": tags,
        "target": target,
        "coverPath": coverPath,
        "time": time
      };

  FavoriteItem.fromJson(Map<String, dynamic> json)
      : name = json["name"],
        author = json["author"],
        type = FavoriteType(json["type"]),
        tags = List<String>.from(json["tags"]),
        target = json["target"],
        coverPath = json["coverPath"],
        time = json["time"];

  FavoriteItem.fromRow(Row row)
      : name = row["name"],
        author = row["author"],
        type = FavoriteType(row["type"]),
        tags = (row["tags"] as String).split(","),
        target = row["target"],
        coverPath = row["cover_path"],
        time = row["time"] {
    tags.remove("");
  }

  @override
  bool operator ==(Object other) {
    return other is FavoriteItem &&
        other.target == target &&
        other.type == type;
  }

  @override
  int get hashCode => target.hashCode ^ type.hashCode;
}

class FavGroup {
  final String name;
  int order;

  FavGroup(this.name, {this.order = 0});

  @override
  bool operator ==(Object other) =>
      other is FavGroup && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

class FavoriteItemWithFolderInfo {
  FavoriteItem comic;
  String folder;

  FavoriteItemWithFolderInfo(this.comic, this.folder);

  @override
  bool operator ==(Object other) {
    return other is FavoriteItemWithFolderInfo &&
        other.comic == comic &&
        other.folder == folder;
  }

  @override
  int get hashCode => comic.hashCode ^ folder.hashCode;
}

class LocalFavoritesManager {
  factory LocalFavoritesManager() =>
      cache ?? (cache = LocalFavoritesManager._create());

  LocalFavoritesManager._create();

  static LocalFavoritesManager? cache;

  late Database _db;
  Database? _secondaryDb;
  late String _dbPath;

  final _foldersController = StreamController<List<FavGroup>>.broadcast();

  Stream<List<FavGroup>> get allFoldersStream => _foldersController.stream;

  List<Database> get _dbs => [
        _db,
        if (_secondaryDb != null) _secondaryDb!,
      ];

  Future<void> init() async {
    final roots = await getManagedDataRoots();
    final primaryPath = managedDataFilePath(roots.first, 'local_favorite.db');
    File(primaryPath).parent.createSync(recursive: true);

    dispose();

    _dbPath = primaryPath;
    _db = sqlite3.open(_dbPath);
    _checkAndCreate(_db);
    await readData();

    _secondaryDb = null;
    if (roots.length > 1) {
      final secondaryPath = managedDataFilePath(roots[1], 'local_favorite.db');
      final secondaryFile = File(secondaryPath);
      if (secondaryFile.existsSync()) {
        _secondaryDb = sqlite3.open(secondaryPath);
        _checkAndCreate(_secondaryDb!);
      }
    }
    _emitFolders();
  }

  void dispose() {
    try {
      _db.dispose();
    } catch (_) {}
    try {
      _secondaryDb?.dispose();
    } catch (_) {}
    _secondaryDb = null;
  }

  void _checkAndCreate(Database db) {
    final tables = _getTablesWithDB(db);
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
    tables.remove('folder_sync');
    tables.remove('folder_order');
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
    final requiredColumns = <String>{'target', 'name', 'author', 'type', 'tags', 'cover_path', 'time'};
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
    final needsMigration =
        !hasDisplayOrder || targetPk != 1 || typePk != 2 || requiredColumns.difference(columns).isNotEmpty;
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

  void _emitFolders() {
    final names = _getFolderNameStrings();
    _foldersController.add(names.map((e) => FavGroup(e, order: 0)).toList());
  }

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
    return tables;
  }

  bool _folderExistsInDb(String folder, Database db) {
    return _getUserTables(db).contains(folder);
  }

  List<Database> _dbsForFolder(String folder) {
    return _dbs.where((db) => _folderExistsInDb(folder, db)).toList();
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

  int _maxValueInDb(Database db, String folder) {
    return db.select("""
      SELECT MAX(display_order) AS max_value
      FROM "$folder";
    """).firstOrNull?["max_value"] ?? 0;
  }

  int _minValueInDb(Database db, String folder) {
    return db.select("""
      SELECT MIN(display_order) AS min_value
      FROM "$folder";
    """).firstOrNull?["min_value"] ?? 0;
  }

  void _createFolderTable(Database db, String name) {
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

  void _dropFolder(Database db, String name) {
    db.execute('drop table if exists "$name";');
    db.execute("""
      delete from folder_order
      where folder_name == ?;
    """, [name]);
  }

  void _insertComic(Database db, String folder, FavoriteItem comic, int order) {
    db.execute("""
      insert into "$folder" (target, name, author, type, tags, cover_path, time, display_order)
      values (?, ?, ?, ?, ?, ?, ?, ?);
    """, [
      comic.target,
      comic.name,
      comic.author,
      comic.type.key,
      comic.tags.join(','),
      comic.coverPath,
      comic.time,
      order,
    ]);
  }

  bool _matchesFavoriteKeyword(FavoriteItem comic, String keyword) {
    if (comic.name.contains(keyword)) return true;
    if (comic.author.contains(keyword)) return true;
    if (comic.tags.any((element) => element.contains(keyword))) return true;
    return false;
  }

  List<String> _getFolderNameStrings() {
    final folders = <String>{};
    final folderToOrder = <String, int>{};
    for (final db in _dbs) {
      for (final folder in _getUserTables(db)) {
        folders.add(folder);
        final res = db.select("""
          select * from folder_order
          where folder_name == ?;
        """, [folder]);
        final order = res.isNotEmpty ? (res.first["order_value"] as int? ?? 0) : 0;
        folderToOrder.putIfAbsent(folder, () => order);
        if (db == _db) {
          folderToOrder[folder] = order;
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

  void updateUI() {
    _emitFolders();
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
    return getAllComics(folderName).length;
  }

  String createFolder(String name) {
    if (name.isEmpty) {
      throw "name is empty!";
    }
    if (_getFolderNameStrings().contains(name)) {
      throw Exception("Folder is existing");
    }
    _createFolderTable(_db, name);
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
      db.execute("""
        ALTER TABLE "$oldName"
        RENAME TO "$newName";
      """);
      final res = db.select("""
        select * from folder_order
        where folder_name == ?;
      """, [oldName]);
      if (res.isNotEmpty) {
        final order = res.first["order_value"];
        db.execute("delete from folder_order where folder_name == ?;", [oldName]);
        db.execute("""
          insert or replace into folder_order (folder_name, order_value)
          values (?, ?);
        """, [newName, order]);
      }
    }
    _emitFolders();
  }

  bool comicExists(String folder, String target, int type) {
    for (final db in _dbsForFolder(folder)) {
      final res = db.select("""
        select * from "$folder"
        where target == ? and type == ?;
      """, [target, type]);
      if (res.isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  void addComic(String folder, FavoriteItem comic, [int? order]) {
    if (!_getFolderNameStrings().contains(folder)) {
      throw Exception("Folder does not exists");
    }
    final db = _dbForFolderWrite(folder);
    final res = db.select("""
      select * from "$folder"
      where target == ? and type == ?;
    """, [comic.target, comic.type.key]);
    if (res.isNotEmpty) {
      return;
    }
    _insertComic(db, folder, comic, order ?? (_maxValueInDb(db, folder) + 1));
    _emitFolders();
  }

  void deleteComic(String folder, FavoriteItem comic) {
    for (final db in _dbsForFolder(folder)) {
      db.execute("""
        delete from "$folder"
        where target == ? and type == ?;
      """, [comic.target, comic.type.key]);
    }
    _emitFolders();
  }

  void deleteComicWithTarget(String folder, String target, FavoriteType type) {
    for (final db in _dbsForFolder(folder)) {
      db.execute("""
        delete from "$folder"
        where target == ? and type == ?;
      """, [target, type.key]);
    }
    _emitFolders();
  }

  void editTags(String target, String folder, List<String> tags) {
    for (final db in _dbsForFolder(folder)) {
      db.execute("""
        update "$folder"
        set tags = ?
        where target == ?;
      """, [tags.join(','), target]);
    }
  }

  List<FavoriteItem> getAllComics(String folder) {
    final merged = <String, FavoriteItem>{};
    final orders = <String, int>{};
    for (final db in _dbsForFolder(folder)) {
      final rows = db.select("""
        select * from "$folder"
        ORDER BY display_order;
      """);
      for (final element in rows) {
        final item = FavoriteItem.fromRow(element);
        final key = '${item.target}|${item.type.key}';
        merged.putIfAbsent(key, () => item);
        orders.putIfAbsent(key, () => element["display_order"] as int? ?? 0);
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

  List<FavoriteItemWithFolderInfo> search(String keyword) {
    final keywordList = keyword.split(" ").where((e) => e.isNotEmpty).toList();
    if (keywordList.isEmpty) {
      return allComics();
    }
    final comics = <FavoriteItemWithFolderInfo>[];
    for (final table in _getFolderNameStrings()) {
      for (final comic in getAllComics(table)) {
        if (_matchesFavoriteKeyword(comic, keywordList.first)) {
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

    bool test(FavoriteItemWithFolderInfo comic, String kw) {
      return _matchesFavoriteKeyword(comic.comic, kw);
    }

    for (var i = 1; i < keywordList.length; i++) {
      comics.removeWhere((element) => !test(element, keywordList[i]));
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
    for (final db in _dbsForFolder(folder)) {
      _dropFolder(db, folder);
    }
    _createFolderTable(targetDb, folder);
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
