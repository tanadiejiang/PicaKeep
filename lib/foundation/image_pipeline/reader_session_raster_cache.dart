import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import 'reader_raster_backend.dart';
import 'reader_viewport.dart';

String? _sourceSnapshotToken(
    File file, FileStat snapshot, String sourceIdentity) {
  if (snapshot.type != FileSystemEntityType.file ||
      snapshot.size <= 0 ||
      sourceIdentity.isEmpty) {
    return null;
  }
  var path = p.normalize(p.absolute(file.path));
  if (Platform.isWindows) path = path.toLowerCase();
  return jsonEncode([
    'reader-session-source-v1',
    sourceIdentity,
    path,
    snapshot.size,
    snapshot.modified.microsecondsSinceEpoch,
    snapshot.changed.microsecondsSinceEpoch,
  ]);
}

/// A source snapshot captured before asynchronous metadata resolution.
class ReaderSessionSourceKey {
  ReaderSessionSourceKey._(this.sourceIdentity, this._token, this._owner,
      this._epoch, this._sourceEpoch);
  final String sourceIdentity;
  final String _token;
  final Object _owner;
  final int _epoch;
  final int _sourceEpoch;
}

/// Immutable geometry/format of a verified original, without retained pixels
/// or files. The whole-image flag is the default policy's decision, excluding
/// explicit caller overrides which may change between page widgets.
class ReaderSessionSourceMetadata {
  const ReaderSessionSourceMetadata({
    required this.metadata,
    required this.fullOrdinaryImage,
  });
  final ReaderRasterMetadata metadata;
  final bool fullOrdinaryImage;
}

class _SessionSourceMetadata {
  _SessionSourceMetadata(this.key, this.value);
  final ReaderSessionSourceKey key;
  final ReaderSessionSourceMetadata value;
}

/// An exact raster of one verified original, including its pixel treatment.
/// Callers must verify the snapshot before taking a raster from this cache.
class ReaderSessionRasterKey {
  ReaderSessionRasterKey._({
    required this.sourceIdentity,
    required this.token,
    required this.outputWidth,
    required this.outputHeight,
    Object? owner,
    int epoch = -1,
    int sourceEpoch = -1,
  })  : _owner = owner,
        _epoch = epoch,
        _sourceEpoch = sourceEpoch;

  final String sourceIdentity;
  final String token;
  final int outputWidth;
  final int outputHeight;
  final Object? _owner;
  final int _epoch;
  final int _sourceEpoch;

  /// Uses metadata already verified by the reader; it performs no file I/O.
  /// Raster locators and preview placeholders must not use this original key.
  /// This constructs identity only. [ReaderSessionRasterCache.keyForSnapshot]
  /// binds it to a session's current refresh/memory-pressure generation.
  static ReaderSessionRasterKey? forSnapshot({
    required File file,
    required FileStat snapshot,
    required String sourceIdentity,
    required ReaderTileDemand demand,
    required String pixelIdentity,
  }) {
    if (snapshot.type != FileSystemEntityType.file ||
        snapshot.size <= 0 ||
        sourceIdentity.isEmpty ||
        pixelIdentity.isEmpty ||
        !demand.density.isFinite ||
        demand.density <= 0 ||
        !demand.sourceRect.isFinite ||
        demand.sourceRect.isEmpty ||
        !demand.rasterRect.isFinite ||
        demand.rasterRect.isEmpty) {
      return null;
    }
    var path = p.normalize(p.absolute(file.path));
    if (Platform.isWindows) path = path.toLowerCase();
    return ReaderSessionRasterKey._(
      sourceIdentity: sourceIdentity,
      outputWidth: demand.outputWidth,
      outputHeight: demand.outputHeight,
      token: jsonEncode([
        'reader-session-raster-v1',
        sourceIdentity,
        path,
        snapshot.size,
        snapshot.modified.microsecondsSinceEpoch,
        snapshot.changed.microsecondsSinceEpoch,
        demand.variant,
        demand.density,
        demand.outputWidth,
        demand.outputHeight,
        pixelIdentity,
      ]),
    );
  }
}

class _SessionRaster {
  _SessionRaster(this.key, this.image, this.lastUse);
  final ReaderSessionRasterKey key;
  final ui.Image image;
  final int lastUse;
  int get bytes => image.width * image.height * 4;
}

