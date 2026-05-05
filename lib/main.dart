import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'foundation/app.dart';
import 'foundation/history.dart';
import 'foundation/local_favorites.dart';
import 'tools/translations.dart';
import 'base.dart';
import 'pages/auth_page.dart';
import 'pages/main_page.dart';
import 'components/window_frame.dart';
import 'server/local_server_runtime_sync.dart';
import 'tools/block_screenshot.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await App.init();
  await appdata.readData();
  await loadTranslations();

  await HistoryManager().init();
  await LocalFavoritesManager().init();
  await downloadManager.init();
  await App.applyDisplayModePreference();

  await initWindowManagerIfDesktop();

  try {
    await syncDesktopLocalServerRuntimeForCurrentMode();
  } catch (e, s) {
    debugPrint('Failed to sync local server runtime: $e\n$s');
  }

  runApp(const PicaKeepApp());

  await showWindowWhenReady();
}

class PicaKeepApp extends StatefulWidget {
  const PicaKeepApp({super.key});

  @override
  State<PicaKeepApp> createState() => _PicaKeepAppState();
}

class _PicaKeepAppState extends State<PicaKeepApp> with WidgetsBindingObserver {
  static const List<Color> _seedColors = [
    Colors.blue,
    Colors.red,
    Colors.pink,
    Colors.purple,
    Colors.indigo,
    Colors.blue,
    Colors.cyan,
    Colors.teal,
    Colors.green,
    Colors.lime,
    Colors.yellow,
    Colors.amber,
    Colors.orange,
  ];

  bool _requireAuthOnResume = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    App.updater = _refreshApp;
    if (appdata.settings[12] == '1') {
      blockScreenshot();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (App.updater == _refreshApp) {
      App.updater = null;
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _requireAuthOnResume = appdata.settings[13] == '1';
      return;
    }

    if (state == AppLifecycleState.resumed) {
      if (_requireAuthOnResume &&
          appdata.settings[13] == '1' &&
          !AuthPage.lock &&
          App.globalContext != null) {
        _requireAuthOnResume = false;
        AuthPage.initial = false;
        AuthPage.lock = true;
        App.globalTo(() => const AuthPage());
      } else {
        _requireAuthOnResume = false;
      }
    }
  }

  void _refreshApp() {
    if (mounted) {
      setState(() {});
    }
  }

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

  Color _getSeedColor() {
    final index = int.tryParse(appdata.settings[27]) ?? 0;
    if (index <= 0 || index >= _seedColors.length) {
      return Colors.blue;
    }
    return _seedColors[index];
  }

  ColorScheme _buildLightScheme(ColorScheme? lightDynamic) {
    if (appdata.settings[27] == '0' && lightDynamic != null) {
      return lightDynamic;
    }
    return ColorScheme.fromSeed(seedColor: _getSeedColor());
  }

  ColorScheme _buildDarkScheme(ColorScheme? darkDynamic) {
    if (appdata.settings[27] == '0' && darkDynamic != null) {
      return darkDynamic;
    }
    return ColorScheme.fromSeed(
      seedColor: _getSeedColor(),
      brightness: Brightness.dark,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        return MaterialApp(
          title: 'PicaKeep',
          navigatorKey: App.navigatorKey,
          debugShowCheckedModeBanner: false,
          locale: App.locale,
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('zh', 'TW'),
            Locale('en', 'US'),
          ],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
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
            colorScheme: _buildLightScheme(lightDynamic),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: _getPureBlack(_buildDarkScheme(darkDynamic)),
            scaffoldBackgroundColor:
                appdata.settings[84] == '1' && _getThemeMode() == ThemeMode.dark
                    ? Colors.black
                    : null,
            useMaterial3: true,
          ),
          themeMode: _getThemeMode(),
          home:
              appdata.settings[13] == '1' ? const AuthPage() : const MainPage(),
        );
      },
    );
  }
}
