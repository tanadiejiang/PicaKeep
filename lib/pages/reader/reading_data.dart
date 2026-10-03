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
      try {
        yield [1];
      } catch (_) {
        yield [];
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

  String buildImageKey(int ep, int page, String url) => url;

  String epDisplayName(int index) {
    return eps?.values.elementAt(index) ?? '';
  }

  Future<List<String>> loadEpNetwork(int ep);

  Stream<List<int>> loadImageNetwork(int ep, int page, String url);
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
