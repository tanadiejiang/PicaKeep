import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';

import 'package:picakeep_image_engine/picakeep_image_engine.dart';
import '../image_loader/stream_image_provider.dart';
import 'derived_image_store.dart';
import 'image_derivative_renderer.dart';
import 'image_server_protocol.dart';
import 'image_work_scheduler.dart';
import 'reader_page_source.dart';
import 'reader_raster_backend.dart';
import 'reader_viewport.dart';
import 'image_disk_quota.dart';

typedef ServerImageRequest = Future<ImageDerivativeResponse> Function(
    String url,
    {String? etag,
    int? maximumBodyBytes,
    Future<Uint8List?> Function()? localBody,
    StreamImageAbortSignal? abortSignal});

class ServerImageSourceVersionChanged implements Exception {
  const ServerImageSourceVersionChanged();
  @override
  String toString() => '图片来源已更新，请重新打开当前页';
}

class ServerReaderPageSource implements RasterReaderPageSource {
  ServerReaderPageSource(
      {required this.original,
      required this.manifest,
      required ServerImageRequest request,
      required Future<void> Function() refreshManifest,
      required String cacheRoot,
      required String serverScope}) {
    _backend = _ServerReaderRasterBackend(
        source: this,
        request: request,
        refreshManifest: refreshManifest,
        store: DerivedImageStore(cacheRoot),
        scope: serverScope);
  }
  final ReaderPageSource original;
  final ImagePageManifest manifest;
  late final _ServerReaderRasterBackend _backend;
  @override
  ReaderPageIdentity get identity => ReaderPageIdentity(
      sourceKey: original.identity.sourceKey,
      workId: original.identity.workId,
      downloadId: original.identity.downloadId,
      episode: original.identity.episode,
      page: original.identity.page,
      sourceVersion: manifest.sourceVersion,
      accessScope: original.identity.accessScope);
  @override
  bool get isAuthoritativeOriginal =>
      manifest.sourceQuality == 'authoritativeOriginal';
  @override
  bool get isPreviewOnly => false;
  @override
  String? get mimeType => original.mimeType;
  @override
  String? get extension => original.extension;
  @override
  int? get width => manifest.width;
  @override
  int? get height => manifest.height;
  @override
  int? get byteLength => original.byteLength;
  @override
  ReaderRasterBackend get rasterBackend => _backend;
  @override
  File get rasterLocator => File('remote-page-${identity.sourceVersion}');
  @override
  Future<ReaderRasterMetadata> openRasterMetadata() async =>
      ReaderRasterMetadata(
          size: ui.Size(manifest.width.toDouble(), manifest.height.toDouble()),
          animated: false,
          format: 'server-lossless-tiles',
          workingBytes: 8 * 1024 * 1024);
  @override
  Stream<List<int>> openOriginal({ReaderPageCancellation? cancellation}) =>
      original.openOriginal(cancellation: cancellation);
  @override
  Future<File> openOriginalFile({ReaderPageCancellation? cancellation}) =>
      original.openOriginalFile(cancellation: cancellation);
  @override
  Future<void> dispose() async {
    _backend.dispose();
    await original.dispose();
  }
}

class _ServerReaderRasterBackend extends ReaderRasterBackend {
  _ServerReaderRasterBackend(
      {required this.source,
      required this.request,
      required this.refreshManifest,
      required this.store,
      required this.scope});
  final ServerReaderPageSource source;
  final ServerImageRequest request;
  final Future<void> Function() refreshManifest;
  final DerivedImageStore store;
  final String scope;
  final Set<StreamImageAbortSignal> _requests = {};
  final Set<ImageWorkTicket<ui.Image>> _fallbacks = {};
  final _backingClaims = <String, Future<ImageDiskReservation>>{};
  bool _disposed = false;
  int _fallbackSequence = 0;
  @override
  bool get requiresFileBacking => false;
  @override
  ImageWorkLane get executionLane => ImageWorkLane.network;
  @override
  Future<ReaderRasterMetadata> probe(File file) => source.openRasterMetadata();

