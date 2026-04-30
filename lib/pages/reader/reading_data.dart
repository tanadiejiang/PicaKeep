part of pica_reader;

abstract class ReadingData {
  ReadingData();

  String get title;

  String get id;

  String get downloadId;

  String get sourceKey;

  bool get hasEp;

  Map<String, String>? get eps;

  bool get downloaded => downloadManager.isExists(downloadId);

  List<int> downloadedEps = [];

  String get favoriteId => id;

  FavoriteType get favoriteType;

  bool checkEpDownloaded(int ep) {
    return !hasEp || downloadedEps.contains(ep-1);
  }

  Future<List<String>> loadEp(int ep) async {
    if(downloaded && downloadedEps.isEmpty){
      var comic = await downloadManager.getComicOrNull(downloadId);
      if (comic != null) {
        downloadedEps = comic.downloadedEps;
      }
    }
    if (downloaded && checkEpDownloaded(ep)){
      int length;
      if(hasEp) {
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

  ImageProvider createImageProvider(int ep, int page, String url){
    if (downloaded && checkEpDownloaded(ep)){
      return FileImageProvider(downloadId, hasEp ? ep : 0, page);
    } else {
      return StreamImageProvider(() => loadImage(ep, page, url), buildImageKey(ep, page, url));
    }
  }

  String buildImageKey(int ep, int page, String url) => url;

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

  LocalReadingData({
    required this.title,
    required this.id,
    required this.downloadId,
    required this.sourceKey,
    required this.hasEp,
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
