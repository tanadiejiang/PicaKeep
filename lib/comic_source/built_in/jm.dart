import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/comic_source/favorite_data.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/jm_comic_detail_page.dart';

final _jmNet = JmNetwork();

final ComicSource jm = ComicSource.named(
  key: 'jm',
  name: '禁漫',
  account: AccountConfig(
    login: (account, password) async {
      final source = ComicSource.require('jm');
      await _jmNet.selectDomain();
      final res = await _jmNet.login(account, password);
      if (res.error) return Res.fromErrorRes(res);
      source.data['account'] = <String>[account, password];
      source.data['token'] = 'logged_in';
      source.data['name'] = _jmNet.lastLoginName;
      source.data['uid'] = _jmNet.lastLoginUid;
      await source.saveData();
      return const Res(true);
    },
    logout: () async {
      final source = ComicSource.require('jm');
      await _jmNet.logout();
      source.data
        ..remove('token')
        ..remove('account');
      await source.saveData();
    },
    reLogin: () async {
      final res = await _jmNet.reLoginFromStored();
      return res;
    },
    infoItems: () async {
      final source = ComicSource.require('jm');
      final name = source.data['name']?.toString() ?? '';
      final uid = source.data['uid']?.toString() ?? '';
      return Res([
        if (name.isNotEmpty) AccountInfoItem(title: '用户名', value: name),
        if (uid.isNotEmpty) AccountInfoItem(title: 'UID', value: uid),
      ]);
    },
  ),
  favoriteData: FavoriteData(
    key: 'jm',
    title: '禁漫',
    multiFolder: false,
    loadComic: (page) async {
      final res = await _jmNet.getFavorites(page);
      if (res.error) return Res.fromErrorRes(res);
      return Res<List<BaseComic>>(res.data, subData: res.subData);
    },
    addOrDelFavorite: (comic) async {
      // 获取当前收藏状态需要知道是否已收藏，这里简单切换
      return _jmNet.setFavorite(comic.id, add: true);
    },
  ),
  searchPageData: SearchPageData(
    defaultOption: 'mr',
    searchOptions: const [
      SearchOption(label: '最新', value: 'mr'),
      SearchOption(label: '最多观看', value: 'mv'),
      SearchOption(label: '最多喜欢', value: 'tf'),
      SearchOption(label: '本周最多', value: 'mv_w'),
      SearchOption(label: '本月最多', value: 'mv_m'),
    ],
    loadPage: (keyword, page, option) async {
      final res = await _jmNet.search(keyword, option, page);
      if (res.error) return Res.fromErrorRes(res);
      return Res<List<BaseComic>>(res.data, subData: res.subData);
    },
  ),
  comicPageBuilder: (comic) => JmComicDetailPage(comic: comic),
);
