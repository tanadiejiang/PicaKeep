import 'download_model.dart';

/// The author/artist shown to users is source metadata, not the generic
/// DownloadedItem.subTitle field. EH uploader and NH groups are deliberately
/// excluded from this resolver.
List<String> resolveDownloadedAuthors(DownloadedItem item) {
  final json = item.toJson();
  final rawJson = json['sourceRowJson']?.toString().trim() ?? '';
  final originalId = json['originalId']?.toString().trim() ?? '';
  if (rawJson.isNotEmpty && originalId.isNotEmpty) {
    final parsed = parseDownloadedItemRecordJson(originalId, rawJson);
    if (parsed != null && parsed != item) {
      return resolveDownloadedAuthors(parsed);
    }
    if (item.type == DownloadType.ehentai ||
        item.type == DownloadType.nhentai) {
      return const <String>[];
    }
  }
  if (item is DownloadedGallery) {
    return resolveEhAuthorsFromFlatTags(item.tags);
  }
  if (item is NhentaiDownloadedComic) {
    return resolveNhentaiAuthors(item.categorizedTags);
  }
  if (item is DownloadedHitomiComic) {
    return _stablePeople(item.artists);
  }
  if (item is DownloadedComic) {
    return _splitPeople(item.author);
  }
  if (item is DownloadedJmComic) {
    return _splitPeople(item.author);
  }
  // HtManga stores an uploader, not an artist, and custom records do not have
  // a source-safe author contract. Do not turn those fields into authors.
  if (item is DownloadedHtComic || item is CustomDownloadedItem) {
    return const <String>[];
  }
  return _splitPeople(item.subTitle);
}

/// Resolves a managed download database row without importing any page/UI
/// code. EH/NH rows with broken or missing JSON intentionally resolve empty.
List<String> resolveDownloadedAuthorsFromRecord(
  String id,
  String rawJson, {
  DownloadedItem? fallback,
}) {
  final parsed = parseDownloadedItemRecordJson(id, rawJson);
  if (parsed != null) {
    return resolveDownloadedAuthors(parsed);
  }
  if (fallback != null &&
      fallback.type != DownloadType.ehentai &&
      fallback.type != DownloadType.nhentai) {
    return resolveDownloadedAuthors(fallback);
  }
  return const <String>[];
}

List<String> resolveEhAuthorsFromFlatTags(Iterable<String> tags) {
  final result = <String>[];
  for (final raw in tags) {
    final separator = raw.indexOf(':');
    if (separator <= 0) continue;
    final namespace = raw.substring(0, separator).trim().toLowerCase();
    if (namespace != 'artist') continue;
    _addStable(result, raw.substring(separator + 1));
  }
  return result;
}

List<String> resolveNhentaiAuthors(
  Map<String, List<String>> categorizedTags,
) {
  final result = <String>[];
  for (final entry in categorizedTags.entries) {
    if (entry.key.trim().toLowerCase() != 'artists') continue;
    for (final value in entry.value) {
      _addStable(result, value);
    }
  }
  return result;
}

/// Resolves the author contract for an online/source-neutral record.
///
/// EH search/favorite rows carry namespaced flat tags, while NH list rows do
/// not carry the Artists category and therefore must remain unknown. Other
/// sources keep their existing explicit author field.
List<String> resolveSourceAuthors({
  required String source,
  Iterable<String> flatTags = const <String>[],
  Map<String, List<String>> categorizedTags = const <String, List<String>>{},
  String fallbackAuthor = '',
}) {
  switch (source.trim().toLowerCase()) {
    case 'ehentai':
    case 'eh':
      return resolveEhAuthorsFromFlatTags(flatTags);
    case 'nhentai':
    case 'nh':
      return resolveNhentaiAuthors(categorizedTags);
    default:
      return splitAuthorNames(fallbackAuthor);
  }
}

List<String> splitAuthorNames(String value) => _stablePeople(
      value.split(RegExp(r'[,，、]')),
    );

List<String> _splitPeople(String value) => splitAuthorNames(value);

List<String> _stablePeople(Iterable<String> values) {
  final result = <String>[];
  for (final value in values) {
    _addStable(result, value);
  }
  return result;
}

void _addStable(List<String> result, String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || result.contains(normalized)) return;
  result.add(normalized);
}
