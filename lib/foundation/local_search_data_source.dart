import 'download_model.dart';
import 'download_author_resolver.dart';
import 'local_favorites.dart';
import 'local_library.dart';
import 'local_search_core.dart';

enum LocalSearchType { favoritesOnly, downloadsOnly, all }

String localSearchAuthor(DownloadedItem item) {
  if (item is LocalLibraryComicItem) {
    return resolveDownloadedAuthors(item).join(', ');
  }
  return item.subTitle.trim();
}

/// 异步收集所有本地漫画的唯一标签和作者，返回 chip 标签列表。
///
/// 作者条目格式为 `'作者: <name>'`；标签条目使用原始字符串。
/// 结果按出现频次降序排列，作者类在前；显示上限由调用侧 take(50) 控制。
Future<List<String>> _collectLocalChips(LocalSearchType scope) async {
  final tagFreq = <String, int>{};
  final authorFreq = <String, int>{};

  if (scope != LocalSearchType.favoritesOnly) {
    // --- 已下载漫画 ---
    final localManager = LocalLibraryManager();
    await localManager.ensureLoaded();
    for (final item in await localManager.getAll()) {
      if (_shouldHideDownloadedItem(
          item, localManager.showAllDatabaseRecords)) {
        continue;
      }
      for (final tag in item.tags) {
        final t = tag.trim();
        if (t.isNotEmpty) tagFreq[t] = (tagFreq[t] ?? 0) + 1;
      }
      final author = localSearchAuthor(item).trim();
      if (author.isNotEmpty) {
        authorFreq[author] = (authorFreq[author] ?? 0) + 1;
      }
    }
  }

  if (scope != LocalSearchType.downloadsOnly) {
    // --- 收藏漫画 ---
    final favManager = LocalFavoritesManager();
    await favManager.init();
    for (final fav in favManager.allComics()) {
      final comic = fav.comic;
      for (final tag in comic.tags) {
        final t = tag.trim();
        if (t.isNotEmpty) tagFreq[t] = (tagFreq[t] ?? 0) + 1;
      }
      final author = comic.author.trim();
      if (author.isNotEmpty) {
        authorFreq[author] = (authorFreq[author] ?? 0) + 1;
      }
    }
  }

  // 按频次降序排列
  final sortedAuthors = authorFreq.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final sortedTags = tagFreq.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  final chips = <String>[];
  for (final e in sortedAuthors) {
    chips.add('作者: ${e.key}');
  }
  for (final e in sortedTags) {
    chips.add(e.key);
  }
  return chips;
}

class LocalSearchResult {
  final String title;
  final String author;
  final String sourceLabel;
  final List<String> tags;
  final DownloadedItem? downloadItem;
  final DownloadedItem? localItem;
  final FavoriteItemWithFolderInfo? favoriteItem;

  const LocalSearchResult({
    required this.title,
    required this.author,
    required this.sourceLabel,
    this.tags = const [],
    this.downloadItem,
    this.localItem,
    this.favoriteItem,
  });
}

/// The page owns request ordering; this source owns local-data scope and matching.
/// Override it in widget tests without touching real libraries.
class LocalSearchDataSource {
  const LocalSearchDataSource();

  Future<List<String>> collectChips(LocalSearchType scope) =>
      _collectLocalChips(scope);

  Future<List<LocalSearchResult>> search(
    String keyword,
    LocalSearchType scope, {
    List<String> aliases = const [],
  }) async {
    final normalizedKeyword = keyword.trim();
    final results = <LocalSearchResult>[];
    final seenIds = <String>{};
    final favManager = LocalFavoritesManager();
    final localManager = LocalLibraryManager();

    if (scope != LocalSearchType.downloadsOnly) await favManager.init();
    await localManager.ensureLoaded();
    final showAllDatabaseRecords = localManager.showAllDatabaseRecords;

    if (scope != LocalSearchType.downloadsOnly) {
      final favResults = favManager.search(normalizedKeyword, aliases: aliases);
      for (final fav in favResults) {
        final comic = fav.comic;
        final localItem =
            localManager.findCachedByCandidates(comic.candidateDownloadIds());
        final idKey = localItem != null
            ? 'local_${localItem.id}'
            : 'fav_${comic.type.key}_${comic.target}';
        if (seenIds.contains(idKey)) continue;
        seenIds.add(idKey);
        results.add(
          LocalSearchResult(
            title: comic.name,
            author: comic.author,
            sourceLabel: '${comic.type.name} · ${fav.folder}',
            tags: comic.tags,
            localItem: localItem,
            favoriteItem: fav,
          ),
        );
      }
    }

    if (scope != LocalSearchType.favoritesOnly) {
      for (final item in await localManager.getAll()) {
        if (_shouldHideDownloadedItem(item, showAllDatabaseRecords)) {
          continue;
        }
        final idKey = 'local_${item.id}';
        if (seenIds.contains(idKey)) continue;
        if (matchesLocalDownloadedItem(item, normalizedKeyword,
            aliases: aliases)) {
          seenIds.add(idKey);
          results.add(
            LocalSearchResult(
              title: item.name,
              author: localSearchAuthor(item),
              sourceLabel: _downloadLabel(item),
              tags: item.tags,
              downloadItem: item,
            ),
          );
        }
      }
    }

    return results;
  }
}

bool _shouldHideDownloadedItem(
  DownloadedItem item,
  bool showAllDatabaseRecords,
) {
  return !showAllDatabaseRecords &&
      item is LocalLibraryComicItem &&
      item.isManagedDownloadItem &&
      !item.localStorageExists;
}

String _downloadLabel(DownloadedItem item) {
  if (item is LocalLibraryComicItem) {
    if (item.isAlbum) {
      return '图集 · 本地';
    }
    final source = item.sourceDisplayName.trim();
    return source.isEmpty ? '本地下载' : '$source · 本地';
  }
  switch (item.type) {
    case DownloadType.picacg:
      return 'Picacg · 下载';
    case DownloadType.ehentai:
      return 'E-Hentai · 下载';
    case DownloadType.jm:
      return '禁漫 · 下载';
    case DownloadType.hitomi:
      return 'Hitomi · 下载';
    case DownloadType.htmanga:
      return '绅士漫画 · 下载';
    case DownloadType.nhentai:
      return 'NHentai · 下载';
    case DownloadType.copyManga:
      return '拷贝漫画 · 下载';
    case DownloadType.komiic:
      return 'Komiic · 下载';
    case DownloadType.pixiv:
      return 'Pixiv · 下载';
    default:
      return '下载';
  }
}
