import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/tools/tags_translation.dart';

const untranslatedTagsSchemaVersion = 1;
const _maxObservationKeys = 4096;
const _maxPendingObservations = 256;

bool isUntranslatedTagSource(String source) {
  final normalized = source.trim().toLowerCase();
  return normalized == 'ehentai' || normalized == 'nhentai';
}

String normalizeUntranslatedTagSource(String source) {
  final normalized = source.trim().toLowerCase();
  return isUntranslatedTagSource(normalized) ? normalized : '';
}

class UntranslatedTagCandidate {
  const UntranslatedTagCandidate({
    required this.namespace,
    required this.rawTag,
  });

  final String namespace;
  final String rawTag;

  String get normalizedNamespace => normalizeTagNamespace(namespace);
  String get normalizedRawTag => normalizeTagValue(rawTag);
  String get key => '$normalizedNamespace::$normalizedRawTag';
}

class UntranslatedTagRecord {
  UntranslatedTagRecord({
    required this.source,
    required this.namespace,
    required this.rawTag,
    required this.encounterCount,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required Set<String> contexts,
  })  : normalizedNamespace = normalizeTagNamespace(namespace),
        normalizedRawTag = normalizeTagValue(rawTag),
        contexts = {...contexts};

  UntranslatedTagRecord._normalized({
    required this.source,
    required this.namespace,
    required this.normalizedNamespace,
    required this.rawTag,
    required this.normalizedRawTag,
    required this.encounterCount,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required Set<String> contexts,
  }) : contexts = {...contexts};

  final String source;
  final String namespace;
  final String normalizedNamespace;
  final String rawTag;
  final String normalizedRawTag;
  int encounterCount;
  DateTime firstSeenAt;
  DateTime lastSeenAt;
  final Set<String> contexts;

  String get key => '$source::$normalizedNamespace::$normalizedRawTag';

  Map<String, dynamic> toJson() => {
        'source': source,
        'namespace': namespace,
        'normalizedNamespace': normalizedNamespace,
        'rawTag': rawTag,
        'normalizedRawTag': normalizedRawTag,
        'encounterCount': encounterCount,
        'firstSeenAt': firstSeenAt.toIso8601String(),
        'lastSeenAt': lastSeenAt.toIso8601String(),
        'contexts': contexts.toList()..sort(),
      };

  static UntranslatedTagRecord? fromJson(Object? value) {
    if (value is! Map) return null;
    final source =
        normalizeUntranslatedTagSource(value['source']?.toString() ?? '');
    final rawTag = value['rawTag']?.toString().trim() ?? '';
    if (source.isEmpty || rawTag.isEmpty) return null;
    final namespace = value['namespace']?.toString().trim() ?? 'tags';
    final firstSeen = DateTime.tryParse(value['firstSeenAt']?.toString() ?? '');
    final lastSeen = DateTime.tryParse(value['lastSeenAt']?.toString() ?? '');
    if (firstSeen == null || lastSeen == null) return null;
    final contexts = value['contexts'] is List
        ? (value['contexts'] as List)
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toSet()
        : <String>{};
    return UntranslatedTagRecord._normalized(
      source: source,
      namespace: namespace.isEmpty ? 'tags' : namespace,
      normalizedNamespace: normalizeTagNamespace(
          value['normalizedNamespace']?.toString() ?? namespace),
      rawTag: rawTag,
      normalizedRawTag:
          normalizeTagValue(value['normalizedRawTag']?.toString() ?? rawTag),
      encounterCount:
          (value['encounterCount'] is num && value['encounterCount'] as num > 0)
              ? (value['encounterCount'] as num).toInt()
              : 1,
      firstSeenAt: firstSeen,
      lastSeenAt: lastSeen,
      contexts: contexts,
    );
  }
}

class UntranslatedTagRepository {
  UntranslatedTagRepository({File? file, DateTime Function()? clock})
      : _file = file,
        _clock = clock ?? DateTime.now;

  static final UntranslatedTagRepository instance = UntranslatedTagRepository();

  final File? _file;
  final DateTime Function() _clock;
  final Map<String, UntranslatedTagRecord> _records = {};
  final Queue<String> _observationOrder = Queue<String>();
  final Set<String> _observationKeys = {};
  Future<void>? _loadFuture;
  Future<void> _writeQueue = Future<void>.value();
  bool _loaded = false;

  File get file =>
      _file ??
      File('${App.dataPath}${Platform.pathSeparator}untranslated_tags.json');

  List<UntranslatedTagRecord> get records {
    final result = _records.values.toList(growable: false);
    result.sort((a, b) {
      final source = a.source.compareTo(b.source);
      if (source != 0) return source;
      final namespace = a.normalizedNamespace.compareTo(b.normalizedNamespace);
      if (namespace != 0) return namespace;
      return a.normalizedRawTag.compareTo(b.normalizedRawTag);
    });
    return List.unmodifiable(result);
  }

