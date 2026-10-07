import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';

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
  static const maxInputBytes = 512 * 1024 * 1024;
  final _leases = <String, int>{};
  final _diskFiles = <String, ImageDiskReservation>{};
  DateTime? _lastTrim;
  Future<void>? _trimInFlight;

  void Function() lease(File file) {
    _leases.update(file.path, (v) => v + 1, ifAbsent: () => 1);
    final releaseBody = DerivedImageStore.protectPath(file.path);
    final releaseMetadata =
        DerivedImageStore.protectPath('${p.withoutExtension(file.path)}.json');
    var released = false;
    return () {
      if (released) return;
      released = true;
      releaseBody();
      releaseMetadata();
      final n = (_leases[file.path] ?? 1) - 1;
      if (n == 0) {
        _leases.remove(file.path);
        final disk = _diskFiles.remove(file.path);
        if (disk != null) unawaited(disk.abort());
      } else {
        _leases[file.path] = n;
      }
    };
  }

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
      if (!await file.exists() || await file.length() != meta['length']) {
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
  }) =>
      putStream(url, Stream.value(bytes),
          contentType: contentType, expectedBytes: bytes.length);

  Future<File> putStream(String identity, Stream<List<int>> stream,
      {String contentType = '', int? expectedBytes}) async {
    await _root.create(recursive: true);
    final key = keyForUrl(identity);
    final extension = _extensionFromContentType(contentType);
    final file = _dataFile(key, extension);
    if (_leases.containsKey(file.path)) {
      throw StateError('An original cache body is still leased');
    }
    final part = File('${file.path}.part');
    final maximum = expectedBytes != null && expectedBytes > 0
        ? expectedBytes
        : maxInputBytes;
    if (maximum > maxInputBytes) {
      throw StateError('Image file exceeds disk budget');
    }
    ImageTemporaryReservation? temporary;
    ImageDiskReservation? disk;
    final oldBytes = await file.exists() ? await file.length() : 0;
    temporary =
        ImageTemporaryPool.shared.reserve(maximum, purpose: 'online-original');
    if (temporary == null) {
      throw StateError('Image source workspace budget exhausted');
    }
    try {
      disk = await ImageDiskQuota.shared.admitWorkspace(
          p.withoutExtension(file.path),
          peakBytes: oldBytes + maximum + 16 * 1024);
    } catch (_) {
      temporary.release();
      rethrow;
    }
    var length = 0;
    final sink = part.openWrite();
    try {
      await sink.addStream(stream.map((chunk) {
        length += chunk.length;
        if (length > maximum) {
          throw StateError('Image file exceeds disk budget');
        }
        return chunk;
      }));
      await sink.flush();
      await sink.close();
      if (length == 0) throw StateError('Empty image response');
      if (expectedBytes != null && length != expectedBytes) {
        throw StateError('Image response length changed');
      }
      if (_leases.containsKey(file.path)) {
        throw StateError(
            'An original cache body was leased during publication');
      }
      if (await file.exists()) await file.delete();
      await part.rename(file.path);
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {/* Preserve the stream failure. */}
      if (await part.exists()) await part.delete();
      await disk.abort();
      temporary.release();
      rethrow;
    }
    final metaPart = File('${_metaFile(key).path}.part');
    try {
      await metaPart.writeAsString(
        jsonEncode({
          'extension': extension,
          'contentType': contentType,
          'updatedAt': DateTime.now().toIso8601String(),
          'length': length,
        }),
        flush: true,
      );
      if (await _metaFile(key).exists()) await _metaFile(key).delete();
      await metaPart.rename(_metaFile(key).path);
      await disk.finishWorkspace();
      final previous = _diskFiles[file.path];
      _diskFiles[file.path] = disk;
      await previous?.abort();
    } catch (_) {
      if (await metaPart.exists()) await metaPart.delete();
      await disk.abort();
      rethrow;
    } finally {
      temporary.release();
    }
    final releaseFresh = lease(file);
    Timer(const Duration(seconds: 5), releaseFresh);
    // Publication does not wait for global directory maintenance.
    if (_trimInFlight == null &&
        (_lastTrim == null ||
            DateTime.now().difference(_lastTrim!) >
                const Duration(seconds: 30))) {
      _lastTrim = DateTime.now();
      _trimInFlight = trim(maxBytes: 256 * 1024 * 1024)
          .whenComplete(() => _trimInFlight = null);
    }
    return file;
  }

  Future<void> trim({required int maxBytes}) async {
    if (!await _root.exists()) {
      return;
    }
    final files = <File>[];
    try {
      await for (final entity in _root.list(followLinks: false)) {
        if (entity is File &&
            !entity.path.endsWith('.json') &&
            !entity.path.endsWith('.part')) {
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
      if (_leases.containsKey(item.file.path)) continue;
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
