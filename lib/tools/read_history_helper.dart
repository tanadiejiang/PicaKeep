import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/history.dart';

HistoryType _historyTypeForDownload(DownloadedItem c) {
  switch (c.type) {
    case DownloadType.picacg:
      return HistoryType.picacg;
    case DownloadType.ehentai:
      return HistoryType.ehentai;
    case DownloadType.jm:
      return HistoryType.jmComic;
    case DownloadType.hitomi:
      return HistoryType.hitomi;
    case DownloadType.htmanga:
      return HistoryType.htmanga;
    case DownloadType.nhentai:
      return HistoryType.nhentai;
    case DownloadType.copyManga:
    case DownloadType.komiic:
    case DownloadType.other:
    case DownloadType.favorite:
      if (c is CustomDownloadedItem && c.sourceKey.isNotEmpty) {
        return HistoryType(c.sourceKey.hashCode);
      }
      return HistoryType.other;
  }
}

/// Inserts or refreshes a history row before opening [ComicReadingPage].
Future<void> ensureHistoryBeforeRead(DownloadedItem comic,
    {Iterable<String> legacyTargets = const <String>[]}) async {
  final dm = DownloadManager();
  await dm.init();
  final coverFile = dm.getCover(comic.id);
  final cover = coverFile.existsSync() ? coverFile.path : '';
  await History.ensureForLocalRead(
    target: comic.id,
    type: _historyTypeForDownload(comic),
    title: comic.name,
    subtitle: comic.subTitle,
    cover: cover,
    legacyTargets: legacyTargets,
  );
}
