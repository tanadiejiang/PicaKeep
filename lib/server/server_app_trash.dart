part of 'server_app.dart';

extension ServerAppTrash on PicaKeepAdminServer {
  Future<LibraryTrashEntry> restoreTrashItem(String trashId) async {
    final restored = await _trashStore.restoreItem(trashId);
    await rescanResources();
    _state.addLog('trash', '已恢复 ${restored.title}');
    return restored;
  }

  Future<LibraryTrashEntry?> purgeTrashItem(String trashId) async {
    final deleted = await _trashStore.purgeItem(trashId);
    if (deleted == null) {
      return null;
    }
    await rescanResources();
    _state.addLog('trash', '已彻底删除 ${deleted.title}');
    return deleted;
  }

  Future<Map<String, dynamic>> batchRestoreTrashItems(
    Iterable<String> trashIds,
  ) async {
    final ids = _normalizedIdList(trashIds);
    final succeeded = <String>[];
    final failed = <Map<String, String>>[];
    for (final trashId in ids) {
      try {
        if (_isServerTrashId(trashId)) {
          await _trashStore.restoreItem(trashId);
        } else {
          final record = await LocalTrashStore.instance.find(trashId);
          if (record == null || !_shouldExposeLocalTrashRecord(record)) {
            throw StateError('trash item not found');
          }
          await TrashManager.instance.restoreLocalItem(trashId);
        }
        succeeded.add(trashId);
      } catch (e) {
        failed.add({'id': trashId, 'error': e.toString()});
      }
    }
    if (succeeded.isNotEmpty) {
      await rescanResources();
      _state.addLog('trash', '批量恢复 ${succeeded.length} 项');
    }
    return _buildBatchResult(ids, succeeded, failed);
  }

  Future<Map<String, dynamic>> batchPurgeTrashItems(
    Iterable<String> trashIds,
  ) async {
    final ids = _normalizedIdList(trashIds);
    final succeeded = <String>[];
    final failed = <Map<String, String>>[];
    for (final trashId in ids) {
      try {
        if (_isServerTrashId(trashId)) {
          final deleted = await _trashStore.purgeItem(trashId);
          if (deleted == null) {
            throw StateError('trash item not found');
          }
        } else {
          final record = await LocalTrashStore.instance.find(trashId);
          if (record == null || !_shouldExposeLocalTrashRecord(record)) {
            throw StateError('trash item not found');
          }
          await TrashManager.instance.permanentlyDeleteTrashItem(trashId);
        }
        succeeded.add(trashId);
      } catch (e) {
        failed.add({'id': trashId, 'error': e.toString()});
      }
    }
    if (succeeded.isNotEmpty) {
      await rescanResources();
      _state.addLog('trash', '批量彻底删除 ${succeeded.length} 项');
    }
    return _buildBatchResult(ids, succeeded, failed);
  }

  Future<Map<String, dynamic>> batchTrashItems(Iterable<String> itemIds) async {
    final ids = _normalizedIdList(itemIds);
    final snapshot = await _currentSnapshot();
    final succeeded = <String>[];
    final failed = <Map<String, String>>[];
    for (final itemId in ids) {
      try {
        final item = snapshot.findItemById(itemId);
        if (item == null) {
          throw StateError('item not found');
        }
        final rootPath = _rootPathForRootId(item.rootId);
        if (rootPath == null || rootPath.trim().isEmpty) {
          throw StateError('root path not found');
        }
        await _trashStore.moveItemToTrash(item: item, rootPath: rootPath);
        await _deleteManagedDownloadDbRow(item);
        succeeded.add(itemId);
      } catch (e) {
        failed.add({'id': itemId, 'error': e.toString()});
      }
    }
    if (succeeded.isNotEmpty) {
      await rescanResources();
      _state.addLog('trash', '批量移入回收站 ${succeeded.length} 项');
    }
    return _buildBatchResult(ids, succeeded, failed);
  }

  Future<Map<String, dynamic>> batchDeleteItemsPermanently(
    Iterable<String> itemIds,
  ) async {
    final ids = _normalizedIdList(itemIds);
    final snapshot = await _currentSnapshot();
    final succeeded = <String>[];
    final failed = <Map<String, String>>[];
    for (final itemId in ids) {
      try {
        final item = snapshot.findItemById(itemId);
        if (item == null) {
          throw StateError('item not found');
        }
        final dir = Directory(item.path);
        if (dir.existsSync()) {
          await dir.delete(recursive: true);
        }
        await _deleteManagedDownloadDbRow(item);
        succeeded.add(itemId);
      } catch (e) {
        failed.add({'id': itemId, 'error': e.toString()});
      }
    }
    if (succeeded.isNotEmpty) {
      await rescanResources();
      _state.addLog('trash', '批量直接删除 ${succeeded.length} 项');
    }
    return _buildBatchResult(ids, succeeded, failed);
  }

