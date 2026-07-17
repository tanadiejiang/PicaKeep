import 'dart:io';

import '../archive/archive_models.dart';
import '../download_author_resolver.dart';
import '../download_model.dart';
import '../local_library.dart';
import '../remote_library_data_source.dart';
import 'download_export_core.dart';
import 'download_export_models.dart';
import 'download_export_paths.dart';

typedef DownloadExportTagTranslator = String Function(String tag);

class DownloadExportRequestFactory {
  const DownloadExportRequestFactory._();

  static Future<DownloadExportRequest> fromItem(
    DownloadedItem item, {
    String? fallbackPath,
    DownloadExportTagTranslator? translateTag,
  }) async {
    final descriptor = DownloadExportDescriptorFactory.fromItem(
      item,
      translateTag: translateTag,
      localPathOverride: fallbackPath,
    );
    if (item is RemoteLibraryRootItem) {
      return DownloadExportRequest(
        descriptor: descriptor,
        source: const DownloadExportUnsupportedSource(
          '远程目录不是漫画，不能直接导出',
        ),
      );
    }
    if (item is RemoteLibraryComicItem) {
      return DownloadExportRequest(
        descriptor: descriptor,
        source: DownloadExportRemoteSource(item),
      );
    }

    final path = (item.fileSystemPath?.trim().isNotEmpty == true
            ? item.fileSystemPath
            : fallbackPath)
        ?.trim();
    if (path == null || path.isEmpty) {
      return DownloadExportRequest(
        descriptor: descriptor,
        source: const DownloadExportUnsupportedSource('找不到漫画本地路径'),
      );
    }

    if (item is LocalLibraryComicItem && item.isArchiveItem) {
      return DownloadExportRequest(
        descriptor: descriptor,
        source: DownloadExportArchiveSource(
          archivePath: path,
          episodeFiles: item.episodeFiles,
          episodeNames: LocalLibraryManager.archiveDisplayChapterNames(item),
        ),
      );
    }
    if (isArchivePath(path)) {
      return DownloadExportRequest(
        descriptor: descriptor,
        source: DownloadExportArchiveSource(archivePath: path),
      );
    }
    return DownloadExportRequest(
      descriptor: descriptor,
      source: DownloadExportDirectorySource(
        rootPath: path,
        episodeFiles:
            item is LocalLibraryComicItem ? item.episodeFiles : const {},
        episodeNames: item is LocalLibraryComicItem ? item.eps : const [],
      ),
    );
  }
}

class DownloadExportDescriptorFactory {
  const DownloadExportDescriptorFactory._();

  static DownloadExportDescriptor fromItem(
    DownloadedItem item, {
    DownloadExportTagTranslator? translateTag,
    String? localPathOverride,
  }) {
    final translator = translateTag ?? _identityTag;
    final rawTags = _rawTagsFor(item);
    var authors = _authorsFor(item);
    var link = '';
    var sourceTime = '';
    var id = item.id;
    var pageCount = _pageCountFor(item);
    var chapters = item.eps;
    var sourceKind = _sourceKindFor(item);
    var downloadTime = item.time;

    if (item is DownloadedComic) {
      id = item.comicId;
      sourceTime = item.sourceTime;
    }
    if (item is ScannedDownloadedComic) {
      sourceKind = DownloadExportSourceKind.localScan;
    }
    if (item is DownloadedGallery) {
      link = item.link;
      id = item.id;
      sourceTime = item.sourceTime;
      pageCount = item.pageCount;
      chapters = const <String>[];
    }
    if (item is DownloadedJmComic) {
      id = item.comicId;
      chapters = item.eps;
    }
    if (item is DownloadedHitomiComic) {
      id = item.comicId;
      link = item.link;
      chapters = const <String>[];
    }
    if (item is DownloadedHtComic) {
      id = item.comicId;
      chapters = const <String>[];
    }
    if (item is NhentaiDownloadedComic) {
      id = item.comicID;
      link = _nhentaiLink(item.comicID);
      chapters = const <String>[];
    }
    if (item is CustomDownloadedItem) {
      id = item.comicId.isEmpty ? item.id : item.comicId;
      chapters = item.eps;
    }
    if (item is LocalLibraryComicItem) {
      sourceKind = item.isArchiveItem
          ? DownloadExportSourceKind.localArchive
          : DownloadExportSourceKind.localScan;
      id = item.originalId.isEmpty ? item.itemId : item.originalId;
      pageCount = item.isArchiveItem
          ? null
          : _countIndexedImagePaths(item.episodeFiles.values.expand((e) => e));
      downloadTime = item.time;
      link = _verifiedWebLink(item.favoriteTarget);
    }
    if (item is RemoteLibraryComicItem) {
      sourceKind = DownloadExportSourceKind.remote;
      id = item.displayId.trim().isEmpty ? item.remoteId : item.displayId;
      authors = splitAuthorNames(item.subTitle);
      link = item.detailUrl;
      sourceTime = item.time?.toIso8601String() ?? '';
      pageCount = item.imageCount > 0 ? item.imageCount : null;
      chapters = item.eps;
      downloadTime = null;
    }
    if (item is RemoteLibraryRootItem) {
      sourceKind = DownloadExportSourceKind.remoteRoot;
      id = item.root.id;
      chapters = const <String>[];
      downloadTime = null;
    }

    final sizeBytes = _sizeBytesFor(item);
    return DownloadExportDescriptor(
      title: item.name,
      author: authors,
      id: id,
      link: link,
      source: item.sourceDisplayName,
      rawTags: rawTags,
      translatedTags: rawTags.map(translator),
      chapters: chapters,
      pageCount: pageCount,
      sizeBytes: sizeBytes,
      downloadTime: downloadTime,
      sourceTime: sourceTime,
      localPath: item is RemoteLibraryComicItem || item is RemoteLibraryRootItem
          ? ''
          : item.fileSystemPath ?? localPathOverride ?? '',
      coverPath: item.localCoverPath ?? '',
      sourceKind: sourceKind,
    );
  }

