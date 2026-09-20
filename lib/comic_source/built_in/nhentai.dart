import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/comic_source/favorite_data.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/favorite_source_id.dart'
    as source_id_rules;
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

/// nhentai 的"语言"标签：详情分桶里 Languages 桶的值。
///
/// 列表卡上的 `lang`（界面显示"中文 / English / 日本語"）与它是同一份信息，
/// 因此这是详情能**忠实还原**列表口径的唯一一项标签。返回 null 表示本次没拿到，
/// 调用方据此保留原值。
///
/// 不返回其它桶：列表卡的标签来自 `tag_ids → 英文名`，详情分桶标签不带 id、
/// 数量与顺序都对不上，映射过去等于换口径。
@visibleForTesting
List<String>? nhentaiLanguageTag(Map<String, List<String>> categorizedTags) {
  final result = <String>[];
  for (final entry in categorizedTags.entries) {
    if (entry.key.trim().toLowerCase() != 'languages') continue;
    for (final value in entry.value) {
      final tag = value.trim();
      if (tag.isEmpty || result.contains(tag)) continue;
      result.add(tag);
    }
  }
  return result.isEmpty ? null : result;
}

final ComicSource nhentai = ComicSource.named(
  key: 'nhentai',
  name: 'Nhentai',

  // ── 账号（cookie 登录，走 webview）─────────────────────────────────────────
  account: AccountConfig(
    // nhentai 无账号页"重新登录"能力：收藏请求走 access_token 自动刷新，
    // 不是账号页可触发的重登操作，故不显示该行。
    allowReLogin: false,
    // nhentai 无账密 API，login 仅占位，正常走 onLogin 跳登录页。
    login: (account, password) async =>
        const Res.error('Nhentai 使用网页登录，请点击"登录"按钮'),
    onLogin: (context) => context.to(() => const NhentaiLoginPage()),
    logout: () async {
      final source = ComicSource.require('nhentai');
      // 先 await Cookie 清理：失败时向上抛，账号页显示"退出失败"并可重试，
      // 不出现"本地标记清了但 token 还在"的假退出。
      await NhentaiNetwork().logout();
      source.data
        ..remove('token')
        ..remove('name');
      await source.saveData();
    },
    // nhentai 无 token 刷新：cookie 失效需手动重登（allowReLogin 未提供）。
    infoItems: () async {
      final source = ComicSource.require('nhentai');
      final name = source.data['name']?.toString() ?? '';
      // 'Nhentai' 是历史登录流程写入的固定占位，不是真实用户名：不能当成资料行显示。
      // 这里同时兼容已经写入该占位值的旧数据。
      if (name.isEmpty || name == 'Nhentai') {
        return const Res(<AccountInfoItem>[]);
      }
      return Res([AccountInfoItem(title: '账号', value: name)]);
    },
  ),

  // ── 搜索（页码翻页，subData=末页页码，框架据此判停）────────────────────────
  searchPageData: SearchPageData(
    defaultOption: '',
    enableTagsSuggestions: true,
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
    loadComic: (page, [folder]) async {
      final res = await NhentaiNetwork().getFavorites(page);
      return _toBaseRes(res);
    },
    loadComicInfo: (target) async {
      final numericId = source_id_rules.extractNhentaiNumericId(target);
      if (numericId == null) {
        return const Res.error('缺少有效的在线 ID');
      }
      final res = await NhentaiNetwork().getComicInfo(numericId);
      if (res.error) return Res.fromErrorRes(res);
      final data = res.data;
      final authors = resolveNhentaiAuthors(data.tags).join(', ').trim();
      return Res(FavoriteInfoPatch(
        name: data.title,
        // 作者只认 Artists 桶（复用既有口径，不拿 uploader 冒充）。
        author: authors.isEmpty ? null : authors,
        // 标签只写**语言**一项。
        //
        // nhentai 列表卡的标签是 `tag_ids → 英文名`（可达二十多条），而详情只有
        // 分桶标签、**不带 tag id**：两者在数量与顺序上都不是同一份数据，硬映射
        // 等于把列表口径换成全量口径（卡片会被填满、搜索命中被稀释）。
        // 语言是详情能忠实还原的那一项（列表卡上就是 `lang`），因此只更新它；
        // 其余标签保留原值。
        tags: nhentaiLanguageTag(data.tags),
        coverPath: data.cover,
      ));
    },
  ),

  // ── 详情页构造器 ───────────────────────────────────────────────────────────
  comicPageBuilder: (comic) => NhentaiComicPageV2(comic.id),

  // ── ID 直跳（纯数字 / nh前缀 / nhentai前缀）────────────────────────────────
  // 前缀剥离由详情页构造前处理（搜索页跳转时统一剥离，见 online_search_page.dart）。
  idMatcher: RegExp(r'^(\d+|nh\d+|nhentai\d+)$', caseSensitive: false),

  // ── 封面鉴权（Referer 规避防盗链，解决搜索列表裂图）──────────────────────────
  imageHeadersBuilder: (comic) => const {'Referer': 'https://nhentai.net/'},
);
