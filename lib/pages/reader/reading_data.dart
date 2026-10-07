part of pica_reader;

abstract class ReadingData {
  ReadingData();

  String get title;

  String get id;

  String get downloadId;

  String get sourceKey;

  /// Source metadata used by the untranslated-tag observer. These remain
  /// empty for sources that do not have a reliable EH/NH identity.
  String? get untranslatedTagSource {
    final normalized = sourceKey.trim().toLowerCase();
    return normalized == 'ehentai' || normalized == 'nhentai'
        ? normalized
        : null;
  }

  String get untranslatedTagComicId => id;

  Iterable<String> get untranslatedTagFlatTags => const <String>[];

  Map<String, List<String>> get untranslatedTagCategorizedTags =>
      const <String, List<String>>{};

  ComicType get comicType;

  bool get hasEp;

  Map<String, String>? get eps;

  bool get downloaded => downloadManager.isExists(downloadId);

  List<int> downloadedEps = [];

  String get favoriteId => id;

  FavoriteType get favoriteType;

  bool get supportsLocalImageSort => false;

  String get localImageSortMode => '0';

  Future<void> setLocalImageSortMode(String value) async {}

  bool checkEpDownloaded(int ep) {
    return !hasEp || downloadedEps.contains(ep - 1);
  }

  Future<List<String>> loadEp(int ep) async {
    if (downloaded && downloadedEps.isEmpty) {
      var comic = await downloadManager.getComicOrNull(downloadId);
      if (comic != null) {
        downloadedEps = comic.downloadedEps;
      }
    }
    // 43 号：41 号排查时加在这里的三条诊断 `print` 已移除。
    // 它们的结论已经沉淀进代码与文档，无需每页都打：
    //   · `downloaded` 为假 → 走 `loadEpNetwork`（`LocalReadingData` 恒返回 `[]`）；
    //   · "读到 0 张图"这条更有用的信号由 `_logEmptyEpisodeFiles`
    //     （`local_library_static.dart`）在**真的列到空**时记一条 warning ——
    //     那才是需要留痕的时刻，而不是每次 loadEp。
    if (downloaded && checkEpDownloaded(ep)) {
      int length;
      if (hasEp) {
        length = downloadManager.getEpLength(downloadId, ep);
      } else {
        length = downloadManager.getComicLength(downloadId);
      }
      return List.filled(length > 0 ? length : 1, "");
    } else {
      return await loadEpNetwork(ep);
    }
  }

  Stream<List<int>> loadImage(int ep, int page, String url) async* {
    if (downloaded && checkEpDownloaded(ep)) {
      final source = await resolvePageSource(ep, page, url);
      try {
        yield* source.openOriginal();
      } finally {
        await source.dispose();
      }
    } else {
      yield* loadImageNetwork(ep, page, url);
    }
  }

  ImageProvider createImageProvider(
    int ep,
    int page,
    String url, {
    StreamImageAbortSignal? abortSignal,
  }) {
    if (downloaded && checkEpDownloaded(ep)) {
      return FileImageProvider(downloadId, hasEp ? ep : 0, page);
    } else {
      return StreamImageProvider(
        () => loadImage(ep, page, url),
        buildImageKey(ep, page, url),
        abortSignal: abortSignal,
      );
    }
  }

  Size? imageSize(int ep, int page, String url) => null;

  /// Optional display-only pixels from an already decoded cover.
  Future<ui.Image?> loadCachedPreview(int ep, int page, String url,
          ReaderResolvedOriginal original) async =>
      null;

  String buildImageKey(int ep, int page, String url) => url;

  String epDisplayName(int index) {
    return eps?.values.elementAt(index) ?? '';
  }

  Future<List<String>> loadEpNetwork(int ep);

  Stream<List<int>> loadImageNetwork(int ep, int page, String url);

  Future<StreamImageLoadResult> loadOriginalNetworkWithProgress(
          int ep, int page, String url,
          {StreamImageAbortSignal? abortSignal}) async =>
      StreamImageLoadResult(stream: loadImageNetwork(ep, page, url));

