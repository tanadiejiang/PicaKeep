import 'dart:async';

import 'package:flutter/material.dart';

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/tools/translations.dart';

import 'account_mode_controller.dart';
import 'account_operation_scope.dart';
import 'login_page.dart';

class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key, this.onClose});

  /// 作为账号容器根页面时用于关闭整个容器；为 null 时按普通路由返回
  /// （保留 `AccountsPage()` 直接 push 的既有用法）。
  final VoidCallback? onClose;

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  final _modeController = AccountModeController.instance;
  bool _loadingMode = true;
  bool _savingMode = false;

  Iterable<ComicSource> get _accountSources =>
      ComicSource.sources.where((source) => source.account != null);

  @override
  void initState() {
    super.initState();
    _loadMode();
  }

  Future<void> _loadMode() async {
    try {
      await _modeController.load();
    } catch (error) {
      if (mounted) _modeError(error);
    } finally {
      if (mounted) setState(() => _loadingMode = false);
    }
  }

  void _modeError(Object error) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：@error'.tlParams({'error': '$error'}))),
      );

  Future<void> _setMode(AccountStorageMode mode) async {
    if (_loadingMode || _savingMode) return;
    if (mode == AccountStorageMode.nas) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('NAS 账号管理暂未接入'.tl)),
        );
      }
      return;
    }
    setState(() => _savingMode = true);
    try {
      await _modeController.save(mode);
    } catch (error) {
      if (mounted) _modeError(error);
    } finally {
      if (mounted) setState(() => _savingMode = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = _accountSources.toList(growable: false);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () {
            final onClose = widget.onClose;
            if (onClose != null) {
              // 账号容器根页面：返回关闭整个容器。
              onClose();
            } else {
              Navigator.of(context).maybePop();
            }
          },
        ),
        title: Text('账号管理'.tl),
      ),
      body: ListView(
        // 左右留白交给各组自己的内边距，源分组才能做到"标题 + 行 + 分隔线"的扁平结构。
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<AccountStorageMode>(
              segments: [
                ButtonSegment(
                  value: AccountStorageMode.local,
                  icon: const Icon(Icons.devices),
                  label: Text('本地'.tl),
                ),
                const ButtonSegment(
                  value: AccountStorageMode.nas,
                  icon: Icon(Icons.dns_outlined),
                  label: Text('NAS'),
                ),
              ],
              selected: {_modeController.mode},
              onSelectionChanged: _loadingMode || _savingMode
                  ? null
                  : (value) => _setMode(value.first),
            ),
          ),
          const SizedBox(height: 8),
          for (final source in sources)
            _AccountSourceTile(key: ValueKey(source.key), source: source),
          if (sources.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 80),
              child: Center(child: Text('暂无可登录的在线源'.tl)),
            ),
        ],
      ),
    );
  }
}

class _AccountSourceTile extends StatefulWidget {
  const _AccountSourceTile({super.key, required this.source});

  final ComicSource source;

  @override
  State<_AccountSourceTile> createState() => _AccountSourceTileState();
}

class _AccountSourceTileState extends State<_AccountSourceTile> {
  Future<List<AccountInfoItem>>? _infoFuture;

