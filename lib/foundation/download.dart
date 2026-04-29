// ignore_for_file: no_leading_underscores_for_local_identifiers, avoid_unused_constructor_parameters

import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import '../tools/extensions.dart';
import 'download_model.dart';

class DownloadManager with _DownloadDb {
  static DownloadManager? cache;

  factory DownloadManager() => cache ?? (cache = DownloadManager._create());

  DownloadManager._create();

  String? path;

  @override
  Database? _db;

  Future<void> _getPath() async {
    final appPath = await getApplicationSupportDirectory();
    path = "${appPath.path}/download";
    var dir = Directory(path!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  Future<void> init() async {
    await _getPath();
    await _initDb();
  }

  Future<void> _initDb() async {
    _db = sqlite3.open("$path/download.db");
    _createTable();
  }

  void dispose() {
    _db?.dispose();
    _db = null;
  }

  String generateId(String source, String id) {
    return "$source-$id";
  }

  Future<DownloadedItem?> getComicOrNull(String id) async {
    return _getComicWithDb(id);
  }

  Future<void> delete(List<String> ids) async {
    for (var id in ids) {
      _deleteFromDb(id);
      var comic = Directory("$path/${getDirectory(id)}");
      try {
        comic.delete(recursive: true);
      } catch (e) {
        if (e is! PathNotFoundException) {
          rethrow;
        }
      }
    }
  }

  Future<String?> deleteEpisode(DownloadedItem comic, int ep) async {
    try {
      if (comic.downloadedEps.length == 1) {
        return "Delete Error: only one downloaded episode";
      }
      if (Directory("$path/${getDirectory(comic.id)}/${ep + 1}").existsSync()) {
        Directory("$path/${getDirectory(comic.id)}/${ep + 1}")
            .deleteSync(recursive: true);
      }
      var size = Directory("$path/${getDirectory(comic.id)}").getMBSizeSync();
      comic.downloadedEps.remove(ep);
      comic.comicSize = size;
      _addToDb(comic, comic.directory ?? getDirectory(comic.id));
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  File getCover(String id) {
    return File("$path/${getDirectory(id)}/cover.jpg");
  }

  File getImage(String id, int ep, int index) {
    String downloadPath;
    if (ep == 0) {
      downloadPath = "$path/${getDirectory(id)}/";
    } else {
      downloadPath = "$path/${getDirectory(id)}/$ep/";
    }
    for (var file in Directory(downloadPath).listSync()) {
      if (file is File &&
          file.uri.pathSegments.last.replaceFirst(RegExp(r"\..+"), "") ==
              index.toString()) {
        return file;
      }
    }
    throw Exception("File not found");
  }
}

extension on Directory {
  double getMBSizeSync() {
    double size = 0;
    try {
      for (var entry in listSync(recursive: true)) {
        if (entry is File) {
          size += entry.lengthSync();
        }
      }
    } catch (_) {}
    return size / 1024 / 1024;
  }
}

abstract mixin class _DownloadDb {
  Database? get _db;

  void _createTable() {
    _db!.execute('''
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
  }

  void _addToDb(DownloadedItem item, String directory, [DateTime? time]) {
    _db!.execute('''
      insert or replace into download
      values (?,?,?,?,?,?,?)
    ''', [
      item.id,
      item.name,
      item.subTitle,
      (time ?? DateTime.now()).millisecondsSinceEpoch,
      directory,
      item.comicSize,
      jsonEncode(item.toJson()),
    ]);
  }

  bool isExists(String id) {
    var result = _db!.select('''
      select id from download
      where id = ?
    ''', [id]);
    return result.isNotEmpty;
  }

  void _deleteFromDb(String id) {
    _db!.execute('''
      delete from download
      where id = ?
    ''', [id]);
  }

  DownloadedItem? _getComicWithDb(String id) {
    var result = _db!.select('''
      select * from download
      where id = ?
    ''', [id]);
    if (result.isEmpty) return null;
    var data = result.first;
    return _getComicFromJson(
      data['id'],
      data['json'],
      DateTime.fromMillisecondsSinceEpoch(data['time']),
      data['directory'],
    );
  }

  int get total {
    var result = _db!.select('''
      select count(*) from download
    ''');
    return result.first['count(*)'];
  }

  List<DownloadedItem> getAll(
      [String order = 'time', String direction = 'desc']) {
    var result = _db!.select('''
      select * from download
      order by $order $direction
    ''');
    return result
        .map(
          (e) => _getComicFromJson(
            e['id'],
            e['json'],
            DateTime.fromMillisecondsSinceEpoch(e['time']),
            e['directory'],
          )!,
        )
        .toList();
  }

  static final _directoryCache = <String, String>{};

  String getDirectory(String id) {
    var directory = _directoryCache[id];
    if (directory == null) {
      var result = _db!.select('''
        select directory from download
        where id = ?
      ''', [id]);
      directory = result.first['directory'] as String;
      directory = _sanitizeFileName(directory);
      if (_directoryCache.length > 50) {
        _directoryCache.remove(_directoryCache.keys.first);
      }
      _directoryCache[id] = directory;
    }
    return directory;
  }

  static String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  }
}

DownloadedItem? _getComicFromJson(
    String id, String json, DateTime time, String? directory) {
  DownloadedItem comic;
  try {
    final data = jsonDecode(json) as Map<String, dynamic>;
    if (id.contains('-') && data.containsKey("sourceKey")) {
      comic = CustomDownloadedItem.fromJson(data);
    } else if (id.startsWith("jm")) {
      comic = DownloadedJmComic.fromMap(data);
    } else if (id.startsWith("hitomi")) {
      comic = DownloadedHitomiComic.fromMap(data);
    } else if (id.startsWith("nhentai")) {
      comic = NhentaiDownloadedComic.fromJson(data);
    } else if (id.startsWith("Ht")) {
      comic = DownloadedHtComic.fromJson(data);
    } else if (id.isNum) {
      comic = DownloadedComic.fromJson(data);
    } else {
      comic = DownloadedGallery.fromJson(data);
    }
    comic.time = time;
    comic.directory = directory;
    return comic;
  } catch (e) {
    return null;
  }
}
