import 'dart:convert';
import 'dart:io';

import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/server/library_trash_store.dart';
import 'package:picakeep/server/local_server_runtime.dart';

const deleteBehaviorTrash = 'trash';
const deleteBehaviorPermanent = 'permanent';
const localTrashDirectoryName = '.picakeep_trash';

String _joinTrashPath(String parent, String child) {
  return '$parent${Platform.pathSeparator}$child';
}

String _basenameTrashPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/').where((entry) => entry.isNotEmpty).toList();
  return segments.isEmpty ? normalized : segments.last;
}

String normalizeDeleteBehavior(String? value) {
  switch (value) {
    case deleteBehaviorPermanent:
      return deleteBehaviorPermanent;
    case deleteBehaviorTrash:
    default:
      return deleteBehaviorTrash;
  }
}

enum TrashItemScope {
  local,
  remote,
}

enum TrashItemKind {
  comic,
  album,
}

TrashItemKind _inferTrashItemKind(
  Map<String, dynamic> json, {
  required TrashItemScope scope,
}) {
  final rawKind = (json['itemKind'] as String? ?? '').trim();
  if (rawKind == TrashItemKind.album.name) {
    return TrashItemKind.album;
  }
  if (rawKind == TrashItemKind.comic.name) {
    return TrashItemKind.comic;
  }

  final rootId = (json['rootId'] as String? ?? '').trim();
  if (rootId.startsWith('custom_')) {
    return TrashItemKind.album;
  }

  final snapshotJson = (json['snapshotJson'] as String? ?? '').trim();
  final itemId = (json['itemId'] as String? ?? '').trim();
  if (snapshotJson.isNotEmpty && itemId.isNotEmpty) {
    final parsed = parseDownloadedItemRecordJson(itemId, snapshotJson);
    if (parsed is LocalLibraryComicItem) {
      return parsed.isAlbum ? TrashItemKind.album : TrashItemKind.comic;
    }
    if (parsed is RemoteLibraryComicItem) {
      return parsed.isCustomLibraryRoot
          ? TrashItemKind.album
          : TrashItemKind.comic;
    }
  }

  final sourceLabel = (json['sourceLabel'] as String? ?? '').trim();
  if (sourceLabel == '图集') {
    return TrashItemKind.album;
  }

  return scope == TrashItemScope.remote && rootId.startsWith('custom_')
      ? TrashItemKind.album
      : TrashItemKind.comic;
}

class TrashItemRecord {
  const TrashItemRecord({
    required this.id,
    required this.scope,
    required this.itemKind,
    required this.itemId,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.sourceLabel,
    required this.originalPath,
    required this.trashedPath,
    required this.deletedAt,
    required this.sizeBytes,
    required this.snapshotJson,
    this.rootId = '',
    this.remotePath = '',
    this.detailUrl = '',
  });

  final String id;
  final TrashItemScope scope;
  final TrashItemKind itemKind;
  final String itemId;
  final String title;
  final String subtitle;
  final String cover;
  final String sourceLabel;
  final String originalPath;
  final String trashedPath;
  final DateTime deletedAt;
  final int sizeBytes;
  final String snapshotJson;
  final String rootId;
  final String remotePath;
  final String detailUrl;

  bool get isLocal => scope == TrashItemScope.local;

  bool get isAlbum => itemKind == TrashItemKind.album;

  Map<String, dynamic> toJson() => {
        'id': id,
        'scope': scope.name,
        'itemKind': itemKind.name,
        'itemId': itemId,
        'title': title,
        'subtitle': subtitle,
        'cover': cover,
        'sourceLabel': sourceLabel,
        'originalPath': originalPath,
        'trashedPath': trashedPath,
        'deletedAt': deletedAt.toIso8601String(),
        'sizeBytes': sizeBytes,
        'snapshotJson': snapshotJson,
        'rootId': rootId,
        'remotePath': remotePath,
        'detailUrl': detailUrl,
      };