  /// Resolves the immutable page selected by the reader to the authoritative
  /// source used by save/share/favorites and by the high-resolution canvas.
  /// The display provider remains free to use a cheaper layer, but this method
  /// never returns that layer.
  Future<ReaderPageSource> resolvePageSource(
      int ep, int page, String url) async {
    if (downloaded && checkEpDownloaded(ep)) {
      final file = downloadManager.getImage(downloadId, hasEp ? ep : 0, page);
      if (await file.exists() && await file.length() > 0) {
        final stat = await file.stat();
        return FileReaderPageSource(
          identity: _pageIdentity(ep, page, url,
              sourceVersion:
                  '${stat.size}:${stat.modified.millisecondsSinceEpoch}'),
          file: file,
          extension: _extensionFromPath(file.path),
          mimeType: _mimeFromPath(file.path),
          byteLength: stat.size,
          modifiedMillis: stat.modified.millisecondsSinceEpoch,
        );
      }
    }

    if (isArchiveUri(url)) {
      final parsed = parseArchiveUri(url)!;
      final stat = await PrivilegedStorageAccess.fileStat(parsed.archivePath);
      final identity = _pageIdentity(ep, page, url,
          sourceVersion: '$url:${stat?.size}:${stat?.modifiedMillis}');
      ImageTemporaryReservation? memberReservation;
      return DeferredReaderPageSource(
        identity: identity,
        extension: _extensionFromPath(parsed.entryPath),
        mimeType: _mimeFromPath(parsed.entryPath),
        opener: (cancellation) async {
          final directory = Directory(
              '${Directory.systemTemp.path}/picakeep-reader-original');
          await directory.create(recursive: true);
          final archive = await _readableLocalOriginal(
              parsed.archivePath, cancellation,
              expectedStat: stat);
          try {
            // The lightweight index cache omits entry lengths; a refreshed
            // bounded central directory provides the actual reservation.
            final index = await ArchiveReadingService.instance
                .getIndex(archive.file.path, forceRefresh: true);
            final matches = index.entries.where((entry) =>
                entry.path == parsed.entryPath && !entry.isDirectory);
            if (matches.isEmpty || matches.first.size <= 0) {
              throw const ArchiveFailure(
                  code: ArchiveErrorCode.entryNotFound,
                  debugMessage: 'Original archive member is unavailable');
            }
            cancellation.throwIfCancelled();
            final bytes = matches.first.size;
            final target = File(
                '${directory.path}/${const Uuid().v4()}${_extensionFromPath(parsed.entryPath)}');
            memberReservation =
                await _reserveOriginalWorkspace(bytes, target.path);
            final result =
                await ArchiveReadingService.instance.materializeEntry(
              archive.file.path,
              parsed.entryPath,
              target,
              passwordArchivePath: parsed.archivePath,
              maxBytes: bytes,
              isCancelled: () => cancellation.isCancelled,
            );
            try {
              await _verifyLocalVersion(parsed.archivePath, stat);
              cancellation.throwIfCancelled();
              return result;
            } catch (_) {
              if (await result.exists()) await result.delete();
              rethrow;
            }
          } catch (_) {
            memberReservation?.release();
            memberReservation = null;
            rethrow;
          } finally {
            try {
              if (archive.temporary && await archive.file.exists()) {
                await archive.file.delete();
              }
            } finally {
              archive.reservation?.release();
            }
          }
        },
        onDispose: () => memberReservation?.release(),
      );
    }
    if (url.isNotEmpty &&
        !url.startsWith('http://') &&
        !url.startsWith('https://')) {
      final stat = await PrivilegedStorageAccess.fileStat(url);
      final identity = _pageIdentity(ep, page, url,
          sourceVersion: '$url:${stat?.size}:${stat?.modifiedMillis}');
      final file = File(url);
      try {
        final handle = await file.open();
        await handle.close();
        if ((stat?.size ?? 0) > 0) {
          final actualStat = await file.stat();
          return FileReaderPageSource(
            identity: identity,
            file: file,
            extension: _extensionFromPath(url),
            mimeType: _mimeFromPath(url),
            byteLength: stat?.size,
            modifiedMillis: actualStat.modified.millisecondsSinceEpoch,
          );
        }
      } catch (_) {}
      ({
        File file,
        bool temporary,
        ImageTemporaryReservation? reservation
      })? resolved;
      return DeferredReaderPageSource(
        identity: identity,
        // Readability can change after selection. A newly readable original
        // remains a user file and must never be deleted by source disposal.
        ownsFile: false,
        extension: _extensionFromPath(url),
        mimeType: _mimeFromPath(url),
        byteLength: stat?.size,
        opener: (cancellation) async {
          resolved = await _readableLocalOriginal(url, cancellation,
              expectedStat: stat);
          return resolved!.file;
        },
        onDispose: () async {
          try {
            if (resolved?.temporary == true && await resolved!.file.exists()) {
              await resolved!.file.delete();
            }
          } finally {
            resolved?.reservation?.release();
          }
        },
      );
    }

    final identity = _pageIdentity(ep, page, url);
    ImageTemporaryReservation? streamReservation;
    return DeferredReaderPageSource(
      identity: identity,
      isAuthoritativeOriginal: true,
      isPreviewOnly: false,
      extension: _extensionFromPath(url),
      mimeType: _mimeFromPath(url),
      opener: (cancellation) async {
        final tempDir =
            Directory('${Directory.systemTemp.path}/picakeep-reader-original');
        final extension =
            _extensionFromPath(url).isEmpty ? '.bin' : _extensionFromPath(url);
        const maximum = 512 * 1024 * 1024;
        final name = '${const Uuid().v4()}$extension';
        final abort = StreamImageAbortSignal();
        unawaited(cancellation.cancelled.then((_) => abort.abort()));
        final response = await loadOriginalNetworkWithProgress(ep, page, url,
            abortSignal: abort);
        final expected = response.expectedTotalBytes;
        try {
          cancellation.throwIfCancelled();
          if (expected != null && (expected <= 0 || expected > maximum)) {
            throw StateError('Original response exceeds staging limit');
          }
          streamReservation = await _reserveOriginalWorkspace(
              expected ?? maximum,
              '${tempDir.path}${Platform.pathSeparator}$name');
          final file = await materializeReaderPageStream(
            response.stream,
            directory: tempDir,
            fileName: name,
            cancellation: cancellation,
            maxBytes: expected ?? maximum,
          );
          if (expected != null && await file.length() != expected) {
            await file.delete();
            throw StateError('Original response length changed');
          }
          return file;
        } catch (_) {
          abort.abort();
          if (response.cancel != null) {
            await response.cancel!();
          } else {
            await response.stream.listen((_) {}, onError: (_) {}).cancel();
          }
          streamReservation?.release();
          streamReservation = null;
          rethrow;
        }
      },
      onDispose: () => streamReservation?.release(),
    );
  }

