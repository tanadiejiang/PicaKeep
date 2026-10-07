import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

import '../../base.dart';
import '../app.dart';
import '../cache_file_inventory.dart';
import '../local_cover_cache.dart';
import 'derived_image_store.dart';

class ImageDiskSpace {
  const ImageDiskSpace(this.availableBytes, this.volumeId);
  final int availableBytes;
  final String volumeId;
}

class ImageDiskQuotaExceeded implements Exception {
  const ImageDiskQuotaExceeded(
      this.reason, this.requestedBytes, this.availableBytes);
  final String reason;
  final int requestedBytes, availableBytes;
  @override
  String toString() => '图片派生空间不足：$reason';
}

class _DiskClaim {
  _DiskClaim(this.path, this.volume, this.baselineBytes, this.peakBytes,
      this.persistentBytes, this.workspace);
  final String path, volume;
  final int baselineBytes;
  int peakBytes, persistentBytes;
  final bool workspace;
  bool finished = false;
  void Function()? releaseProtection;
}

/// An admitted writer retains this until its IO and failed-file cleanup finish.
/// A native backing may retain a finished workspace claim while its surface is
/// alive; releasing the last claim moves it into the existing idle LRU quota.
class ImageDiskReservation {
  ImageDiskReservation._(this._owner, this._claim);
  final ImageDiskQuota _owner;
  final _DiskClaim _claim;
  bool _released = false;

  int get maximumBytes => _claim.peakBytes;

  Future<void> finishWorkspace() async {
    if (_released) return;
    await _owner._serial(() async {
      final bytes =
          await _owner._familyBytes(_claim.path, requireComplete: true);
      _claim.peakBytes = bytes;
      _claim.persistentBytes = 0;
      _claim.finished = true;
      for (final other in _owner._claims) {
        if (other.path == _claim.path && other.workspace && other.finished) {
          other.peakBytes = bytes;
        }
      }
      await _owner._recordFamily(_claim.path);
    });
  }

  Future<void> commit(Iterable<String> paths) async {
    if (_released) return;
    await _owner._serial(() async {
      await _owner._record(paths);
      _claim.finished = true;
      _owner._claims.remove(_claim);
      _claim.releaseProtection?.call();
      _released = true;
      await _owner._trimIdle();
    });
  }

  Future<void> abort() async {
    if (_released) return;
    await _owner._serial(() async {
      // Callers remove their own partials before abort. Failed cleanup remains
      // actual occupied disk, never pretend that a reservation frees storage.
      await _owner._recordFamily(_claim.path);
      _owner._claims.remove(_claim);
      _claim.releaseProtection?.call();
      _released = true;
      await _owner._trimIdle();
    });
  }
}

/// Per-volume physical admission and the existing user-selected idle cache cap.
/// Originals outside managed cache roots are never deletion candidates.
/// Existing files are represented by the inventory, while only the unwritten
/// part of a claim is deducted from real free space; this avoids double counts.
class ImageDiskQuota {
  ImageDiskQuota({
    required this.roots,
    required this.idleLimitBytes,
    required this.space,
    this.maximumActiveBytes = 2 << 30,
    this.headroomBytes = 256 << 20,
    this.protected = DerivedImageStore.isPathLeased,
    this.additionalProtectedPaths,
    this.sortCandidates = sortCacheEvictionCandidates,
    bool? sharePendingAcrossVolumes,
  }) : sharePendingAcrossVolumes =
            sharePendingAcrossVolumes ?? Platform.isAndroid;

  static final _default = ImageDiskQuota(
      roots: _defaultRoots,
      idleLimitBytes: () => appdata.appSettings.cacheLimit * 1024 * 1024,
      headroomBytes: Platform.isWindows ? 512 << 20 : 256 << 20,
      space: (path) async {
        final value =
            await const PicakeepImageEngine().availableDiskSpace(path);
        return ImageDiskSpace(value.availableBytes, value.volumeId);
      },
      additionalProtectedPaths: () async {
        final root = LocalCoverCache.rootDirectory().path;
        final registered = await LocalCoverCache.registeredReproduciblePaths();
        final inventory = await scanCacheFiles([root]);
        return {
          for (final item in inventory.files)
            if (!p.isWithin(p.join(root, 'thumbs'), item.path) &&
                !registered.contains(item.path))
              item.path
        };
      });
  static final Set<String> _registeredRoots = {};
  static void registerDerivedRoot(String root) => _registeredRoots.add(root);
  static List<String> _defaultRoots() {
    final result = <String>[..._registeredRoots];
    try {
      result.addAll([
        App.cachePath,
        p.join(App.dataPath, 'cache'),
        p.join(App.dataPath, 'local_library_cache', 'covers')
      ]);
    } on Error {/* A store may be opened before App.init in a task harness. */}
    return result.toSet().toList();
  }

