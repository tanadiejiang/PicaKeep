import 'dart:io';

import 'package:flutter/services.dart';

class AndroidMulticastLock {
  AndroidMulticastLock._();

  static final AndroidMulticastLock instance = AndroidMulticastLock._();

  static const MethodChannel _channel =
      MethodChannel('lingxue.picakeep/multicast_lock');

  Future<void> acquire() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('acquire');
    } catch (_) {}
  }

  Future<void> release() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('release');
    } catch (_) {}
  }
}