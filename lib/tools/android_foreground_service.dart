import 'package:flutter/services.dart';
import 'package:picakeep/foundation/app.dart';

class AndroidForegroundServiceSupportState {
  const AndroidForegroundServiceSupportState({
    required this.notificationsGranted,
    required this.ignoringBatteryOptimizations,
  });

  final bool notificationsGranted;
  final bool ignoringBatteryOptimizations;
}

class AndroidForegroundServiceController {
  AndroidForegroundServiceController._();

  static final AndroidForegroundServiceController instance =
      AndroidForegroundServiceController._();

  static const MethodChannel _channel =
      MethodChannel('lingxue.picakeep/foreground_service');

  Future<void> startOrUpdate({
    required String title,
    required String content,
    String? statusText,
    int? port,
    String? adminUrl,
  }) async {
    if (!App.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('start', {
        'title': title,
        'content': content,
        'statusText': statusText,
        'port': port,
        'adminUrl': adminUrl,
      });
    } catch (_) {}
  }

  Future<void> stop() async {
    if (!App.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  Future<bool> requestNotificationPermission() async {
    if (!App.isAndroid) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'requestNotificationPermission',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> areNotificationsGranted() async {
    if (!App.isAndroid) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>('areNotificationsEnabled') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!App.isAndroid) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openNotificationSettings() async {
    if (!App.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('openNotificationSettings');
    } catch (_) {}
  }

  Future<void> openBatteryOptimizationSettings() async {
    if (!App.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('openBatteryOptimizationSettings');
    } catch (_) {}
  }

  Future<AndroidForegroundServiceSupportState> readSupportState() async {
    return AndroidForegroundServiceSupportState(
      notificationsGranted: await areNotificationsGranted(),
      ignoringBatteryOptimizations: await isIgnoringBatteryOptimizations(),
    );
  }
}
