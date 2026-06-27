part of 'local_resource_scanner.dart';

extension LocalResourceScannerMetadata on LocalResourceScanner {
  Future<_ServerResourceMetadata> _extractDownloadMetadata({
    required String id,
    required String title,
    required String subtitle,
    required DateTime? updatedAt,
    required Map<String, dynamic>? data,
    required _ParsedDownloadRecord? parsedItem,
    required String fallbackSourceDisplayName,
  }) async {
    final comicItem = data?['comicItem'];
    final comicItemMap = comicItem is Map
        ? comicItem.map((key, value) => MapEntry(key.toString(), value))
        : null;
    final parsedTags = parsedItem?.tags
            .map((entry) => entry.trim())
            .where((entry) => entry.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    final parsedEpisodeTitles = _parsedEpisodeTitles(parsedItem);
    return _ServerResourceMetadata(
      title: _firstNonEmptyValue([
        parsedItem?.name,
        title,
        data?['title']?.toString(),
        comicItemMap?['title']?.toString(),
      ]),
      subtitle: _firstNonEmptyValue([
        parsedItem?.subtitle,
        subtitle,
        data?['subtitle']?.toString(),
        data?['subTitle']?.toString(),
        data?['author']?.toString(),
        comicItemMap?['subTitle']?.toString(),
        comicItemMap?['author']?.toString(),
      ]),
      displayId: _firstNonEmptyValue([
        data?['displayId']?.toString(),
        data?['comicId']?.toString(),
        parsedItem?.data['displayId']?.toString(),
        parsedItem?.data['comicId']?.toString(),
        parsedItem?.data['comicID']?.toString(),
        comicItemMap?['displayId']?.toString(),
        comicItemMap?['comicId']?.toString(),
        comicItemMap?['id']?.toString(),
        parsedItem?.id,
        id,
      ]),
      tags: parsedTags.isNotEmpty
          ? parsedTags
          : _extractTagValues(data, comicItemMap),
      coverPath: _extractCoverPath(data, comicItemMap, parsedItem),
      sourceDisplayName: _firstNonEmptyValue([
        data?['sourceDisplayName']?.toString(),
        parsedItem?.sourceDisplayName,
        _inferSourceDisplayName(id, data),
        fallbackSourceDisplayName,
      ]),
      episodeTitles: parsedEpisodeTitles.isNotEmpty
          ? parsedEpisodeTitles
          : _extractEpisodeTitles(data, comicItemMap),
      updatedAt: updatedAt,
    );
  }

  Map<String, dynamic>? _decodeJsonMap(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {}
    return null;
  }

  List<String> _parsedEpisodeTitles(_ParsedDownloadRecord? parsedItem) {
    if (parsedItem == null) {
      return const <String>[];
    }
    final titles = parsedItem.episodeTitles
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
    if (titles.isEmpty) {
      return const <String>[];
    }
    if (titles.length == 1 && titles.first == parsedItem.name.trim()) {
      return const <String>[];
    }
    return titles;
  }

  _ParsedDownloadRecord? _parseDownloadedRecord(
    String id,
    Map<String, dynamic>? data, {
    required String directory,
    required String fallbackTitle,
    required String fallbackSubtitle,
    required String fallbackSourceDisplayName,
  }) {
    if (data == null) {
      return null;
    }
    final comicItemMap = _asStringDynamicMap(data['comicItem']);
    final name = _firstNonEmptyValue([
      data['name']?.toString(),
      data['title']?.toString(),
      data['galleryTitle']?.toString(),
      data['comicTitle']?.toString(),
      comicItemMap?['title']?.toString(),
      fallbackTitle,
    ]);
    final subtitle = _firstNonEmptyValue([
      data['subtitle']?.toString(),
      data['subTitle']?.toString(),
      data['author']?.toString(),
      comicItemMap?['subTitle']?.toString(),
      comicItemMap?['author']?.toString(),
      fallbackSubtitle,
    ]);
    final parsedDirectory = _firstNonEmptyValue([
      directory,
      data['directory']?.toString(),
      data['path']?.toString(),
      data['localPath']?.toString(),
      data['downloadPath']?.toString(),
    ]);
    final tags = _extractTagValues(data, comicItemMap);
    final episodeTitles = _extractEpisodeTitles(data, comicItemMap);
    final coverPath = _extractCoverPath(data, comicItemMap, null);
    return _ParsedDownloadRecord(
      id: _firstNonEmptyValue([
        data['id']?.toString(),
        data['comicId']?.toString(),
        data['comicID']?.toString(),
        comicItemMap?['id']?.toString(),
        comicItemMap?['comicId']?.toString(),
        id,
      ]),
      name: name,
      subtitle: subtitle,
      directory: parsedDirectory,
      tags: tags,
      episodeTitles: episodeTitles,
      coverPath: coverPath,
      sourceDisplayName: _firstNonEmptyValue([
        data['sourceDisplayName']?.toString(),
        _inferSourceDisplayName(id, data),
        fallbackSourceDisplayName,
      ]),
      comicSizeMb: _extractComicSizeMb(data),
      data: data,
    );
  }

  Iterable<Map<String, dynamic>> _candidateMetadataMaps(
    Map<String, dynamic>? data,
    Map<String, dynamic>? comicItemMap,
  ) sync* {
    for (final map in [
      data,
      comicItemMap,
      _asStringDynamicMap(data?['comic']),
      _asStringDynamicMap(data?['gallery']),
      _asStringDynamicMap(data?['metadata']),
      _asStringDynamicMap(data?['detail']),
      _asStringDynamicMap(comicItemMap?['comic']),
      _asStringDynamicMap(comicItemMap?['gallery']),
      _asStringDynamicMap(comicItemMap?['metadata']),
      _asStringDynamicMap(comicItemMap?['detail']),
    ]) {
      if (map != null) {
        yield map;
      }
    }
  }

  Map<String, dynamic>? _asStringDynamicMap(Object? raw) {
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  List<String> _extractTagValues(
    Map<String, dynamic>? data,
    Map<String, dynamic>? comicItemMap,
  ) {
    for (final map in _candidateMetadataMaps(data, comicItemMap)) {
      for (final key in const [
        'tagList',
        'tags',
        'metadataTags',
        'categories',
        'category',
        'groups',
        'labels',
        'keywords',
      ]) {
        final tags = _normalizeTagValues(map[key]);
        if (tags.isNotEmpty) {
          return tags;
        }
      }
    }
    return const <String>[];
  }

  List<String> _normalizeTagValues(Object? raw) {
    if (raw is List) {
      return raw
          .map(_tagValueFromEntry)
          .map((entry) => entry.trim())
          .where((entry) => entry.isNotEmpty)
          .toSet()
          .toList(growable: false);
    }
    if (raw is Map) {
      return raw.values
          .expand(_normalizeTagValues)
          .map((entry) => entry.trim())
          .where((entry) => entry.isNotEmpty)
          .toSet()
          .toList(growable: false);
    }
    if (raw is String) {
      final normalized = raw.trim();
      if (normalized.isEmpty) {
        return const <String>[];
      }
      if (normalized.startsWith('[') && normalized.endsWith(']')) {
        final decoded = _decodeJsonMap('{"tags":$normalized}')?['tags'];
        if (decoded != null) {
          return _normalizeTagValues(decoded);
        }
      }
      if (normalized.startsWith('{') && normalized.endsWith('}')) {
        final decoded = _decodeJsonMap(normalized);
        if (decoded != null) {
          return _normalizeTagValues(decoded);
        }
      }
      return normalized
          .split(RegExp(r'\s*[,，]\s*'))
          .map((entry) => entry.trim())
          .where((entry) => entry.isNotEmpty)
          .toSet()
          .toList(growable: false);
    }
    final single = raw?.toString().trim() ?? '';
    if (single.isEmpty) {
      return const <String>[];
    }
    return <String>[single];
  }

  String _tagValueFromEntry(Object? raw) {
    if (raw == null) {
      return '';
    }
    if (raw is Map) {
      final mapped = raw.map((key, value) => MapEntry(key.toString(), value));
      return _firstNonEmptyValue([
        mapped['tag']?.toString(),
        mapped['name']?.toString(),
        mapped['title']?.toString(),
        mapped['value']?.toString(),
      ]);
    }
    return raw.toString().trim();
  }

  List<String> _extractEpisodeTitles(
    Map<String, dynamic>? data,
    Map<String, dynamic>? comicItemMap,
  ) {
    for (final map in _candidateMetadataMaps(data, comicItemMap)) {
      for (final key in const [
        'chapters',
        'eps',
        'episodes',
        'episodeList',
        'chapterList',
        'epList',
        'epNames',
      ]) {
        final titles = _normalizeEpisodeTitles(map[key]);
        if (titles.isNotEmpty) {
          return titles;
        }
      }
    }
    return const <String>[];
  }

  double? _extractComicSizeMb(Map<String, dynamic>? data) {
    if (data == null) {
      return null;
    }
    for (final map in _candidateMetadataMaps(
        data, _asStringDynamicMap(data['comicItem']))) {
      final value = _normalizeComicSizeMb(
        map['comicSize'] ?? map['size'] ?? map['totalSize'],
      );
      if (value != null) {
        return value;
      }
    }
    return null;
  }

  double? _normalizeComicSizeMb(Object? raw) {
    if (raw is num) {
      final value = raw.toDouble();
      return value > 0 ? value : null;
    }
    if (raw is String) {
      final value = double.tryParse(raw.trim());
      if (value != null && value > 0) {
        return value;
      }
    }
    return null;
  }

  int _comicSizeMbToBytes(double? comicSizeMb) {
    if (comicSizeMb == null || comicSizeMb <= 0) {
      return 0;
    }
    return (comicSizeMb * 1024 * 1024).round();
  }

  List<String> _normalizeEpisodeTitles(Object? raw) {
    if (raw is List) {
      return raw
          .map((entry) => _episodeTitleFromValue(entry))
          .where((entry) => entry.isNotEmpty)
          .toList(growable: false);
    }
    if (raw is Map) {
      final entries = raw.entries.toList()
        ..sort((a, b) => (int.tryParse(a.key.toString()) ?? 0).compareTo(
              int.tryParse(b.key.toString()) ?? 0,
            ));
      return entries
          .map((entry) => _episodeTitleFromValue(entry.value))
          .where((entry) => entry.isNotEmpty)
          .toList(growable: false);
    }
    final single = _episodeTitleFromValue(raw);
    return single.isEmpty ? const <String>[] : <String>[single];
  }

  String _episodeTitleFromValue(Object? raw) {
    if (raw == null) {
      return '';
    }
    if (raw is String) {
      return raw.trim();
    }
    if (raw is Map) {
      final mapped = raw.map((key, value) => MapEntry(key.toString(), value));
      return _firstNonEmptyValue([
        mapped['title']?.toString(),
        mapped['name']?.toString(),
        mapped['chapter']?.toString(),
        mapped['epName']?.toString(),
        mapped['shortTitle']?.toString(),
        mapped['value']?.toString(),
      ]);
    }
    return raw.toString().trim();
  }

  List<ServerResourceEpisodeSummary> _applyEpisodeTitles(
    List<ServerResourceEpisodeSummary> episodes,
    List<String> titles,
  ) {
    if (episodes.isEmpty || titles.isEmpty) {
      return episodes;
    }
    return [
      for (var i = 0; i < episodes.length; i++)
        ServerResourceEpisodeSummary(
          index: episodes[i].index,
          title: i < titles.length && titles[i].trim().isNotEmpty
              ? titles[i].trim()
              : episodes[i].title,
          path: episodes[i].path,
          imageCount: episodes[i].imageCount,
          totalBytes: episodes[i].totalBytes,
          coverPath: episodes[i].coverPath,
          imagePaths: episodes[i].imagePaths,
          imageSizes: episodes[i].imageSizes,
        ),
    ];
  }

  String _inferSourceDisplayName(String id, Map<String, dynamic>? data) {
    final sourceKey =
        (data?['sourceKey']?.toString() ?? '').trim().toLowerCase();
    if (sourceKey == 'copy_manga') return '拷贝漫画';
    if (sourceKey == 'komiic') return 'Komiic';
    if (sourceKey == 'jm') return '禁漫';
    if (sourceKey == 'hitomi') return 'Hitomi';
    if (sourceKey == 'nhentai') return 'NHentai';
    if (sourceKey == 'htmanga') return '绅士漫画';
    if (sourceKey == 'ehentai') return 'E-Hentai';
    if (sourceKey == 'picacg') return '哔咔';

    final normalizedId = id.trim().toLowerCase();
    if (normalizedId.startsWith('jm')) return '禁漫';
    if (normalizedId.startsWith('hitomi')) return 'Hitomi';
    if (normalizedId.startsWith('nhentai')) return 'NHentai';
    if (normalizedId.startsWith('ht')) return '绅士漫画';
    if (normalizedId.contains('-')) {
      final prefix = normalizedId.split('-').first;
      if (prefix == 'copy_manga') return '拷贝漫画';
      if (prefix == 'komiic') return 'Komiic';
    }
    if (RegExp(r'^[0-9a-f]{24}$').hasMatch(normalizedId)) return '哔咔';
    if (RegExp(r'^\d+$').hasMatch(normalizedId)) return 'E-Hentai';
    return '';
  }

  List<String> _metadataLookupKeysForStoredRecord(
    String rootPath,
    String rawId,
    String rawDirectory,
  ) {
    final keys = <String>[];

    void add(String value) {
      final normalized = value.trim();
      if (normalized.isEmpty || keys.contains(normalized)) {
        return;
      }
      keys.add(normalized);
    }

    final normalizedDirectoryPath =
        _normalizeManagedDirectoryPath(rootPath, rawDirectory);
    final relativeDirectoryPath =
        _relativeManagedDirectoryPath(rootPath, normalizedDirectoryPath);

    add('id::${rawId.trim()}');
    add(normalizedDirectoryPath);
    add(relativeDirectoryPath);
    add(_normalizePath(rawDirectory));
    add(_normalizePath(_basename(rawDirectory)));
    add(_normalizePath(_basename(normalizedDirectoryPath)));
    add(_normalizePath(_basename(relativeDirectoryPath)));
    return keys;
  }

  List<String> _metadataLookupKeysForResolvedDirectory(
    String rootPath,
    String directoryPath,
  ) {
    final keys = <String>[];

    void add(String value) {
      final normalized = value.trim();
      if (normalized.isEmpty || keys.contains(normalized)) {
        return;
      }
      keys.add(normalized);
    }

    final normalizedDirectoryPath = _normalizePath(directoryPath);
    final relativeDirectoryPath =
        _relativeManagedDirectoryPath(rootPath, normalizedDirectoryPath);

    add(normalizedDirectoryPath);
    add(relativeDirectoryPath);
    add(_normalizePath(_basename(directoryPath)));
    add(_normalizePath(_basename(normalizedDirectoryPath)));
    add(_normalizePath(_basename(relativeDirectoryPath)));
    return keys;
  }

  Future<ServerResourceEpisodeSummary?> _buildEpisodeSummary({
    required int index,
    required String title,
    required String directory,
    required List<String> images,
    required bool includeTotalBytes,
  }) async {
    if (images.isEmpty) {
      return null;
    }

    return ServerResourceEpisodeSummary(
      index: index,
      title: title,
      path: directory,
      imageCount: images.length,
      totalBytes: includeTotalBytes ? await _calculateTotalBytes(images) : 0,
      coverPath: await _resolveEpisodeCoverPath(directory, images),
      imagePaths: images,
      imageSizes: List<ServerResourceImageSize?>.filled(images.length, null),
    );
  }
}