  static ImageDiskQuota? overrideForTesting;
  static ImageDiskQuota get shared => overrideForTesting ?? _default;

  final List<String> Function() roots;
  final int Function() idleLimitBytes;
  final Future<ImageDiskSpace> Function(String path) space;
  final int maximumActiveBytes, headroomBytes;
  // Android emulated storage and /data can expose different st_dev values for
  // the same physical userdata capacity. Until mapped, charge both domains.
  final bool sharePendingAcrossVolumes;
  final bool Function(String path) protected;
  final Future<Set<String>> Function()? additionalProtectedPaths;
  final CacheEvictionSorter sortCandidates;
  final _claims = <_DiskClaim>{};
  final _files = <String, CacheFileSnapshot>{};
  final _managedIndexes = <String>{};
  Set<String> _protected = {};
  String? _rootIdentity;
  Future<void> _tail = Future.value();
  int _pendingOperations = 0;
  int get pendingOperations => _pendingOperations;
  String operationStage = 'idle';
  DateTime? _lastInventory;
  int rejectedCount = 0;
  String? lastRejection;

  int get pendingCount => _claims.length;
  List<Map<String, Object>> get reservations => [
        for (final claim in _claims)
          {
            'path': claim.path,
            'volume': claim.volume,
            'peakBytes': claim.peakBytes,
            'workspace': claim.workspace,
            'finished': claim.finished
          }
      ];
  int get activeBytes {
    final perPath = <String, int>{};
    for (final claim in _claims) {
      perPath.update(claim.path, (value) => math.max(value, claim.peakBytes),
          ifAbsent: () => claim.peakBytes);
    }
    return perPath.values.fold(0, (sum, bytes) => sum + bytes);
  }

  int get idleBytes => _files.values
      .where((file) => !_isActive(file.path))
      .fold(0, (sum, file) => sum + file.size);

  Future<T> _serial<T>(Future<T> Function() operation) {
    final completed = Completer<T>();
    if (_pendingOperations == 0) {
      // Do not retain a completed async future from a previous widget/test
      // lifetime as the dispatch root of the next independent operation.
      _tail = Future<void>.value();
    }
    _pendingOperations++;
    _tail = _tail.then((_) async {
      try {
        completed.complete(await operation());
      } catch (error, stack) {
        completed.completeError(error, stack);
      } finally {
        _pendingOperations--;
        operationStage = 'idle';
      }
    });
    return completed.future;
  }

  Future<void> refresh() => _serial(() => _inventory(force: true));
  Future<void> drain() => _tail;

  Future<void> _inventory({bool force = false}) async {
    final currentRoots = _rootPaths()
        .where((path) => !p.equals(path, p.rootPrefix(path)))
        .toList();
    final identity = currentRoots.join('|');
    if (!force &&
        _rootIdentity == identity &&
        _lastInventory != null &&
        DateTime.now().difference(_lastInventory!) <
            const Duration(seconds: 30)) {
      return;
    }
    final inventory = await scanCacheFiles(currentRoots, includePartial: true);
    if (_rootPaths().join('|') != identity) {
      throw const ImageDiskQuotaExceeded('缓存目录已切换', 0, 0);
    }
    _files.clear();
    for (final file in inventory.files) {
      final key = _key(file.path);
      _files[key] =
          CacheFileSnapshot(key, file.size, file.modified, file.changed);
    }
    // Parts count toward occupied disk even though the old automatic LRU omits
    // them; native family stats account for live partials during admission.
    try {
      _protected =
          ((await additionalProtectedPaths?.call()) ?? {}).map(_key).toSet();
    } catch (_) {
      // An unknown manual-cover registry is never permission to evict covers.
      _protected = _files.keys.toSet();
    }
    if (_rootPaths().join('|') != identity) {
      throw const ImageDiskQuotaExceeded('缓存目录已切换', 0, 0);
    }
    _rootIdentity = identity;
    _lastInventory = DateTime.now();
  }

  Future<ImageDiskReservation> admitPublication(String path,
          {required int maximumBytes}) =>
      _admit(path,
          peakBytes: maximumBytes + 16 * 1024,
          persistentBytes: maximumBytes + 16 * 1024,
          workspace: false);

  Future<ImageDiskReservation> admitWorkspace(String path,
          {required int peakBytes}) =>
      _admit(path, peakBytes: peakBytes, persistentBytes: 0, workspace: true);

