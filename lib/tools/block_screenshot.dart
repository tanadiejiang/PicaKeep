import 'package:flutter/services.dart';
import 'package:picakeep/foundation/app.dart';

Future<void> blockScreenshot() async {
  if (!App.isAndroid) return;
  try {
    await const MethodChannel('com.github.pacalini.pica_comic/screenshot')
        .invokeMethod('set');
  } catch (_) {}
}