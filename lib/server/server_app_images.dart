part of 'server_app.dart';

class _ServerReadableImage {
  _ServerReadableImage(this.path, {this.cleanup});
  final String path;
  final Future<void> Function()? cleanup;
  int _references = 0;
  bool _disposed = false;
  Timer? _expiry;
  void Function()? _remove;
  void Function() retain() {
    if (_disposed) throw StateError('Image input expired');
    _references++;
    _expiry?.cancel();
    var released = false;
    return () {
      if (released) return;
      released = true;
      _references--;
      if (_references == 0 && _remove != null) expire(_remove!);
    };
  }

  void expire(void Function() remove) {
    _remove = remove;
    _expiry?.cancel();
    _expiry = Timer(const Duration(seconds: 30), () {
      if (_references != 0) {
        expire(remove);
        return;
      }
      remove();
      unawaited(dispose());
    });
  }

  Future<void> dispose() async {
    _expiry?.cancel();
    if (_references != 0) {
      _expiry = Timer(const Duration(seconds: 1), () => unawaited(dispose()));
      return;
    }
    if (_disposed) return;
    _disposed = true;
    await cleanup?.call();
  }
}

extension ServerAppImages on PicaKeepAdminServer {
  ImageServerCapabilities get _imageCapabilities => ImageServerCapabilities(
        coverWidths: imageCoverWidths,
        coverFormats: [
          'png',
          'jpeg',
          if (_imageRenderer is NativeImageDerivativeRenderer &&
              _imageRenderer.supportsLargeRegions)
            'webp'
        ],
        manifests: true,
        levels: true,
        tiles: true,
        largeRegions: _imageRenderer.supportsLargeRegions,
      );

  ImageDerivativeService get _derivatives =>
      _imageDerivatives ??= ImageDerivativeService(
        store: DerivedImageStore(
            p.join(App.dataPath, 'cache', 'image_pipeline_v1', 'server'),
            onPublished: _maintainHeadlessImageCache),
        renderer: _imageRenderer,
        responseWait: _imageResponseWait,
      );

  Future<void> _maintainHeadlessImageCache(String publishedPath) async {
    if (_imageMaintenance != null) return _imageMaintenance;
    final dataRoot = App.dataPath, cacheRoot = App.cachePath;
    final store = _imageDerivatives?.store;
    if (store == null || _server == null) return;
    final generation = store.generation;
    final limit = appdata.appSettings.cacheLimit * 1024 * 1024;
    final future = () async {
      final inventory =
          await scanCacheFiles([cacheRoot, p.join(dataRoot, 'cache')]);
      await trimCacheInventory(inventory,
          limitBytes: limit,
          isCurrent: () =>
              _server != null &&
              App.dataPath == dataRoot &&
              App.cachePath == cacheRoot &&
              store.generation == generation &&
              appdata.appSettings.cacheLimit * 1024 * 1024 == limit,
          isProtected: (path) => DerivedImageStore.isPathLeased(path));
    }();
    _imageMaintenance = future;
    try {
      await future;
    } finally {
      if (identical(_imageMaintenance, future)) _imageMaintenance = null;
    }
  }

  Future<String> _pageSourceVersion(String path) async {
    final archive = parseArchiveUri(path);
    final target = archive?.archivePath ?? path;
    final stat = await PrivilegedStorageAccess.fileStat(target);
    if (stat == null || stat.size == 0) {
      throw const FileSystemException('Image source not found');
    }
    return sha256
        .convert(utf8.encode('$path|${stat.size}|${stat.modifiedMillis}'))
        .toString();
  }

