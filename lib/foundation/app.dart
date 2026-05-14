import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:path_provider/path_provider.dart';
import 'app_page_route.dart';
import 'log.dart';
import 'state_controller.dart';
import '../base.dart';

export 'state_controller.dart';
export 'widget_utils.dart';

class AppStartupTrace {
  static final Stopwatch _stopwatch = Stopwatch()..start();

  static int get elapsedMs => _stopwatch.elapsedMilliseconds;

  static void log(String stage) {
    debugPrint('[PicaKeep][startup][${_stopwatch.elapsedMilliseconds}ms] $stage');
  }
}

class App {
  static bool get isAndroid => Platform.isAndroid;
  static bool get isIOS => Platform.isIOS;
  static bool get isWindows => Platform.isWindows;
  static bool get isLinux => Platform.isLinux;
  static bool get isMacOS => Platform.isMacOS;
  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  static BuildContext? get globalContext => navigatorKey.currentContext;

  static final navigatorKey = GlobalKey<NavigatorState>();

  static GlobalKey<NavigatorState>? mainNavigatorKey;

  static VoidCallback? updater;

  static final ValueNotifier<int> localDataVersion = ValueNotifier(0);

  static final ValueNotifier<int> serviceConfigVersion = ValueNotifier(0);

  static final ValueNotifier<int> serviceRuntimeVersion = ValueNotifier(0);

  static void notifyLocalDataChanged() {
    localDataVersion.value++;
    updater?.call();
    Future.microtask(
      () => StateController.findOrNull<SimpleController>(tag: 'me_page')
          ?.update(),
    );
  }

  static void notifyServiceConfigChanged() {
    serviceConfigVersion.value++;
    updater?.call();
  }

  static void notifyServiceRuntimeChanged() {
    serviceRuntimeVersion.value++;
  }

  static UiModes uiMode([BuildContext? context]) {
    context ??= globalContext;
    if (MediaQuery.of(context!).size.shortestSide < 600) {
      return UiModes.m1;
    } else if (!(MediaQuery.of(context).size.shortestSide < 600) &&
        !(MediaQuery.of(context).size.width > 1400)) {
      return UiModes.m2;
    } else {
      return UiModes.m3;
    }
  }

  static late final String cachePath;

  static late final String dataPath;

  static Future<void> init() async {
    cachePath = (await getApplicationCacheDirectory()).path;
    dataPath = (await getApplicationSupportDirectory()).path;
  }

  static back(BuildContext context) {
    if (Navigator.canPop(context)) {
      Navigator.of(context).pop();
    }
  }

  static globalBack() {
    if (Navigator.canPop(globalContext!)) {
      Navigator.of(globalContext!).pop();
    }
  }

  static off(BuildContext context, Widget Function() page) {
    LogManager.addLog(LogLevel.info, "App Status",
        "Going to Page /${page.runtimeType.toString().replaceFirst("() => ", "")}");
    Navigator.of(context)
        .pushReplacement(AppPageRoute(builder: (context) => page()));
  }

  static globalOff(Widget Function() page) {
    LogManager.addLog(LogLevel.info, "App Status",
        "Going to Page /${page.runtimeType.toString().replaceFirst("() => ", "")}");
    Navigator.of(globalContext!)
        .pushReplacement(AppPageRoute(builder: (context) => page()));
  }

  static offAll(Widget Function() page) {
    Navigator.of(globalContext!).pushAndRemoveUntil(
        AppPageRoute(builder: (context) => page()), (route) => false);
  }

  static Future<T?> to<T extends Object?>(
      BuildContext context, Widget Function() page,
      [bool enableIOSGesture = true]) {
    LogManager.addLog(LogLevel.info, "App Status",
        "Going to Page /${page.runtimeType.toString().replaceFirst("() => ", "")}");
    return Navigator.of(context)
        .push<T>(AppPageRoute(builder: (context) => page()));
  }

  static Future<T?> globalTo<T extends Object?>(Widget Function() page,
      {bool preventDuplicates = false}) {
    return Navigator.of(globalContext!)
        .push<T>(AppPageRoute(builder: (context) => page()));
  }

  /// Full-screen reader on the root stack (matches PicaComic); ensures [globalBack] closes the reader.
  static Future<T?> openReader<T extends Object?>(Widget Function() page) =>
      globalTo<T>(page);

  /// Prefer the tab [Navigator] when present (matches PicaComic main stack).
  static BuildContext get innerOrGlobalContext =>
      mainNavigatorKey?.currentContext ?? globalContext!;

  static Future<T?> pushInner<T extends Object?>(Widget Function() page) {
    return Navigator.of(innerOrGlobalContext)
        .push<T>(AppPageRoute(builder: (context) => page()));
  }

  static bool get enablePopGesture => isMobile;

  static String? _currentRoute() {
    return ModalRoute.of(globalContext!)?.toString();
  }

  static String? get currentRoute => _currentRoute();

  static bool get canPop => Navigator.of(globalContext!).canPop();

  static bool temporaryDisablePopGesture = false;

  static int _navigationLockDepth = 0;

  static bool get isNavigationLocked => _navigationLockDepth > 0;

  static void beginNavigationLock() {
    _navigationLockDepth++;
  }

  static void endNavigationLock() {
    if (_navigationLockDepth > 0) {
      _navigationLockDepth--;
    }
  }

  static Future<void> applyDisplayModePreference() async {
    if (!isAndroid) {
      return;
    }
    try {
      if (appdata.settings[38] == "1") {
        await FlutterDisplayMode.setHighRefreshRate();
      } else {
        await FlutterDisplayMode.setLowRefreshRate();
      }
    } catch (_) {}
  }

  static Locale get locale {
    Locale deviceLocale = PlatformDispatcher.instance.locale;
    if (deviceLocale.languageCode == "zh" &&
        deviceLocale.scriptCode == "Hant") {
      deviceLocale = const Locale("zh", "TW");
    }
    return switch (appdata.settings[50]) {
      "cn" => const Locale("zh", "CN"),
      "tw" => const Locale("zh", "TW"),
      "en" => const Locale("en", "US"),
      _ => deviceLocale,
    };
  }

  static Size screenSize(BuildContext context) => MediaQuery.of(context).size;

  static ColorScheme colors(BuildContext context) =>
      Theme.of(context).colorScheme;
}

enum UiModes { m1, m2, m3 }
