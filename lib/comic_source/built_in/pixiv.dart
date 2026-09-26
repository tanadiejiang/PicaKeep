import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/comic_source/favorite_data.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/favorite_source_id.dart' as source_id_rules;
import 'package:picakeep/foundation/widget_utils.dart' show ContextExt;
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/pixiv_author_page_v2.dart';
import 'package:picakeep/pages/online_comic/pixiv_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/pixiv_login_page.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Pixiv 源定义（第十八轮新增）
//
//  路线：Web Ajax API（www.pixiv.net/ajax/*）+ WebView 抓 PHPSESSID。
//
//  为什么不走 App API：App API（app-api.pixiv.net）需要 OAuth refresh_token，
//  形态上要在客户端内置写死的 client_id/client_secret/hash_secret，既与
//  「WebView 抓 Cookie」的产品决策冲突，也无法复用项目已有的
//  account_webview_login 登录状态机。详见 01 号调研 §二。
//
//  与 EH/NH 同构点：cookie 登录、单本无章节（hasEp=false）、图片需 Referer。
//  差异点：Pixiv 有 illust/manga 两类 + Ugoira 动图（首版降级为静态帧）。
// ═══════════════════════════════════════════════════════════════════════════

/// 把 `Res<List<PixivComicBrief>>` 收敛成基类要求的 `Res<List<BaseComic>>`
/// （泛型不协变，必须显式重建）。subData（末页页码）原样透传。
Res<List<BaseComic>> _toBaseRes(Res<List<PixivComicBrief>> res) {
  if (res.error) return Res.fromErrorRes(res, subData: res.subData);
  return Res<List<BaseComic>>(
    List<BaseComic>.from(res.data),
    subData: res.subData,
  );
}

