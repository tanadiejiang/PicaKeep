import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/main_page_hub.dart';
import 'package:picakeep/tools/local_app_links.dart';
import '../base.dart';
import '../components/components.dart';
import 'me_page.dart';
import 'favorites/main_favorites_page.dart';
import 'local_search_page.dart';
import 'settings/settings_page.dart';

enum _MainPaneActionPage {
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

  late final List<Widget> _pages = [
    const MePage(),
    const MainFavoritesPage(),
  ];

  _MainPaneActionPage? _currentPaneActionPage() {
    if (observer.routes.isEmpty) {
      return null;
    }
    final currentRoute =
        observer.routes.last.settings.name ?? observer.routes.last.toString();
    if (currentRoute.contains('LocalSearchPage')) {
      return _MainPaneActionPage.search;
    }
    if (currentRoute.contains('SettingsPage')) {
      return _MainPaneActionPage.settings;
    }
    return null;
  }

  _MainPaneActionPage? _paneActionTypeOf(Widget page) {
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
    if (navigator == null || context == null || _isPaneActionNavigating) {
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

  void checkClipboard() {
    checkLocalClipboard();
  }

  @override
  void initState() {
    super.initState();
    App.mainNavigatorKey = _navigatorKey;
    StateController.putIfNotExists(MainPageHub());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      StateController.find<MainPageHub>().pushPage = _openHubPage;
    });
    checkClipboard();
  }

  int _initialTabIndex() {
    try {
      final i = int.parse(appdata.settings[23]);
      if (i >= 0 && i < _pages.length) return i;
    } catch (_) {}
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return NaviPane(
      initialPage: _initialTabIndex(),
      observer: observer,
      paneItems: [
        PaneItemEntry(
          label: "我",
          icon: Icons.person_outline,
          activeIcon: Icons.person,
        ),
        PaneItemEntry(
          label: "收藏",
          icon: Icons.local_activity_outlined,
          activeIcon: Icons.local_activity,
        ),
      ],
      paneActions: [
        PaneActionEntry(
          label: "搜索",
          icon: Icons.search,
          onTap: () {
            _openHubPage(() => const LocalSearchPage());
          },
        ),
        PaneActionEntry(
          label: "设置",
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
              return NaviPaddingWidget(child: _pages[index]);
            },
          ),
        );
      },
      onPageChange: (index) {
        HapticFeedback.selectionClick();
        _navigatorKey.currentState?.pushAndRemoveUntil(
          AppPageRoute(
            preventRebuild: false,
            isRootRoute: true,
            builder: (context) {
              return NaviPaddingWidget(child: _pages[index]);
            },
          ),
          (route) => false,
        );
      },
    );
  }
}