  Future<_ServerReadableImage> _readableImage(
      String original, String version) async {
    if (!isArchiveUri(original)) {
      try {
        final input = await File(original).open();
        await input.close();
        return _ServerReadableImage(original);
      } on FileSystemException {/* Use the privileged copy contract below. */}
    }
    final key = '$original::$version';
    final known = _readableImages[key];
    if (known != null) {
      final value = await known;
      value.expire(() => _readableImages.remove(key));
      return value;
    }
    final future = () async {
      ImageTemporaryReservation? reservation, archiveReservation;
      Future<ImageTemporaryReservation> reserveInput(
          int bytes, String purpose, String path) async {
        if (bytes <= 0 || bytes > 512 * 1024 * 1024) {
          throw StateError('Image input exceeds staging limit');
        }
        return ImageTemporaryPool.shared
            .reserveOnDisk(bytes, purpose: purpose, path: path);
      }

      final directory = Directory(p.join(_derivatives.store.root, 'inputs',
          sha256.convert(utf8.encode(key)).toString()));
      final destination = File(p.join(directory.path, 'original.img'));
      final releasePath =
          DerivedImageStore.protectTemporaryPath(destination.path);
      final archive = parseArchiveUri(original);
      File? stagedArchive;
      void Function()? releaseArchive;
      int? expectedInputBytes;
      try {
        await directory.create(recursive: true);
        if (archive == null) {
          final stat = await PrivilegedStorageAccess.fileStat(original);
          if (stat == null) {
            throw const FileSystemException('Image input not found');
          }
          expectedInputBytes = stat.size;
          reservation = await reserveInput(
              stat.size, 'server-image-input', destination.path);
          await PrivilegedStorageAccess.copyFileToManagedFile(
              original, destination,
              // The reservation is the source's observed length. Keep the
              // copy bound identical so a source that grows cannot spend
              // outside the admitted workspace before version validation.
              maxBytes: stat.size,
              isCancelled: () => _server == null);
        } else {
          var archivePath = archive.archivePath;
          try {
            final readable = await File(archivePath).open();
            await readable.close();
          } on FileSystemException {
            final stat = await PrivilegedStorageAccess.fileStat(archivePath);
            if (stat == null) {
              throw const FileSystemException('Archive input not found');
            }
            stagedArchive = File(p.join(directory.path, 'source.zip'));
            archiveReservation = await reserveInput(
                stat.size, 'server-archive-input', stagedArchive.path);
            releaseArchive =
                DerivedImageStore.protectTemporaryPath(stagedArchive.path);
            await PrivilegedStorageAccess.copyFileToManagedFile(
                archivePath, stagedArchive,
                maxBytes: stat.size, isCancelled: () => _server == null);
            if (await stagedArchive.length() != stat.size) {
              throw StateError('Archive input length changed during staging');
            }
            archivePath = stagedArchive.path;
          }
          final index = await ArchiveReadingService.instance
              .getIndex(archivePath, forceRefresh: true);
          ArchiveEntry? member;
          for (final entry in index.entries) {
            if (entry.path == archive.entryPath && !entry.isDirectory) {
              member = entry;
              break;
            }
          }
          if (member == null) {
            throw const FileSystemException('Archive image not found');
          }
          expectedInputBytes = member.size;
          reservation = await reserveInput(
              member.size, 'server-archive-member', destination.path);
          await ArchiveReadingService.instance
              .materializeEntry(archivePath, archive.entryPath, destination,
                  passwordArchivePath: archive.archivePath,
                  // The central directory size is the admitted member bound;
                  // a malformed inflater cannot extend the staged source.
                  maxBytes: member.size,
                  isCancelled: () => _server == null);
          if (stagedArchive != null) {
            await stagedArchive.delete();
            stagedArchive = null;
            releaseArchive?.call();
            releaseArchive = null;
            archiveReservation?.release();
            archiveReservation = null;
          }
        }
        if (await destination.length() != expectedInputBytes) {
          throw StateError('Image input length changed during staging');
        }
        if (await _pageSourceVersion(original) != version) {
          throw StateError('Image source changed');
        }
        final value = _ServerReadableImage(destination.path, cleanup: () async {
          for (final file in [destination, stagedArchive]) {
            if (file == null) continue;
            try {
              if (await file.exists()) await file.delete();
            } on FileSystemException {
              // Busy managed files can be removed by the next cache sweep.
            }
          }
          releasePath();
          releaseArchive?.call();
          reservation?.release();
          archiveReservation?.release();
        });
        value.expire(() => _readableImages.remove(key));
        return value;
      } catch (_) {
        for (final file in [destination, stagedArchive]) {
          if (file == null) continue;
          try {
            if (await file.exists()) await file.delete();
          } on FileSystemException {
            // A failed input never becomes a published image derivative.
          }
        }
        releasePath();
        releaseArchive?.call();
        reservation?.release();
        archiveReservation?.release();
        rethrow;
      }
    }();
    _readableImages[key] = future;
    try {
      return await future;
    } catch (_) {
      _readableImages.remove(key);
      rethrow;
    }
  }

