import 'ai_sources.dart';

/// A sanitized description of one item that could not satisfy the strict
/// display-tool contract. It intentionally contains no original values.
class AiResultItemIssue {
  const AiResultItemIssue({
    this.index,
    required this.field,
    required this.expected,
    required this.actualType,
  });

  final int? index;
  final String field;
  final String expected;
  final String actualType;

  Map<String, dynamic> toJson() => {
        if (index != null) 'index': index,
        'field': field,
        'expected': expected,
        'actualType': actualType,
      };
}

/// The single decoding boundary for result-list data from tools and history.
class AiResultItemDecodeReport {
  const AiResultItemDecodeReport({
    required this.items,
    required this.inputCount,
    required this.discardedCount,
    required this.normalizedFields,
    required this.issues,
    this.topLevelIssue,
  });

  final List<AiResultItem> items;
  final int inputCount;
  final int discardedCount;
  final Map<String, int> normalizedFields;
  final List<AiResultItemIssue> issues;
  final AiResultItemIssue? topLevelIssue;

  bool get isValid => topLevelIssue == null && issues.isEmpty;

  Map<String, dynamic> normalizationSummary() => {
        'inputCount': inputCount,
        'discardedCount': discardedCount,
        if (normalizedFields.isNotEmpty)
          'normalizedFields': Map<String, int>.from(normalizedFields),
      };
}

class AiResultItem {
  final String id;
  final String title;
  final String author;
  final String coverUrl;
  final String source;
  final List<String> tags;
  final Map<String, dynamic> availability;

  const AiResultItem({
    required this.id,
    required this.title,
    required this.author,
    required this.coverUrl,
    required this.source,
    required this.tags,
    required this.availability,
  });

  factory AiResultItem.fromJson(Map<String, dynamic> json) {
    return _decodeItem(json, normalizedFields: {}).item;
  }

  /// Decodes old persisted/tool payloads using the history-compatible policy:
  /// malformed fields are repaired independently and only unusable items are
  /// discarded. The strict tool policy is applied by [DisplayResultListTool].
  static AiResultItemDecodeReport decodeToolData(Object? toolData) {
    final normalizedFields = <String, int>{};
    if (toolData is! Map) {
      return AiResultItemDecodeReport(
        items: const [],
        inputCount: 0,
        discardedCount: 0,
        normalizedFields: normalizedFields,
        issues: const [],
        topLevelIssue: AiResultItemIssue(
          field: 'toolData',
          expected: 'object',
          actualType: _typeName(toolData),
        ),
      );
    }

    final itemsValue = toolData['items'];
    if (itemsValue is! List) {
      return AiResultItemDecodeReport(
        items: const [],
        inputCount: 0,
        discardedCount: 0,
        normalizedFields: normalizedFields,
        issues: const [],
        topLevelIssue: AiResultItemIssue(
          field: 'items',
          expected: 'array',
          actualType: _typeName(itemsValue),
        ),
      );
    }

    final decoded = <AiResultItem>[];
    final issues = <AiResultItemIssue>[];
    var discardedCount = 0;

    for (var index = 0; index < itemsValue.length; index++) {
      final raw = itemsValue[index];
      if (raw is! Map) {
        discardedCount++;
        issues.add(
          AiResultItemIssue(
            index: index,
            field: 'item',
            expected: 'object',
            actualType: _typeName(raw),
          ),
        );
        continue;
      }

      final itemResult = _decodeItem(
        _stringKeyedMap(raw),
        normalizedFields: normalizedFields,
      );
      final item = itemResult.item;
      final idMissing = item.id.trim().isEmpty;
      final titleMissing = item.title.trim().isEmpty;
      if (idMissing) {
        issues.add(
          AiResultItemIssue(
            index: index,
            field: 'id',
            expected: 'non-empty string',
            actualType: _typeName(raw['id']),
          ),
        );
      }
      if (titleMissing) {
        issues.add(
          AiResultItemIssue(
            index: index,
            field: 'title',
            expected: 'non-empty string',
            actualType: _typeName(raw['title']),
          ),
        );
      }
      // History/UI decoding is permissive; strict tool execution rejects the
      // same issues without maintaining a second field conversion path.
      if (idMissing && titleMissing) {
        discardedCount++;
        continue;
      }
      decoded.add(item);
    }

    return AiResultItemDecodeReport(
      items: List<AiResultItem>.unmodifiable(decoded),
      inputCount: itemsValue.length,
      discardedCount: discardedCount,
      normalizedFields: Map<String, int>.unmodifiable(normalizedFields),
      issues: List<AiResultItemIssue>.unmodifiable(issues),
    );
  }

