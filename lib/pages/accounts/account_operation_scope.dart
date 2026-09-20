import 'dart:async';

import 'package:flutter/material.dart';
import 'package:picakeep/tools/translations.dart';

class AccountOperationBusyException implements Exception {
  @override
  String toString() => '账号操作正在进行，请稍候'.tl;
}

/// 账号容器内的"单源操作"协调器。
///
/// 以 `source.key` 为单位记录**真实在途操作**：
/// - 同一源的重复操作在真实 Future 结束前只执行一份（登录/重登/退出/资料加载同理）；
/// - 不同源互不阻塞；
/// - 失败会释放门禁并把错误留给界面重试；
/// - 子页返回不释放在途操作——门禁跟着真实 Future 走，不跟导航走。
///
/// 注意：导航 Future（例如打开登录页）**不能**包进这里的门禁，否则子页提交时会自锁。
class AccountOperationController extends ChangeNotifier {
  final Map<String, Future<void>> _inflight = <String, Future<void>>{};
  final Set<String> _busy = <String>{};
  final Map<String, String> _errors = <String, String>{};
  final Map<String, String> _failedOperations = <String, String>{};
  final Map<String, int> _revisions = <String, int>{};
  final Map<Object, VoidCallback> _webviews = <Object, VoidCallback>{};
  bool _disposed = false;

  bool isBusy(String sourceKey) => _busy.contains(sourceKey);

  /// 是否还有任意源的真实操作在途（外层容器关闭前要检查）。
  bool get anyBusy => _busy.isNotEmpty;

  String? errorOf(String sourceKey) => _errors[sourceKey];

  String? failedOperationOf(String sourceKey) => _failedOperations[sourceKey];

  int revisionOf(String sourceKey) => _revisions[sourceKey] ?? 0;

  bool get hasActiveWebview => _webviews.isNotEmpty;

  void registerWebview(Object identity, VoidCallback requestClose) {
    if (_disposed) return;
    _webviews[identity] = requestClose;
    notifyListeners();
  }

  void unregisterWebview(Object identity) {
    if (_webviews.remove(identity) != null) _notify();
  }

  void requestWebviewClose() {
    if (_webviews.isNotEmpty) _webviews.values.last();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void clearError(String sourceKey) {
    _failedOperations.remove(sourceKey);
    if (_errors.remove(sourceKey) != null) _notify();
  }

  /// Different actions never borrow another action's result. Callers disable
  /// their controls while busy and receive the actual result or failure.
  Future<T> execute<T>(
    String sourceKey,
    Future<T> Function() action, {
    String operation = 'mutation',
  }) {
    if (_disposed) return Future<T>.error(StateError('Account scope disposed'));
    if (isBusy(sourceKey)) {
      return Future<T>.error(AccountOperationBusyException());
    }
    final result = Completer<T>();
    final settled = Completer<void>();
    _inflight[sourceKey] = settled.future;
    _busy.add(sourceKey);
    if (operation != 'info') {
      _errors.remove(sourceKey);
      _failedOperations.remove(sourceKey);
    }
    _notify();
    unawaited(() async {
      try {
        result.complete(await action());
      } catch (error, stack) {
        if (operation != 'info') {
          _errors[sourceKey] = error.toString();
          _failedOperations[sourceKey] = operation;
        }
        result.completeError(error, stack);
      } finally {
        _inflight.remove(sourceKey);
        _busy.remove(sourceKey);
        if (operation != 'info') {
          _revisions[sourceKey] = revisionOf(sourceKey) + 1;
        }
        settled.complete();
        _notify();
      }
    }());
    return result.future;
  }

  /// 在 [sourceKey] 上执行一次真实操作。
  ///
  /// 同源已有在途操作时**直接复用**该 Future，不重复执行；操作自身的异常会被
  /// 记录到 [errorOf]，因此调用方 await 不会被异常打断。
  Future<void> run(String sourceKey, Future<void> Function() action) {
    final existing = _inflight[sourceKey];
    if (existing != null) return existing;

    return execute<void>(sourceKey, action).catchError((Object _) {});
  }

  @override
  void dispose() {
    _disposed = true;
    _webviews.clear();
    super.dispose();
  }
}

/// 把协调器放进账号容器（位于稳定内层 Navigator 上方）。
///
/// 账号页通过 [maybeOf] 取用；非账号入口（例如 EH 订阅页自己打开的登录页）
/// 取不到时退化为页内局部控制，不因缺 Scope 崩溃。
class AccountOperationScope
    extends InheritedNotifier<AccountOperationController> {
  const AccountOperationScope({
    super.key,
    required AccountOperationController controller,
    required super.child,
  }) : super(notifier: controller);

  static AccountOperationController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<AccountOperationScope>()
        ?.notifier;
  }
}
