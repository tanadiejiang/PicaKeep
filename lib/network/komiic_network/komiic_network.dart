import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/app_dio.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/network/network_error_text.dart';

import 'komiic_graphql.dart';
import 'komiic_models.dart';
import 'komiic_parsing.dart';

export 'komiic_graphql.dart';
export 'komiic_models.dart';
export 'komiic_parsing.dart';

/// Komiic 在线源网络层单例。
///
/// 关键决策：
/// - **GraphQL 单端点**：查询与 mutation 全部 POST `/api/query`，差异只在
///   `operationName` / `variables` / `query` 三件套里，故只有一个 [_query] 出口。
/// - **token 失效重试**：站点把鉴权失败藏在 HTTP 200 的 `errors` 里，所以必须
///   先判 HTTP 状态、再判 `errors`；命中失效文案时重新登录并**只重试一次**。
/// - **搜索无分页**：`searchComicsAndAuthors` 不接受分页变量，只能靠返回条数判停。
/// - **独立 CookieJar**：项目铁律，各源 cookie 互不污染（Komiic 的 `komiic`
///   目录与其它源完全隔离）。
class KomiicNetwork {
  KomiicNetwork._();

  static KomiicNetwork? _cache;

  factory KomiicNetwork() => _cache ??= KomiicNetwork._();

  static const String komiicBase = 'https://komiic.com';

  /// 站点主机名，仅用于把网络错误提示说得更具体（如
  /// 「到 komiic.com 的连接被中断」）。
  static const String komiicHost = 'komiic.com';

  static const String komiicUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// 独立 CookieJar：**绝不能与其它源共用**，目录固定 `komiic`。
  late final CookieJarSql _cookieJar = CookieJarSql(
    '${App.dataPath}${Platform.pathSeparator}comic_source'
    '${Platform.pathSeparator}komiic${Platform.pathSeparator}cookies.db',
  );

  /// 取源配置。源尚未注册时（本层可先于 `ComicSource.init` 被引用）返回 null，
  /// 由调用方按"未登录"处理，而不是让 `StateError` 冒到 UI。
  ComicSource? get _source => ComicSource.find('komiic');

  String get token => _source?.data['token']?.toString() ?? '';

  bool get isLoggedIn => token.isNotEmpty;

  Dio _dio() {
    final dio = logDio(
      BaseOptions(
        headers: _headers(),
        validateStatus: (status) =>
            status == 200 || (status != null && status >= 400 && status < 500),
      ),
    );
    dio.interceptors.add(CookieManagerSql(_cookieJar));
    return dio;
  }

  /// 统一请求头；已登录时附 Bearer token。
  Map<String, String> _headers() {
    final headers = <String, String>{
      'Referer': '$komiicBase/',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'User-Agent': komiicUA,
    };
    final current = token;
    if (current.isNotEmpty) {
      headers['Authorization'] = 'Bearer $current';
    }
    return headers;
  }

