import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_search_core.dart';

class AiLocalLibraryQueryCore {
  const AiLocalLibraryQueryCore();

  Future<AiLocalQueryResult> query({
    required String query,
    AiLocalQueryScope scope = AiLocalQueryScope.all,
    int? limit,
    bool includePaths = true,
  }) async {
    final normalizedQuery = query.trim();
    final warnings = <String>[];
    final localManager = LocalLibraryManager();
    await localManager.ensureLoaded();

    final results = <String, _EntityAccumulator>{};
    final showAllDatabaseRecords = localManager.showAllDatabaseRecords;

    if (scope.includesLibrary) {
      for (final item in await localManager.getAll()) {
        if (_shouldHideDownloadedItem(item, showAllDatabaseRecords)) continue;
        if (!matchesLocalDownloadedItem(item, normalizedQuery)) continue;
        _putLocal(
          results,
          item,
          includePaths: includePaths,
          query: normalizedQuery,
          reason: '本地库匹配',
          confidence: _confidenceForLocalItem(item, normalizedQuery),
        );
      }
    }

    if (scope.includesFavorites) {
      final favManager = LocalFavoritesManager();
      await favManager.init();
      for (final fav in favManager.search(normalizedQuery)) {
        final localItem = localManager
            .findCachedByCandidates(fav.comic.candidateDownloadIds());
        if (localItem != null &&
            !_shouldHideDownloadedItem(localItem, showAllDatabaseRecords)) {
          final acc = _putLocal(
            results,
            localItem,
            includePaths: includePaths,
            query: normalizedQuery,
            reason: '收藏关联到本地库',
            confidence: 0.95,
          );
          acc.favorite ??= _favoriteJson(fav);
          acc.availability.add('favorite');
          acc.usableActions.add('openFavorite');
        } else {
          final key = _favoriteEntityId(fav);
          final acc = results.putIfAbsent(
            key,
            () => _EntityAccumulator.favorite(
              key,
              _favoriteBaseJson(fav, normalizedQuery),
            ),
          );
          acc.favorite ??= _favoriteJson(fav);
          acc.availability.add('favorite');
          acc.usableActions.add('openFavorite');
        }
      }
    }

    if (scope.includesHistory) {
      final historyManager = HistoryManager();
      if (historyManager.isInitialized) {
        for (final history in historyManager.getAll()) {
          if (!_matchesHistory(history, normalizedQuery)) continue;
          final localItem = localManager.findCachedByCandidates(
            history.candidateDownloadIds(),
          );
          if (localItem != null &&
              !_shouldHideDownloadedItem(localItem, showAllDatabaseRecords)) {
            final acc = _putLocal(
              results,
              localItem,
              includePaths: includePaths,
              query: normalizedQuery,
              reason: '历史关联到本地库',
              confidence: 0.95,
            );
            acc.history ??= _historyJson(history);
            acc.availability.add('history');
            acc.usableActions.add('openHistory');
          } else {
            final key = _historyEntityId(history);
            final acc = results.putIfAbsent(
              key,
              () => _EntityAccumulator.history(
                key,
                _historyBaseJson(history, normalizedQuery),
              ),
            );
            acc.history ??= _historyJson(history);
            acc.availability.add('history');
            acc.usableActions.add('openHistory');
          }
        }
      } else {
        warnings
            .add('history manager is not initialized; history scope skipped');
      }
    }

    final items = results.values.map((e) => e.toJson()).toList()
      ..sort(_compareEntities);
    final capped = limit != null && limit > 0 && items.length > limit
        ? items.sublist(0, limit)
        : items;
    return AiLocalQueryResult(items: capped, warnings: warnings);
  }

  List<AiLocalResolvedInput> parseInputs({String? text, List<String>? items}) {
    final rawInputs = <String>[];
    if (items != null) {
      rawInputs.addAll(items);
    }
    final normalizedText = text?.trim() ?? '';
    if (normalizedText.isNotEmpty) {
      rawInputs.addAll(_splitLooseText(normalizedText));
    }

    final seen = <String>{};
    final parsed = <AiLocalResolvedInput>[];
    for (final raw in rawInputs) {
      final cleaned = _cleanListMarker(raw).trim();
      if (cleaned.isEmpty || !seen.add(cleaned)) continue;
      parsed.addAll(_parseSingleInput(cleaned));
    }
    return parsed;
  }

