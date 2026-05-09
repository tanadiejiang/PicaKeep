import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'base.dart';
import 'components/window_frame.dart';
import 'foundation/app.dart';
import 'foundation/history.dart';
import 'foundation/local_favorites.dart';
import 'pages/auth_page.dart';
import 'pages/main_page.dart';
import 'server/local_server_runtime_sync.dart';
import 'tools/block_screenshot.dart';
import 'tools/translations.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _configureGlobalImageCache();

  await _initializeApplication();
  runApp(const PicaKeepApp());

  if (App.isDesktop) {
    unawaited(_showDesktopWindowWhenReady());
  }
}

Future<void> _initializeApplication() async {
  await App.init();
  await Future.wait([
    appdata.readData(),
    loadTranslations(),
  ]);

  if (App.isDesktop) {
    await initWindowManagerIfDesktop();
  }
}

Future<void> _showDesktopWindowWhenReady() async {
  if (!App.isDesktop) {
    return;
  }
  await showWindowWhenReady();
}

Future<void> _runDeferredStartupWork() async {
  Future<void>.delayed(
    const Duration(milliseconds: 800),
    () => App.applyDisplayModePreference(),
  );
  Future<void>.delayed(
    const Duration(milliseconds: 1800),
    _warmStartupManagers,
  );
  Future<void>.delayed(
    const Duration(milliseconds: 2800),
    _syncStartupServerRuntime,
  );
}

void _configureGlobalImageCache() {
  final imageCache = PaintingBinding.instance.imageCache;
  if (imageCache.maximumSizeBytes < 192 * 1024 * 1024) {
    imageCache.maximumSizeBytes = 192 * 1024 * 1024;
  }
  if (imageCache.maximumSize < 180) {
    imageCache.maximumSize = 180;
  }
}

Future<void> _warmStartupManagers() async {
  try {
    await Future.wait([
      LocalFavoritesManager().init(),
      HistoryManager().init(),
    ]);
  } catch (e, s) {
    debugPrint('Failed to warm startup managers: $e\n$s');
  }
}

Future<void> _syncStartupServerRuntime() async {
  try {
    await syncLocalServerRuntimeForCurrentMode();
  } catch (e, s) {
    debugPrint('Failed to sync local server runtime: $e\n$s');
  }
}

class PicaKeepApp extends StatefulWidget {
  const PicaKeepApp({super.key});

  @override
  State<PicaKeepApp> createState() => _PicaKeepAppState();
}

class _PicaKeepAppState extends State<PicaKeepApp>
    with WidgetsBindingObserver {
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
  DateTime? _lastBackgroundedAt;
  bool _deferredStartupQueued = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    App.updater = _refreshApp;
    App.serviceConfigVersion.addListener(_handleServiceStateSyncRequest);
    App.serviceRuntimeVersion.addListener(_handleServiceStateSyncRequest);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (appdata.settings[12] == '1') {
      blockScreenshot();
    }
    _scheduleDeferredStartupWork();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    App.serviceConfigVersion.removeListener(_handleServiceStateSyncRequest);
    App.serviceRuntimeVersion.removeListener(_handleServiceStateSyncRequest);
    if (App.updater == _refreshApp) {
      App.updater = null;
    }
    super.dispose();
  }

  void _scheduleDeferredStartupWork() {
    if (_deferredStartupQueued) {
      return;
    }
    _deferredStartupQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runDeferredStartupWork());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _requireAuthOnResume = appdata.settings[13] == '1';
      _lastBackgroundedAt = DateTime.now();
      return;
    }

    if (state == AppLifecycleState.resumed) {
      final backgroundDuration = _lastBackgroundedAt == null
          ? Duration.zero
          : DateTime.now().difference(_lastBackgroundedAt!);
      if (_requireAuthOnResume &&
          backgroundDuration >= const Duration(seconds: 2) &&
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
      _lastBackgroundedAt = null;
    }
  }

  void _refreshApp() {
    if (mounted) {
      setState(() {});
    }
  }

  void _handleServiceStateSyncRequest() {
    if (!App.isAndroid) {
      return;
    }
    unawaited(syncAndroidForegroundServiceForCurrentMode());
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
            return _MobileSystemUiFrame(child: child);
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

class _MobileSystemUiFrame extends StatelessWidget {
  const _MobileSystemUiFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final backgroundColor = theme.scaffoldBackgroundColor;
    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: backgroundColor,
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarDividerColor: Colors.transparent,
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: ColoredBox(
        color: backgroundColor,
        child: child,
      ),
    );
  }
}