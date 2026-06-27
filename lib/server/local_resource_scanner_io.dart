part of 'local_resource_scanner.dart';

extension LocalResourceScannerIo on LocalResourceScanner {
  Future<List<String>> _listDirectContentImages(String directoryPath) async {
    final images = await _listDirectVisibleImages(directoryPath);
    return images.where((path) => !_isCoverLikeFile(path)).toList();
  }

  Future<List<String>> _listContentImages(
    String directoryPath, {
    required bool recursive,
  }) async {
    final images = await _listImageFiles(directoryPath, recursive: recursive);
    return images.where((path) => !_isCoverLikeFile(path)).toList();
  }

  Future<File?> _writeDatabaseSnapshot(
      String rootPath, List<int> dbBytes) async {
    try {
      final configuredRoot = Platform.environment['PICAKEEP_CACHE_DIR']?.trim();
      final cacheRoot = configuredRoot == null || configuredRoot.isEmpty
          ? '${Directory.systemTemp.path}${Platform.pathSeparator}picakeep'
          : configuredRoot;
      final dbDir = Directory(
        '$cacheRoot${Platform.pathSeparator}server_db_snapshots',
      );
      await dbDir.create(recursive: true);
      final safeName = _safeCacheName(rootPath);
      final snapshotFile =
          File('${dbDir.path}${Platform.pathSeparator}$safeName.db');
      await snapshotFile.writeAsBytes(dbBytes, flush: true);
      return snapshotFile;
    } catch (_) {
      return null;
    }
  }

  Future<Set<String>> _listRootDirectoryNames(String rootPath) async {
    final names = <String>{};
    final entries =
        await PrivilegedStorageAccess.listDirectoryEntries(rootPath);
    for (final entry in entries) {
      if (!entry.isDirectory ||
          _basename(entry.path) == _serverTrashDirectoryName) {
        continue;
      }
      names.add(entry.name.toLowerCase());
    }
    return names;
  }

  Future<int> _calculateTotalBytes(List<String> filePaths) async {
    var totalBytes = 0;
    for (final filePath in filePaths) {
      final length = await PrivilegedStorageAccess.fileLength(filePath);
      if (length != null) {
        totalBytes += length;
      }
    }
    return totalBytes;
  }

  Future<DateTime> _directoryUpdatedAt(String directoryPath) async {
    try {
      return (await Directory(directoryPath).stat()).modified;
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  Future<List<String>> _listDirectories(String directoryPath) async {
    final results = <String>[];
    final entries =
        await PrivilegedStorageAccess.listDirectoryEntries(directoryPath);
    for (final entry in entries) {
      if (entry.isDirectory &&
          _basename(entry.path) != _serverTrashDirectoryName) {
        results.add(entry.path);
      }
    }
    results
        .sort((a, b) => _naturalCompare(_normalizePath(a), _normalizePath(b)));
    return results;
  }

  Future<List<String>> _listImageFiles(
    String directoryPath, {
    required bool recursive,
  }) async {
    final results = <String>[];
    await _collectImageFiles(directoryPath,
        recursive: recursive, sink: results);
    results
        .sort((a, b) => _naturalCompare(_normalizePath(a), _normalizePath(b)));
    final visibleFiles =
        results.where((file) => !_isCoverLikeFile(file)).toList();
    return visibleFiles.isNotEmpty ? visibleFiles : results;
  }

  Future<void> _collectImageFiles(
    String directoryPath, {
    required bool recursive,
    required List<String> sink,
  }) async {
    final entries =
        await PrivilegedStorageAccess.listDirectoryEntries(directoryPath);
    for (final entry in entries) {
      if (_isInServerTrash(entry.path)) {
        continue;
      }
      if (entry.isDirectory) {
        if (recursive) {
          await _collectImageFiles(entry.path, recursive: true, sink: sink);
        }
        continue;
      }
      if (!_isImageFile(entry.path)) {
        continue;
      }
      sink.add(entry.path);
    }
  }

  Future<List<String>> _listDirectVisibleImages(String directoryPath) async {
    final results = <String>[];
    final entries =
        await PrivilegedStorageAccess.listDirectoryEntries(directoryPath);
    for (final entry in entries) {
      if (entry.isDirectory || _isInServerTrash(entry.path)) {
        continue;
      }
      if (!_isImageFile(entry.path)) {
        continue;
      }
      results.add(entry.path);
    }
    results
        .sort((a, b) => _naturalCompare(_normalizePath(a), _normalizePath(b)));
    final visibleFiles =
        results.where((file) => !_isCoverLikeFile(file)).toList();
    return visibleFiles.isNotEmpty ? visibleFiles : results;
  }

  bool _isInServerTrash(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized
        .split('/')
        .any((segment) => segment == _serverTrashDirectoryName);
  }

  bool _isImageFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.bmp');
  }
}
