import 'package:flutter/foundation.dart';

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/comic_source/favorite_data.dart';
import 'package:picakeep/foundation/favorite_source_id.dart'
    as source_id_rules;
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/jm_comic_page_v2.dart';

final _jmNet = JmNetwork();

final ComicSource jm = ComicSource.named(
  key: 'jm',
  name: '禁漫',
  account: AccountConfig(
    // 注册入口取自原项目 `built_in/jm.dart` 的声明值；本轮未在线验证该地址可达性。
    registerWebsite: 'https://18comic.vip/signup',
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
      // 账号资料（name/uid）属于登录态，退出时一并清除；
      // 只保留 searchOptions 等与账号无关的声明数据。
      source.data
        ..remove('token')
        ..remove('account')
        ..remove('name')
        ..remove('uid');
      await source.saveData();
    },
    reLogin: () async {
      final res = await _jmNet.reLoginFromStored();
      if (res.error) return res;
      // 手动重登会换新 Cookie，资料可能随之变化：成功后回填 name/uid 并落盘，
      // 否则账号页会一直显示旧名字/UID。不改后台预热与启动自愈实现。
      await applyJmReloginProfile(
        ComicSource.require('jm'),
        name: _jmNet.lastLoginName,
        uid: _jmNet.lastLoginUid,
      );
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
    multiFolder: true,
    allFavoritesId: '0',
    loadComic: (page, [folder]) async {
      final res = await _jmNet.getFolderComicsPage(folder ?? '0', page);
      if (res.error) return Res.fromErrorRes(res);
      return Res<List<BaseComic>>(res.data, subData: res.subData);
    },
    loadFolders: () async {
      final res = await _jmNet.getFolders();
      if (res.error) return Res.fromErrorRes(res);
      final map = <String, String>{'0': '全部'};
      for (final f in res.data) {
        map[f.id] = f.name;
      }
      return Res(map);
    },
    addOrDelFavorite: (comic, isAdding) async {
      return _jmNet.setFavorite(comic.id, add: isAdding);
    },
    loadComicInfo: (target) async {
      final numericId = source_id_rules.extractJmNumericId(target);
      if (numericId == null) {
        return const Res.error('缺少有效的在线 ID');
      }
      final res = await _jmNet.getComicInfo(numericId);
      if (res.error) return Res.fromErrorRes(res);
      final info = res.data;
      final authors = info.authors.join(', ').trim();
      return Res(FavoriteInfoPatch(
        name: info.title,
        author: authors.isEmpty ? null : authors,
        // 只写**列表口径**的分类标签。`info.tags` 是详情全量标签（可达数十条），
        // 写进本地会把卡片填满并稀释搜索命中，因此不采用；
        // 接口未返回 category 时为空列表 → 传 null，保留本地原值。
        tags: info.categoryTags.isEmpty
            ? null
            : List<String>.from(info.categoryTags),
        coverPath: info.coverUrl,
      ));
    },
  ),
  searchPageData: SearchPageData(
    defaultOption: 'mr',
    // 七项排序与原项目 `built_in/jm.dart` 的值、文案、顺序一致;
    // order 直接进搜索 URL 的 `o=`,本声明同时供入口页与结果页读取。
    searchOptions: const [
      SearchOption(label: '最新', value: 'mr'),
      SearchOption(label: '总排行', value: 'mv'),
      SearchOption(label: '月排行', value: 'mv_m'),
      SearchOption(label: '周排行', value: 'mv_w'),
      SearchOption(label: '日排行', value: 'mv_t'),
      SearchOption(label: '最多图片', value: 'mp'),
      SearchOption(label: '最多喜欢', value: 'tf'),
    ],
    loadPage: (keyword, page, option) async {
      final res = await _jmNet.search(keyword, option, page);
      if (res.error) return Res.fromErrorRes(res);
      return Res<List<BaseComic>>(res.data, subData: res.subData);
    },
  ),
  comicPageBuilder: (comic) => JmComicPageV2(comic.id),

  // ── ID 直跳（纯数字 / jm前缀）──────────────────────────────────────────────
  idMatcher: RegExp(r'^(?:jm)?\d+$', caseSensitive: false),
);

/// 手动重登成功后的资料回填与落盘。
///
/// 抽成独立函数是为了能直接验证"重登成功后 name/uid 与数据文件一致"，
/// 而不必让测试去驱动真实登录网络请求。空值不覆盖既有资料：
/// 源没有返回新名字时，不能把已经拿到过的真名清成空。
@visibleForTesting
Future<void> applyJmReloginProfile(
  ComicSource source, {
  required String name,
  required String uid,
  Future<void> Function()? save,
}) async {
  final trimmedName = name.trim();
  final trimmedUid = uid.trim();
  if (trimmedName.isNotEmpty) {
    source.data['name'] = trimmedName;
  }
  if (trimmedUid.isNotEmpty) {
    source.data['uid'] = trimmedUid;
  }
  source.data['token'] = 'logged_in';
  await (save ?? source.saveData)();
}
