import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/local_trash_store.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/server/library_trash_store.dart';
import 'package:picakeep/server/local_server_runtime.dart';
import 'package:picakeep/tools/read_history_helper.dart';
import 'package:sqlite3/sqlite3.dart';

const deleteBehaviorTrash = 'trash';
const deleteBehaviorPermanent = 'permanent';
const localTrashDirectoryName = '.picakeep_trash';
const deleteFailureLocalPathNotFound = 'local_path_not_found';
const deleteFailurePermissionDenied = 'permission_denied';
const _storageAccessChannelName = 'lingxue.picakeep/storage_access';
const _androidApplicationId = 'lingxue.picakeep';

const MethodChannel _storageAccessChannel =
    MethodChannel(_storageAccessChannelName);

enum _PrivilegedWriteMode {
  root,
  shizuku,
}

String _joinTrashPath(String parent, String child) {
  return '$parent${Platform.pathSeparator}$child';
}

bool _isImageTrashPath(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.bmp');
}

String _relativeTrashPathIfInside(String rootPath, String filePath) {
  final root = rootPath.trim();
  final file = filePath.trim();
  if (root.isEmpty || file.isEmpty) {
    return '';
  }
  final normalizedRoot = _normalizeAndroidStoragePath(root);
  final normalizedFile = _normalizeAndroidStoragePath(file);
  final lowerRoot = normalizedRoot.toLowerCase();
  final lowerFile = normalizedFile.toLowerCase();
  if (lowerFile == lowerRoot) {
    return '';
  }
  final prefix = '$lowerRoot/';
  if (!lowerFile.startsWith(prefix)) {
    return '';
  }
  return normalizedFile.substring(normalizedRoot.length + 1);
}

String _joinTrashRelativePath(String rootPath, String relativePath) {
  final parts = relativePath
      .replaceAll('\\', '/')
      .split('/')
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty)
      .toList(growable: false);
  var current = rootPath;
  for (final part in parts) {
    current = _joinTrashPath(current, part);
  }
  return current;
}

String _firstImageInTrashDirectory(String rootPath) {
  final root = Directory(rootPath);
  if (!root.existsSync()) {
    return '';
  }
  try {
    final entities = root.listSync(recursive: true, followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entities) {
      if (entity is File && _isImageTrashPath(entity.path)) {
        return entity.path;
      }
    }
  } catch (_) {}
  return '';
}

String resolveLocalTrashCoverPath({
  required String trashedPath,
  required String coverRelativePath,
  required String cover,
}) {
  final root = trashedPath.trim();
  final relative = coverRelativePath.trim();
  if (root.isNotEmpty && relative.isNotEmpty) {
    final file = File(_joinTrashRelativePath(root, relative));
    if (file.existsSync()) {
      return file.path;
    }
  }

  final fallback = cover.trim();
  if (fallback.isNotEmpty) {
    final file = File(fallback);
    if (file.existsSync()) {
      return file.path;
    }
    if (root.isNotEmpty) {
      final relativeFromFallback = _relativeTrashPathIfInside(root, fallback);
      if (relativeFromFallback.isNotEmpty) {
        final remapped =
            File(_joinTrashRelativePath(root, relativeFromFallback));
        if (remapped.existsSync()) {
          return remapped.path;
        }
      }
      final byName = File(_joinTrashPath(root, _basenameTrashPath(fallback)));
      if (byName.existsSync()) {
        return byName.path;
      }
    }
  }

  if (root.isNotEmpty) {
    for (final name in const [
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
      'cover.webp',
    ]) {
      final file = File(_joinTrashPath(root, name));
      if (file.existsSync()) {
        return file.path;
      }
    }
    return _firstImageInTrashDirectory(root);
  }

  return '';
}

String _basenameTrashPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments =
      normalized.split('/').where((entry) => entry.isNotEmpty).toList();
  return segments.isEmpty ? normalized : segments.last;
}