  /// 登录：POST `/api/login`（**不是 GraphQL**），成功返回 token。
  Future<Res<String>> login(String email, String password) async {
    try {
      final response = await _dio().post<String>(
        '$komiicBase/api/login',
        data: jsonEncode(<String, dynamic>{
          'email': email,
          'password': password,
        }),
        options: Options(
          extra: {'noRetry': true},
          contentType: 'application/json',
          // 显式声明取原始字符串。
          //
          // **这不是在修 bug**：dio 5.4.1 的 `DioMixin.fetch<T>` 在 `T == String`
          // 时本来就会强制 `responseType = ResponseType.plain`
          // （pub 缓存 `dio-5.4.1/lib/src/dio_mixin.dart:364-373`），
          // 所以写不写这里行为一致（已用本地探针实测确认）。
          //
          // 写它的意义是**把行为钉在调用点上**：不再依赖"泛型参数恰好是 String"
          // 这个隐式约定。若将来有人把返回类型改成 dynamic 或去掉 `<String>`，
          // 隐式规则就会失效、响应会被静默预解码——显式声明能让那次改动立刻暴露。
          responseType: ResponseType.plain,
        ),
      );
      if (response.statusCode != 200) {
        return Res.error('登录失败（HTTP ${response.statusCode}）',
            errorCode: response.statusCode == 401
                ? ResErrorCode.loginRequired
                : ResErrorCode.network,
            statusCode: response.statusCode);
      }
      final newToken = parseKomiicLoginToken(response.data);
      if (newToken == null) {
        return Res.error(
          '登录响应无法识别：${_describeBody(response)}',
          errorCode: ResErrorCode.parse,
          statusCode: response.statusCode,
        );
      }
      return Res(newToken);
    } on DioException catch (error) {
      // 原始异常文本（dio 的英文包装文案）对用户没有帮助，先落日志再翻译。
      // 真机反馈：这里曾把 "The connection errored: Connection reset by peer /
      // This indicates an error which most likely cannot be solved by the
      // library." 原样显示在登录表单下方 —— 用户既看不懂也不知道该做什么。
      LogManager.addLog(
        LogLevel.warning,
        'KomiicNetwork',
        'login 网络异常：${networkErrorRawMessage(error)}'
            '（type=${error.type.name}, status=${error.response?.statusCode}）',
      );
      return Res.error(
        describeNetworkError(error, host: komiicHost),
        errorCode: ResErrorCode.network,
        statusCode: error.response?.statusCode,
      );
    } catch (error, stackTrace) {
      LogManager.addLog(
        LogLevel.error,
        'KomiicNetwork',
        'login failed: $error\n$stackTrace',
      );
      return Res.error(
        describeNetworkError(error, host: komiicHost),
        errorCode: ResErrorCode.network,
      );
    }
  }

  /// 用已保存的账号密码重新登录（token 失效时的自愈路径）。
  Future<Res<bool>> reLoginFromStored() async {
    final account = _source?.data['account'];
    if (account is! List || account.length < 2) {
      return const Res.error('无可用的账号信息', errorCode: ResErrorCode.loginRequired);
    }
    final result = await login(account[0].toString(), account[1].toString());
    if (result.error) {
      return Res.error(result.errorMessageWithoutNull,
          errorCode: ResErrorCode.loginRequired, statusCode: result.statusCode);
    }
    // 写回 token 并落盘：否则下次请求仍带旧 token，陷入"每请求都重登"。
    final source = _source;
    if (source == null) {
      return const Res.error('Komiic 源未注册，无法保存 token',
          errorCode: ResErrorCode.loginRequired);
    }
    source.data['token'] = result.data;
    try {
      await source.saveData();
    } catch (error, stackTrace) {
      LogManager.addLog(
        LogLevel.error,
        'KomiicNetwork',
        'save token failed: $error\n$stackTrace',
      );
    }
    return const Res(true);
  }

  /// JSON 解析 + `errors` 判定的统一出口。
  ///
  /// 返回 `(data, error)` 二元组语义由 [Res] 表达：成功时 [Res.data] 是响应 Map。
  Future<Res<Map<String, dynamic>>> _query(
    Map<String, dynamic> payload, {
    bool retrying = false,
  }) async {
    try {
      final response = await _dio().post<String>(
        '$komiicBase/api/query',
        data: jsonEncode(payload),
        options: Options(
          contentType: 'application/json',
          // 与 login 同理：显式钉住"取原始字符串"（见 login 处的说明，
          // dio 对 `T == String` 本就有隐式规则，这里只是不再依赖它）。
          responseType: ResponseType.plain,
          // Komiic 用 4xx 表达部分业务错误，交给下面按状态码分类；
          // 传输层 5xx 仍按错误抛出，避免把服务端故障当业务响应解析。
          validateStatus: (status) => status == 200 || (status ?? 0) < 500,
        ),
      );
      final status = response.statusCode;
      if (status != 200) {
        return Res.error('请求失败（HTTP $status）',
            errorCode: status == 401
                ? ResErrorCode.loginRequired
                : ResErrorCode.network,
            statusCode: status);
      }
      final decoded = _decodeBody(response.data);
      if (decoded == null) {
        return Res.error(
          '响应不是合法 JSON：${_describeBody(response)}',
          errorCode: ResErrorCode.parse,
          statusCode: status,
        );
      }
      final errors = decoded['errors'];
      if (errors is List && errors.isNotEmpty) {
        final message = _firstErrorMessage(errors);
        if (_isTokenExpired(message) && !retrying) {
          final reLogin = await reLoginFromStored();
          if (reLogin.success) {
            // 只重试一次：重试仍然失效说明凭据本身也废了，继续递归会打转。
            return _query(payload, retrying: true);
          }
          return const Res.error('登录已过期且重新登录失败',
              errorCode: ResErrorCode.loginRequired);
        }
        return Res.error(message.isEmpty ? 'GraphQL 请求失败' : message);
      }
      return Res(decoded);
    } on DioException catch (error) {
      return Res.error(
        error.message ?? error.toString(),
        errorCode: ResErrorCode.network,
        statusCode: error.response?.statusCode,
      );
    } catch (error, stackTrace) {
      LogManager.addLog(
        LogLevel.error,
        'KomiicNetwork',
        'query ${payload['operationName']} failed: $error\n$stackTrace',
      );
      return Res.error(error.toString(), errorCode: ResErrorCode.network);
    }
  }

