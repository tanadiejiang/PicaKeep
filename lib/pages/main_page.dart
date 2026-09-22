import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/foundation/main_page_hub.dart';
import 'package:picakeep/tools/local_app_links.dart';
import '../base.dart';
import '../components/components.dart';
import 'ai/ai_page.dart';
import 'explore/explore_page.dart';
import 'explore/explore_route_scope.dart';
import 'favorites/main_favorites_page.dart';
import 'local_search_page.dart';
import 'me_page.dart';
import 'online_search/online_search_page.dart';
import 'service_info_page.dart';
import 'settings/settings_page.dart';

enum _MainPaneActionPage {
  onlineSearch,
  search,
  settings,
}

/// 主导航的局部稳定标识。
///
/// `settings[23]` 是**历史存储值**（0=我，1=收藏），不是"最终数组下标"：
/// 直接拿它当索引，在开启 AI 或服务信息 tab 后含义就会漂移（1 会落到 AI）。
/// 因此固定语义映射按 id 查当前可见列表内的下标。
enum MainTabId { me, ai, favorites, explore, serviceInfo }

/// 把历史设置值 `settings[23]`（`0`=我 / `1`=收藏）解析成**当前可见列表**内的下标。
///
/// 关键点：`settings[23]` 是历史存储值，含义只有"我 / 收藏"两种，**不是**最终
/// 数组下标 —— 直接拿它当索引，开启 AI 后 `1` 会落到 AI 页。因此这里按
/// [MainTabId] 在当前可见 tab 列表里查下标；坏值一律回落到「我」。
///
/// 不迁移、不改写旧存储值。
@visibleForTesting
int resolveInitialMainTabIndex({
  required List<MainTabId> visibleTabs,
  required String storedSetting,
}) {
  final wanted =
      storedSetting.trim() == '1' ? MainTabId.favorites : MainTabId.me;
  final index = visibleTabs.indexOf(wanted);
  if (index >= 0) return index;
  final fallback = visibleTabs.indexOf(MainTabId.me);
  return fallback >= 0 ? fallback : 0;
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  final observer = NaviObserver();
  final _navigatorKey = GlobalKey<NavigatorState>();
  bool _isPaneActionNavigating = false;
  Timer? _clipboardCheckTimer;

  bool get _showServiceInfoTab =>
      normalizeAppRuntimeMode(appdata.settings[appRuntimeModeSettingIndex]) ==
      appRuntimeModeServer;

  bool get _showAiTab => appdata.settings[showAiTabSettingIndex] == '1';

  /// 当前可见的 tab 声明（**唯一来源**）：手机底栏与桌面侧栏都由它生成，
  /// 避免"两份索引各写一遍"后分叉。
  List<({MainTabId id, Widget page, PaneItemEntry item})> get _tabs => [
        (
          id: MainTabId.me,
          page: const MePage(),
          item: PaneItemEntry(
            label: '我',
            icon: Icons.person_outline,
            activeIcon: Icons.person,
          ),
        ),
        if (_showAiTab)
          (
            id: MainTabId.ai,
            page: const AiPage(),
            item: PaneItemEntry(
              label: 'AI',
              icon: Icons.smart_toy_outlined,
              activeIcon: Icons.smart_toy,
            ),
          ),
        (
          id: MainTabId.favorites,
          page: const MainFavoritesPage(),
          item: PaneItemEntry(
            label: '收藏',
            icon: Icons.local_activity_outlined,
            activeIcon: Icons.local_activity,
          ),
        ),
        // 探索恒显示：不加隐藏开关，也不用服务配置事件兜底。
        (
          id: MainTabId.explore,
          page: const ExplorePage(),
          item: PaneItemEntry(
            label: '探索',
            icon: Icons.explore_outlined,
            activeIcon: Icons.explore,
          ),
        ),
        if (_showServiceInfoTab)
          (
            id: MainTabId.serviceInfo,
            page: const ServiceInfoPage(),
            item: PaneItemEntry(
              label: '服务信息',
              icon: Icons.router_outlined,
              activeIcon: Icons.router,
            ),
          ),
      ];

  List<Widget> get _pages =>
      _tabs.map((tab) => tab.page).toList(growable: false);

  List<PaneItemEntry> get _paneItems =>
      _tabs.map((tab) => tab.item).toList(growable: false);

  _MainPaneActionPage? _currentPaneActionPage() {
    if (observer.routes.isEmpty) {
      return null;
    }
    final currentRoute =
        observer.routes.last.settings.name ?? observer.routes.last.toString();
    if (currentRoute.contains('OnlineSearchPage')) {
      return _MainPaneActionPage.onlineSearch;
    }
    if (currentRoute.contains('LocalSearchPage')) {
      return _MainPaneActionPage.search;
    }
    if (currentRoute.contains('SettingsPage')) {
      return _MainPaneActionPage.settings;
    }
    return null;
  }

  _MainPaneActionPage? _paneActionTypeOf(Widget page) {
    if (page is OnlineSearchPage) {
      return _MainPaneActionPage.onlineSearch;
    }
    if (page is LocalSearchPage) {
      return _MainPaneActionPage.search;
    }
    if (page is SettingsPage) {
      return _MainPaneActionPage.settings;
    }
    return null;
  }

  void _openHubPage(Widget Function() pageBuilder) {
    final navigator = _navigatorKey.currentState;
    final context = _navigatorKey.currentContext;
    if (navigator == null ||
        context == null ||
        _isPaneActionNavigating ||
        App.isNavigationLocked) {
      return;
    }

    final page = pageBuilder();
    final targetPage = _paneActionTypeOf(page);
    final currentPage = _currentPaneActionPage();
    if (targetPage != null && currentPage == targetPage) {
      return;
    }

    _isPaneActionNavigating = true;
    Future.delayed(const Duration(milliseconds: 350), () {
      _isPaneActionNavigating = false;
    });

    final route = AppPageRoute(
      preventRebuild: false,
      settings: RouteSettings(name: page.runtimeType.toString()),
      builder: (_) => page,
    );
    if (targetPage != null && currentPage != null) {
      navigator.pushReplacement(route);
      return;
    }
    navigator.push(route);
  }

  void _handleServiceConfigChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _scheduleClipboardCheck() {
    _clipboardCheckTimer?.cancel();
    _clipboardCheckTimer = Timer(const Duration(milliseconds: 2800), () {
      if (!mounted) {
        return;
      }
      checkLocalClipboard();
    });
  }

  @override
  void initState() {
    super.initState();
    AppStartupTrace.log('MainPage.initState');
    App.mainNavigatorKey = _navigatorKey;
    App.serviceConfigVersion.addListener(_handleServiceConfigChanged);
    StateController.putIfNotExists(MainPageHub());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppStartupTrace.log('MainPage.firstPostFrame');
      if (!mounted) return;
      StateController.find<MainPageHub>().pushPage = _openHubPage;
      _scheduleClipboardCheck();
    });
  }

  @override
  void dispose() {
    _clipboardCheckTimer?.cancel();
    App.serviceConfigVersion.removeListener(_handleServiceConfigChanged);
    super.dispose();
  }

  /// 启动页下标：由历史设置值 + 当前可见 tab 列表共同决定。
  ///
  /// 不再把 `settings[23]` 直接当数组下标：开启 AI 后它会把"收藏"错落到 AI 页。
  int _initialTabIndex() {
    final stored = 23 < appdata.settings.length ? appdata.settings[23] : '';
    return resolveInitialMainTabIndex(
      visibleTabs: _tabs.map((tab) => tab.id).toList(growable: false),
      storedSetting: stored,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    final paneItems = _paneItems;
    return NaviPane(
      key: ValueKey((_showServiceInfoTab, _showAiTab)),
      initialPage: _initialTabIndex(),
      observer: observer,
      paneItems: paneItems,
      paneActions: [
        PaneActionEntry(
          label: '在线搜索',
          icon: Icons.travel_explore,
          onTap: () {
            _openHubPage(() => const OnlineSearchPage());
          },
        ),
        PaneActionEntry(
          label: '搜索',
          icon: Icons.search,
          onTap: () {
            _openHubPage(() => const LocalSearchPage());
          },
        ),
        PaneActionEntry(
          label: '设置',
          icon: Icons.settings_outlined,
          onTap: () {
            _openHubPage(() => const SettingsPage());
          },
        ),
      ],
      pageBuilder: (index) {
        return Navigator(
          observers: [observer],
          key: _navigatorKey,
          onGenerateRoute: (settings) => AppPageRoute(
            preventRebuild: false,
            isRootRoute: true,
            builder: (context) {
              return _wrapPage(pages[index]);
            },
          ),
        );
      },
      onPageChange: (index) {
        if (App.isNavigationLocked) {
          return;
        }
        HapticFeedback.selectionClick();
        _navigatorKey.currentState?.pushAndRemoveUntil(
          AppPageRoute(
            preventRebuild: false,
            isRootRoute: true,
            builder: (context) {
              return _wrapPage(pages[index]);
            },
          ),
          (route) => false,
        );
      },
    );
  }

  /// 给 tab 页面套上导航 padding 与**路由恢复作用域**。
  ///
  /// 探索页需要知道自己何时"重新成为当前路由"，才能在从侧栏设置/详情/账号页
  /// 返回后做一次上下文核对 —— 它拿不到那些 push 的 Future，只能靠路由观察。
  Widget _wrapPage(Widget page) {
    return ExploreRouteScope(
      observer: observer,
      child: NaviPaddingWidget(child: page),
    );
  }
}
