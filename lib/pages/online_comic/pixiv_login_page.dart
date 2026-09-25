import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show CookieManager, WebUri;
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/tools/translations.dart';

import 'account_webview_login.dart';
import 'webview_login_round.dart';

/// Pixiv 登录页（WebView 抓 `PHPSESSID`）。
///
/// ## 成功判定（cookie 基线比对）
///
/// 1. **第一次**读到 cookie 快照时，把它记为**基线**（此刻用户还没提交登录表单）；
/// 2. 之后每次快照：`PHPSESSID` 非空且**与基线不同** → 本次确实产生了新会话 → 提交；
/// 3. 唯一例外：基线本身**非空**（说明打开前就有旧会话、清理没生效）时，
///    额外要求"已离开登录页"，避免把打开时就存在的会话算成本次登录。
///
/// ### 为什么把"采基线"和"判提交"合并在同一个临界区
///
/// 早期实现让两者各自独立发请求，可能并发；若基线读到的是登录**后**的快照，
/// `sessId == baseline` 将永远成立 → 一直不提交（表现为"登录成功但不自动返回"）。
/// 合并后基线只在首次快照确定，不存在竞态。
///
/// ## 判定条件的演进（两个都被真机推翻过的版本，勿回退）
///
/// **v1（秒退）**：「已离开登录页 + `PHPSESSID` 非空」。
/// 问题：入口是**首页**，所以"已离开登录页"从第一帧恒真；而 Pixiv **匿名访问
/// 首页也会下发 `PHPSESSID`** → WebView 一打开就自动关窗（用户实测反馈）。
///
/// **v2（登录后不自动返回）**：加"必须观察到曾在登录页"（`seenLoginPage`）当闸门。
/// 问题：该闸门依赖**标题**识别登录页，但 Pixiv 登录页在 `accounts.pixiv.net`，
/// WebView 只回传标题（**拿不到 URL**），标题形如「ログイン - pixiv」；
/// 一旦标题语言不在标记表内、或首次回调时用户已完成登录而直接是登录后页面，
/// `seenLoginPage` 恒为 false → 登录成功了页面却不返回（用户实测反馈）。
///
/// **v3（当前）**：改用 **cookie 基线比对**。会话值变化与页面语言、标题文案、
/// 导航时序全都无关，是唯一稳定的客观信号。
///
/// 不复用 [AccountWebLoginSession.collect] 的原因：该路径按 [AccountLoginSite]
/// 硬编码了 NH/EH 的 cookie URL 与成功条件（`account_webview_login.dart` 的
/// `_readCandidate`），枚举里没有 pixiv；这里直接驱动
/// [AccountLoginWebviewFactory] + [WebviewLoginRound]，复用同一套轮次状态机
/// （迟到回调按轮次丢弃、一轮最多提交一次），UI 门禁仍交给基类的 [runLogin]。
///
/// 降级入口：手填 `PHPSESSID`，供 WebView 不可用或抓不到 cookie 时使用。
class PixivLoginPage extends StatefulWidget {
  const PixivLoginPage({
    super.key,
    this.webviewFactory = createAccountLoginWebview,
    this.submitCredentials,
  });

  final AccountLoginWebviewFactory webviewFactory;
  final AccountLoginSubmit? submitCredentials;

  @override
  State<PixivLoginPage> createState() => _PixivLoginPageState();
}

class _PixivLoginPageState extends AccountCookieLoginState<PixivLoginPage> {
  @override
  String get sourceKey => 'pixiv';

  /// 登录入口：**必须是登录页**，不是首页。
  ///
  /// 依据 [pixiv-web-api](https://github.com/Sn0wCrack/pixiv-web-api) 的
  /// `LOGIN_PAGE_URL = 'https://accounts.pixiv.net/login'`。登录成功后 Pixiv 会
  /// 跳回 `www.pixiv.net`，这次迁移才是"本次登录完成"的信号。
  ///
  /// `return_to` 让登录后回到主站首页，用户能立刻看到已登录状态。
  static const _loginUrl =
      'https://accounts.pixiv.net/login?return_to=https%3A%2F%2Fwww.pixiv.net%2F';

