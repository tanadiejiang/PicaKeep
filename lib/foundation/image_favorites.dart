import 'dart:convert';

import 'package:picakeep/foundation/history.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:picakeep/foundation/state_controller.dart';

/// Local image bookmark stored in [HistoryManager] SQLite (`image_favorites` table).
class ImageFavorite {
  final String id;
  final String imagePath;
  final String title;
  final int ep;
  final int page;
  final Map<String, dynamic> otherInfo;

  const ImageFavorite(
    this.id,
    this.imagePath,
    this.title,
    this.ep,
    this.page,
    this.otherInfo,
  );
}

class ImageFavoriteManager {
  static Database get _db => HistoryManager().database;
  static List<Database> get _dbs => HistoryManager().databases;

  static String _favoriteKey(String id, int ep, int page) => '$id::$ep::$page';

  static ImageFavorite _fromRow(Row row) {
    return ImageFavorite(
      row["id"] as String,
      row["cover"] as String,
      row["title"] as String,
      row["ep"] as int,
      row["page"] as int,
      jsonDecode(row["other"] as String) as Map<String, dynamic>,
    );
  }

  static void _notifyUpdated() {
    Future.microtask(() {
      StateController.findOrNull<SimpleController>(tag: "me_page")?.update();
      StateController.findOrNull<SimpleController>(tag: "image_favorites_page")
          ?.update();
    });
  }

  static void add(ImageFavorite favorite) {
    _db.execute(
      """
      insert into image_favorites(id, title, cover, ep, page, other)
      values(?, ?, ?, ?, ?, ?);
    """,
      [
        favorite.id,
        favorite.title,
        favorite.imagePath,
        favorite.ep,
        favorite.page,
        jsonEncode(favorite.otherInfo),
      ],
    );
    _notifyUpdated();
  }

  static List<ImageFavorite> getAll() {
    final merged = <String, ImageFavorite>{};
    for (final db in _dbs) {
      final res = db.select("select * from image_favorites;");
      for (final row in res) {
        final item = _fromRow(row);
        merged.putIfAbsent(
          _favoriteKey(item.id, item.ep, item.page),
          () => item,
        );
      }
    }
    return merged.values.toList();
  }

  static void delete(ImageFavorite favorite) {
    for (final db in _dbs) {
      db.execute(
        """
        delete from image_favorites
        where id = ? and ep = ? and page = ?;
      """,
        [favorite.id, favorite.ep, favorite.page],
      );
    }
    _notifyUpdated();
  }

  static bool exist(String id, int ep, int page) {
    for (final db in _dbs) {
      final res = db.select(
        """
        select 1 from image_favorites
        where id = ? and ep = ? and page = ?
        limit 1;
      """,
        [id, ep, page],
      );
      if (res.isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  static int get length => getAll().length;

  static ImageFavorite fromHitomiFile(
    String id,
    String name,
    String author,
    String type,
    String coverPath,
    String hash,
  ) {
    return ImageFavorite(
      id,
      coverPath,
      name,
      0,
      0,
      {'author': author, 'type': type, 'hash': hash},
    );
  }
}
