import 'dart:io';
import 'dart:async';

import 'package:flutter/services.dart';

import '../base.dart';
import 'package:picakeep/foundation/local_library_settings.dart';

class PrivilegedFileStat {
  const PrivilegedFileStat({required this.size, required this.modifiedMillis});
  final int size;
  final int modifiedMillis;
}

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

  static Future<PrivilegedFileStat?> fileStat(String path) async {
    final method = _androidPrivilegedAccessMethod('statFile');
    // In privileged mode a visible mountpoint does not establish readability.
    if (Platform.isAndroid && method != null) {
      final result = await _storageAccessChannel
          .invokeMapMethod<String, Object>(method, {'path': path});
      if (result == null) return null;
      return PrivilegedFileStat(
        size: (result['size'] as num).toInt(),
        modifiedMillis: (result['modifiedMillis'] as num).toInt(),
      );
    }
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
    if (copyCancelled()) {
      throw StateError('Original file copy cancelled');
    }
    await destination.parent.create(recursive: true);
    final method = _androidPrivilegedAccessMethod('copyFileToManaged');
    if (Platform.isAndroid && method != null) {
      final requestId =
          '${DateTime.now().microsecondsSinceEpoch}-${destination.path.hashCode}';
      var finished = false;
      final stat = await fileStat(sourcePath);
      if (stat == null) {
        throw FileSystemException('Original file is unavailable', sourcePath);
      }
      if (stat.size > maxBytes) {
        throw StateError('Original file exceeds reserved disk bytes');
      }
      if (copyCancelled()) throw StateError('Original file copy cancelled');
      // Register only once a native job will be sent. An aborted stat/preflight
      // must not leave a cancellation ID with no job to remove it.
      if (cancelled != null) {
        unawaited(cancelled.then((_) async {
          if (!finished) {
            try {
              await _storageAccessChannel.invokeMethod<Object>(
                  'cancelCopyToManaged', {'requestId': requestId});
            } catch (_) {}
          }
        }));
      }
      try {
        await _storageAccessChannel.invokeMethod<Object>(method, {
          'path': sourcePath,
          'destination': destination.path,
          'maxBytes': maxBytes,
          'requestId': requestId,
        });
      } finally {
        finished = true;
      }
      if (copyCancelled()) {
        if (await destination.exists()) await destination.delete();
        throw StateError('Original file copy cancelled');
      }
      return destination;
    }
    final stat = await fileStat(sourcePath);
    if (stat == null) {
      throw FileSystemException('Original file is unavailable', sourcePath);
    }
    if (stat.size > maxBytes) {
      throw StateError('Original file exceeds reserved disk bytes');
    }
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

  /// Returns `true` if [path] refers to an existing directory, consulting
  /// the privileged channel when `dart:io` cannot see it.
  static Future<bool> directoryExists(String path) async {
    try {
      if (await Directory(path).exists()) {
        return true;
      }
    } catch (_) {}
    return _existsWithPrivilegedAccess(path);
  }

  /// Returns `true` if [path] refers to an existing file, consulting the
  /// privileged channel when `dart:io` cannot see it.
  static Future<bool> fileExists(String path) async {
    try {
      if (await File(path).exists()) {
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
      if (await file.exists()) {
        return await file.length();
      }
    } catch (_) {}
    return (await fileStat(path))?.size;
  }

  /// Reads the full contents of [path]. Returns `null` when the file does
  /// not exist or neither `dart:io` nor the privileged channel can read it.
  static Future<Uint8List?> readFileBytes(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        // 同 listDirectoryEntries：root/shizuku 下 existsSync()=true 但读到空字节
        // 可能是 scoped storage 静默拦截，回退特权通道。真正的空文件极少见，
        // 回退在通道未启用时返回 null，调用方按读取失败处理，无副作用。
        if (bytes.isNotEmpty) {
          return bytes;
        }
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
      if (await directory.exists()) {
        final entries = (await directory.list(followLinks: false).toList())
            .where((entity) => entity is Directory || entity is File)
            .map(
              (entity) => LocalDirectoryEntry(
                name: _basename(entity.path),
                path: entity.path,
                isDirectory: entity is Directory,
              ),
            )
            .toList();
        // dart:io 列出非空才直接采用。root/shizuku 模式下，受 scoped storage 限制的
        // 任意外部路径（如用户自定义图集目录）常出现 existsSync()=true 但 listSync()
        // 静默返回空（不抛异常）的情况——此时必须回退到特权通道，否则图集扫不到内容、
        // 连阅读都打不开。空目录与"被静默拦截"无法区分，故空时一律尝试特权通道；
        // 通道未启用（非 root/shizuku）会返回空，结果等价于原空列表，无副作用。
        if (entries.isNotEmpty) {
          return entries;
        }
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
        case 'statFile':
          return 'statFileWithRoot';
        case 'copyFileToManaged':
          return 'copyFileToManagedWithRoot';
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
        case 'statFile':
          return 'statFileWithShizuku';
        case 'copyFileToManaged':
          return 'copyFileToManagedWithShizuku';
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
