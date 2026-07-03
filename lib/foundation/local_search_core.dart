import 'download_model.dart';
import 'local_library.dart';

Iterable<String> localSearchTagTerms(String tag) sync* {
  final raw = tag.trim();
  if (raw.isEmpty) return;
  yield raw.toLowerCase();
  if (raw.contains(':')) {
    final value = raw.split(':').last.trim();
    if (value.isNotEmpty) {
      yield value.toLowerCase();
    }
  }
}

Iterable<String> localDownloadedItemSearchTerms(DownloadedItem item) sync* {
  yield item.name.toLowerCase();
  yield item.subTitle.toLowerCase();
  yield item.sourceDisplayName.toLowerCase();

  for (final tag in item.tags) {
    yield* localSearchTagTerms(tag);
  }

  try {
    final json = item.toJson();
    for (final key in const [
      'comicId',
      'id',
      'itemId',
      'link',
      'favoriteTarget',
      'directory',
    ]) {
      final value = json[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        yield value.toLowerCase();
      }
    }
  } catch (_) {}

  if (item is LocalLibraryComicItem) {
    yield item.itemId.toLowerCase();
    yield item.originalId.toLowerCase();
    final favoriteTarget = item.favoriteTarget?.trim();
    if (favoriteTarget != null && favoriteTarget.isNotEmpty) {
      yield favoriteTarget.toLowerCase();
    }
    final fileSystemPath = item.fileSystemPath?.trim();
    if (fileSystemPath != null && fileSystemPath.isNotEmpty) {
      yield fileSystemPath.toLowerCase();
    }
    for (final alias in item.aliases) {
      final normalized = alias.trim();
      if (normalized.isNotEmpty) {
        yield normalized.toLowerCase();
      }
    }
    if (item.isAlbum) {
      yield '图集';
    }
  }
}

bool matchesLocalDownloadedItem(DownloadedItem item, String keyword) {
  final words = keyword
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((e) => e.isNotEmpty)
      .toList();
  if (words.isEmpty) {
    return true;
  }
  final terms = localDownloadedItemSearchTerms(item)
      .where((e) => e.isNotEmpty)
      .toList();
  return words.every((word) => terms.any((term) => term.contains(word)));
}
