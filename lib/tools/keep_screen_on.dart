import 'package:flutter/services.dart';
import 'package:picakeep/foundation/app.dart';

const MethodChannel _keepScreenOnChannel =
    MethodChannel('lingxue.picakeep/keepScreenOn');

void setKeepScreenOn() async {
  if (!App.isMobile) {
    return;
  }
  try {
    await _keepScreenOnChannel.invokeMethod('set');
  } catch (_) {}
}

void cancelKeepScreenOn() async {
  if (!App.isMobile) {
    return;
  }
  try {
    await _keepScreenOnChannel.invokeMethod('cancel');
  } catch (_) {}
}
