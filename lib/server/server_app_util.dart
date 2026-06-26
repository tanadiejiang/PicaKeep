part of 'server_app.dart';

extension ServerAppUtil on PicaKeepAdminServer {
  String _normalizePath(String path) {
    final normalized = path.trim().replaceAll('\\', '/');
    if (normalized.isEmpty) {
      return '';
    }
    final collapsed = normalized.replaceAll(RegExp(r'/+'), '/');
    final trimmed = collapsed.replaceFirst(RegExp(r'/+$'), '');
    return trimmed.toLowerCase();
  }

  bool _isPathInsideRoot(String path, String rootPath) {
    final normalizedPath = _normalizePath(path);
    final normalizedRoot = _normalizePath(rootPath);
    if (normalizedPath.isEmpty || normalizedRoot.isEmpty) {
      return false;
    }
    return normalizedPath == normalizedRoot ||
        normalizedPath.startsWith('$normalizedRoot/');
  }

  bool _isManagedRootId(String rootId) =>
      rootId == 'current_download' || rootId == 'original_download';

  String? _managedRootPathForRootId(String rootId) {
    final currentConfig = _config;
    if (currentConfig == null) {
      return null;
    }
    return switch (rootId) {
      'current_download' => currentConfig.currentDownloadRoot.trim(),
      'original_download' => currentConfig.originalDownloadRoot.trim(),
      _ => null,
    };
  }

  String _relativeManagedDirectoryPath(String rootPath, String directoryPath) {
    final normalizedRoot = _normalizePath(rootPath);
    final normalizedDirectory = _normalizePath(directoryPath);
    if (normalizedRoot.isEmpty || normalizedDirectory.isEmpty) {
      return '';
    }
    if (normalizedDirectory == normalizedRoot) {
      return '';
    }
    final prefix = '$normalizedRoot/';
    if (!normalizedDirectory.startsWith(prefix)) {
      return '';
    }
    return normalizedDirectory.substring(prefix.length);
  }

  bool _shouldExposeLocalTrashRecord(LocalTrashRecordData record) {
    final currentConfig = _config;
    if (currentConfig == null) {
      return false;
    }
    final originalPath = record.originalPath.trim();
    final trashedPath = record.trashedPath.trim();
    if (originalPath.isEmpty || trashedPath.isEmpty) {
      return false;
    }
    if (!FileSystemEntity.isDirectorySync(trashedPath)) {
      return false;
    }
    return currentConfig.allLibraryRoots
        .any((root) => _isPathInsideRoot(originalPath, root));
  }

  Future<List<Map<String, dynamic>>> _buildCombinedTrashItemsPayload() async {
    final serverEntries = await _trashStore.listEntries();
    final localEntries = (await LocalTrashStore.instance.listTrashed())
        .where(_shouldExposeLocalTrashRecord)
        .toList(growable: false);
    final combined = <({int deletedAtMillis, Map<String, dynamic> payload})>[
      for (final entry in serverEntries)
        (
          deletedAtMillis: entry.deletedAt.millisecondsSinceEpoch,
          payload: _buildTrashItemPayload(entry),
        ),
      for (final record in localEntries)
        (
          deletedAtMillis: record.deletedAtMillis,
          payload: _buildLocalTrashItemPayload(record),
        ),
    ];
    combined.sort((a, b) => b.deletedAtMillis.compareTo(a.deletedAtMillis));
    return combined.map((entry) => entry.payload).toList(growable: false);
  }

  Map<String, dynamic> _buildLocalTrashItemPayload(
      LocalTrashRecordData record) {
    final encodedId = Uri.encodeComponent(record.id);
    return {
      'id': record.id,
      'itemId': record.itemId,
      'rootId': record.rootId,
      'itemKind': record.itemKind,
      'title': record.title,
      'subtitle': record.subtitle,
      'sourceDisplayName': record.sourceLabel,
      'originalPath': record.originalPath,
      'trashedPath': record.trashedPath,
      'deletedAt': DateTime.fromMillisecondsSinceEpoch(record.deletedAtMillis)
          .toIso8601String(),
      'sizeBytes': record.sizeBytes,
      'coverUrl': '/api/library/trash/$encodedId/cover',
      'source': 'local',
    };
  }

  Future<File?> _trashCoverFileForId(String trashId) async {
    if (_isServerTrashId(trashId)) {
      final entry = await _trashStore.findById(trashId);
      if (entry == null) {
        return null;
      }
      final coverFile = _trashStore.coverFileFor(entry);
      return coverFile.path.trim().isEmpty ? null : coverFile;
    }
    final record = await LocalTrashStore.instance.find(trashId);
    if (record == null) {
      return null;
    }
    final coverPath = resolveLocalTrashCoverPath(
      trashedPath: record.trashedPath,
      coverRelativePath: record.coverRelativePath,
      cover: record.cover,
    );
    if (coverPath.trim().isEmpty) {
      return null;
    }
    final file = File(coverPath);
    return file.existsSync() ? file : null;
  }

  Future<void> _deleteManagedDownloadDbRow(
      ServerResourceItemSummary item) async {
    if (!_isManagedRootId(item.rootId)) {
      return;
    }
    final rootPath = _managedRootPathForRootId(item.rootId);
    if (rootPath == null || rootPath.isEmpty) {
      return;
    }
    final dbFile = File('$rootPath${Platform.pathSeparator}download.db');
    if (!dbFile.existsSync()) {
      return;
    }
    final relativeDirectory =
        _relativeManagedDirectoryPath(rootPath, item.path);
    Database? db;
    try {
      db = sqlite3.open(dbFile.path);
      var deletedAny = false;
      if (relativeDirectory.isNotEmpty) {
        deletedAny = db.select(
          'select 1 from download where directory = ? limit 1',
          [relativeDirectory],
        ).isNotEmpty;
        if (deletedAny) {
          db.execute(
              'delete from download where directory = ?', [relativeDirectory]);
        }
      }
      if (!deletedAny) {
        deletedAny = db.select(
          'select 1 from download where directory = ? limit 1',
          [item.path],
        ).isNotEmpty;
        if (deletedAny) {
          db.execute('delete from download where directory = ?', [item.path]);
        }
      }
      if (!deletedAny) {
        db.execute('delete from download where id = ?', [item.id]);
      }
    } catch (e, s) {
      _state.addLog('trash', '同步清理 download.db 行失败: $e');
      _state.addLog('trash', s.toString());
    } finally {
      db?.dispose();
    }
  }

