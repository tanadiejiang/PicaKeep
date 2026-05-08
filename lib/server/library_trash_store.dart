import 'dart:convert';
import 'dart:io';

import 'local_resource_scanner.dart';

const serverTrashDirectoryName = '.picakeep_trash';

String _joinServerTrashPath(String parent, String child) {
  return '$parent${Platform.pathSeparator}$child';
}

String _basenameServerTrashPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/').where((entry) => entry.isNotEmpty).toList();
  return segments.isEmpty ? normalized : segments.last;
}

String _relativeServerTrashPath(String path, String from) {
  final normalizedPath = path.replaceAll('\\', '/');
  final normalizedFrom = from.replaceAll('\\', '/');
  if (!normalizedPath.startsWith(normalizedFrom)) {
    return _basenameServerTrashPath(path);
  }
  final relative = normalizedPath.substring(normalizedFrom.length);
  return relative.replaceFirst(RegExp(r'^/+'), '');
}

class LibraryTrashEntry {
  const LibraryTrashEntry({
    required this.id,
    required this.itemId,
    required this.rootId,
    required this.title,
    required this.subtitle,
    required this.sourceDisplayName,
    required this.tags,
    required this.originalPath,
    required this.trashedPath,
    required this.coverRelativePath,
    required this.imageCount,
    required this.totalBytes,
    required this.deletedAt,
  });

