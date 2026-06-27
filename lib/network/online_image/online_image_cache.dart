import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:picakeep/foundation/app.dart';

class OnlineImageCacheEntry {
  const OnlineImageCacheEntry({
    required this.file,
    required this.contentType,
  });

  final File file;
  final String contentType;
}

class OnlineImageCache {
  OnlineImageCache._();

  static final OnlineImageCache instance = OnlineImageCache._();

  Directory get _root =>
      Directory('${App.cachePath}${Platform.pathSeparator}online_images');

  File _metaFile(String key) =>
      File('${_root.path}${Platform.pathSeparator}$key.json');

  File _dataFile(String key, String extension) =>
      File('${_root.path}${Platform.pathSeparator}$key.$extension');

  String keyForUrl(String url) => sha1.convert(utf8.encode(url)).toString();

  Future<OnlineImageCacheEntry?> get(String url) async {
    final key = keyForUrl(url);
    final metaFile = _metaFile(key);
    if (!await metaFile.exists()) {
      return null;
    }
    try {
      final meta = jsonDecode(await metaFile.readAsString());
      if (meta is! Map) {
        return null;
      }
      final extension = meta['extension']?.toString() ?? 'img';
      final contentType = meta['contentType']?.toString() ?? '';
      final file = _dataFile(key, extension);
      if (!await file.exists()) {
        return null;
      }
      return OnlineImageCacheEntry(file: file, contentType: contentType);
    } catch (_) {
      return null;
    }
  }

  Future<File> put(
    String url,
    List<int> bytes, {
    String contentType = '',
  }) async {
    await _root.create(recursive: true);
    final key = keyForUrl(url);
    final extension = _extensionFromContentType(contentType);
    final file = _dataFile(key, extension);
    await file.writeAsBytes(bytes, flush: true);
    await _metaFile(key).writeAsString(
      jsonEncode({
        'url': url,
        'extension': extension,
        'contentType': contentType,
        'updatedAt': DateTime.now().toIso8601String(),
        'length': bytes.length,
      }),
      flush: true,
    );
    await trim(maxBytes: 256 * 1024 * 1024);
    return file;
  }

  Future<void> trim({required int maxBytes}) async {
    if (!await _root.exists()) {
      return;
    }
    final files = <File>[];
    try {
      await for (final entity in _root.list(followLinks: false)) {
        if (entity is File && !entity.path.endsWith('.json')) {
          files.add(entity);
        }
      }
    } on FileSystemException {
      return;
    }
    var total = 0;
    final stats = <({File file, DateTime modified, int size})>[];
    for (final file in files) {
      try {
        final stat = await file.stat();
        total += stat.size;
        stats.add((file: file, modified: stat.modified, size: stat.size));
      } catch (_) {}
    }
    if (total <= maxBytes) {
      return;
    }
    stats.sort((a, b) => a.modified.compareTo(b.modified));
    for (final item in stats) {
      if (total <= maxBytes) {
        break;
      }
      try {
        await item.file.delete();
        total -= item.size;
        final basename = item.file.uri.pathSegments.last;
        final key = basename.contains('.')
            ? basename.substring(0, basename.lastIndexOf('.'))
            : basename;
        final meta = _metaFile(key);
        if (await meta.exists()) {
          await meta.delete();
        }
      } catch (_) {}
    }
  }

  String _extensionFromContentType(String contentType) {
    final lower = contentType.toLowerCase();
    if (lower.contains('jpeg') || lower.contains('jpg')) return 'jpg';
    if (lower.contains('png')) return 'png';
    if (lower.contains('webp')) return 'webp';
    if (lower.contains('gif')) return 'gif';
    return 'img';
  }
}
