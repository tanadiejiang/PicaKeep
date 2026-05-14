import 'package:flutter/services.dart';
import 'package:picakeep/foundation/app.dart';

Future<void> blockScreenshot() async {
  if (!App.isAndroid) return;
  try {
    await const MethodChannel('lingxue.picakee/screenshot')
        .invokeMethod('set');
  } catch (_) {}
}
