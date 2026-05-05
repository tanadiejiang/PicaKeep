import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';

import 'local_server_runtime.dart';

bool canManageDesktopLocalServerRuntime() {
  return currentServerPlatformCapability().isFullServerTarget;
}

Future<void> syncDesktopLocalServerRuntimeForCurrentMode({
  bool restartIfRunning = false,
}) async {
  if (!canManageDesktopLocalServerRuntime()) {
    return;
  }

  final mode = normalizeAppRuntimeMode(
    appdata.settings[appRuntimeModeSettingIndex],
  );
  final runtime = LocalServerRuntime.instance;

  if (mode == appRuntimeModeServer) {
    if (restartIfRunning && runtime.isRunning) {
      await runtime.restart();
      return;
    }
    if (!runtime.isRunning) {
      await runtime.start();
    }
    return;
  }

  if (runtime.isRunning) {
    await runtime.stop();
  }
}