  Future<AiLocalResolveResult> resolve({
    String? text,
    List<String>? items,
    AiLocalQueryScope scope = AiLocalQueryScope.all,
    bool includePaths = true,
  }) async {
    final inputs = parseInputs(text: text, items: items);
    final resultInputs = <Map<String, Object?>>[];
    final summary = <String, int>{
      'total': inputs.length,
      'localMatched': 0,
      'possibleLocalMatch': 0,
      'notFound': 0,
      'manualReview': 0,
    };

    for (var i = 0; i < inputs.length; i++) {
      final input = inputs[i];
      final lookup = input.lookupKeyword;
      final queryResult = await query(
        query: lookup,
        scope: scope,
        limit: 10,
        includePaths: includePaths,
      );
      final matches = queryResult.items;
      final hasDownloaded = matches.any((item) {
        final availability = item['availability'];
        return availability is List && availability.contains('downloaded');
      });
      final status = input.parseConfidence < 0.45
          ? 'manualReview'
          : hasDownloaded
              ? 'localMatched'
              : matches.isNotEmpty
                  ? 'possibleLocalMatch'
                  : 'notFound';
      summary[status] = (summary[status] ?? 0) + 1;
      final recommendedAction = switch (status) {
        'localMatched' => 'skip',
        'possibleLocalMatch' => 'manualReview',
        'manualReview' => 'manualReview',
        _ => 'searchOnline',
      };
      resultInputs.add({
        'inputId': 'input:${i + 1}',
        'rawText': input.rawText,
        'kind': input.kind,
        if (input.source != null) 'source': input.source,
        if (input.originId != null) 'originId': input.originId,
        'keyword': lookup,
        'parseConfidence': input.parseConfidence,
        'localMatches': matches,
        'status': status,
        'recommendedAction': recommendedAction,
        'warnings': input.warnings,
      });
    }

    return AiLocalResolveResult(inputs: resultInputs, summary: summary);
  }
}

enum AiLocalQueryScope {
  all,
  library,
  favorites,
  history;

  bool get includesLibrary => this == all || this == library;
  bool get includesFavorites => this == all || this == favorites;
  bool get includesHistory => this == all || this == history;
}

AiLocalQueryScope? parseAiLocalQueryScope(Object? value) {
  final raw = value?.toString().trim().toLowerCase();
  if (raw == null || raw.isEmpty || raw == '全部' || raw == 'all') {
    return AiLocalQueryScope.all;
  }
  if (raw == '库' || raw == '本地库' || raw == 'library') {
    return AiLocalQueryScope.library;
  }
  if (raw == '收藏' || raw == '收藏夹' || raw == 'favorites') {
    return AiLocalQueryScope.favorites;
  }
  if (raw == '历史' || raw == 'history') {
    return AiLocalQueryScope.history;
  }
  return null;
}

class AiLocalQueryResult {
  const AiLocalQueryResult({required this.items, this.warnings = const []});

  final List<Map<String, Object?>> items;
  final List<String> warnings;
}

class AiLocalResolveResult {
  const AiLocalResolveResult({required this.inputs, required this.summary});

  final List<Map<String, Object?>> inputs;
  final Map<String, int> summary;
}

class AiLocalResolvedInput {
  const AiLocalResolvedInput({
    required this.rawText,
    required this.kind,
    required this.keyword,
    required this.parseConfidence,
    this.source,
    this.originId,
    this.warnings = const [],
  });

  final String rawText;
  final String kind;
  final String keyword;
  final String? source;
  final String? originId;
  final double parseConfidence;
  final List<String> warnings;

  String get lookupKeyword {
    final id = originId?.trim() ?? '';
    if (id.isNotEmpty) {
      return id;
    }
    return keyword.trim().isEmpty ? rawText : keyword;
  }
}

class _EntityAccumulator {
  _EntityAccumulator(this.entityId, this.base);

  factory _EntityAccumulator.favorite(
    String entityId,
    Map<String, Object?> base,
  ) =>
      _EntityAccumulator(entityId, base)..availability.add('favorite');

