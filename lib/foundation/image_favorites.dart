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
    Future.microtask(
        () => StateController.findOrNull<SimpleController>(tag: "me_page")?.update());
  }

  static List<ImageFavorite> getAll() {
    final res = _db.select("select * from image_favorites;");
    return res
        .map(
          (e) => ImageFavorite(
            e["id"] as String,
            e["cover"] as String,
            e["title"] as String,
            e["ep"] as int,
            e["page"] as int,
            jsonDecode(e["other"] as String) as Map<String, dynamic>,
          ),
        )
        .toList();
  }

  static void delete(ImageFavorite favorite) {
    _db.execute(
      """
      delete from image_favorites
      where id = ? and ep = ? and page = ?;
    """,
      [favorite.id, favorite.ep, favorite.page],
    );
    Future.microtask(
        () => StateController.findOrNull<SimpleController>(tag: "me_page")?.update());
  }

  static bool exist(String id, int ep, int page) {
    final res = _db.select(
      """
      select * from image_favorites
      where id = ? and ep = ? and page = ?;
    """,
      [id, ep, page],
    );
    return res.isNotEmpty;
  }

  static int get length {
    final res = _db.select("select count(*) from image_favorites;");
    return res.first.values.first! as int;
  }

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
