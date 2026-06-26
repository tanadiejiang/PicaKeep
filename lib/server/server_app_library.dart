part of 'server_app.dart';

extension ServerAppLibrary on PicaKeepAdminServer {
  Future<Response?> _handleLibraryRootsRequest(Request request) async {
    final segments = request.url.pathSegments;
    if (segments.length != 5 || segments[4] != 'collection-shell') {
      return _jsonResponse({'error': 'not found'}, statusCode: 404);
    }
    if (request.method != 'PUT') {
      return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
    }
    final rootId = segments[3].trim();
    if (!rootId.startsWith('custom_')) {
      return _jsonResponse({'error': 'unsupported root'}, statusCode: 400);
    }
    final config = _config ?? PicaKeepServerConfig.defaults();
    final rootPath = _rootPathForRootId(rootId)?.trim() ?? '';
    if (rootPath.isEmpty) {
      return _jsonResponse({'error': 'root not found'}, statusCode: 404);
    }
    final payload = await _readJsonMapFromBody(request);
    final enabled = payload['enabled'] == true;
    final nextConfig = config.setCollectionShellModeForPath(rootPath, enabled);
    _config = nextConfig;
    await PicaKeepServerConfig.save(configPath, nextConfig);
    final refreshed = await rescanResources();
    final root = refreshed.roots.firstWhere(
      (entry) => entry.id == rootId,
      orElse: () => ServerResourceRootSummary(
        id: rootId,
        title: rootId,
        path: rootPath,
        exists: false,
        itemCount: 0,
        totalBytes: 0,
        supportsCollectionShell: true,
        collectionShellEnabled: enabled,
      ),
    );
    _state.addLog(
      'config',
      '已${enabled ? '开启' : '关闭'}合集外壳目录识别：$rootPath',
    );
    return _jsonResponse({
      'ok': true,
      'root': _buildLibraryRootPayload(root, refreshed.items),
      'librarySignature': _librarySignature ?? '',
    });
  }

  Future<Response?> _handleLibraryRequest(Request request) async {
    final segments = request.url.pathSegments;
    if (segments.length >= 3 &&
        segments[0] == 'api' &&
        segments[1] == 'library' &&
        segments[2] == 'roots') {
      return _handleLibraryRootsRequest(request);
    }
    if (segments.length < 3 ||
        segments[0] != 'api' ||
        segments[1] != 'library' ||
        segments[2] != 'items') {
      return null;
    }

    final snapshot = await _currentSnapshot();
    if (segments.length == 3) {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _jsonResponse({
        'generatedAt': snapshot.generatedAt.toIso8601String(),
        'librarySignature': _librarySignature ?? '',
        'totalComicCount': snapshot.totalComicCount,
        'totalBytes': snapshot.totalBytes,
        'roots': snapshot.roots
            .map((root) => _buildLibraryRootPayload(root, snapshot.items))
            .toList(),
        'items': snapshot.items.map(_buildLibraryItemPayload).toList(),
      });
    }

    if (segments.length == 4 && segments[3] == 'refresh') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final refreshed = await rescanResources();
      return _jsonResponse({
        'ok': true,
        'generatedAt': refreshed.generatedAt.toIso8601String(),
        'librarySignature': _librarySignature ?? '',
        'totalComicCount': refreshed.totalComicCount,
        'totalBytes': refreshed.totalBytes,
        'roots': refreshed.roots
            .map((root) => _buildLibraryRootPayload(root, refreshed.items))
            .toList(),
        'items': refreshed.items.map(_buildLibraryItemPayload).toList(),
      });
    }

