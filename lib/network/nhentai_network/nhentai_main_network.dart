import 'dart:convert';
import 'dart:io' show Cookie;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:html/dom.dart';
import 'package:picakeep/foundation/explore/providers/nhentai_explore_options.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/cloudflare.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/network/nhentai_network/tags.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/tools/extensions.dart';
import 'package:picakeep/tools/translations.dart';
import '../app_dio.dart';
import 'models.dart';
import 'package:html/parser.dart';

export 'models.dart';

/// 把上传时间格式化成相对时间（X 天前 / X 个月前）。
///
/// 内联自上游 `tools/time.dart` 的 timeToString —— PicaKeep 的 time.dart 不含该
/// 函数（仅一个 TimeExtension），故在网络层内本地化，避免改公共 time.dart。
String _nhTimeToString(DateTime time) {
  var current = DateTime.now();
  if (current.millisecondsSinceEpoch < time.millisecondsSinceEpoch) {
    return "Error";
  }
  final diff = current.difference(time);
  if (diff.inDays > 360) {
    return "@year 年前".tlParams({"year": (diff.inDays ~/ 360).toString()});
  } else if (diff.inDays > 30) {
    return "@month 个月前".tlParams({"month": (diff.inDays ~/ 30).toString()});
  } else if (diff.inHours > 24) {
    return "@day 天前".tlParams({"day": diff.inDays.toString()});
  } else if (diff.inMinutes > 60) {
    return "@hour 小时前".tlParams({"hour": diff.inHours.toString()});
  } else if (diff.inSeconds > 60) {
    return "@minute 分钟前".tlParams({"minute": diff.inMinutes.toString()});
  } else {
    return "刚刚".tl;
  }
}

/// nhentai 语言类 tag id → 展示语言名（`Unknown` 表示判定不出，不入表）。
///
/// 与 v2 API 的 `tag_ids`、HTML 的 `data-tags` 共用同一份映射：两处判定口径
/// 必须一致，否则同一本书在首页与搜索页会显示不同语言。
const Map<String, String> nhentaiLanguageTagNames = {
  '12227': 'English',
  '6346': '日本語',
  '29963': '中文',
};

/// v2 列表与随机详情共用的轻量元数据解析；不补发逐本详情请求。
/// 列表主要给 tag_ids，详情/部分响应可直接给具名 tags。
@visibleForTesting
NhentaiComicBrief? parseNhentaiV2Gallery(
  Map<String, dynamic> item, {
  required String cdnServer,
}) {
  final id = item['id']?.toString() ?? '';
  if (!RegExp(r'^\d+$').hasMatch(id) || int.tryParse(id) == 0) return null;

  final titles = item['title'];
  final title = <Object?>[
    item['english_title'],
    if (titles is Map) titles['english'],
    item['japanese_title'],
    if (titles is Map) titles['japanese'],
    if (titles is Map) titles['pretty'],
    if (titles is String) titles,
  ].whereType<String>().map((value) => value.trim()).firstWhere(
        (value) => value.isNotEmpty,
        orElse: () => id,
      );

  String imagePath(Object? value) {
    if (value is String) return value.trim();
    if (value is Map) return imagePath(value['path'] ?? value['url']);
    return '';
  }

  var rawCover = imagePath(item['thumbnail']);
  if (rawCover.isEmpty) rawCover = imagePath(item['cover']);
  final cdn = cdnServer.replaceAll(RegExp(r'/+$'), '');
  final cover = rawCover.isEmpty
      ? ''
      : rawCover.startsWith('//')
          ? 'https:$rawCover'
          : Uri.tryParse(rawCover)?.hasScheme == true
              ? rawCover
              : '$cdn/${rawCover.replaceAll(RegExp(r'^/+'), '')}';

  final tagIds = <String>{};
  final namesById = <String, String>{};
  final namedTags = <String>{};
  String? language;
  const languageNames = {
    'english': 'English',
    'japanese': '日本語',
    'chinese': '中文',
  };
  final rawIds = item['tag_ids'];
  if (rawIds is List) {
    tagIds.addAll(rawIds.where((value) => value != null).map((e) => '$e'));
  }
  final rawTags = item['tags'];
  if (rawTags is List) {
    for (final tag in rawTags) {
      if (tag is! Map) continue;
      final tagId = tag['id']?.toString();
      final name = tag['name'] is String ? (tag['name'] as String).trim() : '';
      if (tagId != null) {
        tagIds.add(tagId);
        if (name.isNotEmpty) namesById[tagId] = name;
      }
      if (tag['type'] == 'language') {
        language ??= languageNames[name.toLowerCase()];
      } else if (name.isNotEmpty) {
        namedTags.add(name);
      }
    }
  }
  final tags = <String>{};
  for (final tagId in tagIds) {
    final mappedLanguage = nhentaiLanguageTagNames[tagId];
    if (mappedLanguage != null) {
      language ??= mappedLanguage;
      continue;
    }
    final name = namesById[tagId] ?? nhentaiTags[tagId];
    if (name != null && name.isNotEmpty) tags.add(name);
  }
  tags.addAll(namedTags);
  return NhentaiComicBrief(
      title, cover, id, language ?? 'Unknown', tags.toList());
}