  Response _jsonResponse(
    Map<String, dynamic> body, {
    int statusCode = 200,
  }) {
    return Response(
      statusCode,
      body: const JsonEncoder.withIndent('  ').convert(body),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  Future<List<String>> _readStringListFromBody(
    Request request,
    String key,
  ) async {
    final body = await request.readAsString();
    if (body.trim().isEmpty) {
      return const <String>[];
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      return const <String>[];
    }
    final value = decoded[key];
    if (value is! List) {
      return const <String>[];
    }
    return value
        .map((entry) => entry.toString().trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> _readJsonMapFromBody(Request request) async {
    final body = await request.readAsString();
    if (body.trim().isEmpty) {
      return const <String, dynamic>{};
    }
    final decoded = jsonDecode(body);
    return _readJsonLikeMap(decoded);
  }

  Map<String, dynamic> _readJsonLikeMap(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return const <String, dynamic>{};
  }

  List<String> _readStringListValue(Object? value) {
    if (value is! List) {
      return const <String>[];
    }
    return value
        .map((entry) => entry.toString().trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }

  Set<int> _readIntSetValue(Object? value) {
    if (value is List) {
      return value
          .map(_readIntValue)
          .whereType<int>()
          .where((entry) => entry >= 0)
          .toSet();
    }
    if (value is String) {
      return value
          .split(',')
          .map((entry) => int.tryParse(entry.trim()))
          .whereType<int>()
          .where((entry) => entry >= 0)
          .toSet();
    }
    return const <int>{};
  }

  int? _readIntValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  Future<ServerResourceSnapshot> _scanResources() {
    final config = _config ?? PicaKeepServerConfig.defaults();
    return _scanner.scan(
      currentDownloadRoot: config.currentDownloadRoot,
      originalDownloadRoot: config.originalDownloadRoot,
      customLibraryRoots: config.customLibraryRoots,
      customLibraryCollectionShellModes:
          config.customLibraryCollectionShellModes,
    );
  }

  void _setSnapshot(
    ServerResourceSnapshot snapshot, {
    required bool emitEvent,
  }) {
    final previousSignature = _librarySignature;
    _snapshot = snapshot;
    _recomputeLibrarySignature(emitEvent: emitEvent);
    if (previousSignature != _librarySignature) {
      _deepItemCache.clear();
      _deepItemInFlight.clear();
      _favoriteCoverFallbackCache.clear();
    }
  }

  void _recomputeLibrarySignature({required bool emitEvent}) {
    final snapshot = _snapshot;
    if (snapshot == null) {
      _librarySignature = null;
      return;
    }
    final nextSignature = _computeLibrarySignature(snapshot);
    final changed = _librarySignature != nextSignature;
    _librarySignature = nextSignature;
    if (!emitEvent || !changed) {
      return;
    }
    _pendingLibraryChangedSignature = nextSignature;
    _pendingLibraryChangedGeneratedAt = snapshot.generatedAt;
    _pendingLibraryChangedTimer?.cancel();
    _pendingLibraryChangedTimer = Timer(
      const Duration(milliseconds: 250),
      _flushPendingLibraryChangedEvent,
    );
  }

  void _flushPendingLibraryChangedEvent() {
    _pendingLibraryChangedTimer?.cancel();
    _pendingLibraryChangedTimer = null;
    final signature = _pendingLibraryChangedSignature?.trim() ?? '';
    final generatedAt = _pendingLibraryChangedGeneratedAt;
    _pendingLibraryChangedSignature = null;
    _pendingLibraryChangedGeneratedAt = null;
    if (signature.isEmpty || generatedAt == null) {
      return;
    }
    _eventBus.emit(LibraryEvent.libraryChanged(signature, generatedAt));
  }

  String _computeLibrarySignature(ServerResourceSnapshot snapshot) {
    final buffer = StringBuffer();
    final config = _config ?? PicaKeepServerConfig.defaults();
    buffer
      ..writeln(config.currentDownloadRoot.trim())
      ..writeln(config.originalDownloadRoot.trim())
      ..writeln(encodeLocalCollectionShellPathMap(
        config.customLibraryCollectionShellModes,
      ));
    for (final root in [...snapshot.roots]..sort((a, b) {
        final idCompare = a.id.compareTo(b.id);
        if (idCompare != 0) {
          return idCompare;
        }
        return a.path.compareTo(b.path);
      })) {
      buffer.writeln(
        '${root.id}|${root.path}|${root.exists}|${root.itemCount}|${root.totalBytes}',
      );
    }
    buffer
      ..writeln(snapshot.totalComicCount.toString())
      ..writeln(snapshot.totalBytes.toString());
    return _fnv1a64(buffer.toString());
  }

  String _fnv1a64(String input) {
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    const mask = 0xffffffffffffffff;
    for (final byte in utf8.encode(input)) {
      hash ^= byte;
      hash = (hash * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts =
        normalized.split('/').where((entry) => entry.isNotEmpty).toList();
    return parts.isEmpty ? normalized : parts.last;
  }
}
