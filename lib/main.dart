import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'foundation/app.dart';
import 'foundation/history.dart';
import 'foundation/local_favorites.dart';
import 'base.dart';
import 'pages/main_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await App.init();
  await appdata.readData();

  await HistoryManager().init();
  await LocalFavoritesManager().init();

  runApp(const PicaKeepApp());
}

class PicaKeepApp extends StatefulWidget {
  const PicaKeepApp({super.key});

  @override
  State<PicaKeepApp> createState() => _PicaKeepAppState();
}

class _PicaKeepAppState extends State<PicaKeepApp> {
  ThemeMode _getThemeMode() {
    final value = appdata.settings[32];
    switch (value) {
      case '1':
        return ThemeMode.light;
      case '2':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  ColorScheme _getPureBlack(ColorScheme scheme) {
    if (appdata.settings[28] == '1' && _getThemeMode() == ThemeMode.dark) {
      return scheme.copyWith(
        surface: Colors.black,
        surfaceContainerHighest: const Color(0xFF121212),
      );
    }
    return scheme;
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        return MaterialApp(
          title: 'PicaKeep',
          navigatorKey: App.navigatorKey,
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme:
                lightDynamic ?? ColorScheme.fromSeed(seedColor: Colors.blue),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: _getPureBlack(darkDynamic ??
                ColorScheme.fromSeed(
                    seedColor: Colors.blue, brightness: Brightness.dark)),
            scaffoldBackgroundColor:
                appdata.settings[28] == '1' && _getThemeMode() == ThemeMode.dark
                    ? Colors.black
                    : null,
            useMaterial3: true,
          ),
          themeMode: _getThemeMode(),
          onGenerateRoute: (settings) {
            return MaterialPageRoute(
              builder: (context) {
                App.mainNavigatorKey = GlobalKey<NavigatorState>();
                return const MainPage();
              },
            );
          },
        );
      },
    );
  }
}
