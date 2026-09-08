import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/pages/online_comic/webview.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// 从多行 `key: value` 文本解析出 cookie map。
///
/// 移植自上游 EhUserCookieParser.parse：按行切，每行按第一个 `:` 切成 key/value，
/// 两侧 trim。容错：非 `key: value` 形态的行直接跳过。
Map<String, String> parseCookieText(String text) {
  final result = <String, String>{};
  for (final line in text.split('\n')) {
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    final key = line.substring(0, idx).trim();
    final value = line.substring(idx + 1).trim();
    if (key.isEmpty || value.isEmpty) continue;
    result[key] = value;
  }
  return result;
}

/// E-Hentai 登录页（cookie 登录 + Webview 抓取）。
///
/// 主路径：手填 / 粘贴解析 ipb_member_id / ipb_pass_hash / igneous / star。
/// 增强路径："在 Webview 中登录" —— 移动端 InAppWebview、桌面端 DesktopWebview，
/// 登录论坛成功后自动抓两域 cookie + UA。两路最终都汇入 [loginWithCookies]。
class EhLoginPage extends StatefulWidget {
  const EhLoginPage({super.key});

  @override
  State<EhLoginPage> createState() => _EhLoginPageState();
}

class _EhLoginPageState extends State<EhLoginPage> {
  final _idController = TextEditingController();
  final _hashController = TextEditingController();
  final _igneousController = TextEditingController();
  final _starController = TextEditingController();
  final _pasteController = TextEditingController();
  bool _logging = false;
  bool _showPaste = false;
  String? _error;

