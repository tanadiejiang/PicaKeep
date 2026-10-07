import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'image_disk_quota.dart';

enum DerivedImageUsage { cover, preview, readerLevel, readerTile }

class ImageTemporaryReservation {
  ImageTemporaryReservation._(this.bytes, this.purpose, this._release);
  final int bytes;
  final String purpose;
  final void Function() _release;
  ImageDiskReservation? _disk;
  bool _released = false;
  void release() {
    if (_released) return;
    _released = true;
    _release();
    final disk = _disk;
    if (disk != null) unawaited(disk.abort());
  }
}

/// Active workspaces have a separate finite peak; they are never LRU victims.
class ImageTemporaryPool {
  ImageTemporaryPool(
      {this.maximumBytes = 2 * 1024 * 1024 * 1024,
      this.maximumPerJob = 2 * 1024 * 1024 * 1024});
  static final shared = ImageTemporaryPool();
  final int maximumBytes, maximumPerJob;
  int _reserved = 0;
  int get reservedBytes => _reserved;
  ImageTemporaryReservation? reserve(int bytes, {required String purpose}) {
    if (bytes <= 0 ||
        bytes > maximumPerJob ||
        bytes > maximumBytes - _reserved) {
      return null;
    }
    _reserved += bytes;
    return ImageTemporaryReservation._(
        bytes, purpose, () => _reserved -= bytes);
  }

  Future<ImageTemporaryReservation> reserveOnDisk(int bytes,
      {required String purpose, required String path}) async {
    final value = reserve(bytes, purpose: purpose);
    if (value == null) {
      throw ImageDiskQuotaExceeded(
          '原文件暂存额度不足', bytes, maximumBytes - _reserved);
    }
    try {
      value._disk =
          await ImageDiskQuota.shared.admitWorkspace(path, peakBytes: bytes);
      return value;
    } catch (_) {
      value.release();
      rethrow;
    }
  }
}

class DerivedImageKey {
  const DerivedImageKey({
    required this.namespace,
    required this.resourceId,
    required this.sourceVersion,
    required this.usage,
    required this.variant,
    this.algorithmVersion = 1,
  });

  final String namespace;
  final String resourceId;
  final String sourceVersion;
  final DerivedImageUsage usage;
  final String variant;
  final int algorithmVersion;

  Map<String, Object> toJson() => {
        'namespace': namespace,
        'resourceId': resourceId,
        'sourceVersion': sourceVersion,
        'usage': usage.name,
        'variant': variant,
        'algorithmVersion': algorithmVersion,
      };

  String get token =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();
}

class DerivedImageEntry {
  const DerivedImageEntry({
    required this.key,
    required this.path,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.bytes,
    required this.digest,
    required this.lossless,
    required this.lastAccess,
  });

  final DerivedImageKey key;
  final String path;
  final String mimeType;
  final int width;
  final int height;
  final int bytes;
  final String digest;
  final bool lossless;
  final DateTime lastAccess;

  String get etag => '"$digest"';

  Map<String, Object> toJson() => {
        'schema': 1,
        'key': key.toJson(),
        'fileName': p.basename(path),
        'mimeType': mimeType,
        'width': width,
        'height': height,
        'bytes': bytes,
        'digest': digest,
        'lossless': lossless,
        'lastAccess': lastAccess.toIso8601String(),
        'complete': true,
      };
}

class DerivedImageLease {
  DerivedImageLease(this.entry, this._release);
  final DerivedImageEntry entry;
  final void Function() _release;
  bool _released = false;
  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

class DerivedImageStore {
  DerivedImageStore(String root,
      {this.maximumTemporaryBytes = 128 * 1024 * 1024, this.onPublished})
      : root = p.normalize(p.absolute(root)) {
    _stores.add(this);
    ImageDiskQuota.registerDerivedRoot(this.root);
  }

  final String root;
  final int maximumTemporaryBytes;
  final Future<void> Function(String publishedPath)? onPublished;
  static final Set<DerivedImageStore> _stores = {};
  static final Map<String, int> _temporaryLeases = {};
  static Future<void> Function(String publishedPath)? publicationObserver;
  final Map<String, int> _leases = {};
  final Map<String, DateTime> _touches = {};
  Timer? _touchTimer;
  int _generation = 0;
  int _reservedTemporaryBytes = 0;
  bool _disposed = false;

  int get generation => _generation;
  int get reservedTemporaryBytes => _reservedTemporaryBytes;
  int get activeLeases => _leases.values.fold(0, (a, b) => a + b);

  static void Function() protectPath(String path) {
    final key = _pathKey(path);
    _temporaryLeases.update(key, (value) => value + 1, ifAbsent: () => 1);
    var released = false;
    return () {
      if (released) return;
      released = true;
      final count = (_temporaryLeases[key] ?? 1) - 1;
      if (count <= 0) {
        _temporaryLeases.remove(key);
      } else {
        _temporaryLeases[key] = count;
      }
    };
  }

  static void Function() protectTemporaryPath(String path) => protectPath(path);