  factory _EntityAccumulator.history(
    String entityId,
    Map<String, Object?> base,
  ) =>
      _EntityAccumulator(entityId, base)..availability.add('history');

  final String entityId;
  final Map<String, Object?> base;
  final Set<String> availability = <String>{};
  final Set<String> usableActions = <String>{};
  Map<String, Object?>? local;
  Map<String, Object?>? favorite;
  Map<String, Object?>? history;

  Map<String, Object?> toJson() {
    final missingFields = <String>[];
    if ((base['originId']?.toString() ?? '').isEmpty) {
      missingFields.add('originId');
    }
    if ((base['authors'] as List?)?.isEmpty ?? true) {
      missingFields.add('authors');
    }
    if (local == null) missingFields.add('local');
    if (favorite == null) missingFields.add('favorite');
    if (history == null) missingFields.add('history');

    return {
      ...base,
      'entityId': entityId,
      'availability': availability.toList()..sort(),
      'local': local,
      'favorite': favorite,
      'history': history,
      'usableActions': usableActions.toList()..sort(),
      'missingFields': missingFields,
    };
  }
}

_EntityAccumulator _putLocal(
  Map<String, _EntityAccumulator> results,
  LocalLibraryComicItem item, {
  required bool includePaths,
  required String query,
  required String reason,
  required double confidence,
}) {
  final id = _localEntityId(item);
  final acc = results.putIfAbsent(
    id,
    () =>
        _EntityAccumulator(id, _localBaseJson(item, query, reason, confidence)),
  );
  acc.local ??= _localJson(item, includePaths: includePaths);
  acc.availability.add('downloaded');
  if (item.localStorageExists) {
    acc.availability.add('localStorageExists');
    acc.usableActions.add('openLocal');
  }
  acc.usableActions.add('viewDownloadStatus');
  return acc;
}

Map<String, Object?> _localBaseJson(
  LocalLibraryComicItem item,
  String query,
  String reason,
  double confidence,
) {
  final originId =
      item.originalId.trim().isNotEmpty ? item.originalId : item.id;
  return {
    'entityId': _localEntityId(item),
    'idQuality': originId.trim().isEmpty ? 'weak' : 'stable',
    'title': item.name,
    'aliases': item.aliases,
    'authors': resolveDownloadedAuthors(item),
    'source': item.type.name,
    'sourceDisplayName': item.sourceDisplayName,
    'originId': originId,
    'metadata': _downloadedMetadata(item),
    'match': {
      'confidence': confidence,
      'matchedFields': _matchedFieldsForLocal(item, query),
      'query': query,
      'reason': reason,
    },
  };
}

Map<String, Object?> _favoriteBaseJson(
  FavoriteItemWithFolderInfo fav,
  String query,
) {
  final comic = fav.comic;
  return {
    'entityId': _favoriteEntityId(fav),
    'idQuality': comic.target.trim().isEmpty ? 'weak' : 'stable',
    'title': comic.name,
    'aliases': const <String>[],
    'authors': _authors(comic.author),
    'source': _sourceKeyForFavoriteType(comic.type),
    'sourceDisplayName': comic.type.name,
    'originId': comic.target,
    'metadata': {
      'tags': comic.tags,
      'time': comic.time,
    },
    'match': {
      'confidence': 0.72,
      'matchedFields': _matchedFieldsForFavorite(comic, query),
      'query': query,
      'reason': '收藏匹配',
    },
  };
}

Map<String, Object?> _historyBaseJson(History history, String query) => {
      'entityId': _historyEntityId(history),
      'idQuality': history.target.trim().isEmpty ? 'weak' : 'stable',
      'title': history.title,
      'aliases': const <String>[],
      'authors': _authors(history.subtitle),
      'source': history.type.name,
      'sourceDisplayName': history.type.name,
      'originId': history.target,
      'metadata': {
        'time': history.time.toIso8601String(),
        'ep': history.ep,
        'page': history.page,
        'maxPage': history.maxPage,
      },
      'match': {
        'confidence': 0.68,
        'matchedFields': _matchedFieldsForHistory(history, query),
        'query': query,
        'reason': '历史匹配',
      },
    };

