import 'dart:io';

import 'package:picakeep/foundation/archive/archive_models.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';

HistoryType _historyTypeForDownload(DownloadedItem c) {
  if (c is LocalLibraryComicItem && c.isAlbum) {
    return HistoryType.localAlbum;
  }
  if (c is RemoteLibraryComicItem && c.isCustomLibraryRoot) {
    return HistoryType.localAlbum;
  }
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
      if (c is CustomDownloadedItem && c.sourceKey.isNotEmpty) {
        return HistoryType(c.sourceKey.hashCode);
      }
      return HistoryType.other;
    case DownloadType.pixiv:
      // 第十八轮：pixiv 有专属 HistoryType，不走「自定义源 hashCode」兜底。
      return HistoryType.pixiv;
    case DownloadType.other:
    case DownloadType.favorite:
      if (c is CustomDownloadedItem && c.sourceKey.isNotEmpty) {
        return HistoryType(c.sourceKey.hashCode);
      }
      return HistoryType.other;
  }
}

String _firstEpisodeCoverPath(LocalLibraryComicItem item) {
  final keys = item.episodeFiles.keys.toList()..sort();
  for (final key in keys) {
    final files = item.episodeFiles[key] ?? const <String>[];
    for (final file in files) {
      final path = file.trim();
      if (path.isNotEmpty && File(path).existsSync()) {
        return path;
      }
    }
  }
  return '';
}

String resolveLocalComicCoverPath(DownloadedItem comic,
    {Iterable<String> legacyTargets = const <String>[]}) {
  final directPath = comic.localCoverPath?.trim();
  if (directPath != null &&
      directPath.isNotEmpty &&
      File(directPath).existsSync()) {
    return directPath;
  }

  if (comic is LocalLibraryComicItem) {
    final firstEpisodeCover = _firstEpisodeCoverPath(comic);
    if (firstEpisodeCover.isNotEmpty) {
      return firstEpisodeCover;
    }
  }

  try {
    final localItem = LocalLibraryManager()
        .findCachedByCandidates([comic.id, ...legacyTargets]);
    final coverPath = localItem?.localCoverPath?.trim();
    if (coverPath != null &&
        coverPath.isNotEmpty &&
        File(coverPath).existsSync()) {
      return coverPath;
    }
    if (localItem != null) {
      final firstEpisodeCover = _firstEpisodeCoverPath(localItem);
      if (firstEpisodeCover.isNotEmpty) {
        return firstEpisodeCover;
      }
    }
  } catch (_) {}

  try {
    final file = DownloadManager().getCoverFromCandidates([
      comic.id,
      ...legacyTargets,
    ]);
    if (file.existsSync()) {
      return file.path;
    }
  } catch (_) {}

  final rootPath = comic.fileSystemPath?.trim();
  if (rootPath != null && rootPath.isNotEmpty) {
    for (final name in ['cover.jpg', 'cover.jpeg', 'cover.png', 'cover.webp']) {
      final file = File('$rootPath${Platform.pathSeparator}$name');
      if (file.existsSync()) {
        return file.path;
      }
    }
  }

  return '';
}

File resolveLocalComicCover(DownloadedItem comic,
    {Iterable<String> legacyTargets = const <String>[]}) {
  final coverPath =
      resolveLocalComicCoverPath(comic, legacyTargets: legacyTargets);
  return coverPath.isEmpty ? File('') : File(coverPath);
}

/// Inserts or refreshes a history row before opening [ComicReadingPage].
Future<void> ensureHistoryBeforeRead(DownloadedItem comic,
    {Iterable<String> legacyTargets = const <String>[]}) async {
  String cover = '';
  if (comic is RemoteLibraryComicItem) {
    cover = comic.coverUrl.trim();
  }
  if (cover.isEmpty) {
    cover = resolveLocalComicCoverPath(comic, legacyTargets: legacyTargets);
  }
  // 压缩包产物（Pixiv 打包开关 `settings[154]`）的封面**不在磁盘上**，而在包里：
  // 上面那条链是**同步**的，只认磁盘路径（`File(...).existsSync()`），
  // 对 `archive://` 与包内的 `cover.jpg` 都看不见。
  //
  // 所以这里只给"路径是压缩包"的情况补一次异步解析 ——
  // `resolveCoverPathForItem` 已经实现为"压缩包 → 解出封面落到缓存再返回"。
  // 少了这一步，从「已下载」直接开读时历史记录会没有封面（只有占位图）。
  // 判定收紧到压缩包，是为了让目录形态与其它来源的行为**一个字都不变**。
  if (cover.isEmpty &&
      comic is LocalLibraryComicItem &&
      isArchivePath(comic.fileSystemPath ?? '')) {
    try {
      final resolved =
          await LocalLibraryManager().resolveCoverPathForItem(comic);
      if (resolved != null && resolved.trim().isNotEmpty) {
        cover = resolved;
      }
    } catch (_) {}
  }
  await History.ensureForLocalRead(
    target: comic.id,
    type: _historyTypeForDownload(comic),
    title: comic.name,
    subtitle: comic.subTitle,
    cover: cover,
    legacyTargets: legacyTargets,
  );
}
