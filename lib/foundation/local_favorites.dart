// ignore_for_file: no_leading_underscores_for_local_identifiers

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

String getCurTime() {
  return DateTime.now()
      .toIso8601String()
      .replaceFirst("T", " ")
      .substring(0, 19);
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
    return nameMap[key] ?? "Unknown";
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
  /// Since `_addToLocalFavoriteFolder` stores `comic.id` (the full download DB ID)
  /// as `target`, this method must detect whether `target` already contains the
  /// source prefix to avoid double-prefixing (e.g. "copy_manga-copy_manga-xxx").
  String toDownloadId() {
    // For types 0 (picacg) and 1 (ehentai): target IS the download ID.
    if (type.key == 0 || type.key == 1) return target;

    // For types 2–6: simple prefix without separator.
    const simplePrefixes = <int, String>{
      2: 'jm', 3: 'hitomi', 4: 'Ht', 6: 'nhentai',
    };
    final sp = simplePrefixes[type.key];
    if (sp != null) return target.startsWith(sp) ? target : '$sp$target';

    // For type 7 (copyManga): prefix "copy_manga-"
    if (type.key == 7) return target.startsWith('copy_manga-') ? target : 'copy_manga-$target';

    // For type 8 (Komiic): prefix "Komiic-"
    if (type.key == 8) return target.startsWith('Komiic-') ? target : 'Komiic-$target';

    return target;
  }

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
  late String _dbPath;

  final _foldersController = StreamController<List<FavGroup>>.broadcast();

  Stream<List<FavGroup>> get allFoldersStream => _foldersController.stream;

  Future<void> init() async {
    final appDir = await getApplicationSupportDirectory();
    _dbPath = "${appDir.path}/local_favorite.db";
    try {
      _db.dispose();
    } catch (_) {}
    _db = sqlite3.open(_dbPath);
    _checkAndCreate();
    await readData();
    _emitFolders();
  }

  void dispose() {
    try {
      _db.dispose();
    } catch (_) {}
  }

  void _checkAndCreate() {
    final tables = _getTablesWithDB();
    if (!tables.contains('folder_order')) {
      _db.execute("""
        create table folder_order (
          folder_name text primary key,
          order_value int
        );
      """);
    }
    tables.remove('folder_order');
    if (tables.isEmpty) return;
    var testTable = tables.first;
    var res = _db.select("""
      PRAGMA table_info("$testTable");
    """);
    bool shouldUpdate = false;
    for (var row in res) {
      if (row["name"] == "type" && row["pk"] == 0) {
        shouldUpdate = true;
        break;
      }
    }
    if (shouldUpdate) {
      for (var table in tables) {
        var tempName = "${table}_dw5d8g2_temp";
        _db.execute("""
          CREATE TABLE "$tempName" AS SELECT * FROM "$table";
          DROP TABLE "$table";
          CREATE TABLE "$table" (
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
          INSERT INTO "$table" SELECT * FROM "$tempName";
          DROP TABLE "$tempName";
        """);
      }
    }
  }

  void _emitFolders() {
    final names = _getFolderNameStrings();
    _foldersController
        .add(names.map((e) => FavGroup(e, order: 0)).toList());
  }

  Future<void> readData() async {
    var file = File("$_dbPath.localFavorite");
    if (file.existsSync()) {
      Map<String, List<FavoriteItem>> allComics = {};
      try {
        var data = (const JsonDecoder().convert(file.readAsStringSync()))
            as Map<String, dynamic>;
        for (var key in data.keys.toList()) {
          Set<FavoriteItem> comics = {};
          for (var comic in data[key]!) {
            comics.add(FavoriteItem.fromJson(comic));
          }
          if (allComics.containsKey(key)) {
            comics.addAll(allComics[key]!);
          }
          allComics[key] = comics.toList();
        }
        await clearAll();
        for (var folder in allComics.keys) {
          createFolder(folder);
          var comics = allComics[folder]!;
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

  List<String> _getTablesWithDB() {
    final tables = _db
        .select("SELECT name FROM sqlite_master WHERE type='table';")
        .map((element) => element["name"] as String)
        .toList();
    return tables;
  }

  List<String> _getFolderNameStrings() {
    final folders = _getTablesWithDB();
    folders.remove('folder_order');
    var folderToOrder = <String, int>{};
    for (var folder in folders) {
      var res = _db.select("""
        select * from folder_order
        where folder_name == ?;
      """, [folder]);
      if (res.isNotEmpty) {
        folderToOrder[folder] = res.first["order_value"];
      } else {
        folderToOrder[folder] = 0;
      }
    }
    folders.sort((a, b) => folderToOrder[a]! - folderToOrder[b]!);
    return folders;
  }

  List<String> get folderNames => _getFolderNameStrings();

  void updateUI() {
    _emitFolders();
  }

  int maxValue(String folder) {
    return _db.select("""
      SELECT MAX(display_order) AS max_value
      FROM "$folder";
    """).firstOrNull?["max_value"] ?? 0;
  }

  int minValue(String folder) {
    return _db.select("""
      SELECT MIN(display_order) AS min_value
      FROM "$folder";
    """).firstOrNull?["min_value"] ?? 0;
  }

  int count(String folderName) {
    return _db.select("""
      select count(*) as c
      from "$folderName"
    """).first["c"];
  }

  String createFolder(String name) {
    if (name.isEmpty) {
      throw "name is empty!";
    }
    if (_getFolderNameStrings().contains(name)) {
      throw Exception("Folder is existing");
    }
    _db.execute("""
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
    _emitFolders();
    return name;
  }

  void deleteFolder(String name) {
    _db.execute("""
      drop table "$name";
    """);
    _emitFolders();
  }

  void rename(String oldName, String newName) {
    if (_getFolderNameStrings().contains(newName)) {
      throw "Name already exists!";
    }
    if (newName.contains('"')) {
      throw "Invalid name";
    }
    _db.execute("""
      ALTER TABLE "$oldName"
      RENAME TO "$newName";
    """);
    _emitFolders();
  }

  bool comicExists(String folder, String target, int type) {
    var res = _db.select("""
      select * from "$folder"
      where target == ? and type == ?;
    """, [target, type]);
    return res.isNotEmpty;
  }

  void addComic(String folder, FavoriteItem comic, [int? order]) {
    if (!_getFolderNameStrings().contains(folder)) {
      throw Exception("Folder does not exists");
    }
    var res = _db.select("""
      select * from "$folder"
      where target == ?;
    """, [comic.target]);
    if (res.isNotEmpty) {
      return;
    }
    if (order != null) {
      _db.execute("""
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
    } else {
      _db.execute("""
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
        maxValue(folder) + 1,
      ]);
    }
    _emitFolders();
  }

  void deleteComic(String folder, FavoriteItem comic) {
    _db.execute("""
      delete from "$folder"
      where target == ? and type == ?;
    """, [comic.target, comic.type.key]);
    _emitFolders();
  }

  void deleteComicWithTarget(String folder, String target, FavoriteType type) {
    _db.execute("""
      delete from "$folder"
      where target == ? and type == ?;
    """, [target, type.key]);
    _emitFolders();
  }

  void editTags(String target, String folder, List<String> tags) {
    _db.execute("""
      update "$folder"
      set tags = ?
      where target == ?;
    """, [tags.join(','), target]);
  }

  List<FavoriteItem> getAllComics(String folder) {
    var rows = _db.select("""
      select * from "$folder"
      ORDER BY display_order;
    """);
    return rows.map((element) => FavoriteItem.fromRow(element)).toList();
  }

  List<FavoriteItemWithFolderInfo> search(String keyword) {
    var keywordList = keyword.split(" ");
    var searchKeyword = keywordList.first;
    var comics = <FavoriteItemWithFolderInfo>[];
    for (var table in _getFolderNameStrings()) {
      var likePattern = "%$searchKeyword%";
      var res = _db.select("""
        SELECT * FROM "$table"
        WHERE name LIKE ? OR author LIKE ? OR tags LIKE ?;
      """, [likePattern, likePattern, likePattern]);
      for (var comic in res) {
        comics.add(FavoriteItemWithFolderInfo(
            FavoriteItem.fromRow(comic), table));
      }
      if (comics.length > 200) {
        break;
      }
    }

    bool test(FavoriteItemWithFolderInfo comic, String kw) {
      if (comic.comic.name.contains(kw)) return true;
      if (comic.comic.author.contains(kw)) return true;
      if (comic.comic.tags.any((element) => element.contains(kw))) return true;
      return false;
    }

    for (var i = 1; i < keywordList.length; i++) {
      comics =
          comics.where((element) => test(element, keywordList[i])).toList();
    }

    return comics;
  }

  List<FavoriteItemWithFolderInfo> allComics() {
    var res = <FavoriteItemWithFolderInfo>[];
    for (final folder in _getFolderNameStrings()) {
      var comics = _db.select("""
        select * from "$folder";
      """);
      res.addAll(comics.map((element) =>
          FavoriteItemWithFolderInfo(
              FavoriteItem.fromRow(element), folder)));
    }
    return res;
  }

  Future<void> clearAll() async {
    for (var folder in _getFolderNameStrings()) {
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
    deleteFolder(folder);
    createFolder(folder);
    for (int i = 0; i < newFolder.length; i++) {
      addComic(folder, newFolder[i], i);
    }
    _emitFolders();
  }

  void updateOrder(Map<String, int> order) {
    for (var folder in order.keys) {
      _db.execute("""
        insert or replace into folder_order (folder_name, order_value)
        values (?, ?);
      """, [folder, order[folder]]);
    }
    _emitFolders();
  }

  void onReadEnd(String favoriteId, FavoriteType favoriteType) {}
}