  Future<void> load() {
    if (_loaded) return Future<void>.value();
    final pending = _loadFuture;
    if (pending != null) return pending;
    final future = _loadFromDisk();
    _loadFuture = future;
    return future.whenComplete(() {
      if (identical(_loadFuture, future)) _loadFuture = null;
    });
  }

  Future<void> _loadFromDisk() async {
    try {
      final currentFile = file;
      if (await currentFile.exists()) {
        final decoded = jsonDecode(await currentFile.readAsString());
        final values = decoded is Map ? decoded['records'] : decoded;
        if (values is List) {
          for (final value in values) {
            final record = UntranslatedTagRecord.fromJson(value);
            if (record != null) _records[record.key] = record;
          }
        }
      }
    } catch (_) {
      _records.clear();
    } finally {
      _loaded = true;
    }
  }

  Future<int> observeMissingTags({
    required String source,
    required String observationId,
    required Iterable<UntranslatedTagCandidate> candidates,
    required String context,
    DateTime? now,
  }) {
    return observeMissingTagBatches(
      [
        UntranslatedTagObservationBatch(
          source: source,
          observationId: observationId,
          candidates: candidates,
          context: context,
        ),
      ],
      now: now,
    );
  }

  /// Commits multiple comic observations under one repository queue and one
  /// disk write. Callers use this for a restore/scan operation so large
  /// batches do not turn into one fsync per comic.
  Future<int> observeMissingTagBatches(
    Iterable<UntranslatedTagObservationBatch> batches, {
    DateTime? now,
  }) {
    return _enqueue(() async {
      await load();
      var accepted = 0;
      final timestamp = now ?? _clock();
      for (final batch in batches) {
        final normalizedSource = normalizeUntranslatedTagSource(batch.source);
        final normalizedObservation = batch.observationId.trim();
        if (normalizedSource.isEmpty || normalizedObservation.isEmpty) {
          continue;
        }
        final batchKeys = <String>{};
        for (final candidate in batch.candidates) {
          final rawTag = candidate.rawTag.trim();
          if (rawTag.isEmpty || candidate.normalizedRawTag.isEmpty) continue;
          final recordKey =
              '$normalizedSource::${candidate.normalizedNamespace}::${candidate.normalizedRawTag}';
          if (!batchKeys.add(recordKey)) continue;
          final observationKey = '$normalizedObservation::$recordKey';
          if (!_rememberObservation(observationKey)) continue;
          final current = _records[recordKey];
          if (current == null) {
            _records[recordKey] = UntranslatedTagRecord(
              source: normalizedSource,
              namespace: candidate.namespace.trim().isEmpty
                  ? candidate.normalizedNamespace
                  : candidate.namespace.trim(),
              rawTag: rawTag,
              encounterCount: 1,
              firstSeenAt: timestamp,
              lastSeenAt: timestamp,
              contexts: {
                if (batch.context.trim().isNotEmpty) batch.context.trim(),
              },
            );
          } else {
            current.encounterCount += 1;
            current.lastSeenAt = timestamp;
            if (batch.context.trim().isNotEmpty) {
              current.contexts.add(batch.context.trim());
            }
          }
          accepted += 1;
        }
      }
      if (accepted > 0) await _writeToDisk();
      return accepted;
    });
  }

  bool _rememberObservation(String value) {
    if (!_observationKeys.add(value)) return false;
    _observationOrder.addLast(value);
    while (_observationOrder.length > _maxObservationKeys) {
      _observationKeys.remove(_observationOrder.removeFirst());
    }
    return true;
  }

  Future<void> pruneTranslated({
    TagTranslationLookupResult Function(String rawTag, String namespace)
        lookup = lookupTagTranslation,
  }) {
    return _enqueue(() async {
      await load();
      if (!tagTranslationsReady) return;
      _records.removeWhere(
          (_, record) => lookup(record.rawTag, record.namespace).found);
      await _writeToDisk();
    });
  }

  Future<void> clear() {
    return _enqueue(() async {
      await load();
      _records.clear();
      _observationKeys.clear();
      _observationOrder.clear();
      await _writeToDisk();
    });
  }

  String formatText([Iterable<UntranslatedTagRecord>? source]) {
    final values = (source ?? records).toList(growable: false);
    final buffer = StringBuffer()
      ..writeln('PicaKeep 待翻译标签')
      ..writeln('生成时间：${_clock().toIso8601String()}')
      ..writeln();
    String? currentSource;
    String? currentNamespace;
    for (final record in values) {
      if (record.source != currentSource) {
        currentSource = record.source;
        currentNamespace = null;
        buffer
          ..writeln('来源：$currentSource')
          ..writeln();
      }
      if (record.normalizedNamespace != currentNamespace) {
        currentNamespace = record.normalizedNamespace;
        buffer.writeln('[$currentNamespace]');
      }
      buffer.writeln(
        '- ${record.rawTag} | 次数：${record.encounterCount} | '
        '首次：${record.firstSeenAt.toIso8601String()} | '
        '最后：${record.lastSeenAt.toIso8601String()}',
      );
    }
    if (values.isEmpty) buffer.writeln('暂无待翻译标签');
    return buffer.toString();
  }

