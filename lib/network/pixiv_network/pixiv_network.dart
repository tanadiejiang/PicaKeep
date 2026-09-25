/// Pixiv 在线源网络层。
///
/// 设计要点（与项目其它源保持一致，但有三处 **Pixiv 专属**决策）：
/// 1. **独立 CookieJar**：Pixiv 的 `PHPSESSID` 绝不允许写进 nhentai/eh 共用的
///    `SingleInstanceCookieJar`（项目铁律：多源共库会串 cookie，导致 A 站登录态
///    泄漏到 B 站、或 B 站风控跟着 A 站的失效 session 一起失效）。这里用独立
///    db 文件 `pixiv_cookies.db`。
/// 2. **固定 safe mode**：本项目不提供 R18 入口，搜索一律 `mode=safe`，
///    不暴露任何 r18 开关——避免未成年人内容与账号风控。调用方也无从覆盖。
/// 3. **Web 端 Ajax 而非 App API**：Web 端只需 `PHPSESSID` + Referer/UA 即可
///    访问，不改动 comic_source.dart（其 `pixiv` key 由上层接入时注册）。
library;

import 'dart:convert';
import 'dart:io' show Cookie, Platform;

import 'package:dio/dio.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/app_dio.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/network/res.dart';

import 'pixiv_parsing.dart';

export 'pixiv_models.dart';

class PixivNetwork {
  factory PixivNetwork() => _cache ?? (_cache = PixivNetwork._create());

  PixivNetwork._create() {
    _loadSessionFromJar();
  }

  static PixivNetwork? _cache;

  /// Pixiv 站点根地址。
  static const pixivWebBase = 'https://www.pixiv.net';

  /// 固定 Web UA。
  ///
  /// Pixiv 对 UA 与 Referer 的组合校验较严：UA 与抓取 session 时不一致会直接
  /// 触发风控（返回 HTML 而不是 JSON）。因此全链路统一用同一个桌面 Chrome UA。
  static const pixivWebUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// 会话 cookie 名（Pixiv Web 登录凭证）。
  static const phpSessIdCookieName = 'PHPSESSID';

  /// 独立 CookieJar。
  ///
  /// 与 eh/jm 同构（各自一个 db 文件），**不能用** [SingleInstanceCookieJar]：
  /// 那个是 nhentai/cloudflare 共用实例，写入 Pixiv 的 PHPSESSID 会污染其它源。
  final CookieJarSql cookieJar = CookieJarSql(
    '${App.dataPath}${Platform.pathSeparator}comic_source'
    '${Platform.pathSeparator}pixiv_cookies.db',
  );

  /// 内存中的会话快照（避免每请求都查 sqlite）。
  String? _phpSessId;