  Future<ImageDerivativeProbe> _probeImage(String path, String version,
      {ImageWorkPriority priority = ImageWorkPriority.visible}) async {
    final key = '$path::$version';
    final existing = _imageProbeCache[key];
    if (existing != null) return existing;
    if (_imageProbeCache.length >= 128) {
      _imageProbeCache.remove(_imageProbeCache.keys.first);
    }
    final future = ImageWorkScheduler.shared
        .submit<ImageDerivativeProbe>(
            key: 'server-probe:$key',
            priority: priority,
            estimatedBytes: 64 * 1024 * 1024,
            servesNetwork: true,
            run: (cancel) {
              cancel.throwIfCancelled();
              return _imageRenderer.probe(path);
            })
        .future;
    try {
      final result = await future;
      _imageProbeCache[key] = result;
      return result;
    } catch (_) {
      _imageProbeCache.remove(key);
      rethrow;
    }
  }

  Future<Response> _handleCoverVariant(
      Request request, ServerResourceItemSummary item,
      {required String? rootPath}) async {
    final query = request.url.queryParameters;
    final width = int.tryParse(query['w'] ?? '');
    final format = query['format'] ?? 'png';
    if (query['variant'] != imageCoverVariant ||
        !imageCoverWidths.contains(width) ||
        !_imageCapabilities.coverFormats.contains(format)) {
      return _jsonResponse({'error': 'invalid image variant'}, statusCode: 400);
    }
    final version = _coverVersionToken(item);
    if (query['v'] != version) return _imageVersionConflict(version);
    String? cover = item.isArchive ? item.coverPath : _coverPathCache[item.id];
    cover ??= await _scanner.resolveCoverPathOnly(item, rootPath: rootPath);
    if (cover.isEmpty) {
      return _jsonResponse({'error': 'cover not found'}, statusCode: 404);
    }
    void Function()? releaseInput;
    try {
      final sourceVersion = await _pageSourceVersion(cover);
      final input = await _readableImage(cover, sourceVersion);
      releaseInput = input.retain();
      final metadata = await _probeImage(input.path, sourceVersion);
      if (metadata.animated || metadata.bitDepth > 8) {
        return _jsonResponse({'error': 'original-format rendering required'},
            statusCode: 422);
      }
      final size =
          imageDerivativeCoverSize(metadata.width, metadata.height, width!);
      final key = DerivedImageKey(
          namespace: 'server-cover',
          resourceId: item.id,
          sourceVersion: '$version:$sourceVersion',
          usage: DerivedImageUsage.cover,
          algorithmVersion: imageDerivativeAlgorithmVersion,
          variant: '$imageCoverVariant:$width:$format');
      final result = await _derivatives.prepare(
          sourcePath: input.path,
          acquireSource: input.retain,
          estimatedWorkingBytes: metadata.estimatedWorkingBytes,
          key: key,
          region: ImageDerivativeRect(0, 0, metadata.width, metadata.height),
          width: size.$1,
          height: size.$2,
          format: format,
          priority: ImageWorkPriority.cover,
          isSourceCurrent: () async =>
              _coverVersionToken(item) == version &&
              await _pageSourceVersion(cover!) == sourceVersion);
      return _derivativeResponse(request, result, version);
    } on ArchiveFailure catch (failure) {
      return _jsonResponse({'error': 'archive input unavailable'},
          statusCode: [
            ArchiveErrorCode.passwordRequired,
            ArchiveErrorCode.wrongPassword,
            ArchiveErrorCode.encryptedArchive
          ].contains(failure.code)
              ? 403
              : 422);
    } on FileSystemException {
      return _jsonResponse({'error': 'cover not found'}, statusCode: 404);
    } catch (error) {
      return _jsonResponse(
          {'error': 'image resource limited', 'retryable': false},
          statusCode: 422);
    } finally {
      releaseInput?.call();
    }
  }

