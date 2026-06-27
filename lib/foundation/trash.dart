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

part 'trash_delete.dart';
part 'trash_restore.dart';
part 'trash_remote.dart';
part 'trash_io.dart';

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
