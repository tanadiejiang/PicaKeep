import 'package:flutter/services.dart';
import 'package:picakeep/foundation/app.dart';

/// Bridges the in-app dark-mode setting (settings[32]) to Android's
/// per-app night mode (UiModeManager.setApplicationNightMode, API 31+).
///
/// Why: the system splash screen on Android 12+ is drawn by system_server
/// before our process starts, so it picks the launch theme using the system
/// uiMode unless we have previously told the system our per-app preference.
/// Calling [setMode] every time the user changes the setting keeps that
/// preference in sync, so the next cold start renders the splash with the
/// right theme variant (drawable / drawable-night, values / values-night).
///
/// Values mirror settings[32]:
/// - "0" follow system
/// - "1" force light
/// - "2" force dark
class NightModeChannel {
  NightModeChannel._();

  static final NightModeChannel instance = NightModeChannel._();

  static const MethodChannel _channel =
      MethodChannel('lingxue.picakeep/night_mode');

  Future<void> setMode(String mode) async {
    if (!App.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setMode', {'mode': mode});
    } catch (_) {
      // Best-effort: swallow errors so settings UI never blocks on this.
    }
  }
}
