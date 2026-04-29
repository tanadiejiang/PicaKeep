// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'package:flutter/services.dart';

const _pathCN = "assets/tags.json";
const _pathTW = "assets/tags_tw.json";

Map<String, Map<String, List<String>>> _tagTranslations = {};
Map<String, Map<String, List<String>>> _tagTranslationsTW = {};

Future<void> loadTagTranslations() async {
  if (_tagTranslations.isEmpty) {
    var data = jsonDecode(await rootBundle.loadString(_pathCN));
    for (var category in data.keys) {
      _tagTranslations[category.toString()] = {};
      for (var tag in data[category]) {
        _tagTranslations[category.toString()]![tag['original']] = [
          tag['translation'],
          tag['description'] ?? '',
        ];
      }
    }
  }
}

Future<void> loadTagTranslationsTW() async {
  if (_tagTranslationsTW.isEmpty) {
    var data = jsonDecode(await rootBundle.loadString(_pathTW));
    for (var category in data.keys) {
      _tagTranslationsTW[category.toString()] = {};
      for (var tag in data[category]) {
        _tagTranslationsTW[category.toString()]![tag['original']] = [
          tag['translation'],
          tag['description'] ?? '',
        ];
      }
    }
  }
}

Map<String, Map<String, List<String>>> get tagTranslations => _tagTranslations;

Map<String, Map<String, List<String>>> get tagTranslationsTW =>
    _tagTranslationsTW;