  final String id;
  final String itemId;
  final String rootId;
  final String title;
  final String subtitle;
  final String sourceDisplayName;
  final List<String> tags;
  final String originalPath;
  final String trashedPath;
  final String coverRelativePath;
  final int imageCount;
  final int totalBytes;
  final DateTime deletedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'itemId': itemId,
        'rootId': rootId,
        'title': title,
        'subtitle': subtitle,
        'sourceDisplayName': sourceDisplayName,
        'tags': tags,
        'originalPath': originalPath,
        'trashedPath': trashedPath,
        'coverRelativePath': coverRelativePath,
        'imageCount': imageCount,
        'totalBytes': totalBytes,
        'deletedAt': deletedAt.toIso8601String(),
      };

  factory LibraryTrashEntry.fromJson(Map<String, dynamic> json) {
    return LibraryTrashEntry(
      id: (json['id'] as String? ?? '').trim(),
      itemId: (json['itemId'] as String? ?? '').trim(),
      rootId: (json['rootId'] as String? ?? '').trim(),
      title: (json['title'] as String? ?? '').trim(),
      subtitle: (json['subtitle'] as String? ?? '').trim(),
      sourceDisplayName: (json['sourceDisplayName'] as String? ?? '').trim(),
      tags: (json['tags'] is List)
          ? (json['tags'] as List)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList(growable: false)
          : const <String>[],
      originalPath: (json['originalPath'] as String? ?? '').trim(),
      trashedPath: (json['trashedPath'] as String? ?? '').trim(),
      coverRelativePath: (json['coverRelativePath'] as String? ?? '').trim(),
      imageCount: (json['imageCount'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      deletedAt: DateTime.tryParse((json['deletedAt'] as String? ?? '').trim()) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class LibraryTrashStore {
  LibraryTrashStore(this.indexPath);

  final String indexPath;
  List<LibraryTrashEntry>? _cache;

  Future<List<LibraryTrashEntry>> listEntries() async {
    final loaded = await _load();
    return loaded.toList()
      ..sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
  }

  Future<LibraryTrashEntry?> findById(String id) async {
    final normalized = id.trim();
    if (normalized.isEmpty) {
      return null;
    }
    final loaded = await _load();
    for (final entry in loaded) {
      if (entry.id == normalized) {
        return entry;
      }
    }
    return null;
  }

  Future<LibraryTrashEntry> moveItemToTrash({
    required ServerResourceItemSummary item,
    required String rootPath,
  }) async {
    final sourceDir = Directory(item.path);
    if (!sourceDir.existsSync()) {
      throw const FileSystemException('item path not found');
    }
    final trashRoot = Directory(_joinServerTrashPath(rootPath, serverTrashDirectoryName));
    trashRoot.createSync(recursive: true);
    final entryId = _generateEntryId();
    final trashedPath = _joinServerTrashPath(trashRoot.path, entryId);
    final entry = LibraryTrashEntry(
      id: entryId,
      itemId: item.id,
      rootId: item.rootId,
      title: item.title,
      subtitle: item.subtitle,
      sourceDisplayName: item.sourceDisplayName,
      tags: item.tags,
      originalPath: item.path,
      trashedPath: trashedPath,
      coverRelativePath: _coverRelativePath(item),
      imageCount: item.imageCount,
      totalBytes: item.totalBytes,
      deletedAt: DateTime.now(),
    );
    await _moveDirectory(sourceDir, Directory(trashedPath));
    final loaded = await _load();
    loaded.add(entry);
    await _save(loaded);
    return entry;
  }

  Future<LibraryTrashEntry> restoreItem(String id) async {
    final loaded = await _load();
    final entry = loaded.firstWhere(
      (item) => item.id == id,
      orElse: () => throw StateError('trash entry not found'),
    );
    final trashedDir = Directory(entry.trashedPath);
    if (!trashedDir.existsSync()) {
      throw const FileSystemException('trashed directory not found');
    }
    final originalDir = Directory(entry.originalPath);
    if (originalDir.existsSync()) {
      throw const FileSystemException('original path already exists');
    }
    originalDir.parent.createSync(recursive: true);
    await _moveDirectory(trashedDir, originalDir);
    loaded.removeWhere((item) => item.id == id);
    await _save(loaded);
    return entry;
  }

  Future<LibraryTrashEntry?> purgeItem(String id) async {
    final loaded = await _load();
    final index = loaded.indexWhere((item) => item.id == id);
    if (index < 0) {
      return null;
    }
    final entry = loaded[index];
    final dir = Directory(entry.trashedPath);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    loaded.removeAt(index);
    await _save(loaded);
    return entry;
  }

  File coverFileFor(LibraryTrashEntry entry) {
    final relative = entry.coverRelativePath.trim();
    if (relative.isEmpty) {
      return File('');
    }
    return File(_joinServerTrashPath(entry.trashedPath, relative));
  }

  Future<List<LibraryTrashEntry>> _load() async {
    final cached = _cache;
    if (cached != null) {
      return cached;
    }
    final file = File(indexPath);
    if (!file.existsSync()) {
      _cache = <LibraryTrashEntry>[];
      return _cache!;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        _cache = decoded
            .whereType<Map>()
            .map((entry) => LibraryTrashEntry.fromJson(
                  entry.map((key, value) => MapEntry(key.toString(), value)),
                ))
            .toList(growable: true);
        return _cache!;
      }
    } catch (_) {}
    _cache = <LibraryTrashEntry>[];
    return _cache!;
  }

  Future<void> _save(List<LibraryTrashEntry> items) async {
    final file = File(indexPath);
    file.parent.createSync(recursive: true);
    await file.writeAsString(
      jsonEncode(items.map((item) => item.toJson()).toList(growable: false)),
    );
    _cache = items;
  }

  String _coverRelativePath(ServerResourceItemSummary item) {
    final coverPath = item.coverPath?.trim() ?? '';
    if (coverPath.isEmpty) {
      return '';
    }
    try {
      return _relativeServerTrashPath(coverPath, item.path);
    } catch (_) {
      return _basenameServerTrashPath(coverPath);
    }
  }

  String _generateEntryId() {
    final time = DateTime.now().microsecondsSinceEpoch;
    final salt = (_cache?.length ?? 0).toString();
    return 'srvtrash_${time}_$salt';
  }

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
    await for (final entity in source.list(recursive: false, followLinks: false)) {
      if (entity is Directory) {
        await _copyDirectory(
          entity,
          Directory(_joinServerTrashPath(
            destination.path,
            _basenameServerTrashPath(entity.path),
          )),
        );
      } else if (entity is File) {
        await entity.copy(
          _joinServerTrashPath(destination.path, _basenameServerTrashPath(entity.path)),
        );
      }
    }
  }
}