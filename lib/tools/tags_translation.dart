// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'package:flutter/services.dart';

const _pathCN = "assets/tags.json";
const _pathTW = "assets/tags_tw.json";

Map<String, Map<String, String>> _tagTranslations = {};
Map<String, Map<String, String>> _tagTranslationsTW = {};
TagTranslationLoadState _tagTranslationLoadState =
    TagTranslationLoadState.notLoaded;
Future<void>? _tagTranslationLoadFuture;

enum TagTranslationLoadState { notLoaded, loading, ready, failed }

class TagTranslationLookupResult {
  const TagTranslationLookupResult({
    required this.displayText,
    required this.found,
    required this.normalizedNamespace,
    required this.normalizedRawTag,
    required this.matchedNamespace,
    required this.translationReady,
  });

  final String displayText;
  final bool found;
  final String normalizedNamespace;
  final String normalizedRawTag;
  final String matchedNamespace;
  final bool translationReady;

  bool get missing => translationReady && !found;
  bool get translated => found;
}

Future<void> loadTagTranslations() {
  if (_tagTranslationLoadState == TagTranslationLoadState.ready) {
    return Future<void>.value();
  }
  final pending = _tagTranslationLoadFuture;
  if (pending != null) {
    return pending;
  }
  final future = _loadTagTranslationsInternal();
  _tagTranslationLoadFuture = future;
  return future.whenComplete(() {
    if (identical(_tagTranslationLoadFuture, future)) {
      _tagTranslationLoadFuture = null;
    }
  });
}

Future<void> _loadTagTranslationsInternal() async {
  _tagTranslationLoadState = TagTranslationLoadState.loading;
  try {
    _tagTranslations = await _loadTagTranslationFile(_pathCN);
    _tagTranslationLoadState = TagTranslationLoadState.ready;
  } catch (_) {
    _tagTranslations = {};
    _tagTranslationLoadState = TagTranslationLoadState.failed;
    rethrow;
  }
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

TagTranslationLoadState get tagTranslationLoadState => _tagTranslationLoadState;

bool get tagTranslationsReady =>
    _tagTranslationLoadState == TagTranslationLoadState.ready;

String normalizeTagNamespace(String namespace) {
  final lower = namespace.trim().toLowerCase();
  const plural2Ns = <String, String>{
    'parodies': 'parody',
    'characters': 'character',
    'artists': 'artist',
    'groups': 'group',
    'languages': 'language',
    'categories': 'reclass',
  };
  return plural2Ns[lower] ?? (lower.isEmpty ? 'tags' : lower);
}

String normalizeTagValue(String value) => value.trim().toLowerCase();

TagTranslationLookupResult lookupTagTranslation(String key, String namespace) {
  return lookupTagTranslationInTables(
    key,
    namespace,
    translations: _tagTranslations,
    translationReady: tagTranslationsReady,
  );
}

TagTranslationLookupResult lookupTagTranslationInTables(
  String key,
  String namespace, {
  required Map<String, Map<String, String>> translations,
  bool translationReady = true,
}) {
  final rawKey = key.trim();
  final normalizedRawTag = normalizeTagValue(rawKey);
  final normalizedNamespace = normalizeTagNamespace(namespace);

  String? lookupInNamespace(String ns) {
    for (final entry in translations.entries) {
      if (normalizeTagNamespace(entry.key) != ns) {
        continue;
      }
      final value = entry.value[normalizedRawTag];
      if (value != null && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }

  String? translated = lookupInNamespace(normalizedNamespace);
  var matchedNamespace = translated == null ? '' : normalizedNamespace;
  if (translated == null) {
    for (final entry in translations.entries) {
      final value = entry.value[normalizedRawTag];
      if (value != null && value.trim().isNotEmpty) {
        translated = value.trim();
        matchedNamespace = normalizeTagNamespace(entry.key);
        break;
      }
    }
  }
  return TagTranslationLookupResult(
    displayText: translated ?? rawKey,
    found: translated != null,
    normalizedNamespace: normalizedNamespace,
    normalizedRawTag: normalizedRawTag,
    matchedNamespace: matchedNamespace,
    translationReady: translationReady,
  );
}

/// Test-only injection keeps lookup tests independent from Flutter asset loading.
void setTagTranslationsForTesting(
  Map<String, Map<String, String>> value, {
  bool ready = true,
}) {
  _tagTranslations = {
    for (final entry in value.entries)
      entry.key: {
        for (final tag in entry.value.entries)
          tag.key.trim().toLowerCase(): tag.value,
      },
  };
  _tagTranslationLoadState =
      ready ? TagTranslationLoadState.ready : TagTranslationLoadState.notLoaded;
}

void resetTagTranslationsForTesting() {
  _tagTranslations = {};
  _tagTranslationLoadState = TagTranslationLoadState.notLoaded;
  _tagTranslationLoadFuture = null;
}

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
  return lookupTagTranslation(key, namespace).displayText;
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

/// 本地 tag 的跨语言别名集合（不含自身；冒号前缀先剥离）。
/// 正向：英文 key → 中文译名；反向：中文译名 → 英文 key。
/// eh 的 "namespace:tag" 会额外产出纯 tag 别名。
List<String> tagAliasesForTag(String tag) {
  final t = tag.trim().toLowerCase();
  if (t.isEmpty) return const [];
  final postColon = t.contains(':') ? t.split(':').last.trim() : '';
  final aliases = <String>{};
  if (postColon.isNotEmpty && postColon != t) aliases.add(postColon);
  for (final table in _tagTranslations.entries) {
    for (final entry in table.value.entries) {
      if (entry.key == t || (postColon.isNotEmpty && entry.key == postColon)) {
        aliases.add(entry.value.trim());
      } else {
        final v = entry.value.toLowerCase();
        if (v.contains(t) || (postColon.isNotEmpty && v.contains(postColon))) {
          aliases.add(entry.key);
        }
      }
    }
  }
  return aliases.toList(growable: false);
}