Map<String, Object?> _localJson(
  LocalLibraryComicItem item, {
  required bool includePaths,
}) {
  return {
    'id': item.id,
    'itemId': item.itemId,
    'originalId': item.originalId,
    'downloadType': item.type.name,
    'downloaded': true,
    'canOpenLocal': item.localStorageExists,
    'localStorageExists': item.localStorageExists,
    'canDelete': item.canDelete,
    'downloadedEps': item.downloadedEps,
    'eps': item.eps,
    'hasMultipleEpisodes': item.hasMultipleEpisodes,
    'isAlbum': item.isAlbum,
    'isArchiveItem': item.isArchiveItem,
    'comicSize': item.comicSize,
    if (includePaths) ...{
      'fileSystemPath': item.fileSystemPath,
      'directory': item.directory,
      'localCoverPath': item.localCoverPath,
      'sourceDbPath': item.sourceDbPath,
      'sourceDirectory': item.sourceDirectory,
      'sourceDbId': item.sourceDbId,
      'sourceDbRowId': item.sourceDbRowId,
    },
  };
}

Map<String, Object?> _favoriteJson(FavoriteItemWithFolderInfo fav) => {
      'target': fav.comic.target,
      'typeKey': fav.comic.type.key,
      'typeName': fav.comic.type.name,
      'folder': fav.folder,
      'coverPath': fav.comic.coverPath,
      'author': fav.comic.author,
      'tags': fav.comic.tags,
      'time': fav.comic.time,
      'candidateDownloadIds': fav.comic.candidateDownloadIds(),
    };

Map<String, Object?> _historyJson(History h) => {
      'target': h.target,
      'typeValue': h.type.value,
      'typeName': h.type.name,
      'cover': h.cover,
      'ep': h.ep,
      'page': h.page,
      'readEpisode': h.readEpisode.toList()..sort(),
      'maxPage': h.maxPage,
      'time': h.time.toIso8601String(),
      'candidateDownloadIds': h.candidateDownloadIds(),
    };

Map<String, Object?> _downloadedMetadata(LocalLibraryComicItem item) => {
      'tags': item.tags,
      'comicSize': item.comicSize,
      'time': item.time?.toIso8601String(),
      'sourceRowTimeMillis': item.sourceRowTimeMillis,
    };

String _localEntityId(LocalLibraryComicItem item) {
  final origin =
      item.originalId.trim().isNotEmpty ? item.originalId : item.itemId;
  if (origin.trim().isNotEmpty) {
    return 'local:${item.type.name}:$origin';
  }
  return 'local:${item.type.name}:${item.id}';
}

String _favoriteEntityId(FavoriteItemWithFolderInfo fav) =>
    'favorite:${fav.comic.type.key}:${fav.comic.target}:${fav.folder}';

String _historyEntityId(History history) =>
    'history:${history.type.value}:${history.target}';

bool _shouldHideDownloadedItem(
  DownloadedItem item,
  bool showAllDatabaseRecords,
) {
  return !showAllDatabaseRecords &&
      item is LocalLibraryComicItem &&
      item.isManagedDownloadItem &&
      !item.localStorageExists;
}

bool _matchesHistory(History h, String keyword) {
  final words = keyword
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((e) => e.isNotEmpty)
      .toList();
  if (words.isEmpty) return true;
  final terms = [
    h.title,
    h.subtitle,
    h.target,
    h.type.name,
    ...h.candidateDownloadIds(),
  ].map((e) => e.toLowerCase()).toList();
  return words.every((word) => terms.any((term) => term.contains(word)));
}

double _confidenceForLocalItem(LocalLibraryComicItem item, String query) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return 0.5;
  if (item.id.toLowerCase() == normalized ||
      item.itemId.toLowerCase() == normalized ||
      item.originalId.toLowerCase() == normalized) {
    return 1;
  }
  if (item.name.toLowerCase() == normalized) return 0.95;
  if (item.name.toLowerCase().contains(normalized)) return 0.85;
  return 0.7;
}