  /// Shared registry indexes occupy persistent quota but must never be LRU
  /// victims: losing one can hide which cover files are reproducible. Only
  /// this exact file is registered; its siblings remain outside ownership.
  Future<ImageDiskReservation> admitManagedIndex(String path,
          {required int maximumBytes}) =>
      _admit(path,
          peakBytes: maximumBytes + 16 * 1024,
          persistentBytes: maximumBytes + 16 * 1024,
          workspace: false,
          managedIndex: true);

  Future<ImageDiskReservation> _admit(String path,
          {required int peakBytes,
          required int persistentBytes,
          required bool workspace,
          bool managedIndex = false}) =>
      _serial(() async {
        if (peakBytes <= 0 || peakBytes > maximumActiveBytes) {
          return _deny('工作区超限', peakBytes, maximumActiveBytes);
        }
        if (managedIndex) _managedIndexes.add(_key(path));
        operationStage = 'inventory';
        await _inventory();
        final identity = _rootIdentity;
        final normalized = _key(path);
        operationStage = 'family-stat';
        final baseline = await _familyBytes(normalized, requireComplete: true);
        peakBytes =
            workspace ? math.max(peakBytes, baseline) : peakBytes + baseline;
        if (!workspace && !_owned(normalized)) {
          return _deny('发布目录不属于可再生缓存', peakBytes, 0);
        }
        if (persistentBytes > 0) {
          await _trimIdle(extraBytes: persistentBytes);
          final promised =
              _claims.fold(0, (sum, claim) => sum + claim.persistentBytes);
          final limit = idleLimitBytes();
          if (limit <= 0 || idleBytes + promised + persistentBytes > limit) {
            return _deny('持久缓存额度不足', persistentBytes,
                math.max(0, limit - idleBytes - promised));
          }
        }
        final samePath = _claims.where((claim) => claim.path == normalized);
        if (!workspace && samePath.isNotEmpty) {
          return _deny('同一派生文件已有发布作业', peakBytes, 0);
        }
        final oldPeak = samePath.fold<int>(
            0, (value, claim) => math.max(value, claim.peakBytes));
        if (activeBytes + math.max(0, peakBytes - oldPeak) >
            maximumActiveBytes) {
          return _deny(
              '在飞工作区额度不足', peakBytes, maximumActiveBytes - activeBytes);
        }
        ImageDiskSpace disk;
        try {
          operationStage = 'volume-space';
          disk = await space(normalized);
        } catch (_) {
          return _deny('无法核验该磁盘可用空间', peakBytes, 0);
        }
        if (disk.volumeId.isEmpty || disk.availableBytes < 0) {
          return _deny('磁盘空间查询不支持', peakBytes, 0);
        }
        int unwritten = 0;
        final counted = <String>{};
        for (final claim in _claims) {
          if ((!sharePendingAcrossVolumes && claim.volume != disk.volumeId) ||
              !counted.add(claim.path)) {
            continue;
          }
          final group = _claims.where((item) => item.path == claim.path);
          final maximum = group.fold<int>(
              0, (value, item) => math.max(value, item.peakBytes));
          final written = await _familyBytes(claim.path);
          unwritten += math.max(0, maximum - written);
        }
        final int existing =
            samePath.isEmpty ? baseline : math.max(oldPeak, baseline);
        final int required =
            headroomBytes + unwritten + math.max(0, peakBytes - existing);
        if (disk.availableBytes < required) {
          // Free only owned, unleased reproducible files; never touch a download.
          await _trimIdle(freeBytes: required - disk.availableBytes);
          final volume = disk.volumeId;
          try {
            disk = await space(normalized);
          } catch (_) {
            return _deny('无法重新核验该磁盘可用空间', peakBytes, 0);
          }
          if (disk.volumeId != volume) {
            return _deny('目标磁盘已切换', peakBytes, 0);
          }
          if (disk.availableBytes < required) {
            return _deny('磁盘剩余空间需保留余量', required, disk.availableBytes);
          }
        }
        if (!_sameRoots(identity)) {
          return _deny('缓存目录已切换', peakBytes, 0);
        }
        final claim = _DiskClaim(normalized, disk.volumeId, baseline, peakBytes,
            persistentBytes, workspace);
        claim.releaseProtection = DerivedImageStore.protectPath(normalized);
        _claims.add(claim);
        return ImageDiskReservation._(this, claim);
      });

  Never _deny(String reason, int requested, int available) {
    rejectedCount++;
    lastRejection = reason;
    throw ImageDiskQuotaExceeded(reason, requested, available);
  }

  bool _owned(String path) =>
      _managedIndexes.any((index) => path == index || path == '$index.part') ||
      roots().any((root) =>
          p.isWithin(_key(root), path) &&
          !p.equals(_key(root), p.rootPrefix(root)));
  bool _isActive(String path) => _claims.any((claim) =>
      claim.workspace &&
      (path == claim.path || path.startsWith('${claim.path}.')));