final ComicSource pixiv = ComicSource.named(
  key: 'pixiv',
  name: 'Pixiv',

  // ── 账号（WebView 抓 PHPSESSID，与 EH/NH 同构）────────────────────────────
  account: AccountConfig(
    // Pixiv 无账密 API：表单登录被 Google reCAPTCHA 拦截（两份独立资料确认），
    // 因此 login 仅作占位，正常走 onLogin 跳 WebView 登录页。
    login: (account, password) async =>
        const Res.error('Pixiv 使用网页登录，请点击"登录"按钮'),
    onLogin: (context) => context.to(() => const PixivLoginPage()),
    logout: () async {
      final source = ComicSource.require('pixiv');
      // 先 await Cookie 清理：失败时向上抛，账号页显示"退出失败"并可重试，
      // 不出现"本地标记清了但 Cookie 还在"的假退出。
      await PixivNetwork().logout();
      source.data
        ..remove('token')
        ..remove('name')
        ..remove('userId');
      await source.saveData();
    },
    // Pixiv 无 token 刷新入口：会话失效需手动重登（与 NH 一致）。
    allowReLogin: false,
    infoItems: () async {
      final source = ComicSource.require('pixiv');
      final name = source.data['name']?.toString() ?? '';
      final userId = source.data['userId']?.toString() ?? '';
      if (name.isEmpty && userId.isEmpty) {
        return const Res(<AccountInfoItem>[]);
      }
      return Res([
        if (name.isNotEmpty) AccountInfoItem(title: '账号', value: name),
        if (userId.isNotEmpty) AccountInfoItem(title: '用户 ID', value: userId),
        // PHPSESSID 在别处登录可能被轮换导致本会话失效，给出明确提示
        // （依据 pixiv-web-api README 的警告，见 01 号调研 §3.1）。
        const AccountInfoItem(
          title: '提示',
          value: '该会话在其它设备登录可能导致失效，建议使用不常用账号',
        ),
      ]);
    },
  ),

  // ── 搜索（页码翻页，subData=末页页码，框架据此判停）──────────────────────
  // 固定 mode=safe：R-18 需要登录且属高风险内容，本源自用场景不做 r18 档，
  // 避免未登录用户搜到空结果却不知原因。
  searchPageData: SearchPageData(
    defaultOption: 'date_d',
    // 排序项与 pixiv-ajax-api-docs 的 order 取值一致。
    // 注意：popular* 系需要 Premium，这里不提供以免用户选了报错。
    searchOptions: const [
      SearchOption(label: '最新', value: 'date_d'),
      SearchOption(label: '最旧', value: 'date'),
    ],
    loadPage: (keyword, page, option) async {
      final res = await PixivNetwork().search(keyword, page, option);
      return _toBaseRes(res);
    },
  ),

  // ── 收藏（Pixiv 书签为单夹语义：public/private 是可见性而非多夹）────────────
  favoriteData: FavoriteData(
    key: 'pixiv',
    title: 'Pixiv',
    multiFolder: false,
    loadComic: (page, [folder]) async {
      final res = await PixivNetwork().getBookmarks(page);
      return _toBaseRes(res);
    },
    addOrDelFavorite: (comic, isAdding) {
      final numericId = source_id_rules.extractPixivNumericId(comic.id);
      if (numericId == null) {
        return Future.value(const Res.error('缺少有效的在线 ID'));
      }
      return PixivNetwork().setBookmark(numericId, isAdding: isAdding);
    },
    loadComicInfo: (target) async {
      final numericId = source_id_rules.extractPixivNumericId(target);
      if (numericId == null) {
        return const Res.error('缺少有效的在线 ID');
      }
      final res = await PixivNetwork().getComicInfo(numericId);
      if (res.error) return Res.fromErrorRes(res);
      final info = res.data;
      return Res(FavoriteInfoPatch(
        name: info.title,
        author: info.author.isEmpty ? null : info.author,
        // 只写列表口径的标签（详情 tags 已按 title/translation 拍平），
        // 与 JM/NH 的"不要把全量标签灌进卡片"原则一致。
        tags: info.tags.isEmpty ? null : List<String>.from(info.tags),
        coverPath: info.coverUrl,
      ));
    },
  ),

  // ── 详情页构造器 ───────────────────────────────────────────────────────────
  comicPageBuilder: (comic) => PixivComicPageV2(comic.id),

  // ── 封面请求头 ────────────────────────────────────────────────────────────
  // Pixiv 图片 CDN（i.pximg.net）有严格的 Referer 防盗链：裸请求会 403，
  // 必须带 `Referer: https://www.pixiv.net/`。返回非空后封面改走
  // StreamImageProvider（OnlineImageManager），顺带获得磁盘缓存与去重。
  //
  // ⚠️ **UA 必须与 API 请求用同一个 `PixivNetwork.pixivWebUA`**（Chrome/124），
  // 不能图省事用 `foundation/def.dart` 的通用 `webUA`（Chrome/138）：
  // Pixiv 会校验 UA 与会话/Referer 组合的一致性，UA 不一致时图片请求被拒，
  // 表现为"探索页列表封面全空、详情页预览全空"（真机反馈过）。
  // 详情页的封面走 `BaseOnlineComicPage.imageHeaders`，那里用的就是 pixivWebUA，
  // 所以同一个作品会出现"详情页封面正常、列表封面空白"的分裂现象。
  //
  // 注意：这里**不能**带 API 签名头（本项目铁律⑧）—— 图片域与 API 域不同，
  // 签名头绑定 API 的 Host/path，带上反而会被拒。
  imageHeadersBuilder: (comic) => const {
    'Referer': 'https://www.pixiv.net/',
    'User-Agent': PixivNetwork.pixivWebUA,
  },

  // ── ID 直跳（纯数字 / pixiv前缀）──────────────────────────────────────────
  // 前缀剥离由搜索页统一处理（见 online_search_page.dart 的 _stripIdPrefix）。
  idMatcher: RegExp(r'^(?:pixiv)?\d+$', caseSensitive: false),

  // ── 作者页直跳（把输入当作作者 uid）───────────────────────────────────────
  // 用户输入的纯数字在他看来**就是 uid**，所以这里直接把 id 交给作者页，
  // **不做**"从作品 id 反查作者"（那要查详情、多一次网络请求，用户明确排除）。
  //
  // 为什么入参要再清洗一次：搜索页虽然已经先剥过一次前缀（`_stripIdPrefix`）
  // 再把 cleanId 传进来，但钩子不能假设调用方一定清洗过。这里复用 foundation 的
  // extractPixivNumericId —— 本文件收藏区（addOrDelFavorite / loadComicInfo）在用的
  // 同一个函数，覆盖 `pixiv41678351` 这类前缀形态；非数字时它返回 null，
  // 此时按 `''` 处理，由作者页自己报"uid 无效"（不在源层编造一个能打开的页面）。
  authorPageBuilder: (comic) => PixivAuthorPageV2(
    source_id_rules.extractPixivNumericId(comic.id) ?? '',
  ),
);
