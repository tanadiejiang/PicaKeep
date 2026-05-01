import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/tools/local_app_links.dart';
import '../base.dart';
import '../components/components.dart';
import 'me_page.dart';
import 'favorites/main_favorites_page.dart';
import 'local_search_page.dart';
import 'settings/settings_page.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  final observer = NaviObserver();
  final _navigatorKey = GlobalKey<NavigatorState>();

  late final List<Widget> _pages = [
    const MePage(),
    const MainFavoritesPage(),
  ];

  void checkClipboard() {
    checkLocalClipboard();
  }

  @override
  void initState() {
    super.initState();
    App.mainNavigatorKey = _navigatorKey;
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
            final ctx = App.mainNavigatorKey?.currentContext;
            if (ctx != null) {
              App.to(ctx, () => const LocalSearchPage());
            }
          },
        ),
        PaneActionEntry(
          label: "设置",
          icon: Icons.settings_outlined,
          onTap: () {
            final ctx = App.mainNavigatorKey?.currentContext;
            if (ctx != null) {
              App.to(ctx, () => const SettingsPage());
            }
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