  /// `jsonDecode` 的安全包装：非 Map 或解析异常都返回 null。
  Map<String, dynamic>? _decodeBody(String? body) {
    if (body == null || body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 把无法解析的响应描述成一句可用于排查的信息。
  ///
  /// 目标是**让用户能把真实响应贴回来**：只报"解析失败"时，服务端到底返回了
  /// 空体、HTML 还是另一种 JSON 结构完全无从判断。这里给出状态码、Content-Type
  /// 与正文片段，并对 HTML 正文额外提示风控可能。
  ///
  /// token 的**提取**规则不在这里，而在纯解析层的 [parseKomiicLoginToken]：
  /// 那是可 `dart test` 直调的纯逻辑，放这里就没法单独验证了。
  String _describeBody(Response<String> response) {
    final contentType =
        response.headers.value('content-type') ?? '(无 Content-Type)';
    final body = response.data?.trim() ?? '';
    if (body.isEmpty) {
      return 'HTTP ${response.statusCode}，Content-Type=$contentType，正文为空';
    }
    final lower = body.toLowerCase();
    final hint = lower.contains('<html') || lower.contains('<!doctype')
        ? '（疑似 HTML 页面，可能被 Cloudflare / 风控拦截）'
        : '';
    final preview = body.length > 160 ? '${body.substring(0, 160)}…' : body;
    return 'HTTP ${response.statusCode}，Content-Type=$contentType$hint，'
        '正文片段：${preview.replaceAll(RegExp(r'\s+'), ' ')}';
  }

  /// 取 `errors[0].message`；结构不符时返回空串。
  String _firstErrorMessage(List errors) {
    final first = errors.first;
    if (first is Map) return first['message']?.toString() ?? '';
    return first?.toString() ?? '';
  }

  /// token 失效判定：**大小写不敏感**，`token` + （`expired` 或 `no token`）。
  bool _isTokenExpired(String message) {
    final lower = message.toLowerCase();
    if (!lower.contains('token')) return false;
    return lower.contains('expired') || lower.contains('no token');
  }

  /// 搜索：**本站搜索接口不接受分页**，只传 keyword；返回条数用于判停。
  Future<Res<List<KomiicComicBrief>>> search(String keyword) async {
    final result = await _query(searchComicAndAuthorQuery(keyword: keyword));
    if (result.error) return Res.fromErrorRes(result);
    final payload = result.data['data'];
    final searchResult =
        payload is Map ? payload['searchComicsAndAuthors'] : null;
    final comics = searchResult is Map ? searchResult['comics'] : null;
    final parsed = parseKomiicComicList(comics);
    // 搜索无分页协议：返回条数为 0 时让框架认为"没有更多"（subData = 0）。
    return Res(parsed, subData: parsed.isEmpty ? 0 : null);
  }

  /// 通用列表加载（`recentUpdate` / `hotComics`）。
  ///
  /// subData 判停协议（对齐 `_EhGalleryLoader`）：**有下一页时不传 subData**
  /// （框架据此继续上拉），**仅不满一页时把当前页数作为 subData**
  /// （框架据此停止上拉）。满页意味着后面可能还有，同样不传。
  Future<Res<List<KomiicComicBrief>>> getComicList({
    required String operationName,
    required int page,
    int limit = 20,
    String orderBy = 'DATE_UPDATED',
    String status = '',
    bool asc = true,
  }) async {
    final Map<String, dynamic> payload;
    switch (operationName) {
      case 'recentUpdate':
        payload = recentUpdateQuery(page: page, limit: limit);
      case 'hotComics':
        payload = hotComicsQuery(page: page, limit: limit);
      default:
        return const Res.error('不支持的列表操作', errorCode: ResErrorCode.unsupported);
    }
    if (orderBy != 'DATE_UPDATED' || status.isNotEmpty || !asc) {
      // 上面两个顶层函数只覆盖默认排序；需要自定义排序时走通用模板。
      payload['variables'] = <String, dynamic>{
        'pagination': komiicPagination(
          page: page,
          limit: limit,
          orderBy: orderBy,
          status: status,
          asc: asc,
        ),
      };
    }
    final result = await _query(payload);
    if (result.error) return Res.fromErrorRes(result);
    return _parseComicListResult(result.data, operationName, limit, page);
  }

  /// 从 `data.<field>` 取数组并按 limit 判停。
  Res<List<KomiicComicBrief>> _parseComicListResult(
    Map<String, dynamic> body,
    String field,
    int limit,
    int page,
  ) {
    final data = body['data'];
    final list = data is Map ? data[field] : null;
    final parsed = parseKomiicComicList(list);
    final rawCount = parseKomiicRawCount(list);
    return Res<List<KomiicComicBrief>>(
      parsed,
      subData: rawCount < limit ? page : null,
    );
  }

  /// 按分类取漫画；`categoryId == '0'` 表示全部分类，传空数组。
  Future<Res<List<KomiicComicBrief>>> getComicsByCategory({
    required String categoryId,
    required int page,
    int limit = 20,
    String orderBy = 'DATE_UPDATED',
    String status = '',
  }) async {
    final result = await _query(
      comicByCategoriesQuery(
        categoryId: categoryId == '0' ? const <String>[] : <String>[categoryId],
        page: page,
        limit: limit,
        orderBy: orderBy,
        status: status,
      ),
    );
    if (result.error) return Res.fromErrorRes(result);
    return _parseComicListResult(result.data, 'comicByCategories', limit, page);
  }

  /// 按 id 批量取漫画。
  Future<Res<List<KomiicComicBrief>>> getComicsByIds(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const Res(<KomiicComicBrief>[]);
    final result = await _query(comicByIdsQuery(comicIds: ids));
    if (result.error) return Res.fromErrorRes(result);
    final data = result.data['data'];
    final list = data is Map ? data['comicByIds'] : null;
    return Res(parseKomiicComicList(list));
  }

  /// 单本漫画的推荐 id 列表。
  Future<Res<List<String>>> getRecommendIds(String comicId) async {
    final result = await _query(recommendComicByIdQuery(comicId: comicId));
    if (result.error) return Res.fromErrorRes(result);
    final data = result.data['data'];
    return Res(
        parseKomiicStringIds(data is Map ? data['recommendComicById'] : null));
  }

  /// 详情：本体的漫画对象 → 章节 → 推荐，三者按需拼装。
  ///
  /// `comicByIds` 一次同时取本体与推荐（省一轮请求）。原始 Map 里保留
  /// `description` / `monthViews` 等 brief 不承载的字段，因此**不再单独补一次
  /// 请求**：同一份响应既喂给 [parseKomiicComicInfo]，也用来解出推荐列表。
  /// 推荐 id 拿不到时不失败，详情页的推荐区空着即可。
  Future<Res<KomiicComicInfo>> getComicInfo(String id) async {
    final recommendRes = await getRecommendIds(id);
    final recommendIds = recommendRes.dataOrNull ?? const <String>[];
    final ids = <String>[id, ...recommendIds];

    final rawRes = await _query(comicByIdsQuery(comicIds: ids));
    if (rawRes.error) return Res.fromErrorRes(rawRes);
    final data = rawRes.data['data'];
    final rawList = data is Map ? data['comicByIds'] : null;

    // 按 id 建索引，同时保留原始 Map（详情需要 brief 之外的字段）。
    final rawById = <String, Map<String, dynamic>>{};
    final briefById = <String, KomiicComicBrief>{};
    for (final comic in parseKomiicComicList(rawList)) {
      briefById[comic.id] = comic;
    }
    if (rawList is List) {
      for (final item in rawList) {
        if (item is! Map) continue;
        final itemId = item['id']?.toString() ?? '';
        if (itemId.isEmpty || rawById.containsKey(itemId)) continue;
        rawById[itemId] = item.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    }

    final self = rawById[id];
    if (self == null) {
      return const Res.error('未找到该漫画', errorCode: ResErrorCode.parse);
    }

    final chaptersRes = await getChapters(id);
    if (chaptersRes.error) return Res.fromErrorRes(chaptersRes);

    final recommendations = <KomiicComicBrief>[
      for (final recommendId in recommendIds)
        if (briefById[recommendId] != null) briefById[recommendId]!,
    ];

    return Res(
      parseKomiicComicInfo(
        self,
        chapters: chaptersRes.data,
        recommendations: recommendations,
      ),
    );
  }

  /// 章节列表。
  Future<Res<List<KomiicChapter>>> getChapters(String comicId) async {
    final result = await _query(chapterByComicIdQuery(comicId: comicId));
    if (result.error) return Res.fromErrorRes(result);
    final data = result.data['data'];
    return Res(
      parseKomiicChapters(
        data is Map ? data['chaptersByComicId'] : null,
      ),
    );
  }

  /// 章节图片 URL 列表。
  Future<Res<List<String>>> getImages(String chapterId) async {
    final result = await _query(imagesByChapterIdQuery(chapterId: chapterId));
    if (result.error) return Res.fromErrorRes(result);
    final data = result.data['data'];
    return Res(
      parseKomiicImageUrls(
        data is Map ? data['imagesByChapterId'] : null,
      ),
    );
  }

  /// 收藏夹列表。
  Future<Res<List<KomiicFolder>>> getFolders() async {
    final result = await _query(myFolderQuery());
    if (result.error) return Res.fromErrorRes(result);
    final data = result.data['data'];
    return Res(parseKomiicFolders(data is Map ? data['folders'] : null));
  }

  /// 某本漫画所属的收藏夹 id 列表。
  Future<Res<List<String>>> getComicFolders(String comicId) async {
    final result = await _query(comicInAccountFoldersQuery(comicId: comicId));
    if (result.error) return Res.fromErrorRes(result);
    final data = result.data['data'];
    return Res(
      parseKomiicStringIds(
        data is Map ? data['comicInAccountFolders'] : null,
      ),
    );
  }

  /// 收藏 / 取消收藏（两个 mutation 只在 operation 与字段名上不同）。
  Future<Res<bool>> addOrDelFavorite({
    required String comicId,
    required String folderId,
    required bool isAdding,
  }) async {
    final payload = isAdding
        ? addComicToFolderMutation(comicId: comicId, folderId: folderId)
        : removeComicToFolderMutation(comicId: comicId, folderId: folderId);
    final result = await _query(payload);
    if (result.error) return Res.fromErrorRes(result);
    return const Res(true);
  }

  /// 收藏夹分页：先取 id 列表，再批量补全漫画本体。
  Future<Res<List<KomiicComicBrief>>> getFolderComicsPage(
    String folderId,
    int page,
  ) async {
    final result = await _query(
      folderComicIdsQuery(folderId: folderId, page: page),
    );
    if (result.error) return Res.fromErrorRes(result);
    final data = result.data['data'];
    final folderRes = data is Map ? data['folderComicIds'] : null;
    final ids = parseKomiicStringIds(
      folderRes is Map ? folderRes['comicIds'] : null,
    );
    if (ids.isEmpty) return const Res(<KomiicComicBrief>[], subData: 0);
    final comicsRes = await getComicsByIds(ids);
    if (comicsRes.error) return Res.fromErrorRes(comicsRes);
    return Res(
      comicsRes.data,
      subData: ids.length < 20 ? page : null,
    );
  }
}