  static List<AiResultItem> fromToolData(Object? toolData) =>
      decodeToolData(toolData).items;

  /// The canonical persisted/tool output shape.
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'coverUrl': coverUrl,
        'source': source,
        'tags': List<String>.from(tags),
        'availability': _stringKeyedMap(availability),
      };
}

class _DecodedItem {
  const _DecodedItem(this.item);

  final AiResultItem item;
}

_DecodedItem _decodeItem(
  Map<String, dynamic> json, {
  required Map<String, int> normalizedFields,
}) {
  String stringField(String field) {
    final value = json[field];
    if (value == null) return '';
    if (value is String || value is num || value is bool) {
      final result = value.toString();
      if (value is! String) _increment(normalizedFields, field);
      return result;
    }
    _increment(normalizedFields, field);
    return '';
  }

  final sourceValue = normalizeAiSource(json['source']);
  if (json['source'] != null && sourceValue == null) {
    _increment(normalizedFields, 'source');
  }

  return _DecodedItem(
    AiResultItem(
      id: stringField('id'),
      title: stringField('title'),
      author: _decodeAuthor(json['author'], normalizedFields),
      coverUrl: stringField('coverUrl'),
      source: sourceValue ?? '',
      tags: _decodeTags(json['tags'], normalizedFields),
      availability: _decodeAvailability(json['availability'], normalizedFields),
    ),
  );
}

String _decodeAuthor(Object? value, Map<String, int> normalizedFields) {
  if (value == null) return '';
  if (value is List) {
    _increment(normalizedFields, 'author');
    return value
        .map((entry) => entry?.toString() ?? '')
        .where((entry) => entry.trim().isNotEmpty)
        .join(' / ');
  }
  if (value is String || value is num || value is bool) {
    if (value is! String) _increment(normalizedFields, 'author');
    return value.toString();
  }
  _increment(normalizedFields, 'author');
  return value.toString();
}

List<String> _decodeTags(Object? value, Map<String, int> normalizedFields) {
  if (value == null) return const [];
  if (value is List) {
    if (value.any((entry) => entry is! String)) {
      _increment(normalizedFields, 'tags');
    }
    return value
        .map((entry) => entry?.toString().trim() ?? '')
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }
  if (value is String) {
    _increment(normalizedFields, 'tags');
    return value.trim().isEmpty ? const [] : [value];
  }
  if (value is Map) {
    _increment(normalizedFields, 'tags');
    final tags = <String>[];
    final entries = value.entries.toList()
      ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
    for (final entry in entries) {
      final namespace = entry.key.toString().trim();
      final values = entry.value is List ? entry.value as List : [entry.value];
      for (final raw in values) {
        final text = raw?.toString().trim() ?? '';
        if (text.isEmpty) continue;
        tags.add(namespace.isEmpty ? text : '$namespace: $text');
      }
    }
    return tags;
  }
  _increment(normalizedFields, 'tags');
  return const [];
}

Map<String, dynamic> _decodeAvailability(
  Object? value,
  Map<String, int> normalizedFields,
) {
  if (value == null) return <String, dynamic>{};
  if (value is Map) {
    final result = _stringKeyedMap(value);
    if (value.keys.any((key) => key is! String)) {
      _increment(normalizedFields, 'availability');
    }
    return result;
  }
  _increment(normalizedFields, 'availability');
  if (value is String || value is num || value is bool) {
    return {'summary': value.toString()};
  }
  if (value is List) {
    return {
      'states': value
          .map((entry) => entry?.toString().trim() ?? '')
          .where((entry) => entry.isNotEmpty)
          .toList(growable: false),
    };
  }
  return <String, dynamic>{};
}

Map<String, dynamic> _stringKeyedMap(Map value) => value.map(
      (key, value) => MapEntry(key.toString(), _deepCopyJsonLike(value)),
    );

Object? _deepCopyJsonLike(Object? value) {
  if (value is Map) {
    return _stringKeyedMap(value);
  }
  if (value is List) {
    return value.map(_deepCopyJsonLike).toList(growable: false);
  }
  return value;
}

void _increment(Map<String, int> counts, String field) {
  counts[field] = (counts[field] ?? 0) + 1;
}

String _typeName(Object? value) {
  if (value == null) return 'null';
  if (value is String) return 'string';
  if (value is num) return 'number';
  if (value is bool) return 'boolean';
  if (value is Map) return 'object';
  if (value is List) return 'array';
  return 'unknown';
}