  void Function() protectOwnedPath(String path) {
    if (!_owns(path)) throw ArgumentError('Path outside derived root');
    final key = _pathKey(path);
    _leases.update(key, (value) => value + 1, ifAbsent: () => 1);
    var released = false;
    return () {
      if (released) return;
      released = true;
      final count = (_leases[key] ?? 1) - 1;
      if (count <= 0) {
        _leases.remove(key);
      } else {
        _leases[key] = count;
      }
      if (_disposed && _leases.isEmpty) _stores.remove(this);
    };
  }

  static bool isPathLeased(String path, {String? ignoringProtection}) =>
      _temporaryLeases.entries.any((lease) =>
          lease.value >
              (lease.key ==
                      (ignoringProtection == null
                          ? null
                          : _pathKey(ignoringProtection))
                  ? 1
                  : 0) &&
          (_pathKey(path) == lease.key ||
              _pathKey(path).startsWith('${lease.key}.'))) ||
      _stores.any((store) => store._leases.keys.any((protected) =>
          _pathKey(path) == protected ||
          _pathKey(path).startsWith('$protected.')));

  /// Invalidate writers before a global cache clear starts traversing files.
  static void invalidateWithin(String cacheRoot) {
    for (final store in _stores) {
      if (p.equals(store.root, cacheRoot) ||
          p.isWithin(cacheRoot, store.root)) {
        store._generation++;
        store._touches.clear();
      }
    }
  }

  File _index(DerivedImageKey key) =>
      File(p.join(root, key.usage.name, '${key.token}.json'));

