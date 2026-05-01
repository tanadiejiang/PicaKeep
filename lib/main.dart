import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'foundation/app.dart';
import 'foundation/history.dart';
import 'foundation/local_favorites.dart';
import 'tools/translations.dart';
import 'base.dart';
import 'pages/main_page.dart';
import 'components/window_frame.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await App.init();
  await appdata.readData();
  await loadTranslations();

  await HistoryManager().init();
  await LocalFavoritesManager().init();
  await downloadManager.init();

  await initWindowManagerIfDesktop();

  runApp(const PicaKeepApp());

  await showWindowWhenReady();
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
    if (appdata.settings[84] == '1' && _getThemeMode() == ThemeMode.dark) {
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
          builder: (context, child) {
            if (child == null) {
              return const SizedBox.shrink();
            }
            if (App.isDesktop) {
              return WindowFrame(child: child);
            }
            return child;
          },
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
                appdata.settings[84] == '1' && _getThemeMode() == ThemeMode.dark
                    ? Colors.black
                    : null,
            useMaterial3: true,
          ),
          themeMode: _getThemeMode(),
          home: const MainPage(),
        );
      },
    );
  }
}
