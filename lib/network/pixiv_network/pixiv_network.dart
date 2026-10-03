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

  /// 把一次失败的**可诊断特征**拼成一句话：步骤 + HTTP 状态码 + Content-Type +
  /// 正文片段。
  ///
  /// 为什么必须带上这些：作者页三步链路里第 3 步
  /// （`profile/illusts` 的 `ids[]` 复数 GET）**只在 PixivFE v3.0.3 的实现里被
  /// 证实过，尚未真机验证**。真机一旦失败，日志里若只有"加载失败"，
  /// 就分不清是"端点换了（404/405/HTML 风控页）"还是"只读接口被限流"，
  /// 也看不出该换 POST 还是换 `/touch/ajax/illust/details/many`。
  ///
  /// 只记**响应正文片段**（不含请求头/Cookie），符合项目"凭据绝不进日志"的约定。
  String _httpDiagnostics({
    required String? step,
    required int? statusCode,
    required Map<String, List<String>> headers,
    required String raw,
  }) {
    if (step == null) return '';
    final contentType = headers['content-type']?.join(', ') ?? '无';
    return '（$step；HTTP ${statusCode ?? '无'}；Content-Type: $contentType；'
        '正文片段: ${_clipBodyForLog(raw)}）';
  }

  /// 正文片段（折叠空白、截断），仅用于错误文案。
  String _clipBodyForLog(String raw, [int max = 200]) {
    final normalized = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return '<空>';
    return normalized.length <= max
        ? normalized
        : '${normalized.substring(0, max)}…';
  }

  /// 统一的 JSON GET。
  ///
  /// [retrying] 是**内部重试标记**：空响应/非 JSON（典型的风控拦截或半截响应）
  /// 属于可自愈的瞬时失败，这里最多再试一次；重试时置 true 以避免无限重试。
  /// 外部调用方不应传该参数。
  ///
  /// [step] 是**可选的失败诊断标签**（例如 `作者作品详情 GET /ajax/user/1/profile/illusts`）。
  /// 传了它，所有失败分支都会附上 HTTP 状态码 / Content-Type / 正文片段
  /// （见 [_httpDiagnostics]）；不传则文案与本参数引入前**完全一致**，
  /// 已有调用点（搜索 / 收藏 / 详情 / 榜单 / 推荐）的行为不受影响。
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
    String? step,
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
          //
          // 43 号复核：**放行 4xx 是有意的，也是对的** —— 429 同样包含在内。
          // 它不会变成"静默失败"，因为两层各管各的：
          // - **错误识别在这一层**：429 的响应体照样会走下面的 `error` 判定
          //   （43 号已把判据从"只认布尔真"扩展到"字符串形态也认"）；
          // - **重试策略在适配器层**：`app_dio.dart` 的 `RetryHttpClientAdapter`
          //   已把 429 从"4xx 不重试"里单独摘出来，会退避后重试。
          // 所以这里**不需要也不应该**对 429 特殊处理。
          validateStatus: (status) =>
              status != null &&
              (status == 200 || (status >= 400 && status < 500)),
          headers: _baseHeaders(),
        ),
      );

      final statusCode = response.statusCode;
      final raw = response.data ?? '';
      final diagnostics = _httpDiagnostics(
        step: step,
        statusCode: statusCode,
        headers: response.headers.map,
        raw: raw,
      );

      // 401/403 优先按登录问题归类：即便响应体是 HTML 也要给出"需要登录"，
      // 否则用户看到的是含糊的解析失败。
      if (statusCode == 401 || statusCode == 403) {
        return Res.error(
          '需要登录$diagnostics',
          errorCode: ResErrorCode.loginRequired,
          statusCode: statusCode,
        );
      }

      if (raw.trim().isEmpty) {
        if (!retrying) {
          return _getJson(
            url,
            requireAuth: requireAuth,
            retrying: true,
            step: step,
          );
        }
        return Res.error(
          'Empty response$diagnostics',
          errorCode: ResErrorCode.parse,
          statusCode: statusCode,
        );
      }

      dynamic decoded;
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        if (!retrying) {
          return _getJson(
            url,
            requireAuth: requireAuth,
            retrying: true,
            step: step,
          );
        }
        return Res.error(
          'Pixiv 返回非 JSON（可能触发风控），请稍后重试或检查网络/登录状态'
          '$diagnostics',
          errorCode: ResErrorCode.parse,
          statusCode: statusCode,
        );
      }
      if (decoded is! Map) {
        return Res.error(
          'Pixiv 返回非 JSON（可能触发风控），请稍后重试或检查网络/登录状态'
          '（实际类型 ${describePixivJsonShape(decoded)}）$diagnostics',
          errorCode: ResErrorCode.parse,
          statusCode: statusCode,
        );
      }
      final json = decoded.map((key, value) => MapEntry(key.toString(), value));

      // ⚠️ 判据是「**`error` 这个键存在且不为 `false`**」，不能只判 `== true`。
      //
      // Pixiv 的出错响应有**两种形态**：
      //   1. `{"error": true, "message": "…"}`
      //   2. `{"error": "ランキングが見つかりませんでした"}` ← **字符串**
      //
      // 旧写法只认第一种，第二种会被当成成功响应往下走 —— 落到解析器时
      // `contents is! List` 成立、**返回空列表**，于是界面表现为
      // **"榜单/列表就是空的"，不报错、无提示**（本项目 35 号踩过同一类坑，
      // 那次是端点下线返回错误 JSON 被当正常数据）。
      // 本文件 `:890` 的注释里就记着第二种形态的实例。
      final errorFlag = json['error'];
      final hasError = errorFlag != null && errorFlag != false;
      if (hasError) {
        // 字符串形态没有 `message` 键，错误原因就在 `error` 本身。
        final rawMessage = json['message'] ?? (errorFlag is String ? errorFlag : null);
        final message = rawMessage?.toString();
        return Res.error(
          '${(message == null || message.isEmpty) ? 'Pixiv 接口返回错误' : message}'
          '$diagnostics',
          errorCode: _errorCodeForStatus(statusCode),
          statusCode: statusCode,
        );
      }

      return Res<Map<String, dynamic>>(json);
    } on DioException catch (e) {
      return Res.error(
        '${e.message ?? '网络请求失败'}'
        '${step == null ? '' : '（$step；HTTP ${e.response?.statusCode ?? '无'}）'}',
        errorCode: ResErrorCode.network,
        statusCode: e.response?.statusCode,
      );
    } catch (e) {
      return Res.error(
        '${e.toString()}${step == null ? '' : '（$step）'}',
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

      // 与 GET 侧同口径：**`error` 存在且不为 `false` 即失败**（字符串形态也要认）。
      // 详见 `_getJson` 里的说明。
      final postErrorFlag = json['error'];
      final postHasError = postErrorFlag != null && postErrorFlag != false;
      if (postHasError) {
        final rawMessage =
            json['message'] ?? (postErrorFlag is String ? postErrorFlag : null);
        final message = rawMessage?.toString();
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

  /// 取作品详情（`/ajax/illust/{id}?lang=zh`）。
  ///
  /// **`lang=zh` 不能省**：Pixiv 的 Ajax 错误消息**跟随这个参数**
  /// （见 [recommendedUrl] 的说明）。作品被删除 / 不存在时，不带它拿到的是
  /// **日文**服务端原文（如「作品が見つかりません」），会直接显示给用户。
  /// 本文件其它端点（搜索 `:954`、排行 `:1143`、作者页 `:1271/:1280/:1295`）
  /// 都带了，只有这里曾漏掉。
  Future<Res<PixivComicInfo>> getComicInfo(String id) async {
    if (id.trim().isEmpty) {
      return const Res.error('作品 id 为空',
          errorCode: ResErrorCode.invalidArgument);
    }
    final res = await _getJson('$pixivWebBase/ajax/illust/$id?lang=zh');
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
    // **必须先把 `body` 取出来再解析**：[_getJson] 交回的是**整个响应**
    // （`{error, message, body}`），搜索结果在 `body` 之下。把顶层直接喂给
    // [parsePixivSearchItems] 会让 `body['illustManga']` 恒为 null，
    // 表现为"搜索永远 0 条结果"，而且**不报任何错**——比报错难查得多。
    // 同一文件里 [getComicInfo] / [getBookmarks] 都是这个取值口径。
    final body = res.data['body'];
    if (body is! Map) {
      return Res.error(
        '搜索响应缺少 body'
        '（body 实际 ${describePixivJsonShape(res.data['body'])}；'
        '顶层键: ${describePixivJsonShape(res.data)}）',
        errorCode: ResErrorCode.parse,
      );
    }
    final map = body.map((key, value) => MapEntry(key.toString(), value));
    try {
      final items = parsePixivSearchItems(map);
      return Res<List<PixivComicBrief>>(
        items,
        subData: parsePixivSearchMaxPage(map),
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
  ///
  /// [content] 传空（默认）时按 [mode] 自动推导，见 [rankingContentForMode]：
  /// 三档"综合榜"必须用 `all`，否则 404。显式传入则原样使用（留给未来加漫画榜）。
  Future<Res<List<PixivComicBrief>>> getRanking({
    String mode = 'daily',
    String? content,
    int page = 1,
  }) async {
    final safePage = page <= 0 ? 1 : page;
    final requested = content?.trim() ?? '';
    final effectiveContent =
        requested.isEmpty ? rankingContentForMode(mode) : requested;
    final url = Uri.parse('$pixivWebBase/ranking.php').replace(
      queryParameters: <String, String>{
        'format': 'json',
        'mode': mode,
        'content': effectiveContent,
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

  /// 只提供"综合榜"、**不接受 `content=illust`** 的榜期。
  ///
  /// 实测（2026-09，宿主机直连）：
  /// - `original`（原创）/ `male`（男性向）/ `female`（女性向）带
  ///   `content=illust` 一律 **404**，正文是
  ///   `{"error":"ランキングが見つかりませんでした"}`（带 `lang=zh` 时变成
  ///   「抱歉，您现在无法当面访问pixiv的排行榜」——两句都不点明真实原因）；
  ///   改成 `content=all` 立刻 200 且仍是 50 条/页。
  /// - `daily` / `weekly` / `monthly` / `rookie` 四档相反：`content=illust` 正常，
  ///   所以**不能一刀切全用 `all`**。
  ///
  /// `content=all` 的榜单会混入漫画（`illust_type=1`），实测 50 条里 22 插画 +
  /// 28 漫画、且**每条都带 `illust_id`**（小说不进这个接口），因此
  /// [parsePixivRankingItems] 的"id 非数字则跳过"不会误伤，分页判停用的
  /// "满 50 条即还有下一页"也仍然成立。
  static const pixivRankingAllContentModes = <String>{
    'original',
    'male',
    'female',
  };

  /// 按榜期推导该用哪个 `content`：综合榜用 `all`，其余用 `illust`。
  static String rankingContentForMode(String mode) =>
      pixivRankingAllContentModes.contains(mode.trim()) ? 'all' : 'illust';

  /// 推荐端点使用的 `mode` 值。
  ///
  /// 实测 `illust/discovery` **只接受 `all`**：缺参或换成别的值（`rookie` /
  /// `original` / `illust` / `manga` …）一律 400 +「不正确的请求。」
  /// （不带 `lang=zh` 时是日文「不正なリクエストです。」）。
  /// 既然只有一个合法值，就不做成参数——省得调用方传一个必然失败的值。
  static const pixivDiscoveryMode = 'all';

  /// 推荐请求 URL。
  ///
  /// 单独抽成静态方法，是为了让"端点还活着吗"这件事**至少能被单测守住**：
  /// Pixiv 下线一个 Ajax 端点时不会有任何公告，只表现为 404，
  /// 而代码里看不出区别（见 [getRecommended] 的端点变更记录）。
  ///
  /// `lang=zh` 不只是文案偏好：**Pixiv 的 Ajax 错误消息跟随这个参数**。
  /// 不带时 404 正文是「リクエストされたページが見つかりませんでした」、
  /// 400 是「不正なリクエストです。」，会**原样显示在界面上**；
  /// 带上后分别是「无法找到您所请求的页面」/「不正确的请求。」。
  static String recommendedUrl() => Uri.parse(
        '$pixivWebBase/ajax/illust/discovery',
      ).replace(
        queryParameters: <String, String>{
          'mode': pixivDiscoveryMode,
          'lang': 'zh',
        },
      ).toString();

  /// 推荐（首页插画推荐）。
  ///
  /// ## 端点变更记录（2026-09，宿主机直连 + 真机复现）
  ///
  /// 原用的 `illust/recommended-nologin` **已被 Pixiv 下线**：任何参数组合都返回
  /// `404` + `{"error":true,"message":"リクエストされたページが見つかりませんでした","body":[]}`，
  /// 而 [_getJson] 会把服务端 `message` 原样带上来，于是探索页「推荐」分区
  /// 只剩这一句日文错误（用户看到的正是它）。需登录版的 `illust/recommended`
  /// 同样 404。这两个端点都已不可用，**不要改回去**。
  ///
  /// 现在走站点首页推荐位实际使用的 `illust/discovery?mode=all`，实测结论：
  /// - **游客可用**（不带任何 Cookie 也 200），符合本源自用场景；
  /// - 固定返回 **10 条**，`p` / `page` / `offset` / `limit` 传了也被忽略；
  /// - 每次请求返回的 10 条**内容不同**（推荐池滚动），所以"重新加载"有意义；
  /// - 响应只有 `body.illusts` 一个键，**没有游标也没有总数** → 不建立续页
  ///   （伪造分页会让用户以为"还有更多"却永远翻不到新内容）。
  ///
  /// 封面是 `360x360` 方图缩略图（`..._square1200.jpg`），比旧端点的 240x480
  /// 竖图更矮；探索页列表项按固定比例裁切显示，不受影响。
  Future<Res<List<PixivComicBrief>>> getRecommended() async {
    final res = await _getJson(recommendedUrl());
    if (res.error) return Res.fromErrorRes(res);
    final body = res.data['body'];
    if (body is! Map) {
      return Res.error(
        '推荐响应缺少 body'
        '（body 实际 ${describePixivJsonShape(res.data['body'])}；'
        '顶层键: ${describePixivJsonShape(res.data)}）',
        errorCode: ResErrorCode.parse,
      );
    }
    try {
      return Res<List<PixivComicBrief>>(
        parsePixivDiscoveryItems(
          body.map((key, value) => MapEntry(key.toString(), value)),
        ),
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

  // ═════════════════════════════════════════════════════════════════════════
  //  作者页（App 内）三步链路
  //
  //  为什么是三步而不是一步：Pixiv **没有**"给我这个作者的作品列表"这种一次到位的
  //  读接口。活跃实现（PixivFE v3.0.3 的 core/user.go）的做法就是：
  //  取作者资料 → 取全部作品 id → 按 id 批量取作品详情。本实现照抄该链路。
  //
  //  ⚠️→✅ 三步链路的验证状态（已更新）：**已用真实请求逐条验证通过**
  //  （2026-09，宿主机直连 www.pixiv.net，游客态，无 Cookie）：
  //  - 第 1 步 200，`body` 带 `userId` / `name` / `following` / `comment` / `image`；
  //  - 第 2 步 200，`body.illusts` 是 `{id: null}` 的 **map**；**没有漫画的作者**
  //    回来的是 `body.manga = []`（空**数组**而不是 map）——所以
  //    [isPixivWorkIdContainer] 必须同时认 Map 与 List，否则"这个作者没画漫画"
  //    会被误报成"形状不符"；
  //  - 第 3 步 200，`body.works` 是 `{id: 作品对象}` 的 **map**，单项字段与搜索项
  //    同构（`_parseBriefItem` 可直接吃）。
  //  当初标为"未验证"是因为当时开发沙箱访问不了 www.pixiv.net，该限制现已不存在。
  //  各失败分支仍保留可诊断特征（步骤名 + HTTP 状态码 + Content-Type + 正文片段 +
  //  实际形状），端点若再变可据此直接判断"换 POST 还是换 /touch/ajax/illust/details/many"。
  // ═════════════════════════════════════════════════════════════════════════

  /// 作者作品列表每页条数。
  ///
  /// 取 30 与 PixivFE 的 `userWorksPageSize` 一致：该值决定"一次 `ids[]` 请求带
  /// 多少个 id"，太大容易被服务端截断/拒（URL 也会变长），太小则请求数翻倍。
  static const authorWorksPageSize = 30;

  /// 作者资料 URL（`GET /ajax/user/{uid}?full=1&lang=zh`）。
  ///
  /// `full=1` 才会带简介/关注数等作者页要展示的字段（不带时是精简形态）。
  /// 端点依据：PixivFE `core/endpoints.go` 的 `GetUserInformationURL`；
  /// 字段依据：pixiv-ajax-api-docs 的 `9153585_full_1.json` 样例响应
  /// （外加 2026-09 的真实请求复核）。
  ///
  /// `lang=zh` 的作用见 [recommendedUrl]：**Pixiv 的 Ajax 错误消息跟着它走**，
  /// 不带时失败信息是日文，会原样显示给用户。
  static String authorInfoUrl(String uid) =>
      '$pixivWebBase/ajax/user/$uid?full=1&lang=zh';

  /// 作者全部作品 id 的 URL（`GET /ajax/user/{uid}/profile/all`）。
  ///
  /// 端点依据：PixivFE 的 `GetUserWorksURL`；响应形状依据同名样例响应以及
  /// 2026-09 的真实请求复核（`body.illusts` / `body.manga` 是 `{id: null}` 的 map，
  /// 其中**没有作品的那一类可能是空数组 `[]`**，[parsePixivUserWorkIds] 两种都吃）。
  /// `lang=zh` 同上，只为让失败文案是中文。
  static String authorWorkIdsUrl(String uid) =>
      '$pixivWebBase/ajax/user/$uid/profile/all?lang=zh';

  /// 按 id 批量取作品详情的 URL
  /// （`GET /ajax/user/{uid}/profile/illusts?work_category=illustManga&is_first_page=0
  /// &lang=zh&ids[]=…`）。
  ///
  /// - `work_category=illustManga`：**插画与漫画一起取**。作者页应当显示"全部作品"，
  ///   分类下钻不在本轮范围内（与搜索列表"两类合并"的既有决策一致）；
  /// - `is_first_page=0`：这不是作者页首屏那次请求（首屏语义归 PixivFE 的前端），
  ///   我们只按 id 取详情，置 0 与 PixivFE 的 `GetUserFullArtworkURL` 相同；
  /// - `ids[]` 必须**重复出现**，不能写成逗号拼接——用 `queryParameters` 表达不了
  ///   重复键，故这里手工拼串；id 已在调用前校验为纯数字，无需转义。
  static String authorWorksUrl(String uid, List<String> ids) {
    final buffer = StringBuffer(
      '$pixivWebBase/ajax/user/$uid/profile/illusts'
      '?work_category=illustManga&is_first_page=0&lang=zh',
    );
    for (final id in ids) {
      buffer.write('&ids[]=$id');
    }
    return buffer.toString();
  }

  /// 取作者资料（链路第 1 步）。
  ///
  /// 不要求登录：公开作者资料游客可见，而 ID 直跳区的 chip 也不以登录为前提
  /// （搜索页只要源已注册就会给出 chip）。
  Future<Res<PixivAuthor>> getAuthorInfo(String uid) async {
    final id = uid.trim();
    if (id.isEmpty || int.tryParse(id) == null) {
      return const Res.error(
        '作者 uid 无效（应为纯数字）',
        errorCode: ResErrorCode.invalidArgument,
      );
    }
    const stepLabel = '作者信息';
    final res = await _getJson(
      authorInfoUrl(id),
      step: '$stepLabel GET ${authorInfoUrl(id)}',
    );
    if (res.error) return Res.fromErrorRes(res);
    final body = res.data['body'];
    if (body is! Map) {
      return Res.error(
        '$stepLabel响应缺少 body'
        '（body 实际 ${describePixivJsonShape(res.data['body'])}；'
        '顶层键: ${describePixivJsonShape(res.data)}）',
        errorCode: ResErrorCode.parse,
      );
    }
    try {
      return Res<PixivAuthor>(
        parsePixivAuthorInfo(body.map((k, v) => MapEntry(k.toString(), v))),
      );
    } catch (e) {
      return Res.error(
        '$stepLabel解析失败：$e（body 键: '
        '${body.keys.map((k) => k.toString()).take(12).join(', ')}）',
        errorCode: ResErrorCode.parse,
      );
    }
  }

  /// 取作者全部作品 id（链路第 2 步）。
  ///
  /// 单独暴露成私有方法只为一件事：**让失败能归因到具体步骤**。
  /// 第 3 步的报错文案里会带上"id 列表已拿到 N 个"，从而区分
  /// "取不到 id（第 2 步问题）"与"取详情失败（第 3 步问题）"。
  Future<Res<List<String>>> _fetchAuthorWorkIds(String uid) async {
    const stepLabel = '作者作品 id 列表';
    final url = authorWorkIdsUrl(uid);
    final res = await _getJson(url, step: '$stepLabel GET $url');
    if (res.error) return Res.fromErrorRes(res);
    final body = res.data['body'];
    if (body is! Map) {
      return Res.error(
        '$stepLabel响应缺少 body'
        '（body 实际 ${describePixivJsonShape(res.data['body'])}；'
        '顶层键: ${describePixivJsonShape(res.data)}）',
        errorCode: ResErrorCode.parse,
      );
    }
    final map = body.map((k, v) => MapEntry(k.toString(), v));
    // 形状不符时如实报出**实际类型/键名**，不静默当成"没有作品"。
    if (!isPixivWorkIdContainer(map['illusts']) ||
        !isPixivWorkIdContainer(map['manga'])) {
      return Res.error(
        '$stepLabel形状不符：期望 illusts/manga 为 {id: null} 的 map，实际 '
        'illusts=${describePixivJsonShape(map['illusts'])}, '
        'manga=${describePixivJsonShape(map['manga'])}'
        '（body 键: ${map.keys.take(12).join(', ')}）',
        errorCode: ResErrorCode.parse,
      );
    }
    return Res<List<String>>(parsePixivUserWorkIds(map));
  }

  /// 取作者作品列表的某一页（链路第 2 + 3 步）。
  ///
  /// 分页语义：**先拿全部 id（数值倒序 = 新作在前），再按 [authorWorksPageSize]
  /// 切片**，然后用切片里的 id 批量取详情。因此"第 N 页"是稳定且可枚举的，
  /// 不像偏移量分页那样在作者发布新作时整体错位。
  ///
  /// [Res.subData] 放**总页数**（`ids.length / pageSize` 向上取整），
  /// 调用方据此判停；`0` 表示该作者没有任何公开作品。
  Future<Res<List<PixivComicBrief>>> getAuthorWorks(
    String uid, {
    int page = 1,
    int pageSize = authorWorksPageSize,
  }) async {
    final id = uid.trim();
    if (id.isEmpty || int.tryParse(id) == null) {
      return const Res.error(
        '作者 uid 无效（应为纯数字）',
        errorCode: ResErrorCode.invalidArgument,
      );
    }
    final safePage = page <= 0 ? 1 : page;
    final safePageSize = pageSize <= 0 ? authorWorksPageSize : pageSize;

    final idsRes = await _fetchAuthorWorkIds(id);
    if (idsRes.error) return Res.fromErrorRes(idsRes);
    final ids = idsRes.data;
    final totalPages =
        ids.isEmpty ? 0 : ((ids.length + safePageSize - 1) ~/ safePageSize);

    // 越界（含"作者没有作品"）返回空列表 + 总页数，让 UI 正常判停：
    // 这里不是错误，报错会让"翻到底"显示成故障。
    if (ids.isEmpty || safePage > totalPages) {
      return Res<List<PixivComicBrief>>(
        const <PixivComicBrief>[],
        subData: totalPages,
      );
    }

    final start = (safePage - 1) * safePageSize;
    final end = start + safePageSize > ids.length
        ? ids.length
        : start + safePageSize;
    final slice = ids.sublist(start, end);

    const stepLabel = '作者作品详情';
    final url = authorWorksUrl(id, slice);
    final res = await _getJson(
      url,
      step: '$stepLabel GET /ajax/user/$id/profile/illusts'
          '(work_category=illustManga, ids=${slice.length} 个, 第 $safePage/$totalPages 页)',
    );
    if (res.error) return Res.fromErrorRes(res);
    final body = res.data['body'];
    if (body is! Map) {
      return Res.error(
        '$stepLabel响应缺少 body'
        '（body 实际 ${describePixivJsonShape(res.data['body'])}；'
        '顶层键: ${describePixivJsonShape(res.data)}）',
        errorCode: ResErrorCode.parse,
      );
    }
    final map = body.map((k, v) => MapEntry(k.toString(), v));
    final works = parsePixivUserWorks(map);
    if (works.isEmpty) {
      // 200 但一条都没解析出来：**必须报出来**，不能当成"没有作品"——
      // 请求带了 ${slice.length} 个 id，正常至少能回一部分。
      //
      // 43 号复核：这里**保持报错**是**有意的**，不改为"静默返回空列表"。
      // 理由：它是"**响应结构变了**"的唯一探测点，而结构变更恰恰是本项目
      // 踩过多次的坑（35 号的端点下线、键名变更，**全都是静默的**）。
      // 改成静默等于主动撤掉哨兵 —— 那类故障将重新变得不可发现。
      //
      // 但原文案只对开发者有意义，所以补上**用户能理解的原因**：
      // 30 个 id 全部不可见时，最常见的现实原因是作者把这批作品删了或
      // 设为不公开，其次才是我们解析出错。
      return Res.error(
        '$stepLabel一条都没解析出来（请求了 ${slice.length} 个 id）。'
        '常见原因：这些作品已被作者删除或设为不公开；'
        '若反复出现，则可能是 Pixiv 的响应结构变了。'
        '（期望 body.works 为 {id: 作品} 的 map，实际 '
        '${describePixivJsonShape(map['works'])}'
        '；body 键: ${map.keys.take(12).join(', ')}）',
        errorCode: ResErrorCode.parse,
      );
    }
    return Res<List<PixivComicBrief>>(works, subData: totalPages);
  }
}