  ReaderPageIdentity _pageIdentity(
    int ep,
    int page,
    String url, {
    String? sourceVersion,
  }) =>
      ReaderPageIdentity(
        sourceKey: sourceKey,
        workId: id,
        downloadId: downloadId,
        episode: ep,
        page: page,
        sourceVersion: sourceVersion ?? buildImageKey(ep, page, url),
        accessScope: imageAccessScope,
      );

  String get imageAccessScope {
    try {
      final data = ComicSource.require(sourceKey).data;
      final account = [
        data['userId'],
        data['token'],
        data['cookie'],
        data['account']
      ].join('|');
      return sha256.convert(utf8.encode(account)).toString();
    } catch (_) {
      return 'public';
    }
  }

  String originalNetworkCacheIdentity(int ep, int page, String url) =>
      _pageIdentity(ep, page, url, sourceVersion: url).stableKey;

  ReaderPageSource networkPageSource(
    int ep,
    int page,
    String url, {
    Map<String, String>? headers,
    bool isOriginal = true,
    int? width,
    int? height,
    String sourceTier = 'original',
  }) {
    final identity =
        _pageIdentity(ep, page, url, sourceVersion: '$sourceTier:$url');
    void Function()? release;
    return DeferredReaderPageSource(
      identity: identity,
      ownsFile: false,
      isAuthoritativeOriginal: isOriginal,
      extension: _extensionFromPath(url),
      mimeType: _mimeFromPath(url),
      width: width,
      height: height,
      opener: (cancellation) async {
        final abort = StreamImageAbortSignal();
        unawaited(cancellation.cancelled.then((_) => abort.abort()));
        final file = await OnlineImageManager.instance.getImageFile(
          url,
          headers: headers,
          abortSignal: abort,
          cacheIdentity: identity.stableKey,
        );
        release = OnlineImageCache.instance.lease(file);
        return file;
      },
      onDispose: () => release?.call(),
    );
  }