/// 探索首页单本 `div.gallery` 的**容错解析**（顶层函数，便于直接用 HTML 夹具测试）。
///
/// 与 [NhentaiNetwork.parseComic] 的**唯一差异是容错性，不是字段口径**：
/// - 字段口径完全一致：`a > img` 取封面、`div.caption` 取标题、`a[href]` 取数字
///   id、`data-tags` 按空格切分后经 [nhentaiTags] 映射成英文标签名、语言按
///   [nhentaiLanguageTagNames] 判定（判定不出为 `Unknown`）。
/// - 容错差异：`parseComic` 对四个元素一律 `!` 强制解包，缺任何一个就抛异常
///   （调用方整页失败）；本函数缺字段不崩、能用多少用多少，id 非法时才返回
///   `null`（且**只因此一处**返回 null，调用方据此跳过坏条目）。
///
/// 注意：`data-tags` 缺失或为空时返回**空标签列表 + `Unknown`**，不补发详情
/// 请求、也不把数字 id 当标签名——这是"允许未知"，不是功能回退。
@visibleForTesting
NhentaiComicBrief? parseNhentaiHomeComic(Element comicDom) {
  try {
    // id：href 里抠数字，空 / 非数字一律判坏（唯一返回 null 的出口）。
    final anchor = comicDom.querySelector("a");
    final id = anchor?.attributes["href"]?.nums ?? '';
    if (id.isEmpty || int.tryParse(id) == null) return null;

    // 封面：懒加载时 `src` 是空串或内联 `data:` 占位，回退 `data-src`。
    final img = comicDom.querySelector("a > img");
    var cover = img?.attributes["src"] ?? '';
    if (cover.isEmpty || cover.startsWith('data:')) {
      final lazy = img?.attributes["data-src"] ?? '';
      if (lazy.isNotEmpty) cover = lazy;
    }

    final name = comicDom.querySelector("div.caption")?.text ?? '';

    // 标签 / 语言同源：都从 data-tags 的空格分隔 id 列表读。
    final tagIds = (comicDom.attributes["data-tags"] ?? '')
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .toList();

    // 只保留 nhentaiTags 里有英文名的 id，未知数字 id 直接丢弃（不落地数字）。
    final tags =
        tagIds.map((tag) => nhentaiTags[tag]).whereType<String>().toList();

    var lang = 'Unknown';
    for (final tag in tagIds) {
      final mapped = nhentaiLanguageTagNames[tag];
      if (mapped != null) {
        lang = mapped;
        break;
      }
    }

    return NhentaiComicBrief(
      name.trim().isEmpty ? id : name,
      cover,
      id,
      lang,
      tags,
    );
  } catch (_) {
    return null;
  }
}

class NhentaiNetwork {
  factory NhentaiNetwork() => _cache ?? (_cache = NhentaiNetwork._create());

  NhentaiNetwork._create();

  @visibleForTesting
  NhentaiNetwork.forTesting({
    required Future<Res<String>> Function(String url) get,
  }) : _getOverride = get;

  Future<Res<String>> Function(String url)? _getOverride;

  static NhentaiNetwork? _cache;

  SingleInstanceCookieJar? cookieJar;

  bool logged = false;

  String baseUrl = "https://nhentai.net";

  /// 从 /api/v2/cdn 动态获取的缩略图 CDN 服务器前缀，避免硬编码子域名。
  String? _cdnServer;

  late Dio dio;

