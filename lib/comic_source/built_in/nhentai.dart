import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/comic_source/favorite_data.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/nhentai_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/nhentai_login_page.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Nhentai 源定义
//
//  与 ehentai 同构（cookie 登录 / 单本无章节 / webview 抓 cookie），但 nhentai
//  搜索/收藏均为页码翻页（有总页数），无需 ehentai 的游标缓存器，直接传 page。
// ═══════════════════════════════════════════════════════════════════════════

/// 把 `Res<List<NhentaiComicBrief>>` 收敛成基类要求的 `Res<List<BaseComic>>`
/// （泛型不协变，必须显式重建）。subData（末页页码）原样透传给翻页判停协议。
Res<List<BaseComic>> _toBaseRes(Res<List<NhentaiComicBrief>> res) {
  if (res.error) return Res.fromErrorRes(res, subData: res.subData);
  return Res<List<BaseComic>>(
    List<BaseComic>.from(res.data),
    subData: res.subData,
  );
}

final ComicSource nhentai = ComicSource.named(
  key: 'nhentai',
  name: 'Nhentai',

  // ── 账号（cookie 登录，走 webview）─────────────────────────────────────────
  account: AccountConfig(
    // nhentai 无账密 API，login 仅占位，正常走 onLogin 跳登录页。
    login: (account, password) async =>
        const Res.error('Nhentai 使用网页登录，请点击"登录"按钮'),
    onLogin: (context) => context.to(() => const NhentaiLoginPage()),
    logout: () async {
      final source = ComicSource.require('nhentai');
      NhentaiNetwork().logout();
      source.data
        ..remove('token')
        ..remove('name');
      await source.saveData();
    },
    // nhentai 无 token 刷新：cookie 失效需手动重登（allowReLogin 未提供）。
    infoItems: () async {
      final source = ComicSource.require('nhentai');
      final name = source.data['name']?.toString() ?? '';
      return Res([
        if (name.isNotEmpty) AccountInfoItem(title: '账号', value: name),
      ]);
    },
  ),

  // ── 搜索（页码翻页，subData=末页页码，框架据此判停）────────────────────────
  searchPageData: SearchPageData(
    defaultOption: '',
    searchOptions: const [
      SearchOption(label: '最新', value: ''),
      SearchOption(label: '今日热门', value: '&sort=popular-today'),
      SearchOption(label: '本周热门', value: '&sort=popular-week'),
      SearchOption(label: '本月热门', value: '&sort=popular-month'),
      SearchOption(label: '全部热门', value: '&sort=popular'),
    ],
    loadPage: (keyword, page, option) async {
      final res = await NhentaiNetwork()
          .search(keyword, page, NhentaiSort.fromValue(option));
      return _toBaseRes(res);
    },
  ),

  // ── 收藏（单文件夹，页码翻页）──────────────────────────────────────────────
  favoriteData: FavoriteData(
    key: 'nhentai',
    title: 'Nhentai',
    multiFolder: false,
    loadComic: (page) async {
      final res = await NhentaiNetwork().getFavorites(page);
      return _toBaseRes(res);
    },
  ),

  // ── 详情页构造器 ───────────────────────────────────────────────────────────
  comicPageBuilder: (comic) => NhentaiComicPageV2(comic.id),

  // ── 封面鉴权（Referer 规避防盗链，解决搜索列表裂图）──────────────────────────
  imageHeadersBuilder: (comic) => const {'Referer': 'https://nhentai.net/'},
);
