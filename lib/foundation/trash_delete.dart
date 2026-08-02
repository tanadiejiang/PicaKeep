part of 'trash.dart';

extension TrashManagerDelete on TrashManager {
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

  /// 强制永久删除，不走回收站（无论设置如何）。
  Future<DeleteItemResult> forceDeletePermanently(DownloadedItem item) async {
    final error = await _deleteLocalItemPermanently(item);
    if (error != null) {
      return DeleteItemResult.failure(error);
    }
    return DeleteItemResult.success();
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

  /// 07号计划"更新信息"写回入口：更新 [sourceDbPath] 对应 download.db 里
  /// 某一行的 title/subtitle/json 三列，不改动 time/directory/size（这三者
  /// 在本地"信息"区有独立于在线数据的语义——下载时间/本地文件页数/本地记录标识，
  /// 不应被在线覆盖流程改写）。
  ///
  /// 复用既有的 [_mutateSourceDbFile]（含 root/Shizuku 特权IO fallback），
  /// 不重复实现一套数据库写入基础设施——评估过直接把 [_mutateSourceDbFile]
  /// 整体提升为公开方法的成本：它依赖大量 trash 场景私有辅助
  /// （_isPermissionDenied/_resolvePrivilegedWriteModeForOperation/
  /// _privilegedReadFileBytes/_privilegedWriteFileBytes/_joinTrashPath等），
  /// 这些私有函数分散在 trash.dart/trash_io.dart 多个 part 文件里，把它们
  /// 一并公开化会扩大 TrashManager 的公开面且与 trash 场景语义混淆，故只新增
  /// 这一个职责单一的公开方法作为最小对外入口，内部仍走同一套私有实现。
  ///
  /// 返回 true 表示确认目标行存在且写入成功；false 表示数据库文件不存在、
  /// 目标行不存在，或写入过程失败（详见 [_mutateSourceDbFile] 的异常语义，
  /// 该方法本身不吞异常，调用方需自行 catch）。
  Future<bool> updateSourceDbRowMetadata({
    required String sourceDbPath,
    required String sourceDbId,
    required String newTitle,
    required String newSubtitle,
    required String newJson,
  }) async {
    final dbPath = sourceDbPath.trim();
    final dbId = sourceDbId.trim();
    if (dbPath.isEmpty || dbId.isEmpty) {
      return false;
    }
    var rowFound = false;
    final ok = await _mutateSourceDbFile(
      dbPath,
      mutate: (db) async {
        final existing = db.select(
          'select 1 from download where id = ? limit 1',
          [dbId],
        );
        if (existing.isEmpty) {
          return;
        }
        rowFound = true;
        db.execute(
          'update download set title = ?, subtitle = ?, json = ? where id = ?',
          [newTitle, newSubtitle, newJson, dbId],
        );
      },
    );
    return ok && rowFound;
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

  int _estimateItemSizeBytes(DownloadedItem item) {
    final sizeMb = item.comicSize;
    if (sizeMb == null || !sizeMb.isFinite || sizeMb <= 0) {
      return 0;
    }
    return (sizeMb * 1024 * 1024).round();
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

  bool _isServerTrashRecordId(String recordId) =>
      recordId.trim().startsWith('srvtrash_');
}
