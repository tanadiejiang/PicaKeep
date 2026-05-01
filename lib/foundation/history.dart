// ignore_for_file: no_leading_underscores_for_local_identifiers

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import '../foundation/state_controller.dart';

final class HistoryType {
  static HistoryType get picacg => const HistoryType(0);
  static HistoryType get ehentai => const HistoryType(1);
  static HistoryType get jmComic => const HistoryType(2);
  static HistoryType get hitomi => const HistoryType(3);
  static HistoryType get htmanga => const HistoryType(4);
  static HistoryType get nhentai => const HistoryType(6);

  final int value;

  String get name {
    const nameMap = {
      0: "picacg",
      1: "ehentai",
      2: "jm",
      3: "hitomi",
      4: "htmanga",
      6: "nhentai",
    };
    return nameMap[value] ?? "Unknown";
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
}

class HistoryManager {
  static HistoryManager? cache;

  HistoryManager.create();

  factory HistoryManager() =>
      cache == null ? (cache = HistoryManager.create()) : cache!;

  late Database _db;
  late String _dbPath;

  int get length => _db.select("select count(*) from history;").first[0] as int;

  Map<String, bool>? _cachedHistory;

  Future<void> init() async {
    final appDir = await getApplicationSupportDirectory();
    _dbPath = "${appDir.path}/history.db";
    _db = sqlite3.open(_dbPath);

    _db.execute("""
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

    var res = _db.select("""
      PRAGMA table_info(history);
    """);
    if (res.every((row) => row["name"] != "max_page")) {
      _db.execute("""
        alter table history
        add column max_page int;
      """);
    }
  }

  Future<void> addHistory(History newItem) async {
    var res = _db.select("""
      select * from history
      where target == ?;
    """, [newItem.target]);
    if (res.isEmpty) {
      _db.execute("""
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
      _db.execute("""
        update history
        set time = ${DateTime.now().millisecondsSinceEpoch}
        where target == ?;
      """, [newItem.target]);
    }
    _cachedHistory = null;
  }

  Future<void> saveReadHistory(History history,
      [bool updateMePage = true]) async {
    _db.execute("""
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
    if (updateMePage) {
      Future.microtask(() {
        StateController.findOrNull(tag: "me_page")?.update();
      });
    }
  }

  void readDataFromJson(dynamic json) {
    if (json is List) {
      for (var h in json) {
        if (h is Map<String, dynamic>) {
          var item = History.fromMap(h);
          if (find(item.target) == null) {
            addHistory(item);
          }
        }
      }
    }
  }

  void clearHistory() {
    _db.execute("delete from history;");
    _cachedHistory = null;
  }

  void remove(String id) {
    _db.execute("""
      delete from history
      where target == ?;
    """, [id]);
    _cachedHistory = null;
  }

  History? findSync(String target) {
    return find(target);
  }

  History? find(String target) {
    if (_cachedHistory == null) {
      _cachedHistory = {};
      var res = _db.select("select * from history;");
      for (var element in res) {
        _cachedHistory![element["target"] as String] = true;
      }
    }
    if (!_cachedHistory!.containsKey(target)) {
      return null;
    }

    var res = _db.select("""
      select * from history
      where target == ?;
    """, [target]);
    if (res.isEmpty) {
      return null;
    }
    return History.fromRow(res.first);
  }

  List<History> getAll() {
    var res = _db.select("""
      select * from history
      order by time DESC;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  List<History> getRecent() {
    var res = _db.select("""
      select * from history
      order by time DESC
      limit 20;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  int count() {
    var res = _db.select("""
      select count(*) from history;
    """);
    return res.first[0] as int;
  }
}
