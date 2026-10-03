import 'dart:async';

import 'package:flutter/material.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/pages/auth_page.dart';
import 'package:picakeep/pages/download_page.dart';
import 'package:picakeep/pages/downloading/downloading_page.dart';
import 'download_notification_controller.dart';

/// Native intents are consumed only after the main navigator and unlock gate
/// are ready. AuthPage calls [tryOpen] again after a successful unlock.
class DownloadNotificationRoutes {
  DownloadNotificationRoutes._();
  static final instance = DownloadNotificationRoutes._();
  bool _initialized = false;
  Route<void>? _lastRoute;
  Timer? _navigationRetry;

  void initialize() {
    if (_initialized || !App.isAndroid) return;
    _initialized = true;
    DownloadNotificationController.instance.routeVersion.addListener(tryOpen);
    unawaited(DownloadNotificationController.instance.pullRoute());
  }

  void tryOpen() {
    if (!App.isAndroid) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = App.mainNavigatorKey?.currentState;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      final ready = navigator != null &&
          !AuthPage.lock &&
          !App.isNavigationLocked &&
          (lifecycle == null || lifecycle == AppLifecycleState.resumed);
      if (!ready &&
          !AuthPage.lock &&
          navigator != null &&
          DownloadNotificationController.instance.hasPendingRoute &&
          (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
        _navigationRetry?.cancel();
        _navigationRetry = Timer(const Duration(milliseconds: 300), tryOpen);
      }
      final target =
          DownloadNotificationController.instance.takeRoute(ready: ready);
      if (target == null || navigator == null) return;
      _navigationRetry?.cancel();
      _navigationRetry = null;
      final name = 'picakeep.download.$target';
      if (_lastRoute?.isCurrent == true && _lastRoute?.settings.name == name) {
        return;
      }
      final route = AppPageRoute<void>(
        settings: RouteSettings(name: name),
        builder: (_) => target == 'queue'
            ? const DownloadingPage()
            : const DownloadPage(forceLocal: true),
      );
      _lastRoute = route;
      unawaited(navigator.push<void>(route));
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void foregrounded() {
    initialize();
    unawaited(DownloadNotificationController.instance
        .foregrounded()
        .then((_) => tryOpen()));
  }
}