List<String> _matchedFieldsForLocal(LocalLibraryComicItem item, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const <String>[];
  final authors = resolveDownloadedAuthors(item).join(', ');
  final fields = <String, String>{
    'id': item.id,
    'itemId': item.itemId,
    'originalId': item.originalId,
    'title': item.name,
    'author': authors,
    'source': item.sourceDisplayName,
    'fileSystemPath': item.fileSystemPath ?? '',
  };
  final matched = <String>[];
  for (final entry in fields.entries) {
    if (entry.value.toLowerCase().contains(q)) matched.add(entry.key);
  }
  if (item.tags.any((tag) => tag.toLowerCase().contains(q))) {
    matched.add('tags');
  }
  if (item.aliases.any((alias) => alias.toLowerCase().contains(q))) {
    matched.add('aliases');
  }
  return matched;
}

List<String> _matchedFieldsForFavorite(FavoriteItem comic, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const <String>[];
  final fields = <String, String>{
    'title': comic.name,
    'author': comic.author,
    'target': comic.target,
    'source': comic.type.name,
  };
  final matched = <String>[];
  for (final entry in fields.entries) {
    if (entry.value.toLowerCase().contains(q)) matched.add(entry.key);
  }
  if (comic.tags.any((tag) => tag.toLowerCase().contains(q))) {
    matched.add('tags');
  }
  if (comic.candidateDownloadIds().any((id) => id.toLowerCase().contains(q))) {
    matched.add('candidateDownloadIds');
  }
  return matched;
}

List<String> _matchedFieldsForHistory(History h, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const <String>[];
  final fields = <String, String>{
    'title': h.title,
    'subtitle': h.subtitle,
    'target': h.target,
    'source': h.type.name,
  };
  final matched = <String>[];
  for (final entry in fields.entries) {
    if (entry.value.toLowerCase().contains(q)) matched.add(entry.key);
  }
  if (h.candidateDownloadIds().any((id) => id.toLowerCase().contains(q))) {
    matched.add('candidateDownloadIds');
  }
  return matched;
}

List<String> _authors(String value) => value
    .split(RegExp(r'[,，/&、]'))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty && e != '未知')
    .toList();

String _sourceKeyForFavoriteType(FavoriteType type) => switch (type.key) {
      0 => 'picacg',
      1 => 'ehentai',
      2 => 'jm',
      3 => 'hitomi',
      4 => 'htmanga',
      6 => 'nhentai',
      7 => 'copy_manga',
      8 => 'Komiic',
      _ => 'other',
    };

int _compareEntities(Map<String, Object?> a, Map<String, Object?> b) {
  int score(Map<String, Object?> item) {
    final availability = item['availability'];
    final values = availability is List ? availability : const [];
    var score = 0;
    if (values.contains('localStorageExists')) score += 1000;
    if (values.contains('downloaded')) score += 500;
    if (values.contains('favorite')) score += 100;
    if (values.contains('history')) score += 50;
    final match = item['match'];
    if (match is Map) {
      final confidence = match['confidence'];
      if (confidence is num) score += (confidence * 100).round();
    }
    return score;
  }

  final diff = score(b).compareTo(score(a));
  if (diff != 0) return diff;
  return (a['title']?.toString() ?? '').compareTo(b['title']?.toString() ?? '');
}

