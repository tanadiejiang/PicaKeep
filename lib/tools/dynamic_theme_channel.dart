import 'dart:async';

import 'package:flutter/services.dart';
import 'package:picakeep/foundation/app.dart';

class DynamicThemeChannel {
  DynamicThemeChannel._() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static final DynamicThemeChannel instance = DynamicThemeChannel._();

  static const MethodChannel _channel =
      MethodChannel('lingxue.picakeep/dynamic_theme');

  final StreamController<void> _changesController =
      StreamController<void>.broadcast();

  Stream<void> get changes => _changesController.stream;

  Future<void> _handleMethodCall(MethodCall call) async {
    if (!App.isAndroid) {
      return;
    }
    if (call.method == 'changed') {
      _changesController.add(null);
    }
  }
}
