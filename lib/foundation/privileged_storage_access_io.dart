import 'dart:io';
import 'dart:typed_data';

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
