import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/pages/online_comic/webview.dart';

/// Nhentai 登录页（仅网页 Webview 抓 cookie 一条路径）。
///
/// 移植自上游 `nhentai_network/login.dart` 的 `nhLogin`，但做了两点关键修正：
/// 1. **不用网页标题判定登录**：nhentai 登录页 `/login/` 自身标题就含 "nhentai"，
///    用标题判定会在登录页加载瞬间误命中。改为以 `sessionid` cookie 为唯一信号。
/// 2. **webview 关闭后统一校验**：webview 期间持续把抓到的 cookie 写进 cookieJar，
///    关闭（移动端 await 页面返回 / 桌面端 onClose）后读 cookieJar 看有没有
///    `sessionid` —— 无论自动还是手动关，都会校验并复位 UI，不会卡在转圈。
///
/// 已知限制：`sessionid` 是 Django httpOnly cookie，依赖 webview 平台的
/// CookieManager 能否读出 httpOnly。若日志 `NhentaiLogin` 的 cookie keys 里始终
/// 没有 `sessionid`，说明当前平台 webview 读不到 httpOnly cookie，需换方案。
class NhentaiLoginPage extends StatefulWidget {
  const NhentaiLoginPage({super.key});

  @override
  State<NhentaiLoginPage> createState() => _NhentaiLoginPageState();
}

class _NhentaiLoginPageState extends State<NhentaiLoginPage> {
  bool _logging = false;
  bool _done = false; // 防止收尾重复触发
  bool _seenLoginPage = false; // 是否已出现过登录页标题
  String? _error;

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// 把 webview 抓到的 cookies 写进 cookieJar（丢弃 cf_clearance，域 .nhentai.net）。
  /// 仅负责"同步进 jar"，不做登录判定（判定统一在 [_verifyAfterClose] 读 jar）。
  void _harvestCookies(Map<String, String> cookies) {
    final base = NhentaiNetwork().baseUrl;
    final list = <io.Cookie>[];
    cookies.forEach((key, value) {
      final cookie = io.Cookie(key, value);
      cookie.domain = '.nhentai.net';
      if (key != 'cf_clearance') {
        list.add(cookie);
      }
    });
    if (list.isNotEmpty) {
      NhentaiNetwork().cookieJar?.saveFromResponse(Uri.parse(base), list);
    }
    LogManager.addLog(
      LogLevel.info,
      'NhentaiLogin',
      'harvest cookies: keys=${cookies.keys.toList()}',
    );
  }

  /// cookieJar 里是否已有登录会话 cookie。
  ///
  /// nhentai 新版用 JWT：登录后下发 `access_token` + `refresh_token`（不再是旧版
  /// Django session 的 `sessionid`）。任一存在即视为已登录。
  bool _hasSessionInJar() {
    final jar = NhentaiNetwork().cookieJar;
    if (jar == null) return false;
    final cookies = jar.loadForRequest(Uri.parse(NhentaiNetwork().baseUrl));
    final names = cookies.map((c) => c.name).toList();
    LogManager.addLog(
        LogLevel.info, 'NhentaiLogin', 'jar cookies after close: $names');
    return names.contains('access_token') || names.contains('refresh_token');
  }

  Future<void> _loginWithWebview() async {
    if (_logging) return;
    // cookieJar 需先就绪（saveFromResponse / loadForRequest 依赖它）。
    if (NhentaiNetwork().cookieJar == null) {
      await NhentaiNetwork().init();
    }
    setState(() {
      _logging = true;
      _error = null;
      _done = false;
    });
    final loginUrl = '${NhentaiNetwork().baseUrl}/login/?next=/';

    if (App.isMobile) {
      // await 推送的 webview 页面：用户返回（或自动关闭）后 resume。
      await App.globalTo(() => AppWebview(
            singlePage: true,
            initialUrl: loginUrl,
            onTitleChange: (title, controller) async {
              if (_done) return;
              LogManager.addLog(
                  LogLevel.info, 'NhentaiLogin', 'mobile title=$title');

              // 状态机：必须先出现过登录页标题，之后离开登录页才算登录完成。
              // 防止 jar 里有旧 token 时第一次 onTitleChange 就误关。
              if (title.contains('Login') || title.contains('Register')) {
                _seenLoginPage = true;
              }

              final cookies =
                  await controller.getCookies('${NhentaiNetwork().baseUrl}/') ??
                      {};
              _harvestCookies(cookies);
              final ua = await controller.getUA();
              if (ua != null) {
                appdata.implicitData[3] = ua;
                appdata.writeImplicitData();
              }

              // 快捷路径：已见过登录页 + 当前 webview cookies 里有 token → 登录成功。
              // 用 cookies 而非 jar 判断，确保是本次 webview 下发的 token。
              final hasToken = cookies.containsKey('access_token') ||
                  cookies.containsKey('refresh_token');
              if (_seenLoginPage && hasToken) {
                _done = true;
                App.globalBack();
              }
            },
          ));
      _verifyAfterClose();
    } else if (App.isDesktop) {
      if (await DesktopWebview.isAvailable()) {
        final webview = DesktopWebview(
          initialUrl: loginUrl,
          onClose: _verifyAfterClose,
          onTitleChange: (title, controller) async {
            LogManager.addLog(
                LogLevel.info, 'NhentaiLogin', 'desktop title=$title');
            final cookies =
                await controller.getCookies('${NhentaiNetwork().baseUrl}/');
            _harvestCookies(cookies);
            final ua = controller.userAgent;
            if (ua != null) {
              appdata.implicitData[3] = ua;
              appdata.writeImplicitData();
            }
            // 快捷路径：一旦 jar 里出现 sessionid，立即关窗（onClose 收尾）。
            if (_hasSessionInJar()) {
              controller.close();
            }
          },
        );
        webview.open();
      } else {
        setState(() => _logging = false);
        _showMessage('当前设备不支持 Webview 登录');
      }
    }
  }

  /// webview 关闭后统一校验：读 cookieJar 看 sessionid，成功写 token + pop，
  /// 失败复位 UI + 提示（不再卡转圈）。
  void _verifyAfterClose() {
    if (!mounted || _done) return;
    final ok = _hasSessionInJar();
    if (ok) {
      _done = true;
      NhentaiNetwork().logged = true;
      final source = ComicSource.find('nhentai');
      if (source != null) {
        source.data['token'] = 'ok';
        source.data['name'] = source.data['name'] ?? 'Nhentai';
        source.saveData();
      }
      _showMessage('登录成功');
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _logging = false;
        _error = '未检测到登录会话。请确认已在网页内完成登录；'
            '若已登录仍提示此条，可能是本设备 Webview 无法读取登录 cookie。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Nhentai 登录')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: SizedBox(
            width: 460,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Nhentai 使用网页登录。点击下方按钮，在打开的网页中完成登录，'
                  '登录成功后关闭网页即可自动返回。',
                  style: TextStyle(fontSize: 15),
                ),
                const SizedBox(height: 20),
                if (_error != null) ...[
                  Text(_error!, style: TextStyle(color: colorScheme.error)),
                  const SizedBox(height: 12),
                ],
                FilledButton.icon(
                  onPressed: _logging ? null : _loginWithWebview,
                  icon: _logging
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_outward, size: 16),
                  label: Text(_logging ? '等待网页登录…' : '在 Webview 中登录'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
