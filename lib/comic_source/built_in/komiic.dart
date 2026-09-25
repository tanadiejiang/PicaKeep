import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/comic_source/favorite_data.dart';
import 'package:picakeep/foundation/def.dart' show webUA;
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/komiic_network/komiic_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/komiic_comic_page_v2.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Komiic 源定义（第十八轮新增）
//
//  路线：内置 Dart 源（**不是** JS 插件源）。
//
//  为什么不做插件源：PicaKeep 的 JS 插件源引擎是半成品 —— `assets/init.js`
//  存在（与原项目 SHA256 相同）但未注册进 pubspec，`flutter_qjs` 依赖、
//  `js_engine.dart`、`parser.dart` 全部不存在，`_loadCustomSources()` 是空实现。
//  打通插件引擎是独立工程（收益是全生态 33+ 个源），应另立计划，不应与
//  Komiic 接入捆绑。详见 02 号调研 §五的双路线对比。
//
//  ── sourceKey 大小写约定（重要）─────────────────────────────────────────────
//  本项目既有代码把 Komiic 的**下载/历史/收藏**来源标识记作大写 `'Komiic'`
//  （download_model.dart / history.dart / local_favorites.dart /
//  local_library_static.dart），而本文件注册的 `ComicSource.key` 用小写
//  `'komiic'`（与既有四源 picacg/jm/ehentai/nhentai 全小写的命名习惯一致，
//  也决定 comic_source/komiic.data 的文件名）。
//  两者由各自的分支负责映射：下载侧 `_sourceKeyForDownloadType` 返回
//  `'Komiic'`，阅读器侧 `KomiicReadingData.sourceKey` 用 `'Komiic'`，
//  而网络层通过 `ComicSource.find('komiic')` 取配置与 token。
//  **改动任一处都必须四处同步**，否则"已下载"状态与本地收藏会静默命不中。
// ═══════════════════════════════════════════════════════════════════════════

/// 把 Komiic 的 brief 列表收敛成基类要求的 `Res<List<BaseComic>>`。
Res<List<BaseComic>> _toBaseRes(Res<List<KomiicComicBrief>> res) {
  if (res.error) return Res.fromErrorRes(res, subData: res.subData);
  return Res<List<BaseComic>>(
    List<BaseComic>.from(res.data),
    subData: res.subData,
  );
}