  Future<void> _record(Iterable<String> paths) async {
    for (final path in paths) {
      final key = _key(path);
      if (!_owned(key)) continue;
      try {
        final stat = await File(path).stat();
        if (stat.type == FileSystemEntityType.file) {
          _files[key] =
              CacheFileSnapshot(key, stat.size, stat.modified, stat.changed);
        } else {
          _files.remove(key);
        }
      } on FileSystemException {
        // Unknown occupancy remains charged until a successful inventory.
      }
    }
  }

  Future<void> _recordFamily(String path) async {
    if (!_owned(path)) return;
    final parent = Directory(p.dirname(path));
    try {
      await for (final file in parent.list(followLinks: false)) {
        final key = _key(file.path);
        if (file is File && (key == path || key.startsWith('$path.'))) {
          await _record([file.path]);
        }
      }
    } on FileSystemException {/* Unknown residual occupancy stays charged. */}
  }

  Future<void> _trimIdle({int extraBytes = 0, int freeBytes = 0}) async {
    if (_rootIdentity != _rootPaths().join('|')) {
      return;
    }
    final limit = idleLimitBytes();
    final identity = _rootIdentity;
    var bytes = idleBytes;
    var reclaimed = 0;
    final pending =
        _claims.fold(0, (sum, claim) => sum + claim.persistentBytes);
    // Most releases and small publications fit the idle quota. Avoid ordering
    // the entire cache in that common case, especially during cover scrolling.
    if (bytes + pending + extraBytes <= limit && freeBytes <= 0) return;
    final candidates = await sortCandidates(_files.values.toList());
    if (!_sameRoots(identity)) return;
    for (final file in candidates) {
      if (bytes + pending + extraBytes <= limit && reclaimed >= freeBytes) {
        break;
      }
      if (!_owned(file.path) ||
          _managedIndexes.contains(file.path) ||
          _isActive(file.path) ||
          protected(file.path) ||
          _protected.contains(file.path) ||
          file.path.endsWith('.part')) {
        continue;
      }
      try {
        final stat = await File(file.path).stat();
        if (!_sameRoots(identity) || !_owned(file.path)) break;
        if (stat.type == FileSystemEntityType.notFound) {
          _files.remove(_key(file.path));
          bytes -= file.size;
          continue;
        }
        if (stat.size != file.size ||
            stat.modified != file.modified ||
            stat.changed != file.changed) {
          await _record([file.path]);
          bytes += stat.size - file.size;
          continue;
        }
        if (!_sameRoots(identity) || !_owned(file.path)) break;
        if (_isActive(file.path) ||
            protected(file.path) ||
            _protected.contains(file.path) ||
            !await _safeParents(file.path)) {
          continue;
        }
        if (!_sameRoots(identity) || !_owned(file.path)) break;
        if (_isActive(file.path) ||
            protected(file.path) ||
            _protected.contains(file.path)) {
          continue;
        }
        await File(file.path).delete();
        _files.remove(_key(file.path));
        bytes -= stat.size;
        reclaimed += stat.size;
      } on FileSystemException {/* Keep occupied bytes for the next scan. */}
    }
  }

  bool _sameRoots(String? identity) => identity == _rootPaths().join('|');

  List<String> _rootPaths() => {
        ...roots().map((path) => p.normalize(p.absolute(path))),
        ..._managedIndexes,
        for (final index in _managedIndexes) '$index.part'
      }.toList();

  Future<bool> _safeParents(String path) async {
    final matching =
        roots().map(_key).where((root) => p.isWithin(root, path)).toList();
    if (matching.isEmpty) return false;
    matching.sort((a, b) => b.length.compareTo(a.length));
    final root = matching.first;
    var current = p.dirname(path);
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

  Future<int> _familyBytes(String path, {bool requireComplete = false}) async {
    var bytes = 0;
    try {
      final parent = Directory(p.dirname(path));
      final type = await FileSystemEntity.type(parent.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return 0;
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
            'Workspace parent is not a directory', parent.path);
      }
      await for (final file in parent.list(followLinks: false)) {
        final key = _key(file.path);
        if (file is File && (key == path || key.startsWith('$path.'))) {
          bytes += (await file.stat()).size;
        }
      }
    } on FileSystemException {
      if (requireComplete) rethrow;
      // A partial stat is conservative for unwritten promises; publication
      // and ownership handoff demand a complete stat and must not shrink it.
    }
    return bytes;
  }

  static String _key(String path) {
    final normalized = p.normalize(p.absolute(path));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}
