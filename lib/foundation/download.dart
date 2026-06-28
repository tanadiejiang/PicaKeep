import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import '../base.dart';
import '../tools/extensions.dart';
import 'download_model.dart';
import 'local_library_settings.dart';
import 'local_trash_store.dart';

const _storageAccessChannelName = 'lingxue.picakeep/storage_access';
const _androidApplicationId = 'lingxue.picakeep';

const MethodChannel _storageAccessChannel =
    MethodChannel(_storageAccessChannelName);

enum _PrivilegedDeleteMode {
  root,
  shizuku,
}

Future<bool> _hasRootAccess({bool forceRefresh = false}) async {
  if (!Platform.isAndroid) {
    return false;
  }
  try {
    return await _storageAccessChannel.invokeMethod<bool>(
          'hasRootAccess',
          {'forceRefresh': forceRefresh},
        ) ??
        false;
  } catch (_) {
    return false;
  }
}

Future<bool> _hasShizukuPermission({bool forceRefresh = false}) async {
  if (!Platform.isAndroid) {
    return false;
  }
  try {
    return await _storageAccessChannel.invokeMethod<bool>(
          'hasShizukuPermission',
          {'forceRefresh': forceRefresh},
        ) ??
        false;
  } catch (_) {
    return false;
  }
}

List<_PrivilegedDeleteMode> _enabledPrivilegedDeleteModes() {
  if (!Platform.isAndroid) {
    return const [];
  }
  final modes = <_PrivilegedDeleteMode>[];
  if (normalizeAndroidRootMode(appdata.settings[androidRootModeSettingIndex]) ==
      '1') {
    modes.add(_PrivilegedDeleteMode.root);
  }
  if (normalizeAndroidShizukuMode(
          appdata.settings[androidShizukuModeSettingIndex]) ==
      '1') {
    modes.add(_PrivilegedDeleteMode.shizuku);
  }
  return modes;
}

Future<_PrivilegedDeleteMode?> _resolvePrivilegedDeleteMode({
  bool forceRefresh = false,
}) async {
  for (final mode in _enabledPrivilegedDeleteModes()) {
    switch (mode) {
      case _PrivilegedDeleteMode.root:
        if (await _hasRootAccess(forceRefresh: forceRefresh)) {
          return mode;
        }
        break;
      case _PrivilegedDeleteMode.shizuku:
        if (await _hasShizukuPermission(forceRefresh: forceRefresh)) {
          return mode;
        }
        break;
    }
  }
  return null;
}

Future<bool> _pathExistsWithPrivilegedMode(
  String path, {
  required _PrivilegedDeleteMode mode,
}) async {
  final method = switch (mode) {
    _PrivilegedDeleteMode.root => 'existsWithRoot',
    _PrivilegedDeleteMode.shizuku => 'existsWithShizuku',
  };
  return await _storageAccessChannel.invokeMethod<bool>(
        method,
        {'path': path},
      ) ??
      false;
}

