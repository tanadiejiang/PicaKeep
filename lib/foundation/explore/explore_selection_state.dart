/// Persisted selection state for the Explore page.
///
/// This file deliberately stays independent from Flutter and network code so
/// malformed settings can be normalized in plain Dart tests and at startup.
library;

import 'dart:convert';

import 'explore_models.dart';

const int exploreSelectionSettingIndex = 164;

const String exploreSelectionKindRecommend = 'recommend';
const String exploreSelectionKindRanking = 'ranking';

class ExploreSelectionState {
  const ExploreSelectionState({
    required this.kind,
    required this.entryId,
    required this.rankingOption,
  });

  final String kind;
  final String entryId;
  final String rankingOption;

  Map<String, String> toJson() => <String, String>{
        'kind': kind,
        'entry': entryId,
        'rankingOption': rankingOption,
      };
}

/// Canonicalize the persisted envelope without depending on a source registry.
/// Source-specific validity is checked later against the live descriptor.
String normalizeExploreSelectionJson(String? raw) {
  final decoded = _decodeMap(raw);
  final sourceValues = decoded['bySource'];
  final bySource = <String, dynamic>{};
  if (sourceValues is Map) {
    for (final entry in sourceValues.entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      final value = entry.value as Map;
      final clean = <String, String>{};
      for (final key in const ['kind', 'entry', 'rankingOption']) {
        final item = value[key];
        if (item is String && item.isNotEmpty) clean[key] = item;
      }
      if (clean.isNotEmpty) bySource[entry.key] = clean;
    }
  }
  return jsonEncode(<String, dynamic>{
    'version': 1,
    'bySource': bySource,
  });
}

ExploreSelectionState selectionForDescriptor({
  required String sourceKey,
  required ExploreSourceDescriptor descriptor,
  required String? raw,
}) {
  final decoded = _decodeMap(raw);
  final bySource = decoded['bySource'];
  final source = bySource is Map ? bySource[sourceKey] : null;
  final saved = source is Map ? source : const <String, dynamic>{};

  final recommend = descriptor
      .entriesOf(ExploreSectionKind.recommend)
      .where((entry) => entry.availableAsTab)
      .toList(growable: false);
  final ranking = descriptor.entriesOf(ExploreSectionKind.ranking).firstOrNull;
  final savedKind = saved['kind'];
  final kind = savedKind == exploreSelectionKindRanking && ranking != null
      ? exploreSelectionKindRanking
      : exploreSelectionKindRecommend;

  final savedEntry = saved['entry'];
  final entry = kind == exploreSelectionKindRecommend
      ? recommend
              .where((candidate) => candidate.id == savedEntry)
              .firstOrNull
              ?.id ??
          recommend.firstOrNull?.id ??
          ''
      : ranking?.id ?? '';

  final savedOption = saved['rankingOption'];
  final rankingOption = ranking == null
      ? ''
      : ranking.options
              .where((option) => option.id == savedOption)
              .firstOrNull
              ?.id ??
          ranking.defaultOptionIdOrFirst ??
          '';

  return ExploreSelectionState(
    kind: kind,
    entryId: entry,
    rankingOption: rankingOption,
  );
}

String updateExploreSelectionJson({
  required String? raw,
  required String sourceKey,
  required ExploreSelectionState state,
}) {
  final normalized = _decodeMap(normalizeExploreSelectionJson(raw));
  final bySource = <String, dynamic>{};
  final existing = normalized['bySource'];
  if (existing is Map) {
    for (final entry in existing.entries) {
      if (entry.key is String && entry.value is Map) {
        bySource[entry.key] = Map<String, String>.from(entry.value as Map);
      }
    }
  }
  bySource[sourceKey] = state.toJson();
  return jsonEncode(<String, dynamic>{
    'version': 1,
    'bySource': bySource,
  });
}

Map<String, dynamic> _decodeMap(String? raw) {
  if (raw == null || raw.trim().isEmpty) return <String, dynamic>{};
  try {
    final value = jsonDecode(raw);
    if (value is Map) return Map<String, dynamic>.from(value);
  } catch (_) {
    // Invalid settings are intentionally treated as an empty envelope.
  }
  return <String, dynamic>{};
}
