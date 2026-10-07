import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// An inventory is only a deletion candidate list, never deletion authority.
class CacheFileSnapshot {
  const CacheFileSnapshot(this.path, this.size, this.modified, this.changed);

  final String path;
  final int size;
  final DateTime modified;
  final DateTime changed;
}

class CacheFileInventory {
  const CacheFileInventory(this.totalBytes, this.files,
      {this.purposeBytes = const {}});

  final int totalBytes;
  final List<CacheFileSnapshot> files;
  final Map<String, int> purposeBytes;
}

/// Inactive decoded scratch yields space before ordinary cache rasters;
/// modification time still orders candidates within each class. This only
/// orders candidates: ownership, leases and source-stat checks decide deletion.
int compareCacheEvictionCandidates(CacheFileSnapshot a, CacheFileSnapshot b) {
  final purpose = _evictionRank(a.path).compareTo(_evictionRank(b.path));
  return purpose != 0 ? purpose : a.modified.compareTo(b.modified);
}

int _evictionRank(String path) {
  // Match parent directory components exactly. Similar names or a filename
  // alone must not promote an ordinary cache image into decoded scratch.
  final directories = p.split(p.dirname(path));
  return directories.any((component) {
    final name = component.toLowerCase();
    return name == 'native_backing' || name == 'cover_backing';
  })
      ? 0
      : 1;
}

typedef CacheEvictionSorter = Future<List<CacheFileSnapshot>> Function(
    List<CacheFileSnapshot> files);

/// Ranking and sorting are CPU work, even when no files need statting. A cache
/// tree may contain thousands of entries, so do both on a worker and parse each
/// path only once. The returned ordering grants no authority to delete files.
Future<List<CacheFileSnapshot>> sortCacheEvictionCandidates(
        List<CacheFileSnapshot> files) =>
    Isolate.run(() {
      final ranked = [
        for (final file in files) (file: file, rank: _evictionRank(file.path)),
      ];
      ranked.sort((a, b) {
        final purpose = a.rank.compareTo(b.rank);
        return purpose != 0
            ? purpose
            : a.file.modified.compareTo(b.file.modified);
      });
      return [for (final candidate in ranked) candidate.file];
    }, debugName: 'cache-eviction-order');

String _cachePurpose(String path) {
  final parts = p.split(path).map((part) => part.toLowerCase()).toSet();
  if (path.endsWith('.part') ||
      path.endsWith('.partial') ||
      parts.contains('work') ||
      parts.contains('native_backing') ||
      parts.contains('cover_backing')) {
    return 'workspace';
  }
  if (parts.contains('readertile')) return 'readerTile';
  if (parts.contains('readerlevel')) return 'readerLevel';
  if (parts.contains('preview')) return 'preview';
  if (parts.contains('covers') ||
      parts.contains('cover') ||
      parts.contains('remote_library_covers')) {
    return 'cover';
  }
  if (parts.contains('inputs') ||
      parts.contains('online_images') ||
      parts.contains('reader_original') ||
      parts.contains('reader_sources')) {
    return 'original';
  }
  return 'other';
}

/// Walking / statting / sorting a cache tree must not compete with UI frames.
/// Only paths cross the isolate boundary; App state and live leases stay out.
Future<CacheFileInventory> scanCacheFiles(List<String> roots,
        {bool includePartial = false}) =>
    Isolate.run(
      () => _scanCacheFiles(roots, includePartial),
      debugName: 'cache-file-inventory',
    );

String _pathKey(String path) => Platform.isWindows ? path.toLowerCase() : path;

CacheFileInventory _scanCacheFiles(List<String> roots, bool includePartial) {
  final visited = <String>{};
  final pending = roots
      .where((root) => root.trim().isNotEmpty)
      .map((root) => p.normalize(p.absolute(root)))
      .toList();
  final files = <CacheFileSnapshot>[];
  var totalBytes = 0;
  final purposeBytes = <String, int>{};
  while (pending.isNotEmpty) {
    final path = pending.removeLast();
    if (!visited.add(_pathKey(path))) continue;
    try {
      // Do not follow symlinks, including a root that is itself a link.
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        pending.addAll(Directory(path)
            .listSync(followLinks: false)
            .where((entry) => entry is File || entry is Directory)
            .map((entry) => p.normalize(entry.path)));
      } else if (type == FileSystemEntityType.file) {
        final stat = File(path).statSync();
        if (stat.type != FileSystemEntityType.file) continue;
        totalBytes += stat.size;
        final purpose = _cachePurpose(path);
        purposeBytes.update(purpose, (value) => value + stat.size,
            ifAbsent: () => stat.size);
        if (stat.size > 0 && (includePartial || !path.endsWith('.part'))) {
          files.add(
              CacheFileSnapshot(path, stat.size, stat.modified, stat.changed));
        }
      }
    } on FileSystemException {
      // A removed/unreadable subtree cannot abort the remaining cache roots.
    }
  }
  files.sort((a, b) => a.modified.compareTo(b.modified));
  return CacheFileInventory(totalBytes, files, purposeBytes: purposeBytes);
}

/// Run on the caller isolate, where root identity and leases are authoritative.
/// Files created/replaced after inventory are left for the next maintenance.
Future<void> trimCacheInventory(
  CacheFileInventory inventory, {
  required int limitBytes,
  required bool Function() isCurrent,
  required bool Function(String path) isProtected,
  CacheEvictionSorter sortCandidates = sortCacheEvictionCandidates,
}) async {
  if (limitBytes <= 0 || inventory.totalBytes <= limitBytes || !isCurrent()) {
    return;
  }
  var remaining = inventory.totalBytes;
  final candidates = await sortCandidates(inventory.files);
  if (!isCurrent()) return;
  for (final candidate in candidates) {
    if (remaining <= limitBytes || !isCurrent()) break;
    if (isProtected(candidate.path) || candidate.path.endsWith('.part')) {
      continue;
    }
    try {
      if (await FileSystemEntity.type(candidate.path, followLinks: false) !=
          FileSystemEntityType.file) {
        remaining -= candidate.size;
        continue;
      }
      final file = File(candidate.path);
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) {
        remaining -= candidate.size;
        continue;
      }
      if (stat.type != FileSystemEntityType.file) continue;
      if (stat.size != candidate.size ||
          stat.modified != candidate.modified ||
          stat.changed != candidate.changed) {
        remaining += stat.size - candidate.size;
        continue;
      }
      // Both filesystem awaits may have allowed a new reader/root to arrive.
      if (!isCurrent()) break;
      if (isProtected(candidate.path)) continue;
      await file.delete();
      remaining -= candidate.size;
    } on FileSystemException {
      // A disappeared/busy file does not justify deleting outside this list.
    }
  }
}
