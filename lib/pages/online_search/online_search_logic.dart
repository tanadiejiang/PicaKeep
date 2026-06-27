import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/res.dart';

class OnlineSearchLogic {
  OnlineSearchLogic();

  List<ComicSource> get searchableSources => ComicSource.sources
      .where((source) => source.searchPageData != null)
      .toList();

  List<ComicSource> get loggedInSearchableSources => ComicSource.sources
      .where((source) => source.searchPageData != null && source.isLoggedIn)
      .toList();

  List<String> get searchHistory => appdata.searchHistory.reversed.toList();

  void addSearchHistory(String keyword) {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      return;
    }
    appdata.searchHistory.remove(trimmed);
    appdata.searchHistory.add(trimmed);
    if (appdata.searchHistory.length > 40) {
      appdata.searchHistory.removeRange(0, appdata.searchHistory.length - 40);
    }
    appdata.writeHistory();
  }

  void clearSearchHistory() {
    appdata.searchHistory.clear();
    appdata.writeHistory();
  }

  Future<Res<List<BaseComic>>> search({
    required ComicSource source,
    required String keyword,
    required int page,
    required String option,
  }) {
    final data = source.searchPageData;
    if (data == null) {
      return Future.value(const Res.error('该在线源不支持搜索'));
    }
    if (!source.isLoggedIn) {
      return Future.value(const Res.error('请先登录该在线源'));
    }
    return data.loadPage(keyword, page, option);
  }
}
