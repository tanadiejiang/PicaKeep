import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show CookieManager, WebUri;
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/tools/translations.dart';

import 'account_webview_login.dart';

class NhentaiLoginPage extends StatefulWidget {
  const NhentaiLoginPage({
    super.key,
    this.webviewFactory = createAccountLoginWebview,
    this.submitCredentials,
    this.prepareWebview,
  });

  final AccountLoginWebviewFactory webviewFactory;
  final AccountLoginSubmit? submitCredentials;
  final Future<void> Function()? prepareWebview;

  @override
  State<NhentaiLoginPage> createState() => _NhentaiLoginPageState();
}

class _NhentaiLoginPageState extends AccountCookieLoginState<NhentaiLoginPage> {
  @override
  String get sourceKey => 'nhentai';

  Future<void> _prepare() async {
    final network = NhentaiNetwork();
    if (network.cookieJar == null) {
      final wasLogged = network.logged;
      try {
        await network.init();
      } finally {
        // Reading an old jar while preparing a new login is not authentication.
        network.logged = wasLogged;
      }
    }
    // Desktop WebView uses a separate profile; only the mobile plugin owns this jar.
    if (!App.isMobile) return;
    final manager = CookieManager.instance();
    final url = WebUri('${network.baseUrl}/');
    for (final name in const ['access_token', 'refresh_token']) {
      await manager.deleteCookie(url: url, name: name, domain: '.nhentai.net');
      await manager.deleteCookie(url: url, name: name);
    }
  }

  Future<void> _submit(AccountLoginCandidate candidate) async {
    final network = NhentaiNetwork();
    final jar = network.cookieJar;
    if (jar == null) throw StateError('Cookie 存储尚未初始化'.tl);
    final cookies = Map<String, String>.of(candidate.cookies)
      ..remove('cf_clearance');
    final uri = Uri.parse(network.baseUrl).replace(path: '/');
    await persistAccountCookies(
      jar: jar,
      source: ComicSource.require(sourceKey),
      replacements: {uri: cookies},
      identityCookieNames: const {'access_token', 'refresh_token'},
      userAgent: candidate.userAgent,
      authenticate: () async {
        final actual = jar.loadForRequest(uri);
        final matches = actual.any((cookie) =>
            (cookie.name == 'access_token' || cookie.name == 'refresh_token') &&
            cookie.value.isNotEmpty &&
            cookies[cookie.name] == cookie.value);
        if (!matches) {
          throw StateError('未检测到本次登录会话，请重试'.tl);
        }
        return {'token': 'ok'};
      },
    );
    network.logged = true;
  }

  Future<void> _loginWithWebview() => runLogin(() => collectAndSubmit(
        site: AccountLoginSite.nhentai,
        url: '${NhentaiNetwork().baseUrl}/login/?next=/',
        factory: widget.webviewFactory,
        prepare: widget.prepareWebview ?? _prepare,
        submit: widget.submitCredentials ?? _submit,
      ));

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return withLoginBackHandling(Scaffold(
      appBar: AppBar(title: Text('Nhentai 登录'.tl)),
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
                  'Nhentai 使用网页登录。点击下方按钮，在打开的网页中完成登录，登录成功后关闭网页即可自动返回。'.tl,
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
              ],
            ),
          ),
        ),
      ),
    ));
  }
}
