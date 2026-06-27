part of 'trash.dart';

extension TrashManagerRestore on TrashManager {
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
}
