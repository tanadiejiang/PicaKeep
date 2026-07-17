import 'untranslated_tag_store.dart';
import 'dart:collection';
import 'package:picakeep/tools/tags_translation.dart';

/// A page-independent report of tags observed while handling one comic.
///
/// [flat] and [categorized] are intentionally kept as source data. Candidate
/// parsing and translation lookup remain delegated to the existing helpers.
class UntranslatedTagObservation {
  UntranslatedTagObservation({
    required this.source,
    required this.comicId,
    Iterable<String>? flat,
    Map<String, Iterable<String>>? categorized,
    Iterable<String>? flatTags,
    Map<String, Iterable<String>>? categorizedTags,
    required this.context,
    required this.operationId,
  })  : flat = List.unmodifiable([
          ...?flat,
          ...?flatTags,
        ]),
        categorized = _mergeCategorized(categorized, categorizedTags);

  final String source;
  final String comicId;
  final List<String> flat;
  final Map<String, List<String>> categorized;
  final String context;
  final String operationId;

  /// Compatibility names for callers that use the store's older API terms.
  List<String> get flatTags => flat;
  Map<String, List<String>> get categorizedTags => categorized;

  String get normalizedSource => normalizeUntranslatedTagSource(source);
  String get canonicalComicId => canonicalizeUntranslatedComicId(comicId);
}

typedef UntranslatedTagObservationDto = UntranslatedTagObservation;

Map<String, List<String>> _mergeCategorized(
  Map<String, Iterable<String>>? first,
  Map<String, Iterable<String>>? second,
) {
  final result = <String, List<String>>{};
  for (final input in [first, second]) {
    if (input == null) continue;
    for (final entry in input.entries) {
      result.putIfAbsent(entry.key, () => <String>[]).addAll(entry.value);
    }
  }
  return Map.unmodifiable({
    for (final entry in result.entries)
      entry.key: List<String>.unmodifiable(entry.value),
  });
}

/// Comic identity used by the observation key. EH/NH ids are case-insensitive
/// in the surrounding data sources, while whitespace is never meaningful.
String canonicalizeUntranslatedComicId(String comicId) =>
    comicId.trim().toLowerCase();

String canonicalUntranslatedComicId(String comicId) =>
    canonicalizeUntranslatedComicId(comicId);

class UntranslatedTagCoordinator {
  UntranslatedTagCoordinator({
    UntranslatedTagRepository? repository,
    this.lookup = lookupTagTranslation,
    String Function(String comicId)? canonicalizeComicId,
  })  : repository = repository ?? UntranslatedTagRepository.instance,
        _canonicalizeComicId =
            canonicalizeComicId ?? canonicalizeUntranslatedComicId;

  static final UntranslatedTagCoordinator instance =
      UntranslatedTagCoordinator();

  final UntranslatedTagRepository repository;
  final TagTranslationLookupResult Function(String rawTag, String namespace)
      lookup;
  final String Function(String comicId) _canonicalizeComicId;

  // Operations are retained as complete units until lookup is usable. There
  // is deliberately no per-comic or global fixed-size pending queue here.
  final Map<String, List<UntranslatedTagObservation>> _pending = {};
  final Map<String, Set<String>> _completedOperationRecords = {};
  final Queue<String> _completedOperationOrder = Queue<String>();
  Future<void> _queue = Future<void>.value();

  static const _maxCompletedOperations = 128;

  int get pendingOperationCount => _pending.length;

  int get pendingObservationCount =>
      _pending.values.fold(0, (count, items) => count + items.length);

  Future<int> observe(UntranslatedTagObservation observation) {
    return _enqueue(() async {
      final normalized = _normalize(observation);
      if (normalized == null) return 0;
      if (!tagTranslationsReady) {
        _hold(normalized);
        return 0;
      }

      await _flushReadyPending();
      final result = await _process(normalized);
      if (result.deferred) _hold(normalized);
      return result.accepted;
    });
  }

  Future<int> observeBatch(Iterable<UntranslatedTagObservation> observations) {
    final batch = observations.toList(growable: false);
    return _enqueue(() async {
      final normalized = <UntranslatedTagObservation>[];
      for (final observation in batch) {
        final value = _normalize(observation);
        if (value != null) normalized.add(value);
      }
      if (!tagTranslationsReady) {
        for (final observation in normalized) {
          _hold(observation);
        }
        return 0;
      }

      await _flushReadyPending();
      final result = await _processBatch(normalized);
      for (final observation in result.deferredObservations) {
        _hold(observation);
      }
      return result.accepted;
    });
  }

  /// Replays every retained operation once the translation table is ready.
  /// Operations whose lookup still reports not-ready are retained intact.
  Future<int> flushPending() => _enqueue(_flushReadyPending);

  UntranslatedTagObservation? _normalize(
      UntranslatedTagObservation observation) {
    final source = normalizeUntranslatedTagSource(observation.source);
    final comicId = _canonicalizeComicId(observation.comicId).trim();
    final operationId = observation.operationId.trim();
    if (source.isEmpty || comicId.isEmpty || operationId.isEmpty) return null;
    return UntranslatedTagObservation(
      source: source,
      comicId: comicId,
      flat: observation.flat,
      categorized: observation.categorized,
      context: observation.context,
      operationId: operationId,
    );
  }

