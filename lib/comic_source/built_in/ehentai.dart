import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/comic_source/favorite_data.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/eh_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/eh_login_page.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  搜索分页游标缓存器
//
//  移植自上游 PicaComic 的 _EhentaiGalleriesLoader。
//  ehentai 翻页靠 next 游标而非页码，无总页数。本缓存器把游标细节藏在内部，
//  对外暴露标准的 int page 接口，配合 PicaKeep 的 subData 判停协议：
//    - nextPage == null（到末页）→ subData = cache.length（令框架停止上拉）
//    - nextPage != null            → 不传 subData（框架认为还有更多页）
// ═══════════════════════════════════════════════════════════════════════════

class _EhGalleryLoader {
  _EhGalleryLoader({required this.firstPageLoader});

  /// 首页加载闭包（由搜索或收藏页构造时注入）
  final Future<Res<Galleries>> Function() firstPageLoader;

  /// ehentai 服务器返回的下一页游标；null 表示到末页
  String? nextPage;

  /// 已加载的分页缓存，cache[i] 对应第 i+1 页
  final List<List<EhGalleryBrief>> _cache = [];

  /// 对外入口：page 从 1 开始
  Future<Res<List<BaseComic>>> call(int page) async {
    // page==1 或缓存为空 → 重置并重新加载首页
    if (page == 1 || _cache.isEmpty) {
      final res = await _firstRequest();
      if (res.error) return Res.fromErrorRes(res);
    }
    final idx = page - 1;
    // 按需续翻直到缓存有目标页
    while (idx >= _cache.length) {
      if (nextPage == null) break; // 末页，不能再往后翻
      final res = await _loadNext();
      if (res.error) return Res.fromErrorRes(res);
    }
    if (idx >= _cache.length) {
      return const Res.error('页数超出范围');
    }
    if (nextPage == null) {
      // 到达末页：subData = 当前缓存总页数，框架据此停止上拉
      return Res<List<BaseComic>>(_cache[idx], subData: _cache.length);
    }
    return Res<List<BaseComic>>(_cache[idx]);
  }

  Future<Res<void>> _firstRequest() async {
    _cache.clear();
    nextPage = null;
    final res = await firstPageLoader();
    if (res.error) return Res.fromErrorRes(res);
    _cache.add(res.data.galleries);
    nextPage = res.data.next;
    return const Res(null);
  }

  Future<Res<void>> _loadNext() async {
    final url = nextPage;
    if (url == null) return const Res(null);
    final res = await EhNetwork().getGalleries(url);
    if (res.error) return Res.fromErrorRes(res);
    _cache.add(res.data.galleries);
    nextPage = res.data.next;
    return const Res(null);
  }
}

// 当前搜索 loader（新关键词/选项时重建）
_EhGalleryLoader? _searchLoader;
String? _lastSearchKey; // "keyword|option" 指纹，变化时重建 loader

// 收藏夹 loader
_EhGalleryLoader? _favLoader;

// ═══════════════════════════════════════════════════════════════════════════
//  E-Hentai 源定义（08 计划在 04 空壳上扩充）
// ═══════════════════════════════════════════════════════════════════════════

