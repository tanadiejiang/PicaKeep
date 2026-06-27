part of 'local_resource_scanner.dart';

extension LocalResourceScannerCover on LocalResourceScanner {
  Future<String> resolveCoverPathOnly(
    ServerResourceItemSummary shallow, {
    required String? rootPath,
  }) async {
    final metadataCoverPath = shallow.coverPath?.trim() ?? '';
    if (metadataCoverPath.isNotEmpty &&
        await PrivilegedStorageAccess.fileExists(metadataCoverPath)) {
      return metadataCoverPath;
    }

    final directCover = await _findCoverLikeImage(shallow.path);
    if (directCover != null) {
      return directCover;
    }

    final directImages = await _listDirectVisibleImages(shallow.path);
    if (directImages.isNotEmpty) {
      return directImages.first;
    }

    final children = await _listDirectories(shallow.path);
    if (children.isEmpty) {
      return '';
    }
    final firstChildImages = await _listDirectVisibleImages(children.first);
    if (firstChildImages.isNotEmpty) {
      return firstChildImages.first;
    }
    return '';
  }

  String _extractCoverPath(
    Map<String, dynamic>? data,
    Map<String, dynamic>? comicItemMap,
    _ParsedDownloadRecord? parsedItem,
  ) {
    final parsedCover = parsedItem?.coverPath.trim() ?? '';
    if (parsedCover.isNotEmpty) {
      return parsedCover;
    }

    for (final map in _candidateMetadataMaps(data, comicItemMap)) {
      for (final key in const ['coverPath', 'cover', 'localCoverPath']) {
        final raw = map[key]?.toString().trim() ?? '';
        if (raw.isNotEmpty) {
          return raw;
        }
      }
    }
    return '';
  }

  String _resolveShallowItemCoverPath(
    String? metadataCoverPath,
    String directoryPath,
  ) {
    final normalizedMetadataPath = metadataCoverPath?.trim() ?? '';
    if (normalizedMetadataPath.isNotEmpty) {
      return normalizedMetadataPath;
    }
    return '';
  }

  Future<String> _resolveItemCoverPath(
    String? metadataCoverPath,
    String directoryPath,
    List<ServerResourceEpisodeSummary> episodes,
  ) async {
    final normalizedMetadataPath = metadataCoverPath?.trim() ?? '';
    if (normalizedMetadataPath.isNotEmpty &&
        await PrivilegedStorageAccess.fileExists(normalizedMetadataPath)) {
      return normalizedMetadataPath;
    }

    final coverFile = await _findCoverLikeImage(directoryPath);
    if (coverFile != null) {
      return coverFile;
    }

    for (final episode in episodes) {
      final coverPath = episode.coverPath?.trim() ?? '';
      if (coverPath.isNotEmpty) {
        return coverPath;
      }
    }
    return '';
  }

  Future<String> _resolveEpisodeCoverPath(
    String directoryPath,
    List<String> images,
  ) async {
    final coverFile = await _findCoverLikeImage(directoryPath);
    if (coverFile != null) {
      return coverFile;
    }
    return images.first;
  }

  Future<String?> _findCoverLikeImage(String directoryPath) async {
    final entries =
        await PrivilegedStorageAccess.listDirectoryEntries(directoryPath);
    for (final entry in entries) {
      if (entry.isDirectory) {
        continue;
      }
      if (!_isImageFile(entry.path) || _isInServerTrash(entry.path)) {
        continue;
      }
      if (_isCoverLikeFile(entry.path)) {
        return entry.path;
      }
    }
    return null;
  }

  bool _isCoverLikeFile(String path) {
    final name = _basename(path).toLowerCase();
    return name == 'cover.jpg' ||
        name == 'cover.jpeg' ||
        name == 'cover.png' ||
        name == 'cover.webp';
  }
}