final ComicSource komiic = ComicSource.named(
  key: 'komiic',
  name: 'Komiic',

  // ── 账号（邮箱 + 密码换 Bearer token，与 JM/Picacg 的账密模式一致）──────────
  account: AccountConfig(
    registerWebsite: 'https://komiic.com/register',
    login: (account, password) async {
      final source = ComicSource.require('komiic');
      final res = await KomiicNetwork().login(account, password);
      if (res.error) return Res.fromErrorRes(res);
      source.data['token'] = res.data;
      // 凭据留作 token 过期后的自动重登（网络层 reLoginFromStored 会读它）。
      source.data['account'] = <String>[account, password];
      source.data['name'] = account;
      await source.saveData();
      return const Res(true);
    },
    logout: () async {
      final source = ComicSource.require('komiic');
      // Komiic 无服务端登出接口，token 是纯 Bearer；清本地即可。
      source.data
        ..remove('token')
        ..remove('account')
        ..remove('name');
      await source.saveData();
    },
    reLogin: () async {
      final res = await KomiicNetwork().reLoginFromStored();
      return res.error ? Res.fromErrorRes(res) : const Res(true);
    },
    infoItems: () async {
      final source = ComicSource.require('komiic');
      final name = source.data['name']?.toString() ?? '';
      if (name.isEmpty) {
        return const Res(<AccountInfoItem>[]);
      }
      return Res([AccountInfoItem(title: '账号', value: name)]);
    },
  ),

  // ── 搜索（**该接口不支持分页**，只返回第一页）──────────────────────────────
  // Komiic 的 searchComicsAndAuthors operation 不接受 pagination 变量，
  // 两个独立参考实现（Venera 官方源 / Aidoku 源）都因此返回 maxPage: 1。
  // 这里 page > 1 时直接返回空列表并令框架停止上拉，避免无限加载。
  searchPageData: SearchPageData(
    defaultOption: '',
    // Komiic 搜索 operation 无 optionList（Venera 源里声明为空数组），
    // 故本源不提供排序选项。
    searchOptions: const [],
    loadPage: (keyword, page, option) async {
      if (page > 1) {
        // 用 subData 告知框架"已到末页"，框架据此停止上拉。
        return const Res<List<BaseComic>>(<BaseComic>[], subData: 1);
      }
      final res = await KomiicNetwork().search(keyword);
      if (res.error) return Res.fromErrorRes(res);
      return Res<List<BaseComic>>(
        List<BaseComic>.from(res.data),
        subData: 1,
      );
    },
  ),

  // ── 收藏（多收藏夹）────────────────────────────────────────────────────────
  favoriteData: FavoriteData(
    key: 'komiic',
    title: 'Komiic',
    multiFolder: true,
    allFavoritesId: '',
    loadComic: (page, [folder]) async {
      final folderId = folder ?? '';
      if (folderId.isEmpty) {
        // 无夹 id 时不猜默认夹：Komiic 的收藏必须指定 folderId，
        // 走 recentUpdate 会得到"看起来像收藏"的错误内容。
        return const Res<List<BaseComic>>(<BaseComic>[]);
      }
      final res = await KomiicNetwork().getFolderComicsPage(folderId, page);
      return _toBaseRes(res);
    },
    loadFolders: () async {
      final res = await KomiicNetwork().getFolders();
      if (res.error) return Res.fromErrorRes(res);
      final map = <String, String>{};
      for (final folder in res.data) {
        map[folder.id] = folder.name;
      }
      return Res(map);
    },
    // 注意：`NetworkFavoriteAction` 的签名只有 `(comic, isAdding)` 两参
    // （见 favorite_data.dart:7），**多夹选择不在这里做**。Komiic 是
    // multiFolder 源且没有「默认夹」，无法从一个 (comic, isAdding) 调用里
    // 推断用户想写进哪个夹，因此本回调不猜夹、直接明确失败；
    // 真正的加减夹由详情页 showPlatformFavoritePanel 承担
    // （见 komiic_comic_page_v2.dart 的 onFavorite）。
    addOrDelFavorite: (comic, isAdding) async {
      return const Res.error('Komiic 为多收藏夹源，请在详情页选择收藏夹');
    },
    loadComicInfo: (target) async {
      final res = await KomiicNetwork().getComicInfo(target);
      if (res.error) return Res.fromErrorRes(res);
      final info = res.data;
      final authors = info.authors.join(', ').trim();
      return Res(FavoriteInfoPatch(
        name: info.title,
        author: authors.isEmpty ? null : authors,
        // 列表口径的标签就是 categories（与卡片显示同源）。
        tags: info.tags.isEmpty ? null : List<String>.from(info.tags),
        coverPath: info.coverUrl,
      ));
    },
  ),

  // ── 详情页构造器 ───────────────────────────────────────────────────────────
  comicPageBuilder: (comic) => KomiicComicPageV2(comic.id),

  // ── 封面请求头 ────────────────────────────────────────────────────────────
  // Komiic 图片端点 /api/image/{kid} 会被防盗链拦截，必须带 Referer。
  // 列表封面用站点根 Referer；章节内图片的 Referer 需要带具体
  // comic/chapter 路径，那一处由 KomiicReadingData.loadImageNetwork 提供。
  imageHeadersBuilder: (comic) => const {
    'Referer': 'https://komiic.com/',
    'User-Agent': webUA,
  },

  // ── ID 直跳（纯数字 / komiic前缀）─────────────────────────────────────────
  idMatcher: RegExp(r'^(?:komiic)?\d+$', caseSensitive: false),
);