/// Recently displayed rasters owned by a reader route, independent of page
/// widget disposal. It retains pixels only, never a source file or its lease.
///
/// [put] clones a caller's handle; [take] transfers that cache handle exactly
/// once. Surface resident/pending bytes and [totalRetainedBytes] must share the
/// reader's global budget. The cache is subordinate to visible decode work.
class ReaderSessionRasterCache with WidgetsBindingObserver {
  ReaderSessionRasterCache({
    this.maximumBytes = 64 << 20,
    this.maximumEntries = 128,
  })  : assert(maximumBytes >= 0),
        assert(maximumEntries >= 0) {
    _instances.add(this);
    WidgetsBinding.instance.addObserver(this);
  }

  final int maximumBytes;
  final int maximumEntries;
  final _identity = Object();
  final _entries = <String, _SessionRaster>{};
  final _sourceMetadata = <String, _SessionSourceMetadata>{};
  final _sourceEpochs = <String, int>{};
  int _epoch = 0;
  int _bytes = 0;
  bool _disposed = false;
  static final _instances = <ReaderSessionRasterCache>{};
  static int _totalRetainedBytes = 0;
  static int _useSequence = 0;
  static const _maximumSourceMetadataEntries = 128;

  int get retainedBytes => _bytes;
  int get length => _entries.length;
  int get sourceMetadataCount => _sourceMetadata.length;
  bool get isDisposed => _disposed;
  static int get totalRetainedBytes => _totalRetainedBytes;

  ReaderSessionSourceKey? sourceKeyForSnapshot({
    required File file,
    required FileStat snapshot,
    required String sourceIdentity,
  }) {
    if (_disposed) return null;
    final token = _sourceSnapshotToken(file, snapshot, sourceIdentity);
    if (token == null) return null;
    return ReaderSessionSourceKey._(sourceIdentity, token, _identity, _epoch,
        _sourceEpochs[sourceIdentity] ?? 0);
  }

  bool _acceptsSourceKey(ReaderSessionSourceKey key) =>
      !_disposed &&
      identical(key._owner, _identity) &&
      key._epoch == _epoch &&
      key._sourceEpoch == (_sourceEpochs[key.sourceIdentity] ?? 0);

  /// Only use after opening and verifying this original snapshot. An identity
  /// alone is insufficient to reuse a source's metadata or default admission.
  ReaderSessionSourceMetadata? sourceMetadata({
    required File file,
    required FileStat snapshot,
    required String sourceIdentity,
  }) {
    if (_disposed) return null;
    final token = _sourceSnapshotToken(file, snapshot, sourceIdentity);
    if (token == null) return null;
    final entry = _sourceMetadata.remove(token);
    if (entry == null || !_acceptsSourceKey(entry.key)) return null;
    _sourceMetadata[token] = entry;
    return entry.value;
  }

  /// A geometry hint for a pending layout only. This must never replace source
  /// stat verification, decode metadata, or pixel-cache identity checks.
  ReaderSessionSourceMetadata? peekSourceMetadata(String sourceIdentity) {
    if (_disposed) return null;
    for (final token in _sourceMetadata.keys.toList().reversed) {
      final entry = _sourceMetadata[token]!;
      if (entry.key.sourceIdentity != sourceIdentity ||
          !_acceptsSourceKey(entry.key)) {
        continue;
      }
      _sourceMetadata.remove(token);
      _sourceMetadata[token] = entry;
      return entry.value;
    }
    return null;
  }

  /// The pre-resolution [guard] prevents a late probe from repopulating this
  /// cache after refresh, memory pressure, or route disposal.
  bool rememberSourceMetadata({
    required File file,
    required FileStat snapshot,
    required String sourceIdentity,
    required ReaderRasterMetadata metadata,
    required bool fullOrdinaryImage,
    required ReaderSessionSourceKey guard,
  }) {
    if (!_acceptsSourceKey(guard) ||
        guard.sourceIdentity != sourceIdentity ||
        !metadata.size.width.isFinite ||
        !metadata.size.height.isFinite ||
        metadata.size.width <= 0 ||
        metadata.size.height <= 0) {
      return false;
    }
    final token = _sourceSnapshotToken(file, snapshot, sourceIdentity);
    if (token == null || token != guard._token) return false;
    _sourceMetadata
        .removeWhere((_, entry) => entry.key.sourceIdentity == sourceIdentity);
    while (_sourceMetadata.length >= _maximumSourceMetadataEntries) {
      _sourceMetadata.remove(_sourceMetadata.keys.first);
    }
    _sourceMetadata[token] = _SessionSourceMetadata(
        guard,
        ReaderSessionSourceMetadata(
            metadata: metadata, fullOrdinaryImage: fullOrdinaryImage));
    return true;
  }

