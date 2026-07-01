// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'package:flutter/services.dart';

const _pathCN = "assets/tags.json";
const _pathTW = "assets/tags_tw.json";

Map<String, Map<String, String>> _tagTranslations = {};
Map<String, Map<String, String>> _tagTranslationsTW = {};

Future<void> loadTagTranslations() async {
  if (_tagTranslations.isNotEmpty) return;
  _tagTranslations = await _loadTagTranslationFile(_pathCN);
}

Future<void> loadTagTranslationsTW() async {
  if (_tagTranslationsTW.isNotEmpty) return;
  _tagTranslationsTW = await _loadTagTranslationFile(_pathTW);
}

Future<Map<String, Map<String, String>>> _loadTagTranslationFile(
    String path) async {
  final data = jsonDecode(await rootBundle.loadString(path));
  final result = <String, Map<String, String>>{};
  if (data is! Map) return result;
  for (final categoryEntry in data.entries) {
    final category = categoryEntry.key.toString();
    final values = categoryEntry.value;
    if (values is! Map) continue;
    result[category] = {
      for (final tagEntry in values.entries)
        tagEntry.key.toString().toLowerCase(): tagEntry.value.toString(),
    };
  }
  return result;
}

Map<String, Map<String, String>> get tagTranslations => _tagTranslations;

Map<String, Map<String, String>> get tagTranslationsTW => _tagTranslationsTW;

// ─────────────────────────────────────────────────────────────────────────────
//  翻译辅助函数
// ─────────────────────────────────────────────────────────────────────────────

/// namespace 名 → 中文分类标题。
/// 用于详情页标签区分类 chip 显示，例如 "female" → "女性"。
/// 若 [namespace] 不在映射表中则原样返回（如 JM/Picacg 的中文key "作者" 等）。
String tagTranslateCategory(String namespace) =>
    _tagCategoryZh[namespace.toLowerCase()] ?? namespace;

/// 按 namespace 查具体标签的中文译名。
/// 例如 tagTranslateWithNs("witch", "female") → "女巫装"。
/// 若找不到则全表兜底（nhentai "Tags" 类别无固定 namespace，需跨表查）。
String tagTranslateWithNs(String key, String namespace) {
  final lowerKey = key.toLowerCase();
  final lowerNs = namespace.toLowerCase();

  // 单数 namespace 映射（nhentai 返回复数，转单数再查）
  const plural2Ns = <String, String>{
    'parodies': 'parody',
    'characters': 'character',
    'artists': 'artist',
    'groups': 'group',
    'languages': 'language',
    'categories': 'reclass',
  };
  final resolvedNs = plural2Ns[lowerNs] ?? lowerNs;

  // 优先命中本 namespace
  final cn = _tagTranslations[resolvedNs]?[lowerKey];
  if (cn != null && cn.isNotEmpty) return cn;

  // 兜底：遍历全表（nhentai "Tags" 类别内含 female/male/mixed 等多 namespace 标签）
  for (final ns in _tagTranslations.values) {
    final fallback = ns[lowerKey];
    if (fallback != null && fallback.isNotEmpty) return fallback;
  }
  return key;
}

/// 输入中文分类名（如“作者/画师/标签/女性”）时，返回对应 namespace 列表。
/// 搜索建议用它把“作者”映射到 artist/group/cosplayer 等 namespace。
List<String> tagNamespacesForChineseCategory(String input) {
  final text = input.trim();
  if (text.isEmpty) return const [];
  final exact = <String>[];
  final partial = <String>[];
  for (final entry in _tagCategoryZh.entries) {
    final ns = entry.key;
    final cn = entry.value;
    if (cn == text || ns == text.toLowerCase()) {
      exact.add(ns);
    } else if (cn.contains(text) || text.contains(cn)) {
      partial.add(ns);
    }
  }
  return {...exact, ...partial}.toList(growable: false);
}

const _tagCategoryZh = <String, String>{
  // 单数（ehentai / 通用）
  'language': '语言',
  'artist': '画师',
  'male': '男性',
  'female': '女性',
  'mixed': '混合',
  'other': '其它',
  'parody': '原作',
  'character': '角色',
  'group': '团队',
  'cosplayer': 'Coser',
  'reclass': '重新分类',
  'rows': '分类',
  'tag': '标签',
  'tags': '标签',
  'series': '原作',
  'category': '分类',
  'categories': '分类',
  // nhentai 特有字段
  'pages': '页数',
  'page': '页数',
  // nhentai HTML 返回的首字母大写复数形式
  'parodies': '原作',
  'characters': '角色',
  'artists': '画师',
  'groups': '团队',
  'languages': '语言',
  // 自然中文输入映射
  'author': '作者',
  'uploader': '上传者',
};