  List<String> _normalizedIdList(Iterable<String> ids) {
    final result = <String>[];
    final seen = <String>{};
    for (final id in ids) {
      final normalized = id.trim();
      if (normalized.isEmpty || !seen.add(normalized)) {
        continue;
      }
      result.add(normalized);
    }
    return result;
  }

  Map<String, dynamic> _buildBatchResult(
    List<String> requested,
    List<String> succeeded,
    List<Map<String, String>> failed,
  ) {
    return {
      'ok': failed.isEmpty,
      'requested': requested.length,
      'succeeded': succeeded.length,
      'succeededIds': succeeded,
      'failed': failed,
    };
  }

  bool _isServerTrashId(String trashId) =>
      trashId.trim().startsWith('srvtrash_');

  Future<Response?> _handleTrashRequest(Request request) async {
    final segments = request.url.pathSegments;
    if (segments.length < 3 ||
        segments[0] != 'api' ||
        segments[1] != 'library' ||
        segments[2] != 'trash') {
      return null;
    }

    if (segments.length == 3) {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      return _jsonResponse({
        'items': await _buildCombinedTrashItemsPayload(),
      });
    }

    if (segments.length == 4 && segments[3] == 'batch-restore') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final ids = await _readStringListFromBody(request, 'trashIds');
      return _jsonResponse(await batchRestoreTrashItems(ids));
    }

    if (segments.length == 4 && segments[3] == 'batch-purge') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final ids = await _readStringListFromBody(request, 'trashIds');
      return _jsonResponse(await batchPurgeTrashItems(ids));
    }

    // request.url.pathSegments is already percent-decoded by Uri; calling
    // Uri.decodeComponent on it again is a double-decode that throws
    // "Illegal percent encoding" on multi-byte characters (e.g. CJK folder
    // names like "%E4%B8%AD..."). Use the segment as-is.
    final trashId = segments[3];

    if (segments.length == 5 && segments[4] == 'cover') {
      if (request.method != 'GET') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      final coverFile = await _trashCoverFileForId(trashId);
      if (coverFile == null || coverFile.path.trim().isEmpty) {
        return _jsonResponse({'error': 'cover not found'}, statusCode: 404);
      }
      return _fileResponse(request, coverFile.path);
    }

    if (segments.length == 5 && segments[4] == 'restore') {
      if (request.method != 'POST') {
        return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
      }
      if (_isServerTrashId(trashId)) {
        final restored = await restoreTrashItem(trashId);
        return _jsonResponse({
          'ok': true,
          'item': _buildTrashItemPayload(restored),
        });
      }
      final record = await LocalTrashStore.instance.find(trashId);
      if (record == null || !_shouldExposeLocalTrashRecord(record)) {
        return _jsonResponse({'error': 'trash item not found'},
            statusCode: 404);
      }
      await TrashManager.instance.restoreLocalItem(trashId);
      await rescanResources();
      return _jsonResponse({'ok': true});
    }

    if (segments.length == 4 && request.method == 'DELETE') {
      if (_isServerTrashId(trashId)) {
        final deleted = await purgeTrashItem(trashId);
        if (deleted == null) {
          return _jsonResponse({'error': 'trash item not found'},
              statusCode: 404);
        }
        return _jsonResponse({'ok': true});
      }
      final record = await LocalTrashStore.instance.find(trashId);
      if (record == null || !_shouldExposeLocalTrashRecord(record)) {
        return _jsonResponse({'error': 'trash item not found'},
            statusCode: 404);
      }
      await TrashManager.instance.permanentlyDeleteTrashItem(trashId);
      await rescanResources();
      return _jsonResponse({'ok': true});
    }

    return _jsonResponse({'error': 'not found'}, statusCode: 404);
  }

  Map<String, dynamic> _buildTrashItemPayload(LibraryTrashEntry entry) {
    final encodedId = Uri.encodeComponent(entry.id);
    return {
      'id': entry.id,
      'itemId': entry.itemId,
      'rootId': entry.rootId,
      'itemKind': entry.itemKind,
      'title': entry.title,
      'subtitle': entry.subtitle,
      'sourceDisplayName': entry.sourceDisplayName,
      'tags': entry.tags,
      'originalPath': entry.originalPath,
      'imageCount': entry.imageCount,
      'totalBytes': entry.totalBytes,
      'deletedAt': entry.deletedAt.toIso8601String(),
      'coverUrl': '/api/library/trash/$encodedId/cover',
      'source': 'server',
    };
  }
}
