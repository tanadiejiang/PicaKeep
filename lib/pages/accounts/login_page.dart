import 'package:flutter/material.dart';

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/network/app_dio.dart';
import 'package:picakeep/network/res.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.source});

  final ComicSource source;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final account = _accountController.text.trim();
    final password = _passwordController.text;
    if (account.isEmpty || password.isEmpty) {
      setState(() {
        _error = '请输入账号和密码';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await widget.source.account!
        .login(account, password)
        .timeout(networkConnectTimeout + networkReceiveTimeout)
        .onError((error, stackTrace) {
      return const Res.error('连接超时，请检查网络或代理');
    });
    if (!mounted) {
      return;
    }
    if (res.error) {
      setState(() {
        _loading = false;
        _error = res.errorMessageWithoutNull;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.source.name} 登录')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _accountController,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: '账号',
              prefixIcon: Icon(Icons.alternate_email),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _passwordController,
            obscureText: true,
            onSubmitted: (_) => _loading ? null : _login(),
            decoration: const InputDecoration(
              labelText: '密码',
              prefixIcon: Icon(Icons.lock_outline),
              border: OutlineInputBorder(),
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
            onPressed: _loading ? null : _login,
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login),
            label: const Text('登录'),
          ),
        ],
      ),
    );
  }
}