  Future<void> init() async {
    cookieJar = SingleInstanceCookieJar.instance;
    // nhentai 新版用 JWT：登录后下发 access_token + refresh_token（不再是旧版
    // Django session 的 sessionid）。任一存在即视为已登录。
    for (var cookie in cookieJar!.loadForRequest(Uri.parse(baseUrl))) {
      if (cookie.name == "access_token" || cookie.name == "refresh_token") {
        logged = true;
      }
    }
    dio = logDio(BaseOptions(
      headers: {
        "Accept":
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        "Accept-Language": "zh-CN,zh-TW;q=0.9,zh;q=0.8,en-US;q=0.7,en;q=0.6",
        "Referer": "$baseUrl/",
      },
      validateStatus: (i) => i == 200 || i == 301 || i == 302 || i == 308,
    ));
    dio.interceptors.add(CookieManagerSql(cookieJar!));
    dio.interceptors.add(CloudflareInterceptor());
  }

  /// 退出登录：清除新版 JWT token cookie（access_token + refresh_token）。
  ///
  /// - 返回可 await 的 Future：调用方必须等它结束才报"已退出"；
  /// - 删除落在根路径 `/`：[CookieJarSql.delete] 严格按 path 精确匹配，而
  ///   baseUrl 自身的 path 为空，写库时 Cookie 默认落在 `/`，用不带 `/` 的 Uri 删不到；
  /// - jar 未绑定时取应用初始化好的共享 jar（只取用，不新建或重置整个库）；
  ///   确实没有可用 jar 时抛错，由调用方显示"退出失败"，不静默谎报已退出。
  Future<void> logout() async {
    logged = false;
    final jar = cookieJar ?? SingleInstanceCookieJar.instance;
    if (jar == null) {
      throw StateError('Cookie 存储尚未初始化，无法退出登录');
    }
    // 保持未初始化状态：只绑定 jar 会让下次请求跳过尚未完成的 Dio 初始化。
    final uri = Uri.parse(baseUrl).replace(path: '/');
    jar.delete(uri, 'access_token');
    jar.delete(uri, 'refresh_token');
  }

  /// 从 cookieJar 读取 CSRF token。
  ///
  /// Django 以 `csrftoken` cookie（非 httpOnly）下发 CSRF token，在
  /// `getComicInfo` 的 script 解析失败时作为 fallback，确保收藏操作有 token。
  String getCsrfToken() {
    if (cookieJar == null) return '';
    final cookies = cookieJar!.loadForRequest(Uri.parse(baseUrl));
    try {
      return cookies.firstWhere((c) => c.name == 'csrftoken').value;
    } catch (_) {
      return '';
    }
  }

  /// 用 refresh_token 刷新 access_token（JWT 过期时调用）。
  /// 返回新 access_token，失败返回空字符串。
  Future<String> _refreshAccessToken() async {
    if (cookieJar == null) return '';
    final cookies = cookieJar!.loadForRequest(Uri.parse(baseUrl));
    String refreshToken = '';
    try {
      refreshToken = cookies.firstWhere((c) => c.name == 'refresh_token').value;
    } catch (_) {
      return '';
    }
    if (refreshToken.isEmpty) return '';

    try {
      final res = await post('$baseUrl/api/v2/auth/refresh', {
        'refresh_token': refreshToken,
      });
      if (res.error) return '';
      final json = const JsonDecoder().convert(res.data);
      final newAccessToken = json['access_token'] as String?;
      if (newAccessToken == null || newAccessToken.isEmpty) return '';

      // 更新 cookieJar 里的 access_token cookie
      final uri = Uri.parse(baseUrl);
      final newCookie = Cookie('access_token', newAccessToken)
        ..domain = uri.host
        ..path = '/'
        ..httpOnly = true;
      cookieJar!.saveFromResponse(uri, [newCookie]);

      // 若响应包含新 refresh_token，也更新
      final newRefreshToken = json['refresh_token'] as String?;
      if (newRefreshToken != null && newRefreshToken.isNotEmpty) {
        final refreshCookie = Cookie('refresh_token', newRefreshToken)
          ..domain = uri.host
          ..path = '/'
          ..httpOnly = true;
        cookieJar!.saveFromResponse(uri, [refreshCookie]);
      }

      return newAccessToken;
    } catch (e) {
      LogManager.addLog(LogLevel.error, 'TokenRefresh', 'Failed: $e');
      return '';
    }
  }

  /// 从 /api/v2/cdn 动态取 CDN 服务器前缀，结果缓存在 [_cdnServer]。
  /// API 文档明确禁止硬编码子域名，CDN 服务器列表可能变动。
  Future<void> _fetchCdnServer() async {
    if (_cdnServer != null) return;
    try {
      // CDN 端点是公开的，不需要认证
      final res = await get('$baseUrl/api/v2/cdn');
      if (!res.error) {
        final data = const JsonDecoder().convert(res.data);
        // 实际响应字段名是 thumb_servers（用于缩略图），不是 servers
        final servers =
            (data['thumb_servers'] as List?) ?? (data['servers'] as List?);
        if (servers != null && servers.isNotEmpty) {
          _cdnServer = (servers.first as String).replaceAll(RegExp(r'/$'), '');
        }
      }
    } catch (_) {}
    // 若请求失败，回退到已知的 CDN 地址（历史观测值，作为兜底）
    _cdnServer ??= 'https://t.nhentai.net';
  }