  /// Capture before decoding. Refresh and memory pressure invalidate this key
  /// even if its source stat and raster geometry subsequently remain unchanged.
  ReaderSessionRasterKey? keyForSnapshot({
    required File file,
    required FileStat snapshot,
    required String sourceIdentity,
    required ReaderTileDemand demand,
    required String pixelIdentity,
  }) {
    if (_disposed) return null;
    final original = ReaderSessionRasterKey.forSnapshot(
        file: file,
        snapshot: snapshot,
        sourceIdentity: sourceIdentity,
        demand: demand,
        pixelIdentity: pixelIdentity);
    if (original == null) return null;
    return ReaderSessionRasterKey._(
        sourceIdentity: original.sourceIdentity,
        token: original.token,
        outputWidth: original.outputWidth,
        outputHeight: original.outputHeight,
        owner: _identity,
        epoch: _epoch,
        sourceEpoch: _sourceEpochs[sourceIdentity] ?? 0);
  }

  bool _accepts(ReaderSessionRasterKey key) =>
      !_disposed &&
      identical(key._owner, _identity) &&
      key._epoch == _epoch &&
      key._sourceEpoch == (_sourceEpochs[key.sourceIdentity] ?? 0);

  /// Evict oldest inactive rasters first to admit visible work. This is
  /// synchronous so no other cache can consume space between check and charge.
  static bool trimToCombinedBudget({
    required int activeAndPendingBytes,
    int requiredBytes = 0,
    int limitBytes = 192 << 20,
  }) {
    assert(activeAndPendingBytes >= 0 && requiredBytes >= 0 && limitBytes >= 0);
    while (activeAndPendingBytes + requiredBytes + _totalRetainedBytes >
        limitBytes) {
      ReaderSessionRasterCache? oldestCache;
      _SessionRaster? oldest;
      for (final cache in _instances) {
        if (cache._entries.isEmpty) continue;
        final candidate = cache._entries.values.first;
        if (oldest == null || candidate.lastUse < oldest.lastUse) {
          oldest = candidate;
          oldestCache = cache;
        }
      }
      if (oldestCache == null) break;
      oldestCache._remove(oldest!.key.token)?.image.dispose();
    }
    return activeAndPendingBytes + requiredBytes + _totalRetainedBytes <=
        limitBytes;
  }

  /// Retains its own handle. The caller remains responsible for [image].
  /// [availableBytes] bounds the additional globally charged bytes; it should
  /// be computed after evicting inactive cache entries under the shared budget.
  bool put(ReaderSessionRasterKey key, ui.Image image, {int? availableBytes}) {
    if (!_accepts(key) ||
        maximumEntries == 0 ||
        image.width != key.outputWidth ||
        image.height != key.outputHeight) {
      return false;
    }
    final bytes = image.width * image.height * 4;
    final previousBytes = _entries[key.token]?.bytes ?? 0;
    if (bytes > maximumBytes ||
        (availableBytes != null && bytes - previousBytes > availableBytes)) {
      return false;
    }
    final clone = image.clone();
    _remove(key.token)?.image.dispose();
    while (_entries.isNotEmpty &&
        (_bytes + bytes > maximumBytes || _entries.length >= maximumEntries)) {
      _remove(_entries.keys.first)?.image.dispose();
    }
    _entries[key.token] = _SessionRaster(key, clone, ++_useSequence);
    _bytes += bytes;
    _totalRetainedBytes += bytes;
    return true;
  }

  /// Transfers the cached handle to the caller, who now owns its disposal.
  /// No clone remains charged to this cache after a successful call.
  ui.Image? take(ReaderSessionRasterKey key) {
    if (!_accepts(key)) return null;
    return _remove(key.token)?.image;
  }

  /// An explicit refresh invalidates this source without discarding other pages.
  void invalidateSource(String sourceIdentity) {
    if (_disposed) return;
    _sourceEpochs[sourceIdentity] = (_sourceEpochs[sourceIdentity] ?? 0) + 1;
    _sourceMetadata
        .removeWhere((_, entry) => entry.key.sourceIdentity == sourceIdentity);
    final matching = _entries.values
        .where((entry) => entry.key.sourceIdentity == sourceIdentity)
        .map((entry) => entry.key.token)
        .toList();
    for (final token in matching) {
      _remove(token)?.image.dispose();
    }
  }

  _SessionRaster? _remove(String token) {
    final entry = _entries.remove(token);
    if (entry != null) {
      _bytes -= entry.bytes;
      _totalRetainedBytes -= entry.bytes;
    }
    return entry;
  }

  void clear() {
    _epoch++;
    _sourceEpochs.clear();
    _sourceMetadata.clear();
    for (final token in _entries.keys.toList()) {
      _remove(token)?.image.dispose();
    }
  }

  @override
  void didHaveMemoryPressure() => clear();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    clear();
    _instances.remove(this);
  }
}