  /// 登录/注册页标题或 URL 片段：命中任一即认为"还在登录页"。
  ///
  /// **注意：这只是辅助信号**，主判据是 cookie 基线比对（见类文档）。
  /// 标题回调只给标题、不给 URL，且 Pixiv 会按账号语言返回不同文案，
  /// 因此这里尽量覆盖常见语言形态，但**不能依赖它决定成败**。
  ///
  /// 标记必须足够具体：裸 `login` / `登录` 会把站内含该词的页面误判成登录页，
  /// 让辅助判断长期为 true（虽然主判据不受影响，但会削弱这一层保护）。
  static const _loginPathMarkers = <String>[
    // 入口域名（若未来回调能带 URL，这条最可靠）。
    'accounts.pixiv.net',
    // 主站登录/注册路由。
    '/auth/login',
    '/register',
    '/signup',
    'account/register',
    // 标题形态：英文 / 日文 / 中文。
    'login - pixiv',
    'ログイン - pixiv',
    'pixivにログイン',
    'pixiv 登入',
    'pixiv 登录',
    'pixiv 登録',
  ];

  final _sessIdController = TextEditingController();

  @override
  void dispose() {
    _sessIdController.dispose();
    super.dispose();
  }

  /// 判定"还在登录页"：按 URL/标题里的登录路由标记判断。
  ///
  /// 优先用 URL 路径（稳定契约）；WebView 只给标题时退化为标题匹配——两者的
  /// 关键词集合一致，因此合并成一个判断。拿不到任何文本时保守返回 true
  ///（视为仍在登录页），宁可多轮询也不秒退。
  bool _isOnLoginPage(String? text) {
    final value = text?.trim().toLowerCase() ?? '';
    if (value.isEmpty) return true;
    for (final marker in _loginPathMarkers) {
      if (value.contains(marker)) return true;
    }
    return false;
  }

  Future<void> _loginWithWebview() => runLogin(_runWebviewRound);

  /// 单轮 WebView 登录：打开登录页 → 轮询 cookie → 判据成立则提交。
  Future<bool> _runWebviewRound() async {
    await _clearWebviewSessionCookie();

    final round = WebviewLoginRound();
    final id = round.begin();
    final closed = Completer<void>();
    AccountLoginWebview? webview;
    Timer? timer;

    // 最近一次回调提供的 reader（移动端随导航/标题变化，桌面端 2 秒轮询）。
    AccountLoginReader? reader;
    // 最近一次已知的「是否仍在登录页」（仅作为**辅助**信号，见下）。
    var onLoginPage = true;
    Map<String, String>? captured;
    var reading = false;

    /// **登录前**的会话基线。
    ///
    /// 这是本页判定的核心：`_clearWebviewSessionCookie()` 之后理论上应为空，
    /// 但清理可能失败（无 API、权限、实现差异），所以显式记下"打开前是什么"。
    /// 登录成功必须体现为 **PHPSESSID 与基线不同**，否则就是旧会话残留。
    ///
    /// 用哨兵区分"未采集"（null）与"采集到空"（''）。
    String? baselineSessId;

    /// 从一次 cookie 快照里同时完成「采基线」或「判提交」。
    ///
    /// **为什么把两件事合并在同一个 harvest 临界区里**：早期实现让
    /// `captureBaseline` 与 `read` 各自独立发请求，二者可能并发；
    /// 若基线读到的其实是"用户已登录后"的快照，则 `sessId == baselineSessId`
    /// 永远成立 → 一直不提交，表现为"登录成功了但不自动返回"。
    /// 合并后**第一次**读到 cookie 时确定基线，后续都基于同一基线判断，
    /// 不再有并发竞态。
    void handleCookies(Map<String, String> cookies, bool onLoginPageNow) {
      final sessId = cookies[PixivNetwork.phpSessIdCookieName]?.trim() ?? '';

      // 首次拿到任何快照 → 这就是基线（此时用户尚未提交登录表单，
      // 因为回调/轮询发生在页面刚打开时）。
      if (baselineSessId == null) {
        baselineSessId = sessId;
        return;
      }

      if (sessId.isEmpty) return;
      // 与基线相同 → 旧会话，不是本次登录产生的。
      if (sessId == baselineSessId) return;
      // 基线为空（清理成功）或值已变化 → 本次确实产生了新会话。
      // 仅在"基线非空且尚未离开登录页"这种可疑情形下额外要求已离开登录页。
      if (baselineSessId!.isNotEmpty && onLoginPageNow) return;

      captured = cookies;
      round.requestClose();
      webview?.requestClose();
    }

    Future<void> read(AccountLoginReader source) async {
      if (reading) return;
      if (!round.beginHarvest(id)) return;
      reading = true;
      try {
        final cookies = await source.cookies(_loginUrl);
        if (!round.canAccept(id)) return;
        handleCookies(cookies, onLoginPage);
      } catch (_) {
        // 单次读取失败按噪声处理：WebView 可能正在导航，下一轮再试。
      } finally {
        reading = false;
        round.endHarvest();
      }
    }

    void startTimer() {
      timer ??= Timer.periodic(const Duration(seconds: 2), (_) {
        final current = reader;
        if (current == null) return;
        unawaited(read(current));
      });
    }

    /// 处理一次标题回调：标题只用于**辅助**判断是否已离开登录页。
    void handleTitle(String title, AccountLoginReader r) {
      reader = r;
      onLoginPage = _isOnLoginPage(title);
    }

    try {
      if (!mounted) return false;
      webview = widget.webviewFactory(
        context,
        _loginUrl,
        (title, r) {
          handleTitle(title, r);
          startTimer();
          unawaited(read(r));
        },
        () {
          round.markClosed();
          if (!closed.isCompleted) closed.complete();
        },
      );

      unawaited(webview.open());
      startTimer();

      // 登录动作由用户在 WebView 内完成，这里只能等待窗口关闭（用户点关闭，
      // 或上面的三条件命中后由本页请求关闭）。
      await closed.future;
      if (captured == null) return false;

      final candidate = AccountLoginCandidate(captured!, null);
      await (widget.submitCredentials ?? _submit)(candidate);
      return true;
    } finally {
      timer?.cancel();
      round.markClosed();
      webview?.dispose();
    }
  }

