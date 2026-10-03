import 'dart:developer';

import 'package:flutter/foundation.dart';

/// Opt-in profile timeline events. Never logs file paths or writes trace files.
class IllustCoverDiagnostics {
  static const enabled =
      kProfileMode && bool.fromEnvironment('PIKAKEEP_COVER_DIAGNOSTICS');

  static void event(String name, {Map<String, Object>? arguments}) {
    if (enabled) {
      Timeline.instantSync('IllustCover.$name', arguments: arguments);
    }
  }

  static Future<T> measure<T>(String stage, Future<T> Function() action) async {
    if (!enabled) return action();
    final task = TimelineTask()..start('IllustCover.$stage');
    try {
      return await action();
    } finally {
      task.finish();
    }
  }
}