  /// 从源级配置读 token。
  ///
  /// 契约：token 存在 `ComicSource.require('pixiv').data['token']`。key 未注册时
  /// （本层单独接入阶段）[ComicSource.require] 会抛 StateError——这里吞掉并视为
  /// 未登录，保证网络层在源注册完成前也能安全构造。
  String get _storedToken {
    try {
      return ComicSource.require('pixiv').data['token']?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 当前有效会话值。
  ///
  /// **回退顺序：内存快照 → 源数据里的 token。**
  ///
  /// 两者在登录时写入的是同一个值（`PHPSESSID`），但生命周期不同：
  /// - `_phpSessId` 只在进程内有效，或由 [\_loadSessionFromJar] 在构造时载入；
  ///   jar 读取失败（权限、路径变化、清缓存、换设备恢复）会让它为 null；
  /// - `data['token']` 是持久化的源数据，重启后仍在。
  ///
  /// 首版只读 `_phpSessId`，造成一个**静默的不一致**：[isLoggedIn] 因为 token
  /// 非空而判为已登录，但请求不带 Cookie（[_cookieHeader] 返回空），
  /// 服务端视为未登录 —— 用户看到"账号页显示已登录，收藏却说需要登录"。
  /// 回退后"判定"与"实际发送"用的是同一个值，口径一致。
  String? get _session {
    final memory = _phpSessId;
    if (memory != null && memory.isNotEmpty) return memory;
    final stored = _storedToken;
    return stored.isEmpty ? null : stored;
  }

  /// 是否已登录：有有效会话即可。
  bool get isLoggedIn => _session != null;

  /// 把 WebView 捕获的**全部** pixiv cookie 写进 CookieJar。
  ///
  /// 为什么不复用 [setSessionCookie]：那个只写 `PHPSESSID`。
  /// 真机证据显示 Pixiv 的**写操作**（收藏增删）还需要别的 cookie
  /// （读接口正常、写接口被拒并提示"请重新登录"）。登录时 WebView 已经把
  /// 整站 cookie 都拿到了，这里**一次全存**，避免只存 session 造成的
  /// "读得了、写不了"。
  ///
  /// 只存非空项；域名统一 `/.pixiv.net`（与 [setSessionCookie] 同口径），
  /// 保证 `www.pixiv.net` 与 `i.pximg.net` 都能命中。
  Future<void> saveCookies(Map<String, String> cookies) async {
    final list = <Cookie>[];
    String? sessId;
    cookies.forEach((name, value) {
      final key = name.trim();
      final val = value.trim();
      if (key.isEmpty || val.isEmpty) return;
      if (key == phpSessIdCookieName) sessId = val;
      list.add(Cookie(key, val)
        ..domain = '.pixiv.net'
        ..path = '/');
    });
    if (list.isEmpty) return;
    cookieJar.saveFromResponse(Uri.parse(pixivWebBase), list);
    // 同步内存快照：否则 [_session] 仍看旧值，请求头与会话判定会分叉。
    if (sessId != null && sessId!.isNotEmpty) {
      _phpSessId = sessId;
    }
    // cookie 变了，此前缓存的 CSRF token 可能已随之更换。
    _csrfToken = null;
  }

  /// 当前持有会话的 PHPSESSID（无则 null）。
  ///
  /// 返回的是**实际会用于请求的值**（内存快照，或源数据 token 的回退结果），
  /// 不是单纯的内存字段——对外语义就该是"当前会话是什么"。
  /// 若要校验"值是否真的落到了 jar 里"，用 [readPersistedPhpSessId]。
  String? get storedPhpSessId => _session;

  /// 从 CookieJar **回读** PHPSESSID。
  ///
  /// 与 [storedPhpSessId] 的区别是数据来源：本方法读的是持久化 jar 的真实内容，
  /// 因此能证伪"内存里写了、jar 里没落盘或被旧值覆盖"的情况。
  /// 登录收尾用它做写入校验，避免把残留旧会话当成本次登录成功。
  String? readPersistedPhpSessId() {
    final cookies = cookieJar.loadForRequest(Uri.parse(pixivWebBase));
    for (final cookie in cookies) {
      if (cookie.name == phpSessIdCookieName && cookie.value.isNotEmpty) {
        return cookie.value;
      }
    }
    return null;
  }

  /// 启动时把持久化的 PHPSESSID 载入内存快照。
  void _loadSessionFromJar() {
    final cookies = cookieJar.loadForRequest(Uri.parse(pixivWebBase));
    for (final cookie in cookies) {
      if (cookie.name == phpSessIdCookieName && cookie.value.isNotEmpty) {
        _phpSessId = cookie.value;
        return;
      }
    }
  }

  /// 写入会话 cookie。
  ///
  /// domain 用 `.pixiv.net`（带前导点）是刻意的：Pixiv 的登录态要在
  /// `www.pixiv.net` 与图片域 `i.pximg.net` 之间共享，只写 host 会导致
  /// 图片请求 403。path 固定 `/`。
  Future<void> setSessionCookie(String phpSessId) async {
    final value = phpSessId.trim();
    if (value.isEmpty) return;
    _phpSessId = value;
    final cookie = Cookie(phpSessIdCookieName, value)
      ..domain = '.pixiv.net'
      ..path = '/'
      ..httpOnly = true;
    cookieJar.saveFromResponse(Uri.parse(pixivWebBase), <Cookie>[cookie]);
  }

  /// 退出登录：清 CookieJar 与内存快照。
  ///
  /// 用 [CookieJarSql.deleteUri]（按域名族全清）而不是逐条 [CookieJarSql.delete]：
  /// 后者按 `(name, domain, path)` 精确匹配，而写库时 path 落成 `/`、
  /// 用不带 `/` 的 Uri 删不到，会留下"退出后仍带旧 session"的脏状态。
  Future<void> logout() async {
    _phpSessId = null;
    cookieJar.deleteUri(Uri.parse(pixivWebBase));
  }

  /// 拼当前 Cookie 头。
  ///
  /// **带 jar 里全部 pixiv cookie，而不是只带 PHPSESSID。**
  ///
  /// 真机证据：读接口（详情/搜索/取 uid）全部正常，唯独**写接口**（收藏）被
  /// 服务端拒绝并提示"请重新登录"。读通过、写被拒，典型原因是写操作还依赖
  /// 除 session 之外的凭据——最可能是 CSRF token cookie。
  /// 只拼 PHPSESSID 会让这类请求在服务端看来"凭据不完整"。
  ///
  /// 仍保留 [\_session] 兜底：jar 读取失败（权限/路径异常）时至少带上 session，
  /// 不让"判为已登录却不发凭据"的不一致重新出现。
  String _cookieHeader() {
    try {
      final cookies = cookieJar.loadForRequest(Uri.parse(pixivWebBase));
      final parts = <String>[];
      for (final cookie in cookies) {
        if (cookie.name.isEmpty || cookie.value.isEmpty) continue;
        parts.add('${cookie.name}=${cookie.value}');
      }
      if (parts.isNotEmpty) return parts.join('; ');
    } catch (_) {
      // 读 jar 失败：退回下面的内存快照。
    }
    final session = _session;
    if (session == null) return '';
    return '$phpSessIdCookieName=$session';
  }

  /// 构造 Ajax 请求头（GET/POST 共用）。
  ///
  /// 抽出来的唯一目的是让 [_getJson] 与 [_postJson] 的 UA / Referer / Cookie
  /// 口径完全一致——两处一旦分叉，Pixiv 会按"UA 与 session 不匹配"触发风控，
  /// 表现为返回 HTML 而不是 JSON。`_getJson` 的对外行为不因此改变。
  ///
  /// [contentType] 仅在 POST 时传入 `application/json`；GET 沿用原来的
  /// `Accept: application/json`（原实现就没有 Content-Type，不要新增）。
  ///
  /// [withCsrf] 为 true 时附上 CSRF token（**只有写操作需要**，见 [_csrfHeader]）。
  Map<String, dynamic> _baseHeaders({
    String? contentType,
    bool withCsrf = false,
    String? referer,
    bool withOrigin = false,
  }) {
    final cookie = _cookieHeader();
    return <String, dynamic>{
      'Referer': referer ?? '$pixivWebBase/',
      // 写操作带上 Origin：部分站点的 CSRF 校验会比对 Origin/Referer 是否同源，
      // 缺失时按"跨站伪造"处理（回复往往就是"请重新登录"，不点明真实原因）。
      if (withOrigin) 'Origin': pixivWebBase,
      'User-Agent': pixivWebUA,
      'Accept': 'application/json',
      if (contentType != null) 'Content-Type': contentType,
      if (cookie.isNotEmpty) 'Cookie': cookie,
      ...?withCsrf ? _csrfHeader() : null,
    };
  }

  /// 已取得的 CSRF token（内存缓存）。
  String? _csrfToken;

  /// 拼 CSRF 头；没有可用 token 时返回 null（**不硬造空值**）。
  ///
  /// 真机证据链：登录有效（GET 能取到当前用户 uid），但收藏 POST 被服务端
  /// 拒绝并提示"请重新登录"——**读通过、写被拒**是 CSRF 校验失败的典型表现。
  /// Pixiv 未公开该机制，故 token 来源做**两条并列容错**：
  /// cookie（[pixivCsrfCookieNames]）与页面 HTML（[parsePixivCsrfTokenFromHtml]）。
  Map<String, String>? _csrfHeader() {
    final token = _csrfToken;
    if (token == null || token.isEmpty) return null;
    // 头名同时给两种写法：`X-CSRF-Token` 是主流约定，
    // 少数实现认 `X-XSRF-TOKEN`；多带一个无副作用（服务端取自己认的那个）。
    return <String, String>{
      'X-CSRF-Token': token,
      'X-XSRF-TOKEN': token,
    };
  }

  /// 确保 CSRF token 可用：先查 cookie，再（必要时）拉一次首页从 HTML 解析。
  ///
  /// 拿到后缓存在内存里，避免每次写操作都多一次请求。
  /// 两条来源都取不到时返回 null——调用方照常发请求（行为与修复前一致，
  /// 不会比现在更差），但会把"没有 token"记进日志便于排查。
  Future<String?> ensureCsrfToken({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = _csrfToken;
      if (cached != null && cached.isNotEmpty) return cached;
    }

    // 来源 1：cookie jar。
    final fromCookie = _csrfTokenFromJar();
    if (fromCookie != null) {
      _csrfToken = fromCookie;
      return fromCookie;
    }

    // 来源 2：首页 HTML（与 fetchUserId 同一次页面请求的另一种用法）。
    final fromHtml = await _fetchCsrfTokenFromPage();
    if (fromHtml != null) {
      _csrfToken = fromHtml;
      return fromHtml;
    }

    LogManager.addLog(
      LogLevel.warning,
      'PixivNetwork',
      '写操作令牌未取得：首页 HTML 里既没有 meta csrf-token，也没有 '
          'serverSerializedPreloadedState 里的 api.token'
          '（实际 cookie=${_cookieNamesForDiagnostics().join(",")}）；'
          '收藏等写操作会被服务端以 400 +「请重新登录」拒绝 —— '
          '该文案有误导性，实际原因是缺令牌而不是未登录。',
    );
    return null;
  }

  /// 从 CookieJar 里按候选名找 CSRF token。
  ///
  /// **必须解码**：`XSRF-TOKEN` 一类 cookie 常以 URL 编码下发，
  /// 原样放进请求头会因为字符不匹配而校验失败（这类"看起来带对了却仍被拒"
  /// 的情况最难查）。解码失败则退回原值，不因编码问题丢掉 token。
  String? _csrfTokenFromJar() {
    try {
      final cookies = cookieJar.loadForRequest(Uri.parse(pixivWebBase));
      for (final name in pixivCsrfCookieNames) {
        for (final cookie in cookies) {
          if (cookie.name == name && cookie.value.trim().isNotEmpty) {
            return _decodeCookieValue(cookie.value.trim());
          }
        }
      }
    } catch (_) {
      // 读 jar 失败按"没有"处理，继续走页面来源。
    }
    return null;
  }

  String _decodeCookieValue(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  /// cookie **名称**清单（**不含值**）：仅用于诊断日志。
  ///
  /// 只记名字不记值——凭据绝不进日志（见项目日志脱敏约定）。
  List<String> _cookieNamesForDiagnostics() {
    try {
      return cookieJar
          .loadForRequest(Uri.parse(pixivWebBase))
          .map((cookie) => cookie.name)
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  Future<String?> _fetchCsrfTokenFromPage() async {
    if (_session == null) return null;
    try {
      final dio = logDio();
      final response = await dio.get<String>(
        '$pixivWebBase/',
        options: Options(
          responseType: ResponseType.plain,
          headers: <String, dynamic>{
            'Referer': '$pixivWebBase/',
            'User-Agent': pixivWebUA,
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            if (_cookieHeader().isNotEmpty) 'Cookie': _cookieHeader(),
          },
          validateStatus: (status) =>
              status == 200 ||
              (status != null && status >= 400 && status < 500),
        ),
      );
      return parsePixivCsrfTokenFromHtml(response.data);
    } catch (_) {
      return null;
    }
  }

  /// 统一的 JSON GET。
  ///
  /// [retrying] 是**内部重试标记**：空响应/非 JSON（典型的风控拦截或半截响应）
  /// 属于可自愈的瞬时失败，这里最多再试一次；重试时置 true 以避免无限重试。
  /// 外部调用方不应传该参数。
  ///
  /// 错误分层（都不抛异常，全部收敛成 [Res.error]）：
  /// - 空响应 → [ResErrorCode.parse]；
  /// - 非 JSON（风控返回 HTML）→ [ResErrorCode.parse]，文案提示风控；
  /// - 顶层 `error == true` → 取 `message`；
  /// - 401/403 → [ResErrorCode.loginRequired]，附状态码；
  /// - 其它传输异常 → [ResErrorCode.network]。
  Future<Res<Map<String, dynamic>>> _getJson(
    String url, {
    bool requireAuth = false,
    bool retrying = false,
  }) async {
    if (requireAuth && !isLoggedIn) {
      return const Res.error(
        '需要登录',
        errorCode: ResErrorCode.loginRequired,
      );
    }

    final dio = logDio();
    try {
      final response = await dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          // 4xx 也要拿回响应体：Pixiv 的错误信息在 JSON 里（`error`/`message`），
          // 直接抛 DioException 会让上层只能看到"状态码 400"而丢掉原因。
          validateStatus: (status) =>
              status != null &&
              (status == 200 || (status >= 400 && status < 500)),
          headers: _baseHeaders(),
        ),
      );

      final statusCode = response.statusCode;
      final raw = response.data ?? '';

      // 401/403 优先按登录问题归类：即便响应体是 HTML 也要给出"需要登录"，
      // 否则用户看到的是含糊的解析失败。
      if (statusCode == 401 || statusCode == 403) {
        return Res.error(
          '需要登录',
          errorCode: ResErrorCode.loginRequired,
          statusCode: statusCode,
        );
      }

      if (raw.trim().isEmpty) {
        if (!retrying) {
          return _getJson(url, requireAuth: requireAuth, retrying: true);
        }
        return Res.error(
          'Empty response',
          errorCode: ResErrorCode.parse,
          statusCode: statusCode,
        );
      }

      dynamic decoded;
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        if (!retrying) {
          return _getJson(url, requireAuth: requireAuth, retrying: true);
        }
        return Res.error(
          'Pixiv 返回非 JSON（可能触发风控），请稍后重试或检查网络/登录状态',
          errorCode: ResErrorCode.parse,
          statusCode: statusCode,
        );
      }
      if (decoded is! Map) {
        return Res.error(
          'Pixiv 返回非 JSON（可能触发风控），请稍后重试或检查网络/登录状态',
          errorCode: ResErrorCode.parse,
          statusCode: statusCode,
        );
      }
      final json = decoded.map((key, value) => MapEntry(key.toString(), value));

      if (json['error'] == true) {
        final message = json['message']?.toString();
        return Res.error(
          (message == null || message.isEmpty) ? 'Pixiv 接口返回错误' : message,
          errorCode: _errorCodeForStatus(statusCode),
          statusCode: statusCode,
        );
      }

      return Res<Map<String, dynamic>>(json);
    } on DioException catch (e) {
      return Res.error(
        e.message ?? '网络请求失败',
        errorCode: ResErrorCode.network,
        statusCode: e.response?.statusCode,
      );
    } catch (e) {
      return Res.error(
        e.toString(),
        errorCode: ResErrorCode.network,
      );
    } finally {
      dio.close(force: true);
    }
  }

  /// 顶层 `error == true` 时的错误码归类（4xx 已经不是登录/权限问题时按 accessDenied）。
  ResErrorCode _errorCodeForStatus(int? statusCode) {
    if (statusCode == 401) return ResErrorCode.loginRequired;
    if (statusCode != null && statusCode >= 400 && statusCode < 500) {
      return ResErrorCode.accessDenied;
    }
    return ResErrorCode.parse;
  }

  /// 统一的 JSON POST（与 [_getJson] 同风格的错误分层）。
  ///
  /// Pixiv 的写接口（书签增删）只接受 `Content-Type: application/json` + 站点
  /// Referer，因此 body 用 jsonEncode 后原样发出，header 由 [_baseHeaders] 统一
  /// 构造。错误分层与 `_getJson` 完全一致：
  /// - 空响应 / 非 JSON（风控返回 HTML）→ [ResErrorCode.parse]；
  /// - 顶层 `error == true` → 取 `message`，按状态码归类；
  /// - 401/403 → [ResErrorCode.loginRequired]，附状态码；
  /// - 其它传输异常 → [ResErrorCode.network]。
  ///
  /// 与 GET 不同：POST 是**非幂等**操作，这里**不做**自动重试——重复提交书签
  /// 增删虽在服务端幂等，但重试会把"真实失败"掩盖成"最终成功"，也可能放大
  /// 风控命中。调用方按返回结果决定是否让用户重试。
  Future<Res<Map<String, dynamic>>> _postJson(
    String url,
    Map<String, dynamic> data, {
    bool requireAuth = false,
    bool retriedWithCsrf = false,
    String? referer,
  }) async {
    if (requireAuth && !isLoggedIn) {
      return const Res.error(
        '需要登录',
        errorCode: ResErrorCode.loginRequired,
      );
    }

    // 写操作先确保 CSRF token 可用（读操作不需要，见 [_csrfHeader]）。
    // 取不到也照常发（不阻塞主流程），下面的失败分支会刷新后重试一次。
    await ensureCsrfToken();

    final dio = logDio();
    try {
      final response = await dio.post<String>(
        url,
        data: jsonEncode(data),
        options: Options(
          responseType: ResponseType.plain,
          // 同 _getJson：4xx 也要拿回响应体，否则上层只能看到状态码而丢掉
          // Pixiv 放在 JSON 里的 error/message 原因。
          validateStatus: (status) =>
              status != null &&
              (status == 200 || (status >= 400 && status < 500)),
          headers: _baseHeaders(
            contentType: 'application/json',
            withCsrf: true,
            withOrigin: true,
            referer: referer,
          ),
        ),
      );

      final statusCode = response.statusCode;
      final raw = response.data ?? '';

      // 服务端把"会话/令牌不可信"表达成失败时的统一处理：
      // **刷新 CSRF 后重试一次**。
      //
      // 真机症状：登录有效（GET 能取到当前 uid），但收藏 POST 返回
      // "请重新登录"——读通过、写被拒。这类失败**不可能**靠让用户重新登录
      // 解决（用户已试过），只可能是本次请求少了写操作必需的令牌。
      // 只重试一次：重试仍失败说明不是 CSRF 问题，继续重试会打转。
      Future<Res<Map<String, dynamic>>?> retryWithFreshCsrf(
        String message,
      ) async {
        if (retriedWithCsrf) return null;
        if (!_looksLikeAuthFailure(message)) return null;
        final refreshed = await ensureCsrfToken(forceRefresh: true);
        if (refreshed == null) return null;
        LogManager.addLog(
          LogLevel.warning,
          'PixivNetwork',
          'POST 被拒（$message），已刷新 CSRF token 后重试一次：$url',
        );
        return _postJson(
          url,
          data,
          requireAuth: requireAuth,
          retriedWithCsrf: true,
          referer: referer,
        );
      }

      // 401/403 优先按登录问题归类，理由同 _getJson。
      if (statusCode == 401 || statusCode == 403) {
        final retried = await retryWithFreshCsrf('HTTP $statusCode');
        if (retried != null) return retried;
        return Res.error(
          '需要登录',
          errorCode: ResErrorCode.loginRequired,
          statusCode: statusCode,
        );
      }

      if (raw.trim().isEmpty) {
        return Res.error(
          'Empty response',
          errorCode: ResErrorCode.parse,
          statusCode: statusCode,
        );
      }

      dynamic decoded;
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        return Res.error(
          'Pixiv 返回非 JSON（可能触发风控），请稍后重试或检查网络/登录状态',
          errorCode: ResErrorCode.parse,
          statusCode: statusCode,
        );
      }
      if (decoded is! Map) {
        return Res.error(
          'Pixiv 返回非 JSON（可能触发风控），请稍后重试或检查网络/登录状态',
          errorCode: ResErrorCode.parse,
          statusCode: statusCode,
        );
      }
      final json = decoded.map((key, value) => MapEntry(key.toString(), value));

      if (json['error'] == true) {
        final message = json['message']?.toString();
        final text =
            (message == null || message.isEmpty) ? 'Pixiv 接口返回错误' : message;
        // 关键：服务端在这里说的"请重新登录"**不一定**是真的未登录
        // （GET 已证明会话有效），更可能是写操作令牌不被接受。
        // 先刷新 CSRF 重试一次，再决定是否如实回报。
        final retried = await retryWithFreshCsrf(text);
        if (retried != null) return retried;
        return Res.error(
          text,
          errorCode: _errorCodeForStatus(statusCode),
          statusCode: statusCode,
        );
      }

      return Res<Map<String, dynamic>>(json);
    } on DioException catch (e) {
      return Res.error(
        e.message ?? '网络请求失败',
        errorCode: ResErrorCode.network,
        statusCode: e.response?.statusCode,
      );
    } catch (e) {
      return Res.error(
        e.toString(),
        errorCode: ResErrorCode.network,
      );
    } finally {
      dio.close(force: true);
    }
  }

  /// 粗判"这次失败像会话/令牌问题"。
  ///
  /// 只用于决定**是否值得刷新 CSRF 重试一次**，不用于向用户分类错误
  /// （用户可见的错误码仍走 [_errorCodeForStatus]）。
  /// 文案来自服务端且语言不定（中/日/英），故按关键词宽匹配。
  bool _looksLikeAuthFailure(String message) {
    final lower = message.toLowerCase();
    const markers = <String>[
      '登录',
      '登入',
      'ログイン',
      'login',
      'log in',
      'unauthorized',
      'forbidden',
      'csrf',
      'token',
    ];
    return markers.any(lower.contains);
  }

  /// 取作品详情（`/ajax/illust/{id}`）。
  Future<Res<PixivComicInfo>> getComicInfo(String id) async {
    if (id.trim().isEmpty) {
      return const Res.error('作品 id 为空',
          errorCode: ResErrorCode.invalidArgument);
    }
    final res = await _getJson('$pixivWebBase/ajax/illust/$id');
    if (res.error) return Res.fromErrorRes(res);
    final body = res.data['body'];
    if (body is! Map) {
      return const Res.error('Pixiv 详情响应缺少 body',
          errorCode: ResErrorCode.parse);
    }
    try {
      return Res<PixivComicInfo>(
        parsePixivComicInfo(body.map((k, v) => MapEntry(k.toString(), v))),
      );
    } catch (e) {
      return Res.error('详情解析失败：$e', errorCode: ResErrorCode.parse);
    }
  }

  /// 取作品逐页图片 URL（`/ajax/illust/{id}/pages`）。
  Future<Res<List<PixivPage>>> getComicPages(String id) async {
    if (id.trim().isEmpty) {
      return const Res.error('作品 id 为空',
          errorCode: ResErrorCode.invalidArgument);
    }
    final res = await _getJson('$pixivWebBase/ajax/illust/$id/pages');
    if (res.error) return Res.fromErrorRes(res);
    try {
      return Res<List<PixivPage>>(parsePixivPages(res.data['body']));
    } catch (e) {
      return Res.error('分页解析失败：$e', errorCode: ResErrorCode.parse);
    }
  }

  /// 取动图元数据（`/ajax/illust/{id}/ugoira_meta`），仅在 `illustType == 2` 时有意义。
  Future<Res<PixivUgoiraMeta>> getUgoiraMeta(String id) async {
    if (id.trim().isEmpty) {
      return const Res.error('作品 id 为空',
          errorCode: ResErrorCode.invalidArgument);
    }
    final res = await _getJson('$pixivWebBase/ajax/illust/$id/ugoira_meta');
    if (res.error) return Res.fromErrorRes(res);
    final body = res.data['body'];
    if (body is! Map) {
      return const Res.error('Pixiv 动图响应缺少 body',
          errorCode: ResErrorCode.parse);
    }
    try {
      return Res<PixivUgoiraMeta>(
        parsePixivUgoiraMeta(body.map((k, v) => MapEntry(k.toString(), v))),
      );
    } catch (e) {
      return Res.error('动图元数据解析失败：$e', errorCode: ResErrorCode.parse);
    }
  }

  /// 搜索作品。
  ///
  /// - `mode` 固定 `safe`（本项目不提供 R18 入口，见文件头注释）；
  /// - 关键词用 [Uri.encodeComponent] 编码后拼进 path（Pixiv 该接口的 word
  ///   同时出现在 path 与 query，两处都要带）；
  /// - `order` 为空时默认 `date_d`（按时间倒序，与 Web 默认一致）；
  /// - `s_mode=s_tag` 表示按标签搜索（Web 端默认行为）。
  ///
  /// 若能推断出总页数，会放进 [Res.subData]，调用方据此判停；推断不出则为 null。
  Future<Res<List<PixivComicBrief>>> search(
    String keyword,
    int page,
    String option,
  ) async {
    final word = keyword.trim();
    if (word.isEmpty) {
      return const Res.error('搜索关键词为空',
          errorCode: ResErrorCode.invalidArgument);
    }
    final encoded = Uri.encodeComponent(word);
    final order = option.trim().isEmpty ? 'date_d' : option.trim();
    final safePage = page <= 0 ? 1 : page;
    final url =
        Uri.parse('$pixivWebBase/ajax/search/artworks/$encoded').replace(
      queryParameters: <String, String>{
        'word': word,
        'mode': 'safe',
        'p': safePage.toString(),
        'order': order,
        's_mode': 's_tag',
      },
    ).toString();

    // 搜索接口的 Referer 必须是站点根（不带具体路径），否则 Pixiv 视为跨站请求。
    final res = await _getJson(url);
    if (res.error) return Res.fromErrorRes(res);
    try {
      final items = parsePixivSearchItems(res.data);
      return Res<List<PixivComicBrief>>(
        items,
        subData: parsePixivSearchMaxPage(res.data),
      );
    } catch (e) {
      return Res.error('搜索解析失败：$e', errorCode: ResErrorCode.parse);
    }
  }

  /// 取排行榜（`/ranking.php?format=json`）。
  ///
  /// 该接口与其他 Ajax 接口不同：走 `ranking.php` 且返回顶层 `contents` 数组，
  /// 因此不能用 `_getJson` 的 `body` 约定，这里单独请求后交给
  /// [parsePixivRankingItems]（字段是下划线风格）。
  Future<Res<List<PixivComicBrief>>> getRanking({
    String mode = 'daily',
    String content = 'illust',
    int page = 1,
  }) async {
    final safePage = page <= 0 ? 1 : page;
    final url = Uri.parse('$pixivWebBase/ranking.php').replace(
      queryParameters: <String, String>{
        'format': 'json',
        'mode': mode,
        'content': content,
        'p': safePage.toString(),
      },
    ).toString();
    final res = await _getJson(url);
    if (res.error) return Res.fromErrorRes(res);
    try {
      return Res<List<PixivComicBrief>>(parsePixivRankingItems(res.data));
    } catch (e) {
      return Res.error('榜单解析失败：$e', errorCode: ResErrorCode.parse);
    }
  }

  /// 榜单每页条数（`ranking.php` 固定每页 50）。
  static const rankingPageSize = 50;

  /// 推荐（首页插画推荐）。
  ///
  /// 走 `illust/recommended-nologin`（**游客版**）而不是需要登录的
  /// `illust/recommended`：本源自用场景优先保证未登录也能看到内容，
  /// 拿到的是公开推荐池；带 PHPSESSID 时服务端会返回更贴合账号的结果。
  ///
  /// `content_type=illust` 只取插画（不含 manga），与「推荐」入口的语义一致。
  /// 该接口无可靠的分页契约，故不暴露 page 参数，调用方按单页处理。
  Future<Res<List<PixivComicBrief>>> getRecommended() async {
    final url = Uri.parse(
      '$pixivWebBase/ajax/illust/recommended-nologin',
    ).replace(
      queryParameters: <String, String>{
        'content_type': 'illust',
        'include_ranking_label': 'true',
      },
    ).toString();
    final res = await _getJson(url);
    if (res.error) return Res.fromErrorRes(res);
    final body = res.data['body'];
    if (body is! Map) {
      return const Res.error('推荐响应结构异常', errorCode: ResErrorCode.parse);
    }
    try {
      return Res<List<PixivComicBrief>>(
        parsePixivSearchItems(<String, dynamic>{
          'illust': <String, dynamic>{
            'data': (body['illusts'] as List?) ?? const <dynamic>[],
          },
        }),
      );
    } catch (e) {
      return Res.error('推荐解析失败：$e', errorCode: ResErrorCode.parse);
    }
  }

  /// 拉一次站点首页 HTML，解析出**当前登录用户**的 uid，并写入源数据。
  ///
  /// ## 为什么走页面 HTML 而不是 ajax 接口
  ///
  /// Pixiv 没有"返回我自己 uid"的公开 ajax 接口——所有 `/ajax/user/{uid}/...`
  /// 都要 uid 入参，构成循环依赖。而首页 HTML 里一定内嵌了当前用户信息
  /// （`global-data` meta 的 `userData`），`pixiv-web-api` 的 `findUserId`
  /// 也是这个思路。解析规则见 [parsePixivUserIdFromHtml]。
  ///
  /// ## 为什么要落盘
  ///
  /// 收藏列表接口的路径必须带 uid，每次收藏都重新拉一次首页代价太大；
  /// 成功一次就写进 `data['userId']` 存起来。
  ///
  /// 失败时返回的错误**区分两种情况**：
  /// - 没有会话 → `loginRequired`（真的未登录）；
  /// - 有会话但解析不出 → `parse`（已登录，站点结构变了），并带上状态码与
  ///   页面长度，便于判断是拿到风控页还是页面结构变了。
  Future<Res<String>> fetchUserId() async {
    if (_session == null) {
      return const Res.error('需要登录', errorCode: ResErrorCode.loginRequired);
    }
    final dio = logDio();
    try {
      final response = await dio.get<String>(
        '$pixivWebBase/',
        options: Options(
          // 要的是 HTML 原文，必须显式 plain（这里 T 是 String，dio 本就会
          // 强制 plain，显式写出来是为了不依赖那条隐式规则）。
          responseType: ResponseType.plain,
          // **不能复用 [_baseHeaders]**：那里是 `Accept: application/json`
          // （给 ajax 接口用的），拿它去请求首页会被按 AJAX 处理，
          // 可能返回 JSON 或 406，而不是我们要解析的 HTML 页面。
          headers: <String, dynamic>{
            'Referer': '$pixivWebBase/',
            'User-Agent': pixivWebUA,
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            if (_cookieHeader().isNotEmpty) 'Cookie': _cookieHeader(),
          },
          validateStatus: (status) =>
              status == 200 ||
              (status != null && status >= 400 && status < 500),
        ),
      );
      final html = response.data ?? '';
      final userId = parsePixivUserIdFromHtml(html);
      if (userId == null) {
        return Res.error(
          '未能从 Pixiv 页面解析出用户 ID'
          '（HTTP ${response.statusCode}，页面长度 ${html.length}）',
          errorCode: ResErrorCode.parse,
          statusCode: response.statusCode,
        );
      }
      await _saveUserId(userId);
      return Res(userId);
    } on DioException catch (error) {
      return Res.error(
        error.message ?? error.toString(),
        errorCode: ResErrorCode.network,
        statusCode: error.response?.statusCode,
      );
    } catch (error, stackTrace) {
      LogManager.addLog(
        LogLevel.error,
        'PixivNetwork',
        'fetchUserId failed: $error\n$stackTrace',
      );
      return Res.error(error.toString(), errorCode: ResErrorCode.network);
    }
  }

  /// 把 uid 写进源数据并落盘；源未注册时静默跳过（不阻断主流程）。
  Future<void> _saveUserId(String userId) async {
    final source = ComicSource.find('pixiv');
    if (source == null) return;
    source.data['userId'] = userId;
    try {
      await source.saveData();
    } catch (error, stackTrace) {
      LogManager.addLog(
        LogLevel.warning,
        'PixivNetwork',
        'save userId failed: $error\n$stackTrace',
      );
    }
  }

  /// 收藏列表每页条数（Pixiv Web 端书签页固定 48）。
  static const bookmarkPageSize = 48;

  /// 取当前登录账号的收藏（书签）列表。
  ///
  /// 接口：`/ajax/user/{userId}/illusts/bookmarks?tag=&offset={offset}`
  /// `&limit=48&rest=show&lang=zh`。
  ///
  /// 关键决策：
  /// - `userId` 取自源配置 `ComicSource.find('pixiv')?.data['userId']`（登录时由
  ///   WebView 从页面读出）。**没有 userId 时直接返回 loginRequired**：书签接口
  ///   的路径里必须带 userId，缺了它连"公开书签"都无法定位到具体用户，
  ///   只有明确报错才不会让上层把空 URL 请求当成"没有收藏"。
  /// - `offset` 用 `(page - 1) * 48` 折算：该接口是偏移量分页而非页码分页，
  ///   语义与其它源的 `page` 不同，这里在网络层内部收敛，对外仍是页码。
  /// - 请求**允许未登录发出**（此处不传 requireAuth）：Pixiv 的公开书签无需
  ///   登录即可读取，只是拿到的是公开部分；有 PHPSESSID 时会一并带上，
  ///   服务端据此返回含私密书签的完整列表。
  /// - `body.total` 是**书签总数**（不是页数），原样放进 [Res.subData]；
  ///   字段缺失时不传，由调用方退回保守判停。
  ///
  /// **uid 缺失时会先自愈再报错**（见下），不再直接把"已登录"报成"需要登录"。
  Future<Res<List<PixivComicBrief>>> getBookmarks(int page) async {
    var userId =
        ComicSource.find('pixiv')?.data['userId']?.toString().trim() ?? '';
    if (userId.isEmpty) {
      // 自愈：uid 可能因为旧版本登录（当时从 cookie 猜、拿不到）而缺失，
      // 也可能被清缓存抹掉。这里主动补一次，而不是让用户去"重新登录"——
      // 重新登录并不能解决 uid 解析的问题，那是把用户引向无效路径。
      final fetched = await fetchUserId();
      if (fetched.error) {
        // 关键：**不报 loginRequired**。会话本身是有效的（否则 [fetchUserId]
        // 会先返回 loginRequired），失败原因只是 uid 没解析出来。
        // 报"需要登录"正是本次缺陷的症状，会把排查引偏。
        return Res.error(
          '无法获取 Pixiv 用户 ID：${fetched.errorMessageWithoutNull}',
          errorCode: ResErrorCode.parse,
          statusCode: fetched.statusCode,
        );
      }
      userId = fetched.data;
    }

    final safePage = page <= 0 ? 1 : page;
    final offset = (safePage - 1) * bookmarkPageSize;
    final url =
        Uri.parse('$pixivWebBase/ajax/user/$userId/illusts/bookmarks').replace(
      queryParameters: <String, String>{
        // tag 留空表示"全部标签"；Pixiv 要求该参数必须存在，不能省略。
        'tag': '',
        'offset': offset.toString(),
        'limit': bookmarkPageSize.toString(),
        // rest=show 才会返回完整作品条目（hide 只给 id）。
        'rest': 'show',
        'lang': 'zh',
      },
    ).toString();

    final res = await _getJson(url);
    if (res.error) return Res.fromErrorRes(res);
    final body = res.data['body'];
    if (body is! Map) {
      return const Res.error('Pixiv 收藏响应缺少 body',
          errorCode: ResErrorCode.parse);
    }
    try {
      final map = body.map((k, v) => MapEntry(k.toString(), v));
      final total = map['total'];
      return Res<List<PixivComicBrief>>(
        parsePixivBookmarkItems(map),
        // total 缺失（结构变化）时不传，避免上层把 null 当成"0 条"而误判到底。
        subData: total is num ? total.toInt() : null,
      );
    } catch (e) {
      return Res.error('收藏解析失败：$e', errorCode: ResErrorCode.parse);
    }
  }

  /// 添加 / 取消收藏（书签）。
  ///
  /// - 加书签：POST `/ajax/illusts/bookmarks/add`，body
  ///   `{"comment":"","illust_id":<int>,"restrict":0,"tags":[]}`；
  /// - 取消书签：POST `/ajax/illusts/bookmarks/delete`，body
  ///   `{"illust_id":<int>}`。
  ///
  /// `restrict: 0` 表示**公开**书签（与 Web 默认一致）；本项目不提供私密书签
  /// 开关，理由同文件头的 safe mode 决策：不给用户制造"收藏了别人看不到"的
  /// 意外。`comment` / `tags` 留空，本源的收藏是纯收藏夹语义（见 pixiv.dart 的
  /// `multiFolder: false`），不回写备注与标签，避免覆盖用户在 Web 端写的内容。
  ///
  /// 两个接口都需要登录态：`requireAuth: true` 会在本地就拦下未登录调用，
  /// 不发无意义的请求（服务端也会返回 401/403，由 [_postJson] 兜底归类）。
  /// `illust_id` 必须转成 int：Pixiv 这里不接受字符串 id，传字符串会被拒。
  Future<Res<bool>> setBookmark(
    String illustId, {
    required bool isAdding,
  }) async {
    final id = int.tryParse(illustId.trim());
    if (id == null) {
      return const Res.error('作品 id 无效',
          errorCode: ResErrorCode.invalidArgument);
    }
    if (!isLoggedIn) {
      return const Res.error('需要登录', errorCode: ResErrorCode.loginRequired);
    }

    final path = isAdding ? 'add' : 'delete';
    final payload = isAdding
        ? <String, dynamic>{
            'comment': '',
            'illust_id': id,
            'restrict': 0,
            'tags': <String>[],
          }
        : <String, dynamic>{
            'illust_id': id,
          };

    final res = await _postJson(
      '$pixivWebBase/ajax/illusts/bookmarks/$path',
      payload,
      requireAuth: true,
      // **Referer 精确到作品页，而不是站点根。**
      //
      // Pixiv 的收藏动作在网页上是从作品页发起的，站点对写操作可能校验
      // Referer 与目标作品是否一致；用根路径会被判成"跨页伪造的请求"，
      // 而这类拒绝的回复往往只说"请重新登录"，不点明真实原因。
      // 真机症状正是"读接口全正常、写接口被拒并提示重新登录"。
      referer: '$pixivWebBase/artworks/$id',
    );
    if (res.error) {
      // 记日志：Pixiv 的业务错误是 HTTP 200 + `error:true`，
      // 不会触发网络层的 4xx 日志，不显式记下来就完全查不到现场。
      LogManager.addLog(
        LogLevel.warning,
        'PixivNetwork',
        '收藏${isAdding ? '添加' : '移除'}失败（illust=$id）：'
            '${res.errorMessageWithoutNull}'
            '(HTTP ${res.statusCode}, csrf=${_csrfToken == null ? "无" : "有"})',
      );
      return Res.fromErrorRes(res);
    }
    return const Res<bool>(true);
  }
}