  @override
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
      {required String backingPath}) async {
    final shape = _shape(demand);
    return _responseLimit(shape.width, shape.height) +
        shape.width * shape.height * 12 +
        demand.outputWidth * demand.outputHeight * 12;
  }

  ({ImageManifestLevel level, int width, int height}) _shape(
      ReaderTileDemand demand) {
    final preview = demand.column < 0 || demand.row < 0;
    final suitable = source.manifest.levels
        .where(
            (level) => level.lossless && level.density + 1e-9 >= demand.density)
        .toList()
      ..sort((a, b) => a.density.compareTo(b.density));
    if (suitable.isEmpty) {
      throw StateError('Server lacks required original density');
    }
    final level = suitable.first;
    if (!preview && (level.density - demand.density).abs() > 1e-9) {
      throw StateError('Server tile grid does not match requested density');
    }
    return (
      level: level,
      width: preview ? level.width : demand.outputWidth,
      height: preview ? level.height : demand.outputHeight
    );
  }

  int _responseLimit(int width, int height) {
    final bytes = width * height * 5 + 64 * 1024;
    if (bytes > 32 * 1024 * 1024) {
      throw const ImageWorkBudgetExceeded(33 << 20, 32 << 20);
    }
    return bytes;
  }

  @override
  Future<ui.Image> decode(
    File file,
    ReaderTileDemand demand, {
    required String backingPath,
    required int memoryBudgetBytes,
    required bool Function() isCancelled,
    Future<void>? cancelled,
  }) async {
    if (_disposed || isCancelled()) throw const ImageWorkCancelled();
    final manifest = source.manifest;
    final preview = demand.column < 0 || demand.row < 0;
    final shape = _shape(demand);
    final level = shape.level;
    final expectedWidth = shape.width, expectedHeight = shape.height;
    final maximumBodyBytes = _responseLimit(expectedWidth, expectedHeight);
    final url = preview
        ? level.url
        : level.tileUrlTemplate
            .replaceAll('{x}', '${demand.column}')
            .replaceAll('{y}', '${demand.row}');
    final key = DerivedImageKey(
        namespace: 'remote-reader:$scope',
        resourceId: manifest.pageIdentity,
        sourceVersion: manifest.sourceVersion,
        algorithmVersion: manifest.algorithmVersion,
        usage: preview
            ? DerivedImageUsage.readerLevel
            : DerivedImageUsage.readerTile,
        variant: '${level.index}:${demand.column}:${demand.row}:png');
    final cached = await store.lookup(key);
    final abort = StreamImageAbortSignal();
    _requests.add(abort);
    if (cancelled != null) unawaited(cancelled.then((_) => abort.abort()));
    DerivedImageLease? lease;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      final response = await request(url,
          etag: cached?.etag,
          maximumBodyBytes: maximumBodyBytes,
          localBody: cached == null
              ? null
              : () async {
                  final current = await store.lookup(key);
                  if (current == null ||
                      current.bytes > maximumBodyBytes ||
                      current.digest != cached.digest ||
                      current.etag != cached.etag ||
                      current.bytes != cached.bytes) {
                    return null;
                  }
                  final reading = store.lease(current);
                  try {
                    final input = File(current.path);
                    if (await input.length() != current.bytes) return null;
                    final bytes = BytesBuilder(copy: false);
                    await for (final chunk in input.openRead()) {
                      if (_disposed || isCancelled()) {
                        throw const ImageWorkCancelled();
                      }
                      if (bytes.length + chunk.length > maximumBodyBytes ||
                          bytes.length + chunk.length > current.bytes) {
                        return null;
                      }
                      bytes.add(chunk);
                    }
                    final body = bytes.takeBytes();
                    if (body.length != current.bytes ||
                        sha256.convert(body).toString() != current.digest) {
                      return null;
                    }
                    return body;
                  } finally {
                    reading.release();
                  }
                },
          abortSignal: abort);
      if (_disposed || isCancelled()) throw const ImageWorkCancelled();
      if (response.statusCode == 409) {
        await refreshManifest();
        throw const ServerImageSourceVersionChanged();
      }
      if (response.statusCode == 404) {
        return await _decodeOriginal(demand,
            backingPath: backingPath,
            memoryBudgetBytes: memoryBudgetBytes,
            isCancelled: isCancelled,
            cancelled: cancelled);
      }
      if (response.body.length > maximumBodyBytes ||
          !response.isImage ||
          response.headers['x-image-source-version'] !=
              manifest.sourceVersion ||
          response.headers['content-type']?.split(';').first != 'image/png' ||
          int.tryParse(response.headers['x-image-width'] ?? '') !=
              expectedWidth ||
          int.tryParse(response.headers['x-image-height'] ?? '') !=
              expectedHeight) {
        throw StateError(
            'Unverified server reader image (${response.statusCode})');
      }
      buffer = await ui.ImmutableBuffer.fromUint8List(response.body);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width != expectedWidth ||
          descriptor.height != expectedHeight) {
        throw StateError('Server reader image has incorrect dimensions');
      }
      final entry = await store.put(
          key: key,
          content: Stream.value(response.body),
          mimeType: 'image/png',
          width: expectedWidth,
          height: expectedHeight,
          lossless: true,
          maximumBytes: response.body.length,
          canPublish: () => !_disposed && !isCancelled());
      if (entry != null) lease = store.lease(entry);
      codec = await descriptor.instantiateCodec(
          targetWidth: demand.outputWidth, targetHeight: demand.outputHeight);
      final image = (await codec.getNextFrame()).image;
      if (_disposed || isCancelled()) {
        image.dispose();
        throw const ImageWorkCancelled();
      }
      return image;
    } finally {
      _requests.remove(abort);
      lease?.release();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  Future<ui.Image> _decodeOriginal(
    ReaderTileDemand demand, {
    required String backingPath,
    required int memoryBudgetBytes,
    required bool Function() isCancelled,
    Future<void>? cancelled,
  }) async {
    final cancellation = ReaderPageCancellation();
    if (cancelled != null) {
      unawaited(cancelled.then((_) => cancellation.cancel()));
    }
    final original = await source.openOriginalFile(cancellation: cancellation);
    final release = ReaderPageFileLease.acquire(original);
    var started = false, released = false;
    void releaseOriginal() {
      if (released) return;
      released = true;
      release();
    }

    try {
      if (_disposed || isCancelled()) throw const ImageWorkCancelled();
      const native = NativeReaderRasterBackend(persistRaster: false);
      final available = PicakeepImageEngine.isAvailable;
      final nativeMetadata = available ? await native.probe(original) : null;
      final dartMetadata = available
          ? null
          : await ImageWorkScheduler.shared
              .submit<ImageDerivativeProbe>(
                  key:
                      'remote-fallback-probe:${identityHashCode(this)}:${_fallbackSequence++}',
                  servesNetwork: true,
                  priority: ImageWorkPriority.visible,
                  // Compatibility decoding is bounded to 4MP and 16MiB input.
                  // Probe can decode its first frame, so it needs its own ledger.
                  estimatedBytes: 128 << 20,
                  run: (cancel) {
                    if (_disposed || isCancelled()) {
                      throw const ImageWorkCancelled();
                    }
                    cancel.throwIfCancelled();
                    return const BoundedDartImageDerivativeRenderer()
                        .probe(original.path);
                  })
              .future;
      final width = nativeMetadata?.size.width ?? dartMetadata!.width;
      final height = nativeMetadata?.size.height ?? dartMetadata!.height;
      if (width != source.manifest.width || height != source.manifest.height) {
        throw const ServerImageSourceVersionChanged();
      }
      final working = available
          ? await native.estimateWorkingBytes(original, demand,
              backingPath: backingPath)
          : width.toInt() * height.toInt() * 20 + await original.length() * 2;
      if (_disposed || isCancelled()) throw const ImageWorkCancelled();
      final ticket = ImageWorkScheduler.shared.submit<ui.Image>(
          key:
              'remote-fallback:${identityHashCode(this)}:${_fallbackSequence++}:${demand.variant}',
          servesNetwork: true,
          priority: ImageWorkPriority.visible,
          estimatedBytes:
              working + demand.outputWidth * demand.outputHeight * 12,
          disposeResult: (image) => image.dispose(),
          run: (cancel) async {
            started = true;
            bool cancelledNow() =>
                cancel.isCancelled || _disposed || isCancelled();
            try {
              if (cancelledNow()) throw const ImageWorkCancelled();
              if (available) {
                await _backingClaims.putIfAbsent(backingPath, () async {
                  final value = await ImageDiskQuota.shared
                      .admitWorkspace(backingPath, peakBytes: 1);
                  await value.finishWorkspace();
                  return value;
                });
                return await native.decode(original, demand,
                    backingPath: backingPath,
                    memoryBudgetBytes: working,
                    isCancelled: cancelledNow,
                    cancelled: cancel.cancelled);
              }
              final raster = await const BoundedDartImageDerivativeRenderer()
                  .render(original.path,
                      region: ImageDerivativeRect(
                          demand.rasterRect.left.round(),
                          demand.rasterRect.top.round(),
                          demand.rasterRect.width.round(),
                          demand.rasterRect.height.round()),
                      width: demand.outputWidth,
                      height: demand.outputHeight,
                      format: 'png',
                      backingPath: backingPath,
                      jobBudgetBytes: working,
                      isCancelled: cancelledNow);
              if (cancelledNow()) throw const ImageWorkCancelled();
              final codec = await ui.instantiateImageCodec(raster.bytes);
              try {
                final image = (await codec.getNextFrame()).image;
                if (cancelledNow()) {
                  image.dispose();
                  throw const ImageWorkCancelled();
                }
                return image;
              } finally {
                codec.dispose();
              }
            } finally {
              releaseOriginal();
            }
          });
      _fallbacks.add(ticket);
      if (cancelled != null) unawaited(cancelled.then((_) => ticket.cancel()));
      try {
        return await ticket.future;
      } finally {
        _fallbacks.remove(ticket);
        if (!started) releaseOriginal();
      }
    } finally {
      // A cancelled running native job retains the original until its own
      // finally completes; a queued/rejected/probe failure releases here.
      if (!started) releaseOriginal();
    }
  }

  void dispose() {
    _disposed = true;
    for (final abort in _requests) {
      abort.abort();
    }
    for (final ticket in _fallbacks.toList()) {
      ticket.cancel();
    }
    for (final claim in _backingClaims.values) {
      unawaited(claim.then((value) => value.abort(), onError: (_) {}));
    }
    _backingClaims.clear();
    store.dispose();
  }
}