  Future<Response> _handlePageDerivative(
      Request request, ServerResourceItemSummary item,
      {required String? rootPath}) async {
    if (request.method != 'GET') {
      return _jsonResponse({'error': 'method not allowed'}, statusCode: 405);
    }
    final segments = request.url.pathSegments;
    final episodeIndex = int.tryParse(segments[5]);
    final pageIndex = int.tryParse(segments[6]);
    if (episodeIndex == null || pageIndex == null) {
      return _jsonResponse({'error': 'invalid image target'}, statusCode: 400);
    }
    final deepItem = await _ensureDeepItem(item, rootPath: rootPath);
    final episode = _findEpisode(deepItem, episodeIndex);
    if (episode == null ||
        pageIndex < 0 ||
        pageIndex >= episode.imagePaths.length) {
      return _jsonResponse({'error': 'page not found'}, statusCode: 404);
    }
    final source = episode.imagePaths[pageIndex];
    if (isArchiveUri(source) &&
        item.archiveEncrypted &&
        !item.archivePasswordMatched) {
      return _jsonResponse({'error': 'archive locked'}, statusCode: 403);
    }
    void Function()? releaseInput;
    try {
      final version = await _pageSourceVersion(source);
      final requestedVersion = request.url.queryParameters['v'];
      if (requestedVersion != null && requestedVersion != version) {
        return _imageVersionConflict(version);
      }
      final input = await _readableImage(source, version);
      releaseInput = input.retain();
      final metadata = await _probeImage(input.path, version);
      final base = imagePagePath(item.id, episodeIndex, pageIndex);
      final levels = <ImageManifestLevel>[];
      final longest = math.max(metadata.width, metadata.height);
      final highest = longest <= 1 ? 0 : (math.log(longest) / math.ln2).ceil();
      for (var index = 0; index <= highest; index++) {
        final density = 1 / math.pow(2, highest - index);
        levels.add(ImageManifestLevel(
            index: index,
            width: math.max(1, (metadata.width * density).ceil()),
            height: math.max(1, (metadata.height * density).ceil()),
            density: density.toDouble(),
            url:
                '$base/levels/$index?v=$version&a=$imageDerivativeAlgorithmVersion',
            tileUrlTemplate:
                '$base/tiles/$index/{x}/{y}?v=$version&a=$imageDerivativeAlgorithmVersion'));
      }
      final eligible = metadata.tilesAvailable &&
          !metadata.animated &&
          metadata.bitDepth <= 8;
      final manifest = ImagePageManifest(
          pageIdentity: '${item.id}:$episodeIndex:$pageIndex',
          sourceVersion: version,
          width: metadata.width,
          height: metadata.height,
          originalUrl: '$base?sourceVersion=$version',
          levels: eligible ? levels : const [],
          tilesAvailable: eligible,
          colorSpace: metadata.colorSpace,
          pixelFormat: metadata.bitDepth > 8 ? 'original-format' : 'rgba8888',
          preparation: eligible ? 'ready' : 'originalOnly');
      if (segments.length == 8 && segments[7] == 'manifest') {
        return _jsonResponse(manifest.toJson());
      }
      if (!eligible) {
        return _jsonResponse({'error': 'original-format rendering required'},
            statusCode: 422);
      }
      if (requestedVersion == null) {
        return _jsonResponse({'error': 'source version required'},
            statusCode: 400);
      }
      final levelIndex =
          segments.length >= 9 ? int.tryParse(segments[8]) : null;
      if (levelIndex == null || levelIndex < 0 || levelIndex >= levels.length) {
        return _jsonResponse({'error': 'invalid image level'}, statusCode: 400);
      }
      final level = levels[levelIndex];
      late ImageDerivativeRect region;
      late int width, height;
      late String variant;
      late DerivedImageUsage usage;
      if (segments.length == 9 && segments[7] == 'levels') {
        if (level.width * level.height > 4 * 1024 * 1024 ||
            math.max(level.width, level.height) > 4096) {
          return _jsonResponse({'error': 'level requires tiles'},
              statusCode: 422);
        }
        region = ImageDerivativeRect(0, 0, metadata.width, metadata.height);
        width = level.width;
        height = level.height;
        variant = 'level:$levelIndex:png';
        usage = DerivedImageUsage.readerLevel;
      } else if (segments.length == 11 && segments[7] == 'tiles') {
        final x = int.tryParse(segments[9]);
        final y = int.tryParse(segments[10]);
        if (x == null ||
            y == null ||
            x < 0 ||
            y < 0 ||
            x * imageTileSize >= level.width ||
            y * imageTileSize >= level.height) {
          return _jsonResponse({'error': 'tile not found'}, statusCode: 404);
        }
        final divisor = 1 << (highest - levelIndex);
        final sourceX = x * imageTileSize * divisor;
        final sourceY = y * imageTileSize * divisor;
        final sourceWidth =
            math.min(imageTileSize * divisor, metadata.width - sourceX);
        final sourceHeight =
            math.min(imageTileSize * divisor, metadata.height - sourceY);
        region =
            ImageDerivativeRect(sourceX, sourceY, sourceWidth, sourceHeight);
        width = (sourceWidth / divisor).ceil();
        height = (sourceHeight / divisor).ceil();
        variant = 'tile:$levelIndex:$x:$y:$imageTileSize:png';
        usage = DerivedImageUsage.readerTile;
      } else {
        return _jsonResponse({'error': 'not found'}, statusCode: 404);
      }
      final key = DerivedImageKey(
          namespace: 'server-page',
          resourceId: '${item.id}:$episodeIndex:$pageIndex',
          sourceVersion: version,
          usage: usage,
          algorithmVersion: imageDerivativeAlgorithmVersion,
          variant: variant);
      final result = await _derivatives.prepare(
          sourcePath: input.path,
          acquireSource: input.retain,
          estimatedWorkingBytes: metadata.estimatedWorkingBytes,
          key: key,
          region: region,
          width: width,
          height: height,
          format: 'png',
          isSourceCurrent: () async =>
              await _pageSourceVersion(source) == version);
      if (await _pageSourceVersion(source) != version) {
        return _imageVersionConflict(await _pageSourceVersion(source));
      }
      return _derivativeResponse(request, result, version);
    } on ArchiveFailure catch (failure) {
      return _jsonResponse({'error': 'archive input unavailable'},
          statusCode: [
            ArchiveErrorCode.passwordRequired,
            ArchiveErrorCode.wrongPassword,
            ArchiveErrorCode.encryptedArchive
          ].contains(failure.code)
              ? 403
              : 422);
    } on FileSystemException {
      return _jsonResponse({'error': 'page not found'}, statusCode: 404);
    } catch (_) {
      return _jsonResponse(
          {'error': 'image resource limited', 'retryable': false},
          statusCode: 422);
    } finally {
      releaseInput?.call();
    }
  }

