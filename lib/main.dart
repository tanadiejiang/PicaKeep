import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'base.dart';
import 'components/window_frame.dart';
import 'foundation/app.dart';
import 'foundation/archive/archive_registry.dart';
import 'foundation/history.dart';
import 'foundation/local_data_source.dart';
import 'foundation/local_favorites.dart';
import 'foundation/remote_library_event_channel.dart';
import 'pages/auth_page.dart';
import 'pages/main_page.dart';
import 'server/local_server_runtime.dart';
import 'server/local_server_runtime_sync.dart';
import 'tools/block_screenshot.dart';
import 'tools/dynamic_theme_channel.dart';
import 'tools/translations.dart';

Future<void> main(List<String> args) async {
  AppStartupTrace.log('main.start');
  WidgetsFlutterBinding.ensureInitialized();
  AppStartupTrace.log('widgetsBinding.ready');

  // Headless 服务端模式：无界面、直接启动本地服务（供无显示器环境如 NAS 使用，
  // 由 xvfb 包裹运行）。不调用 runApp / window_manager，仅复用与桌面版完全相同的
  // PicaKeepAdminServer，保证能力一致。
  if (args.contains('--server')) {
    await _runHeadlessServer(args);
    return;
  }

  _configureGlobalImageCache();
  AppStartupTrace.log('imageCache.configured');

  await _initializeApplication();
  AppStartupTrace.log('initializeApplication.done');
  runApp(const PicaKeepApp());
  AppStartupTrace.log('runApp.called');

  if (App.isDesktop) {
    unawaited(_showDesktopWindowWhenReady());
  }
}

Future<void> _runHeadlessServer(List<String> args) async {
  final dataPathOverride = _resolveHeadlessDataPathOverride(args);
  await App.init(
    dataPathOverride: dataPathOverride,
    migrateExistingData: true,
  );
  setManagedDataRootOverride(App.dataPath);
  await appdata.readEssentialData();
  ArchiveRegistry.initDefaults();

  final runtime = LocalServerRuntime.instance;
  final configPath = _parseConfigPathArg(args);
  if (configPath != null) {
    runtime.configPathOverride = configPath;
  }

  try {
    await runtime.start();
  } catch (e, s) {
    stderr.writeln('PicaKeep headless 服务端启动失败: $e');
    stderr.writeln(s);
    exitCode = 1;
    return;
  }

  final snapshot = await runtime.readSnapshot();
  stdout.writeln('PicaKeep headless 服务端已启动');
  stdout.writeln('配置文件: ${snapshot.configPath}');
  stdout.writeln('监听: ${snapshot.host}:${snapshot.port}');
  if (snapshot.statusUrl != null) {
    stdout.writeln('状态接口: ${snapshot.statusUrl}');
  }
  if (snapshot.adminUrl != null) {
    stdout.writeln('管理后台: ${snapshot.adminUrl}');
  }
  stdout.writeln('停止服务: Ctrl+C');

  final completer = Completer<void>();
  var stopping = false;
  Future<void> shutdown(String signalName) async {
    if (stopping) {
      return;
    }
    stopping = true;
    stdout.writeln('\n收到 $signalName，正在停止服务...');
    try {
      await runtime.stop();
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  ProcessSignal.sigint.watch().listen((_) => unawaited(shutdown('Ctrl+C')));
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => unawaited(shutdown('SIGTERM')));
  }
  await completer.future;
}

String? _resolveHeadlessDataPathOverride(List<String> args) {
  final envOverride = Platform.environment[App.serverDataDirEnvKey]?.trim();
  if (envOverride != null && envOverride.isNotEmpty) {
    return envOverride;
  }
  final configPath = _parseConfigPathArg(args);
  if (configPath != null) {
    return File(configPath).parent.path;
  }
  return null;
}

String? _parseConfigPathArg(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--config=')) {
      final value = arg.substring('--config='.length).trim();
      return value.isEmpty ? null : value;
    }
    if (arg == '--config' && i + 1 < args.length) {
      final value = args[i + 1].trim();
      return value.isEmpty ? null : value;
    }
  }
  return null;
}