  /// 从 cookieJar 读取 access_token 值。
  String _getAccessToken() {
    final jar = cookieJar;
    if (jar == null) return '';
    final cookies = jar.loadForRequest(Uri.parse(baseUrl));
    try {
      return cookies.firstWhere((c) => c.name == 'access_token').value;
    } catch (_) {
      return '';
    }
  }

  Future<Res<String>> get(String url,
      [Map<String, String>? extraHeaders]) async {
    if (_getOverride != null) return _getOverride!(url);
    if (cookieJar == null) {
      await init();
    }
    try {
      var res = await dio.get<String>(
        url,
        options: Options(
          followRedirects: false,
          headers: extraHeaders,
        ),
      );
      if (res.statusCode == 301 ||
          res.statusCode == 302 ||
          res.statusCode == 308) {
        final location = res.headers["Location"]?.first ??
            res.headers["location"]?.first ??
            "";
        // Location 可能是绝对 URL 或相对路径。
        // 不能用 Uri.replace(path:) —— 它会把 ? 当 path 字符 encode 成 %3F。
        final origin = Uri.parse(url).origin;
        final target =
            location.startsWith('http') ? location : '$origin$location';
        return get(target, extraHeaders);
      }
      return Res(res.data);
    } catch (e) {
      // NH 的传输失败无法从文案可靠区分类别，一律归 network（不猜登录）。
      return Res(null,
          errorMessage: e.toString(),
          errorCode: ResErrorCode.network,
          statusCode: e is DioException ? e.response?.statusCode : null);
    }
  }