  Future<void> flush() => _enqueue(() async {
        await load();
        await _writeToDisk();
      });

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _writeQueue.then((_) => action());
    _writeQueue = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  Future<void> _writeToDisk() async {
    final currentFile = file;
    await currentFile.parent.create(recursive: true);
    final temp = File('${currentFile.path}.tmp');
    final payload = jsonEncode({
      'schemaVersion': untranslatedTagsSchemaVersion,
      'records': records.map((record) => record.toJson()).toList(),
    });
    await temp.writeAsString(payload, flush: true);
    if (await currentFile.exists()) await currentFile.delete();
    await temp.rename(currentFile.path);
  }
}

class UntranslatedTagObservationBatch {
  const UntranslatedTagObservationBatch({
    required this.source,
    required this.observationId,
    required this.candidates,
    required this.context,
  });

  final String source;
  final String observationId;
  final Iterable<UntranslatedTagCandidate> candidates;
  final String context;
}

class UntranslatedTagCollector {
  UntranslatedTagCollector({
    required this.repository,
    this.lookup = lookupTagTranslation,
  });

  final UntranslatedTagRepository repository;
  final TagTranslationLookupResult Function(String rawTag, String namespace)
      lookup;

  static final Queue<_PendingTagObservation> _pending =
      Queue<_PendingTagObservation>();

  Future<int> observe({
    required String source,
    required String observationId,
    required String context,
    Iterable<String> flatTags = const <String>[],
    Map<String, List<String>> categorizedTags = const <String, List<String>>{},
  }) async {
    if (!isUntranslatedTagSource(source)) return 0;
    if (!tagTranslationsReady) {
      _pending.addLast(
        _PendingTagObservation(
          source: source,
          observationId: observationId,
          context: context,
          flatTags: flatTags.toList(growable: false),
          categorizedTags: {
            for (final entry in categorizedTags.entries)
              entry.key: entry.value.toList(growable: false),
          },
        ),
      );
      while (_pending.length > _maxPendingObservations) {
        _pending.removeFirst();
      }
      return 0;
    }
    await flushPending(repository);
    final candidates = collectUntranslatedTagCandidates(
      source: source,
      flatTags: flatTags,
      categorizedTags: categorizedTags,
    );
    final missing = candidates.where((candidate) {
      final result = lookup(candidate.rawTag, candidate.namespace);
      return result.translationReady && result.missing;
    });
    return repository.observeMissingTags(
      source: source,
      observationId: observationId,
      candidates: missing,
      context: context,
    );
  }

  static Future<void> flushPending(UntranslatedTagRepository repository) async {
    if (!tagTranslationsReady || _pending.isEmpty) return;
    final pending = List<_PendingTagObservation>.of(_pending);
    _pending.clear();
    final collector = UntranslatedTagCollector(repository: repository);
    for (final observation in pending) {
      await collector.observe(
        source: observation.source,
        observationId: observation.observationId,
        context: observation.context,
        flatTags: observation.flatTags,
        categorizedTags: observation.categorizedTags,
      );
    }
  }
}

List<UntranslatedTagCandidate> collectUntranslatedTagCandidates({
  String? source,
  Iterable<String> flatTags = const <String>[],
  Map<String, List<String>> categorizedTags = const <String, List<String>>{},
}) {
  final result = <UntranslatedTagCandidate>[];
  final seen = <String>{};
  void add(String namespace, String rawTag) {
    final candidate = UntranslatedTagCandidate(
      namespace: namespace.trim().isEmpty ? 'tags' : namespace,
      rawTag: rawTag,
    );
    if (source?.trim().toLowerCase() == 'nhentai' &&
        _isNhentaiMetadataNamespace(candidate.normalizedNamespace)) {
      return;
    }
    if (candidate.normalizedRawTag.isEmpty || !seen.add(candidate.key)) return;
    result.add(candidate);
  }

  for (final entry in categorizedTags.entries) {
    for (final value in entry.value) {
      add(entry.key, value);
    }
  }
  for (final tag in flatTags) {
    final value = tag.trim();
    if (value.isEmpty) continue;
    final separator = value.indexOf(':');
    if (separator > 0) {
      add(value.substring(0, separator), value.substring(separator + 1));
    } else {
      add('tags', value);
    }
  }
  return result;
}

bool _isNhentaiMetadataNamespace(String namespace) {
  return const {
    'page',
    'pages',
    'time',
    'uploaded',
    'upload',
    'date',
    '日期',
    '时间',
  }.contains(namespace.trim().toLowerCase());
}

class _PendingTagObservation {
  const _PendingTagObservation({
    required this.source,
    required this.observationId,
    required this.context,
    required this.flatTags,
    required this.categorizedTags,
  });

  final String source;
  final String observationId;
  final String context;
  final List<String> flatTags;
  final Map<String, List<String>> categorizedTags;
}