  Future<({File file, bool temporary, ImageTemporaryReservation? reservation})>
      _readableLocalOriginal(
    String path,
    ReaderPageCancellation cancellation, {
    PrivilegedFileStat? expectedStat,
  }) async {
    cancellation.throwIfCancelled();
    await _verifyLocalVersion(path, expectedStat);
    final file = File(path);
    try {
      final handle = await file.open();
      final length = await handle.length();
      await handle.close();
      if (length > 0) {
        return (file: file, temporary: false, reservation: null);
      }
    } catch (_) {}
    final directory =
        Directory('${Directory.systemTemp.path}/picakeep-reader-original');
    await directory.create(recursive: true);
    final target = File(
        '${directory.path}/${const Uuid().v4()}${_extensionFromPath(path)}');
    final stat = expectedStat ?? await PrivilegedStorageAccess.fileStat(path);
    if (stat == null || stat.size <= 0) {
      throw FileSystemException('Original file is unavailable', path);
    }
    final reservation = await _reserveOriginalWorkspace(stat.size, target.path);
    try {
      await PrivilegedStorageAccess.copyFileToManagedFile(path, target,
          maxBytes: stat.size,
          isCancelled: () => cancellation.isCancelled,
          cancelled: cancellation.cancelled);
      await _verifyLocalVersion(path, stat);
      if (await target.length() != stat.size) {
        throw StateError('Original source changed during file copy');
      }
      return (file: target, temporary: true, reservation: reservation);
    } catch (_) {
      try {
        if (await target.exists()) await target.delete();
      } finally {
        reservation.release();
      }
      rethrow;
    }
  }

  static Future<ImageTemporaryReservation> _reserveOriginalWorkspace(
          int bytes, String path) =>
      ImageTemporaryPool.shared
          .reserveOnDisk(bytes, purpose: 'reader-original', path: path);

  static Future<void> _verifyLocalVersion(
      String path, PrivilegedFileStat? expected) async {
    if (expected == null) return;
    final actual = await PrivilegedStorageAccess.fileStat(path);
    if (actual == null ||
        actual.size != expected.size ||
        actual.modifiedMillis != expected.modifiedMillis) {
      throw StateError('Original source changed while this page was selected');
    }
  }

  static String _extensionFromPath(String value) {
    final path = Uri.tryParse(value)?.path ?? value;
    final match = RegExp(r'\.[A-Za-z0-9]{2,5}$').firstMatch(path);
    return match?.group(0)?.toLowerCase() ?? '';
  }

  static String? _mimeFromPath(String value) {
    switch (_extensionFromPath(value)) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      default:
        return null;
    }
  }
}

class LocalReadingData extends ReadingData {
  @override
  final String title;

  @override
  final String id;

  @override
  final String downloadId;

  @override
  final String sourceKey;

  @override
  final bool hasEp;

  @override
  final Map<String, String>? eps;

  @override
  final FavoriteType favoriteType;

  @override
  final ComicType comicType;

  LocalReadingData({
    required this.title,
    required this.id,
    required this.downloadId,
    required this.sourceKey,
    required this.hasEp,
    required this.comicType,
    this.eps,
    this.favoriteType = const FavoriteType(0),
  });

  @override
  Future<List<String>> loadEpNetwork(int ep) async {
    return [];
  }

  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) async* {
    yield [];
  }
}
