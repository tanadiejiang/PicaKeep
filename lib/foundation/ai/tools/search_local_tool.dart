import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_search_core.dart';

import '../ai_tool.dart';

class SearchLocalTool extends AiTool {
  const SearchLocalTool();

  @override
  String get name => 'search_local';

  @override
  String get description => '搜索本地库、收藏夹和阅读历史。';

  @override
  Map<String, Object?> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'keyword': {'type': 'string', 'description': '搜索关键词'},
          'scope': {
            'type': 'string',
            'enum': ['全部', '库', '收藏', '历史', 'all', 'library', 'favorites', 'history'],
            'description': '搜索范围，默认全部',
          },
        },
        'required': ['keyword'],
      };

  @override
  Future<AiToolResult> execute(Map<String, dynamic> args) async {
    final keyword = args['keyword']?.toString().trim() ?? '';
    if (keyword.isEmpty) return const AiToolResult.failure('keyword is required');
    final scope = _normalizeScope(args['scope']);
    if (scope == null) return const AiToolResult.failure('unsupported scope');

    final items = <Map<String, Object?>>[];
    final seen = <String>{};
    final localManager = LocalLibraryManager();
    await localManager.ensureLoaded();

    if (scope == _Scope.all || scope == _Scope.favorites) {
      final favManager = LocalFavoritesManager();
      await favManager.init();
      for (final fav in favManager.search(keyword)) {
        final comic = fav.comic;
        final localItem =
            localManager.findCachedByCandidates(comic.candidateDownloadIds());
        final id = 'fav_${comic.type.key}_${comic.target}';
        if (!seen.add(id)) continue;
        items.add({
          'id': comic.target,
          'title': comic.name,
          'author': comic.author,
          'source': '${comic.type.name} · ${fav.folder}',
          'downloaded': localItem != null,
        });
      }
    }

    if (scope == _Scope.all || scope == _Scope.library) {
      final showAllDatabaseRecords = localManager.showAllDatabaseRecords;
      for (final item in await localManager.getAll()) {
        if (_shouldHideDownloadedItem(item, showAllDatabaseRecords)) continue;
        if (!matchesLocalDownloadedItem(item, keyword)) continue;
        final id = 'local_${item.id}';
        if (!seen.add(id)) continue;
        items.add(_downloadedItemJson(item));
      }
    }

    if (scope == _Scope.all || scope == _Scope.history) {
      final historyManager = HistoryManager();
      if (historyManager.isInitialized) {
        for (final h in historyManager.getAll()) {
          if (!_matchesHistory(h, keyword)) continue;
          final id = 'history_${h.target}';
          if (!seen.add(id)) continue;
          final localItem = localManager.findCachedByCandidates(h.candidateDownloadIds());
          items.add({
            'id': h.target,
            'title': h.title,
            'author': h.subtitle,
            'source': '${h.type.name} · 历史',
            'downloaded': localItem != null,
          });
        }
      }
    }

    return AiToolResult.success({'items': items});
  }

  Map<String, Object?> _downloadedItemJson(DownloadedItem item) => {
        'id': item.id,
        'title': item.name,
        'author': item.subTitle,
        'source': item.sourceDisplayName,
        'downloaded': true,
      };

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
    ].map((e) => e.toLowerCase()).toList();
    return words.every((word) => terms.any((term) => term.contains(word)));
  }

  _Scope? _normalizeScope(Object? value) {
    final raw = value?.toString().trim().toLowerCase();
    if (raw == null || raw.isEmpty || raw == '全部' || raw == 'all') {
      return _Scope.all;
    }
    if (raw == '库' || raw == '本地库' || raw == 'library') {
      return _Scope.library;
    }
    if (raw == '收藏' || raw == '收藏夹' || raw == 'favorites') {
      return _Scope.favorites;
    }
    if (raw == '历史' || raw == 'history') {
      return _Scope.history;
    }
    return null;
  }
}

enum _Scope { all, library, favorites, history }
