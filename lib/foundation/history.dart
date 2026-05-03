// ignore_for_file: no_leading_underscores_for_local_identifiers

import 'dart:io';

import 'package:picakeep/foundation/local_data_source.dart';
import 'package:sqlite3/sqlite3.dart';
import '../foundation/state_controller.dart';

const _legacyCustomHistorySourceKeys = <String>[
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

String? _preferredCustomHistorySourceKey(int type) {
  final mapping = <int, String>{
    'copy_manga'.hashCode: 'copy_manga',
    'Komiic'.hashCode: 'Komiic',
    'ikmmh'.hashCode: 'ikmmh',
    'baozi'.hashCode: 'baozi',
  };
  return mapping[type];
}

void _addCandidate(Set<String> candidates, String value) {
  final v = value.trim();
  if (v.isNotEmpty) {
    candidates.add(v);
  }
}

void _addCustomHistoryCandidates(Set<String> candidates, String target,
    [String? preferredSourceKey]) {
  if (preferredSourceKey != null && preferredSourceKey.isNotEmpty) {
    _addCandidate(candidates, '$preferredSourceKey-$target');
  }
  for (final key in _legacyCustomHistorySourceKeys) {
    _addCandidate(candidates, '$key-$target');
  }
}

List<String> _buildHistoryDownloadIdCandidates(String target, int type) {
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
    case 5:
      _addCandidate(candidates,
          target.startsWith('nhentai') ? target : 'nhentai$target');
      break;
    case 6:
      _addCustomHistoryCandidates(candidates, target);
      break;
    default:
      _addCustomHistoryCandidates(
          candidates, target, _preferredCustomHistorySourceKey(type));
      break;
  }

  return candidates.toList();
}

final class HistoryType {
  static HistoryType get picacg => const HistoryType(0);
  static HistoryType get ehentai => const HistoryType(1);
  static HistoryType get jmComic => const HistoryType(2);
  static HistoryType get hitomi => const HistoryType(3);
  static HistoryType get htmanga => const HistoryType(4);
  static HistoryType get nhentai => const HistoryType(5);

  /// Generic local/custom source fallback used by PicaKeep.
  static HistoryType get other => const HistoryType(6);

  final int value;

  String get name {
    const nameMap = {
      0: "picacg",
      1: "ehentai",
      2: "jm",
      3: "hitomi",
      4: "htmanga",
      5: "nhentai",
      6: "other",
    };
    return nameMap[value] ?? _preferredCustomHistorySourceKey(value) ?? "other";
  }

  const HistoryType(this.value);

  @override
  bool operator ==(Object other) =>
      other is HistoryType && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

class History {
  HistoryType type;
  DateTime time;
  String title;
  String subtitle;
  String cover;
  int ep;
  int page;
  String target;
  Set<int> readEpisode;
  int? maxPage;

  History(this.type, this.time, this.title, this.subtitle, this.cover, this.ep,
      this.page, this.target,
      [this.readEpisode = const <int>{}, this.maxPage]);

  Map<String, dynamic> toMap() => {
        "type": type.value,
        "time": time.millisecondsSinceEpoch,
        "title": title,
        "subtitle": subtitle,
        "cover": cover,
        "ep": ep,
        "page": page,
        "target": target,
        "readEpisode": readEpisode.toList(),
        "max_page": maxPage
      };

  History.fromMap(Map<String, dynamic> map)
      : type = HistoryType(map["type"]),
        time = DateTime.fromMillisecondsSinceEpoch(map["time"]),
        title = map["title"],
        subtitle = map["subtitle"],
        cover = map["cover"],
        ep = map["ep"],
        page = map["page"],
        target = map["target"],
        readEpisode = Set<int>.from(
            (map["readEpisode"] as List<dynamic>?)?.toSet() ?? const <int>{}),
        maxPage = map["max_page"];

  History.fromRow(Row row)
      : type = HistoryType(row["type"]),
        time = DateTime.fromMillisecondsSinceEpoch(row["time"]),
        title = row["title"],
        subtitle = row["subtitle"],
        cover = row["cover"],
        ep = row["ep"],
        page = row["page"],
        target = row["target"],
        readEpisode = Set<int>.from((row["readEpisode"] as String)
            .split(',')
            .where((element) => element != "")
            .map((e) => int.parse(e))),
        maxPage = row["max_page"];