  Future<Res<String>> post(String url, dynamic data,
      [Map<String, String>? headers]) async {
    if (cookieJar == null) {
      await init();
    }
    try {
      var res = await dio.post<String>(url,
          data: data, options: Options(headers: headers));
      return Res(res.data);
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  NhentaiComicBrief parseComic(Element comicDom) {
    var img = comicDom.querySelector("a > img")!.attributes["src"]!;
    var name = comicDom.querySelector("div.caption")!.text;
    var id = comicDom.querySelector("a")!.attributes["href"]!.nums;
    var lang = "Unknown";
    var tags = comicDom.attributes["data-tags"] ?? "";
    if (tags.contains("12227")) {
      lang = "English";
    } else if (tags.contains("6346")) {
      lang = "日本語";
    } else if (tags.contains("29963")) {
      lang = "中文";
    }
    var tagsRes = <String>[];
    for (var tag in tags.split(" ")) {
      if (nhentaiTags[tag] != null) {
        tagsRes.add(nhentaiTags[tag]!);
      }
    }
    return NhentaiComicBrief(name, img, id, lang, tagsRes);
  }

  List<T> removeNullValue<T extends Object>(List<T?> list) {
    while (list.remove(null)) {}
    return List.from(list);
  }

  Future<Res<NhentaiHomePageData>> getHomePage([int? page]) async {
    return getHomePageData(page ?? 1);
  }

  Future<Res<bool>> loadMoreHomePageData(NhentaiHomePageData data) async {
    final res = await getHomePageData(data.page + 1);
    if (res.error) return Res.fromErrorRes(res);
    if (res.data.latestError != null) {
      return Res.fromErrorRes(res.data.latestError!);
    }
    data.latest.addAll(res.data.latest);
    data.page = res.data.page;
    return const Res(true);
  }

  Future<Res<List<NhentaiComicBrief>>> search(String keyword, int page,
      [NhentaiSort sort = NhentaiSort.recent]) async {
    // 改用 v2 API，规避 HTML 抓取 data-tags 属性已消失导致标签/语言全空的问题
    await _fetchCdnServer();
    // 认证依赖 cookie interceptor，不发 Authorization header（access_token 值≠ v2 User Token）
    final res = await get(
      '$baseUrl/api/v2/search'
      '?query=${Uri.encodeComponent(keyword)}&page=$page&sort=${nhentaiSortParam(sort)}',
    );
    if (res.error) return Res.fromErrorRes(res);
    return _parseV2SearchResponse(res.data);
  }

  /// v2 search 响应解析（榜单与关键字搜索共用）。
  Res<List<NhentaiComicBrief>> _parseV2SearchResponse(String data) {
    try {
      final json = const JsonDecoder().convert(data);
      final rawResult = json is List ? json : json['result'];
      if (rawResult is! List) {
        return const Res.error('搜索响应缺少 result 数组',
            errorCode: ResErrorCode.parse);
      }
      final items = rawResult
          .whereType<Map<String, dynamic>>()
          .map(_parseV2GalleryItem)
          .whereType<NhentaiComicBrief>()
          .where((comic) => comic.id.isNotEmpty)
          .toList();
      if (rawResult.isNotEmpty && items.isEmpty) {
        return const Res.error('搜索响应非空但无有效条目', errorCode: ResErrorCode.parse);
      }
      final numPages =
          json is Map ? int.tryParse('${json['num_pages']}') ?? 1 : 1;
      return Res(items, subData: numPages);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res.error("Failed to Parse Data: $e",
          errorCode: ResErrorCode.parse);
    }
  }

  /// 热门榜单：空关键词 + 四种热门排序，走 `/api/v2/search`。
  ///
  /// 这是**榜单**语义，与首页 Popular 推荐块是两件事：首页 Popular 不冒充榜期。
  /// [sort] 必须是四种热门排序之一；传入 [NhentaiSort.recent] 属调用方错误。
  Future<Res<List<NhentaiComicBrief>>> getPopularRanking(
    NhentaiSort sort,
    int page,
  ) async {
    if (sort == NhentaiSort.recent) {
      return const Res.error('榜单不支持"最新"排序',
          errorCode: ResErrorCode.invalidArgument);
    }
    return search('', page, sort);
  }

  /// 语言分类：单个 `language:<lang>` 查询（**不把三种语言拼成一个字符串**）。
  Future<Res<List<NhentaiComicBrief>>> getLanguageComics(
    NhentaiLanguage language,
    int page, {
    NhentaiSort sort = NhentaiSort.recent,
  }) {
    return search('language:${language.tag}', page, sort);
  }

  /// 本地标签目录的具名搜索：**发送原始词**（不发送中文翻译）。
  ///
  /// 多词 / 标点 / 引号由 [buildNhentaiTagQuery] 统一组装，URI 编码由网络层
  /// 的 `Uri.encodeComponent` 完成。
  Future<Res<List<NhentaiComicBrief>>> searchTag(
    String rawTag,
    int page, {
    NhentaiSort sort = NhentaiSort.recent,
  }) {
    final query = buildNhentaiTagQuery(rawTag);
    if (query == null) {
      return Future.value(
          const Res.error('标签为空', errorCode: ResErrorCode.invalidArgument));
    }
    return search(query, page, sort);
  }

  /// 首页：Popular 推荐块（**仅第一页**）+ 最新列表。
  ///
  /// v2 列表直接提供 tag_ids；HTML 首页已经不再保证提供 data-tags。
  /// Popular 仍来自独立推荐端点，不用榜期搜索代替，也不逐本查详情。
  Future<Res<NhentaiHomePageData>> getHomePageData(int page) async {
    final normalizedPage = page < 1 ? 1 : page;
    await _fetchCdnServer();
    final responses = await Future.wait([
      _getV2List('$baseUrl/api/v2/galleries?page=$normalizedPage'),
      if (normalizedPage == 1) _getHomePopular(),
    ]);
    final latest = responses.first;
    final popular = normalizedPage == 1 ? responses[1] : null;
    return Res(
      NhentaiHomePageData(
        popular?.dataOrNull ?? <NhentaiComicBrief>[],
        latest.dataOrNull ?? <NhentaiComicBrief>[],
        popularError: popular?.error == true ? popular : null,
        latestError: latest.error ? latest : null,
      )..page = normalizedPage,
      subData: responses.first.subData,
    );
  }

  Future<Res<List<NhentaiComicBrief>>> getLatest(int page) async {
    await _fetchCdnServer();
    return _getV2List('$baseUrl/api/v2/galleries?page=$page');
  }

  Future<Res<List<NhentaiComicBrief>>> _getV2List(String url) async {
    final response = await get(url);
    if (response.error) return Res.fromErrorRes(response);
    return _parseV2SearchResponse(response.data);
  }

  Future<Res<List<NhentaiComicBrief>>> _getHomePopular() async {
    final response = await _getV2List('$baseUrl/api/v2/popular');
    // 仅兼容不存在的端点别名；429 / 登录 / 网络失败不额外重试。
    if (response.statusCode == 404 || response.statusCode == 405) {
      return _getV2List('$baseUrl/api/v2/galleries/popular');
    }
    return response;
  }

  /// 单本随机推荐。
  ///
  /// v2 随机端点已经返回完整标签，不需要再取一次详情页。
  Future<Res<NhentaiComicBrief>> getRandomComic() async {
    await _fetchCdnServer();
    final res = await get('$baseUrl/api/v2/galleries/random');
    if (res.error) return Res.fromErrorRes(res);
    try {
      final json = const JsonDecoder().convert(res.data);
      final comic =
          json is Map<String, dynamic> ? _parseV2GalleryItem(json) : null;
      if (comic == null) {
        return const Res.error('随机推荐未返回有效 id', errorCode: ResErrorCode.parse);
      }
      return Res(comic);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res.error("Failed to Parse Data: $e",
          errorCode: ResErrorCode.parse);
    }
  }

  Future<Res<NhentaiComic>> getComicInfo(String id) async {
    Res<String> res;
    if (id == "") {
      res = await get("$baseUrl/random");
      if (res.error) {
        return Res.fromErrorRes(res);
      }
    } else {
      res = await get("$baseUrl/g/$id/");
    }
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      String combineSpans(Element? title) {
        var res = "";
        for (var span in title?.children ?? []) {
          res += span.text;
        }
        return res;
      }

      var document = parse(res.data);

      id = id == "" ? document.querySelector("h3#gallery_id")!.text.nums : id;

      var cover =
          document.querySelector("div#cover > a > img")!.attributes["src"]!;

      var title = combineSpans(document.querySelector("h1.title")!);

      var subTitle = combineSpans(document.querySelector("h2.title"));

      Map<String, List<String>> tags = {};
      for (var field in document.querySelectorAll("div.tag-container")) {
        var fieldName =
            field.firstChild!.text!.removeAllBlank.replaceLast(":", "");
        if (fieldName == "Uploaded") {
          var timeStr = document.querySelector("time")?.attributes["datetime"];
          if (timeStr != null) {
            tags["时间".tl] = [_nhTimeToString(DateTime.parse(timeStr))];
            continue;
          }
        }
        tags[fieldName] = [];
        for (var span in field.querySelectorAll("span.name")) {
          tags[fieldName]!.add(span.text);
        }
      }

      bool favorite =
          document.querySelector("button#favorite > span.text")?.text !=
                  "Favorite" &&
              logged;

      var thumbnails = <String>[];
      for (var t in document.querySelectorAll("a.gallerythumb > img")) {
        thumbnails.add(t.attributes["src"]!);
      }

      var recommendations = <NhentaiComicBrief>[];
      for (var comic in document.querySelectorAll("div.gallery")) {
        var c = parseComic(comic);
        recommendations.add(c);
      }
      String token = "";
      try {
        var script = document
            .querySelectorAll("script")
            .firstWhere((element) => element.text.contains("csrf_token"))
            .text;
        token = script.split("csrf_token: \"")[1].split("\",")[0];
      } catch (e) {
        // ignore
      }
      // Fallback：script 解析失败时从 cookie jar 读 csrftoken cookie。
      // Django 同时以非 httpOnly cookie 下发 CSRF token，jar 里一定有。
      if (token.isEmpty) token = getCsrfToken();

      return Res(NhentaiComic(id, title, subTitle, cover, tags, favorite,
          thumbnails, recommendations, token));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null,
          errorMessage: "Failed to Parse Data: $e",
          errorCode: ResErrorCode.parse);
    }
  }