String _normalizeAndroidStoragePath(String path) {
  var normalized = path.trim().replaceAll('\\', '/');
  while (normalized.contains('//')) {
    normalized = normalized.replaceAll('//', '/');
  }
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

bool _isOtherAppAndroidContainerRoot(String path) {
  if (!Platform.isAndroid) {
    return false;
  }
  final normalized = _normalizeAndroidStoragePath(path);
  final segments =
      normalized.split('/').where((entry) => entry.isNotEmpty).toList();
  final androidIndex = segments.indexOf('Android');
  if (androidIndex < 0 || androidIndex + 2 >= segments.length) {
    return false;
  }
  final container = segments[androidIndex + 1];
  if (container != 'data' && container != 'obb') {
    return false;
  }
  final packageName = segments[androidIndex + 2];
  return packageName.isNotEmpty && packageName != _androidApplicationId;
}

Future<void> _deletePathWithPrivilegedMode(
  String path, {
  required _PrivilegedDeleteMode mode,
}) async {
  final method = switch (mode) {
    _PrivilegedDeleteMode.root => 'deletePathWithRoot',
    _PrivilegedDeleteMode.shizuku => 'deletePathWithShizuku',
  };
  await _storageAccessChannel.invokeMethod<void>(
    method,
    {'path': path},
  );
}

class DownloadManager with _DownloadDb {
  static DownloadManager? cache;

  factory DownloadManager() => cache ?? (cache = DownloadManager._create());

  DownloadManager._create();

  String? path;

  @override
  Database? _db;
  String? _dbFilePath;
  Set<String>? _downloadIdSetCache;
  final Map<String, String?> _resolvedIdCache = {};

  void _clearLookupCaches() {
    _downloadIdSetCache = null;
    _resolvedIdCache.clear();
  }

  Set<String> _knownDownloadIds() {
    final cached = _downloadIdSetCache;
    if (cached != null) {
      return cached;
    }
    if (_db == null) {
      return const <String>{};
    }
    final ids = _db!
        .select('select id from download;')
        .map((row) => (row['id'] as String? ?? '').trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    _downloadIdSetCache = ids;
    return ids;
  }

  Future<void> _getPath() async {
    _DownloadDb.clearDirectoryCache();
    if (appdata.settings[22].isEmpty) {
      final appPath = await getApplicationSupportDirectory();
      path = "${appPath.path}/download";
    } else {
      path = appdata.settings[22];
    }
    final dir = Directory(path!);
    final shouldUsePrivilegedExists = _isOtherAppAndroidContainerRoot(path!);
    if (shouldUsePrivilegedExists) {
      final mode = await _resolvePrivilegedDeleteMode(forceRefresh: true);
      if (mode == null ||
          !await _pathExistsWithPrivilegedMode(path!, mode: mode)) {
        throw StateError('download_path_permission_denied');
      }
    } else if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    print('[PicaKeep] Download path: $path');
  }

  Future<void> init() async {
    if (_db != null && _dbFilePath != null && path != null) {
      final configuredPath =
          appdata.settings[22].isEmpty ? path! : appdata.settings[22];
      if (_dbFilePath == "$configuredPath/download.db") {
        path = configuredPath;
        return;
      }
    }
    await _getPath();
    await _initDb();
  }

  Future<void> _initDb() async {
    final nextDbPath = "$path/download.db";
    if (_db != null && _dbFilePath == nextDbPath) {
      return;
    }
    _db?.dispose();
    _db = sqlite3.open(nextDbPath);
    _dbFilePath = nextDbPath;
    _createTable();
    _clearLookupCaches();
  }

  void dispose() {
    _db?.dispose();
    _db = null;
    _dbFilePath = null;
    _clearLookupCaches();
  }

  String? get dbFilePath => _dbFilePath;

  String _comicPath(String relativeDir) => '${path!}$pathSep$relativeDir';

  bool _dirExists(String relativeDir) {
    if (path == null) return false;
    try {
      return Directory(_comicPath(relativeDir)).existsSync();
    } catch (_) {
      return false;
    }
  }

  String _resolveDirectoryForId(String id, String rawFromDb) {
    if (path == null || _db == null) {
      return _DownloadDb.sanitizeFileName(
          rawFromDb.trim().isNotEmpty ? rawFromDb : id);
    }
    final raw = rawFromDb.trim();
    final sanitized = _DownloadDb.sanitizeFileName(raw.isNotEmpty ? raw : id);
    if (_dirExists(sanitized)) return sanitized;
    if (raw.isNotEmpty && raw != sanitized && _dirExists(raw)) return raw;
    try {
      final parent = Directory(path!);
      if (!parent.existsSync()) return sanitized;
      final lowerSan = sanitized.toLowerCase();
      final lowerRaw = raw.toLowerCase();
      for (final e in parent.listSync()) {
        if (e is! Directory) continue;
        final name = e.uri.pathSegments.isEmpty
            ? ''
            : e.uri.pathSegments
                .lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (name.isEmpty || name == 'download.db') continue;
        final ln = name.toLowerCase();
        if (ln == lowerSan || ln == lowerRaw) return name;
      }
    } catch (_) {}
    return sanitized;
  }

  String generateId(String source, String id) {
    return "$source-$id";
  }

  Future<DownloadedItem?> getComicOrNull(String id) async {
    return _getComicWithDb(id);
  }

  String? resolveExistingId(Iterable<String> candidates) {
    if (_db == null) return null;
    final normalized = <String>[];
    final seen = <String>{};
    for (final candidate in candidates) {
      final id = candidate.trim();
      if (id.isEmpty || !seen.add(id)) {
        continue;
      }
      normalized.add(id);
    }
    if (normalized.isEmpty) {
      return null;
    }

    final cacheKey = normalized.join('\u0001');
    if (_resolvedIdCache.containsKey(cacheKey)) {
      return _resolvedIdCache[cacheKey];
    }

    final knownIds = _knownDownloadIds();
    for (final id in normalized) {
      if (knownIds.contains(id)) {
        _resolvedIdCache[cacheKey] = id;
        return id;
      }
    }
    _resolvedIdCache[cacheKey] = null;
    return null;
  }

  Future<DownloadedItem?> getComicOrNullFromCandidates(
      Iterable<String> candidates) async {
    final id = resolveExistingId(candidates);
    if (id == null) {
      return null;
    }
    return _getComicWithDb(id);
  }

  File getCoverFromCandidates(Iterable<String> candidates) {
    final id = resolveExistingId(candidates);
    if (id == null) {
      return File('');
    }
    return getCover(id);
  }

  Future<void> delete(List<String> ids) async {
    await deletePermanentlyByIds(ids);
  }

  Future<void> deletePermanentlyByIds(List<String> ids) async {
    for (var id in ids) {
      final directory = getDirectory(id);
      _deleteFromDb(id);
      var comic = Directory("$path/$directory");
      try {
        await comic.delete(recursive: true);
      } catch (e) {
        if (e is! PathNotFoundException) {
          rethrow;
        }
      }
    }
    _clearLookupCaches();
  }

  void deleteDbRecordOnly(String id) {
    _deleteFromDb(id);
    _clearLookupCaches();
  }

  int? rowIdFor(String id) {
    if (_db == null) {
      return null;
    }
    final result = _db!.select('''
      select rowid as __rowid__
      from download
      where id = ?
      limit 1
    ''', [id]);
    if (result.isEmpty) {
      return null;
    }
    return result.first['__rowid__'] as int?;
  }

  void upsertDbRecordOnly(
    DownloadedItem item,
    String directory, [
    DateTime? time,
    int? rowId,
  ]) {
    if (rowId != null && rowId > 0) {
      _db!.execute('''
        insert or replace into download(
          rowid,
          id,
          title,
          subtitle,
          time,
          directory,
          size,
          json
        ) values (?,?,?,?,?,?,?,?)
      ''', [
        rowId,
        item.id,
        item.name,
        item.subTitle,
        (time ?? DateTime.now()).millisecondsSinceEpoch,
        directory,
        item.comicSize,
        jsonEncode(item.toJson()),
      ]);
    } else {
      _addToDb(item, directory, time);
    }
    _clearLookupCaches();
  }

  Future<String?> deleteEpisode(DownloadedItem comic, int ep) async {
    try {
      if (comic.downloadedEps.length == 1) {
        return "Delete Error: only one downloaded episode";
      }
      final comicDirectory = "$path/${getDirectory(comic.id)}";
      final episodeDirectory = Directory("$comicDirectory/${ep + 1}");
      var deleted = false;
      try {
        if (episodeDirectory.existsSync()) {
          await episodeDirectory.delete(recursive: true);
          deleted = true;
        }
      } on FileSystemException catch (e) {
        if (!_isPermissionDenied(e)) {
          rethrow;
        }
      }
      if (!deleted) {
        final mode = await _resolvePrivilegedDeleteMode();
        final resolvedMode = mode ??
            (_enabledPrivilegedDeleteModes().isEmpty
                ? null
                : await _resolvePrivilegedDeleteMode(forceRefresh: true));
        if (resolvedMode == null) {
          return '当前路径权限不足，无法删除。请检查 Shizuku 授权 / Root 模式，或改用可访问目录。';
        }
        await _deletePathWithPrivilegedMode(
          episodeDirectory.path,
          mode: resolvedMode,
        );
      }
      var size = comic.comicSize;
      try {
        size = Directory(comicDirectory).getMBSizeSync();
      } catch (_) {}
      comic.downloadedEps.remove(ep);
      comic.comicSize = size;
      _addToDb(comic, comic.directory ?? getDirectory(comic.id));
      _clearLookupCaches();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  bool _isPermissionDenied(FileSystemException e) {
    final message = e.message.toLowerCase();
    final osMessage = e.osError?.message.toLowerCase() ?? '';
    return e.osError?.errorCode == 13 ||
        message.contains('permission denied') ||
        osMessage.contains('permission denied');
  }

  File getCoverForDisplay(String id) {
    return getCover(id);
  }

  File getCover(String id) {
    final dir = getDirectory(id);
    final root = _comicPath(dir);
    for (final name in ['cover.jpg', 'cover.webp', 'cover.png']) {
      final f = File('$root$pathSep$name');
      if (f.existsSync()) return f;
    }
    try {
      final d = Directory(root);
      if (d.existsSync()) {
        for (final e in d.listSync()) {
          if (e is File && _isImageFile(e)) return e;
        }
      }
    } catch (_) {}
    return File('$root${pathSep}cover.jpg');
  }

  File getImage(String id, int ep, int index) {
    final dir = getDirectory(id);
    final base = _comicPath(dir);
    // 候选图片目录：
    //  - 有 ep（ep>0）：固定 {base}/{ep}/
    //  - 无 ep（ep==0）：先根目录 {base}/；若根目录无数字图片，回退 {base}/1/
    //    （JmNetwork 下载即便单章也会把图放进 1/ 子目录，根目录仅 cover.jpg）。
    final candidateDirs = ep == 0
        ? ['$base$pathSep', '$base${pathSep}1$pathSep']
        : ['$base$pathSep$ep$pathSep'];
    for (final downloadPath in candidateDirs) {
      final file = _findImageInDir(downloadPath, index);
      if (file != null) return file;
    }
    throw Exception("File not found");
  }

  /// 在 [downloadPath] 内按 0/1-based 自适应查找第 [index]（0-based）张图。
  /// 找不到返回 null。
  File? _findImageInDir(String downloadPath, int index) {
    try {
      // 收集目录内所有「纯数字文件名」的图片文件，按数字 stem 建索引。
      // 历史遗留下载为 0-based（0.jpg 起），OnlineDownloadManager 落盘为 1-based（1.png 起）。
      // 同一个 download.db 被新旧两套读取，索引基准不一致会导致整本错位 + 首页 File not found。
      // 这里按目录实际最小 stem 自适应：0-based 用 index，1-based 用 index+1。
      final byStem = <int, File>{};
      var minStem = 1 << 30;
      for (var file in Directory(downloadPath).listSync()) {
        if (file is! File) continue;
        final stem =
            file.uri.pathSegments.last.replaceFirst(RegExp(r"\..+"), "");
        final n = int.tryParse(stem);
        if (n == null) continue;
        byStem[n] = file;
        if (n < minStem) minStem = n;
      }
      if (byStem.isNotEmpty) {
        // index 为 reader 的 0-based 页序号。
        final base = minStem <= 0 ? 0 : 1;
        final target = byStem[index + base];
        if (target != null) return target;
        // 兜底：精确 index 命中（极少数混合命名）。
        final exact = byStem[index];
        if (exact != null) return exact;
      }
    } catch (_) {}
    return null;
  }

  int getComicLength(String id) {
    final base = _comicPath(getDirectory(id));
    // 无 ep 漫画：图通常在根目录；但 JmNetwork 下载即便单章也放进 1/ 子目录，
    // 根目录仅 cover.jpg。根目录无图时回退 1/ 子目录计数，保持与 getImage 一致。
    final root = _countImagesInDir('$base$pathSep');
    if (root > 0) return root;
    return _countImagesInDir('$base${pathSep}1$pathSep');
  }

  int _countImagesInDir(String downloadPath) {
    int count = 0;
    try {
      for (var file in Directory(downloadPath).listSync()) {
        if (file is! File || !_isImageFile(file)) continue;
        // 只统计「纯数字文件名」的页图片，排除 cover.jpg 等非页文件，
        // 否则根目录的封面会被误计为 1 张，导致单章 jm（图在 1/ 子目录）页数只剩 1。
        final stem =
            file.uri.pathSegments.last.replaceFirst(RegExp(r"\..+"), "");
        if (int.tryParse(stem) == null) continue;
        count++;
      }
    } catch (_) {}
    return count;
  }

  int getEpLength(String id, int ep) {
    return _countImagesInDir(
        '${_comicPath(getDirectory(id))}$pathSep$ep$pathSep');
  }

  int scanDirectoryForComics() {
    if (path == null) return 0;
    final dir = Directory(path!);
    if (!dir.existsSync()) return 0;

    int count = 0;
    final entries = dir.listSync();
    final hiddenIndex = LocalTrashStore.instance.hiddenIndexSync();
    for (final entry in entries) {
      if (entry is! Directory) continue;
      final dirName = entry.uri.pathSegments.last;
      if (dirName.isEmpty ||
          dirName == 'download.db' ||
          dirName == '.picakeep_trash' ||
          hiddenIndex.matchesPath(entry.path)) {
        continue;
      }

      // Check if this directory has ANY image files (either in subdirs or flat)
      final subEntries = entry.listSync();
      final hasSubdirImages =
          subEntries.any((e) => e is Directory && _hasImageFiles(e));
      final hasFlatImages = subEntries.any((e) => e is File && _isImageFile(e));

      if (!hasSubdirImages && !hasFlatImages) continue;

      if (isExists(dirName) || _hasDirectoryRecord(dirName)) continue;

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
    if (count > 0) {
      _clearLookupCaches();
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
    int parsed = 0;
    int failed = 0;
    final bestItems = <String, DownloadedItem>{};
    final bestScores = <String, int>{};
    final orderedKeys = <String>[];
    final hiddenIndex = LocalTrashStore.instance.hiddenIndexSync();
    final dbPath = _dbFilePath ?? '$path/download.db';
    for (var e in result) {
      final rawId = (e['id'] as String? ?? '').trim();
      final rawDirectory = (e['directory'] as String? ?? '').trim();
      final item = _getComicFromJson(
        e['id'],
        e['json'],
        DateTime.fromMillisecondsSinceEpoch(e['time']),
        e['directory'],
      );
      if (item != null) {
        parsed++;
        final resolvedDirectory = _resolveDirectoryForId(rawId, rawDirectory);
        final originalPath = _comicPath(resolvedDirectory);
        if (hiddenIndex.matchesManagedDownload(
          itemId: rawId,
          sourceDbPath: dbPath,
          sourceDbId: rawId,
          sourceDirectory:
              rawDirectory.isNotEmpty ? rawDirectory : resolvedDirectory,
          originalPath: originalPath,
        )) {
          continue;
        }
        final dedupeKey = resolvedDirectory.isNotEmpty
            ? resolvedDirectory.toLowerCase()
            : rawId.toLowerCase();
        final score = _downloadRowPriority(rawId, rawDirectory);
        final previousScore = bestScores[dedupeKey];
        if (previousScore == null) {
          orderedKeys.add(dedupeKey);
          bestScores[dedupeKey] = score;
          bestItems[dedupeKey] = item;
        } else if (score > previousScore) {
          bestScores[dedupeKey] = score;
          bestItems[dedupeKey] = item;
        }
      } else {
        failed++;
      }
    }
    final items = orderedKeys.map((key) => bestItems[key]!).toList();
    print(
        '[PicaKeep] getAll() loaded: ${items.length} visible, $parsed parsed, $failed failed, total ${result.length}');

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
    if (item.id.isEmpty || directory.isEmpty) {
      print(
          '[PicaKeep] _addToDb: Skipping invalid data (empty id or directory)');
      return;
    }
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
    if (_db == null) {
      return false;
    }
    var result = _db!.select('''
      select id from download
      where id = ?
    ''', [id]);
    return result.isNotEmpty;
  }

  bool _hasDirectoryRecord(String directory) {
    final normalized = directory.trim();
    if (normalized.isEmpty) {
      return false;
    }
    final result = _db!.select('''
      select 1 from download
      where directory = ?
      limit 1
    ''', [normalized]);
    return result.isNotEmpty;
  }

  bool _looksLikeCanonicalDownloadId(String id) {
    final value = id.trim();
    return value.contains('-') ||
        value.startsWith('jm') ||
        value.startsWith('hitomi') ||
        value.startsWith('nhentai') ||
        value.startsWith('Ht') ||
        value.isNum ||
        RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(value);
  }

  int _downloadRowPriority(String id, String directory) {
    final normalizedId = id.trim();
    final normalizedDirectory = directory.trim();
    if (normalizedId.isEmpty) {
      return -1;
    }
    if (_looksLikeCanonicalDownloadId(normalizedId) &&
        normalizedId != normalizedDirectory) {
      return 2;
    }
    if (_looksLikeCanonicalDownloadId(normalizedId)) {
      return 1;
    }
    return 0;
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
    if (_db == null) return 0;
    var result = _db!.select('''
      select count(*) from download
    ''');
    return result.first['count(*)'] ?? 0;
  }

  static final _directoryCache = <String, String>{};

  static void clearDirectoryCache() {
    _directoryCache.clear();
  }

  String getDirectory(String id) {
    if (_db == null) {
      return sanitizeFileName(id);
    }
    var directory = _directoryCache[id];
    if (directory == null) {
      var result = _db!.select('''
        select directory from download
        where id = ?
      ''', [id]);
      if (result.isEmpty) {
        return sanitizeFileName(id);
      }
      final rawDb = result.first['directory'] as String? ?? '';
      directory = (this as DownloadManager)._resolveDirectoryForId(id, rawDb);
      if (_directoryCache.length > 50) {
        _directoryCache.remove(_directoryCache.keys.first);
      }
      _directoryCache[id] = directory;
    }
    return directory;
  }

  static String sanitizeFileName(String name) {
    if (name.isEmpty) return 'unknown';
    String sanitized = name;
    sanitized = sanitized.replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001F]'), '_');
    sanitized =
        sanitized.replaceAll(RegExp(r'[\u3000-\u303F\uFF00-\uFFEF]'), '_');
    sanitized = sanitized.replaceAll(RegExp(r'[【】《》「」『』〔〕【】〘〙〚〛]'), '_');
    sanitized = sanitized.replaceAll(RegExp(r'[（）]'), '_');
    if (sanitized.isEmpty) {
      return 'unknown_${DateTime.now().millisecondsSinceEpoch}';
    }
    return sanitized;
  }
}

DownloadedItem? _getComicFromJson(
    String id, String json, DateTime time, String? directory) {
  final comic = parseDownloadedItemRecordJson(
    id,
    json,
    time: time,
    directory: directory,
  );
  if (comic != null) {
    return comic;
  }

  final jsonSample =
      json.length > 300 ? '${json.substring(0, 300)}...[TRUNCATED]' : json;
  print(
      '[PicaKeep] _getComicFromJson FAILED for id="$id": unable to parse with any method');
  print('[PicaKeep] JSON sample: $jsonSample');
  return null;
}
