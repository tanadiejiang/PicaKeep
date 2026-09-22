import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/res.dart';

typedef NetworkFavoriteLoader = Future<Res<List<BaseComic>>> Function(int page,
    [String? folder]);

typedef NetworkFavoriteAction = Future<Res<bool>> Function(
    BaseComic comic, bool isAdding);

/// 按来源 id 拉取"用于回写本地收藏记录"的元数据。
///
/// [target] 是该源在本地收藏库里的原始标识（形态因源而异：jm/nh/picacg 是纯
/// id，ehentai 通常是完整画廊链接）。实现方负责校验形态，校验不过时返回
/// `Res.error` 并由调用方归类为"链接/ID 不可用"。
typedef NetworkComicInfoLoader = Future<Res<FavoriteInfoPatch>> Function(
    String target);

/// 一次"更新卡片信息"能拿到的字段集合。
///
/// 每个字段都可空，**null 表示该源本次没有提供这个字段**，调用方必须保留本地
/// 原值 —— 不要用空串或空列表表达"没有"，否则会把用户已有的信息擦掉。
class FavoriteInfoPatch {
  const FavoriteInfoPatch({
    this.name,
    this.author,
    this.tags,
    this.coverPath,
  });

  /// 作品名。
  final String? name;

  /// 作者（各源口径由实现方决定，例如 EH 取 artist 桶、NH 取 Artists 桶）。
  final String? author;

  /// **列表口径**的分类标签；拿不到就留 null（不要塞详情全量标签）。
  ///
  /// 口径依据：本地收藏条目既可能来自"网络收藏转存"，也可能来自下载，两端要
  /// 收敛成同一种卡片形态。详情接口的全量标签可达数十条，会填满卡片并稀释
  /// 搜索命中（`FavoriteItem.tags` 被搜索、导出、AI 查询等 40+ 处消费）。
  final List<String>? tags;

  /// 封面本地路径或 URL。
  final String? coverPath;

  /// 是否有任何可写字段。
  bool get isEmpty =>
      (name == null || name!.trim().isEmpty) &&
      (author == null || author!.trim().isEmpty) &&
      (tags == null || tags!.isEmpty) &&
      (coverPath == null || coverPath!.trim().isEmpty);
}

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
    this.loadComicInfo,
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

  /// 可选：按 id 拉取用于回写本地收藏记录的元数据。
  ///
  /// 为 null 表示该源没有这项能力（例如无网络层的 hitomi / htmanga 等），
  /// 「更新卡片信息」会把该源条目计入"该来源暂不支持更新"，不影响其它条目。
  final NetworkComicInfoLoader? loadComicInfo;
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