String _normalizeAndroidStoragePath(String path) {
  var normalized = path.trim().replaceAll('\\', '/');
  while (normalized.contains('//')) {
    normalized = normalized.replaceAll('//', '/');
  }
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

bool _shouldForcePrivilegedIo(String path) {
  if (!App.isAndroid) {
    return false;
  }
  final normalized = _normalizeAndroidStoragePath(path);
  final segments =
      normalized.split('/').where((entry) => entry.isNotEmpty).toList();
  final androidIndex = segments.indexOf('Android');
  if (androidIndex < 0 || androidIndex + 2 >= segments.length) {
    return false;
  }
  final container = segments[androidIndex + 1];
  if (container != 'data' && container != 'obb') {
    return false;
  }
  final packageName = segments[androidIndex + 2];
  return packageName.isNotEmpty && packageName != _androidApplicationId;
}

bool _sameNormalizedPath(String left, String right) {
  final normalizedLeft = _normalizeAndroidStoragePath(left).toLowerCase();
  final normalizedRight = _normalizeAndroidStoragePath(right).toLowerCase();
  return normalizedLeft.isNotEmpty && normalizedLeft == normalizedRight;
}

bool _isUnsafeLocalDeleteRoot(String originalPath, String? sourceDbPath) {
  final sourceDb = sourceDbPath?.trim() ?? '';
  if (sourceDb.isEmpty) {
    return false;
  }
  final dbParent = File(sourceDb).parent.path;
  if (_sameNormalizedPath(originalPath, dbParent)) {
    return true;
  }
  final dbGrandParent = File(dbParent).parent.path;
  return _shouldForcePrivilegedIo(originalPath) &&
      _sameNormalizedPath(originalPath, dbGrandParent);
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

enum _LocalPathState {
  exists,
  missing,
  permissionDenied,
}

Future<bool> _hasRootAccess({
  bool forceRefresh = false,
}) async {
  if (!App.isAndroid) {
    return false;
  }
  try {
    return await _storageAccessChannel.invokeMethod<bool>(
          'hasRootAccess',
          {'forceRefresh': forceRefresh},
        ) ??
        false;
  } catch (_) {
    return false;
  }
}

Future<bool> _hasShizukuPermission({
  bool forceRefresh = false,
}) async {
  if (!App.isAndroid) {
    return false;
  }
  try {
    return await _storageAccessChannel.invokeMethod<bool>(
          'hasShizukuPermission',
          {'forceRefresh': forceRefresh},
        ) ??
        false;
  } catch (_) {
    return false;
  }
}

List<_PrivilegedWriteMode> _enabledPrivilegedWriteModes() {
  if (!App.isAndroid) {
    return const [];
  }
  final modes = <_PrivilegedWriteMode>[];
  if (normalizeAndroidRootMode(appdata.settings[androidRootModeSettingIndex]) ==
      '1') {
    modes.add(_PrivilegedWriteMode.root);
  }
  if (normalizeAndroidShizukuMode(
          appdata.settings[androidShizukuModeSettingIndex]) ==
      '1') {
    modes.add(_PrivilegedWriteMode.shizuku);
  }
  return modes;
}

Future<_PrivilegedWriteMode?> _resolvePrivilegedWriteMode({
  bool forceRefresh = false,
}) async {
  if (!App.isAndroid) {
    return null;
  }
  for (final mode in _enabledPrivilegedWriteModes()) {
    switch (mode) {
      case _PrivilegedWriteMode.root:
        if (await _hasRootAccess(forceRefresh: forceRefresh)) {
          return mode;
        }
        break;
      case _PrivilegedWriteMode.shizuku:
        if (await _hasShizukuPermission(forceRefresh: forceRefresh)) {
          return mode;
        }
        break;
    }
  }
  return null;
}

Future<_PrivilegedWriteMode?> _resolvePrivilegedWriteModeForOperation() async {
  final mode = await _resolvePrivilegedWriteMode();
  if (mode != null) {
    return mode;
  }
  if (_enabledPrivilegedWriteModes().isEmpty) {
    return null;
  }
  return _resolvePrivilegedWriteMode(forceRefresh: true);
}

Future<bool> _privilegedPathExists(
  String path, {
  required _PrivilegedWriteMode mode,
}) async {
  if (!App.isAndroid) {
    return false;
  }
  try {
    final method = switch (mode) {
      _PrivilegedWriteMode.root => 'existsWithRoot',
      _PrivilegedWriteMode.shizuku => 'existsWithShizuku',
    };
    return await _storageAccessChannel.invokeMethod<bool>(
          method,
          {'path': path},
        ) ??
        false;
  } catch (_) {
    return false;
  }
}

Future<void> _privilegedDeletePath(
  String path, {
  required _PrivilegedWriteMode mode,
}) async {
  final method = switch (mode) {
    _PrivilegedWriteMode.root => 'deletePathWithRoot',
    _PrivilegedWriteMode.shizuku => 'deletePathWithShizuku',
  };
  await _storageAccessChannel.invokeMethod<void>(
    method,
    {'path': path},
  );
}

Future<Uint8List?> _privilegedReadFileBytes(
  String path, {
  required _PrivilegedWriteMode mode,
}) async {
  final method = switch (mode) {
    _PrivilegedWriteMode.root => 'readFileWithRoot',
    _PrivilegedWriteMode.shizuku => 'readFileWithShizuku',
  };
  final result = await _storageAccessChannel.invokeMethod<Object>(
    method,
    {'path': path},
  );
  if (result is Uint8List) {
    return result;
  }
  if (result is ByteData) {
    return result.buffer.asUint8List();
  }
  if (result is List) {
    return Uint8List.fromList(result.cast<int>());
  }
  return null;
}

Future<void> _privilegedWriteFileBytes(
  String path,
  Uint8List bytes, {
  required _PrivilegedWriteMode mode,
}) async {
  final method = switch (mode) {
    _PrivilegedWriteMode.root => 'writeFileWithRoot',
    _PrivilegedWriteMode.shizuku => 'writeFileWithShizuku',
  };
  await _storageAccessChannel.invokeMethod<void>(
    method,
    {'path': path, 'bytes': bytes},
  );
}

Future<void> _privilegedMovePath(
  String sourcePath,
  String targetPath, {
  required _PrivilegedWriteMode mode,
}) async {
  final method = switch (mode) {
    _PrivilegedWriteMode.root => 'movePathWithRoot',
    _PrivilegedWriteMode.shizuku => 'movePathWithShizuku',
  };
  await _storageAccessChannel.invokeMethod<void>(
    method,
    {'sourcePath': sourcePath, 'targetPath': targetPath},
  );
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
    this.coverRelativePath = '',
    required this.sourceLabel,
    required this.originalPath,
    required this.trashedPath,
    required this.deletedAt,
    required this.sizeBytes,
    required this.snapshotJson,
    this.rootId = '',
    this.remotePath = '',
    this.detailUrl = '',
    this.sourceDbPath = '',
    this.sourceDbId = '',
    this.sourceDirectory = '',
    this.sourceDbRowId = 0,
    this.sourceDbTimeMillis = 0,
    this.sourceDbRecordRemoved = false,
  });

  final String id;
  final TrashItemScope scope;
  final TrashItemKind itemKind;
  final String itemId;
  final String title;
  final String subtitle;
  final String cover;
  final String coverRelativePath;
  final String sourceLabel;
  final String originalPath;
  final String trashedPath;
  final DateTime deletedAt;
  final int sizeBytes;
  final String snapshotJson;
  final String rootId;
  final String remotePath;
  final String detailUrl;
  final String sourceDbPath;
  final String sourceDbId;
  final String sourceDirectory;
  final int sourceDbRowId;
  final int sourceDbTimeMillis;
  final bool sourceDbRecordRemoved;

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
        'coverRelativePath': coverRelativePath,
        'sourceLabel': sourceLabel,
        'originalPath': originalPath,
        'trashedPath': trashedPath,
        'deletedAt': deletedAt.toIso8601String(),
        'sizeBytes': sizeBytes,
        'snapshotJson': snapshotJson,
        'rootId': rootId,
        'remotePath': remotePath,
        'detailUrl': detailUrl,
        'sourceDbPath': sourceDbPath,
        'sourceDbId': sourceDbId,
        'sourceDirectory': sourceDirectory,
        'sourceDbRowId': sourceDbRowId,
        'sourceDbTimeMillis': sourceDbTimeMillis,
        'sourceDbRecordRemoved': sourceDbRecordRemoved,
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
      coverRelativePath: (json['coverRelativePath'] as String? ??
              (json['cover_relative_path'] as String? ?? ''))
          .trim(),
      sourceLabel: (json['sourceLabel'] as String? ?? '').trim(),
      originalPath: (json['originalPath'] as String? ?? '').trim(),
      trashedPath: (json['trashedPath'] as String? ?? '').trim(),
      deletedAt:
          DateTime.tryParse((json['deletedAt'] as String? ?? '').trim()) ??
              DateTime.fromMillisecondsSinceEpoch(0),
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      snapshotJson: (json['snapshotJson'] as String? ?? '{}').trim(),
      rootId: (json['rootId'] as String? ?? '').trim(),
      remotePath: (json['remotePath'] as String? ?? '').trim(),
      detailUrl: (json['detailUrl'] as String? ?? '').trim(),
      sourceDbPath: (json['sourceDbPath'] as String? ?? '').trim(),
      sourceDbId: (json['sourceDbId'] as String? ?? '').trim(),
      sourceDirectory: (json['sourceDirectory'] as String? ?? '').trim(),
      sourceDbRowId: (json['sourceDbRowId'] as num?)?.toInt() ?? 0,
      sourceDbTimeMillis: (json['sourceDbTimeMillis'] as num?)?.toInt() ?? 0,
      sourceDbRecordRemoved: json['sourceDbRecordRemoved'] == true ||
          json['sourceDbRecordRemoved'] == 1,
    );
  }

  factory TrashItemRecord.fromLocalStore(LocalTrashRecordData data) {
    return TrashItemRecord(
      id: data.id,
      scope: TrashItemScope.local,
      itemKind: data.itemKind == TrashItemKind.album.name
          ? TrashItemKind.album
          : TrashItemKind.comic,
      itemId: data.itemId,
      title: data.title,
      subtitle: data.subtitle,
      cover: data.cover,
      coverRelativePath: data.coverRelativePath,
      sourceLabel: data.sourceLabel,
      originalPath: data.originalPath,
      trashedPath: data.trashedPath,
      deletedAt: DateTime.fromMillisecondsSinceEpoch(data.deletedAtMillis),
      sizeBytes: data.sizeBytes,
      snapshotJson: data.snapshotJson,
      rootId: data.rootId,
      remotePath: data.remotePath,
      detailUrl: data.detailUrl,
      sourceDbPath: data.sourceDbPath,
      sourceDbId: data.sourceDbId,
      sourceDirectory: data.sourceDirectory,
      sourceDbRowId: data.sourceDbRowId,
      sourceDbTimeMillis: data.sourceDbTimeMillis,
      sourceDbRecordRemoved: data.sourceDbRecordRemoved,
    );
  }

  LocalTrashRecordData toLocalStoreData(
      {String state = localTrashStateTrashed}) {
    return LocalTrashRecordData(
      id: id,
      state: state,
      itemKind: itemKind.name,
      itemId: itemId,
      title: title,
      subtitle: subtitle,
      cover: cover,
      coverRelativePath: coverRelativePath,
      sourceLabel: sourceLabel,
      originalPath: originalPath,
      trashedPath: trashedPath,
      deletedAtMillis: deletedAt.millisecondsSinceEpoch,
      sizeBytes: sizeBytes,
      snapshotJson: snapshotJson,
      rootId: rootId,
      remotePath: remotePath,
      detailUrl: detailUrl,
      sourceDbPath: sourceDbPath,
      sourceDbId: sourceDbId,
      sourceDirectory: sourceDirectory,
      sourceDbRowId: sourceDbRowId,
      sourceDbTimeMillis: sourceDbTimeMillis,
      sourceDbRecordRemoved: sourceDbRecordRemoved,
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

String deleteFailureMessage(String? error) {
  switch (error) {
    case deleteFailurePermissionDenied:
      return '当前路径权限不足，无法删除。请检查 Shizuku 授权 / Root 模式，或改用可访问目录。';
    case deleteFailureLocalPathNotFound:
      return '未找到可删除的本地目录或下载记录。';
    case 'delete_failed':
    case null:
      return '删除失败';
    default:
      return error;
  }
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
      ...(scope == null ? _items : _items.where((item) => item.scope == scope)),
    ];
    if (scope != TrashItemScope.remote) {
      items.addAll(
        (await LocalTrashStore.instance.listTrashed())
            .map(TrashItemRecord.fromLocalStore),
      );
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
      final error = await _deleteLocalItemPermanently(item);
      if (error != null) {
        return DeleteItemResult.failure(error);
      }
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

  Future<void> restoreLocalItem(String recordId) async {
    if (_isServerTrashRecordId(recordId)) {
      final restored =
          await LocalServerRuntime.instance.restoreTrashItem(recordId);
      await _evictRestoredLocalImageCachesForPath(
        restored.originalPath,
        coverRelativePath: restored.coverRelativePath,
      );
      App.notifyLocalDataChanged();
      return;
    }
    final storedRecord = await LocalTrashStore.instance.find(recordId);
    if (storedRecord != null && storedRecord.state == localTrashStateTrashed) {
      await _restoreStoredLocalItem(
          TrashItemRecord.fromLocalStore(storedRecord));
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
    final trashedExists = await _resolveLocalPathState(trashedDir);
    if (trashedExists == _LocalPathState.permissionDenied) {
      throw StateError(deleteFailurePermissionDenied);
    }
    if (trashedExists == _LocalPathState.missing) {
      throw StateError('trashed directory not found');
    }

    final originalDir = Directory(record.originalPath);
    final originalState = await _resolveLocalPathState(originalDir);
    if (originalState == _LocalPathState.permissionDenied) {
      throw StateError(deleteFailurePermissionDenied);
    }
    if (originalState == _LocalPathState.exists) {
      throw StateError('original path already exists');
    }
    final mustUsePrivileged = _shouldForcePrivilegedIo(record.trashedPath) ||
        _shouldForcePrivilegedIo(record.originalPath);
    if (!mustUsePrivileged && trashedDir.existsSync()) {
      originalDir.parent.createSync(recursive: true);
      await _moveDirectory(trashedDir, originalDir);
    } else {
      final mode = await _resolvePrivilegedWriteModeForOperation();
      if (mode == null) {
        throw StateError(deleteFailurePermissionDenied);
      }
      await _privilegedMovePath(
        record.trashedPath,
        record.originalPath,
        mode: mode,
      );
    }

    final directory = record.sourceDirectory.trim().isNotEmpty
        ? record.sourceDirectory.trim()
        : _basenameTrashPath(record.originalPath);
    final sourceDbId = record.sourceDbId.trim().isNotEmpty
        ? record.sourceDbId.trim()
        : record.itemId.trim();
    final repairedSnapshotJson = await _repairRestoredSnapshotJson(
      record,
      directory: directory,
      sourceDbId: sourceDbId,
    );
    final restored = parseDownloadedItemRecordJson(
      sourceDbId,
      repairedSnapshotJson,
      directory: directory,
    );
    if (restored != null && !record.itemId.startsWith('local_')) {
      final manager = DownloadManager();
      await manager.init();
      manager.upsertDbRecordOnly(
        restored,
        directory,
        record.sourceDbTimeMillis > 0
            ? DateTime.fromMillisecondsSinceEpoch(record.sourceDbTimeMillis)
            : record.deletedAt,
        record.sourceDbRowId > 0 ? record.sourceDbRowId : null,
      );
    }

    _items.removeWhere((item) => item.id == recordId);
    await _save();
    if (_isServerMode) {
      LocalServerRuntime.instance.markResourceStateDirty();
    }
    await _evictRestoredLocalImageCachesForRecord(record);
    App.notifyLocalDataChanged();
  }

  Future<void> permanentlyDeleteTrashItem(String recordId) async {
    if (_isServerTrashRecordId(recordId)) {
      await LocalServerRuntime.instance.purgeTrashItem(recordId);
      return;
    }
    final storedRecord = await LocalTrashStore.instance.find(recordId);
    if (storedRecord != null && storedRecord.state == localTrashStateTrashed) {
      final record = TrashItemRecord.fromLocalStore(storedRecord);
      if (record.trashedPath.isNotEmpty) {
        final dir = Directory(record.trashedPath);
        final dirState = await _resolveLocalPathState(dir);
        if (dirState == _LocalPathState.permissionDenied) {
          throw StateError(deleteFailurePermissionDenied);
        }
        if (dirState == _LocalPathState.exists) {
          final mustUsePrivileged =
              _shouldForcePrivilegedIo(record.trashedPath);
          if (!mustUsePrivileged && dir.existsSync()) {
            await dir.delete(recursive: true);
          } else {
            final mode = await _resolvePrivilegedWriteModeForOperation();
            if (mode == null) {
              throw StateError(deleteFailurePermissionDenied);
            }
            await _privilegedDeletePath(record.trashedPath, mode: mode);
          }
        }
      }
      if (record.sourceDbPath.trim().isNotEmpty ||
          record.sourceDbId.trim().isNotEmpty) {
        await LocalTrashStore.instance.markPurged(recordId);
      } else {
        await LocalTrashStore.instance.delete(recordId);
      }
      if (_isServerMode) {
        LocalServerRuntime.instance.markResourceStateDirty();
      }
      App.notifyLocalDataChanged();
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
      final dirState = await _resolveLocalPathState(dir);
      if (dirState == _LocalPathState.permissionDenied) {
        throw StateError(deleteFailurePermissionDenied);
      }
      if (dirState == _LocalPathState.exists) {
        final mustUsePrivileged = _shouldForcePrivilegedIo(record.trashedPath);
        if (!mustUsePrivileged && dir.existsSync()) {
          await dir.delete(recursive: true);
        } else {
          final mode = await _resolvePrivilegedWriteModeForOperation();
          if (mode == null) {
            throw StateError(deleteFailurePermissionDenied);
          }
          await _privilegedDeletePath(record.trashedPath, mode: mode);
        }
      }
    }
    _items.removeWhere((item) => item.id == recordId);
    await _save();
    if (_isServerMode) {
      LocalServerRuntime.instance.markResourceStateDirty();
    }
    App.notifyLocalDataChanged();
  }

  Future<void> _restoreStoredLocalItem(TrashItemRecord record) async {
    if (!record.isLocal) {
      throw StateError('remote trash restore is not ready');
    }

    if (record.trashedPath.isNotEmpty) {
      final trashedDir = Directory(record.trashedPath);
      final trashedState = await _resolveLocalPathState(trashedDir);
      if (trashedState == _LocalPathState.permissionDenied) {
        throw StateError(deleteFailurePermissionDenied);
      }
      if (trashedState == _LocalPathState.missing) {
        throw StateError('trashed directory not found');
      }

      final originalDir = Directory(record.originalPath);
      final originalState = await _resolveLocalPathState(originalDir);
      if (originalState == _LocalPathState.permissionDenied) {
        throw StateError(deleteFailurePermissionDenied);
      }
      if (originalState == _LocalPathState.exists) {
        throw StateError('original path already exists');
      }
      final mustUsePrivileged = _shouldForcePrivilegedIo(record.trashedPath) ||
          _shouldForcePrivilegedIo(record.originalPath);
      if (!mustUsePrivileged && trashedDir.existsSync()) {
        originalDir.parent.createSync(recursive: true);
        await _moveDirectory(trashedDir, originalDir);
      } else {
        final mode = await _resolvePrivilegedWriteModeForOperation();
        if (mode == null) {
          throw StateError(deleteFailurePermissionDenied);
        }
        await _privilegedMovePath(
          record.trashedPath,
          record.originalPath,
          mode: mode,
        );
      }
    }

    if (record.sourceDbRecordRemoved) {
      await _restoreSourceDbRecord(record);
    }

    await LocalTrashStore.instance.delete(record.id);
    if (_isServerMode) {
      LocalServerRuntime.instance.markResourceStateDirty();
    }
    await _evictRestoredLocalImageCachesForRecord(record);
    App.notifyLocalDataChanged();
  }

  Future<bool> _removeSourceDbRecord(_LocalDeleteTarget target) async {
    final sourceDbPath = target.sourceDbPath?.trim() ?? '';
    final sourceDbId = target.sourceDbId?.trim().isNotEmpty == true
        ? target.sourceDbId!.trim()
        : target.downloadDbId?.trim() ?? '';
    final sourceDirectory = target.sourceDirectory?.trim() ?? '';
    if (sourceDbPath.isEmpty ||
        (sourceDbId.isEmpty && sourceDirectory.isEmpty)) {
      return false;
    }
    return _mutateSourceDbFile(
      sourceDbPath,
      skipIfMissing: true,
      mutate: (db) async {
        if (sourceDbId.isNotEmpty &&
            db.select(
              'select 1 from download where id = ? limit 1',
              [sourceDbId],
            ).isNotEmpty) {
          db.execute('delete from download where id = ?', [sourceDbId]);
          return;
        }
        if (sourceDirectory.isNotEmpty) {
          db.execute('delete from download where directory = ?', [
            sourceDirectory,
          ]);
        }
      },
    );
  }

  Future<bool> _mutateSourceDbFile(
    String sourceDbPath, {
    required Future<void> Function(Database db) mutate,
    bool createIfMissing = false,
    bool skipIfMissing = false,
  }) async {
    final file = File(sourceDbPath);
    Uint8List? sourceBytes;
    var exists = false;
    var needsPrivilegedRead = false;
    _PrivilegedWriteMode? mode;
    try {
      exists = await file.exists();
      if (exists) {
        try {
          sourceBytes = await file.readAsBytes();
        } on FileSystemException catch (e) {
          if (!_isPermissionDenied(e)) {
            rethrow;
          }
          needsPrivilegedRead = true;
        }
      }
    } on FileSystemException catch (e) {
      if (!_isPermissionDenied(e)) {
        rethrow;
      }
      needsPrivilegedRead = true;
    }

    if (App.isAndroid && (needsPrivilegedRead || !exists)) {
      mode = await _resolvePrivilegedWriteModeForOperation();
      if (mode != null) {
        final privilegedExists = await _privilegedPathExists(
          sourceDbPath,
          mode: mode,
        );
        if (privilegedExists) {
          exists = true;
          sourceBytes =
              await _privilegedReadFileBytes(sourceDbPath, mode: mode);
          if (sourceBytes == null) {
            throw StateError(deleteFailurePermissionDenied);
          }
        } else {
          exists = false;
        }
      }
    }

    if (exists && sourceBytes == null) {
      if (mode == null && App.isAndroid) {
        mode = await _resolvePrivilegedWriteModeForOperation();
      }
      if (mode != null) {
        sourceBytes = await _privilegedReadFileBytes(sourceDbPath, mode: mode);
      }
      if (sourceBytes == null) {
        throw StateError(deleteFailurePermissionDenied);
      }
    }

    if (!exists) {
      if (skipIfMissing) {
        return true;
      }
      if (!createIfMissing) {
        return false;
      }
    }

    final tempRoot =
        Directory(_joinTrashPath(App.dataPath, 'trash_db_mutation'));
    tempRoot.createSync(recursive: true);
    final tempFile = File(
      _joinTrashPath(
        tempRoot.path,
        'download_${DateTime.now().microsecondsSinceEpoch}.db',
      ),
    );

    try {
      if (sourceBytes != null && sourceBytes.isNotEmpty) {
        await tempFile.writeAsBytes(sourceBytes, flush: true);
      }
      final db = sqlite3.open(tempFile.path);
      try {
        db.execute('''
          create table if not exists download (
            id text primary key,
            title text,
            subtitle text,
            time int,
            directory text,
            size int,
            json text
          )
        ''');
        await mutate(db);
      } finally {
        db.dispose();
      }
      final nextBytes = await tempFile.readAsBytes();
      final mustUsePrivileged = _shouldForcePrivilegedIo(sourceDbPath);
      if (mustUsePrivileged) {
        final mode = await _resolvePrivilegedWriteModeForOperation();
        if (mode == null) {
          throw StateError(deleteFailurePermissionDenied);
        }
        await _privilegedWriteFileBytes(sourceDbPath, nextBytes, mode: mode);
        return true;
      }
      try {
        file.parent.createSync(recursive: true);
        await file.writeAsBytes(nextBytes, flush: true);
      } on FileSystemException catch (e) {
        if (!_isPermissionDenied(e)) {
          rethrow;
        }
        final mode = await _resolvePrivilegedWriteModeForOperation();
        if (mode == null) {
          throw StateError(deleteFailurePermissionDenied);
        }
        await _privilegedWriteFileBytes(sourceDbPath, nextBytes, mode: mode);
      }
      return true;
    } finally {
      if (tempFile.existsSync()) {
        try {
          tempFile.deleteSync();
        } catch (_) {}
      }
    }
  }

  Future<void> _evictRestoredLocalImageCachesForRecord(
    TrashItemRecord record,
  ) {
    return _evictRestoredLocalImageCachesForPath(
      record.originalPath,
      coverRelativePath: record.coverRelativePath,
      coverPath: record.cover,
    );
  }

  Future<void> _evictRestoredLocalImageCachesForPath(
    String rootPath, {
    String coverRelativePath = '',
    String coverPath = '',
  }) async {
    final paths = <String>{};
    final root = rootPath.trim();
    final relative = coverRelativePath.trim();
    if (root.isNotEmpty && relative.isNotEmpty) {
      paths.add(_joinTrashRelativePath(root, relative));
    }
    final cover = coverPath.trim();
    if (cover.isNotEmpty) {
      paths.add(cover);
    }
    if (root.isNotEmpty) {
      try {
        final metadata =
            await LocalLibraryManager.instance.buildRestoredFileMetadata(root);
        final metadataCover = metadata.coverPath?.trim() ?? '';
        if (metadataCover.isNotEmpty) {
          paths.add(metadataCover);
        }
        for (final files in metadata.episodeFiles.values) {
          for (final file in files) {
            final path = file.trim();
            if (path.isNotEmpty) {
              paths.add(path);
            }
          }
        }
      } catch (_) {}
    }
    _evictLocalImageCachePaths(paths);
  }

  void _evictLocalImageCachePaths(Iterable<String> paths) {
    final imageCache = PaintingBinding.instance.imageCache;
    for (final rawPath in paths) {
      final path = rawPath.trim();
      if (path.isEmpty) {
        continue;
      }
      BaseImageProvider.evictKey('local_file::$path');
      final streamProvider = StreamImageProvider(
        () => const Stream<List<int>>.empty(),
        'local_file::$path',
      );
      imageCache.evict(streamProvider, includeLive: true);
      imageCache.evict(FileImage(File(path)), includeLive: true);
    }
  }

  Future<void> _restoreSourceDbRecord(TrashItemRecord record) async {
    final sourceDbPath = record.sourceDbPath.trim();
    final sourceDbId = record.sourceDbId.trim().isNotEmpty
        ? record.sourceDbId.trim()
        : record.itemId.trim();
    final directory = record.sourceDirectory.trim().isNotEmpty
        ? record.sourceDirectory.trim()
        : _basenameTrashPath(record.originalPath);
    if (sourceDbPath.isEmpty || sourceDbId.isEmpty || directory.isEmpty) {
      return;
    }
    final repairedSnapshotJson = await _repairRestoredSnapshotJson(
      record,
      directory: directory,
      sourceDbId: sourceDbId,
    );
    final restored = parseDownloadedItemRecordJson(
      sourceDbId,
      repairedSnapshotJson,
      directory: directory,
    );
    if (restored == null) {
      return;
    }
    final restoreTimeMillis = record.sourceDbTimeMillis > 0
        ? record.sourceDbTimeMillis
        : record.deletedAt.millisecondsSinceEpoch;
    final requestedRowId = record.sourceDbRowId > 0 ? record.sourceDbRowId : 0;
    await _mutateSourceDbFile(
      sourceDbPath,
      createIfMissing: true,
      mutate: (db) async {
        final existingRow = db.select(
          '''
            select rowid as __rowid__
            from download
            where id = ?
            limit 1
          ''',
          [sourceDbId],
        );
        if (existingRow.isNotEmpty) {
          db.execute('''
            update download
            set title = ?,
                subtitle = ?,
                time = ?,
                directory = ?,
                size = ?,
                json = ?
            where id = ?
          ''', [
            restored.name,
            restored.subTitle,
            restoreTimeMillis,
            directory,
            restored.comicSize,
            repairedSnapshotJson,
            sourceDbId,
          ]);
          return;
        }

        if (requestedRowId > 0) {
          final occupiedRow = db.select(
            '''
              select id
              from download
              where rowid = ?
              limit 1
            ''',
            [requestedRowId],
          );
          if (occupiedRow.isEmpty) {
            db.execute('''
              insert into download(
                rowid,
                id,
                title,
                subtitle,
                time,
                directory,
                size,
                json
              ) values (?,?,?,?,?,?,?,?)
            ''', [
              requestedRowId,
              sourceDbId,
              restored.name,
              restored.subTitle,
              restoreTimeMillis,
              directory,
              restored.comicSize,
              repairedSnapshotJson,
            ]);
            return;
          }
        }

        db.execute('''
          insert into download(
            id,
            title,
            subtitle,
            time,
            directory,
            size,
            json
          ) values (?,?,?,?,?,?,?)
        ''', [
          sourceDbId,
          restored.name,
          restored.subTitle,
          restoreTimeMillis,
          directory,
          restored.comicSize,
          repairedSnapshotJson,
        ]);
      },
    );
  }

  Future<String> _repairRestoredSnapshotJson(
    TrashItemRecord record, {
    required String directory,
    required String sourceDbId,
  }) async {
    dynamic decoded;
    try {
      decoded = jsonDecode(record.snapshotJson);
    } catch (_) {
      return record.snapshotJson;
    }
    if (decoded is! Map) {
      return record.snapshotJson;
    }
    final json = decoded.map((key, value) => MapEntry(key.toString(), value));
    final originalPath = record.originalPath.trim();
    final trashedPath = record.trashedPath.trim();
    String remapPath(String value) {
      final path = value.trim();
      if (path.isEmpty || originalPath.isEmpty) {
        return path;
      }
      if (trashedPath.isNotEmpty) {
        final relativeFromTrash = _relativeTrashPathIfInside(trashedPath, path);
        if (relativeFromTrash.isNotEmpty) {
          return _joinTrashRelativePath(originalPath, relativeFromTrash);
        }
        if (_sameNormalizedPath(path, trashedPath)) {
          return originalPath;
        }
      }
      return path;
    }

    Object? remapValue(Object? value) {
      if (value is String) {
        return remapPath(value);
      }
      if (value is List) {
        return value.map(remapValue).toList(growable: false);
      }
      if (value is Map) {
        return value
            .map((key, entry) => MapEntry(key.toString(), remapValue(entry)));
      }
      return value;
    }

    LocalLibraryRestoredFileMetadata? metadata;
    if (originalPath.isNotEmpty) {
      metadata = await LocalLibraryManager.instance
          .buildRestoredFileMetadata(originalPath);
    }
    final rebuiltEpisodeFiles =
        metadata?.episodeFiles ?? const <int, List<String>>{};
    final orderedImages = <String>[
      for (final entry
          in rebuiltEpisodeFiles.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)))
        ...entry.value,
    ];
    final rebuiltCoverPath = metadata?.coverPath?.trim() ?? '';

    json['fileSystemPath'] = originalPath;
    json['sourceDirectory'] = directory;
    json['sourceDbId'] = sourceDbId;
    if (record.sourceDbPath.trim().isNotEmpty) {
      json['sourceDbPath'] = record.sourceDbPath.trim();
    }
    if (record.sourceDbRowId > 0) {
      json['sourceDbRowId'] = record.sourceDbRowId;
    }
    if (record.sourceDbTimeMillis > 0) {
      json['sourceRowTimeMillis'] = record.sourceDbTimeMillis;
    }

    if (rebuiltEpisodeFiles.isNotEmpty) {
      json['episodeFiles'] = {
        for (final entry in rebuiltEpisodeFiles.entries)
          entry.key.toString(): List<String>.from(entry.value),
      };
      json['downloadedEps'] = metadata!.downloadedEps;
      json['eps'] = metadata.eps;
      json['comicSize'] = metadata.sizeMb;
      json['size'] = metadata.sizeMb;
      for (final key in const [
        'pages',
        'imagePaths',
        'images',
        'files',
        'downloadedFiles',
      ]) {
        if (json.containsKey(key)) {
          json[key] = List<String>.from(orderedImages);
        }
      }
    } else {
      if (json.containsKey('episodeFiles')) {
        json['episodeFiles'] = remapValue(json['episodeFiles']);
      }
      for (final key in const [
        'pages',
        'imagePaths',
        'images',
        'files',
        'downloadedFiles',
      ]) {
        if (json.containsKey(key)) {
          json[key] = remapValue(json[key]);
        }
      }
    }

    if (rebuiltCoverPath.isNotEmpty && File(rebuiltCoverPath).existsSync()) {
      json['localCoverPath'] = rebuiltCoverPath;
      if (json.containsKey('coverPath')) {
        json['coverPath'] = rebuiltCoverPath;
      }
      if (json.containsKey('cover')) {
        json['cover'] = rebuiltCoverPath;
      }
      final gallery = json['gallery'];
      if (gallery is Map) {
        final galleryData = gallery.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        if (galleryData.containsKey('cover')) {
          galleryData['cover'] = rebuiltCoverPath;
        }
        if (galleryData.containsKey('coverPath')) {
          galleryData['coverPath'] = rebuiltCoverPath;
        }
        json['gallery'] = galleryData;
      }
    } else {
      final localCoverPath =
          remapPath((json['localCoverPath'] as String? ?? '').trim());
      if (localCoverPath.isNotEmpty && File(localCoverPath).existsSync()) {
        json['localCoverPath'] = localCoverPath;
      } else {
        final coverPath = resolveLocalTrashCoverPath(
          trashedPath: originalPath,
          coverRelativePath: record.coverRelativePath,
          cover: record.cover,
        );
        json['localCoverPath'] = coverPath;
      }
    }

    if (metadata != null &&
        record.sourceDbPath.trim().isNotEmpty &&
        sourceDbId.trim().isNotEmpty) {
      await LocalLibraryManager.instance.persistRestoredFileMetadataCache(
        sourceDbPath: record.sourceDbPath.trim(),
        sourceDbId: sourceDbId.trim(),
        itemDirectory: originalPath,
        metadata: metadata,
      );
    }

    return jsonEncode(json);
  }

  Future<DeleteItemResult> _moveLocalItemToTrash(DownloadedItem item) async {
    final target = await _resolveLocalDeleteTarget(item);
    if (target == null) {
      return DeleteItemResult.failure(deleteFailureLocalPathNotFound);
    }
    final sourceDir = Directory(target.originalPath);
    print(
      '[PicaKeep][Trash] move local item to trash path=${target.originalPath} db=${target.sourceDbPath ?? ''} directory=${target.sourceDirectory ?? ''}',
    );
    if (_isUnsafeLocalDeleteRoot(target.originalPath, target.sourceDbPath)) {
      print(
          '[PicaKeep][Trash] refuse unsafe delete root: ${target.originalPath}');
      return DeleteItemResult.failure(deleteFailureLocalPathNotFound);
    }
    final pathState = await _resolveLocalPathState(sourceDir);
    if (pathState == _LocalPathState.permissionDenied) {
      return DeleteItemResult.failure(deleteFailurePermissionDenied);
    }
    if (pathState == _LocalPathState.missing && !target.hasSourceDbRecord) {
      return DeleteItemResult.failure(deleteFailureLocalPathNotFound);
    }

    final snapshot = await _buildLocalTrashSnapshot(item, target);
    final recordId = _generateRecordId();
    final sourceDbId = target.sourceDbId?.trim().isNotEmpty == true
        ? target.sourceDbId!.trim()
        : target.downloadDbId?.trim() ?? '';
    final sourceDirectory = target.sourceDirectory?.trim().isNotEmpty == true
        ? target.sourceDirectory!.trim()
        : _basenameTrashPath(target.originalPath);
    final sourceDbRowId = target.sourceDbRowId ?? 0;
    final deletedAt = DateTime.now();
    final trashedPath = pathState == _LocalPathState.exists
        ? _joinTrashPath(
            _joinTrashPath(sourceDir.parent.path, localTrashDirectoryName),
            recordId,
          )
        : '';

    final pendingRecord = _buildLocalTrashRecord(
      id: recordId,
      item: item,
      snapshot: snapshot,
      originalPath: target.originalPath,
      trashedPath: trashedPath,
      deletedAt: deletedAt,
      sizeBytes: _estimateItemSizeBytes(item),
      sourceDbPath: target.sourceDbPath?.trim() ?? '',
      sourceDbId: sourceDbId,
      sourceDirectory: sourceDirectory,
      sourceDbRowId: sourceDbRowId,
      sourceDbTimeMillis: target.sourceDbTimeMillis ?? 0,
      sourceDbRecordRemoved: false,
    );
    await LocalTrashStore.instance.upsert(
      pendingRecord.toLocalStoreData(state: localTrashStatePending),
    );

    var sourceDbRecordRemoved = false;
    var directoryMoved = false;
    try {
      if (target.hasSourceDbRecord) {
        sourceDbRecordRemoved = await _removeSourceDbRecord(target);
      }

      if (pathState == _LocalPathState.exists) {
        final mustUsePrivileged = _shouldForcePrivilegedIo(target.originalPath);
        final canDirectIo = !mustUsePrivileged && sourceDir.existsSync();
        if (canDirectIo) {
          Directory(sourceDir.parent.path).createSync(recursive: true);
          await _moveDirectory(sourceDir, Directory(trashedPath));
        } else {
          final mode = await _resolvePrivilegedWriteModeForOperation();
          if (mode == null) {
            throw StateError(deleteFailurePermissionDenied);
          }
          await _privilegedMovePath(
            target.originalPath,
            trashedPath,
            mode: mode,
          );
        }
        directoryMoved = true;
      }

      final record = _buildLocalTrashRecord(
        id: recordId,
        item: item,
        snapshot: snapshot,
        originalPath: target.originalPath,
        trashedPath: trashedPath,
        deletedAt: deletedAt,
        sizeBytes: pendingRecord.sizeBytes,
        sourceDbPath: target.sourceDbPath?.trim() ?? '',
        sourceDbId: sourceDbId,
        sourceDirectory: sourceDirectory,
        sourceDbRowId: sourceDbRowId,
        sourceDbTimeMillis: target.sourceDbTimeMillis ?? 0,
        sourceDbRecordRemoved: sourceDbRecordRemoved,
      );

      await LocalTrashStore.instance.upsert(record.toLocalStoreData());
      if (_isServerMode) {
        LocalServerRuntime.instance.markResourceStateDirty();
      }
      App.notifyLocalDataChanged();
      return DeleteItemResult.success(record);
    } catch (e) {
      if (directoryMoved) {
        try {
          final trashedDir = Directory(trashedPath);
          final mustUsePrivileged = _shouldForcePrivilegedIo(trashedPath) ||
              _shouldForcePrivilegedIo(target.originalPath);
          if (!mustUsePrivileged && trashedDir.existsSync()) {
            await _moveDirectory(trashedDir, Directory(target.originalPath));
          } else if (trashedPath.isNotEmpty) {
            final mode = await _resolvePrivilegedWriteModeForOperation();
            if (mode != null) {
              await _privilegedMovePath(
                trashedPath,
                target.originalPath,
                mode: mode,
              );
            }
          }
        } catch (rollbackError) {
          print(
              '[PicaKeep] Failed to roll back moved directory: $rollbackError');
        }
      }
      if (sourceDbRecordRemoved) {
        try {
          await _restoreSourceDbRecord(
            _buildLocalTrashRecord(
              id: recordId,
              item: item,
              snapshot: snapshot,
              originalPath: target.originalPath,
              trashedPath: trashedPath,
              deletedAt: deletedAt,
              sizeBytes: pendingRecord.sizeBytes,
              sourceDbPath: target.sourceDbPath?.trim() ?? '',
              sourceDbId: sourceDbId,
              sourceDirectory: sourceDirectory,
              sourceDbRowId: sourceDbRowId,
              sourceDbTimeMillis: target.sourceDbTimeMillis ?? 0,
              sourceDbRecordRemoved: true,
            ),
          );
        } catch (rollbackError) {
          print(
              '[PicaKeep] Failed to roll back source DB record: $rollbackError');
        }
      }
      await LocalTrashStore.instance.delete(recordId);
      if (e is StateError && e.message == deleteFailurePermissionDenied) {
        return DeleteItemResult.failure(deleteFailurePermissionDenied);
      }
      if (e is FileSystemException && _isPermissionDenied(e)) {
        return DeleteItemResult.failure(deleteFailurePermissionDenied);
      }
      rethrow;
    }
  }

  Future<String?> _deleteLocalItemPermanently(DownloadedItem item) async {
    final target = await _resolveLocalDeleteTarget(item);
    if (target == null) {
      return deleteFailureLocalPathNotFound;
    }
    final sourceDbId = target.sourceDbId?.trim().isNotEmpty == true
        ? target.sourceDbId!.trim()
        : target.downloadDbId?.trim() ?? '';
    final dir = Directory(target.originalPath);
    final pathState = await _resolveLocalPathState(dir);
    if (pathState == _LocalPathState.permissionDenied) {
      return deleteFailurePermissionDenied;
    }
    if (pathState == _LocalPathState.missing && !target.hasSourceDbRecord) {
      return deleteFailureLocalPathNotFound;
    }

    final mustUsePrivileged = _shouldForcePrivilegedIo(target.originalPath);
    if (target.hasSourceDbRecord || sourceDbId.isNotEmpty) {
      if (pathState == _LocalPathState.exists) {
        if (!mustUsePrivileged && dir.existsSync()) {
          await dir.delete(recursive: true);
        } else {
          final mode = await _resolvePrivilegedWriteModeForOperation();
          if (mode == null) {
            return deleteFailurePermissionDenied;
          }
          await _privilegedDeletePath(target.originalPath, mode: mode);
        }
      }
      try {
        await _removeSourceDbRecord(target);
      } on StateError catch (e) {
        if (e.message == deleteFailurePermissionDenied) {
          return deleteFailurePermissionDenied;
        }
        rethrow;
      }
      if (_isServerMode) {
        LocalServerRuntime.instance.markResourceStateDirty();
      }
      App.notifyLocalDataChanged();
      return null;
    }
    if (pathState == _LocalPathState.exists) {
      if (!mustUsePrivileged && dir.existsSync()) {
        await dir.delete(recursive: true);
      } else {
        final mode = await _resolvePrivilegedWriteModeForOperation();
        if (mode == null) {
          return deleteFailurePermissionDenied;
        }
        await _privilegedDeletePath(target.originalPath, mode: mode);
      }
    }
    if (_isServerMode) {
      LocalServerRuntime.instance.markResourceStateDirty();
    }
    App.notifyLocalDataChanged();
    return null;
  }

  Future<_TrashSnapshotPayload> _buildLocalTrashSnapshot(
    DownloadedItem item,
    _LocalDeleteTarget target,
  ) async {
    final sourceRowJson = target.sourceRowJson?.trim() ?? '';
    final sourceDbId = target.sourceDbId?.trim() ?? '';
    if (sourceRowJson.isNotEmpty && sourceDbId.isNotEmpty) {
      return _TrashSnapshotPayload(
        itemId: sourceDbId,
        snapshotJson: sourceRowJson,
      );
    }
    if (item is! LocalLibraryComicItem && target.downloadDbId != null) {
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

  int _estimateItemSizeBytes(DownloadedItem item) {
    final sizeMb = item.comicSize;
    if (sizeMb == null || !sizeMb.isFinite || sizeMb <= 0) {
      return 0;
    }
    return (sizeMb * 1024 * 1024).round();
  }

  TrashItemRecord _buildLocalTrashRecord({
    required String id,
    required DownloadedItem item,
    required _TrashSnapshotPayload snapshot,
    required String originalPath,
    required String trashedPath,
    required DateTime deletedAt,
    required int sizeBytes,
    required String sourceDbPath,
    required String sourceDbId,
    required String sourceDirectory,
    required int sourceDbRowId,
    required int sourceDbTimeMillis,
    required bool sourceDbRecordRemoved,
    String? coverPathOverride,
    String? coverRelativePathOverride,
  }) {
    final coverPath = coverPathOverride ??
        resolveLocalComicCoverPath(
          item,
          legacyTargets: [
            snapshot.itemId,
            sourceDbId,
            sourceDirectory,
            originalPath,
          ],
        ).trim();
    final coverRelativePath = coverRelativePathOverride ??
        (coverPath.isEmpty
            ? ''
            : _relativeTrashPathIfInside(originalPath, coverPath));
    return TrashItemRecord(
      id: id,
      scope: TrashItemScope.local,
      itemKind: item is LocalLibraryComicItem && item.isAlbum
          ? TrashItemKind.album
          : TrashItemKind.comic,
      itemId: snapshot.itemId,
      title: item.name,
      subtitle: item.subTitle,
      cover: coverPath,
      coverRelativePath: coverRelativePath,
      sourceLabel: item.sourceDisplayName,
      originalPath: originalPath,
      trashedPath: trashedPath,
      deletedAt: deletedAt,
      sizeBytes: sizeBytes,
      snapshotJson: snapshot.snapshotJson,
      remotePath: '',
      detailUrl: '',
      rootId: '',
      sourceDbPath: sourceDbPath,
      sourceDbId: sourceDbId,
      sourceDirectory: sourceDirectory,
      sourceDbRowId: sourceDbRowId,
      sourceDbTimeMillis: sourceDbTimeMillis,
      sourceDbRecordRemoved: sourceDbRecordRemoved,
    );
  }

  Future<_LocalDeleteTarget?> _resolveLocalDeleteTarget(
      DownloadedItem item) async {
    if (item is LocalLibraryComicItem) {
      final path = item.fileSystemPath?.trim() ?? '';
      if (path.isEmpty) {
        return null;
      }
      return _LocalDeleteTarget(
        originalPath: path,
        downloadDbId:
            item.isManagedDownloadItem ? item.originalId.trim() : null,
        restoreItemId:
            item.isManagedDownloadItem ? item.originalId.trim() : item.id,
        sourceDbPath: item.sourceDbPath?.trim(),
        sourceDbId: item.sourceDbId?.trim().isNotEmpty == true
            ? item.sourceDbId!.trim()
            : (item.isManagedDownloadItem ? item.originalId.trim() : null),
        sourceDirectory: item.sourceDirectory?.trim().isNotEmpty == true
            ? item.sourceDirectory!.trim()
            : _basenameTrashPath(path),
        sourceDbRowId: item.sourceDbRowId,
        sourceRowJson: item.sourceRowJson,
        sourceDbTimeMillis: item.sourceRowTimeMillis,
      );
    }

    final manager = DownloadManager();
    await manager.init();
    final directory = manager.getDirectory(item.id).trim();
    if (directory.isEmpty || (manager.path?.trim().isEmpty ?? true)) {
      return null;
    }
    final dbPath =
        manager.dbFilePath ?? _joinTrashPath(manager.path!, 'download.db');
    return _LocalDeleteTarget(
      originalPath: _joinTrashPath(manager.path!, directory),
      downloadDbId: item.id,
      restoreItemId: item.id,
      sourceDbPath: dbPath,
      sourceDbId: item.id,
      sourceDirectory: directory,
      sourceDbRowId: manager.rowIdFor(item.id),
      sourceRowJson: jsonEncode(item.toJson()),
      sourceDbTimeMillis: item.time?.millisecondsSinceEpoch,
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
          Directory(_joinTrashPath(
              destination.path, _basenameTrashPath(entity.path))),
        );
      } else if (entity is File) {
        await entity.copy(
            _joinTrashPath(destination.path, _basenameTrashPath(entity.path)));
      }
    }
  }

  _LocalPathState _localPathState(Directory dir) {
    try {
      return dir.existsSync()
          ? _LocalPathState.exists
          : _LocalPathState.missing;
    } on FileSystemException catch (e) {
      if (_isPermissionDenied(e)) {
        return _LocalPathState.permissionDenied;
      }
      return _LocalPathState.missing;
    }
  }

  Future<_LocalPathState> _resolveLocalPathState(Directory dir) async {
    final localState = _localPathState(dir);
    final shouldCheckPrivileged = App.isAndroid &&
        (localState == _LocalPathState.permissionDenied ||
            _shouldForcePrivilegedIo(dir.path));
    if (!shouldCheckPrivileged) {
      return localState;
    }
    final mode = await _resolvePrivilegedWriteModeForOperation();
    if (mode == null) {
      return _LocalPathState.permissionDenied;
    }
    final exists = await _privilegedPathExists(dir.path, mode: mode);
    return exists ? _LocalPathState.exists : _LocalPathState.missing;
  }

  bool _isPermissionDenied(FileSystemException e) {
    final message = e.message.toLowerCase();
    final osMessage = e.osError?.message.toLowerCase() ?? '';
    return e.osError?.errorCode == 13 ||
        message.contains('permission denied') ||
        osMessage.contains('permission denied');
  }
}

class _LocalDeleteTarget {
  const _LocalDeleteTarget({
    required this.originalPath,
    required this.restoreItemId,
    this.downloadDbId,
    this.sourceDbPath,
    this.sourceDbId,
    this.sourceDirectory,
    this.sourceDbRowId,
    this.sourceRowJson,
    this.sourceDbTimeMillis,
  });

  final String originalPath;
  final String restoreItemId;
  final String? downloadDbId;
  final String? sourceDbPath;
  final String? sourceDbId;
  final String? sourceDirectory;
  final int? sourceDbRowId;
  final String? sourceRowJson;
  final int? sourceDbTimeMillis;

  bool get hasSourceDbRecord =>
      (sourceDbPath?.trim().isNotEmpty ?? false) ||
      (sourceDbId?.trim().isNotEmpty ?? false) ||
      (downloadDbId?.trim().isNotEmpty ?? false);
}

class _TrashSnapshotPayload {
  const _TrashSnapshotPayload({
    required this.itemId,
    required this.snapshotJson,
  });

  final String itemId;
  final String snapshotJson;
}