  /// 非账号容器入口（取不到 Scope）时的页内退路，保证不因缺 Scope 崩溃。
  AccountOperationController? _ownOperations;
  AccountOperationController? _operations;
  int _revision = 0;
  bool _refreshRequested = false;
  bool _reloadScheduled = false;
  bool _opening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final operations = AccountOperationScope.maybeOf(context) ??
        (_ownOperations ??= AccountOperationController());
    if (identical(_operations, operations)) return;
    _operations?.removeListener(_operationChanged);
    _operations = operations;
    _revision = operations.revisionOf(widget.source.key);
    operations.addListener(_operationChanged);
    _requestInfo();
  }

  @override
  void didUpdateWidget(covariant _AccountSourceTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) _requestInfo();
  }

  void _operationChanged() {
    if (!mounted) return;
    final revision = _operations!.revisionOf(widget.source.key);
    if (revision != _revision) {
      _revision = revision;
      _refreshRequested = true;
    }
    if (_refreshRequested) _requestInfo();
    setState(() {});
  }

  void _requestInfo() {
    _refreshRequested = true;
    if (_reloadScheduled) return;
    _reloadScheduled = true;
    scheduleMicrotask(() {
      _reloadScheduled = false;
      if (!mounted || _operations!.isBusy(widget.source.key)) return;
      _refreshRequested = false;
      _reloadInfo();
    });
  }

  @override
  void dispose() {
    _operations?.removeListener(_operationChanged);
    _ownOperations?.dispose();
    super.dispose();
  }

  void _reloadInfo() {
    final loader = widget.source.account?.infoItems;
    if (!widget.source.isLoggedIn || loader == null) {
      setState(() {
        _infoFuture = Future.value(const <AccountInfoItem>[]);
      });
      return;
    }
    final future = _operations!.execute<List<AccountInfoItem>>(
      widget.source.key,
      () async {
        final res = await loader();
        if (res.error) throw StateError(res.errorMessageWithoutNull);
        return res.data;
      },
      operation: 'info',
    );
    // A synchronous loader failure can settle before the next frame attaches
    // FutureBuilder. Keep the original future (and error) for its error view.
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    setState(() {
      _infoFuture = future;
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _openLogin() async {
    if (_opening || _operations!.isBusy(widget.source.key)) return;
    final revision = _revision;
    setState(() => _opening = true);
    // 若源提供了自定义登录入口（如 ehentai 的 Cookie 登录），优先走它。
    // onLogin 返回 Future，await 它（登录页关闭）后再刷新账号信息区。
    final customLogin = widget.source.account?.onLogin;
    try {
      if (customLogin != null) {
        await customLogin(context);
      } else {
        await Navigator.of(context).push<bool>(
          AppPageRoute(
            builder: (_) => LoginPage(
              source: widget.source,
              operations: _operations,
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) _showMessage('$error');
    } finally {
      if (mounted) {
        setState(() => _opening = false);
        if (_revision == revision) _requestInfo();
      }
    }
  }

  Future<void> _logout() async {
    final logout = widget.source.account?.logout;
    if (logout == null) return;
    if (_operations!.isBusy(widget.source.key)) return;
    try {
      await _operations!.execute<void>(
          widget.source.key, () async => await logout(),
          operation: 'logout');
    } catch (error) {
      if (mounted) _showMessage('退出失败：@error'.tlParams({'error': '$error'}));
    }
  }

  Future<void> _reLogin() async {
    final relogin = widget.source.account?.reLogin;
    if (relogin == null) return;
    if (_operations!.isBusy(widget.source.key)) return;
    try {
      await _operations!.execute<void>(widget.source.key, () async {
        final res = await relogin();
        if (res.error) {
          throw StateError(res.errorMessageWithoutNull);
        }
        if (res.dataOrNull != true) throw StateError('登录未完成，请重试'.tl);
      }, operation: 'relogin');
      if (mounted) _showMessage('重新登录成功'.tl);
    } catch (error) {
      if (mounted) _showMessage('$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final loggedIn = source.isLoggedIn;
    // 依赖 Scope：协调器的忙碌状态变化会重建该分组。
    final busy = _operations?.isBusy(source.key) ?? false;
    final error = _operations?.errorOf(source.key);
    final retryLogout =
        error != null && _operations?.failedOperationOf(source.key) == 'logout';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 扁平源分组：20sp 源标题 + 资料/动作行 + 分隔线，不再套通用卡片与云图标。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  source.name,
                  style: const TextStyle(fontSize: 20),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (loggedIn) ...[
                const SizedBox(width: 8),
                Builder(builder: (context) {
                  final cs = Theme.of(context).colorScheme;
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '已登录'.tl,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                  );
                }),
              ],
              if (!loggedIn) ...[
                const SizedBox(width: 8),
                Text(
                  '未登录'.tl,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (retryLogout)
          ListTile(
            title: Text('重试退出'.tl),
            subtitle: Text(error),
            trailing: const Icon(Icons.logout),
            onTap: busy ? null : _logout,
          ),
        if (!loggedIn && !retryLogout)
          ListTile(
            title: Text('登录'.tl),
            onTap: busy || _opening ? null : _openLogin,
          )
        else if (loggedIn) ...[
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
                  title: Text('账号信息加载失败'.tl),
                  subtitle: Text(snapshot.error.toString()),
                  // 失败与"登录标记"是两种状态：这里只让用户重试读取，
                  // 不自动把他退出登录，也不把缓存错误当新资料。
                  trailing: TextButton(
                    onPressed: busy ? null : _requestInfo,
                    child: Text('重试'.tl),
                  ),
                );
              }
              final items = snapshot.data ?? const <AccountInfoItem>[];
              if (items.isEmpty) {
                // 无资料可显示时不渲染噪声行（例如 NH 没有资料项）。
                return const SizedBox.shrink();
              }
              return Column(
                children: [
                  for (final item in items)
                    if (item.builder != null)
                      item.builder!(context)
                    else
                      ListTile(
                        dense: true,
                        title: Text(item.title.tl),
                        subtitle: item.value.isEmpty ? null : Text(item.value),
                      ),
                ],
              );
            },
          ),
          // 只有源显式允许且确实提供 handler 时才显示重登；
          // EH/NH 的 reLogin 不是"重新登录"语义，不在此暴露。
          // 忙碌状态取自协调器：真实 Future 结束前同一个源只允许一份操作。
          if ((source.account?.allowReLogin ?? true) &&
              source.account?.reLogin != null)
            ListTile(
              title: Text('重新登录'.tl),
              subtitle: Text('如果登录失效点击此处'.tl),
              trailing: busy
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              onTap: busy ? null : _reLogin,
            ),
          if (!retryLogout)
            ListTile(
              title: Text('退出登录'.tl),
              trailing: busy
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.logout),
              onTap: busy ? null : _logout,
            ),
        ],
        const Divider(height: 1),
      ],
    );
  }
}