  Future<Res<List<NhentaiComment>>> getComments(String id) async {
    // nhentai 已废弃旧的 /api/gallery/{id}/comments（返回 403 + "Use new API"）。
    // 新 API：GET /api/v2/galleries/{id}/comments，返回 {result:[...], num_pages, ...}。
    var res = await get("$baseUrl/api/v2/galleries/$id/comments");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var json = const JsonDecoder().convert(res.data);
      // v2 把评论数组包在 result 字段里（旧版是裸数组），做兼容取值。
      var list = json is Map ? (json["result"] as List? ?? const []) : json;
      var comments = <NhentaiComment>[];
      for (var c in list) {
        var avatar = c["poster"]?["avatar_url"]?.toString() ?? "";
        // avatar_url 可能已是完整 URL，也可能是相对路径，后者才拼 CDN 前缀。
        if (avatar.isNotEmpty && !avatar.startsWith("http")) {
          avatar = "https://i3.nhentai.net/$avatar";
        }
        comments.add(NhentaiComment(
            c["poster"]?["username"]?.toString() ?? "",
            avatar,
            c["body"]?.toString() ?? "",
            (c["post_date"] as num?)?.toInt() ?? 0));
      }
      return Res(comments);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null,
          errorMessage: "Failed to Parse Data: $e",
          errorCode: ResErrorCode.parse);
    }
  }

  Future<Res<List<String>>> getImages(String id) async {
    var res = await get("$baseUrl/g/$id/1/");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);
      var scripts = document.querySelectorAll("script");

      var script = scripts
          .firstWhere((element) => element.text.contains("media_id"))
          .text;

      var galleryData = json.decode(json.decode(script)["body"]);

      var url = document
          .querySelector("#image-container > a > img")!
          .attributes["src"]!;

      String baseUrl = url.split('/galleries')[0];

      var images = <String>[];
      for (var image in galleryData["pages"]) {
        images.add("$baseUrl/${image["path"]}");
      }

      return Res(images);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null,
          errorMessage: "Failed to Parse Data: $e",
          errorCode: ResErrorCode.parse);
    }
  }

  // ── v2 收藏列表（带 token 刷新）──────────────────────────────────────
  Future<Res<List<NhentaiComicBrief>>> getFavorites(int page) async {
    if (cookieJar == null) await init();
    if (!logged) {
      return const Res(null,
          errorMessage: 'login required',
          errorCode: ResErrorCode.loginRequired);
    }
    await _fetchCdnServer();

    // 首次尝试
    final token = _getAccessToken();
    if (token.isEmpty) {
      return const Res(null,
          errorMessage: 'login required',
          errorCode: ResErrorCode.loginRequired);
    }

    final res = await get(
      '$baseUrl/api/v2/favorites?page=$page',
      {'Authorization': 'User $token'},
    );

    // 若401，尝试刷新 token 后重试一次
    if (res.error &&
        res.errorMessage != null &&
        res.errorMessage!.contains('401')) {
      final newToken = await _refreshAccessToken();
      if (newToken.isEmpty) {
        return const Res(null, errorMessage: 'Token expired, please re-login');
      }
      final retryRes = await get(
        '$baseUrl/api/v2/favorites?page=$page',
        {'Authorization': 'User $newToken'},
      );
      if (retryRes.error) return Res.fromErrorRes(retryRes);
      return _parseFavoritesV2(retryRes.data);
    }

    if (res.error) return Res.fromErrorRes(res);
    return _parseFavoritesV2(res.data);
  }

  /// 解析 v2 favorites 响应
  Res<List<NhentaiComicBrief>> _parseFavoritesV2(String data) {
    return _parseV2SearchResponse(data);
  }

  /// v2 GalleryListItem → NhentaiComicBrief
  NhentaiComicBrief? _parseV2GalleryItem(Map<String, dynamic> e) {
    return parseNhentaiV2Gallery(
      e,
      cdnServer: _cdnServer ?? 'https://t.nhentai.net',
    );
  }

  // ── v2 收藏/取消收藏（替代旧版 /api/gallery/{id}/favorite）────────────────
  Future<Res<bool>> favoriteComic(String id, String token) async {
    final accessToken = _getAccessToken();
    if (accessToken.isNotEmpty) {
      try {
        final res = await dio.post<String>(
          '$baseUrl/api/v2/galleries/$id/favorite',
          options: Options(
            validateStatus: (s) => s != null && s < 500,
            headers: {'Authorization': 'User $accessToken'},
          ),
        );
        if (res.statusCode == 200) return const Res(true);
      } catch (_) {}
    }
    // 旧版 CSRF fallback
    final res = await post('$baseUrl/api/gallery/$id/favorite', null, {
      'Referer': '$baseUrl/g/$id',
      'X-Csrftoken': token,
      'X-Requested-With': 'XMLHttpRequest',
    });
    return res.error ? Res.fromErrorRes(res) : const Res(true);
  }

  Future<Res<bool>> unfavoriteComic(String id, String token) async {
    final accessToken = _getAccessToken();
    if (accessToken.isNotEmpty) {
      try {
        final res = await dio.delete<String>(
          '$baseUrl/api/v2/galleries/$id/favorite',
          options: Options(
            validateStatus: (s) => s != null && s < 500,
            headers: {'Authorization': 'User $accessToken'},
          ),
        );
        if (res.statusCode == 200) return const Res(true);
      } catch (_) {}
    }
    // 旧版 CSRF fallback
    final res = await post('$baseUrl/api/gallery/$id/unfavorite', null, {
      'Referer': '$baseUrl/g/$id',
      'X-Csrftoken': token,
      'X-Requested-With': 'XMLHttpRequest',
    });
    return res.error ? Res.fromErrorRes(res) : const Res(true);
  }

  Future<Res<List<NhentaiComicBrief>>> getCategoryComics(
      String path, int page, NhentaiSort sort) async {
    var param = switch (sort) {
      NhentaiSort.recent => '/',
      NhentaiSort.popularToday => '/popular-today',
      NhentaiSort.popularWeek => '/popular-week',
      NhentaiSort.popularMonth => '/popular-month',
      NhentaiSort.popularAll => '/popular'
    };
    var res = await get("$baseUrl$path$param?page=$page");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);

      var comicDoms = document.querySelectorAll("div.gallery");

      var lastPagination = document
          .querySelector("section.pagination > a.last")
          ?.attributes["href"]
          ?.nums;

      if (comicDoms.isEmpty) {
        return const Res([], subData: 0);
      }

      return Res(
          removeNullValue(List.generate(
              comicDoms.length, (index) => parseComic(comicDoms[index]))),
          subData: lastPagination == null ? 1 : int.parse(lastPagination));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null,
          errorMessage: "Failed to Parse Data: $e",
          errorCode: ResErrorCode.parse);
    }
  }
}

