import 'dart:io';

enum ArchiveFormat { zip, cbz, unknown }

ArchiveFormat archiveFormatForPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.cbz')) return ArchiveFormat.cbz;
  if (lower.endsWith('.zip')) return ArchiveFormat.zip;
  return ArchiveFormat.unknown;
}

bool isArchivePath(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.zip') || lower.endsWith('.cbz');
}

class ArchiveEntry {
  const ArchiveEntry({
    required this.path,
    required this.size,
    required this.isEncrypted,
    required this.isDirectory,
    this.isAesEncrypted = false,
    this.compressionMethod = 0,
  });

  final String path;
  final int size;
  final bool isEncrypted;
  final bool isDirectory;
  final bool isAesEncrypted;
  final int compressionMethod;

  String get name {
    final idx = path.lastIndexOf('/');
    return idx >= 0 ? path.substring(idx + 1) : path;
  }

  String get parentPath {
    final idx = path.lastIndexOf('/');
    return idx > 0 ? path.substring(0, idx) : '';
  }
}

class ArchiveProbeResult {
  const ArchiveProbeResult({
    required this.format,
    required this.isEncrypted,
    required this.entryCount,
    required this.imageEntryCount,
  });

  final ArchiveFormat format;
  final bool isEncrypted;
  final int entryCount;
  final int imageEntryCount;

  bool get hasImages => imageEntryCount > 0;
}

class ArchiveIndex {
  const ArchiveIndex({
    required this.archivePath,
    required this.format,
    required this.isEncrypted,
    required this.entries,
    required this.fileSize,
    required this.mtimeMillis,
  });

  final String archivePath;
  final ArchiveFormat format;
  final bool isEncrypted;
  final List<ArchiveEntry> entries;
  final int fileSize;
  final int mtimeMillis;

  List<ArchiveEntry> get imageEntries =>
      entries.where((e) => !e.isDirectory && _isImageEntry(e.path)).toList();
}

class ArchiveChapter {
  const ArchiveChapter({
    required this.index,
    required this.name,
    required this.entryPaths,
  });

  final int index;
  final String name;
  final List<String> entryPaths;
}

class ArchiveFingerprint {
  const ArchiveFingerprint({
    required this.fileSize,
    required this.mtimeMillis,
  });

  final int fileSize;
  final int mtimeMillis;

  @override
  String toString() => '${fileSize}_$mtimeMillis';
}

// archive:// URI format: archive://?path=<encoded>&entry=<encoded>
Uri buildArchiveUri(String archivePath, String entryPath) {
  return Uri(
    scheme: 'archive',
    host: '',
    queryParameters: {
      'path': archivePath,
      'entry': entryPath,
    },
  );
}

({String archivePath, String entryPath})? parseArchiveUri(String uriString) {
  try {
    final uri = Uri.parse(uriString);
    if (uri.scheme != 'archive') return null;
    final path = uri.queryParameters['path'];
    final entry = uri.queryParameters['entry'];
    if (path == null || entry == null) return null;
    return (archivePath: path, entryPath: entry);
  } catch (_) {
    return null;
  }
}

bool isArchiveUri(String uriString) {
  try {
    return Uri.parse(uriString).scheme == 'archive';
  } catch (_) {
    return false;
  }
}

bool _isImageEntry(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png') ||
      lower.endsWith('.webp');
}

bool isValidArchiveEntryPath(String entryPath) {
  if (entryPath.isEmpty) return false;
  if (entryPath.startsWith('/')) return false;
  final parts = entryPath.split('/');
  for (final part in parts) {
    if (part == '..') return false;
    if (part.isEmpty && parts.length > 1) return false;
    for (final ch in part.codeUnits) {
      if (ch < 0x20) return false;
    }
  }
  return true;
}

bool isHiddenArchiveEntry(String entryPath) {
  final parts = entryPath.split('/');
  for (final part in parts) {
    if (part.startsWith('.')) return true;
    if (part == '__MACOSX') return true;
  }
  return false;
}

Future<ArchiveFingerprint?> fingerprintForPath(String archivePath) async {
  try {
    final stat = await File(archivePath).stat();
    return ArchiveFingerprint(
      fileSize: stat.size,
      mtimeMillis: stat.modified.millisecondsSinceEpoch,
    );
  } catch (_) {
    return null;
  }
}