  Future<void> _submit(AccountLoginCandidate candidate) async {
    final network = PixivNetwork();
    final sessId =
        candidate.cookies[PixivNetwork.phpSessIdCookieName]?.trim() ?? '';
    if (sessId.isEmpty) {
      throw StateError('未检测到 ${PixivNetwork.phpSessIdCookieName}，请重试'.tl);
    }

    final source = ComicSource.require(sourceKey);
    // 先清旧会话再写新值：PHPSESSID 被轮换后旧 cookie 会残留在独立 jar 里，
    // 不清掉就可能出现"新值已写入、旧值仍被优先带走"的脏状态。
    await network.logout();
    // 存**全部**捕获到的 cookie，而不只是 PHPSESSID。
    //
    // 真机证据：登录后读接口（详情/搜索/取 uid）全部正常，但**收藏写操作**
    // 被服务端拒绝并提示"请重新登录"。读通过、写被拒，说明写操作还依赖
    // session 之外的凭据（最可能是 CSRF token cookie）——登录时 WebView 已经
    // 把整站 cookie 都拿到了，没有理由只存一个。
    await network.saveCookies(candidate.cookies);

    // 写入后从 jar 回读校验：确认持久层里**确实是**本次捕获的这个值。
    // 这一步防的是"读到了残留旧会话就当成登录成功"——此时回读会拿到旧值或空值。
    // 用 readPersistedPhpSessId（读 jar）而非 storedPhpSessId（内存快照）：
    // 后者刚被 setSessionCookie 写成新值，永远等于 sessId，起不到校验作用。
    final persisted = network.readPersistedPhpSessId()?.trim() ?? '';
    if (persisted.isEmpty || persisted != sessId) {
      throw StateError('会话写入校验失败，请重试'.tl);
    }

    source.data['token'] = sessId;
    source.data['name'] = 'Pixiv';
    // 先落盘：下面的 fetchUserId 会用 _session（含 token 回退）拼 Cookie，
    // 数据写进去才保证它一定能带上凭据。
    await source.saveData();

    // uid 获取：走「拉首页 HTML 解析」而不是从 cookie 猜。
    //
    // 真机反馈：cookie 里**没有** uid（首版按 `pixiv_uid`/`p_uid`/`uid` 等键名
    // 猜，全部落空），导致 `data['userId']` 恒空、收藏接口每次都报"需要登录"，
    // 且重新登录也无效——因为换的只是 PHPSESSID，与 uid 无关。
    // 这里登录后立刻解析一次；失败也不阻断登录（收藏入口首次使用时还会自愈重试）。
    final fetched = await network.fetchUserId();
    if (fetched.error) {
      // 兜底：仍有极少数部署形态可能把 uid 放 cookie，保留这条旧路径，
      // 但不作为主路径（它已被真机证伪一次）。
      final guessed = _extractUserId(candidate.cookies);
      if (guessed != null && guessed.isNotEmpty) {
        source.data['userId'] = guessed;
      }
    }
    await source.saveData();
  }