  factory TrashItemRecord.fromJson(Map<String, dynamic> json) {
    final scopeName = (json['scope'] as String? ?? '').trim();
    final scope = scopeName == TrashItemScope.remote.name
        ? TrashItemScope.remote
        : TrashItemScope.local;
    return TrashItemRecord(
      id: (json['id'] as String? ?? '').trim(),
      scope: scope,
      itemKind: _inferTrashItemKind(json, scope: scope),
      itemId: (json['itemId'] as String? ?? '').trim(),
      title: (json['title'] as String? ?? '').trim(),
      subtitle: (json['subtitle'] as String? ?? '').trim(),
      cover: (json['cover'] as String? ?? '').trim(),
      sourceLabel: (json['sourceLabel'] as String? ?? '').trim(),
      originalPath: (json['originalPath'] as String? ?? '').trim(),
      trashedPath: (json['trashedPath'] as String? ?? '').trim(),
      deletedAt: DateTime.tryParse((json['deletedAt'] as String? ?? '').trim()) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      snapshotJson: (json['snapshotJson'] as String? ?? '{}').trim(),
      rootId: (json['rootId'] as String? ?? '').trim(),
      remotePath: (json['remotePath'] as String? ?? '').trim(),
      detailUrl: (json['detailUrl'] as String? ?? '').trim(),
    );
  }
}

class DeleteItemResult {
  const DeleteItemResult._({
    required this.ok,
    this.record,
    this.error,
  });

  final bool ok;
  final TrashItemRecord? record;
  final String? error;

  factory DeleteItemResult.success([TrashItemRecord? record]) =>
      DeleteItemResult._(ok: true, record: record);

  factory DeleteItemResult.failure(String error) =>
      DeleteItemResult._(ok: false, error: error);
}

class DeleteActionTexts {
  const DeleteActionTexts({
    required this.title,
    required this.content,
    required this.confirmLabel,
  });

  final String title;
  final String content;
  final String confirmLabel;
}

DeleteActionTexts buildDeleteActionTexts({
  String? itemName,
  String itemLabel = '项目',
  int? count,
}) {
  final useTrash = TrashManager.instance.useTrashByDefault;
  final targetText = count != null
      ? '已选择的 $count 个$itemLabel'
      : itemName != null
          ? '“$itemName”'
          : itemLabel;
  if (useTrash) {
    return DeleteActionTexts(
      title: '移入回收站',
      content: '确定要将$targetText移入回收站吗？可在“我-工具-回收站”中恢复。',
      confirmLabel: '移入回收站',
    );
  }
  return DeleteActionTexts(
    title: '确认删除',
    content: count != null
        ? '确定要直接删除$targetText吗？此操作无法撤销。'
        : '确定要直接删除$targetText吗？此操作无法撤销。',
    confirmLabel: '直接删除',
  );
}

class TrashManager {
  TrashManager._();

  static final TrashManager instance = TrashManager._();

  final List<TrashItemRecord> _items = <TrashItemRecord>[];
  bool _loaded = false;

  File get _indexFile => File(_joinTrashPath(App.dataPath, 'trash_index.json'));

  File get _serverTrashIndexFile =>
      File(_joinTrashPath(App.dataPath, 'library_trash.json'));

  bool get _isServerMode =>
      normalizeAppRuntimeMode(appdata.settings[appRuntimeModeSettingIndex]) ==
      appRuntimeModeServer;

  LibraryTrashStore get _serverTrashStore =>
      LibraryTrashStore(_serverTrashIndexFile.path);

  bool _isServerTrashRecordId(String recordId) =>
      recordId.trim().startsWith('srvtrash_');

  Future<void> ensureLoaded() async {
    if (_loaded) {
      return;
    }
    await _load();
  }

  Future<List<TrashItemRecord>> listItems({TrashItemScope? scope}) async {
    await ensureLoaded();
    final items = <TrashItemRecord>[
      ...(scope == null
          ? _items
          : _items.where((item) => item.scope == scope)),
    ];
    if (scope != TrashItemScope.remote) {
      items.addAll(await _listServerLocalItems());
    }
    items.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return items;
  }

  Future<TrashItemRecord?> findById(String id) async {
    final items = await listItems();
    for (final item in items) {
      if (item.id == id) {
        return item;
      }
    }
    return null;
  }

  String get currentDeleteBehavior =>
      normalizeDeleteBehavior(appdata.settings[deleteBehaviorSettingIndex]);

  bool get useTrashByDefault => currentDeleteBehavior == deleteBehaviorTrash;

  Future<DeleteItemResult> deleteItem(DownloadedItem item) async {
    if (item is RemoteLibraryComicItem) {
      if (useTrashByDefault) {
        await item.client.trashItem(item.id);
      } else {
        await item.client.deleteItemPermanently(item.id);
      }
      App.notifyServiceRuntimeChanged();
      return DeleteItemResult.success();
    }
    if (!useTrashByDefault) {
      await _deleteLocalItemPermanently(item);
      return DeleteItemResult.success();
    }
    return _moveLocalItemToTrash(item);
  }

