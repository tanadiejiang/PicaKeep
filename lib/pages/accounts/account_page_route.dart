import 'dart:async';

import 'package:flutter/material.dart';
import 'package:picakeep/tools/translations.dart';

import 'account_operation_scope.dart';
import 'accounts_page.dart';

/// 账号管理的唯一打开入口（我页 / 在线搜索页共用）。
///
/// 返回的 Future 在**整个账号容器关闭时**完成；调用方 await 它即可在关闭后
/// 刷新登录数量或可搜索源。
Future<void> showAccountsPage(BuildContext context) {
  return Navigator.of(context).push<void>(_AccountPageRoute());
}

class _AccountPageRoute extends PageRouteBuilder<void> {
  factory _AccountPageRoute() =>
      _AccountPageRoute._(GlobalKey<_AccountPageHostState>());

  _AccountPageRoute._(this.hostKey)
      : super(
          settings: const RouteSettings(name: 'AccountsPage'),
          opaque: false,
          barrierDismissible: false,
          pageBuilder: (context, animation, secondaryAnimation) =>
              AccountPageHost(key: hostKey),
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              FadeTransition(opacity: animation, child: child),
        );

  final GlobalKey<_AccountPageHostState> hostKey;

  @override
  bool get willHandlePopInternally =>
      (hostKey.currentState?._mustHandleBack ?? false) ||
      super.willHandlePopInternally;

  @override
  bool didPop(dynamic result) {
    if (hostKey.currentState?._consumeProtectedBack() ?? false) return false;
    return super.didPop(null);
  }
}

/// 账号容器：按可用宽度自适应，并用一个稳定的内层 Navigator 承载
/// 账号总览与登录页。
///
/// - `<= 500dp`：全屏；
/// - `> 500dp`：居中、宽 500dp、高度不超过可用视口的 90%（键盘弹出时按剩余高度收缩）。
///
/// 返回顺序：先关闭最上层的网页/对话框，再退登录页，最后关闭容器。
/// 内层每多一个非根路由，就在外层路由上镜像一个 [LocalHistoryEntry]，
/// 这样主导航里"直接 pop 最上层路由"的返回分派也会被正确消耗为"退一层内层页面"。
class AccountPageHost extends StatefulWidget {
  const AccountPageHost({super.key});

  @override
  State<AccountPageHost> createState() => _AccountPageHostState();
}

class _AccountPageHostState extends State<AccountPageHost> {
  final AccountOperationController _operations = AccountOperationController();
  final GlobalKey<NavigatorState> _innerKey = GlobalKey<NavigatorState>();
  late final _AccountInnerObserver _observer = _AccountInnerObserver(this);
  final Map<Route<dynamic>, LocalHistoryEntry> _mirrors =
      <Route<dynamic>, LocalHistoryEntry>{};
  bool _suppressMirrorRemoval = false;

  bool get _mustHandleBack =>
      _operations.hasActiveWebview || _operations.anyBusy;

  bool _consumeProtectedBack() {
    if (_operations.hasActiveWebview) {
      // Direct parent.pop can run under the navigator lock. Close the captured
      // root web route after that dispatch finishes, without consuming history.
      scheduleMicrotask(_operations.requestWebviewClose);
      return true;
    }
    if (_mirrors.isNotEmpty &&
        _mirrors.keys.last.popDisposition == RoutePopDisposition.doNotPop) {
      // A direct parent pop must also honor an inner dialog's PopScope.
      scheduleMicrotask(() => _innerKey.currentState?.maybePop());
      return true;
    }
    if (_mirrors.isNotEmpty || !_operations.anyBusy) return false;
    scheduleMicrotask(() {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('账号操作正在进行，请稍候'.tl)),
      );
    });
    return true;
  }

  @override
  void dispose() {
    _mirrors.clear();
    _operations.dispose();
    super.dispose();
  }

  void _close() {
    if (_consumeProtectedBack()) return;
    Navigator.of(context).pop();
  }

  void _attachMirror(Route<dynamic> innerRoute) {
    final outer = ModalRoute.of(context);
    if (outer == null || _mirrors.containsKey(innerRoute)) return;
    final entry = LocalHistoryEntry(
      onRemove: () {
        _mirrors.remove(innerRoute);
        // 抑制 detachMirror 主动 remove 时的反向回调，避免双退。
        if (_suppressMirrorRemoval || !mounted) return;
        final inner = _innerKey.currentState;
        if (inner != null && inner.canPop()) {
          inner.pop();
        }
      },
    );
    _mirrors[innerRoute] = entry;
    outer.addLocalHistoryEntry(entry);
  }

  void _detachMirror(Route<dynamic> innerRoute) {
    final entry = _mirrors.remove(innerRoute);
    if (entry == null) return;
    _suppressMirrorRemoval = true;
    try {
      // entry.remove() 会同步触发 onRemove，必须在此处抑制。
      entry.remove();
    } finally {
      _suppressMirrorRemoval = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 500;
        // Scope 位于稳定内层 Navigator 上方：窗口缩放重建 Navigator 也不会丢操作状态。
        final inner = AccountOperationScope(
          controller: _operations,
          child: Navigator(
            key: _innerKey,
            observers: <NavigatorObserver>[_observer],
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => AccountsPage(onClose: _close),
            ),
          ),
        );

        if (!wide) {
          return Scaffold(
            body: SafeArea(child: inner),
          );
        }

        // 键盘弹起时按剩余高度收缩，避免遮住登录/确认按钮。
        final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
        final availableHeight =
            (constraints.maxHeight - bottomInset).clamp(0.0, double.infinity);
        return Scaffold(
          backgroundColor: Colors.black.withValues(alpha: 0.32),
          body: SafeArea(
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  key: const ValueKey('accounts-backdrop'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _close,
                ),
                Center(
                    child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 500,
                    maxHeight: availableHeight * 0.9,
                  ),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: Material(
                      clipBehavior: Clip.antiAlias,
                      borderRadius: BorderRadius.circular(16),
                      child: inner,
                    ),
                  ),
                )),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 把内层 Navigator 的非根路由镜像到外层路由的历史记录上。
class _AccountInnerObserver extends NavigatorObserver {
  _AccountInnerObserver(this.host);

  final _AccountPageHostState host;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // 内层根路由（账号总览）不镜像：它对应"关闭容器"这一次返回。
    if (previousRoute != null) {
      host._attachMirror(route);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    host._detachMirror(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    host._detachMirror(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) host._detachMirror(oldRoute);
    if (newRoute != null) host._attachMirror(newRoute);
  }
}
