import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';

import 'app.dart';
import 'download.dart';
import 'image_loader/stream_image_provider.dart';
import 'image_pipeline/cover_decode_target.dart';
import 'image_pipeline/cover_target_provider.dart';
import 'local_favorites.dart';
import 'local_library.dart';
import 'local_search_data_source.dart';
import 'remote_library_data_source.dart';

typedef _CoverBufferLoader = Future<ui.ImmutableBuffer> Function(
    StreamImageAbortSignal signal, StreamController<ImageChunkEvent> chunks);

String _digest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

/// Search keeps metadata matching separate from resolving cover pixels.
/// Sources are tried once each, including asynchronous decode failures.
class LocalSearchCoverResolver {
  LocalSearchCoverResolver({OnlineImageManager? onlineImages})
      : _onlineImages = onlineImages ?? OnlineImageManager.instance;

  final OnlineImageManager _onlineImages;
  final _providers = <String, ImageProvider<Object>>{};
  final _activeProviders = <_SearchCoverProvider>{};
  static final _cancelledGenerations = <String, int>{};
  bool _disposed = false;

  @visibleForTesting
  int get pendingLoadsForTesting => _activeProviders.fold(
      0, (count, provider) => count + provider._active.length);

  @visibleForTesting
  int get providerCountForTesting => _providers.length;

  ImageProvider<Object>? providerFor(LocalSearchResult result) {
    if (_disposed) return null;
    _cancelProviders(
        _activeProviders.where((provider) => !provider.canContinue()).toList());
    final download = result.downloadItem;
    if (download is RemoteLibraryComicItem) return download.coverImageProvider;
    final favorite = result.favoriteItem?.comic;
    final local = download ?? result.localItem;
    final raw = favorite?.coverPath.trim() ?? '';
    final uri = Uri.tryParse(raw);
    final network = uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.host.isNotEmpty
        ? raw
        : null;
    final localFavorite = raw.isNotEmpty &&
            network == null &&
            !raw.contains('://') &&
            raw != LocalLibraryManager.noCoverSentinel
        ? raw
        : null;
    final hasLocalSource = local is LocalLibraryComicItem
        ? local.localStorageExists &&
            local.localCoverPath != LocalLibraryManager.noCoverSentinel
        : local != null && local is! RemoteLibraryComicItem;
    // Pure metadata / explicit absence needs no image pipeline or App session.
    if (localFavorite == null && network == null && !hasLocalSource) {
      return null;
    }
    final source = favorite == null ? null : _sourceFor(favorite.type);
    final headers = source?.imageHeadersBuilder?.call(CustomComic(
            favorite!.name,
            favorite.author,
            raw,
            favorite.target,
            favorite.tags,
            '',
            source.key)) ??
        const <String, String>{};
    final headerSnapshot = Map<String, String>.unmodifiable(headers);
    String session() => _digest([
          source?.key,
          source?.data,
          App.localDataVersion.value,
          App.serviceConfigVersion.value,
          App.serviceRuntimeVersion.value,
        ]);
    final sessionSnapshot = session();
    final manager = LocalLibraryManager();
    final factory = local is LocalLibraryComicItem
        ? manager.coverImageProviderForItem(local)
        : null;
    final localIdentity = local == null
        ? null
        : [
            local.type.name,
            local.id,
            local.fileSystemPath,
            if (local is LocalLibraryComicItem) ...[
              local.sourceDbPath,
              local.sourceDbId,
              local.sourceRowTimeMillis,
            ],
            if (factory is StreamImageProvider) factory.imageKey,
            if (factory is FileImage) factory.file.path,
          ];
    final identity = _digest([
      App.dataPath,
      localIdentity,
      favorite?.type.key,
      favorite?.target,
      localFavorite,
      network,
      headerSnapshot,
      sessionSnapshot,
    ]);
    final cached = _providers.remove(identity);
    if (cached != null) {
      _providers[identity] = cached;
      return cached;
    }
    final loaders = <_CoverBufferLoader>[];
    if (localFavorite != null) {
      loaders.add((signal, chunks) => _localBuffer(
          manager.imageProviderForLocalPath(localFavorite), signal, chunks));
    }
    if (local is LocalLibraryComicItem &&
        local.localStorageExists &&
        local.localCoverPath != LocalLibraryManager.noCoverSentinel) {
      loaders.add((signal, chunks) async {
        final path = await manager.resolveCoverPathForItem(local);
        if (signal.isAborted) throw StateError('Search cover cancelled');
        if (path == null || path.isEmpty) {
          throw StateError('No local search cover');
        }
        return _localBuffer(
            manager.imageProviderForLocalPath(path), signal, chunks);
      });
      if (local.isArchiveItem) {
        // A missing extracted file can leave an archive:// member metadata hint.
        // Use the archive manager's existing materialization only after failure.
        loaders.add((signal, chunks) async {
          await manager.refreshArchiveCoverFor(local);
          if (signal.isAborted) throw StateError('Search cover cancelled');
          final path = local.localCoverPath;
          if (path == null || path.isEmpty || path.contains('://')) {
            throw StateError('No materialized archive search cover');
          }
          return _localBuffer(
              manager.imageProviderForLocalPath(path), signal, chunks);
        });
      }
    } else if (local != null &&
        local is! LocalLibraryComicItem &&
        local is! RemoteLibraryComicItem) {
      loaders.add((signal, chunks) => _localBuffer(
          manager.imageProviderForLocalPath(
              DownloadManager().getCover(local.id).path),
          signal,
          chunks));
    }
    if (network != null) {
      loaders.add((signal, chunks) async {
        final provider = StreamImageProvider.withProgress(
            () => _onlineImages.getImage(network,
                headers: headerSnapshot,
                cacheIdentity: 'local-search::$identity',
                abortSignal: signal),
            'local-search-network::$identity',
            abortSignal: signal);
        final bytes = await provider.load(chunks);
        if (signal.isAborted) throw StateError('Search cover cancelled');
        return ui.ImmutableBuffer.fromUint8List(bytes);
      });
    }
    if (loaders.isEmpty) return null;
    final provider = _SearchCoverProvider(
        'local_cover::search::$identity::${_cancelledGenerations[identity] ?? 0}',
        loaders,
        ownerIdentity: identity,
        canContinue: () => !_disposed && session() == sessionSnapshot,
        onActivity: (provider, active) {
          if (active) {
            _activeProviders.add(provider);
          } else {
            _activeProviders.remove(provider);
          }
        });
    if (_providers.length >= 128) {
      // Removing a cache reference never cancels a still-visible image.
      _providers.remove(_providers.keys.first);
    }
    _providers[identity] = provider;
    return provider;
  }

