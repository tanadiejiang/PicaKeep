import 'dart:convert';
import 'dart:io' show Cookie;
import 'package:dio/dio.dart';
import 'package:html/dom.dart';
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

class NhentaiNetwork {
  factory NhentaiNetwork() => _cache ?? (_cache = NhentaiNetwork._create());

  NhentaiNetwork._create();

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

  void logout() async {
    logged = false;
    // 清除新版 JWT token cookie（access_token + refresh_token）。
    final uri = Uri.parse(baseUrl);
    cookieJar!.delete(uri, "access_token");
    cookieJar!.delete(uri, "refresh_token");
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
        final servers = (data['thumb_servers'] as List?) ?? (data['servers'] as List?);
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

  Future<Res<String>> get(String url, [Map<String, String>? extraHeaders]) async {
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
      if (res.statusCode == 301 || res.statusCode == 302 || res.statusCode == 308) {
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
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<String>> post(String url, dynamic data,
      [Map<String, String>? headers]) async {
    if (cookieJar == null) {
      await init();
    }
    try {
      var res =
          await dio.post<String>(url, data: data, options: Options(headers: headers));
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
    var url = baseUrl;
    if (page != null && page != 1) {
      url = "$url?page=$page";
    }
    var res = await get(url);
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);
      List<Element> popularDoms;
      if (url == baseUrl) {
        popularDoms = document.querySelectorAll(
            "div.container.index-container.index-popular > div.gallery");
      } else {
        popularDoms = const [];
      }
      var latest = document
          .querySelectorAll("div.container.index-container > div.gallery");

      return Res(NhentaiHomePageData(
        removeNullValue(List.generate(
            popularDoms.length, (index) => parseComic(popularDoms[index]))),
        removeNullValue(List.generate(latest.length - popularDoms.length,
            (index) => parseComic(latest[index + popularDoms.length]))),
      ));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  Future<Res<bool>> loadMoreHomePageData(NhentaiHomePageData data) async {
    var res = await get("$baseUrl?page=${data.page + 1}");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);

      var latest = document.querySelectorAll("div.gallery");

      data.latest.addAll(removeNullValue(
          List.generate(latest.length, (index) => parseComic(latest[index]))));

      data.page++;

      return const Res(true);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  Future<Res<List<NhentaiComicBrief>>> search(String keyword, int page,
      [NhentaiSort sort = NhentaiSort.recent]) async {
    // 改用 v2 API，规避 HTML 抓取 data-tags 属性已消失导致标签/语言全空的问题
    await _fetchCdnServer();
    // 认证依赖 cookie interceptor，不发 Authorization header（access_token 值≠ v2 User Token）
    final sortParam = switch (sort) {
      NhentaiSort.recent        => 'date',
      NhentaiSort.popularToday  => 'popular-today',
      NhentaiSort.popularWeek   => 'popular-week',
      NhentaiSort.popularMonth  => 'popular-month',
      NhentaiSort.popularAll    => 'popular',
    };
    final res = await get(
      '$baseUrl/api/v2/search'
      '?query=${Uri.encodeComponent(keyword)}&page=$page&sort=$sortParam',
    );
    if (res.error) return Res.fromErrorRes(res);
    try {
      final json = const JsonDecoder().convert(res.data);
      final items = (json['result'] as List)
          .map((e) => _parseV2GalleryItem(e as Map<String, dynamic>))
          .whereType<NhentaiComicBrief>()
          .toList();
      final numPages = (json['num_pages'] as num?)?.toInt() ?? 1;
      return Res(items, subData: numPages);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
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
      return Res(null, errorMessage: "Failed to Parse Data: $e");
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
      return Res(null, errorMessage: "Failed to Parse Data: $e");
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
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  // ── v2 收藏列表（带 token 刷新）──────────────────────────────────────
  Future<Res<List<NhentaiComicBrief>>> getFavorites(int page) async {
    if (cookieJar == null) await init();
    if (!logged) return const Res(null, errorMessage: 'login required');
    await _fetchCdnServer();

    // 首次尝试
    final token = _getAccessToken();
    if (token.isEmpty) return const Res(null, errorMessage: 'login required');

    final res = await get(
      '$baseUrl/api/v2/favorites?page=$page',
      {'Authorization': 'User $token'},
    );

    // 若401，尝试刷新 token 后重试一次
    if (res.error && res.errorMessage != null && res.errorMessage!.contains('401')) {
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
    try {
      final json = const JsonDecoder().convert(data);
      final items = (json['result'] as List)
          .map((e) => _parseV2GalleryItem(e as Map<String, dynamic>))
          .whereType<NhentaiComicBrief>()
          .toList();
      final numPages = (json['num_pages'] as num?)?.toInt() ?? 1;
      return Res(items, subData: numPages);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'Data Analyse', '$e\n$s');
      return Res(null, errorMessage: 'Failed to Parse Data: $e');
    }
  }

  /// v2 GalleryListItem → NhentaiComicBrief
  NhentaiComicBrief? _parseV2GalleryItem(Map<String, dynamic> e) {
    try {
      final id = e['id'].toString();
      final title = (e['english_title'] as String?)?.trim().isNotEmpty == true
          ? e['english_title'] as String
          : (e['japanese_title'] as String?) ?? id;
      // thumbnail 是相对路径，拼动态 CDN 前缀（由 _fetchCdnServer 预取）
      final rawCover = (e['thumbnail'] as String?) ?? '';
      final cdn = (_cdnServer ?? 'https://t.nhentai.net').replaceAll(RegExp(r'/$'), '');
      final cover = rawCover.startsWith('http')
          ? rawCover
          : '$cdn/${rawCover.replaceAll(RegExp(r'^/+'), '')}';
      final tagIdList = (e['tag_ids'] as List?) ?? [];
      // 只保留 nhentaiTags 里有英文名的 tag，过滤掉未知数字 ID
      final tagIds = tagIdList
          .map((t) => nhentaiTags[t.toString()])
          .whereType<String>()
          .toList();
      // 语言直接从 tag_ids 判断（比对 nhentai 语言 tag ID）
      const langTagIds = {'12227': 'English', '6346': '日本語', '29963': '中文'};
      String lang = 'Unknown';
      for (final t in tagIdList) {
        final mapped = langTagIds[t.toString()];
        if (mapped != null) { lang = mapped; break; }
      }
      return NhentaiComicBrief(title, cover, id, lang, tagIds);
    } catch (_) {
      return null;
    }
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
      return Res(null, errorMessage: "Failed to Parse Data: $e");
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