  Response _imageVersionConflict(String version) => _jsonResponse({
        'error': 'source version changed',
        'sourceVersion': version,
      }, statusCode: 409);

  Response _verifyOriginalResponse(
      Response response, String source, String version) {
    if (response.statusCode != 200) return response;
    Stream<List<int>> verifiedBody() async* {
      yield* response.read();
      if (await _pageSourceVersion(source) != version) {
        throw StateError('Original source changed during transfer');
      }
    }

    return response.change(body: verifiedBody(), headers: {
      'x-image-source-version': version,
      HttpHeaders.cacheControlHeader: 'private, no-cache',
    });
  }

  Future<Response> _derivativeResponse(Request request,
      ImageDerivativePreparation result, String sourceVersion) async {
    final entry = result.entry;
    if (entry == null) {
      if (result.error != null) {
        return _jsonResponse(
            {'error': 'image preparation failed', 'retryable': true},
            statusCode: 422);
      }
      return _jsonResponse({
        'state': 'preparing',
        'busy': result.busy,
        'sourceVersion': sourceVersion
      }, statusCode: 202)
          .change(headers: {
        HttpHeaders.retryAfterHeader: '1',
        HttpHeaders.cacheControlHeader: 'no-store',
      });
    }
    final lease = _derivatives.store.lease(entry);
    final headers = <String, String>{
      HttpHeaders.contentTypeHeader: entry.mimeType,
      HttpHeaders.contentLengthHeader: '${entry.bytes}',
      HttpHeaders.etagHeader: entry.etag,
      HttpHeaders.cacheControlHeader: 'private, max-age=300',
      'x-image-width': '${entry.width}',
      'x-image-height': '${entry.height}',
      'x-image-source-version': sourceVersion,
    };
    if (request.headers[HttpHeaders.ifNoneMatchHeader] == entry.etag) {
      lease.release();
      return Response.notModified(
          headers: headers..remove(HttpHeaders.contentLengthHeader));
    }
    Stream<List<int>> body() async* {
      try {
        yield* File(entry.path).openRead();
      } finally {
        lease.release();
      }
    }

    return Response.ok(body(), headers: headers);
  }

