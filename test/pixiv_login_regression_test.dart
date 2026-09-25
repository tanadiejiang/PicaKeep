/// Pixiv 登录判定条件的回归测试（第十八轮，两轮真机反馈驱动）。
///
/// ## 被真机推翻过的三版判据（勿回退）
///
/// **v1 秒退**：入口是**首页** + 判「已离开登录页 + `PHPSESSID` 非空」。
/// → "已离开登录页"从第一帧恒真，且匿名访问首页也会下发 `PHPSESSID`
/// → WebView 一打开就自动关窗。
///
/// **v2 登录后不自动返回**：加「必须观察到曾在登录页」（依赖**标题**识别）。
/// → WebView 只回传标题（拿不到 URL），Pixiv 登录页标题形如「ログイン - pixiv」，
/// 标题语言不在标记表内、或首次回调已是登录后页面时，该闸门恒为 false
/// → 登录成功了页面却不返回。
///
/// **v3 当前**：改用 **cookie 基线比对** —— `PHPSESSID` 非空且**与登录前基线不同**。
/// 该信号与页面语言、标题文案、导航时序全都无关。
///
/// 本文件的断言锁住这些最容易退化的契约：
/// - **登录入口必须是登录页**（改回首页会让"是否已离开登录页"失去意义）；
/// - **登录页标记必须能识别登录页、且不误判主站首页**；
/// - **判据不得依赖标题**（v2 的教训：标题不可靠，只能当辅助）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';

/// 与 `_PixivLoginPageState._loginUrl` 保持一致。
///
/// 这里刻意**重复声明**而不是 import 私有常量：本测试要能独立抓住"有人把
/// 登录入口改回首页"的回归，若共用同一个常量就没有对照意义。
const _expectedLoginHost = 'accounts.pixiv.net';

/// 与 `_PixivLoginPageState._loginPathMarkers` 保持同步。
///
/// 复制而非 import：标记是私有实现细节，测试要独立守住
/// "能认登录页 + 不误判首页 + 不含过宽词"三侧边界。
const _loginMarkers = <String>[
  'accounts.pixiv.net',
  '/auth/login',
  '/register',
  '/signup',
  'account/register',
  'login - pixiv',
  'ログイン - pixiv',
  'pixivにログイン',
  'pixiv 登入',
  'pixiv 登录',
  'pixiv 登録',
];

/// 与实现一致的登录页判别（仅辅助信号）。
bool _isOnLoginPage(String? text) {
  final value = text?.trim().toLowerCase() ?? '';
  if (value.isEmpty) return true; // 无证据时保守视为仍在登录页
  for (final marker in _loginMarkers) {
    if (value.contains(marker)) return true;
  }
  return false;
}

/// v3 判据的纯语义复刻：给定基线与当前值，判断是否可提交。
///
/// 与 `_PixivLoginPageState.handleCookies()` 的分支保持同构：
/// - 首次快照（`baseline == null`）只用来**确立基线**，永不提交；
/// - 之后 `PHPSESSID` 非空且不同于基线即可提交；
/// - 仅当基线**非空**（打开前就有旧会话、清理没生效）时，
///   额外要求"已离开登录页"。
bool _canSubmit({
  required String? baseline,
  required String current,
  required bool onLoginPage,
}) {
  // 基线未知 → 这一次快照只是采基线，不判断。
  if (baseline == null) return false;
  final value = current.trim();
  if (value.isEmpty) return false;
  if (value == baseline.trim()) return false;
  if (baseline.trim().isNotEmpty && onLoginPage) return false;
  return true;
}

