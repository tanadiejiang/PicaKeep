import 'dart:io';

import 'package:flutter/services.dart';

import '../base.dart';
import 'local_library_settings.dart';

/// Lightweight, cross-file descriptor returned by [PrivilegedStorageAccess.listDirectoryEntries].
///
/// Mirrors the private `_LocalDirectoryEntry` in `local_library.dart` so that
/// other modules (notably the local HTTP server) can reuse the same privileged
/// access primitives without depending on `LocalLibraryManager` itself.
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

/// Shared "dart:io with Shizuku/Root fallback" storage primitives.
///
/// The UI-side "Me" page reads comics from a restricted Android download
/// directory via `LocalLibraryManager`'s private helpers, which try
/// `dart:io` first and fall back to the `lingxue.picakeep/storage_access`
/// platform channel when the path is inaccessible. The HTTP server needs
/// the exact same capability: on a device where the download directory is
/// restricted, the scanner must be able to enumerate entries and the HTTP
/// file endpoint must be able to read bytes, otherwise the server reports
/// `漫画数量 0` even though the UI sees thousands of titles.
///
/// All methods are safe to call on any platform:
///   - on non-Android, only the `dart:io` path runs and the privileged
///     fallback is a no-op;
///   - on Android, if `dart:io` fails, the platform channel is consulted
///     when Shizuku/Root mode is enabled in settings.
class PrivilegedStorageAccess {
  PrivilegedStorageAccess._();

  static const MethodChannel _storageAccessChannel =
      MethodChannel('lingxue.picakeep/storage_access');

  /// Returns `true` if [path] refers to an existing directory, consulting
  /// the privileged channel when `dart:io` cannot see it.
  static Future<bool> directoryExists(String path) async {
    try {
      if (Directory(path).existsSync()) {
        return true;
      }
    } catch (_) {}
    return _existsWithPrivilegedAccess(path);
  }

  /// Returns `true` if [path] refers to an existing file, consulting the
  /// privileged channel when `dart:io` cannot see it.
  static Future<bool> fileExists(String path) async {
    try {
      if (File(path).existsSync()) {
        return true;
      }
    } catch (_) {}
    return _existsWithPrivilegedAccess(path);
  }

  /// Returns the byte length of [path], or `null` if the file cannot be
  /// read by either `dart:io` or the privileged channel.
  static Future<int?> fileLength(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) {
        return await file.length();
      }
    } catch (_) {}
    final bytes = await _readFileWithPrivilegedAccess(path);
    return bytes?.length;
  }

  /// Reads the full contents of [path]. Returns `null` when the file does
  /// not exist or neither `dart:io` nor the privileged channel can read it.
  static Future<Uint8List?> readFileBytes(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) {
        return await file.readAsBytes();
      }
    } catch (_) {}
    return _readFileWithPrivilegedAccess(path);
  }

  /// Lists immediate children of [path] (files and directories), falling
  /// back to the privileged channel when `dart:io` cannot enumerate the
  /// directory. Returns an empty list when the directory does not exist or
  /// cannot be read by either layer.
  static Future<List<LocalDirectoryEntry>> listDirectoryEntries(
    String path,
  ) async {
    try {
      final directory = Directory(path);
      if (directory.existsSync()) {
        return directory
            .listSync(followLinks: false)
            .where((entity) => entity is Directory || entity is File)
            .map(
              (entity) => LocalDirectoryEntry(
                name: _basename(entity.path),
                path: entity.path,
                isDirectory: entity is Directory,
              ),
            )
            .toList();
      }
    } catch (_) {}
    return _listDirectoryEntriesWithPrivilegedAccess(path);
  }

  static Future<List<LocalDirectoryEntry>>
      _listDirectoryEntriesWithPrivilegedAccess(String path) async {
    if (!Platform.isAndroid) {
      return const <LocalDirectoryEntry>[];
    }
    final method = _androidPrivilegedAccessMethod('listDirectoryEntries');
    if (method == null) {
      return const <LocalDirectoryEntry>[];
    }
    try {
      final result = await _storageAccessChannel.invokeListMethod<Object>(
        method,
        {'path': path},
      );
      return (result ?? const <Object>[])
          .whereType<Map>()
          .map((item) {
            final name = item['name']?.toString().trim() ?? '';
            if (name.isEmpty) {
              return null;
            }
            final type = item['type']?.toString();
            return LocalDirectoryEntry(
              name: name,
              path: _joinPath(path, name),
              isDirectory: type == 'directory',
            );
          })
          .whereType<LocalDirectoryEntry>()
          .toList();
    } catch (_) {
      return const <LocalDirectoryEntry>[];
    }
  }

  static Future<Uint8List?> _readFileWithPrivilegedAccess(String path) async {
    if (!Platform.isAndroid) {
      return null;
    }
    final method = _androidPrivilegedAccessMethod('readFile');
    if (method == null) {
      return null;
    }
    try {
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
    } catch (_) {}
    return null;
  }

  static Future<bool> _existsWithPrivilegedAccess(String path) async {
    if (!Platform.isAndroid) {
      return false;
    }
    final method = _androidPrivilegedAccessMethod('exists');
    if (method == null) {
      return false;
    }
    try {
      return await _storageAccessChannel.invokeMethod<bool>(
            method,
            {'path': path},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static String? _androidPrivilegedAccessMethod(String operation) {
    final rootEnabled = normalizeAndroidRootMode(
            appdata.settings[androidRootModeSettingIndex]) ==
        '1';
    if (rootEnabled) {
      switch (operation) {
        case 'listDirectoryEntries':
          return 'listDirectoryEntriesWithRoot';
        case 'readFile':
          return 'readFileWithRoot';
        case 'exists':
          return 'existsWithRoot';
      }
    }

    final shizukuEnabled = normalizeAndroidShizukuMode(
          appdata.settings[androidShizukuModeSettingIndex],
        ) ==
        '1';
    if (shizukuEnabled) {
      switch (operation) {
        case 'listDirectoryEntries':
          return 'listDirectoryEntriesWithShizuku';
        case 'readFile':
          return 'readFileWithShizuku';
        case 'exists':
          return 'existsWithShizuku';
      }
    }
    return null;
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/').where((e) => e.isNotEmpty).toList();
    return segments.isEmpty ? path : segments.last;
  }

  static String _joinPath(String base, String child) {
    if (base.isEmpty) {
      return child;
    }
    return '$base${Platform.pathSeparator}$child';
  }
}