    if (segments.length == 4 && segments[3] == 'batch-trash') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final ids = await _readStringListFromBody(request, 'itemIds');
      return _jsonResponse(await batchTrashItems(ids));
    }

    if (segments.length == 4 && segments[3] == 'batch-delete') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final ids = await _readStringListFromBody(request, 'itemIds');
      return _jsonResponse(await batchDeleteItemsPermanently(ids));
    }

    final itemId = segments[3];
    final item = snapshot.findItemById(itemId);
    if (item == null) {
      return _jsonResponse({'error': 'item not found'}, statusCode: 404);
    }
    final rootPath = _rootPathForRootId(item.rootId);

    if (segments.length == 5 && segments[4] == 'trash') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final rootPath = _rootPathForRootId(item.rootId);
      if (rootPath == null || rootPath.trim().isEmpty) {
        return _jsonResponse({'error': 'root path not found'}, statusCode: 404);
      }
      final entry =
          await _trashStore.moveItemToTrash(item: item, rootPath: rootPath);
      await _deleteManagedDownloadDbRow(item);
      await rescanResources();
      _state.addLog('trash', '已移入回收站 ${item.title}');
      return _jsonResponse({
        'ok': true,
        'item': _buildTrashItemPayload(entry),
      });
    }

    if (segments.length == 5 && segments[4] == 'recommendations') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final limit =
          _clampIntQuery(request.url.queryParameters['limit'], 10, 1, 30);
      return _jsonResponse(_buildLibraryRecommendationsPayload(
        snapshot,
        item,
        limit: limit,
      ));
    }

    if (segments.length == 6 &&
        segments[4] == 'archive' &&
        segments[5] == 'status') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _jsonResponse({
        'isArchive': item.isArchive,
        'encrypted': item.archiveEncrypted,
        'passwordMatched': item.archivePasswordMatched,
        'format': item.archiveFormat,
      });
    }

    if (segments.length == 6 &&
        segments[4] == 'archive' &&
        segments[5] == 'unlock') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      if (!item.isArchive) {
        return _jsonResponse({'error': 'not an archive item'}, statusCode: 400);
      }
      if (!item.archiveEncrypted) {
        return _jsonResponse({'error': 'archive is not encrypted'},
            statusCode: 400);
      }
      final archivePath = _archivePathForItem(item);
      if (archivePath == null || archivePath.isEmpty) {
        return _jsonResponse({'error': 'archive path not found'},
            statusCode: 404);
      }
      final payload = await _readJsonMapFromBody(request);
      final password = payload['password']?.toString() ?? '';
      if (password.isEmpty) {
        return _jsonResponse({'error': 'password required'}, statusCode: 400);
      }

      final ok = await ArchiveReadingService.instance.tryUnlock(
        archivePath,
        password,
      );
      if (!ok) {
        return _jsonResponse({
          'ok': false,
          'passwordMatched': false,
          'error': '密码错误',
        });
      }

      _deepItemCache.remove(item.id);
      _coverPathCache.remove(item.id);
      final refreshed = await rescanResources();
      final refreshedItem = refreshed.findItemById(item.id) ?? item;
      return _jsonResponse({
        'ok': true,
        'passwordMatched': true,
        'coverUrl': _buildItemCoverUrl(refreshedItem),
      });
    }

    if (segments.length == 4 && request.method == 'DELETE') {
      final dir = Directory(item.path);
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
      await _deleteManagedDownloadDbRow(item);
      await rescanResources();
      _state.addLog('trash', '已直接删除 ${item.title}');
      return _jsonResponse({'ok': true});
    }

    if (segments.length == 4) {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final deepItem = await _ensureDeepItem(item, rootPath: rootPath);
      return _jsonResponse(
          _buildLibraryItemPayload(deepItem, includePages: true));
    }

    if (segments.length == 5 && segments[4] == 'cover') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      if (item.isArchive) {
        final coverPath = item.coverPath?.trim() ?? '';
        if (coverPath.isEmpty || !isArchiveUri(coverPath)) {
          return _jsonResponse({'error': 'cover not found'}, statusCode: 404);
        }
        return _archiveBytesResponse(request, coverPath);
      }
      final cachedCoverPath = _coverPathCache[item.id]?.trim() ?? '';
      if (cachedCoverPath.isNotEmpty) {
        final cached = await _fileResponse(request, cachedCoverPath);
        if (cached.statusCode != 404) {
          return cached;
        }
        _coverPathCache.remove(item.id);
      }
      final coverPath = await _scanner.resolveCoverPathOnly(
        item,
        rootPath: rootPath,
      );
      if (coverPath.isEmpty) {
        return _jsonResponse({'error': 'cover not found'}, statusCode: 404);
      }
      _coverPathCache[item.id] = coverPath;
      return _fileResponse(request, coverPath);
    }

    if (segments.length == 6 && segments[4] == 'episodes') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final episodeIndex = int.tryParse(segments[5]);
      if (episodeIndex == null) {
        return _jsonResponse({'error': 'invalid episode'}, statusCode: 400);
      }
      final deepItem = await _ensureDeepItem(item, rootPath: rootPath);
      final episode = _findEpisode(deepItem, episodeIndex);
      if (episode == null) {
        return _jsonResponse({'error': 'episode not found'}, statusCode: 404);
      }
      return _jsonResponse(
        _buildLibraryEpisodePayload(deepItem.id, episode, includePages: true),
      );
    }

    if (segments.length == 7 && segments[4] == 'images') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final episodeIndex = int.tryParse(segments[5]);
      final pageIndex = int.tryParse(segments[6]);
      if (episodeIndex == null || pageIndex == null) {
        return _jsonResponse({'error': 'invalid image target'},
            statusCode: 400);
      }
      final deepItem = await _ensureDeepItem(item, rootPath: rootPath);
      final episode = _findEpisode(deepItem, episodeIndex);
      if (episode == null) {
        return _jsonResponse({'error': 'episode not found'}, statusCode: 404);
      }
      if (pageIndex < 0 || pageIndex >= episode.imagePaths.length) {
        return _jsonResponse({'error': 'page not found'}, statusCode: 404);
      }
      final imagePath = episode.imagePaths[pageIndex];
      if (isArchiveUri(imagePath)) {
        return _archiveBytesResponse(request, imagePath);
      }
      return _fileResponse(request, imagePath);
    }

    return _jsonResponse({'error': 'not found'}, statusCode: 404);
  }

  Future<ServerResourceItemSummary> _ensureDeepItem(
    ServerResourceItemSummary shallow, {
    required String? rootPath,
  }) async {
    if (shallow.rootId.startsWith('custom_') ||
        rootPath == null ||
        rootPath.trim().isEmpty) {
      return shallow;
    }
    final cached = _deepItemCache[shallow.id];
    if (cached != null) {
      return cached;
    }
    final inFlight = _deepItemInFlight[shallow.id];
    if (inFlight != null) {
      return await inFlight;
    }
    final future = _runDeepItemScan(shallow, rootPath: rootPath);
    _deepItemInFlight[shallow.id] = future;
    try {
      return await future;
    } finally {
      _deepItemInFlight.remove(shallow.id);
    }
  }

  Future<ServerResourceItemSummary> _runDeepItemScan(
    ServerResourceItemSummary shallow, {
    required String rootPath,
  }) async {
    await _acquireDeepScanSlot();
    try {
      final deepItem = await _scanner.deepScanItem(shallow, rootPath: rootPath);
      final resolved = deepItem ?? shallow;
      _deepItemCache[shallow.id] = resolved;
      return resolved;
    } finally {
      _releaseDeepScanSlot();
    }
  }

  Future<void> _acquireDeepScanSlot() async {
    while (_activeDeepScanCount >= _maxConcurrentDeepScans) {
      final completer = Completer<void>();
      _deepScanWaiters.add(completer);
      await completer.future;
    }
    _activeDeepScanCount += 1;
  }

  void _releaseDeepScanSlot() {
    if (_activeDeepScanCount > 0) {
      _activeDeepScanCount -= 1;
    }
    if (_deepScanWaiters.isEmpty) {
      return;
    }
    final completer = _deepScanWaiters.removeAt(0);
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  Future<ServerResourceSnapshot> _currentSnapshot() async {
    final snapshot = _snapshot;
    if (snapshot != null) {
      return snapshot;
    }
    final nextSnapshot = await _scanResources();
    _setSnapshot(nextSnapshot, emitEvent: false);
    return nextSnapshot;
  }

  ServerResourceEpisodeSummary? _findEpisode(
    ServerResourceItemSummary item,
    int episodeIndex,
  ) {
    if (item.episodes.isEmpty) {
      return null;
    }
    if (episodeIndex <= 0) {
      return item.episodes.first;
    }
    for (final episode in item.episodes) {
      if (episode.index == episodeIndex) {
        return episode;
      }
    }
    if (item.episodes.length == 1 && episodeIndex == 1) {
      return item.episodes.first;
    }
    return null;
  }

  void _notifyLibraryChanged() {
    // Favorites and image favorites live in their own SQLite stores; changing
    // them must not trigger a full resource rescan, which would block existing
    // remote library endpoints on large libraries.
  }

  String? _rootPathForRootId(String rootId) {
    final config = _config ?? PicaKeepServerConfig.defaults();
    return switch (rootId) {
      'current_download' => config.currentDownloadRoot,
      'original_download' => config.originalDownloadRoot,
      _ when rootId.startsWith('custom_') => () {
          final index = int.tryParse(rootId.substring('custom_'.length));
          if (index == null ||
              index < 0 ||
              index >= config.customLibraryRoots.length) {
            return null;
          }
          return config.customLibraryRoots[index];
        }(),
      _ => null,
    };
  }

  Map<String, dynamic> _buildLibraryRootPayload(
    ServerResourceRootSummary root,
    Iterable<ServerResourceItemSummary> items,
  ) {
    final previewCoverUrls = <String>[];
    for (final item in items) {
      if (item.rootId != root.id || item.coverPath?.trim().isEmpty != false) {
        continue;
      }
      previewCoverUrls.add(
        _buildItemCoverUrl(item),
      );
      if (previewCoverUrls.length >= 6) {
        break;
      }
    }
    return {
      'id': root.id,
      'title': root.title,
      'path': root.path,
      'exists': root.exists,
      'itemCount': root.itemCount,
      'totalBytes': root.totalBytes,
      'supportsCollectionShell': root.supportsCollectionShell,
      'collectionShellEnabled': root.collectionShellEnabled,
      'previewCoverUrls': previewCoverUrls,
    };
  }

  int _clampIntQuery(String? value, int fallback, int min, int max) {
    final parsed = int.tryParse((value ?? '').trim()) ?? fallback;
    if (parsed < min) return min;
    if (parsed > max) return max;
    return parsed;
  }

  Map<String, dynamic> _buildLibraryRecommendationsPayload(
    ServerResourceSnapshot snapshot,
    ServerResourceItemSummary item, {
    required int limit,
  }) {
    final scored = <Map<String, dynamic>>[];
    for (final candidate in snapshot.items) {
      if (candidate.id == item.id || candidate.title == item.title) {
        continue;
      }
      final score = _recommendationScore(item, candidate);
      if (score <= 0) {
        continue;
      }
      scored.add({
        'item': candidate,
        'score': score,
        'reason': _recommendationReason(item, candidate),
      });
    }
    scored.sort((a, b) {
      final scoreCompare =
          (b['score'] as double).compareTo(a['score'] as double);
      if (scoreCompare != 0) return scoreCompare;
      final left = (b['item'] as ServerResourceItemSummary).updatedAt;
      final right = (a['item'] as ServerResourceItemSummary).updatedAt;
      return left.compareTo(right);
    });
    return {
      'generatedAt': DateTime.now().toIso8601String(),
      'librarySignature': _librarySignature ?? '',
      'itemId': item.id,
      'items': [
        for (final entry in scored.take(limit))
          {
            ..._buildLibraryItemPayload(
                entry['item'] as ServerResourceItemSummary),
            'reason': entry['reason'],
            'score': entry['score'],
          },
      ],
    };
  }

  double _recommendationScore(
    ServerResourceItemSummary base,
    ServerResourceItemSummary candidate,
  ) {
    var score = 0.0;
    final baseName = _recommendationNormalize(base.title);
    final candidateName = _recommendationNormalize(candidate.title);
    if (baseName.isNotEmpty && candidateName.isNotEmpty) {
      if (baseName.contains(candidateName) ||
          candidateName.contains(baseName)) {
        score += 90;
      }
      score += _bigramOverlap(baseName, candidateName) * 70;
    }
    final baseTopics = _recommendationTopics(base.title);
    final candidateTopics = _recommendationTopics(candidate.title);
    final topicMatches = baseTopics.intersection(candidateTopics).length;
    score += topicMatches * 22;
    final tagMatches =
        base.tags.toSet().intersection(candidate.tags.toSet()).length;
    score += tagMatches * 18;
    if (base.subtitle.isNotEmpty && base.subtitle == candidate.subtitle) {
      score += 28;
    }
    if (base.sourceDisplayName.isNotEmpty &&
        base.sourceDisplayName == candidate.sourceDisplayName) {
      score += 8;
    }
    return score;
  }

  String _recommendationReason(
    ServerResourceItemSummary base,
    ServerResourceItemSummary candidate,
  ) {
    final baseName = _recommendationNormalize(base.title);
    final candidateName = _recommendationNormalize(candidate.title);
    final overlap = _bigramOverlap(baseName, candidateName);
    if (overlap >= 0.62 ||
        (baseName.isNotEmpty &&
            candidateName.isNotEmpty &&
            (baseName.contains(candidateName) ||
                candidateName.contains(baseName)))) {
      return '名称高度相似';
    }
    if (overlap >= 0.32) return '名称相似';
    final tagMatches =
        base.tags.toSet().intersection(candidate.tags.toSet()).length;
    if (base.subtitle.isNotEmpty &&
        base.subtitle == candidate.subtitle &&
        tagMatches > 0) {
      return '同作者 + 同题材';
    }
    if (tagMatches > 0) return '同标签';
    return '同题材';
  }

  String _recommendationNormalize(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  }

  Set<String> _recommendationTopics(String value) {
    final normalized = value.toLowerCase();
    return RegExp(r'[a-z0-9]+|[一-鿿぀-ヿ]{2,}')
        .allMatches(normalized)
        .map((match) => match.group(0) ?? '')
        .where((token) => token.length >= 2)
        .toSet();
  }

  double _bigramOverlap(String a, String b) {
    final left = _bigrams(a);
    final right = _bigrams(b);
    if (left.isEmpty || right.isEmpty) return 0;
    final intersection = left.intersection(right).length;
    return intersection /
        (left.length < right.length ? left.length : right.length);
  }

  Set<String> _bigrams(String value) {
    if (value.length < 2) return value.isEmpty ? <String>{} : <String>{value};
    return {
      for (var i = 0; i < value.length - 1; i++) value.substring(i, i + 2),
    };
  }

  Map<String, dynamic> _buildLibraryItemPayload(
    ServerResourceItemSummary item, {
    bool includePages = false,
  }) {
    final encodedId = Uri.encodeComponent(item.id);
    return {
      'id': item.id,
      'rootId': item.rootId,
      'sourceTitle': item.sourceTitle,
      'sourceDisplayName': item.sourceDisplayName,
      'title': item.title,
      'displayId': item.displayId,
      'subtitle': item.subtitle,
      'tags': item.tags,
      'path': item.path,
      'imageCount': item.imageCount,
      'totalBytes': item.totalBytes,
      'updatedAt': item.updatedAt.toIso8601String(),
      'itemKind': item.isArchive ? 'archive' : 'directory',
      'isArchive': item.isArchive,
      'archiveEncrypted': item.archiveEncrypted,
      'archivePasswordMatched': item.archivePasswordMatched,
      'archiveFormat': item.archiveFormat,
      'coverUrl': _buildItemCoverUrl(item),
      'detailUrl': '/api/library/items/$encodedId',
      'episodeCount': item.episodes.length,
      'hasMultipleEpisodes': item.hasMultipleEpisodes,
      'episodes': item.episodes
          .map(
            (episode) => _buildLibraryEpisodePayload(
              item.id,
              episode,
              includePages: includePages,
              item: item,
            ),
          )
          .toList(),
    };
  }

  Map<String, dynamic> _buildLibraryEpisodePayload(
    String itemId,
    ServerResourceEpisodeSummary episode, {
    bool includePages = false,
    ServerResourceItemSummary? item,
  }) {
    final encodedId = Uri.encodeComponent(itemId);
    final coverUrl = item == null
        ? '/api/library/items/$encodedId/cover'
        : _buildItemCoverUrl(item);
    return {
      'index': episode.index,
      'title': episode.title,
      'path': episode.path,
      'imageCount': episode.imageCount,
      'totalBytes': episode.totalBytes,
      'coverUrl': coverUrl,
      if (includePages) ...{
        'pages': [
          for (var i = 0; i < episode.imagePaths.length; i++)
            '/api/library/items/$encodedId/images/${episode.index}/$i',
        ],
        'pageSizes': [
          for (final size in episode.imageSizes) size?.toJson(),
        ],
      },
    };
  }

  String _buildItemCoverUrl(ServerResourceItemSummary item) {
    final encodedId = Uri.encodeComponent(item.id);
    final coverVersion = _coverVersionToken(item);
    final version = Uri.encodeQueryComponent(coverVersion);
    return '/api/library/items/$encodedId/cover?v=$version';
  }

  String _coverVersionToken(ServerResourceItemSummary item) {
    if (item.isArchive) {
      return [
        item.updatedAt.millisecondsSinceEpoch,
        item.archiveFormat,
        item.archiveEncrypted ? 'encrypted' : 'plain',
        item.archivePasswordMatched ? 'unlocked' : 'locked',
      ].join(':');
    }
    final coverPath = item.coverPath?.trim() ?? '';
    if (coverPath.isEmpty) {
      return item.updatedAt.millisecondsSinceEpoch.toString();
    }
    try {
      final stat = File(coverPath).statSync();
      return '${item.updatedAt.millisecondsSinceEpoch}:${_basename(coverPath)}:${stat.modified.millisecondsSinceEpoch}:${stat.size}';
    } catch (_) {
      return '${item.updatedAt.millisecondsSinceEpoch}:${_basename(coverPath)}';
    }
  }
}