  List<String> candidateDownloadIds() =>
      _buildHistoryDownloadIdCandidates(target, type.value);

  /// Ensure a DB row exists for this reading session ([ComicReadingPage] uses [target] == [readingData.id]).
  static Future<History> ensureForLocalRead({
    required String target,
    required HistoryType type,
    required String title,
    required String subtitle,
    required String cover,
    Iterable<String> legacyTargets = const <String>[],
    int ep = 0,
    int page = 0,
  }) async {
    final manager = HistoryManager();
    final existing = manager.findSync(target);
    if (existing != null) {
      return existing;
    }
    for (final legacyTarget in legacyTargets) {
      if (legacyTarget == target) continue;
      final migrated = manager.migrateLegacyTarget(
        legacyTarget: legacyTarget,
        newTarget: target,
        type: type,
        title: title,
        subtitle: subtitle,
        cover: cover,
      );
      if (migrated != null) {
        return migrated;
      }
    }
    final h = History(
      type,
      DateTime.now(),
      title,
      subtitle,
      cover,
      ep,
      page,
      target,
    );
    await manager.addHistory(h);
    return manager.findSync(target)!;
  }
}

class HistoryManager {
  static HistoryManager? cache;

  HistoryManager.create();

  factory HistoryManager() =>
      cache == null ? (cache = HistoryManager.create()) : cache!;

  late Database _db;
  Database? _secondaryDb;
  late String _dbPath;

  int get length => count();

  /// Primary writable DB handle.
  Database get database => _db;

  /// Ordered DB handles used by the current source mode.
  List<Database> get databases => [
        _db,
        if (_secondaryDb != null) _secondaryDb!,
      ];

  Map<String, bool>? _cachedHistory;

  Future<void> init() async {
    final roots = await getManagedDataRoots();
    final primaryPath = managedDataFilePath(roots.first, 'history.db');
    File(primaryPath).parent.createSync(recursive: true);

    dispose();

    _dbPath = primaryPath;
    _db = sqlite3.open(_dbPath);
    _configureDatabase(_db);

    _secondaryDb = null;
    if (roots.length > 1) {
      final secondaryPath = managedDataFilePath(roots[1], 'history.db');
      final secondaryFile = File(secondaryPath);
      if (secondaryFile.existsSync()) {
        _secondaryDb = sqlite3.open(secondaryPath);
        _configureDatabase(_secondaryDb!);
      }
    }
    _cachedHistory = null;
  }

  void dispose() {
    try {
      _db.dispose();
    } catch (_) {}
    try {
      _secondaryDb?.dispose();
    } catch (_) {}
    _secondaryDb = null;
    _cachedHistory = null;
  }

  void _configureDatabase(Database db) {
    db.execute("""
      create table if not exists history  (
        target text primary key,
        title text,
        subtitle text,
        cover text,
        time int,
        type int,
        ep int,
        page int,
        readEpisode text,
        max_page int
      );
    """);

    final res = db.select("""
      PRAGMA table_info(history);
    """);
    if (res.every((row) => row["name"] != "max_page")) {
      db.execute("""
        alter table history
        add column max_page int;
      """);
    }

    db.execute("""
      CREATE TABLE IF NOT EXISTS image_favorites (
        id TEXT,
        title TEXT NOT NULL,
        cover TEXT NOT NULL,
        ep INTEGER NOT NULL,
        page INTEGER NOT NULL,
        other TEXT NOT NULL,
        PRIMARY KEY (id, ep, page)
      );
    """);
  }

  bool _existsInDb(Database db, String target) {
    final res = db.select(
      """
      select 1 from history
      where target == ?
      limit 1;
    """,
      [target],
    );
    return res.isNotEmpty;
  }

  History? _findInDb(Database db, String target) {
    final res = db.select(
      """
      select * from history
      where target == ?;
    """,
      [target],
    );
    if (res.isEmpty) {
      return null;
    }
    return History.fromRow(res.first);
  }

  Database? _findDbContainingTarget(String target) {
    for (final db in databases) {
      if (_existsInDb(db, target)) {
        return db;
      }
    }
    return null;
  }

