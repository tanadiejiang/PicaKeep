part of pica_reader;

class JmReadingData extends ReadingData {
  JmReadingData({required this.info, this.forceOnline = false})
      : eps = {
          for (final entry in info.series.entries)
            entry.key.toString(): entry.key <= info.epNames.length
                ? info.epNames[entry.key - 1]
                : '第${entry.key}章',
        };

  final JmComicInfo info;

  /// 强制在线阅读：true 时忽略本地下载，始终走网络（长按章节触发）。
  final bool forceOnline;

  @override
  bool get downloaded => forceOnline ? false : super.downloaded;

  @override
  String get title => info.title;

  @override
  String get id => info.id;

  @override
  String get downloadId => 'jm${info.id}';

  @override
  String get sourceKey => 'jm';

  @override
  ComicType get comicType => ComicType.jm;

  @override
  bool get hasEp => info.series.length > 1;

  @override
  final Map<String, String> eps;

  @override
  FavoriteType get favoriteType => FavoriteType.jm;

  /// 获取第 [ep] 章（1-based）的图片 URL 列表
  @override
  Future<List<String>> loadEpNetwork(int ep) async {
    final chapterId = info.series[ep];
    if (chapterId == null) return const [];
    final res = await JmNetwork().getChapter(chapterId);
    if (res.error) throw Exception(res.errorMessageWithoutNull);
    return res.data;
  }

  /// 下载图片字节 + 图块重组 → 返回重组后字节流
  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) async* {
    // 1. 下载原始字节
    final result = await OnlineImageManager.instance.getImage(
      url,
      headers: getJmImgHeaders(),
    );
    final bytes = <int>[];
    await for (final chunk in result.stream) {
      bytes.addAll(chunk);
    }
    final raw = Uint8List.fromList(bytes);

    // 2. 图块重组
    final chapterId = info.series[ep] ?? info.id;
    final fileName = Uri.parse(url).pathSegments.last;
    final bookId = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final recombined = await JmRecombine.recombine(
      raw,
      epsId: chapterId,
      scrambleId: kJmScrambleId,
      pictureName: bookId,
    );
    yield recombined.bytes;
  }
}
