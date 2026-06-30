import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/comic_source/favorite_data.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/picacg_comic_page_v2.dart';

final PicacgNetwork picacgNetwork = PicacgNetwork();

final ComicSource picacg = ComicSource.named(
  key: 'picacg',
  name: 'Picacg',
  favoriteData: FavoriteData(
    key: 'picacg',
    title: 'Picacg',
    multiFolder: false,
    loadComic: (page) async => picacgNetwork.getFavorites(page),
    addOrDelFavorite: (comic) async {
      return picacgNetwork.favouriteOrUnfavouriteComic(comic.id);
    },
  ),
  account: AccountConfig(
    login: (account, password) async {
      final source = ComicSource.require('picacg');
      final loginRes = await picacgNetwork.login(account, password);
      if (loginRes.error) {
        return Res.fromErrorRes(loginRes);
      }
      source.data['token'] = loginRes.data;
      final profileRes = await picacgNetwork.getProfile();
      if (profileRes.error) {
        source.data.remove('token');
        return Res.fromErrorRes(profileRes);
      }
      picacgNetwork.user = profileRes.data;
      source.data['user'] = profileRes.data.toJson();
      source.data['account'] = <String>[account, password];
      await source.saveData();
      return const Res(true);
    },
    logout: () async {
      final source = ComicSource.require('picacg');
      source.data
        ..remove('token')
        ..remove('user');
      picacgNetwork.user = null;
      await source.saveData();
    },
    reLogin: () => picacgNetwork.loginFromStoredCredentials(),
    infoItems: () async {
      if (picacgNetwork.user == null) {
        final profile = await picacgNetwork.getProfile();
        if (profile.error) {
          return Res.fromErrorRes(profile);
        }
        picacgNetwork.user = profile.data;
      }
      final user = picacgNetwork.user;
      if (user == null) {
        return const Res(<AccountInfoItem>[]);
      }
      return Res([
        AccountInfoItem(title: '账号', value: user.email),
        AccountInfoItem(title: '用户名', value: user.name),
        AccountInfoItem(
          title: '等级',
          value: 'Lv${user.level} ${user.title} Exp${user.exp}',
        ),
        AccountInfoItem(title: '简介', value: user.slogan ?? ''),
      ]);
    },
  ),
  searchPageData: SearchPageData(
    defaultOption: 'dd',
    searchOptions: const [
      SearchOption(label: '新到旧', value: 'dd'),
      SearchOption(label: '旧到新', value: 'da'),
      SearchOption(label: '最多喜欢', value: 'ld'),
      SearchOption(label: '最多指名', value: 'vd'),
    ],
    loadPage: (keyword, page, option) async {
      final res = await picacgNetwork.search(keyword, option, page);
      if (res.error) {
        return Res.fromErrorRes(res);
      }
      return Res<List<BaseComic>>(res.data, subData: res.subData);
    },
  ),
  comicPageBuilder: (comic) => PicacgComicPageV2(comic.id),
  data: <String, dynamic>{
    'appChannel': '3',
    'imageQuality': 'original',
  },
);