  Future<void> addHistory(History newItem) async {
    final db = _findDbContainingTarget(newItem.target) ?? _db;
    final res = db.select(
      """
      select * from history
      where target == ?;
    """,
      [newItem.target],
    );
    if (res.isEmpty) {
      db.execute("""
        insert into history (target, title, subtitle, cover, time, type, ep, page, readEpisode, max_page)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """, [
        newItem.target,
        newItem.title,
        newItem.subtitle,
        newItem.cover,
        newItem.time.millisecondsSinceEpoch,
        newItem.type.value,
        newItem.ep,
        newItem.page,
        newItem.readEpisode.join(','),
        newItem.maxPage
      ]);
    } else {
      db.execute("""
        update history
        set time = ${DateTime.now().millisecondsSinceEpoch}
        where target == ?;
      """, [newItem.target]);
    }
    _cachedHistory = null;
  }

  History? migrateLegacyTarget({
    required String legacyTarget,
    required String newTarget,
    required HistoryType type,
    required String title,
    required String subtitle,
    required String cover,
  }) {
    if (legacyTarget == newTarget) {
      return findSync(newTarget);
    }
    final existing = findSync(newTarget);
    if (existing != null) {
      return existing;
    }
    for (final db in databases) {
      final legacy = _findInDb(db, legacyTarget);
      if (legacy == null) {
        continue;
      }
      final migrated = History(
        type,
        legacy.time,
        title,
        subtitle,
        cover.isNotEmpty ? cover : legacy.cover,
        legacy.ep,
        legacy.page,
        newTarget,
        legacy.readEpisode,
        legacy.maxPage,
      );
      db.execute("""
        insert or replace into history (target, title, subtitle, cover, time, type, ep, page, readEpisode, max_page)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """, [
        migrated.target,
        migrated.title,
        migrated.subtitle,
        migrated.cover,
        migrated.time.millisecondsSinceEpoch,
        migrated.type.value,
        migrated.ep,
        migrated.page,
        migrated.readEpisode.join(','),
        migrated.maxPage,
      ]);
      db.execute("""
        delete from history
        where target == ?;
      """, [legacyTarget]);
      _cachedHistory = null;
      return findSync(newTarget);
    }
    return null;
  }

  Future<void> saveReadHistory(History history,
      [bool updateMePage = true]) async {
    final db = _findDbContainingTarget(history.target) ?? _db;
    db.execute("""
      update history
      set time = ${DateTime.now().millisecondsSinceEpoch}, ep = ?, page = ?, readEpisode = ?, max_page = ?
      where target == ?;
    """, [
      history.ep,
      history.page,
      history.readEpisode.join(','),
      history.maxPage,
      history.target
    ]);
    _cachedHistory = null;
    if (updateMePage) {
      Future.microtask(() {
        StateController.findOrNull<SimpleController>(tag: "me_page")?.update();
      });
    }
  }

  void readDataFromJson(dynamic json) {
    if (json is List) {
      for (var h in json) {
        if (h is Map<String, dynamic>) {
          final item = History.fromMap(h);
          if (find(item.target) == null) {
            addHistory(item);
          }
        }
      }
    }
  }

  void clearHistory() {
    for (final db in databases) {
      db.execute("delete from history;");
    }
    _cachedHistory = null;
  }

  void remove(String id) {
    for (final db in databases) {
      db.execute("""
        delete from history
        where target == ?;
      """, [id]);
    }
    _cachedHistory = null;
  }

  History? findSync(String target) {
    return find(target);
  }

  History? find(String target) {
    _cachedHistory ??= {
      for (final item in getAll()) item.target: true,
    };
    if (!_cachedHistory!.containsKey(target)) {
      return null;
    }
    return _findInDb(_db, target) ??
        (_secondaryDb != null ? _findInDb(_secondaryDb!, target) : null);
  }

  List<History> getAll() {
    final merged = <String, History>{};
    for (final db in databases) {
      final res = db.select("""
        select * from history;
      """);
      for (final element in res) {
        final item = History.fromRow(element);
        final existing = merged[item.target];
        if (existing == null || item.time.isAfter(existing.time)) {
          merged[item.target] = item;
        }
      }
    }
    final items = merged.values.toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    return items;
  }

  List<History> getRecent() {
    final items = getAll();
    if (items.length <= 20) {
      return items;
    }
    return items.sublist(0, 20);
  }

  int count() {
    return getAll().length;
  }
}
