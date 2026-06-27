part of 'trash.dart';

extension TrashManagerRemote on TrashManager {
  Future<List<RemoteLibraryTrashItem>> listRemoteItems() async {
    final client = RemoteLibraryClient.fromCurrentSettings();
    return client.fetchTrashItems();
  }

  Future<void> restoreRemoteItem(String trashId) async {
    final client = RemoteLibraryClient.fromCurrentSettings();
    await client.restoreTrashItem(trashId);
    App.notifyServiceRuntimeChanged();
  }

  Future<RemoteLibraryBatchResult> deleteRemoteItems(
    Iterable<RemoteLibraryComicItem> items,
  ) async {
    final targets = items.toList(growable: false);
    if (targets.isEmpty) {
      return RemoteLibraryBatchResult.allSucceeded(0);
    }
    final client = targets.first.client;
    final result = useTrashByDefault
        ? await client.trashItems(targets.map((item) => item.id))
        : await client.deleteItemsPermanently(targets.map((item) => item.id));
    App.notifyServiceRuntimeChanged();
    _throwIfRemoteBatchFailed(result);
    return result;
  }

  Future<RemoteLibraryBatchResult> restoreRemoteItems(
    Iterable<String> trashIds,
  ) async {
    final ids = trashIds.toList(growable: false);
    final client = RemoteLibraryClient.fromCurrentSettings();
    final result = await client.restoreTrashItems(ids);
    App.notifyServiceRuntimeChanged();
    _throwIfRemoteBatchFailed(result);
    return result;
  }

  Future<RemoteLibraryBatchResult> permanentlyDeleteRemoteItems(
    Iterable<String> trashIds,
  ) async {
    final ids = trashIds.toList(growable: false);
    final client = RemoteLibraryClient.fromCurrentSettings();
    final result = await client.purgeTrashItems(ids);
    App.notifyServiceRuntimeChanged();
    _throwIfRemoteBatchFailed(result);
    return result;
  }

  void _throwIfRemoteBatchFailed(RemoteLibraryBatchResult result) {
    if (result.ok) {
      return;
    }
    final firstError = result.failed.isEmpty
        ? '远程批量操作部分失败'
        : (result.failed.first['error'] ?? '远程批量操作部分失败');
    throw StateError(firstError);
  }

  Future<void> permanentlyDeleteRemoteItem(String trashId) async {
    final client = RemoteLibraryClient.fromCurrentSettings();
    await client.purgeTrashItem(trashId);
    App.notifyServiceRuntimeChanged();
  }

  Future<List<TrashItemRecord>> _listServerLocalItems() async {
    if (!_isServerMode) {
      return const <TrashItemRecord>[];
    }
    final entries = await _serverTrashStore.listEntries();
    return entries
        .map((entry) => TrashItemRecord(
              id: entry.id,
              scope: TrashItemScope.local,
              itemKind: entry.itemKind == TrashItemKind.album.name
                  ? TrashItemKind.album
                  : TrashItemKind.comic,
              itemId: entry.itemId,
              title: entry.title,
              subtitle: entry.subtitle,
              cover: _serverTrashStore.coverFileFor(entry).path,
              coverRelativePath: entry.coverRelativePath,
              sourceLabel: entry.sourceDisplayName,
              originalPath: entry.originalPath,
              trashedPath: entry.trashedPath,
              deletedAt: entry.deletedAt,
              sizeBytes: entry.totalBytes,
              snapshotJson: '{}',
              rootId: entry.rootId,
              remotePath: '',
              detailUrl: '',
            ))
        .toList(growable: false);
  }
}