enum NhentaiSort {
  recent(""),
  popularToday("&sort=popular-today"),
  popularWeek("&sort=popular-week"),
  popularMonth("&sort=popular-month"),
  popularAll("&sort=popular");

  final String value;

  const NhentaiSort(this.value);

  /// 旧搜索页选项的兼容解析：只认 `&sort=` 前缀形态。
  ///
  /// 探索**不要**把裸稳定 ID 送进来 —— 用 [nhentaiSortFromOptionId]。
  static NhentaiSort fromValue(String value) {
    switch (value) {
      case "":
        return NhentaiSort.recent;
      case "&sort=popular-today":
        return NhentaiSort.popularToday;
      case "&sort=popular-week":
        return NhentaiSort.popularWeek;
      case "&sort=popular-month":
        return NhentaiSort.popularMonth;
      case "&sort=popular":
        return NhentaiSort.popularAll;
      default:
        return NhentaiSort.recent;
    }
  }
}

/// 探索使用的**裸稳定 option ID** → v2 API 的 sort 参数值。
///
/// 实现在纯 Dart 的 `nhentai_explore_options.dart`：这里只做转发，让纯层测试
/// 不必 import 本文件（本文件依赖 Flutter）。
String? nhentaiSortParamForOptionId(String optionId) =>
    nhentaiSortOptionIdToParam[optionId.trim()];