  static DownloadExportSourceKind _sourceKindFor(DownloadedItem item) {
    if (item is ScannedDownloadedComic) {
      return DownloadExportSourceKind.localScan;
    }
    switch (item.type) {
      case DownloadType.picacg:
        return DownloadExportSourceKind.picacg;
      case DownloadType.jm:
        return DownloadExportSourceKind.jm;
      case DownloadType.ehentai:
        return DownloadExportSourceKind.ehentai;
      case DownloadType.nhentai:
        return DownloadExportSourceKind.nhentai;
      case DownloadType.hitomi:
        return DownloadExportSourceKind.hitomi;
      case DownloadType.htmanga:
        return DownloadExportSourceKind.htmanga;
      case DownloadType.copyManga:
      case DownloadType.komiic:
      case DownloadType.favorite:
      case DownloadType.other:
        return DownloadExportSourceKind.other;
    }
  }

  static int? _sizeBytesFor(DownloadedItem item) {
    if (item is RemoteLibraryComicItem && item.totalBytes > 0) {
      return item.totalBytes;
    }
    final sizeMb = item.comicSize;
    if (sizeMb == null || sizeMb < 0) return null;
    return (sizeMb * 1024 * 1024).round();
  }

  static int? _pageCountFor(DownloadedItem item) {
    if (item is DownloadedGallery && item.pageCount > 0) {
      return item.pageCount;
    }
    if (item is RemoteLibraryComicItem && item.imageCount > 0) {
      return item.imageCount;
    }
    return null;
  }

  static List<String> _authorsFor(DownloadedItem item) {
    if (item is LocalLibraryComicItem) {
      final raw = item.sourceRowJson?.trim() ?? '';
      if (raw.isNotEmpty) {
        return resolveDownloadedAuthorsFromRecord(
          item.originalId,
          raw,
          fallback: item,
        );
      }
      if (item.type == DownloadType.ehentai ||
          item.type == DownloadType.nhentai) {
        return const <String>[];
      }
    }
    return resolveDownloadedAuthors(item);
  }

  static List<String> _rawTagsFor(DownloadedItem item) {
    if (item is! NhentaiDownloadedComic || item.categorizedTags.isEmpty) {
      return item.tags;
    }
    final result = <String>[];
    final seen = <String>{};
    for (final entry in item.categorizedTags.entries) {
      if (_isNhentaiMetadataBucket(entry.key)) continue;
      for (final value in entry.value) {
        final raw = value.trim();
        if (raw.isEmpty) continue;
        final qualified = '${entry.key.trim()}:$raw';
        if (seen.add(qualified)) result.add(qualified);
      }
    }
    for (final value in item.tags) {
      final raw = value.trim();
      if (raw.isNotEmpty && seen.add(raw)) result.add(raw);
    }
    return result;
  }

  static bool _isNhentaiMetadataBucket(String value) {
    return const {
      'page',
      'pages',
      'time',
      'uploaded',
      'upload',
      'date',
      '日期',
      '时间',
    }.contains(value.trim().toLowerCase());
  }

  static String _nhentaiLink(String id) {
    final normalized = id.trim();
    return RegExp(r'^\d+$').hasMatch(normalized)
        ? 'https://nhentai.net/g/$normalized/'
        : '';
  }

