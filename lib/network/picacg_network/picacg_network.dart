import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:picakeep/comic_source/built_in/picacg.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/app_dio.dart';
import 'package:picakeep/network/res.dart';

import 'headers.dart';
import 'models.dart';
import 'picacg_parsing.dart';

export 'models.dart';

// 探索相关的纯解析已下沉到 picacg_parsing.dart：本文件依赖 Flutter 与
// comic_source/built_in/picacg.dart，解析留在里面会让纯层测试无法用
// `dart test` 运行。这里再导出一次，既有 import 点无需改动。
export 'picacg_parsing.dart';

class PicacgNetwork {
  factory PicacgNetwork() => _cache ??= PicacgNetwork._create();

  PicacgNetwork._create() {
    final userJson = picacg.data['user'];
    if (userJson is Map) {
      user = PicacgProfile.fromJson(userJson);
    }
  }

  static PicacgNetwork? _cache;

  final String apiUrl = 'https://picaapi.picacomic.com';

  String get token => picacg.data['token']?.toString() ?? '';

  PicacgProfile? user;

  Future<Res<Map<String, dynamic>>> _request(
    String method,
    String url, {
    Map<String, dynamic>? data,
    bool allowAnonymous = false,
    bool retryingLogin = false,
    bool noRetry = false,
  }) async {
    if (!allowAnonymous && token.isEmpty) {
      return const Res.error('未登录', errorCode: ResErrorCode.loginRequired);
    }
    final path = url.replaceFirst('$apiUrl/', '');
    final dio = logDio(picacgHeaders(method, token, path));
    try {
      final response = await dio.request<String>(
        url,
        data: data,
        options: Options(
          method: method,
          responseType: ResponseType.plain,
          extra: {'noRetry': noRetry},
          validateStatus: (status) =>
              status == 200 || status == 400 || status == 401,
        ),
      );
      final body = response.data;
      if (body == null || body.isEmpty) {
        return const Res.error('Empty response');
      }
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      if (response.statusCode == 200) {
        return Res(decoded);
      }
      if (response.statusCode == 401 && !allowAnonymous && !retryingLogin) {
        final reLogin = await picacg.reLogin();
        if (reLogin.success) {
          return _request(
            method,
            url,
            data: data,
            allowAnonymous: allowAnonymous,
            retryingLogin: true,
          );
        }
        return Res.error('登录失效且重新登录失败: ${reLogin.errorMessageWithoutNull}',
            errorCode: ResErrorCode.loginRequired, statusCode: 401);
      }
      return Res.error(
        decoded['message']?.toString() ??
            'Invalid Status Code ${response.statusCode}',
        // 400/401 之外的 4xx/5xx：传输层失败，不猜成登录问题。
        errorCode: response.statusCode == 401
            ? ResErrorCode.loginRequired
            : ResErrorCode.network,
        statusCode: response.statusCode,
      );
    } on DioException catch (error) {
      return Res.error(_dioErrorMessage(error),
          errorCode: ResErrorCode.network,
          statusCode: error.response?.statusCode);
    } catch (error, stackTrace) {
      LogManager.addLog(
        LogLevel.error,
        'PicacgNetwork',
        '$error\n$stackTrace',
      );
      return Res.error(error.toString(), errorCode: ResErrorCode.parse);
    }
  }