  Future<List<RemoteLibraryTrashItem>> listRemoteItems() async {
    final client = RemoteLibraryClient.fromCurrentSettings();
    return client.fetchTrashItems();
  }

  Future<void> restoreRemoteItem(String trashId) async {
    final client = RemoteLibraryClient.fromCurrentSettings();
    await client.restoreTrashItem(trashId);
    App.notifyServiceRuntimeChanged();
  }

  Future<void> permanentlyDeleteRemoteItem(String trashId) async {
    final client = RemoteLibraryClient.fromCurrentSettings();
    await client.purgeTrashItem(trashId);
    App.notifyServiceRuntimeChanged();
  }

  Future<void> restoreLocalItem(String recordId) async {
    if (_isServerTrashRecordId(recordId)) {
      await LocalServerRuntime.instance.restoreTrashItem(recordId);
      return;
    }
    await ensureLoaded();
    final record = _items.cast<TrashItemRecord?>().firstWhere(
          (item) => item?.id == recordId,
          orElse: () => null,
        );
    if (record == null) {
      throw StateError('trash item not found');
    }
    if (!record.isLocal) {
      throw StateError('remote trash restore is not ready');
    }

    final trashedDir = Directory(record.trashedPath);
    if (!trashedDir.existsSync()) {
      throw StateError('trashed directory not found');
    }

    final originalDir = Directory(record.originalPath);
    if (originalDir.existsSync()) {
      throw StateError('original path already exists');
    }
    originalDir.parent.createSync(recursive: true);
    await _moveDirectory(trashedDir, originalDir);

    final restored = parseDownloadedItemRecordJson(
      record.itemId,
      record.snapshotJson,
    );
    if (restored != null && !record.itemId.startsWith('local_')) {
      final manager = DownloadManager();
      await manager.init();
      manager.upsertDbRecordOnly(restored, _basenameTrashPath(record.originalPath));
    }

    _items.removeWhere((item) => item.id == recordId);
    await _save();
    App.notifyLocalDataChanged();
  }

  Future<void> permanentlyDeleteTrashItem(String recordId) async {
    if (_isServerTrashRecordId(recordId)) {
      await LocalServerRuntime.instance.purgeTrashItem(recordId);
      return;
    }
    await ensureLoaded();
    final record = _items.cast<TrashItemRecord?>().firstWhere(
          (item) => item?.id == recordId,
          orElse: () => null,
        );
    if (record == null) {
      return;
    }
    if (record.trashedPath.isNotEmpty) {
      final dir = Directory(record.trashedPath);
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    }
    _items.removeWhere((item) => item.id == recordId);
    await _save();
    App.notifyLocalDataChanged();
  }

  Future<DeleteItemResult> _moveLocalItemToTrash(DownloadedItem item) async {
    final target = await _resolveLocalDeleteTarget(item);
    if (target == null) {
      return DeleteItemResult.failure('local_path_not_found');
    }
    final sourceDir = Directory(target.originalPath);
    if (!sourceDir.existsSync()) {
      return DeleteItemResult.failure('local_path_not_found');
    }

    final sourceSizeBytes = await _computeDirectorySize(sourceDir);
    final snapshot = await _buildLocalTrashSnapshot(item, target);
    final trashRoot =
        Directory(_joinTrashPath(sourceDir.parent.path, localTrashDirectoryName));
    trashRoot.createSync(recursive: true);
    final recordId = _generateRecordId();
    final trashedPath = _joinTrashPath(trashRoot.path, recordId);
    final trashedDir = Directory(trashedPath);
    await _moveDirectory(sourceDir, trashedDir);

    if (target.downloadDbId != null) {
      final manager = DownloadManager();
      await manager.init();
      manager.deleteDbRecordOnly(target.downloadDbId!);
    }

    final record = TrashItemRecord(
      id: recordId,
      scope: TrashItemScope.local,
      itemKind: item is LocalLibraryComicItem && item.isAlbum
          ? TrashItemKind.album
          : TrashItemKind.comic,
      itemId: snapshot.itemId,
      title: item.name,
      subtitle: item.subTitle,
      cover: item.localCoverPath?.trim() ?? '',
      sourceLabel: item.sourceDisplayName,
      originalPath: target.originalPath,
      trashedPath: trashedPath,
      deletedAt: DateTime.now(),
      sizeBytes: sourceSizeBytes,
      snapshotJson: snapshot.snapshotJson,
      remotePath: '',
      detailUrl: '',
      rootId: '',
    );

    await ensureLoaded();
    _items.add(record);
    await _save();
    App.notifyLocalDataChanged();
    return DeleteItemResult.success(record);
  }