  void dispose() {
    _disposed = true;
    cancelPending();
    _providers.clear();
  }

  /// Keep tracking active targets even when their LRU owner is evicted.
  /// Existing loaders keep their own budget/lease until cancellation settles.
  void cancelPending() {
    _cancelProviders(_activeProviders.toList());
  }

  void _cancelProviders(List<_SearchCoverProvider> pending) {
    for (final identity
        in pending.map((provider) => provider.ownerIdentity).toSet()) {
      _providers.remove(identity);
      final next = (_cancelledGenerations.remove(identity) ?? 0) + 1;
      if (_cancelledGenerations.length >= 256) {
        _cancelledGenerations.remove(_cancelledGenerations.keys.first);
      }
      _cancelledGenerations[identity] = next;
    }
    for (final provider in pending) {
      provider.cancelPending();
    }
  }

  static ComicSource? _sourceFor(FavoriteType type) {
    final key = switch (type.key) {
      0 => 'picacg',
      1 => 'ehentai',
      2 => 'jm',
      6 => 'nhentai',
      7 => 'copy_manga',
      8 => 'Komiic',
      9 => 'pixiv',
      _ => null,
    };
    for (final source in [...ComicSource.sources, ...ComicSource.builtIn]) {
      if (source.key == key || source.key.hashCode == type.key) return source;
    }
    return null;
  }

  static Future<ui.ImmutableBuffer> _localBuffer(
      ImageProvider<Object> provider,
      StreamImageAbortSignal signal,
      StreamController<ImageChunkEvent> chunks) async {
    if (signal.isAborted) throw StateError('Search cover cancelled');
    if (provider is FileImage) {
      return ui.ImmutableBuffer.fromFilePath(provider.file.path);
    }
    if (provider is StreamImageProvider) {
      final bytes = await provider.load(chunks);
      if (signal.isAborted) throw StateError('Search cover cancelled');
      return ui.ImmutableBuffer.fromUint8List(bytes);
    }
    throw StateError('Unsupported local search cover source');
  }
}