  String _dioErrorMessage(DioException error) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return '连接超时';
    }
    return error.message ?? error.toString();
  }

  Future<Res<Map<String, dynamic>>> get(String url) {
    return _request('GET', url);
  }

  Future<Res<Map<String, dynamic>>> post(
    String url,
    Map<String, dynamic>? data, {
    bool allowAnonymous = false,
    bool noRetry = false,
  }) {
    return _request(
      'POST',
      url,
      data: data,
      allowAnonymous: allowAnonymous,
      noRetry: noRetry,
    );
  }

  Future<Res<String>> login(String email, String password) async {
    final response = await post(
      '$apiUrl/auth/sign-in',
      {'email': email, 'password': password},
      allowAnonymous: true,
      noRetry: true,
    );
    if (response.error) {
      return Res.fromErrorRes(response);
    }
    final token = response.data['data']?['token']?.toString();
    if (token == null || token.isEmpty) {
      return const Res.error('Failed to get token');
    }
    return Res(token);
  }

  Future<Res<bool>> loginFromStoredCredentials() async {
    final account = picacg.data['account'];
    if (account is! List || account.length < 2) {
      return const Res.error('没有已保存的账号密码');
    }
    final loginRes = await login(account[0].toString(), account[1].toString());
    if (loginRes.error) {
      return Res.fromErrorRes(loginRes);
    }
    picacg.data['token'] = loginRes.data;
    final profileRes = await updateProfile();
    if (profileRes.error) {
      return Res.fromErrorRes(profileRes);
    }
    await picacg.saveData();
    return const Res(true);
  }

  Future<Res<PicacgProfile>> getProfile() async {
    final response = await get('$apiUrl/users/profile');
    if (response.error) {
      return Res.fromErrorRes(response);
    }
    try {
      final userJson = response.data['data']['user'] as Map;
      return Res(PicacgProfile.fromApi(userJson));
    } catch (error, stackTrace) {
      LogManager.addLog(
        LogLevel.error,
        'PicacgNetwork',
        'Failed to parse profile: $error\n$stackTrace',
      );
      return Res.error(error.toString());
    }
  }

  Future<Res<bool>> updateProfile() async {
    if (token.isEmpty) {
      return const Res(true);
    }
    final response = await getProfile();
    if (response.error) {
      return Res.fromErrorRes(response);
    }
    user = response.data;
    picacg.data['user'] = user!.toJson();
    await picacg.saveData();
    return const Res(true);
  }

  Future<Res<List<PicacgComicItemBrief>>> search(
    String keyword,
    String sort,
    int page,
  ) async {
    final response = await post(
      '$apiUrl/comics/advanced-search?page=$page',
      {'keyword': keyword, 'sort': sort},
    );
    if (response.error) {
      return Res.fromErrorRes(response);
    }
    return _parseComicList(response.data['data']?['comics']);
  }

  Future<Res<PicacgComicItem>> getComicInfo(String id) async {
    final results = await Future.wait([
      get('$apiUrl/comics/$id'),
      getEps(id),
      getRecommendation(id),
    ]);
    final detailRes = results[0] as Res<Map<String, dynamic>>;
    final epsRes = results[1] as Res<List<String>>;
    final recommendationRes = results[2] as Res<List<PicacgComicItemBrief>>;
    if (detailRes.error) return Res.fromErrorRes(detailRes);
    if (epsRes.error) return Res.fromErrorRes(epsRes);
    try {
      final comicJson = detailRes.data['data']['comic'] as Map;
      return Res(PicacgComicItem.fromApi(
        json: comicJson,
        eps: epsRes.data,
        recommendation: recommendationRes.dataOrNull ?? const [],
      ));
    } catch (error, stackTrace) {
      LogManager.addLog(
        LogLevel.error,
        'PicacgNetwork',
        'Failed to parse comic detail: $error\n$stackTrace',
      );
      return Res.error(error.toString());
    }
  }

  Future<Res<List<String>>> getEps(String id) async {
    final eps = <String>[];
    var page = 0;
    var hasMore = true;
    while (hasMore) {
      page++;
      final response = await get('$apiUrl/comics/$id/eps?page=$page');
      if (response.error) {
        return Res.fromErrorRes(response);
      }
      try {
        final epsJson = response.data['data']['eps'];
        final pages = epsJson['pages'] as int;
        hasMore = page < pages;
        for (final item in epsJson['docs'] as List) {
          eps.add((item as Map)['title']?.toString() ?? '$page');
        }
      } catch (error, stackTrace) {
        LogManager.addLog(
          LogLevel.error,
          'PicacgNetwork',
          'Failed to parse eps: $error\n$stackTrace',
        );
        return Res.error(error.toString());
      }
    }
    return Res(eps.reversed.toList(growable: false));
  }

  Future<Res<List<String>>> getComicContent(String id, int order) async {
    final imageUrls = <String>[];
    var page = 0;
    var hasMore = true;
    while (hasMore) {
      page++;
      final response =
          await get('$apiUrl/comics/$id/order/$order/pages?page=$page');
      if (response.error) {
        return Res.fromErrorRes(response);
      }
      try {
        final pagesJson = response.data['data']['pages'];
        final pages = pagesJson['pages'] as int;
        hasMore = page < pages;
        for (final item in pagesJson['docs'] as List) {
          imageUrls.add(picacgImageUrl((item as Map)['media'] as Map?));
        }
      } catch (error, stackTrace) {
        LogManager.addLog(
          LogLevel.error,
          'PicacgNetwork',
          'Failed to parse images: $error\n$stackTrace',
        );
        return Res.error(error.toString());
      }
    }
    return Res(imageUrls.where((url) => url.isNotEmpty).toList());
  }

  Future<Res<List<PicacgComicItemBrief>>> getFavorites(int page) async {
    final response = await get('$apiUrl/users/favourite?s=dd&page=$page');
    if (response.error) {
      return Res.fromErrorRes(response);
    }
    return _parseComicList(response.data['data']?['comics']);
  }

  Future<Res<bool>> favouriteOrUnfavouriteComic(String id) async {
    final response = await post('$apiUrl/comics/$id/favourite', {});
    if (response.error) {
      return Res.fromErrorRes(response);
    }
    return const Res(true);
  }

  Future<Res<List<PicacgComicItemBrief>>> getRecommendation(String id) async {
    final response = await get('$apiUrl/comics/$id/recommendation');
    if (response.error) {
      return Res.fromErrorRes(response);
    }
    try {
      final comics = response.data['data']?['comics'];
      if (comics is! List) {
        return const Res([]);
      }
      return Res(comics
          .whereType<Map>()
          .map(PicacgComicItemBrief.fromApi)
          .where((comic) => comic.id.isNotEmpty)
          .toList());
    } catch (error, stackTrace) {
      LogManager.addLog(
        LogLevel.error,
        'PicacgNetwork',
        'Failed to parse recommendation: $error\n$stackTrace',
      );
      return Res.error(error.toString());
    }
  }

  /// 点赞或取消点赞漫画（toggle）。
  Future<Res<bool>> likeOrUnlikeComic(String id) async {
    final res = await post('$apiUrl/comics/$id/like', {});
    if (res.error) return Res.fromErrorRes(res);
    return const Res(true);
  }

  /// 获取漫画评论列表（分页）。subData 为总页数（int）。
  Future<Res<List<PicacgComment>>> getComments(String id, int page) async {
    final res = await get('$apiUrl/comics/$id/comments?page=$page');
    if (res.error) return Res.fromErrorRes(res);
    try {
      final data = res.data['data']['comments'] as Map;
      final totalPages = (data['pages'] as num).toInt();
      final docs = data['docs'] as List;
      final comments =
          docs.whereType<Map>().map(PicacgComment.fromApi).toList();
      return Res(comments, subData: totalPages);
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, 'PicacgNetwork', 'Failed to parse comments: $e\n$s');
      return Res.error(e.toString());
    }
  }

  /// 发送顶级评论（非回复）。
  Future<Res<bool>> sendComment(String id, String content) async {
    final res = await post('$apiUrl/comics/$id/comments', {'content': content});
    if (res.error) return Res.fromErrorRes(res);
    return const Res(true);
  }

  /// 发送回复（回复某条评论）。路径用评论 ID，与顶级评论不同。
  Future<Res<bool>> sendReply(String commentId, String content) async {
    final res = await post('$apiUrl/comments/$commentId', {'content': content});
    if (res.error) return Res.fromErrorRes(res);
    return const Res(true);
  }

  /// 点赞或取消点赞评论（toggle）。
  Future<Res<bool>> likeOrUnlikeComment(String commentId) async {
    final res = await post('$apiUrl/comments/$commentId/like', {});
    if (res.error) return Res.fromErrorRes(res);
    return const Res(true);
  }

  /// 获取评论回复列表（分页）。subData 为总页数。
  Future<Res<List<PicacgComment>>> getReply(String commentId, int page) async {
    final res = await get('$apiUrl/comments/$commentId/childrens?page=$page');
    if (res.error) return Res.fromErrorRes(res);
    try {
      final data = res.data['data']['comments'] as Map;
      final totalPages = (data['pages'] as num).toInt();
      final docs = data['docs'] as List;
      final comments =
          docs.whereType<Map>().map(PicacgComment.fromApi).toList();
      return Res(comments, subData: totalPages);
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, 'PicacgNetwork', 'Failed to parse reply: $e\n$s');
      return Res.error(e.toString());
    }
  }

  Res<List<PicacgComicItemBrief>> _parseComicList(Object? comicsJson) {
    try {
      final docs = (comicsJson as Map)['docs'] as List;
      final pages = comicsJson['pages'];
      final comics = docs
          .whereType<Map>()
          .map(PicacgComicItemBrief.fromApi)
          .where((comic) => comic.id.isNotEmpty)
          .toList();
      return Res(comics, subData: pages);
    } catch (error, stackTrace) {
      LogManager.addLog(
        LogLevel.error,
        'PicacgNetwork',
        'Failed to parse comic list: $error\n$stackTrace',
      );
      return Res.error(error.toString(), errorCode: ResErrorCode.parse);
    }
  }

  // ── 探索：分类 / 榜单 / 随机 / 集合 / 最新 ────────────────────────────────

  /// 分类目录 `GET /categories`。
  ///
  /// 过滤掉 `isWeb` 的外部网页类；条目保留**服务器原始 title** —— 展示可以翻译，
  /// 但发请求时必须原样回传 `c=<title>`。
  Future<Res<List<PicacgCategoryItem>>> getCategories() async {
    final response = await get('$apiUrl/categories');
    if (response.error) return Res.fromErrorRes(response);
    try {
      return Res(parsePicacgCategories(response.data['data']));
    } catch (error, stackTrace) {
      LogManager.addLog(LogLevel.error, 'PicacgNetwork',
          'Failed to parse categories: $error\n$stackTrace');
      return Res.error('目录解析失败：$error', errorCode: ResErrorCode.parse);
    }
  }

  /// 分类结果 `GET /comics?page=&c=<原始 title>&s=<dd/da/ld/vd>`（1 起页）。
  Future<Res<List<PicacgComicItemBrief>>> getCategoryComics(
    String categoryTitle,
    String sort,
    int page,
  ) async {
    final title = categoryTitle.trim();
    if (title.isEmpty) {
      return const Res.error('分类名为空', errorCode: ResErrorCode.invalidArgument);
    }
    if (!picacgSorts.contains(sort)) {
      return Res.error('未知排序：$sort', errorCode: ResErrorCode.invalidArgument);
    }
    final response = await get(
      '$apiUrl/comics?page=$page&c=${Uri.encodeComponent(title)}&s=$sort',
    );
    if (response.error) return Res.fromErrorRes(response);
    return _parseComicDocs(response.data['data']?['comics']);
  }

  /// 最新 `GET /comics?page=&s=dd`。**必须保留 pages**。
  Future<Res<List<PicacgComicItemBrief>>> getLatest(int page) async {
    final response = await get('$apiUrl/comics?page=$page&s=dd');
    if (response.error) return Res.fromErrorRes(response);
    return _parseComicDocs(response.data['data']?['comics']);
  }

  /// 随机 `GET /comics/random`，`data.comics[]` 是**数组**。单页。
  Future<Res<List<PicacgComicItemBrief>>> getRandomComics() async {
    final response = await get('$apiUrl/comics/random');
    if (response.error) return Res.fromErrorRes(response);
    return _parseComicArray(response.data['data']?['comics']);
  }

  /// 榜单 `GET /comics/leaderboard?tt=<period>&ct=VC`，单页。
  ///
  /// [period] 必须是 H24 / D7 / D30；不虚构"总榜"。
  Future<Res<List<PicacgComicItemBrief>>> getLeaderboard(String period) async {
    if (!picacgLeaderboardPeriods.contains(period)) {
      return Res.error('未知榜期：$period', errorCode: ResErrorCode.invalidArgument);
    }
    final response = await get('$apiUrl/comics/leaderboard?tt=$period&ct=VC');
    if (response.error) return Res.fromErrorRes(response);
    return _parseComicArray(response.data['data']?['comics']);
  }

  /// 推荐集合 `GET /collections`：**所有真实分组**（不照抄上游固定两组）。
  Future<Res<List<PicacgCollection>>> getCollections() async {
    final response = await get('$apiUrl/collections');
    if (response.error) return Res.fromErrorRes(response);
    try {
      return Res(parsePicacgCollections(response.data['data']));
    } catch (error, stackTrace) {
      LogManager.addLog(LogLevel.error, 'PicacgNetwork',
          'Failed to parse collections: $error\n$stackTrace');
      return Res.error('推荐集合解析失败：$error', errorCode: ResErrorCode.parse);
    }
  }

  /// ``docs/pages`` 容器解析。
  ///
  /// 字段缺失/类型错 → parse；`docs: []` 是合法空成功。
  Res<List<PicacgComicItemBrief>> _parseComicDocs(Object? comicsJson) {
    if (comicsJson is! Map) {
      return const Res.error('分类响应缺少 comics 对象', errorCode: ResErrorCode.parse);
    }
    final docsRaw = comicsJson['docs'];
    if (docsRaw is! List) {
      return const Res.error('分类响应缺少 docs 数组', errorCode: ResErrorCode.parse);
    }
    final parsed = parsePicacgComicDocs(docsRaw);
    if (docsRaw.isNotEmpty && parsed.parsed.isEmpty) {
      return const Res.error('分类响应非空但无有效条目', errorCode: ResErrorCode.parse);
    }
    return Res(parsed.parsed, subData: comicsJson['pages']);
  }

  /// 裸数组容器解析（榜单 / 随机）。`[]` 是空成功，全坏项是 parse。
  Res<List<PicacgComicItemBrief>> _parseComicArray(Object? comicsJson) {
    if (comicsJson is! List) {
      return const Res.error('榜单响应缺少 comics 数组', errorCode: ResErrorCode.parse);
    }
    final parsed = parsePicacgComicDocs(comicsJson);
    if (comicsJson.isNotEmpty && parsed.parsed.isEmpty) {
      return const Res.error('榜单响应非空但无有效条目', errorCode: ResErrorCode.parse);
    }
    return Res(parsed.parsed);
  }
}