  Future<void> _deleteLocalItemPermanently(DownloadedItem item) async {
    final target = await _resolveLocalDeleteTarget(item);
    if (target == null) {
      return;
    }
    if (target.downloadDbId != null) {
      final manager = DownloadManager();
      await manager.init();
      await manager.deletePermanentlyByIds([target.downloadDbId!]);
      App.notifyLocalDataChanged();
      return;
    }
    final dir = Directory(target.originalPath);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    App.notifyLocalDataChanged();
  }

  Future<_TrashSnapshotPayload> _buildLocalTrashSnapshot(
    DownloadedItem item,
    _LocalDeleteTarget target,
  ) async {
    if (item is LocalLibraryComicItem && target.downloadDbId != null) {
      final manager = DownloadManager();
      await manager.init();
      final original = await manager.getComicOrNull(target.downloadDbId!);
      if (original != null) {
        return _TrashSnapshotPayload(
          itemId: original.id,
          snapshotJson: jsonEncode(original.toJson()),
        );
      }
    }
    return _TrashSnapshotPayload(
      itemId: target.restoreItemId,
      snapshotJson: jsonEncode(item.toJson()),
    );
  }

  Future<_LocalDeleteTarget?> _resolveLocalDeleteTarget(DownloadedItem item) async {
    if (item is LocalLibraryComicItem) {
      final path = item.fileSystemPath?.trim() ?? '';
      if (path.isEmpty) {
        return null;
      }
      return _LocalDeleteTarget(
        originalPath: path,
        downloadDbId: item.isManagedDownloadItem ? item.originalId.trim() : null,
        restoreItemId: item.isManagedDownloadItem ? item.originalId.trim() : item.id,
      );
    }

    final manager = DownloadManager();
    await manager.init();
    final directory = manager.getDirectory(item.id).trim();
    if (directory.isEmpty || (manager.path?.trim().isEmpty ?? true)) {
      return null;
    }
    return _LocalDeleteTarget(
      originalPath: _joinTrashPath(manager.path!, directory),
      downloadDbId: item.id,
      restoreItemId: item.id,
    );
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

  Future<void> _load() async {
    _items.clear();
    final file = _indexFile;
    if (!file.existsSync()) {
      _loaded = true;
      return;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        _items.addAll(decoded.whereType<Map>().map(
              (item) => TrashItemRecord.fromJson(
                item.map((key, value) => MapEntry(key.toString(), value)),
              ),
            ));
      }
    } catch (_) {}
    _loaded = true;
  }

  Future<void> _save() async {
    _indexFile.parent.createSync(recursive: true);
    await _indexFile.writeAsString(
      jsonEncode(_items.map((item) => item.toJson()).toList()),
    );
  }

  String _generateRecordId() =>
      'trash_${DateTime.now().microsecondsSinceEpoch}_${_items.length}';

  Future<void> _moveDirectory(Directory source, Directory target) async {
    target.parent.createSync(recursive: true);
    try {
      await source.rename(target.path);
      return;
    } catch (_) {}
    await _copyDirectory(source, target);
    if (source.existsSync()) {
      await source.delete(recursive: true);
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    destination.createSync(recursive: true);
    await for (final entity in source.list(recursive: false)) {
      if (entity is Directory) {
        await _copyDirectory(
          entity,
          Directory(_joinTrashPath(destination.path, _basenameTrashPath(entity.path))),
        );
      } else if (entity is File) {
        await entity.copy(_joinTrashPath(destination.path, _basenameTrashPath(entity.path)));
      }
    }
  }

  Future<int> _computeDirectorySize(Directory dir) async {
    var total = 0;
    if (!dir.existsSync()) {
      return total;
    }
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  }
}

class _LocalDeleteTarget {
  const _LocalDeleteTarget({
    required this.originalPath,
    required this.restoreItemId,
    this.downloadDbId,
  });

  final String originalPath;
  final String restoreItemId;
  final String? downloadDbId;
}

class _TrashSnapshotPayload {
  const _TrashSnapshotPayload({
    required this.itemId,
    required this.snapshotJson,
  });

  final String itemId;
  final String snapshotJson;
}
