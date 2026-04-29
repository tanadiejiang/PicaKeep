import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

Map<String, Map<String, String>> translations = {};
bool _loaded = false;

Future<void> loadTranslations() async {
  if (_loaded) return;
  _loaded = true;
  try {
    final jsonStr = await rootBundle.loadString('assets/translation.json');
    final data = json.decode(jsonStr) as Map<String, dynamic>;
    for (var entry in data.entries) {
      translations[entry.key] = Map<String, String>.from(entry.value);
    }
  } catch (_) {
    translations['zh_CN'] = {};
  }
}

extension AppTranslation on String {
  String get tl => this;

  String get tlEN => this;

  String tlParams(Map<String, String> values) {
    return this;
  }
}
