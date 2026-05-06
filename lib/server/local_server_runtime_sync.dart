import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/tools/android_foreground_service.dart';

import 'local_server_runtime.dart';

bool canManageLocalServerRuntime() {
  return currentServerPlatformCapability().supportsServerMode;
}

Future<void> syncLocalServerRuntimeForCurrentMode({
  bool restartIfRunning = false,
}) async {
  if (!canManageLocalServerRuntime()) {
    await AndroidForegroundServiceController.instance.stop();
    return;
  }

  final mode = normalizeAppRuntimeMode(
    appdata.settings[appRuntimeModeSettingIndex],
  );
  final runtime = LocalServerRuntime.instance;

  if (mode == appRuntimeModeServer) {
    if (restartIfRunning && runtime.isRunning) {
      await runtime.restart();
    } else if (!runtime.isRunning) {
      await runtime.start();
    }
    await syncAndroidForegroundServiceForCurrentMode();
    return;
  }

  if (runtime.isRunning) {
    await runtime.stop();
  }
  await syncAndroidForegroundServiceForCurrentMode();
}

Future<void> syncAndroidForegroundServiceForCurrentMode() async {
  if (!currentServerPlatformCapability().isEnhancedServerTarget) {
    return;
  }

  final mode = normalizeAppRuntimeMode(
    appdata.settings[appRuntimeModeSettingIndex],
  );
  if (mode != appRuntimeModeServer) {
    await AndroidForegroundServiceController.instance.stop();
    return;
  }

  final snapshot = await LocalServerRuntime.instance.readSnapshot();
  if (!snapshot.isRunning) {
    await AndroidForegroundServiceController.instance.stop();
    return;
  }

  final detailText = snapshot.detailText.trim();
  await AndroidForegroundServiceController.instance.startOrUpdate(
    title: 'PicaKeep 服务端 · ${snapshot.statusText}',
    content: detailText.isNotEmpty ? detailText : '端口 ${snapshot.port}',
    statusText: snapshot.statusText,
    port: snapshot.port,
    adminUrl: snapshot.adminUrl,
  );
}