/// 裸稳定 option ID → [NhentaiSort]；未知返回 `null`（不静默回落）。
NhentaiSort? nhentaiSortFromOptionId(String optionId) {
  switch (optionId.trim()) {
    case NhentaiSortOptionIds.recent:
      return NhentaiSort.recent;
    case NhentaiSortOptionIds.popularToday:
      return NhentaiSort.popularToday;
    case NhentaiSortOptionIds.popularWeek:
      return NhentaiSort.popularWeek;
    case NhentaiSortOptionIds.popularMonth:
      return NhentaiSort.popularMonth;
    case NhentaiSortOptionIds.popularAll:
      return NhentaiSort.popularAll;
    default:
      return null;
  }
}

/// [NhentaiSort] → v2 API 的 sort 查询参数值。
String nhentaiSortParam(NhentaiSort sort) {
  switch (sort) {
    case NhentaiSort.recent:
      return 'date';
    case NhentaiSort.popularToday:
      return 'popular-today';
    case NhentaiSort.popularWeek:
      return 'popular-week';
    case NhentaiSort.popularMonth:
      return 'popular-month';
    case NhentaiSort.popularAll:
      return 'popular';
  }
}

/// NH 语言分类。**只允许这三种**，分别生成单个 `language:<tag>` 查询。
enum NhentaiLanguage {
  chinese(NhentaiLanguageIds.chinese, '中文'),
  japanese(NhentaiLanguageIds.japanese, '日本語'),
  english(NhentaiLanguageIds.english, 'English');

  const NhentaiLanguage(this.tag, this.label);

  final String tag;
  final String label;

  static NhentaiLanguage? tryFromId(String id) {
    for (final language in NhentaiLanguage.values) {
      if (language.name == id) return language;
    }
    return null;
  }
}