  Future<DerivedImageEntry?> lookup(DerivedImageKey key,
      {bool verifyDigest = true}) async {
    if (_disposed) return null;
    final index = _index(key);
    try {
      if (await FileSystemEntity.type(index.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final stat = await index.stat();
      if (stat.size > 16 * 1024) return null;
      final json = jsonDecode(await index.readAsString());
      if (json is! Map ||
          json['schema'] != 1 ||
          json['complete'] != true ||
          jsonEncode(json['key']) != jsonEncode(key.toJson())) {
        return null;
      }
      final name = json['fileName'];
      if (name is! String ||
          p.basename(name) != name ||
          !name.startsWith(key.token)) {
        return null;
      }
      final file = File(p.join(index.parent.path, name));
      if (!_owns(file.path) ||
          await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
        return null;
      }
      final bytes = json['bytes'];
      final width = json['width'];
      final height = json['height'];
      final digest = json['digest'];
      if (bytes is! int ||
          bytes <= 0 ||
          width is! int ||
          width <= 0 ||
          height is! int ||
          height <= 0 ||
          digest is! String ||
          await file.length() != bytes) {
        return null;
      }
      if (verifyDigest &&
          (await sha256.bind(file.openRead()).first).toString() != digest) {
        return null;
      }
      _touches[index.path] = DateTime.now();
      _touches[file.path] = DateTime.now();
      _touchTimer ??=
          Timer(const Duration(seconds: 5), () => unawaited(_flushTouches()));
      return DerivedImageEntry(
        key: key,
        path: file.path,
        mimeType: json['mimeType'] as String,
        width: width,
        height: height,
        bytes: bytes,
        digest: digest,
        lossless: json['lossless'] == true,
        lastAccess: stat.modified,
      );
    } on Object {
      return null;
    }
  }

  DerivedImageLease lease(DerivedImageEntry entry) {
    if (_disposed || !_owns(entry.path)) {
      throw StateError('Invalid derived lease');
    }
    final key = _pathKey(entry.path);
    final indexKey = _pathKey(_index(entry.key).path);
    for (final path in [key, indexKey]) {
      _leases.update(path, (value) => value + 1, ifAbsent: () => 1);
    }
    return DerivedImageLease(entry, () {
      for (final path in [key, indexKey]) {
        final count = (_leases[path] ?? 1) - 1;
        if (count <= 0) {
          _leases.remove(path);
        } else {
          _leases[path] = count;
        }
      }
      if (_disposed && _leases.isEmpty) _stores.remove(this);
    });
  }

  Future<DerivedImageEntry?> put({
    required DerivedImageKey key,
    required Stream<List<int>> content,
    required String mimeType,
    required int width,
    required int height,
    required bool lossless,
    required int maximumBytes,
    required bool Function() canPublish,
  }) async {
    if (_disposed ||
        maximumBytes <= 0 ||
        width <= 0 ||
        height <= 0 ||
        maximumBytes > maximumTemporaryBytes - _reservedTemporaryBytes) {
      return null;
    }
    if ((key.usage == DerivedImageUsage.readerLevel ||
            key.usage == DerivedImageUsage.readerTile) &&
        !lossless) {
      throw ArgumentError('Formal reader derivatives must be lossless');
    }
    final extension = switch (mimeType) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      _ => throw ArgumentError('Unsupported derivative format'),
    };
    final globalReservation = ImageTemporaryPool.shared
        .reserve(maximumBytes, purpose: 'derivative-publish:${key.usage.name}');
    if (globalReservation == null) return null;
    final ownGeneration = _generation;
    _reservedTemporaryBytes += maximumBytes;
    final index = _index(key);
    ImageDiskReservation? disk;
    final nonce = DateTime.now().microsecondsSinceEpoch;
    final temporary =
        File(p.join(index.parent.path, '${key.token}.$nonce.part'));
    final indexPart = File('${index.path}.$nonce.part');
    File? published;
    IOSink? sink;
    try {
      disk = await ImageDiskQuota.shared.admitPublication(
          p.join(index.parent.path, key.token),
          maximumBytes: maximumBytes);
      await index.parent.create(recursive: true);
      if (!await _safeDirectory(index.parent.path)) return null;
      sink = temporary.openWrite();
      var written = 0;
      await for (final chunk in content) {
        if (_disposed || _generation != ownGeneration || !canPublish()) {
          return null;
        }
        written += chunk.length;
        if (written > maximumBytes) return null;
        sink.add(chunk);
        // Bound queued sink buffers, including non-file source streams.
        await sink.flush();
      }
      await sink.close();
      sink = null;
      if (written == 0 || _generation != ownGeneration || !canPublish()) {
        return null;
      }
      final digest = (await sha256.bind(temporary.openRead()).first).toString();
      final destination =
          File(p.join(index.parent.path, '${key.token}.$digest.$extension'));
      if (_generation != ownGeneration || !canPublish()) return null;
      if (await destination.exists()) {
        await temporary.delete();
      } else {
        await temporary.rename(destination.path);
        published = destination;
      }
      final entry = DerivedImageEntry(
        key: key,
        path: destination.path,
        mimeType: mimeType,
        width: width,
        height: height,
        bytes: written,
        digest: digest,
        lossless: lossless,
        lastAccess: DateTime.now(),
      );
      await indexPart.writeAsString(jsonEncode(entry.toJson()), flush: true);
      if (_disposed || _generation != ownGeneration || !canPublish()) {
        return null;
      }
      await indexPart.rename(index.path);
      published = null;
      scheduleMaintenance(entry.path, fallback: onPublished);
      await disk.commit([entry.path, index.path]);
      return entry;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      for (final file in [temporary, indexPart, published]) {
        if (file == null ||
            isPathLeased(file.path,
                ignoringProtection: p.join(index.parent.path, key.token))) {
          continue;
        }
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      _reservedTemporaryBytes -= maximumBytes;
      globalReservation.release();
      await disk?.abort();
    }
  }

  /// Keep the new body leased until detached quota maintenance completes.
  /// Publishing and first paint never wait for a directory inventory.
  static void scheduleMaintenance(String publishedPath,
      {Future<void> Function(String publishedPath)? fallback}) {
    final observer = publicationObserver ?? fallback;
    if (observer == null) return;
    final release = protectTemporaryPath(publishedPath);
    unawaited(Future<void>(() async {
      try {
        await observer(publishedPath);
      } catch (_) {
        // Reproducible-cache maintenance is independent from image success.
      } finally {
        release();
      }
    }));
  }

  Future<void> clear() async {
    _generation++;
    _touches.clear();
    await _deleteUnleased();
  }

  Future<void> _deleteUnleased() async {
    if (!await _safeDirectory(root)) return;
    await for (final entity
        in Directory(root).list(recursive: true, followLinks: false)) {
      if (entity is! File || !_owns(entity.path) || isPathLeased(entity.path)) {
        continue;
      }
      try {
        await entity.delete();
      } on FileSystemException {
        // A busy cache file is retained for the next maintenance pass.
      }
    }
  }

  Future<void> _flushTouches() async {
    _touchTimer = null;
    final updates = Map<String, DateTime>.of(_touches);
    _touches.clear();
    final ownGeneration = _generation;
    for (final update in updates.entries) {
      if (_disposed || ownGeneration != _generation) break;
      try {
        final file = File(update.key);
        if (!_owns(file.path) || !await file.exists()) continue;
        // Access accounting is independent from the source-version stamp.
        await file.setLastModified(update.value);
      } on FileSystemException {
        // Access accounting must not turn a successful read into a failure.
      }
    }
  }

  bool _owns(String path) => p.isWithin(root, p.normalize(p.absolute(path)));

  Future<bool> _safeDirectory(String path) async {
    var current = p.normalize(p.absolute(path));
    while (p.equals(current, root) || p.isWithin(root, current)) {
      if (await FileSystemEntity.type(current, followLinks: false) !=
          FileSystemEntityType.directory) {
        return false;
      }
      if (p.equals(current, root)) return true;
      current = p.dirname(current);
    }
    return false;
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _touchTimer?.cancel();
    _touchTimer = null;
    _touches.clear();
    // Leased files remain protected until their consumers release them.
    if (_leases.isEmpty) _stores.remove(this);
  }

  static String _pathKey(String path) {
    final normalized = p.normalize(p.absolute(path));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}
