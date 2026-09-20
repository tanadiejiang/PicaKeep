import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/app_dio.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/network/res.dart';

import 'jm_headers.dart';
import 'jm_image.dart';
import 'jm_models.dart';

export 'jm_headers.dart' show jmImgUA, getJmImgHeaders;
export 'jm_image.dart';
export 'jm_models.dart';

// 从 bytepluses 拉取加密域名清单用的两个节点（香港 + 新加坡）
const List<String> _domainUrls = [
  'https://rup4a04-c02.tos-cn-hongkong.bytepluses.com/newsvr-2025.txt',
  'https://rup4a04-c01.tos-ap-southeast-1.bytepluses.com/newsvr-2025.txt',
];

// 域名清单解密 secret（与 API 数据 secret kJmSecret 完全不同，勿混用）
const List<int> _domainSecret = [
  100, 105, 111, 115, 102, 106, 99, 107, 119, 112, 113, 112,
  100, 102, 106, 107, 118, 110, 113, 81, 106, 115, 105, 107,
];

// ============================================================================
// JM 列表接口条目解析
// ============================================================================
//
// 提成顶层函数是为了让 `test/jm_list_tags_test.dart` 能不经网络直接跑到生产
// 解析代码（类内私有方法测试文件访问不到）。生产链路只有 [_parseBrief]
// 一个薄包装入口，见下方 JmNetwork。

/// 列表接口（搜索 / 收藏 / 收藏夹）条目 → [JmComicBrief]。
/// 三处入口共用，避免解析口径漂移（`id` 为 null 等畸形条目由调用方 catch 跳过）。
/// [withDesc] 为 true 时额外读取 `description`（搜索接口有该字段，收藏接口没有）。
@visibleForTesting
JmComicBrief parseJmListBrief(Map c, {bool withDesc = false}) {
  final id = c['id'].toString();
  return JmComicBrief(
    id: id,
    title: c['name']?.toString() ?? '',
    author: joinJmListField(c['author']),
    tags: parseJmListTags(c),
    coverUrl: getJmCoverUrl(id),
    desc: withDesc ? (c['description']?.toString() ?? '') : '',
  );
}

/// JM 列表接口的分类标签：`category.title` + `category_sub.title`。
/// 与原项目 `comic["category"]/["category_sub"]` 取法一致（列表接口无 `tags` 名称数组）。
/// 按「category 在前、category_sub 在后」输出并**去重**：两者同标题时只保留一个
/// （原项目会重复显示成「同人 同人」，用户明确要求本项目只显示一个）。
/// `c['tags']` 仅作兜底，且过滤纯数字项（那里出现的往往是分类 id 而非名称）。
/// 绝不返回 null，绝不把 Map 或数字 toString 成标签。
/// 入参为 dynamic：`related_list` 等来源的元素未必是 Map，非 Map 直接返回空列表
/// （不能让畸形条目把整段详情/列表解析打挂）。
@visibleForTesting
List<String> parseJmListTags(dynamic c) {
  if (c is! Map) return const [];
  final tags = <String>[];
  _addCategoryTitle(tags, c['category']);
  _addCategoryTitle(tags, c['category_sub']);
  if (tags.isEmpty) {
    for (final t in parseJmStringList(c['tags'])) {
      final s = t.trim();
      if (s.isNotEmpty && int.tryParse(s) == null) _addTag(tags, s);
    }
  }
  return tags;
}

/// 仅当 [v] 是 Map 且 `title` 为非空字符串时收录；`id` 缺失不影响收录。
void _addCategoryTitle(List<String> out, dynamic v) {
  if (v is! Map) return;
  final title = v['title'];
  if (title is String) _addTag(out, title);
}

/// 去重收录：[title] 裁掉首尾空白后非空、且未出现过时才加入。
void _addTag(List<String> out, String title) {
  final s = title.trim();
  if (s.isEmpty || out.contains(s)) return;
  out.add(s);
}

/// 列表接口的 author 字段（可能是数组或字符串）→ 单个展示字符串。
@visibleForTesting
String joinJmListField(dynamic v) {
  if (v is List) return v.join(' / ');
  return v?.toString() ?? '';
}