class _SearchCoverProvider extends StreamImageProvider
    implements CoverTargetProvider {
  _SearchCoverProvider(String imageKey, this._loaders,
      {required this.ownerIdentity,
      required this.canContinue,
      required this.onActivity})
      : super(null, imageKey);

  final List<_CoverBufferLoader> _loaders;
  final String ownerIdentity;
  final bool Function() canContinue;
  final void Function(_SearchCoverProvider provider, bool active) onActivity;
  final _active = <StreamImageAbortSignal>{};
  final _targets = <(int, int, BoxFit), _SearchCoverProvider>{};
  CoverDecodeKey? _targetKey;

  @override
  ImageProvider<Object> forCoverTarget(
      {required int frameWidth,
      required int frameHeight,
      required BoxFit fit}) {
    final target = (frameWidth, frameHeight, fit);
    if (_targets.length >= 8 && !_targets.containsKey(target)) {
      _targets.remove(_targets.keys.first);
    }
    return _targets.putIfAbsent(target, () {
      final child = _SearchCoverProvider(
          '$imageKey::${target.$1}x${target.$2}::${fit.name}', _loaders,
          ownerIdentity: ownerIdentity,
          canContinue: canContinue,
          onActivity: onActivity);
      child._targetKey = CoverDecodeKey(
          child, frameWidth, frameHeight, fit, 4096, 4 * 1024 * 1024, child);
      return child;
    });
  }

  @override
  ImageStreamCompleter loadImage(
      StreamImageProvider key, ImageDecoderCallback decode) {
    final chunks = StreamController<ImageChunkEvent>();
    final signal = StreamImageAbortSignal();
    _active.add(signal);
    onActivity(this, true);
    final completer = _SearchCoverCompleter(
      codec: _codec(signal, chunks, decode),
      chunkEvents: chunks.stream,
    );
    completer.addOnLastListenerRemovedCallback(signal.abort);
    return completer;
  }

  Future<ui.Codec> _codec(
      StreamImageAbortSignal signal,
      StreamController<ImageChunkEvent> chunks,
      ImageDecoderCallback decode) async {
    void check() {
      if (signal.isAborted || !canContinue()) {
        throw const _SearchCoverCancelled();
      }
    }

    Object lastError = StateError('No usable search cover');
    StackTrace lastStack = StackTrace.current;
    try {
      for (final load in _loaders) {
        ui.ImmutableBuffer? buffer;
        ui.Codec? codec;
        ui.FrameInfo? firstFrame;
        try {
          check();
          buffer = await load(signal, chunks);
          check();
          final handedToDecoder = buffer;
          buffer = null; // The Flutter decoder owns the buffer from this call.
          codec = await decode(handedToDecoder);
          check();
          // A valid header can instantiate a Codec whose pixels are damaged.
          // Select the source only after its real first frame decodes.
          firstFrame = await codec.getNextFrame();
          check();
          final validated = _FirstFrameCodec(codec, firstFrame);
          codec = null;
          firstFrame = null; // Ownership transfers to the replay codec.
          return validated;
        } catch (error, stack) {
          check(); // Cancellation is never an excuse to start another source.
          lastError = error;
          lastStack = stack;
        } finally {
          buffer?.dispose();
          firstFrame?.image.dispose();
          codec?.dispose();
        }
      }
      Error.throwWithStackTrace(lastError, lastStack);
    } finally {
      _active.remove(signal);
      if (_active.isEmpty) onActivity(this, false);
      unawaited(chunks.close());
    }
  }

  void cancelPending() {
    for (final signal in _active) {
      signal.abort();
    }
    for (final child in _targets.values) {
      child.cancelPending();
    }
    // Evict only a pending load owned by this page, retaining completed images.
    final key = _targetKey ?? this;
    final cache = PaintingBinding.instance.imageCache;
    if (cache.statusForKey(key).pending) cache.evict(key);
  }
}

class _SearchCoverCancelled implements Exception {
  const _SearchCoverCancelled();
}

/// Cancelled routes have no listener left to consume a deliberately aborted
/// future. Suppress only that private lifecycle signal, even after disposal.
class _SearchCoverCompleter extends MultiFrameImageStreamCompleter {
  _SearchCoverCompleter({required super.codec, required super.chunkEvents})
      : super(scale: 1);

  @override
  void reportError(
      {DiagnosticsNode? context,
      required Object exception,
      StackTrace? stack,
      InformationCollector? informationCollector,
      bool silent = false}) {
    if (exception is _SearchCoverCancelled) return;
    super.reportError(
        context: context,
        exception: exception,
        stack: stack,
        informationCollector: informationCollector,
        silent: silent);
  }
}

/// Replay the checked first frame before continuing the original animation.
class _FirstFrameCodec implements ui.Codec {
  _FirstFrameCodec(this._codec, this._firstFrame);
  final ui.Codec _codec;
  ui.FrameInfo? _firstFrame;
  bool _disposed = false;

  @override
  int get frameCount => _codec.frameCount;
  @override
  int get repetitionCount => _codec.repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    if (_disposed) throw const _SearchCoverCancelled();
    final first = _firstFrame;
    if (first != null) {
      _firstFrame = null;
      return first;
    }
    final frame = await _codec.getNextFrame();
    if (_disposed) {
      frame.image.dispose();
      throw const _SearchCoverCancelled();
    }
    return frame;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _firstFrame?.image.dispose();
    _firstFrame = null;
    _codec.dispose();
  }
}
