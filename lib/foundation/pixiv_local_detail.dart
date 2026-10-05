import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

/// The source row is the identity evidence; names and numeric IDs are not.
class PixivLocalIdentity {
  const PixivLocalIdentity(this.record, this.workId);

  final CustomDownloadedItem record;
  final String? workId;

  static PixivLocalIdentity? fromItem(DownloadedItem item) {
    DownloadedItem? concrete = item;
    if (item is LocalLibraryComicItem) {
      final raw = item.sourceRowJson;
      if (raw == null || raw.trim().isEmpty) return null;
      try {
        concrete = parseDownloadedItemRecordJson(item.originalId, raw);
      } catch (_) {
        return null;
      }
    }
    if (concrete is! CustomDownloadedItem ||
        concrete.sourceKey.trim().toLowerCase() != 'pixiv') {
      return null;
    }
    final raw = concrete.comicId.trim().isNotEmpty
        ? concrete.comicId.trim()
        : concrete.id
            .trim()
            .replaceFirst(RegExp(r'^pixiv', caseSensitive: false), '');
    final id = RegExp(r'^\d+$').hasMatch(raw) && RegExp(r'[1-9]').hasMatch(raw)
        ? raw
        : null;
    return PixivLocalIdentity(concrete, id);
  }

  FavoriteItem? favorite(DownloadedItem item, {String coverPath = ''}) {
    final id = workId;
    if (id == null) return null;
    return FavoriteItem(
      target: id,
      name: item.name,
      coverPath: coverPath,
      author: resolveDownloadedAuthors(record).join(', '),
      type: FavoriteType.pixiv,
      tags: item.tags,
    );
  }

  List<FavoriteItem> aliases(DownloadedItem item) {
    final main = favorite(item);
    if (main == null) return const [];
    return [
      for (final key in {record.sourceKey.hashCode, 'pixiv'.hashCode})
        FavoriteItem(
            target: main.target,
            name: main.name,
            coverPath: '',
            author: main.author,
            type: FavoriteType(key),
            tags: main.tags)
    ];
  }
}

class PixivLocalPage {
  const PixivLocalPage(
      {required this.key,
      required this.ep,
      required this.page,
      required this.provider,
      required this.aspectRatio,
      required this.url});
  final String key;
  final int ep;
  final int page;
  final ImageProvider<Object> provider;
  final double aspectRatio;
  final String url;
}

/// Uses the same factory and loadEp contract as the real reading route.
Future<List<PixivLocalPage>> loadPixivLocalPages(DownloadedItem item) async {
  final identity = PixivLocalIdentity.fromItem(item);
  if (identity == null) return const [];
  final ReadingData data;
  if (item is LocalLibraryComicItem) {
    data = item.createLocalReadingData();
  } else if (item is CustomDownloadedItem) {
    data = item.createLocalReadingData();
  } else {
    return const [];
  }
  final ratio = identity.record.width != null &&
          identity.record.height != null &&
          identity.record.width! > 0 &&
          identity.record.height! > 0
      ? identity.record.width! / identity.record.height!
      : .75;
  final episodes =
      data.hasEp ? [for (var i = 1; i <= (data.eps?.length ?? 1); i++) i] : [0];
  final result = <PixivLocalPage>[];
  for (final ep in episodes) {
    final urls = await data.loadEp(ep);
    for (var i = 0; i < urls.length; i++) {
      result.add(PixivLocalPage(
        key: '${item.id}:$ep:${i + 1}:${urls[i]}',
        ep: ep,
        page: i + 1,
        url: urls[i],
        provider: data.createImageProvider(ep, i + 1, urls[i]),
        aspectRatio: ratio,
      ));
    }
  }
  return List.unmodifiable(result);
}

Map<String, dynamic> pixivLocalMetadata(DownloadedItem item) {
  if (item is LocalLibraryComicItem) {
    try {
      final value = jsonDecode(item.sourceRowJson ?? '');
      if (value is Map) return Map<String, dynamic>.from(value);
    } catch (_) {}
  }
  return PixivLocalIdentity.fromItem(item)?.record.toJson() ?? const {};
}

Set<String> pixivLocalFavoriteFolders(DownloadedItem item,
    {LocalFavoritesManager? manager}) {
  final identity = PixivLocalIdentity.fromItem(item);
  final favorite = identity?.favorite(item);
  if (identity == null || favorite == null) return const {};
  final store = manager ?? LocalFavoritesManager();
  final candidates = [favorite, ...identity.aliases(item)];
  return store.folderNames
      .where((folder) => candidates.any((candidate) =>
          store.comicExists(folder, candidate.target, candidate.type.key)))
      .toSet();
}

void removePixivLocalFavoriteFromFolder(DownloadedItem item, String folder,
    {LocalFavoritesManager? manager}) {
  final identity = PixivLocalIdentity.fromItem(item);
  final favorite = identity?.favorite(item);
  if (identity == null || favorite == null) return;
  final store = manager ?? LocalFavoritesManager();
  for (final candidate in [favorite, ...identity.aliases(item)]) {
    store.deleteComicWithTarget(folder, candidate.target, candidate.type);
  }
}