  static String _identityTag(String tag) => tag.trim();

  static String _verifiedWebLink(String? value) {
    final normalized = value?.trim() ?? '';
    final uri = Uri.tryParse(normalized);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return '';
    }
    return uri.hasAuthority ? normalized : '';
  }

  static int? _countIndexedImagePaths(Iterable<String> paths) {
    final seen = <String>{};
    for (final value in paths) {
      final path = value.trim().replaceAll('\\', '/');
      final lower = path.toLowerCase();
      if (path.isEmpty || path.startsWith('archive:')) continue;
      if (!(lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.png') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.gif'))) {
        continue;
      }
      final name = lower.split('/').last;
      if (const {
        'cover.jpg',
        'cover.jpeg',
        'cover.png',
        'cover.webp',
        'cover.gif',
        'folder.jpg',
        'folder.png',
        'thumb.jpg',
        'thumb.png',
        'thumbnail.jpg',
        'thumbnail.png',
      }.contains(name)) {
        continue;
      }
      seen.add(lower);
    }
    return seen.isEmpty ? null : seen.length;
  }
}

class DownloadExportRemoteSource extends DownloadExportContentSource {
  DownloadExportRemoteSource(this.initialItem);

  final RemoteLibraryComicItem initialItem;

  @override
  Future<List<DownloadExportSourceFile>> listFiles(
    DownloadExportCancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    if (initialItem.needsArchivePassword) {
      throw const DownloadExportSourceException('远程压缩包尚未解锁，无法导出');
    }
    var item = initialItem;
    if (!item.hasCompletePages || !item.hasMeaningfulEpisodeTitles) {
      item = await item.client.fetchItemDetail(item.id);
    }
    if (item.needsArchivePassword) {
      throw const DownloadExportSourceException('远程压缩包尚未解锁，无法导出');
    }
    if (item.episodesData.isEmpty || !item.hasCompletePages) {
      throw const DownloadExportSourceException(
        '远程详情缺少完整章节或页序，不能安全导出',
      );
    }

    final episodes = item.episodesData.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final result = <DownloadExportSourceFile>[];
    final usedPaths = <String>{};
    final multipleEpisodes = episodes.length > 1;
    for (final episode in episodes) {
      cancellation.throwIfCancelled();
      final chapter = multipleEpisodes
          ? DownloadExportPathTools.sanitizeSegment(
              episode.title.trim().isEmpty
                  ? '第${episode.index}章'
                  : episode.title,
            )
          : '';
      for (var pageIndex = 0; pageIndex < episode.pages.length; pageIndex++) {
        final url = episode.pages[pageIndex].trim();
        if (url.isEmpty) {
          throw const DownloadExportSourceException('远程详情包含空的图片资源地址');
        }
        var fileName = _fileNameForUrl(url, pageIndex + 1);
        if (chapter.isNotEmpty) fileName = '$chapter/$fileName';
        fileName = DownloadExportPathTools.uniqueRelativePath(
          fileName,
          usedPaths,
        );
        result.add(_RemoteDownloadExportFile(
          client: item.client,
          url: url,
          relativePath: fileName,
        ));
      }
    }
    if (result.isEmpty) {
      throw const DownloadExportSourceException('远程漫画没有可导出的页面');
    }
    return result;
  }

  static String _fileNameForUrl(String url, int index) {
    final uri = Uri.tryParse(url);
    final rawName = uri == null || uri.pathSegments.isEmpty
        ? ''
        : uri.pathSegments.last.trim();
    final decoded = Uri.decodeComponent(rawName);
    if (decoded.isEmpty || decoded == '.' || decoded == '..') {
      return 'page-$index.img';
    }
    return DownloadExportPathTools.sanitizeSegment(decoded);
  }
}

class _RemoteDownloadExportFile implements DownloadExportSourceFile {
  _RemoteDownloadExportFile({
    required this.client,
    required this.url,
    required this.relativePath,
  });

  final RemoteLibraryClient client;
  final String url;

  @override
  final String relativePath;

  @override
  int? get sizeBytes => null;

  @override
  Future<int> copyTo(
    File target,
    DownloadExportCancellationToken cancellation,
    void Function(int bytes) onBytes,
  ) async {
    cancellation.throwIfCancelled();
    await target.parent.create(recursive: true);
    final sink = target.openWrite();
    var total = 0;
    try {
      await for (final chunk in client.loadImage(url)) {
        cancellation.throwIfCancelled();
        sink.add(chunk);
        total += chunk.length;
        onBytes(chunk.length);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (total == 0) {
      throw const DownloadExportSourceException('远程图片返回为空');
    }
    return total;
  }
}