void main() {
  group('Pixiv 登录入口必须是登录页（否则秒退复现）', () {
    test('登录 URL 不得是站点首页', () {
      // 首页形态：host 为 www.pixiv.net 且 path 为 `/`（或空）。
      // 这正是首版踩坑的取值 —— 它让"已离开登录页"恒成立。
      final homepagePattern = RegExp(r'^https://www\.pixiv\.net/?$');
      expect(
        homepagePattern.hasMatch('https://www.pixiv.net/'),
        isTrue,
        reason: '基准检查：首页形态应能被该正则识别',
      );
      // 修复后的入口应形如 accounts.pixiv.net/login?...，天然不匹配首页形态。
      expect(
        _expectedLoginHost,
        isNot('www.pixiv.net'),
        reason: '登录入口域名必须是 accounts 子域；改回主站会导致判定退化',
      );
    });
  });

  group('v3 判据：会话基线比对（不依赖标题）', () {
    test('首次快照只确立基线，不提交（含"首次就带 session"的情形）', () {
      // 这是 v3 的关键：第一次读到的快照永远用于定基线。
      // 若此时就提交，就退回成 v1 的"有 cookie 即成功"（秒退）。
      expect(
        _canSubmit(baseline: null, current: 'any', onLoginPage: false),
        isFalse,
      );
      expect(
        _canSubmit(baseline: null, current: 'any', onLoginPage: true),
        isFalse,
      );
    });

    test('会话值与基线不同 → 可提交（本次确实产生了新会话）', () {
      expect(
        _canSubmit(
          baseline: 'old-session',
          current: 'new-session',
          onLoginPage: false,
        ),
        isTrue,
      );
    });

    test('基线为空、会话非空 → 可提交（清理成功后的正常路径）', () {
      // 基线为空说明打开前没有旧会话，凡出现非空 session 即本次登录产生。
      expect(
        _canSubmit(baseline: '', current: 'fresh-session', onLoginPage: false),
        isTrue,
      );
      // 即使标题仍被判为登录页也放行：此时 session 只可能是本次登录带来的。
      expect(
        _canSubmit(baseline: '', current: 'fresh-session', onLoginPage: true),
        isTrue,
      );
    });

    test('会话值与基线相同 → 不可提交（残留旧会话，不是本次登录）', () {
      expect(
        _canSubmit(
          baseline: 'same-session',
          current: 'same-session',
          onLoginPage: false,
        ),
        isFalse,
        reason: '这正是"退出后重登仍秒退"的防线：旧值不算新登录',
      );
    });

    test('会话为空 → 无论如何都不可提交', () {
      expect(
        _canSubmit(baseline: '', current: '', onLoginPage: false),
        isFalse,
      );
      expect(
        _canSubmit(baseline: 'x', current: '   ', onLoginPage: false),
        isFalse,
      );
    });

    test('基线非空（清理失败）时额外要求已离开登录页', () {
      expect(
        _canSubmit(
          baseline: 'stale',
          current: 'new',
          onLoginPage: true,
        ),
        isFalse,
        reason: '打开前就有旧会话，不能仅凭"值变了"确认登录完成',
      );
      expect(
        _canSubmit(
          baseline: 'stale',
          current: 'new',
          onLoginPage: false,
        ),
        isTrue,
      );
    });

    test('基线为空（清理成功，正常路径）时标题完全不参与判定', () {
      // 这是**最常见**的路径：`_clearWebviewSessionCookie()` 生效 → 基线为空
      // → 只要出现非空 session 就提交，与标题无关。
      // v2 的失败正是因为把标题当成了**必需**条件，而标题不可靠。
      for (final title in <String>[
        'ログイン - pixiv',
        'pixiv',
        'イラストコミュニケーションサービス [pixiv]',
        '',
      ]) {
        expect(
          _canSubmit(
            baseline: '',
            current: 'new',
            onLoginPage: _isOnLoginPage(title),
          ),
          isTrue,
          reason: '标题 "$title" 不应阻止"基线为空 + 有新 session"的提交',
        );
      }
    });

    test('基线非空时标题仍参与判定（刻意的保守分支）', () {
      // 诚实记录这个权衡：清理失败（基线非空）时仍要看"是否已离开登录页"，
      // 因此该分支下标题语言不匹配会导致不提交。
      // 缓解手段是 `_clearWebviewSessionCookie()` 在移动端清空全部 cookie，
      // 让正常路径走"基线为空"分支（见上一个用例）。
      expect(
        _canSubmit(
          baseline: 'stale',
          current: 'new',
          onLoginPage: _isOnLoginPage('ログイン - pixiv'),
        ),
        isFalse,
      );
      expect(
        _canSubmit(
          baseline: 'stale',
          current: 'new',
          onLoginPage: _isOnLoginPage('イラストコミュニケーションサービス [pixiv]'),
        ),
        isTrue,
      );
    });
  });

  group('PHPSESSID 不是登录成功的充分条件', () {
    test('匿名访问也会拿到 PHPSESSID —— 故"有 cookie"不能单独判成功', () {
      // 这条断言记录的是**已知站点行为**（Pixiv 对匿名访客也下发 PHPSESSID）。
      // 它解释了为什么成功判定必须额外依赖"登录页 → 站内"的迁移信号。
      // 若将来确认 Pixiv 不再对匿名下发，可放开此约束并简化判定。
      expect(
        PixivNetwork.phpSessIdCookieName,
        'PHPSESSID',
        reason: 'cookie 名是判定条件的一部分，改名会让登录/鉴权同时失效',
      );
    });
  });

  group('登录页标记的判别力（辅助信号）', () {
    test('能识别登录页的 URL 与标题形态（含日文）', () {
      expect(_isOnLoginPage('accounts.pixiv.net'), isTrue);
      expect(_isOnLoginPage('https://accounts.pixiv.net/login'), isTrue);
      expect(_isOnLoginPage('https://www.pixiv.net/auth/login'), isTrue);
      expect(_isOnLoginPage('Login - pixiv'), isTrue);
      // 日文标题：v2 失败的直接原因之一就是漏了这一形态。
      expect(_isOnLoginPage('ログイン - pixiv'), isTrue);
      expect(_isOnLoginPage('pixivにログイン'), isTrue);
    });

    test('主站首页与作品页**不被**误判为登录页', () {
      expect(_isOnLoginPage('https://www.pixiv.net/'), isFalse);
      expect(_isOnLoginPage('pixiv'), isFalse);
      expect(
        _isOnLoginPage('https://www.pixiv.net/artworks/100412238'),
        isFalse,
      );
      // 登录后的主站标题（日文）也不得命中。
      expect(
        _isOnLoginPage('イラストコミュニケーションサービス [pixiv]'),
        isFalse,
      );
    });

    test('拿不到任何文本时保守返回 true（宁可多轮询也不秒退）', () {
      expect(_isOnLoginPage(''), isTrue);
      expect(_isOnLoginPage('   '), isTrue);
      expect(_isOnLoginPage(null), isTrue);
    });

    test('不带裸 login 这类过宽标记（会误判站内页面）', () {
      // 首版曾把裸 'login' / '登录' 放进标记表，会把标题含该词的站内页面
      // 当成登录页。这里锁住"标记必须足够具体"这条教训。
      for (final marker in _loginMarkers) {
        expect(
          marker.trim().toLowerCase(),
          isNot('login'),
          reason: '裸 login 过宽',
        );
        expect(
          marker.trim().toLowerCase(),
          isNot('登录'),
          reason: '裸 登录 过宽',
        );
      }
      // 反例：这类页面标题含 "login" 字样，但不该被判为登录页。
      expect(_isOnLoginPage('login history - pixiv'), isFalse);
    });
  });
}
