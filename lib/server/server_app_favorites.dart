part of 'server_app.dart';

extension ServerAppFavorites on PicaKeepAdminServer {
  Future<Response?> _handleFavoritesRequest(Request request) async {
    final segments = request.url.pathSegments;
    if (segments.length < 3 ||
        segments[0] != 'api' ||
        segments[1] != 'library' ||
        segments[2] != 'favorites') {
      return null;
    }

    // LocalFavoritesManager is a singleton that is initialized once during
    // app startup (main.dart). Calling init() here per request would re-open
    // the SQLite db, dispose the previous handle (potentially breaking
    // concurrent UI reads), and add latency that can push small clients past
    // their request timeouts — manifesting as "远程加载失败" on the client.
    final favorites = LocalFavoritesManager();

    if (segments.length == 3) {
      if (request.method == 'GET') {
        return _jsonResponse({
          'folders': [
            for (final folder in favorites.folderNames)
              {
                'name': folder,
                'count': favorites.count(folder),
              },
          ],
        });
      }
      if (request.method == 'POST') {
        final payload = await _readJsonMapFromBody(request);
        final name = payload['name']?.toString().trim() ?? '';
        if (name.isEmpty) {
          return _jsonResponse({'error': 'invalid folder name'},
              statusCode: 400);
        }
        favorites.createFolder(name);
        _state.addLog('favorites', '已新建收藏夹 $name');
        _notifyLibraryChanged();
        return _jsonResponse({'ok': true, 'name': name});
      }
      return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
    }

    final folder = segments[3];

    if (segments.length == 4) {
      if (request.method == 'GET') {
        final snapshot = await _currentSnapshot();
        return _jsonResponse({
          'folder': folder,
          'items': favorites
              .getAllComics(folder)
              .map((item) => _buildFavoriteItemPayload(
                    folder,
                    item,
                    matched: _resolveFavoriteResourceItem(snapshot, item),
                  ))
              .toList(growable: false),
        });
      }
      if (request.method == 'POST') {
        final payload = await _readJsonMapFromBody(request);
        final item = _favoriteItemFromPayload(payload);
        favorites.addComic(folder, item);
        _state.addLog('favorites', '已添加收藏 ${item.name} -> $folder');
        _notifyLibraryChanged();
        return _jsonResponse({'ok': true});
      }
      if (request.method == 'PUT') {
        final payload = await _readJsonMapFromBody(request);
        final newName = payload['newName']?.toString().trim() ?? '';
        if (newName.isEmpty) {
          return _jsonResponse({'error': 'invalid folder name'},
              statusCode: 400);
        }
        favorites.rename(folder, newName);
        _state.addLog('favorites', '已重命名收藏夹 $folder -> $newName');
        _notifyLibraryChanged();
        return _jsonResponse({'ok': true, 'name': newName});
      }
      if (request.method == 'DELETE') {
        favorites.deleteFolder(folder);
        _state.addLog('favorites', '已删除收藏夹 $folder');
        _notifyLibraryChanged();
        return _jsonResponse({'ok': true});
      }
      return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
    }

    final target = segments[4];

    if (segments.length == 6 && segments[5] == 'cover') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final item = _findFavoriteItemByTarget(
        favorites,
        folder,
        target,
        type: _readIntValue(request.url.queryParameters['type']),
      );
      if (item == null) {
        return _jsonResponse({'error': 'favorite not found'}, statusCode: 404);
      }

      final cacheKey = _favoriteCoverCacheKey(folder, item);
      final localCoverPath = item.coverPath.trim();
      if (localCoverPath.isNotEmpty) {
        final localResponse = await _fileResponse(request, localCoverPath);
        if (localResponse.statusCode != 404) {
          return localResponse;
        }
      }

      final cachedCoverPath =
          _favoriteCoverFallbackCache[cacheKey]?.trim() ?? '';
      if (cachedCoverPath.isNotEmpty) {
        final cachedResponse = await _fileResponse(request, cachedCoverPath);
        if (cachedResponse.statusCode != 404) {
          return cachedResponse;
        }
        _favoriteCoverFallbackCache.remove(cacheKey);
      }

      final snapshot = await _currentSnapshot();
      final matched = _resolveFavoriteResourceItem(snapshot, item);
      if (matched == null) {
        return _jsonResponse({'error': 'cover not found'}, statusCode: 404);
      }

      var resolvedCoverPath = matched.coverPath?.trim() ?? '';
      if (resolvedCoverPath.isEmpty) {
        final rootPath = _rootPathForRootId(matched.rootId);
        if (rootPath != null && rootPath.trim().isNotEmpty) {
          resolvedCoverPath = await _scanner.resolveCoverPathOnly(
            matched,
            rootPath: rootPath,
          );
        }
      }
      if (resolvedCoverPath.isEmpty) {
        return _jsonResponse({'error': 'cover not found'}, statusCode: 404);
      }
      if (isArchiveUri(resolvedCoverPath)) {
        return _archiveBytesResponse(request, resolvedCoverPath);
      }
      final resolvedResponse = await _fileResponse(request, resolvedCoverPath);
      if (resolvedResponse.statusCode == 404) {
        return _jsonResponse({'error': 'cover not found'}, statusCode: 404);
      }
      _favoriteCoverFallbackCache[cacheKey] = resolvedCoverPath;
      return resolvedResponse;
    }

