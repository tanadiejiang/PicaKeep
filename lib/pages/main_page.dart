import 'package:flutter/material.dart';
import 'package:picakeep/tools/local_app_links.dart';
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

  final _pages = const <Widget>[
    MePage(),
    MainFavoritesPage(),
  ];

  void checkClipboard() {
    checkLocalClipboard();
  }

  @override
  void initState() {
    super.initState();
    checkClipboard();
  }

  @override
  Widget build(BuildContext context) {
    return NaviPane(
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
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LocalSearchPage()),
            );
          },
        ),
        PaneActionEntry(
          label: "设置",
          icon: Icons.settings_outlined,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            );
          },
        ),
      ],
      pageBuilder: (index) => _pages[index],
    );
  }
}
