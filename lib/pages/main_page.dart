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

  List<Widget> get _pages => [
        const MePage(),
        if (_showAiTab) const AiPage(),
        const MainFavoritesPage(),
        if (_showServiceInfoTab) const ServiceInfoPage(),
      ];

  List<PaneItemEntry> get _paneItems => [
        PaneItemEntry(
          label: '我',
          icon: Icons.person_outline,
          activeIcon: Icons.person,
        ),
        if (_showAiTab)
          PaneItemEntry(
            label: 'AI',
            icon: Icons.smart_toy_outlined,
            activeIcon: Icons.smart_toy,
          ),
        PaneItemEntry(
          label: '收藏',
          icon: Icons.local_activity_outlined,
          activeIcon: Icons.local_activity,
        ),
        if (_showServiceInfoTab)
          PaneItemEntry(
            label: '服务信息',
            icon: Icons.router_outlined,
            activeIcon: Icons.router,
          ),
      ];

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

  int _initialTabIndex(int pageCount) {
    try {
      final i = int.parse(appdata.settings[23]);
      if (i >= 0 && i < pageCount) {
        return i;
      }
    } catch (_) {}
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    final paneItems = _paneItems;
    return NaviPane(
      key: ValueKey((_showServiceInfoTab, _showAiTab)),
      initialPage: _initialTabIndex(pages.length),
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
              return NaviPaddingWidget(child: pages[index]);
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
              return NaviPaddingWidget(child: pages[index]);
            },
          ),
          (route) => false,
        );
      },
    );
  }
}