  void _queueImagePreparation(ServerResourceSnapshot snapshot) {
    // Snapshot publication and HTTP startup never wait for low-priority work.
    for (final item in snapshot.items.take(12)) {
      final version = _coverVersionToken(item);
      if (_backgroundCoverVersions[item.id] == version) continue;
      _backgroundCoverVersions[item.id] = version;
      unawaited(Future<void>(() async {
        if (_server == null || item.isArchive) return;
        try {
          final path = await _scanner.resolveCoverPathOnly(item,
              rootPath: _rootPathForRootId(item.rootId));
          if (path.isEmpty || isArchiveUri(path)) return;
          final sourceVersion = await _pageSourceVersion(path);
          final metadata = await _probeImage(path, sourceVersion,
              priority: ImageWorkPriority.background);
          if (metadata.animated || metadata.bitDepth > 8) return;
          final size =
              imageDerivativeCoverSize(metadata.width, metadata.height, 384);
          await _derivatives.prepare(
              sourcePath: path,
              key: DerivedImageKey(
                  namespace: 'server-cover',
                  resourceId: item.id,
                  sourceVersion: '$version:$sourceVersion',
                  usage: DerivedImageUsage.cover,
                  algorithmVersion: imageDerivativeAlgorithmVersion,
                  variant: '$imageCoverVariant:384:jpeg'),
              region:
                  ImageDerivativeRect(0, 0, metadata.width, metadata.height),
              width: size.$1,
              height: size.$2,
              format: 'jpeg',
              estimatedWorkingBytes: metadata.estimatedWorkingBytes,
              priority: ImageWorkPriority.background,
              isSourceCurrent: () async =>
                  _server != null &&
                  await _pageSourceVersion(path) == sourceVersion);
        } catch (_) {/* A derivative cannot invalidate a published library. */}
      }));
    }
    final ids = snapshot.items.map((item) => item.id).toSet();
    _backgroundCoverVersions.removeWhere((id, _) => !ids.contains(id));
  }
}