    if (segments.length == 5 && request.method == 'DELETE') {
      final item = _findFavoriteItemByTarget(
        favorites,
        folder,
        target,
        type: _readIntValue(request.url.queryParameters['type']),
      );
      if (item == null) {
        return _jsonResponse({'error': 'favorite not found'}, statusCode: 404);
      }
      favorites.deleteComic(folder, item);
      _state.addLog('favorites', '已删除收藏 ${item.name} <- $folder');
      _notifyLibraryChanged();
      return _jsonResponse({'ok': true});
    }

    return _jsonResponse({'error': 'not found'}, statusCode: 404);
  }

  Future<Response?> _handleImageFavoritesRequest(Request request) async {
    final segments = request.url.pathSegments;
    if (segments.length < 3 ||
        segments[0] != 'api' ||
        segments[1] != 'library' ||
        segments[2] != 'image-favorites') {
      return null;
    }

    if (segments.length == 3) {
      if (request.method == 'GET') {
        return _jsonResponse({
          'items': ImageFavoriteManager.getAll()
              .map(_buildImageFavoritePayload)
              .toList(growable: false),
        });
      }
      if (request.method == 'POST') {
        final payload = await _readJsonMapFromBody(request);
        final item = _imageFavoriteFromPayload(payload);
        ImageFavoriteManager.add(item);
        _state.addLog('image_favorites', '已添加图片收藏 ${item.title}');
        _notifyLibraryChanged();
        return _jsonResponse({'ok': true});
      }
      return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
    }

    if (segments.length < 6) {
      return _jsonResponse({'error': 'not found'}, statusCode: 404);
    }

    final id = segments[3];
    final ep = int.tryParse(segments[4]);
    final page = int.tryParse(segments[5]);
    if (ep == null || page == null) {
      return _jsonResponse({'error': 'invalid image favorite key'},
          statusCode: 400);
    }
    final item = _findImageFavorite(id, ep, page);
    if (item == null) {
      return _jsonResponse({'error': 'image favorite not found'},
          statusCode: 404);
    }

    if (segments.length == 7 && segments[6] == 'image') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      if (item.imagePath.trim().isEmpty) {
        return _jsonResponse({'error': 'image not found'}, statusCode: 404);
      }
      return _fileResponse(request, item.imagePath);
    }

    if (segments.length == 6 && request.method == 'DELETE') {
      ImageFavoriteManager.delete(item);
      _state.addLog('image_favorites', '已删除图片收藏 ${item.title}');
      _notifyLibraryChanged();
      return _jsonResponse({'ok': true});
    }

    return _jsonResponse({'error': 'not found'}, statusCode: 404);
  }

  Map<String, dynamic> _buildFavoriteItemPayload(
    String folder,
    FavoriteItem item, {
    ServerResourceItemSummary? matched,
  }) {
    final encodedFolder = Uri.encodeComponent(folder);
    final encodedTarget = Uri.encodeComponent(item.target);
    return {
      'name': item.name,
      'author': item.author,
      'type': item.type.key,
      'tags': item.tags,
      'target': item.target,
      'time': item.time,
      if (matched != null) ...{
        'itemId': matched.id,
        'id': matched.id,
        'displayId': matched.displayId,
        'sourceDisplayName': matched.sourceDisplayName,
        'imageCount': matched.imageCount,
        'totalBytes': matched.totalBytes,
        'updatedAt': matched.updatedAt.toIso8601String(),
      },
      'coverUrl':
          '/api/library/favorites/$encodedFolder/$encodedTarget/cover?type=${item.type.key}',
    };
  }

  Map<String, dynamic> _buildImageFavoritePayload(ImageFavorite item) {
    final encodedId = Uri.encodeComponent(item.id);
    return {
      'id': item.id,
      'title': item.title,
      'ep': item.ep,
      'page': item.page,
      'otherInfo': item.otherInfo,
      'imageUrl':
          '/api/library/image-favorites/$encodedId/${item.ep}/${item.page}/image',
    };
  }

  FavoriteItem? _findFavoriteItemByTarget(
    LocalFavoritesManager favorites,
    String folder,
    String target, {
    int? type,
  }) {
    for (final item in favorites.getAllComics(folder)) {
      if (item.target == target && (type == null || item.type.key == type)) {
        return item;
      }
    }
    return null;
  }

  String _favoriteCoverCacheKey(String folder, FavoriteItem item) {
    return '$folder|${item.type.key}|${item.target}';
  }

  ServerResourceItemSummary? _resolveFavoriteResourceItem(
    ServerResourceSnapshot snapshot,
    FavoriteItem item,
  ) {
    final candidates = _buildFavoriteServerCandidates(item);
    return _findResourceItemByCandidates(snapshot.items, candidates);
  }

  List<String> _buildFavoriteServerCandidates(FavoriteItem item) {
    final candidates = <String>[];
    final seen = <String>{};
    final rawTarget = item.target.trim();

    void addCandidate(String value) {
      final normalized = value.trim();
      if (normalized.isNotEmpty && seen.add(normalized)) {
        candidates.add(normalized);
      }
    }

    for (final candidate in item.candidateDownloadIds()) {
      if (candidate.trim() != rawTarget) {
        addCandidate(candidate);
      }
    }
    addCandidate(rawTarget);
    return candidates;
  }

  ServerResourceItemSummary? _findResourceItemByCandidates(
    List<ServerResourceItemSummary> items,
    List<String> candidates,
  ) {
    if (candidates.isEmpty) return null;

    final normalizedCandidates = candidates
        .map((candidate) => candidate.trim())
        .where((candidate) => candidate.isNotEmpty)
        .toList(growable: false);
    if (normalizedCandidates.isEmpty) return null;

    final itemPools = <({ServerResourceItemSummary item, Set<String> pool})>[
      for (final item in items)
        (item: item, pool: _resourceItemCandidatePool(item)),
    ];

    for (final candidate in normalizedCandidates) {
      for (final entry in itemPools) {
        if (entry.pool.contains(candidate)) {
          return entry.item;
        }
      }
    }

    return null;
  }

  Set<String> _resourceItemCandidatePool(ServerResourceItemSummary item) {
    return <String>{
      item.id,
      item.title,
      item.displayId,
      item.sourceTitle,
      item.sourceDisplayName,
      item.subtitle,
      item.path,
    }.map((value) => value.trim()).where((value) => value.isNotEmpty).toSet();
  }

  ImageFavorite? _findImageFavorite(String id, int ep, int page) {
    for (final item in ImageFavoriteManager.getAll()) {
      if (item.id == id && item.ep == ep && item.page == page) {
        return item;
      }
    }
    return null;
  }

  FavoriteItem _favoriteItemFromPayload(Map<String, dynamic> payload) {
    return FavoriteItem(
      target: payload['target']?.toString() ?? '',
      name: payload['name']?.toString() ?? '',
      coverPath: payload['coverPath']?.toString() ?? '',
      author: payload['author']?.toString() ?? '',
      type: FavoriteType(_readIntValue(payload['type']) ?? 0),
      tags: _readStringListValue(payload['tags']),
    )..time = payload['time']?.toString().trim().isNotEmpty == true
        ? payload['time'].toString().trim()
        : getCurTime();
  }

  ImageFavorite _imageFavoriteFromPayload(Map<String, dynamic> payload) {
    return ImageFavorite(
      payload['id']?.toString() ?? '',
      payload['imagePath']?.toString() ?? '',
      payload['title']?.toString() ?? '',
      _readIntValue(payload['ep']) ?? 0,
      _readIntValue(payload['page']) ?? 0,
      _readJsonLikeMap(payload['otherInfo']),
    );
  }
}