  @override
  void dispose() {
    _idController.dispose();
    _hashController.dispose();
    _igneousController.dispose();
    _starController.dispose();
    _pasteController.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _parsePasted() {
    final cookieMap = parseCookieText(_pasteController.text);
    if (cookieMap.isEmpty) {
      _showMessage('未能从文本中解析出 cookie');
      return;
    }
    setState(() {
      _idController.text = cookieMap['ipb_member_id'] ?? _idController.text;
      _hashController.text = cookieMap['ipb_pass_hash'] ?? _hashController.text;
      _igneousController.text = cookieMap['igneous'] ?? _igneousController.text;
      _starController.text = cookieMap['star'] ?? _starController.text;
    });
  }

  void _loginManually() {
    if (_idController.text.isEmpty || _hashController.text.isEmpty) {
      setState(() => _error = '请填写 ipb_member_id 与 ipb_pass_hash');
      return;
    }
    loginWithCookies({
      'ipb_member_id': _idController.text.trim(),
      'ipb_pass_hash': _hashController.text.trim(),
      if (_igneousController.text.trim().isNotEmpty)
        'igneous': _igneousController.text.trim(),
      if (_starController.text.trim().isNotEmpty)
        'star': _starController.text.trim(),
    });
  }

  void _loginWithWebview() async {
    const loginUrl = 'https://forums.e-hentai.org/index.php?act=Login&CODE=00';
    if (App.isMobile) {
      App.globalTo(() => AppWebview(
            singlePage: true,
            initialUrl: loginUrl,
            onTitleChange: (title, controller) async {
              if (title == 'E-Hentai Forums') {
                final ua = await controller.getUA();
                if (ua != null) {
                  appdata.implicitData[3] = ua;
                  appdata.writeImplicitData();
                }
                final cookies1 =
                    await controller.getCookies('https://e-hentai.org') ?? {};
                final cookies2 =
                    await controller.getCookies('https://exhentai.org') ?? {};
                final cookies = <String, String>{...cookies1, ...cookies2};
                loginWithCookies(cookies);
                App.globalBack();
              }
            },
          ));
    } else if (App.isDesktop) {
      if (await DesktopWebview.isAvailable()) {
        final webview = DesktopWebview(
          initialUrl: loginUrl,
          onTitleChange: (title, webview) async {
            if (title == 'E-Hentai Forums') {
              final ua = webview.userAgent;
              if (ua != null) {
                appdata.implicitData[3] = ua;
                appdata.writeImplicitData();
              }
              final cookies1 = await webview.getCookies('https://e-hentai.org');
              final cookies2 = await webview.getCookies('https://exhentai.org');
              webview.close();
              final cookies = <String, String>{...cookies1, ...cookies2};
              loginWithCookies(cookies);
            }
          },
        );
        webview.open();
      } else {
        _showMessage('当前设备不支持 Webview，请使用手动填写 Cookie');
      }
    }
  }

  void loginWithCookies(Map<String, String> cookiesMap) async {
    setState(() {
      _logging = true;
      _error = null;
    });

    final cookieJar = EhNetwork().cookieJar;
    // 先清旧 cookie，避免上一个账号残留与新账号混写。
    cookieJar.deleteUri(Uri.parse('https://e-hentai.org'));
    cookieJar.deleteUri(Uri.parse('https://exhentai.org'));

    // 双域名双写：同一份身份 cookie 分别以 .e-hentai.org / .exhentai.org 各写一遍。
    final cookies =
        cookiesMap.entries.map((e) => Cookie(e.key, e.value)).toList();
    for (final c in cookies) {
      c.domain = '.e-hentai.org';
    }
    cookieJar.saveFromResponse(Uri.parse('https://e-hentai.org'), cookies);
    for (final c in cookies) {
      c.domain = '.exhentai.org';
    }
    cookieJar.saveFromResponse(Uri.parse('https://exhentai.org'), cookies);

    final valid = await EhNetwork().validateCookies();
    if (!mounted) return;
    if (valid) {
      final source = ComicSource.find('ehentai');
      if (source != null) {
        source.data['token'] = 'ok';
        // 抓真实用户名；拿不到则回退占位，不阻断登录。
        final name = await EhNetwork().getUserName();
        source.data['name'] =
            (name != null && name.isNotEmpty) ? name : 'E-Hentai';
        await source.saveData();
      }
      _showMessage('登录成功');
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } else {
      // 校验失败：清脏 cookie，不写 token，保持可重试。
      cookieJar.deleteUri(Uri.parse('https://e-hentai.org'));
      cookieJar.deleteUri(Uri.parse('https://exhentai.org'));
      setState(() {
        _logging = false;
        _error = 'Cookie 无效或已过期，请检查后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('E-Hentai 登录')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: SizedBox(
            width: 460,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  key: ValueKey(appdata.settings[20]),
                  initialValue: appdata.settings[20] == '0' ? '0' : '1',
                  decoration: const InputDecoration(labelText: '搜索站点'),
                  items: const [
                    DropdownMenuItem(value: '0', child: Text('E-Hentai（表站）')),
                    DropdownMenuItem(value: '1', child: Text('ExHentai（里站）')),
                  ],
                  onChanged: _logging
                      ? null
                      : (value) async {
                          if (value == null) return;
                          final previous = appdata.settings[20];
                          setState(() => _logging = true);
                          appdata.settings[20] = value;
                          try {
                            await appdata.updateSettings(false);
                          } catch (_) {
                            appdata.settings[20] = previous;
                            if (mounted) _showMessage('站点设置保存失败，请重试');
                          } finally {
                            if (mounted) setState(() => _logging = false);
                          }
                        },
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child:
                      Text('里站需要账号具备访问权限及有效 Cookie。直接打开画廊链接时，阅读和下载跟随链接所属站点。'),
                ),
                const Text('Cookies', style: TextStyle(fontSize: 18)),
                const SizedBox(height: 12),
                _field(_idController, 'ipb_member_id'),
                _field(_hashController, 'ipb_pass_hash'),
                _field(_igneousController, 'igneous（里站需要，普通站可空）'),
                _field(_starController, 'star（可空）'),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _showPaste = !_showPaste),
                    child: Text(_showPaste ? '收起快速填写' : '通过 Cookie 文本快速填写'),
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _showPaste
                      ? Column(
                          key: const ValueKey('paste'),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(
                              controller: _pasteController,
                              maxLines: 5,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                hintText: 'ipb_member_id: xxxxx\n'
                                    'ipb_pass_hash: xxxxx\n'
                                    'igneous: xxxxx',
                              ),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton(
                              onPressed: _parsePasted,
                              child: const Text('解析'),
                            ),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: colorScheme.error)),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _logging ? null : _loginManually,
                  child: _logging
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('登录'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _logging ? null : _loginWithWebview,
                  icon: const Icon(Icons.arrow_outward, size: 16),
                  label: const Text('在 Webview 中登录'),
                ),
                TextButton.icon(
                  onPressed: () => launchUrlString(
                    'https://forums.e-hentai.org/index.php?act=Reg&CODE=00',
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.arrow_outward, size: 16),
                  label: const Text('注册'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController controller, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          labelText: label,
        ),
      ),
    );
  }
}
