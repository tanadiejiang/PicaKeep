import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:picakeep/base.dart';

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
    translations['en_US'] = {};
  }
}

extension AppTranslation on String {
  String get tl {
    String targetKey;
    switch (appdata.settings[50]) {
      case 'en':
        targetKey = 'en_US';
        break;
      case 'tw':
        targetKey = 'zh_TW';
        break;
      default:
        targetKey = 'zh_CN';
    }

    if (targetKey == 'zh_CN') return this;

    return translations[targetKey]?[this] ?? this;
  }

  String get tlEN => translations['en_US']?[this] ?? this;

  String tlParams(Map<String, String> values) {
    var res = tl;
    for (var entry in values.entries) {
      res = res.replaceFirst('@${entry.key}', entry.value);
    }
    return res;
  }
}
