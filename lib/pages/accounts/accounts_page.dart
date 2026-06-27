import 'package:flutter/material.dart';

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/network/res.dart';

import 'account_mode_controller.dart';
import 'login_page.dart';

class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key});

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  final _modeController = AccountModeController.instance;
  bool _loadingMode = true;

  Iterable<ComicSource> get _accountSources =>
      ComicSource.sources.where((source) => source.account != null);

  @override
  void initState() {
    super.initState();
    _loadMode();
  }

  Future<void> _loadMode() async {
    await _modeController.load();
    if (mounted) {
      setState(() {
        _loadingMode = false;
      });
    }
  }

  Future<void> _setMode(AccountStorageMode mode) async {
    if (mode == AccountStorageMode.nas) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('NAS 在线源联动即将上线')),
        );
      }
      await _modeController.save(AccountStorageMode.local);
      if (mounted) {
        setState(() {});
      }
      return;
    }
    await _modeController.save(mode);
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = _accountSources.toList(growable: false);
    return Scaffold(
      appBar: AppBar(title: const Text('账号')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<AccountStorageMode>(
            segments: const [
              ButtonSegment(
                value: AccountStorageMode.local,
                icon: Icon(Icons.devices),
                label: Text('本地'),
              ),
              ButtonSegment(
                value: AccountStorageMode.nas,
                icon: Icon(Icons.dns_outlined),
                label: Text('NAS'),
              ),
            ],
            selected: {_modeController.mode},
            onSelectionChanged:
                _loadingMode ? null : (value) => _setMode(value.first),
          ),
          const SizedBox(height: 16),
          for (final source in sources) _AccountSourceTile(source: source),
          if (sources.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 80),
              child: Center(child: Text('暂无可登录的在线源')),
            ),
        ],
      ),
    );
  }
}

class _AccountSourceTile extends StatefulWidget {
  const _AccountSourceTile({required this.source});

  final ComicSource source;

  @override
  State<_AccountSourceTile> createState() => _AccountSourceTileState();
}

class _AccountSourceTileState extends State<_AccountSourceTile> {
  Future<List<AccountInfoItem>>? _infoFuture;
  bool _reLoginLoading = false;

  @override
  void initState() {
    super.initState();
    _reloadInfo();
  }

  void _reloadInfo() {
    final loader = widget.source.account?.infoItems;
    if (!widget.source.isLoggedIn || loader == null) {
      _infoFuture = Future.value(const <AccountInfoItem>[]);
      return;
    }
    _infoFuture = loader().then((res) {
      if (res.error) {
        throw res.errorMessageWithoutNull;
      }
      return res.data;
    });
  }

  Future<void> _openLogin() async {
    final changed = await Navigator.of(context).push<bool>(
      AppPageRoute(builder: (_) => LoginPage(source: widget.source)),
    );
    if (changed == true && mounted) {
      setState(_reloadInfo);
    }
  }

  Future<void> _logout() async {
    await widget.source.account?.logout?.call();
    if (mounted) {
      setState(_reloadInfo);
    }
  }

  Future<void> _reLogin() async {
    if (_reLoginLoading) {
      return;
    }
    setState(() {
      _reLoginLoading = true;
    });
    final relogin = widget.source.account?.reLogin;
    final Res<bool> res;
    if (relogin == null) {
      res = const Res.error('该源不支持重新登录');
    } else {
      res = await relogin();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _reLoginLoading = false;
      _reloadInfo();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(res.error ? res.errorMessageWithoutNull : '重新登录成功'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final loggedIn = source.isLoggedIn;
    return Card.outlined(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.cloud_queue),
            title: Row(
              children: [
                Text(source.name),
                if (loggedIn) ...[
                  const SizedBox(width: 8),
                  Builder(builder: (context) {
                    final cs = Theme.of(context).colorScheme;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '已登录',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                    );
                  }),
                ],
              ],
            ),
            subtitle: Text(loggedIn ? '点击查看账号信息' : '未登录'),
            trailing: loggedIn
                ? const Icon(Icons.check_circle_outline)
                : const Icon(Icons.login),
            onTap: loggedIn ? null : _openLogin,
          ),
          const Divider(height: 1),
          if (!loggedIn)
            ListTile(
              leading: const Icon(Icons.login),
              title: const Text('登录'),
              onTap: _openLogin,
            )
          else ...[
            FutureBuilder<List<AccountInfoItem>>(
              future: _infoFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: LinearProgressIndicator(),
                  );
                }
                if (snapshot.hasError) {
                  return ListTile(
                    leading: const Icon(Icons.error_outline),
                    title: const Text('账号信息加载失败'),
                    subtitle: Text(snapshot.error.toString()),
                  );
                }
                final items = snapshot.data ?? const <AccountInfoItem>[];
                if (items.isEmpty) {
                  return const ListTile(title: Text('暂无账号信息'));
                }
                return Column(
                  children: [
                    for (final item in items)
                      ListTile(
                        dense: true,
                        title: Text(item.title),
                        subtitle: item.value.isEmpty ? null : Text(item.value),
                      ),
                  ],
                );
              },
            ),
            ListTile(
              leading: _reLoginLoading
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              title: const Text('重新登录'),
              subtitle: const Text('如果登录失效点击此处'),
              onTap: _reLoginLoading ? null : _reLogin,
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('退出登录'),
              onTap: _logout,
            ),
          ],
        ],
      ),
    );
  }
}