final ComicSource ehentai = ComicSource.named(
  key: 'ehentai',
  name: 'E-Hentai',

  // ── 账号（04 计划已实现，08 补 reLogin）─────────────────────────────────
  account: AccountConfig(
    // E-Hentai 无账密登录 API，login 仅占位，正常走 onLogin 跳登录页。
    login: (account, password) async =>
        const Res.error('E-Hentai 使用 Cookie 登录，请点击"登录"按钮'),
    onLogin: (context) => context.to(() => const EhLoginPage()),
    logout: () async {
      final source = ComicSource.require('ehentai');
      // 清两域全部 cookie（含 ipb_member_id / ipb_pass_hash / igneous）
      EhNetwork().cookieJar.deleteUri(Uri.parse('https://e-hentai.org'));
      EhNetwork().cookieJar.deleteUri(Uri.parse('https://exhentai.org'));
      EhNetwork().cookiesStr = '';
      source.data
        ..remove('token')
        ..remove('name');
      await source.saveData();
    },
    // ehentai 无 token 刷新：恢复持久 cookie + validateCookies 校验
    reLogin: () async {
      await EhNetwork().getCookies(true);
      final ok = await EhNetwork().validateCookies();
      if (!ok) return const Res.error('Cookie 已失效，请重新登录');
      return const Res(true);
    },
    infoItems: () async {
      final source = ComicSource.require('ehentai');
      final name = source.data['name']?.toString() ?? '';
      // 先刷新一次 cookie，回填 EhNetwork 的 id/hash/igneous 字段。
      await EhNetwork().getCookies(true);
      final net = EhNetwork();
      return Res([
        if (name.isNotEmpty) AccountInfoItem(title: '用户名', value: name),
        if (net.id.isNotEmpty)
          AccountInfoItem(title: 'ipb_member_id', value: net.id),
        if (net.hash.isNotEmpty)
          AccountInfoItem(title: 'ipb_pass_hash', value: net.hash),
        if (net.igneous.isNotEmpty)
          AccountInfoItem(title: 'igneous', value: net.igneous),
      ]);
    },
  ),

  // ── 搜索 ─────────────────────────────────────────────────────────────────
  searchPageData: SearchPageData(
    defaultOption: '',
    enableTagsSuggestions: true,
    searchOptions: const [
      SearchOption(label: '全部', value: ''),
      SearchOption(label: '同人', value: 'doujinshi'),
      SearchOption(label: '漫画', value: 'manga'),
      SearchOption(label: '3星以上', value: 'stars3'),
      SearchOption(label: '4星以上', value: 'stars4'),
    ],
    loadPage: (keyword, page, option) async {
      final searchKey = '$keyword|$option';
      // 关键词或选项变化时重建 loader（重置游标）
      if (page == 1 || _lastSearchKey != searchKey) {
        _lastSearchKey = searchKey;
        // 解析 option → ehentai 过滤参数
        int? fCats;
        int? minStars;
        switch (option) {
          case 'doujinshi':
            // f_cats 反码：排除除 Doujinshi(2) 外所有分类
            fCats = 1021;
          case 'manga':
            // 排除除 Manga(4) 外所有分类
            fCats = 1019;
          case 'stars3':
            minStars = 3;
          case 'stars4':
            minStars = 4;
        }
        _searchLoader = _EhGalleryLoader(
          firstPageLoader: () => EhNetwork().search(
            keyword,
            fCats: fCats,
            minStars: minStars,
          ),
        );
      }
      final loader = _searchLoader;
      if (loader == null) return const Res.error('搜索状态异常');
      return loader(page);
    },
  ),

  // ── 收藏 ─────────────────────────────────────────────────────────────────
  favoriteData: FavoriteData(
    key: 'ehentai',
    title: 'E-Hentai',
    multiFolder: true,
    loadComic: (page, [folderId]) async {
      if (page == 1 || _favLoader == null) {
        _favLoader = _EhGalleryLoader(
          firstPageLoader: () {
            final catParam = (folderId == null || folderId == '-1')
                ? ''
                : '?favcat=$folderId';
            return EhNetwork().getGalleries(
              '${EhNetwork().ehBaseUrl}/favorites.php$catParam',
              favoritePage: true,
            );
          },
        );
      }
      return _favLoader!(page);
    },
    loadFolders: () async {
      final res = await EhNetwork().getGalleries(
        '${EhNetwork().ehBaseUrl}/favorites.php',
        favoritePage: true,
      );
      if (res.error) return Res.fromErrorRes(res);
      final names = EhNetwork().folderNames;
      final map = <String, String>{'-1': '全部'};
      for (int i = 0; i < names.length; i++) {
        map[i.toString()] = names[i];
      }
      return Res(map);
    },
    addOrDelFavorite: (comic, isAdding) async {
      if (isAdding) {
        final link = comic.id;
        final m = RegExp(r'/g/(\d+)/([0-9a-f]+)').firstMatch(link);
        if (m == null) return const Res.error('无法解析 gid/token');
        final ok = await EhNetwork().favorite(m.group(1)!, m.group(2)!);
        return ok ? const Res(true) : const Res.error('收藏失败');
      } else {
        final link = comic.id;
        final m = RegExp(r'/g/(\d+)/').firstMatch(link);
        if (m == null) return const Res.error('无法解析 gid');
        final ok = await EhNetwork().unfavorite2(m.group(1)!);
        return ok ? const Res(true) : const Res.error('取消收藏失败');
      }
    },
  ),

  // ── 详情页构造器（接 06 计划的 EhentaiComicPageV2）────────────────────────
  comicPageBuilder: (comic) => EhentaiComicPageV2(comic.id),

  // ── 封面鉴权三件套 Header 钩子（解决搜索列表裂图，接 03 计划的钩子入口）──────
  // online_search_result_page.dart 的 _coverProvider 会调用此钩子；
  // 返回非空 headers → 走 StreamImageProvider（OnlineImageManager），不再裂图。
  imageHeadersBuilder: (comic) => {
    'Cookie': EhNetwork().cookiesStr,
    'User-Agent': EhNetwork.ehUA,
    'Referer': EhNetwork().ehBaseUrl,
  },
);
