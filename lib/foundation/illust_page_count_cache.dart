import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';

typedef IllustPageCountStampReader = Future<String?> Function(String path);

/// 只缓存成功统计。目录及已枚举的章节目录都参加验证，失败和未知从不落盘。
/// 下载数据库仍是权威来源；本缓存只是旧记录的应用内加速层。
class IllustPageCountCache {
  IllustPageCountCache.inMemory() : _file = null;
  IllustPageCountCache.atFile(File file) : _file = file;

  final File? _file;
  final _entries = <String, _PageCountRecord>{};
  Future<void>? _load;
  Future<void> _saveTail = Future.value();
  bool _dirty = false;
  int _generation = 0;
  int get generation => _generation;
  static const _maxEntries = 4096;
  static const _maxAge = Duration(days: 7);

  String _key(IllustLibraryEntry entry) => sha256
      .convert(utf8.encode(jsonEncode([
        entry.item.sourceDbPath,
        entry.item.originalId,
        entry.item.fileSystemPath,
        entry.item.sourceRowTimeMillis,
        entry.item.sourceRowJson,
      ])))
      .toString();

  Future<void> load() => _load ??= _read();

  Future<void> _read() async {
    if (_file == null) return;
    try {
      final json = jsonDecode(await _file.readAsString());
      if (json is! Map || json['version'] != 1 || json['counts'] is! Map) {
        return;
      }
      for (final entry in (json['counts'] as Map).entries.take(_maxEntries)) {
        final value = entry.value;
        if (value is! Map) continue;
        final count = value['count'],
            time = value['time'],
            stamps = value['stamps'];
        if (count is! int ||
            count <= 0 ||
            time is! int ||
            stamps is! Map ||
            stamps.isEmpty) {
          continue;
        }
        if (stamps.entries.any((e) => e.key is! String || e.value is! String)) {
          continue;
        }
        _entries[entry.key.toString()] =
            _PageCountRecord(count, time, Map<String, String>.from(stamps));
      }
    } catch (_) {
      // A missing/corrupt cache never changes user download data.
    }
  }

  Future<int?> lookup(IllustLibraryEntry entry,
      {IllustPageCountStampReader readStamp = readIllustPageCountStamp}) async {
    await load();
    final generation = _generation;
    final key = _key(entry);
    final cached = _entries[key];
    if (cached == null) return null;
    if (DateTime.now().millisecondsSinceEpoch - cached.time >
        _maxAge.inMilliseconds) {
      _entries.remove(key);
      _dirty = true;
      return null;
    }
    for (final dependency in cached.stamps.entries) {
      String? current;
      try {
        current = await readStamp(dependency.key);
      } catch (_) {}
      if (generation != _generation) return null;
      if (current == null || current != dependency.value) {
        _entries.remove(key);
        _dirty = true;
        return null;
      }
    }
    return cached.count;
  }

  void store(IllustLibraryEntry entry, int count, Map<String, String?> stamps,
      {required int generation}) {
    if (generation != _generation ||
        count <= 0 ||
        stamps.isEmpty ||
        stamps.values.any((stamp) => stamp == null)) {
      return;
    }
    _entries.remove(_key(entry));
    _entries[_key(entry)] = _PageCountRecord(count,
        DateTime.now().millisecondsSinceEpoch, Map<String, String>.from(stamps));
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _dirty = true;
  }

  Future<void> clear() async {
    await load();
    _generation++;
    _entries.clear();
    _dirty = true;
    await save();
  }

  Future<void> save() {
    if (_file == null || !_dirty) return _saveTail;
    _dirty = false;
    final encoded = jsonEncode({
      'version': 1,
      'counts': {
        for (final entry in _entries.entries)
          entry.key: {
            'count': entry.value.count,
            'time': entry.value.time,
            'stamps': entry.value.stamps,
          }
      }
    });
    return _saveTail = _saveTail.then((_) async {
      try {
        await _file.parent.create(recursive: true);
        final temporary = File('${_file.path}.part');
        await temporary.writeAsString(encoded, flush: true);
        await temporary.rename(_file.path);
      } catch (_) {
        _dirty = true;
      }
    });
  }
}

class _PageCountRecord {
  const _PageCountRecord(this.count, this.time, this.stamps);
  final int count, time;
  final Map<String, String> stamps;
}

/// 无同步 IO，不用读取整个文件的长度兜底；拿不到可靠标识就不复用统计。
Future<String?> readIllustPageCountStamp(String path) async {
  try {
    final stat = await FileStat.stat(path);
    if (stat.type == FileSystemEntityType.notFound) return null;
    return '${stat.type}:${stat.size}:${stat.modified.microsecondsSinceEpoch}';
  } catch (_) {
    return null;
  }
}

IllustPageCountCache? _sharedPageCounts;
String? _sharedPageCountRoot;

Future<IllustPageCountCache> sharedIllustPageCountCache() async {
  final String root;
  try {
    root = App.dataPath;
  } catch (_) {
    // 初始环境尚未就绪时（含纯逻辑测试）不把临时路径当作应用缓存目录。
    return IllustPageCountCache.inMemory();
  }
  if (_sharedPageCounts == null || _sharedPageCountRoot != root) {
    _sharedPageCountRoot = root;
    _sharedPageCounts = IllustPageCountCache.atFile(
        File('$root${Platform.pathSeparator}local_library_cache'
            '${Platform.pathSeparator}illust_page_counts.json'));
  }
  await _sharedPageCounts!.load();
  return _sharedPageCounts!;
}

/// 初始装配仅验证已有成功缓存，最多 4 路；不会主动扫描未缓存的作品。
Future<List<IllustLibraryEntry>> hydrateIllustPageCounts(
  List<IllustLibraryEntry> entries, {
  IllustPageCountCache? cache,
  IllustPageCountStampReader readStamp = readIllustPageCountStamp,
}) async {
  if (entries.isEmpty) return const <IllustLibraryEntry>[];
  final effective = cache ?? await sharedIllustPageCountCache();
  final result = List<IllustLibraryEntry>.of(entries);
  var next = 0;
  Future<void> worker() async {
    while (next < entries.length) {
      final index = next++;
      final entry = entries[index];
      if (entry.pageCount != null) continue;
      final count = await effective.lookup(entry, readStamp: readStamp);
      if (count != null) {
        result[index] = entry.withResolvedInfo(pageCount: count);
      }
    }
  }

  await Future.wait(List.generate(4, (_) => worker()));
  return result;
}

/// 显式刷新/本地数据变化时清除旧统计，也阻止正在运行的旧统计再次写入。
Future<void> invalidateIllustPageCounts() async =>
    (await sharedIllustPageCountCache()).clear();