  /// 从 cookie 里推断 userId（**兜底路径，非主路径**）。
  ///
  /// 真机已证伪"Pixiv 把 uid 放 cookie"这一假设（见 [_submit] 说明），
  /// 主路径改成了 [PixivNetwork.fetchUserId]（拉页面 HTML 解析）。
  /// 这里保留按常见键名逐个尝试的旧逻辑，仅作极少数部署形态的兜底；
  /// 都取不到返回 null（调用方跳过，不报错）。
  String? _extractUserId(Map<String, String> cookies) {
    const candidates = <String>[
      'pixiv_uid',
      'p_uid',
      'uid',
      'userId',
      'user_id',
    ];
    for (final key in candidates) {
      final value = cookies[key]?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  /// 手填 PHPSESSID 降级登录（WebView 不可用或抓不到 cookie 时）。
  void _loginManually() {
    final sessId = _sessIdController.text.trim();
    if (sessId.isEmpty) {
      setState(() => loginError = '请填写 PHPSESSID'.tl);
      return;
    }
    setState(() => loginError = null);
    runLogin(() async {
      await (widget.submitCredentials ?? _submit)(
        AccountLoginCandidate(
          {PixivNetwork.phpSessIdCookieName: sessId},
          null,
        ),
      );
      return true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return withLoginBackHandling(Scaffold(
      appBar: AppBar(title: Text('Pixiv 登录'.tl)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: SizedBox(
            width: 460,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Pixiv 使用网页登录。点击下方按钮，在打开的网页中完成登录，'
                          '登录成功后关闭网页即可自动返回。'
                          'PHPSESSID 在其它设备登录可能被轮换导致本会话失效，'
                          '建议使用不常用账号。'
                      .tl,
                  style: const TextStyle(fontSize: 15),
                ),
                const SizedBox(height: 20),
                if (loginError != null) ...[
                  Text(loginError!, style: TextStyle(color: colorScheme.error)),
                  const SizedBox(height: 12),
                ],
                FilledButton.icon(
                  onPressed: logging ? null : _loginWithWebview,
                  icon: logging
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_outward, size: 16),
                  label: Text(logging ? '等待网页登录…'.tl : '在 Webview 中登录'.tl),
                ),
                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 12),
                Text(
                  '手填 PHPSESSID（降级入口）'.tl,
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _sessIdController,
                  enabled: !logging,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: 'PHPSESSID',
                    hintText: '从浏览器开发者工具的 Cookie 中复制'.tl,
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: logging ? null : _loginManually,
                  child: Text('使用该会话登录'.tl),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
  }
}

/// 清理 WebView 自身的 Pixiv 会话 cookie（仅移动端；桌面端登录窗口使用独立
/// profile，UA 与移动端不同，且不共享移动端插件管理的 cookie jar）。
///
/// 放在"打开登录页之前 + 建立轮询之前"调用：先清后登，才能把本次登录新产生的
/// `PHPSESSID` 与上一轮残留区分开。
///
/// ## 为什么必须清"该域下全部 cookie"而不是只清 PHPSESSID
///
/// WebView 的 cookie 存储与 Dart 侧 `PixivNetwork` 的 CookieJar 是**两套独立
/// 存储**：源里的 `logout()` 只清 Dart jar，WebView 里仍留着登录态。
/// 实测反馈：**退出登录后再点登录同样秒退** —— WebView 带着残留登录 cookie
/// 打开登录页，被 pixiv 直接重定向到已登录的首页，于是
/// 「已离开登录页 + PHPSESSID 非空」立刻成立。
///
/// 只删 `PHPSESSID` 也不够：Pixiv 的登录态还由其它会话 cookie 维持，
/// 删一个不等于登出。因此这里额外用 `deleteAllCookies()` 清空 WebView 全部
/// cookie（登录窗口是专用 WebView，不影响用户其它浏览行为）。
Future<void> _clearWebviewSessionCookie() async {
  if (!App.isMobile) return;
  const cookieName = PixivNetwork.phpSessIdCookieName;
  try {
    final manager = CookieManager.instance();
    // 第一道：按域精确删 PHPSESSID（覆盖 httpOnly / 父域形态）。
    for (final raw in <String>[
      'https://accounts.pixiv.net/',
      '${PixivNetwork.pixivWebBase}/',
    ]) {
      final url = WebUri(raw);
      await manager.deleteCookie(url: url, name: cookieName);
      await manager.deleteCookie(
        url: url,
        name: cookieName,
        domain: '.pixiv.net',
      );
    }
    // 第二道：整体清空，确保非 PHPSESSID 的会话 cookie 也不残留。
    await manager.deleteAllCookies();
  } catch (_) {
    // WebView cookie 清理失败不阻断登录：新登录会覆盖写入新 session。
  }
}
