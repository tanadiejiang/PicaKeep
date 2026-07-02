import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/res.dart';

typedef NetworkFavoriteLoader = Future<Res<List<BaseComic>>> Function(
  int page, [String? folder]);

typedef NetworkFavoriteAction = Future<Res<bool>> Function(
    BaseComic comic, bool isAdding);

class FavoriteData {
  const FavoriteData({
    required this.key,
    required this.title,
    required this.loadComic,
    this.multiFolder = false,
    this.loadFolders,
    this.deleteFolder,
    this.addFolder,
    this.allFavoritesId,
    this.addOrDelFavorite,
  });

  final String key;
  final String title;
  final bool multiFolder;
  final NetworkFavoriteLoader loadComic;
  final Future<Res<Map<String, String>>> Function()? loadFolders;
  final Future<Res<bool>> Function(String folder)? deleteFolder;
  final Future<Res<bool>> Function(String folder)? addFolder;
  final String? allFavoritesId;
  final NetworkFavoriteAction? addOrDelFavorite;
}

FavoriteData? getFavoriteDataOrNull(String key, Iterable<FavoriteData> data) {
  for (final item in data) {
    if (item.key == key) {
      return item;
    }
  }
  return null;
}

FavoriteData getFavoriteData(String key, Iterable<FavoriteData> data) {
  final result = getFavoriteDataOrNull(key, data);
  if (result == null) {
    throw StateError('FavoriteData not found: $key');
  }
  return result;
}