Future<void> _initializeApplication() async {
  AppStartupTrace.log('initializeApplication.start');
  AppStartupTrace.log('App.init.start');
  await App.init();
  AppStartupTrace.log('App.init.done');

  await appdata.readEssentialData();
  ArchiveRegistry.initDefaults();
  if (_shouldLoadTranslationsBeforeRunApp()) {
    await loadTranslations();
  } else {
    AppStartupTrace.log('loadTranslations.deferred');
  }

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

bool _shouldLoadTranslationsBeforeRunApp() {
  final language = appdata.settings[50];
  return language == 'en' || language == 'tw';
}

Future<void> _runDeferredStartupLoads() async {
  await appdata.readDeferredData();
  if (!_shouldLoadTranslationsBeforeRunApp()) {
    await loadTranslations();
  }
}

Future<void> _runDeferredStartupWork() async {
  unawaited(_runDeferredStartupLoads());
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
  DateTime? _lastBackgroundedAt;
  bool _deferredStartupQueued = false;
  ColorScheme? _lightDynamicScheme;
  ColorScheme? _darkDynamicScheme;
  int _dynamicColorRequestVersion = 0;
  int _dynamicColorAppliedVersion = 0;
  DateTime? _lastDynamicColorRefreshAt;
  Timer? _dynamicColorRefreshDebounce;

  @override
  void initState() {
    super.initState();
    AppStartupTrace.log('PicaKeepApp.initState');
    WidgetsBinding.instance.addObserver(this);
    App.updater = _refreshApp;
    App.serviceConfigVersion.addListener(_handleServiceStateSyncRequest);
    App.serviceRuntimeVersion.addListener(_handleServiceStateSyncRequest);
    RemoteLibraryEventChannel.instance.start();
    DynamicThemeChannel.instance.changes.listen((_) {
      _handleDynamicThemeChanged();
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!App.isMobile) {
      HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
    }
    if (appdata.settings[12] == '1') {
      blockScreenshot();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppStartupTrace.log('PicaKeepApp.firstPostFrame');
    });
    _scheduleInitialDynamicColorsLoad();
    _scheduleDeferredStartupWork();
  }

  @override
  void dispose() {
    _dynamicColorRefreshDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (!App.isMobile) {
      HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    }
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

  bool get _usesDynamicTheme => App.isAndroid && appdata.settings[27] == '0';

  void _scheduleInitialDynamicColorsLoad() {
    if (!_usesDynamicTheme) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refreshDynamicColors(force: true));
    });
  }

  bool _shouldThrottleDynamicColorRefresh({required bool force}) {
    if (force) {
      return false;
    }
    final lastRefreshAt = _lastDynamicColorRefreshAt;
    if (lastRefreshAt == null) {
      return false;
    }
    return DateTime.now().difference(lastRefreshAt) <
        const Duration(milliseconds: 600);
  }

  Future<void> _refreshDynamicColors({bool force = false}) async {
    if (!_usesDynamicTheme ||
        _shouldThrottleDynamicColorRefresh(force: force)) {
      return;
    }
    final requestVersion = ++_dynamicColorRequestVersion;
    _lastDynamicColorRefreshAt = DateTime.now();
    AppStartupTrace.log('dynamicColors.start');
    try {
      final corePalette = await DynamicColorPlugin.getCorePalette();
      if (!mounted) {
        return;
      }
      if (requestVersion < _dynamicColorAppliedVersion) {
        return;
      }
      if (corePalette == null) {
        AppStartupTrace.log('dynamicColors.unavailable');
        return;
      }
      final lightScheme = corePalette.toColorScheme();
      final darkScheme = corePalette.toColorScheme(brightness: Brightness.dark);
      if (!mounted || requestVersion < _dynamicColorAppliedVersion) {
        return;
      }
      setState(() {
        _dynamicColorAppliedVersion = requestVersion;
        _lightDynamicScheme = lightScheme;
        _darkDynamicScheme = darkScheme;
      });
      AppStartupTrace.log('dynamicColors.done');
    } catch (e) {
      AppStartupTrace.log('dynamicColors.failed: $e');
    }
  }

  /// Coalesce bursty refresh triggers (config changes, wallpaper recolor,
  /// resume, brightness flips) into a single deferred refresh.
  ///
  /// Returning to the app after changing the wallpaper makes Android — MIUI
  /// especially — emit a rapid burst of onConfigurationChanged callbacks. If
  /// every one forced an immediate refresh we'd run getCorePalette() + two
  /// HCT toColorScheme() quantizations + a full MaterialApp rebuild dozens of
  /// times on the main isolate within a frame or two, which is exactly the
  /// ANR shown when the wallpaper changes. Debouncing lets the burst settle
  /// and then refreshes once.
  void _scheduleDynamicColorRefresh() {
    if (!_usesDynamicTheme) {
      return;
    }
    _dynamicColorRefreshDebounce?.cancel();
    _dynamicColorRefreshDebounce = Timer(
      const Duration(milliseconds: 350),
      () {
        if (!mounted) {
          return;
        }
        unawaited(_refreshDynamicColors(force: true));
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      RemoteLibraryEventChannel.instance.onBackground();
      _requireAuthOnResume = appdata.settings[13] == '1';
      _lastBackgroundedAt = DateTime.now();
      return;
    }

    if (state == AppLifecycleState.resumed) {
      RemoteLibraryEventChannel.instance.onForeground();
      _scheduleDynamicColorRefresh();
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

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    if (_usesDynamicTheme && _getThemeMode() == ThemeMode.system) {
      _scheduleDynamicColorRefresh();
    }
  }

  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    final focusContext = FocusManager.instance.primaryFocus?.context;
    unawaited(App.maybePopActiveRoute(context: focusContext));
    return true;
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

  void _handleDynamicThemeChanged() {
    _scheduleDynamicColorRefresh();
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
        final framedChild = App.isDesktop
            ? WindowFrame(child: child)
            : _MobileSystemUiFrame(child: child);
        return framedChild;
      },
      theme: ThemeData(
        colorScheme: _buildLightScheme(_lightDynamicScheme),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: _getPureBlack(_buildDarkScheme(_darkDynamicScheme)),
        scaffoldBackgroundColor:
            appdata.settings[84] == '1' && _getThemeMode() == ThemeMode.dark
                ? Colors.black
                : null,
        useMaterial3: true,
      ),
      themeMode: _getThemeMode(),
      home: appdata.settings[13] == '1' ? const AuthPage() : const MainPage(),
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
