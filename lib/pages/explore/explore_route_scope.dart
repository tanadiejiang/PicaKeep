/// 探索页面与主导航之间的**路由恢复接缝**。
///
/// 背景：侧栏/入口的「设置」「在线搜索」等页面由 `MainPage` 直接 push，探索页
/// 拿不到那次 push 的 Future，因此无法在"设置页返回"时主动核对上下文（站点、
/// 登录态、卡片与屏蔽配置可能都变了）。而 `MainPage` 已有的 [NaviObserver]
/// 能观察到每一次 push/pop。
///
/// 做法：`MainPage` 通过 [ExploreRouteScope] 把该 [NaviObserver] 暴露给子树；
/// 探索页用 [ExploreRouteRestoreMixin] 订阅它，在**自己重新成为 current route**
/// 时排一次队做上下文核对。
///
/// 注意：它不是 `RouteObserver`，因此不能套 `RouteAware` —— 这里只需要"路由栈
/// 变了"这一个信号，再自己判断当前路由是不是本页。
library;

import 'package:flutter/widgets.dart';
import 'package:picakeep/components/components.dart';

/// 把主导航的 [NaviObserver] 暴露给子树（不依赖它重建）。
///
/// 故意不用 `InheritedNotifier`：那会在每次导航变化时重建所有依赖者，而本机制
/// 要的是"页面自己决定何时核对"，不是"导航一变就重建"。因此这里只暴露
/// Listenable，由页面手动订阅。
class ExploreRouteScope extends InheritedWidget {
  const ExploreRouteScope({
    super.key,
    required this.observer,
    required super.child,
  });

  final NaviObserver observer;

  static NaviObserver? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ExploreRouteScope>()
        ?.observer;
  }

  @override
  bool updateShouldNotify(ExploreRouteScope oldWidget) =>
      observer != oldWidget.observer;
}

/// 让页面在"自己重新成为当前路由"时收到一次回调。
///
/// 使用方只需实现 [onExploreRouteRestored]。回调在**帧后**触发，避免在导航回调
/// 里同步 setState（那会在路由动画期间重建整棵树）。
mixin ExploreRouteRestoreMixin<T extends StatefulWidget> on State<T> {
  NaviObserver? _routeObserver;
  ModalRoute<dynamic>? _ownRoute;

  /// 上一次已知的当前路由是否为本页，用于识别"从别处返回"。
  bool _wasCurrent = true;

  /// 自己重新成为当前路由时调用（已排在帧后）。
  void onExploreRouteRestored() {}

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = ExploreRouteScope.maybeOf(context);
    _ownRoute = _findOwnRoute(observer);
    if (identical(observer, _routeObserver)) return;
    _routeObserver?.removeListener(_handleRouteChanged);
    _routeObserver = observer;
    _routeObserver?.addListener(_handleRouteChanged);
    _wasCurrent = _isCurrentRoute();
  }

  @override
  void dispose() {
    _routeObserver?.removeListener(_handleRouteChanged);
    _routeObserver = null;
    super.dispose();
  }

  void _handleRouteChanged() {
    if (!mounted) return;
    final isCurrent = _isCurrentRoute();
    final wasCurrent = _wasCurrent;
    _wasCurrent = isCurrent;
    // 只在"重新成为当前"时核对；离开时不做任何事。
    if (!isCurrent || wasCurrent) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isCurrentRoute()) return;
      onExploreRouteRestored();
    });
  }

  /// 本页是否仍是当前路由。
  ///
  /// 只比较页面路由：菜单、对话框的开合不代表离开页面，也不应触发整页核对。
  bool _isCurrentRoute() {
    final route = _ownRoute;
    if (route == null) return true;
    final pages = _routeObserver?.routes.whereType<PageRoute>();
    if (route is PageRoute && pages != null && pages.isNotEmpty) {
      return identical(pages.last, route);
    }
    return route.isCurrent;
  }

  /// Locate the route by its subtree, without subscribing this whole page to
  /// ModalRoute.of's isCurrent/canPop notifications when a menu opens or closes.
  /// RouteSettings cannot identify it: unnamed routes share const settings.
  ModalRoute<dynamic>? _findOwnRoute(NaviObserver? observer) {
    if (observer == null) return null;
    final contexts = <BuildContext, ModalRoute<dynamic>>{
      for (final route in observer.routes.whereType<ModalRoute<dynamic>>())
        if (route.subtreeContext != null) route.subtreeContext!: route,
    };
    ModalRoute<dynamic>? result = contexts[context];
    if (result != null) return result;
    context.visitAncestorElements((element) {
      result = contexts[element];
      return result == null;
    });
    return result;
  }
}
