// ignore_for_file: no_leading_underscores_for_local_identifiers, avoid_unused_constructor_parameters

import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import '../base.dart';
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
    if (appdata.settings[22].isEmpty) {
      final appPath = await getApplicationSupportDirectory();
      path = "${appPath.path}/download";
    } else {
      path = appdata.settings[22];
    }
    var dir = Directory(path!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    print('[PicaKeep] Download path: $path');
  }

  Future<void> init() async {
    await _getPath();
    await _initDb();
  }

  Future<void> _initDb() async {
    _db?.dispose();
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

  int scanDirectoryForComics() {
    if (path == null) return 0;
    final dir = Directory(path!);
    if (!dir.existsSync()) return 0;

    int count = 0;
    final entries = dir.listSync();
    for (final entry in entries) {
      if (entry is! Directory) continue;
      final dirName = entry.uri.pathSegments.last;
      if (dirName == 'download.db') continue;

      // Check if this directory has ANY image files (either in subdirs or flat)
      final subEntries = entry.listSync();
      final hasSubdirImages =
          subEntries.any((e) => e is Directory && _hasImageFiles(e));
      final hasFlatImages = subEntries.any((e) => e is File && _isImageFile(e));

      if (!hasSubdirImages && !hasFlatImages) continue;

      if (isExists(dirName)) continue;

      final chapters = <String>[];
      final downloadedChapters = <int>[];

      // Mode 1: Flat images (no chapter subdirs, images in root)
      if (hasFlatImages && !hasSubdirImages) {
        chapters.add('\u7B2C1\u7AE0');
        downloadedChapters.add(0);
      }
      // Mode 2: Chapter subdirectories
      else if (hasSubdirImages) {
        for (final subEntry in subEntries) {
          if (subEntry is Directory && _hasImageFiles(subEntry)) {
            final chName = subEntry.uri.pathSegments.last;
            chapters.add(chName);
            downloadedChapters.add(chapters.length - 1);
          }
        }
      }

      final totalSize = entry.getMBSizeSync();

      final comic = DownloadedComic(
        comicId: dirName,
        title: dirName,
        author: '',
        chapters: chapters,
        downloadedChapters: downloadedChapters,
        size: totalSize,
        tagList: [],
      );
      comic.time = DateTime.now();
      comic.directory = dirName;

      _addToDb(comic, dirName, DateTime.now());
      count++;
    }
    return count;
  }

  static bool _isImageFile(FileSystemEntity e) {
    if (e is! File) return false;
    final name = e.uri.pathSegments.last.toLowerCase();
    return name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.png') ||
        name.endsWith('.webp');
  }

  static bool _hasImageFiles(Directory dir) {
    return dir.listSync().any((e) => _isImageFile(e));
  }

  List<DownloadedItem> getAll(
      [String order = 'time', String direction = 'desc']) {
    // Auto-init if _db is null (disposed after path change)
    if (_db == null || path == null) {
      print(
          '[PicaKeep] getAll() called but _db=$_db, path=$path, auto-init...');
      return [];
    }

    var result = _db!.select('''
      select * from download
      order by $order $direction
    ''');
    int success = 0;
    int failed = 0;
    final items = <DownloadedItem>[];
    for (var e in result) {
      final item = _getComicFromJson(
        e['id'],
        e['json'],
        DateTime.fromMillisecondsSinceEpoch(e['time']),
        e['directory'],
      );
      if (item != null) {
        items.add(item);
        success++;
      } else {
        failed++;
      }
    }
    print(
        '[PicaKeep] getAll() loaded: $success success, $failed failed, total ${result.length}');

    return items;
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
  DownloadedItem? comic;
  try {
    final data = jsonDecode(json) as Map<String, dynamic>;

    // Primary: use ID prefix matching (consistent with original PicaComic)
    if (id.contains('-')) {
      // Custom sources: copy_manga, Komiic, etc.
      try {
        comic = CustomDownloadedItem.fromJson(data);
      } catch (e) {
        print(
            '[PicaKeep] CustomDownloadedItem.fromJson failed for id="$id": $e');
      }
    } else if (id.startsWith("jm")) {
      try {
        comic = DownloadedJmComic.fromMap(data);
      } catch (e) {
        print('[PicaKeep] DownloadedJmComic.fromMap failed for id="$id": $e');
      }
    } else if (id.startsWith("hitomi")) {
      try {
        comic = DownloadedHitomiComic.fromMap(data);
      } catch (e) {
        print(
            '[PicaKeep] DownloadedHitomiComic.fromMap failed for id="$id": $e');
      }
    } else if (id.startsWith("nhentai")) {
      try {
        comic = NhentaiDownloadedComic.fromJson(data);
      } catch (e) {
        print(
            '[PicaKeep] NhentaiDownloadedComic.fromJson failed for id="$id": $e');
      }
    } else if (id.startsWith("Ht")) {
      try {
        comic = DownloadedHtComic.fromJson(data);
      } catch (e) {
        print('[PicaKeep] DownloadedHtComic.fromJson failed for id="$id": $e');
      }
    } else if (id.isNum) {
      // E-Hentai: pure numeric ID like "2971848"
      try {
        comic = DownloadedGallery.fromJson(data);
      } catch (e) {
        print('[PicaKeep] DownloadedGallery.fromJson failed for id="$id": $e');
      }
    } else {
      // Picacg: MongoDB ObjectId like "6595730e2ef71146c8a109a6"
      try {
        comic = DownloadedComic.fromJson(data);
      } catch (e) {
        print('[PicaKeep] DownloadedComic.fromJson failed for id="$id": $e');
      }
    }

    // Fallback: if primary parsing failed, try JSON key detection
    if (comic == null) {
      print(
          '[PicaKeep] Primary parsing failed for id="$id", trying fallback...');
      if (data.containsKey("comicItem")) {
        try {
          comic = DownloadedComic.fromJson(data);
        } catch (e) {
          print(
              '[PicaKeep] Fallback DownloadedComic.fromJson failed for id="$id": $e');
        }
      } else if (data.containsKey("galleryTitle")) {
        try {
          comic = DownloadedGallery.fromJson(data);
        } catch (e) {
          print(
              '[PicaKeep] Fallback DownloadedGallery.fromJson failed for id="$id": $e');
        }
      } else if (data.containsKey("comicID")) {
        try {
          comic = NhentaiDownloadedComic.fromJson(data);
        } catch (e) {
          print(
              '[PicaKeep] Fallback NhentaiDownloadedComic.fromJson failed for id="$id": $e');
        }
      } else if (data.containsKey("sourceKey")) {
        try {
          comic = CustomDownloadedItem.fromJson(data);
        } catch (e) {
          print(
              '[PicaKeep] Fallback CustomDownloadedItem.fromJson failed for id="$id": $e');
        }
      }
    }

    if (comic == null) {
      print(
          '[PicaKeep] _getComicFromJson FAILED for id="$id": unable to parse with any method');
      final jsonSample =
          json.length > 300 ? '${json.substring(0, 300)}...[TRUNCATED]' : json;
      print('[PicaKeep] JSON sample: $jsonSample');
      return null;
    }

    comic.time = time;
    comic.directory = directory;
    return comic;
  } catch (e, s) {
    final jsonSample =
        json.length > 300 ? '${json.substring(0, 300)}...[TRUNCATED]' : json;
    print('[PicaKeep] _getComicFromJson FAILED for id="$id": $e');
    print('[PicaKeep] Stack: $s');
    print('[PicaKeep] JSON sample: $jsonSample');
    return null;
  }
}