List<String> _splitLooseText(String text) {
  final lines = text
      .split(RegExp(r'[\r\n]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  final result = <String>[];
  for (final line in lines) {
    final pieces = line
        .split(RegExp(r'[;；、,，]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    result.addAll(pieces.isEmpty ? [line] : pieces);
  }
  return result;
}

String _cleanListMarker(String value) {
  return value
      .replaceFirst(RegExp(r'^\s*(?:[-*•]|\d+[\.、\)]|[（(]\d+[）)])\s*'), '')
      .trim();
}

List<AiLocalResolvedInput> _parseSingleInput(String raw) {
  final urls = RegExp(r'https?://[^\s，,；;、]+', caseSensitive: false)
      .allMatches(raw)
      .map((m) => m.group(0)!)
      .toList();
  if (urls.length > 1) {
    return urls.map(_parseUrlInput).toList();
  }
  if (urls.length == 1 && raw.trim() == urls.first) {
    return [_parseUrlInput(urls.first)];
  }
  if (urls.length == 1) {
    final parsed = _parseUrlInput(urls.first);
    return [
      parsed,
      AiLocalResolvedInput(
        rawText: raw,
        kind: 'mixed',
        keyword: raw.replaceAll(urls.first, '').trim(),
        parseConfidence: 0.5,
        warnings: const ['输入同时包含 URL 和文本，已拆出 URL，剩余文本需复核'],
      ),
    ].where((e) => e.keyword.trim().isNotEmpty).toList();
  }

  final idParsed = _parseSourceIdInput(raw);
  if (idParsed != null) return [idParsed];

  return [
    AiLocalResolvedInput(
      rawText: raw,
      kind: 'title',
      keyword: raw,
      parseConfidence: raw.length < 2 ? 0.35 : 0.7,
      warnings: raw.length < 2 ? const ['标题关键词过短，可能误匹配'] : const [],
    ),
  ];
}

AiLocalResolvedInput _parseUrlInput(String url) {
  final lower = url.toLowerCase();
  final eh = RegExp(r'/g/(\d+)/([a-z0-9]+)').firstMatch(lower);
  if (eh != null) {
    return AiLocalResolvedInput(
      rawText: url,
      kind: 'url',
      source: 'ehentai',
      originId: '${eh.group(1)}-${eh.group(2)}',
      keyword: '${eh.group(1)}-${eh.group(2)}',
      parseConfidence: 0.95,
    );
  }
  final jm = RegExp(r'(?:jmcomic|18comic|jm)[^\d]*(\d+)').firstMatch(lower);
  if (jm != null) {
    final id = jm.group(1)!;
    return AiLocalResolvedInput(
      rawText: url,
      kind: 'url',
      source: 'jm',
      originId: 'jm$id',
      keyword: 'jm$id',
      parseConfidence: 0.9,
    );
  }
  final nh = RegExp(r'nhentai\.net/g/(\d+)').firstMatch(lower);
  if (nh != null) {
    final id = nh.group(1)!;
    return AiLocalResolvedInput(
      rawText: url,
      kind: 'url',
      source: 'nhentai',
      originId: 'nhentai$id',
      keyword: 'nhentai$id',
      parseConfidence: 0.9,
    );
  }
  return AiLocalResolvedInput(
    rawText: url,
    kind: 'url',
    keyword: url,
    parseConfidence: 0.45,
    warnings: const ['无法从 URL 安全识别来源或 id，按原文查重'],
  );
}

AiLocalResolvedInput? _parseSourceIdInput(String raw) {
  final normalized = raw.trim();
  final lower = normalized.toLowerCase();
  final jm = RegExp(r'^jm\s*#?\s*(\d+)$').firstMatch(lower);
  if (jm != null) {
    final id = 'jm${jm.group(1)}';
    return AiLocalResolvedInput(
      rawText: raw,
      kind: 'sourceId',
      source: 'jm',
      originId: id,
      keyword: id,
      parseConfidence: 0.95,
    );
  }
  final nh = RegExp(r'^(?:nh|nhentai)\s*#?\s*(\d+)$').firstMatch(lower);
  if (nh != null) {
    final id = 'nhentai${nh.group(1)}';
    return AiLocalResolvedInput(
      rawText: raw,
      kind: 'sourceId',
      source: 'nhentai',
      originId: id,
      keyword: id,
      parseConfidence: 0.95,
    );
  }
  final eh = RegExp(r'^(\d+)-([a-z0-9]+)$').firstMatch(lower);
  if (eh != null) {
    final id = '${eh.group(1)}-${eh.group(2)}';
    return AiLocalResolvedInput(
      rawText: raw,
      kind: 'sourceId',
      source: 'ehentai',
      originId: id,
      keyword: id,
      parseConfidence: 0.88,
    );
  }
  if (RegExp(r'^[0-9a-f]{24}$', caseSensitive: false).hasMatch(normalized)) {
    return AiLocalResolvedInput(
      rawText: raw,
      kind: 'sourceId',
      source: 'picacg',
      originId: normalized,
      keyword: normalized,
      parseConfidence: 0.85,
    );
  }
  return null;
}
