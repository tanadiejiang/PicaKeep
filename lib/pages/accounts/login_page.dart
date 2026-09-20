import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/tools/translations.dart';

import 'account_operation_scope.dart';

/// 通用账密登录页（Picacg / JM）。
///
/// 只服务走 [AccountConfig.login] 的源；EH/NH 走各自的 [AccountConfig.onLogin] 网页流程。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.source, this.operations});

  final ComicSource source;

  /// 账号容器提供的单源操作协调器。
  ///
  /// 非 null 时，真实登录提交会登记到它上面：同源在途操作期间禁止再次提交，
  /// 且子页返回不会释放在途操作。为 null（非账号入口）时页内自行控制。
  final AccountOperationController? operations;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;
  final _ownOperations = AccountOperationController();

  AccountOperationController get _operations =>
      widget.operations ?? _ownOperations;

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.dispose();
    _ownOperations.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_loading || _operations.isBusy(widget.source.key)) return;
    final route = ModalRoute.of(context);
    final account = _accountController.text.trim();
    // 密码原样提交，不做 trim。
    final password = _passwordController.text;
    if (account.isEmpty || password.isEmpty) {
      setState(() {
        _error = '请输入用户名和密码'.tl;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // 门禁跟随真实提交和写盘，子页返回不会提前释放它。
      await _operations.execute<void>(widget.source.key, () async {
        final result = await widget.source.account!.login(account, password);
        if (result.error) throw StateError(result.errorMessageWithoutNull);
        if (result.dataOrNull != true) {
          throw StateError('登录未完成，请重试'.tl);
        }
      }, operation: 'login');
      if (mounted && route?.isCurrent == true) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is StateError ? error.message : error.toString();
      });
    }
  }

  Future<void> _openRegister() async {
    final url = widget.source.account?.registerWebsite;
    if (url == null) return;
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (!mounted || opened) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('无法打开注册页面：@url'.tlParams({'url': url}))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final registerWebsite = widget.source.account?.registerWebsite;
    return ListenableBuilder(
      listenable: _operations,
      builder: (context, child) {
        final busy = _loading || _operations.isBusy(widget.source.key);
        return Scaffold(
          appBar: AppBar(
              title:
                  Text('登录 @source'.tlParams({'source': widget.source.name}))),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              TextField(
                controller: _accountController,
                enabled: !busy,
                // 通用文本输入：JM 是用户名，Picacg 允许邮箱，不强制按邮箱键盘限制。
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: '用户名'.tl,
                  prefixIcon: const Icon(Icons.alternate_email),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _passwordController,
                enabled: !busy,
                obscureText: true,
                onSubmitted: (_) => busy ? null : _login(),
                decoration: InputDecoration(
                  labelText: '密码'.tl,
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: colorScheme.error),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: busy ? null : _login,
                icon: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.login),
                label: Text('继续'.tl),
              ),
              if (registerWebsite != null) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: busy ? null : _openRegister,
                  icon: const Icon(Icons.app_registration, size: 18),
                  label: Text('注册'.tl),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