  void _hold(UntranslatedTagObservation observation) {
    _pending
        .putIfAbsent(
            observation.operationId, () => <UntranslatedTagObservation>[])
        .add(observation);
  }

  Future<int> _flushReadyPending() async {
    if (!tagTranslationsReady || _pending.isEmpty) return 0;
    final pending = Map<String, List<UntranslatedTagObservation>>.from(
      _pending.map((key, value) => MapEntry(key, List.of(value))),
    );
    _pending.clear();
    var accepted = 0;
    for (final entry in pending.entries) {
      final result = await _processBatch(entry.value);
      accepted += result.accepted;
      if (result.deferredObservations.isNotEmpty) {
        _pending[entry.key] = result.deferredObservations;
      }
    }
    return accepted;
  }

  Future<_ObservationResult> _process(
      UntranslatedTagObservation observation) async {
    final prepared = await _prepareObservation(observation, <String>{});
    final batch = prepared.batch;
    if (batch == null) {
      return _ObservationResult(
        accepted: 0,
        deferred: prepared.deferred,
      );
    }
    final accepted = await repository.observeMissingTagBatches([batch]);
    prepared.operationRecords.addAll(prepared.operationRecordKeys);
    return _ObservationResult(accepted: accepted);
  }

  Future<_BatchObservationResult> _processBatch(
    Iterable<UntranslatedTagObservation> observations,
  ) async {
    final reservedKeys = <String>{};
    final prepared = <_PreparedObservation>[];
    final deferred = <UntranslatedTagObservation>[];
    for (final observation in observations) {
      final value = await _prepareObservation(observation, reservedKeys);
      if (value.deferred) deferred.add(observation);
      if (value.batch != null) {
        prepared.add(value);
        reservedKeys.addAll(value.operationRecordKeys);
      }
    }
    if (prepared.isEmpty) {
      return _BatchObservationResult(
        accepted: 0,
        deferredObservations: deferred,
      );
    }
    final accepted = await repository.observeMissingTagBatches(
      prepared.map((value) => value.batch!),
    );
    for (final value in prepared) {
      value.operationRecords.addAll(value.operationRecordKeys);
    }
    return _BatchObservationResult(
      accepted: accepted,
      deferredObservations: deferred,
    );
  }

  Future<_PreparedObservation> _prepareObservation(
    UntranslatedTagObservation observation,
    Set<String> reservedKeys,
  ) async {
    final candidates = collectUntranslatedTagCandidates(
      source: observation.source,
      flatTags: observation.flat,
      categorizedTags: observation.categorized,
    );
    final missing = <UntranslatedTagCandidate>[];
    for (final candidate in candidates) {
      TagTranslationLookupResult result;
      try {
        result = lookup(candidate.rawTag, candidate.namespace);
      } catch (_) {
        return const _PreparedObservation(deferred: true);
      }
      if (!result.translationReady) {
        return const _PreparedObservation(deferred: true);
      }
      if (result.missing) missing.add(candidate);
    }
    if (missing.isEmpty) return const _PreparedObservation();

    final operationRecords = _completedOperationRecords.putIfAbsent(
      observation.operationId,
      () {
        _completedOperationOrder.addLast(observation.operationId);
        while (_completedOperationOrder.length > _maxCompletedOperations) {
          final expired = _completedOperationOrder.removeFirst();
          _completedOperationRecords.remove(expired);
        }
        return <String>{};
      },
    );
    final eligible = <UntranslatedTagCandidate>[];
    final eligibleKeys = <String>[];
    for (final candidate in missing) {
      final key = _operationRecordKey(observation, candidate);
      if (operationRecords.contains(key) || reservedKeys.contains(key)) {
        continue;
      }
      eligible.add(candidate);
      eligibleKeys.add(key);
    }
    if (eligible.isEmpty) return const _PreparedObservation();

    return _PreparedObservation(
      batch: UntranslatedTagObservationBatch(
        source: observation.source,
        observationId: _observationId(observation),
        candidates: eligible,
        context: observation.context,
      ),
      operationRecords: operationRecords,
      operationRecordKeys: eligibleKeys,
    );
  }

  String _observationId(UntranslatedTagObservation observation) =>
      '${observation.operationId}::${observation.context.trim()}::'
      '${observation.source}::'
      '${observation.canonicalComicId}';

  String _operationRecordKey(
    UntranslatedTagObservation observation,
    UntranslatedTagCandidate candidate,
  ) =>
      '${observation.context.trim()}::${observation.source}::'
      '${observation.canonicalComicId}::${candidate.key}';

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }
}

class _ObservationResult {
  const _ObservationResult({required this.accepted, this.deferred = false});

  final int accepted;
  final bool deferred;
}

class _PreparedObservation {
  const _PreparedObservation({
    this.batch,
    this.operationRecords = const <String>{},
    this.operationRecordKeys = const <String>[],
    this.deferred = false,
  });

  final UntranslatedTagObservationBatch? batch;
  final Set<String> operationRecords;
  final List<String> operationRecordKeys;
  final bool deferred;
}

class _BatchObservationResult {
  const _BatchObservationResult({
    required this.accepted,
    required this.deferredObservations,
  });

  final int accepted;
  final List<UntranslatedTagObservation> deferredObservations;
}
