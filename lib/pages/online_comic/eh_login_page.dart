import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'account_webview_login.dart';

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
/// 手填和网页登录共用源级操作门禁与凭据保存流程。
class EhLoginPage extends StatefulWidget {
  const EhLoginPage({
    super.key,
    this.webviewFactory = createAccountLoginWebview,
    this.submitCredentials,
  });

  final AccountLoginWebviewFactory webviewFactory;
  final AccountLoginSubmit? submitCredentials;

  @override
  State<EhLoginPage> createState() => _EhLoginPageState();
}

class _EhLoginPageState extends AccountCookieLoginState<EhLoginPage> {
  @override
  String get sourceKey => 'ehentai';
  final _idController = TextEditingController();
  final _hashController = TextEditingController();
  final _igneousController = TextEditingController();
  final _starController = TextEditingController();
  final _pasteController = TextEditingController();
  bool _showPaste = false;

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
      _showMessage('未能从文本中解析出 cookie'.tl);
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
    if (_idController.text.trim().isEmpty ||
        _hashController.text.trim().isEmpty) {
      setState(() => loginError = '请填写 ipb_member_id 与 ipb_pass_hash'.tl);
      return;
    }
    final candidate = AccountLoginCandidate({
      'ipb_member_id': _idController.text.trim(),
      'ipb_pass_hash': _hashController.text.trim(),
      if (_igneousController.text.trim().isNotEmpty)
        'igneous': _igneousController.text.trim(),
      if (_starController.text.trim().isNotEmpty)
        'star': _starController.text.trim(),
    }, null);
    runLogin(() async {
      await (widget.submitCredentials ?? _submit)(candidate);
      return true;
    });
  }

  Future<void> _loginWithWebview() => runLogin(() => collectAndSubmit(
        site: AccountLoginSite.ehentai,
        url: 'https://forums.e-hentai.org/index.php?act=Login&CODE=00',
        factory: widget.webviewFactory,
        submit: widget.submitCredentials ?? _submit,
      ));

  Future<void> _submit(AccountLoginCandidate candidate) async {
    final network = EhNetwork();
    try {
      await persistAccountCookies(
        jar: network.cookieJar,
        source: ComicSource.require(sourceKey),
        replacements: {
          Uri.parse('https://e-hentai.org/'): candidate.cookies,
          Uri.parse('https://exhentai.org/'): candidate.cookies,
        },
        identityCookieNames: const {
          'ipb_member_id',
          'ipb_pass_hash',
          'igneous',
          'star',
        },
        userAgent: candidate.userAgent,
        authenticate: () async {
          if (!await network.validateCookies()) {
            throw StateError('Cookie 无效或已过期，请检查后重试'.tl);
          }
          final name = await network.getUserName();
          return {
            'token': 'ok',
            'name': name?.isNotEmpty == true ? name! : 'E-Hentai'
          };
        },
      );
    } finally {
      await network.getCookies(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return withLoginBackHandling(Scaffold(
      appBar: AppBar(title: Text('E-Hentai 登录'.tl)),
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
                  decoration: InputDecoration(labelText: '搜索站点'.tl),
                  items: [
                    DropdownMenuItem(
                        value: '0', child: Text('E-Hentai（表站）'.tl)),
                    DropdownMenuItem(
                        value: '1', child: Text('ExHentai（里站）'.tl)),
                  ],
                  onChanged: logging
                      ? null
                      : (value) async {
                          if (value == null) return;
                          final previous = appdata.settings[20];
                          setState(() => logging = true);
                          appdata.settings[20] = value;
                          try {
                            await appdata.updateSettings(false);
                          } catch (_) {
                            appdata.settings[20] = previous;
                            if (mounted) _showMessage('站点设置保存失败，请重试'.tl);
                          } finally {
                            if (mounted) setState(() => logging = false);
                          }
                        },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                      '里站需要账号具备访问权限及有效 Cookie。直接打开画廊链接时，阅读和下载跟随链接所属站点。'.tl),
                ),
                const Text('Cookies', style: TextStyle(fontSize: 18)),
                const SizedBox(height: 12),
                _field(_idController, 'ipb_member_id'),
                _field(_hashController, 'ipb_pass_hash'),
                _field(_igneousController, 'igneous（里站需要，普通站可空）'.tl),
                _field(_starController, 'star（可空）'.tl),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _showPaste = !_showPaste),
                    child:
                        Text(_showPaste ? '收起快速填写'.tl : '通过 Cookie 文本快速填写'.tl),
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
                              child: Text('解析'.tl),
                            ),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
                if (loginError != null) ...[
                  const SizedBox(height: 8),
                  Text(loginError!, style: TextStyle(color: colorScheme.error)),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: logging ? null : _loginManually,
                  child: logging
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text('登录'.tl),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: logging ? null : _loginWithWebview,
                  icon: const Icon(Icons.arrow_outward, size: 16),
                  label: Text('在 Webview 中登录'.tl),
                ),
                TextButton.icon(
                  onPressed: () => launchUrlString(
                    'https://forums.e-hentai.org/index.php?act=Reg&CODE=00',
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.arrow_outward, size: 16),
                  label: Text('注册'.tl),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
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
