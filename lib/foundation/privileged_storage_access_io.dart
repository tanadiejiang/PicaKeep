import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class PrivilegedFileStat {
  const PrivilegedFileStat({required this.size, required this.modifiedMillis});
  final int size;
  final int modifiedMillis;
}

class LocalDirectoryEntry {
  const LocalDirectoryEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
  });

  final String name;
  final String path;
  final bool isDirectory;
}

class PrivilegedStorageAccess {
  PrivilegedStorageAccess._();

  static Future<PrivilegedFileStat?> fileStat(String path) async {
    try {
      final stat = await File(path).stat();
      if (stat.type != FileSystemEntityType.file) return null;
      return PrivilegedFileStat(
          size: stat.size,
          modifiedMillis: stat.modified.millisecondsSinceEpoch);
    } catch (_) {
      return null;
    }
  }

  static Future<File> copyFileToManagedFile(
    String sourcePath,
    File destination, {
    int maxBytes = 2 * 1024 * 1024 * 1024,
    bool Function()? isCancelled,
    Future<void>? cancelled,
  }) async {
    var cancellationRequested = isCancelled?.call() == true;
    if (cancelled != null) {
      unawaited(cancelled.then((_) => cancellationRequested = true));
    }
    bool copyCancelled() =>
        cancellationRequested || isCancelled?.call() == true;
    if (copyCancelled()) throw StateError('Original file copy cancelled');
    final stat = await fileStat(sourcePath);
    if (stat == null) {
      throw FileSystemException('Original file is unavailable', sourcePath);
    }
    if (stat.size > maxBytes) {
      throw StateError('Original file exceeds reserved disk bytes');
    }
    await destination.parent.create(recursive: true);
    if (copyCancelled()) throw StateError('Original file copy cancelled');
    final output = await destination.open(mode: FileMode.write);
    var total = 0;
    var succeeded = false;
    try {
      await for (final chunk in File(sourcePath).openRead()) {
        if (copyCancelled()) {
          throw StateError('Original file copy cancelled');
        }
        total += chunk.length;
        if (total > maxBytes) {
          throw StateError('Original file exceeds reserved disk bytes');
        }
        await output.writeFrom(chunk);
      }
      if (copyCancelled()) throw StateError('Original file copy cancelled');
      await output.flush();
      succeeded = true;
      return destination;
    } finally {
      await output.close();
      if (!succeeded && await destination.exists()) await destination.delete();
    }
  }

  static Future<bool> directoryExists(String path) async {
    try {
      return await Directory(path).exists();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> fileExists(String path) async {
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  static Future<int?> fileLength(String path) async {
    try {
      final file = File(path);
      if (!(await file.exists())) {
        return null;
      }
      return await file.length();
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> readFileBytes(String path) async {
    try {
      final file = File(path);
      if (!(await file.exists())) {
        return null;
      }
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static Future<List<LocalDirectoryEntry>> listDirectoryEntries(
    String path,
  ) async {
    try {
      final directory = Directory(path);
      if (!(await directory.exists())) {
        return const <LocalDirectoryEntry>[];
      }
      return (await directory.list(followLinks: false).toList())
          .where((entity) => entity is Directory || entity is File)
          .map(
            (entity) => LocalDirectoryEntry(
              name: _basename(entity.path),
              path: entity.path,
              isDirectory: entity is Directory,
            ),
          )
          .toList(growable: false);
    } catch (_) {
      return const <LocalDirectoryEntry>[];
    }
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/').where((e) => e.isNotEmpty).toList();
    return segments.isEmpty ? path : segments.last;
  }
}
