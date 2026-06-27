part of pica_reader;

class PicacgReadingData extends ReadingData {
  PicacgReadingData({
    required this.comic,
  }) : eps = {
          for (var i = 0; i < comic.eps.length; i++)
            (i + 1).toString(): comic.eps[i],
        };

  final PicacgComicItem comic;

  @override
  String get title => comic.title;

  @override
  String get id => comic.id;

  @override
  String get downloadId => comic.id;

  @override
  String get sourceKey => 'picacg';

  @override
  ComicType get comicType => ComicType.picacg;

  @override
  bool get hasEp => true;

  @override
  final Map<String, String> eps;

  @override
  FavoriteType get favoriteType => FavoriteType.picacg;

  @override
  Future<List<String>> loadEpNetwork(int ep) async {
    final res = await PicacgNetwork().getComicContent(comic.id, ep);
    if (res.error) {
      throw Exception(res.errorMessageWithoutNull);
    }
    return res.data;
  }

  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) async* {
    final result = await OnlineImageManager.instance.getImage(url);
    yield* result.stream;
  }
}