/// 兼容数组/单字符串的字符串列表解析（详情接口的 author / tags / works 等）。
@visibleForTesting
List<String> parseJmStringList(dynamic v) {
  if (v is List) return v.map((e) => e.toString()).toList();
  if (v is String && v.isNotEmpty) return [v];
  return const [];
}

class JmNetwork {
  JmNetwork._();

  static JmNetwork? _cache;

  factory JmNetwork() => _cache ??= JmNetwork._();

  late final CookieJarSql _cookieJar = CookieJarSql(
    '${App.dataPath}${Platform.pathSeparator}comic_source${Platform.pathSeparator}jm_cookies.db',
  );

  CookieManagerSql get _cookieManager => CookieManagerSql(_cookieJar);

  bool _performingLogin = false;
  // 本次 app 生命周期内是否已做过域名刷新（防 _get 404 自愈循环）
  bool _domainRefreshedThisSession = false;
  // 本次 app 生命周期内是否已做过启动域名重选（防重复探测）
  bool _domainSelectedThisSession = false;

  List<String> get _domains {
    const fallback =
        'www.cdntwice.org,www.cdnsha.org,www.cdnaspa.cc,www.cdnntr.cc';
    final raw = appdata.settings[85].trim();
    return (raw.isNotEmpty ? raw : fallback)
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  int get _domainIndex {
    final idx = int.tryParse(appdata.settings[17]) ?? 0;
    return idx.clamp(0, _domains.length - 1);
  }

  String get _baseUrl => 'https://${_domains[_domainIndex]}';

  // ── 域名探测 ──────────────────────────────────────────────────────────────

  Future<void> selectDomain() async {
    final time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final opts = getJmApiOptions(time, post: true)
      ..validateStatus = (_) => true;
    int? picked;
    final futures = <Future<void>>[];
    for (var i = 0; i < _domains.length; i++) {
      final domain = _domains[i];
      final idx = i;
      futures.add(() async {
        try {
          final res = await logDio(opts).post('https://$domain/login', data: '&');
          if (res.statusCode == 401 && picked == null) picked = idx;
        } catch (_) {}
      }());
    }
    await Future.wait(futures);
    if (picked != null) {
      appdata.settings[17] = picked.toString();
      LogManager.addLog(LogLevel.info, 'JmNetwork',
          'Selected domain ${picked! + 1}: ${_domains[picked!]}');
    }
  }

  /// 从单个 bytepluses 节点拉取并解密域名清单，返回前4个域名；失败返回空列表。
  Future<List<String>> _tryFetchAndDecrypt(String url) async {
    try {
      final opts = BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        responseType: ResponseType.plain,
        headers: {
          ...getJmBaseHeaders(),
          'user-agent': jmImgUA,
        },
      );
      final res = await logDio(opts).get<String>(url);
      if (res.statusCode != 200 || res.data == null) return const [];
      final secret = String.fromCharCodes(_domainSecret);
      final decrypted = convertJmData(res.data!, secret);
      final json = jsonDecode(decrypted) as Map;
      final servers = json['Server'] as List?;
      if (servers == null || servers.isEmpty) return const [];
      return servers
          .take(4)
          .map((e) => e.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } catch (e) {
      LogManager.addLog(
          LogLevel.warning, 'JmNetwork', 'tryFetchAndDecrypt($url): $e');
      return const [];
    }
  }

  /// 动态获取 jm API 域名清单，写入 settings[85] 并重选有效域名索引。
  /// 失败时静默返回 false，不清空现有域名。
  Future<bool> getApiDomains() async {
    for (final url in _domainUrls) {
      final domains = await _tryFetchAndDecrypt(url);
      if (domains.isNotEmpty) {
        appdata.settings[85] = domains.join(',');
        await appdata.updateSettings();
        await selectDomain();
        LogManager.addLog(LogLevel.info, 'JmNetwork',
            'API domains refreshed: ${domains.join(', ')}');
        return true;
      }
    }
    LogManager.addLog(
        LogLevel.warning, 'JmNetwork', 'getApiDomains: all nodes failed');
    return false;
  }

  /// app 启动 / jm 源首次使用时：对现有域名做一次 401 探测重选活域名索引。
  /// 轻量（不打 bytepluses），解决"重登才不404"——重登做的就是 selectDomain。
  void maybeSelectDomainOnStartup() {
    if (_domainSelectedThisSession) return;
    _domainSelectedThisSession = true;
    unawaited(selectDomain());
  }

  /// app 启动预热（对齐上游"启动即重登"）：
  /// 1) 先对现有域名做一次活域名重选（轻量，不打 bytepluses）；
  /// 2) 若本地已登录，再用存储账密重换一份新鲜会话 cookie。
  ///
  /// jm 会话 cookie 寿命极短，且我们落 SQLite 持久化、无 expires 永不过期清理，
  /// 冷启动若不重登会带着失效的"僵尸 cookie"打 /album，服务端按游客返回、
  /// 收藏/点赞态恒显未收藏。重登的 `login` 自身依赖活域名 `_baseUrl`，
  /// 故必须在 selectDomain 完成后串行执行。整体异步、吞异常，不阻塞、不拖垮启动。
  void warmUpOnStartup() {
    if (_domainSelectedThisSession) return;
    _domainSelectedThisSession = true;
    unawaited(_warmUp());
  }

  Future<void> _warmUp() async {
    try {
      await selectDomain();
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.warning, 'JmNetwork', 'warmUp selectDomain: $e\n$s');
    }
    // 仅已登录才重登：游客无账密，避免无谓请求。
    if (!_hasStoredLogin) return;
    try {
      final res = await reLoginFromStored();
      LogManager.addLog(
        res.success ? LogLevel.info : LogLevel.warning,
        'JmNetwork',
        res.success
            ? 'startup relogin ok'
            : 'startup relogin failed: ${res.errorMessage}',
      );
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'JmNetwork', 'startup relogin: $e\n$s');
    }
  }

  /// 本地是否已登录（jm.data 里 token 非空）。与 [reLoginFromStored] 读同一份数据，
  /// 不依赖 ComicSource，保持网络层纯净。
  bool get _hasStoredLogin {
    final token = _readJmData()?['token']?.toString() ?? '';
    return token.isNotEmpty;
  }

  /// 判断错误文案是否表示"需要登录"。放宽到简体/英文，防服务端改文案漏判自愈。
  static bool _looksLikeLoginError(String msg) {
    final lower = msg.toLowerCase();
    return msg.contains('登入') ||
        msg.contains('登录') ||
        lower.contains('login') ||
        lower.contains('member');
  }

  // ── GET（带解密）──────────────────────────────────────────────────────────

  Future<Res<dynamic>> _get(String url, {bool isRetry = false}) async {
    while (_performingLogin) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // 接受所有 4xx 以便读取响应体（jm 有时用 404 而非 401 表示未登录）
    final opts = getJmApiOptions(time)
      ..validateStatus = (i) => i != null && i < 500;
    final dio = logDio(opts);
    dio.interceptors.add(_cookieManager);
    try {
      final res = await dio.get<Uint8List>(url);
      final status = res.statusCode ?? 0;
      if (status != 200) {
        // 尝试解码响应体，检查是否是"请先登录"错误
        String? errMsg;
        try {
          final bodyStr = utf8.decode(res.data ?? Uint8List(0));
          final decoded = jsonDecode(bodyStr) as Map?;
          errMsg = decoded?['errorMsg']?.toString() ??
              decoded?['msg']?.toString() ??
              decoded?['error']?.toString();
        } catch (_) {}
        final needsLogin = errMsg != null && _looksLikeLoginError(errMsg);
        if (needsLogin && !isRetry) {
          final reRes = await reLoginFromStored();
          if (reRes.success) return _get(url, isRetry: true);
        }
        // 404 自愈：先重选活域名(selectDomain，便宜)，仍不行再拉新清单(getApiDomains)。
        // 仅非登录错误、且本 session 未自愈过。
        if (status == 404 && !needsLogin && !isRetry && !_domainRefreshedThisSession) {
          _domainRefreshedThisSession = true;
          LogManager.addLog(LogLevel.info, 'JmNetwork',
              '404 detected, re-selecting domain then refreshing if needed...');
          await selectDomain();
          var newUrl = _rebuildUrl(url);
          final retry = await _get(newUrl, isRetry: true);
          if (!retry.error) return retry;
          // selectDomain 不够 → 拉 bytepluses 新清单再试
          final ok = await getApiDomains();
          if (ok) {
            newUrl = _rebuildUrl(url);
            return _get(newUrl, isRetry: true);
          }
          return retry;
        }
        return Res.error(
            errMsg ?? 'Invalid Status Code: $status. ${_statusText(status)}');
      }
      final bodyStr = utf8.decode(res.data ?? Uint8List(0));
      final json = jsonDecode(bodyStr) as Map;
      final raw = json['data'];
      if (raw == null || (raw is List && raw.isEmpty)) {
        return const Res.error('Empty data');
      }
      final decrypted = convertJmData(
        raw is String ? raw : jsonEncode(raw),
        '$time$kJmSecret',
      );
      return Res<dynamic>(jsonDecode(decrypted));
    } on DioException catch (e) {
      return Res.error(e.message ?? e.toString());
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'JmNetwork', '$e\n$s');
      return Res.error(e.toString());
    }
  }

  /// 把 URL 中的旧域名替换为当前 _baseUrl（用于 404 自愈后重试）
  String _rebuildUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final baseUri = Uri.tryParse(_baseUrl);
    if (baseUri == null) return url;
    return uri.replace(host: baseUri.host, scheme: baseUri.scheme).toString();
  }

  // ── POST ──────────────────────────────────────────────────────────────────

  Future<Res<dynamic>> _post(String url, String body,
      {bool isRetry = false}) async {
    final time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final opts = getJmApiOptions(time, post: true)
      ..validateStatus = (i) => i == 200 || i == 401;
    final dio = logDio(opts);
    dio.interceptors.add(_cookieManager);
    try {
      final res = await dio.post<Uint8List>(url, data: body);
      final bodyStr = utf8.decode(res.data ?? Uint8List(0));
      if (res.statusCode == 401) {
        final msg =
            ((jsonDecode(bodyStr) as Map?)?['errorMsg'])?.toString() ?? '401';
        // 登录态失效自愈：用存储的账号密码重登一次再重试（与 _get 一致）。
        // jm 的 POST（收藏/点赞/评论）不像 GET 那样会被浏览自愈带过，
        // cookie 过期时这里若不自愈就会把"請先登入會員"直接抛给用户。
        final needsLogin = _looksLikeLoginError(msg);
        if (needsLogin && !isRetry) {
          final reRes = await reLoginFromStored();
          if (reRes.success) return _post(url, body, isRetry: true);
        }
        return Res.error(msg);
      }
      final json = jsonDecode(bodyStr) as Map;
      // POST 的 200 静默降级兜底：服务端可能返回 200 但 body 含 status:fail + 登录错误文案。
      // 若命中且未重试过，触发一次自愈（对齐 GET 的游客 200 兜底逻辑）。
      if (!isRetry &&
          json['status'] == 'fail' &&
          _hasStoredLogin &&
          _looksLikeLoginError(json['msg']?.toString() ?? '')) {
        final reRes = await reLoginFromStored();
        if (reRes.success) return _post(url, body, isRetry: true);
      }
      final raw = json['data'];
      if (raw == null) return const Res<dynamic>(null);
      final decrypted = convertJmData(
        raw is String ? raw : jsonEncode(raw),
        '$time$kJmSecret',
      );
      return Res<dynamic>(jsonDecode(decrypted));
    } on DioException catch (e) {
      return Res.error(e.message ?? e.toString());
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'JmNetwork', '$e\n$s');
      return Res.error(e.toString());
    }
  }

  // ── 登录 ──────────────────────────────────────────────────────────────────

  Future<Res<bool>> login(String account, String password) async {
    _performingLogin = true;
    try {
      final res = await _post(
        '$_baseUrl/login',
        'username=${Uri.encodeComponent(account)}&password=${Uri.encodeComponent(password)}',
        isRetry: true, // 登录接口自身不触发自愈，避免递归
      );
      if (res.error) return Res.fromErrorRes(res);
      // 把服务器返回的 username/uid 写回调用方可读的数据
      _lastLoginName = res.data?['username']?.toString() ?? '';
      _lastLoginUid = res.data?['uid']?.toString() ?? '';
      return const Res(true);
    } finally {
      _performingLogin = false;
    }
  }

  String _lastLoginName = '';
  String _lastLoginUid = '';
  String get lastLoginName => _lastLoginName;
  String get lastLoginUid => _lastLoginUid;

  Future<Res<bool>> reLoginFromStored() async {
    final data = _readJmData();
    final creds = data?['account'] as List?;
    if (creds == null || creds.length < 2) {
      return const Res.error('no stored credentials');
    }
    return login(creds[0].toString(), creds[1].toString());
  }

  Future<void> logout() async => _cookieJar.deleteAll();

  // ── 搜索 ──────────────────────────────────────────────────────────────────

  Future<Res<List<JmComicBrief>>> search(
      String keyword, String order, int page) async {
    final encoded =
        Uri.encodeComponent(keyword.trim()).replaceAll('%20', '+');
    final url = page == 1
        ? '$_baseUrl/search?search_query=$encoded&o=$order'
        : '$_baseUrl/search?search_query=$encoded&o=$order&page=$page';
    final res = await _get(url);
    if (res.error) return Res.fromErrorRes(res);
    try {
      final comics = <JmComicBrief>[];
      for (final c in res.data['content'] as List) {
        try {
          comics.add(_parseBrief(c as Map, withDesc: true));
        } catch (_) {
          continue;
        }
      }
      final total = _parseInt(res.data['total']);
      final perPage = comics.isEmpty ? 1 : comics.length;
      return Res(comics, subData: total == 0 ? 1 : (total / perPage).ceil());
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'JmNetwork', 'search: $e\n$s');
      return Res.error(e.toString());
    }
  }

  // ── 漫画详情 ──────────────────────────────────────────────────────────────

  Future<Res<JmComicInfo>> getComicInfo(String id, {bool isRetry = false}) async {
    final res = await _get('$_baseUrl/album?id=$id');
    if (res.error) return Res.fromErrorRes(res);
    try {
      final d = res.data as Map;
      // 游客 200 静默降级兜底：服务端对失效会话/游客的 /album 可能返回 200 但
      // 整体不含 is_favorite/liked 字段（非 false，是 key 缺失），此时 _get 的
      // 401 自愈够不着。若本地已登录且字段整体缺失，视为会话可疑，重登重取一次。
      // containsKey 区分"字段缺失(会话失效)"与"返回 false(真未收藏)"，避免误循环。
      if (!isRetry &&
          _hasStoredLogin &&
          !d.containsKey('is_favorite') &&
          !d.containsKey('liked')) {
        final reRes = await reLoginFromStored();
        if (reRes.success) return getComicInfo(id, isRetry: true);
      }
      final series = <int, String>{};
      final epNames = <String>[];
      var sort = 1;
      for (final s in (d['series'] as List? ?? [])) {
        series[sort] = s['id'].toString();
        var name = s['name']?.toString() ?? '';
        if (name.isEmpty) name = '第${s['sort']}話';
        epNames.add(name);
        sort++;
      }
      if (series.isEmpty) {
        series[1] = id;
        epNames.add('第1章');
      }

      // 解析相关推荐
      final relatedList = (d['related_list'] as List? ?? []);
      final relatedComics = <JmComicBrief>[];
      for (final item in relatedList) {
        final comicId = item['id']?.toString() ?? '';
        if (comicId.isEmpty) continue;
        relatedComics.add(JmComicBrief(
          id: comicId,
          title: item['name']?.toString() ?? '',
          author: parseJmStringList(item['author']).join(', '),
          tags: parseJmListTags(item),
          coverUrl: getJmCoverUrl(comicId),
        ));
      }

      return Res(JmComicInfo(
        id: id,
        title: d['name']?.toString() ?? 'Unknown',
        authors: parseJmStringList(d['author']),
        description: d['description']?.toString() ?? '',
        likes: _parseInt(d['likes']),
        views: _parseInt(d['total_views']),
        comments: _parseInt(d['comment_total']),
        tags: parseJmStringList(d['tags']),
        works: parseJmStringList(d['works']),
        actors: parseJmStringList(d['actors']),
        series: series,
        epNames: epNames,
        isFavourite: d['is_favorite'] == true || d['is_favorite'] == 1,
        isLiked: d['liked'] == true || d['liked'] == 1,
        coverUrl: getJmCoverUrl(id),
        relatedComics: relatedComics,
      ));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'JmNetwork', 'getComicInfo: $e\n$s');
      return Res.error(e.toString());
    }
  }

  // ── 章节图片 ──────────────────────────────────────────────────────────────

  Future<Res<List<String>>> getChapter(String chapterId) async {
    final res = await _get('$_baseUrl/chapter?id=$chapterId');
    if (res.error) return Res.fromErrorRes(res);
    try {
      final images = <String>[];
      for (final s in res.data['images'] as List) {
        images.add(getJmImageUrl(s.toString(), chapterId));
      }
      return Res(images);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'JmNetwork', 'getChapter: $e\n$s');
      return Res.error(e.toString());
    }
  }

  // ── 收藏 ──────────────────────────────────────────────────────────────────

  Future<Res<bool>> setFavorite(String comicId, {required bool add}) async {
    final res = await _post('$_baseUrl/favorite', 'aid=$comicId');
    if (res.error) return Res.fromErrorRes(res);
    try {
      final type = res.data['type']?.toString() ?? '';
      final isNowAdded = type == 'add';
      if (add != isNowAdded) {
        final res2 = await _post('$_baseUrl/favorite', 'aid=$comicId');
        if (res2.error) return Res.fromErrorRes(res2);
      }
      return const Res(true);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  Future<Res<List<JmComicBrief>>> getFavorites(int page) async {
    final res =
        await _get('$_baseUrl/favorite?page=$page&folder_id=0&o=mr');
    if (res.error) return Res.fromErrorRes(res);
    try {
      final comics = <JmComicBrief>[];
      for (final c in (res.data['list'] as List? ?? [])) {
        try {
          comics.add(_parseBrief(c as Map));
        } catch (_) {
          continue;
        }
      }
      final total = _parseInt(res.data['total']);
      final perPage = comics.isEmpty ? 1 : comics.length;
      return Res(comics,
          subData: total == 0 ? 1 : (total / perPage).ceil());
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'JmNetwork', 'getFavorites: $e\n$s');
      return Res.error(e.toString());
    }
  }

  Future<Res<List<JmComicBrief>>> getFolderComicsPage(
      String folderId, int page) async {
    final res = await _get(
        '$_baseUrl/favorite?page=$page&folder_id=$folderId&o=mr');
    if (res.error) return Res.fromErrorRes(res);
    try {
      final comics = <JmComicBrief>[];
      for (final c in (res.data['list'] as List? ?? [])) {
        try {
          comics.add(_parseBrief(c as Map));
        } catch (_) {
          continue;
        }
      }
      final total = _parseInt(res.data['total']);
      final perPage = comics.isEmpty ? 1 : comics.length;
      return Res(comics,
          subData: total == 0 ? 1 : (total / perPage).ceil());
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, 'JmNetwork', 'getFolderComicsPage: $e\n$s');
      return Res.error(e.toString());
    }
  }

  /// 获取收藏夹列表（随收藏列表一起返回的 folder_list）
  Future<Res<List<JmFolder>>> getFolders() async {
    final res = await _get('$_baseUrl/favorite?page=1&folder_id=0&o=mr');
    if (res.error) return Res.fromErrorRes(res);
    try {
      final folders = <JmFolder>[];
      for (final f in (res.data['folder_list'] as List? ?? [])) {
        final id = f['FID']?.toString() ?? '';
        final name = f['name']?.toString() ?? '';
        if (id.isNotEmpty) folders.add(JmFolder(id: id, name: name));
      }
      return Res(folders);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'JmNetwork', 'getFolders: $e\n$s');
      return Res.error(e.toString());
    }
  }

  /// 将已收藏漫画移动到指定收藏夹
  Future<Res<bool>> moveFavoriteToFolder(String comicId, String folderId) async {
    final res = await _post(
        '$_baseUrl/favorite_folder', 'type=move&aid=$comicId&folder_id=$folderId');
    if (res.error) return Res.fromErrorRes(res);
    return const Res(true);
  }

  // ── 评论 ──────────────────────────────────────────────────────────────────

  /// 获取漫画评论。mode=manhua 为漫画评论。
  Future<Res<List<JmComment>>> getComments(String comicId, int page,
      {String mode = 'manhua'}) async {
    final res =
        await _get('$_baseUrl/forum?mode=$mode&aid=$comicId&page=$page');
    if (res.error) return Res.fromErrorRes(res);
    try {
      final comments = <JmComment>[];
      for (final c in (res.data['list'] as List? ?? [])) {
        try {
          final replies = <JmComment>[];
          for (final r in (c['replys'] as List? ?? [])) {
            replies.add(JmComment(
              id: r['CID']?.toString() ?? '',
              username: r['username']?.toString() ?? '',
              content: _stripHtml(r['content']?.toString() ?? ''),
              timeAgo: r['addtime']?.toString() ?? '',
              avatar: getJmAvatarUrl(r['photo']?.toString() ?? ''),
            ));
          }
          comments.add(JmComment(
            id: c['CID']?.toString() ?? '',
            username: c['username']?.toString() ?? '',
            content: _stripHtml(c['content']?.toString() ?? ''),
            timeAgo: c['addtime']?.toString() ?? '',
            avatar: getJmAvatarUrl(c['photo']?.toString() ?? ''),
            replies: replies,
          ));
        } catch (_) {
          continue;
        }
      }
      final total = _parseInt(res.data['total']);
      final perPage = comments.isEmpty ? 1 : comments.length;
      return Res(comments,
          subData: total == 0 ? 1 : (total / perPage).ceil());
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'JmNetwork', 'getComments: $e\n$s');
      return Res.error(e.toString());
    }
  }

  // ── 工具 ──────────────────────────────────────────────────────────────────

  /// 去除评论 content 中的 HTML 标签（原项目用 html 包 parseFragment，
  /// 这里用正则简化处理，评论内容通常只被 div 包裹的纯文本）。
  static String _stripHtml(String input) {
    final noTags = input.replaceAll(RegExp(r'<[^>]*>'), '');
    return noTags
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .trim();
  }

  static String _statusText(int code) => switch (code) {
        400 => 'Bad request',
        401 => 'Unauthorized',
        403 => 'Forbidden',
        404 => 'Not found',
        _ => 'Error',
      };

  /// 列表接口条目解析入口（实现见顶层 [parseJmListBrief]）。
  static JmComicBrief _parseBrief(Map c, {bool withDesc = false}) =>
      parseJmListBrief(c, withDesc: withDesc);

  /// 点赞漫画
  Future<Res<bool>> likeComic(String id) async {
    final res = await _post('$_baseUrl/like', 'id=$id');
    if (res.error) return Res.fromErrorRes(res);
    return const Res(true);
  }

  /// 发送评论
  Future<Res<String>> comment(String aid, String content) async {
    final body = 'comment=${Uri.encodeComponent(content)}&status=undefined&aid=$aid';
    final res = await _post('$_baseUrl/comment', body);
    if (res.error) return Res.fromErrorRes(res);

    // 检查响应中的 status 字段
    if (res.data is Map && res.data['status'] == 'fail') {
      final message = res.data['msg']?.toString() ?? '发送失败';
      return Res.error(message);
    }

    final message = res.data is Map ? (res.data['msg']?.toString() ?? '评论成功') : '评论成功';
    return Res(message);
  }

  /// 回复某条评论。[commentId] 为被回复评论的 ID（即 JmComment.id）。
  /// 尝试用 CID（大写）作为参数名，对齐 API 响应中的字段名。
  Future<Res<String>> replyComment(String aid, String content, String commentId) async {
    final body =
        'comment=${Uri.encodeComponent(content)}&aid=$aid&CID=$commentId&is_reply=1&forum_subject=1';
    LogManager.addLog(LogLevel.info, 'JmNetwork',
        'replyComment body: $body (commentId=$commentId)');
    final res = await _post('$_baseUrl/comment', body);
    LogManager.addLog(LogLevel.info, 'JmNetwork',
        'replyComment response: error=${res.error}, data=${res.data}');
    if (res.error) return Res.fromErrorRes(res);
    if (res.data is Map && res.data['status'] == 'fail') {
      final message = res.data['msg']?.toString() ?? '发送失败';
      return Res.error(message);
    }
    final message =
        res.data is Map ? (res.data['msg']?.toString() ?? '回复成功') : '回复成功';
    return Res(message);
  }

  static int _parseInt(dynamic v) {
    if (v is int) return v;
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static Map<String, dynamic>? _readJmData() {
    try {
      final file = File(
        '${App.dataPath}${Platform.pathSeparator}comic_source${Platform.pathSeparator}jm.data',
      );
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync()) as Map;
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }
}
