part of 'local_library.dart';

const MethodChannel _storageAccessChannel =
    MethodChannel('lingxue.picakeep/storage_access');

String _albumDisplayTitleForLeafDirectory(String dirPath) {
  final leafTitle = _basename(dirPath).trim();
  if (!_isPlainNumericTitle(leafTitle)) {
    return leafTitle;
  }
  final parentTitle = _parentDirectoryTitle(dirPath).trim();
  return parentTitle.isEmpty ? leafTitle : parentTitle;
}

String _episodeTitleForLeafDirectory(String dirPath, String displayTitle) {
  final leafTitle = _basename(dirPath).trim();
  final normalizedDisplay = displayTitle.trim();
  if (_isPlainNumericTitle(leafTitle)) {
    final numeric = int.tryParse(leafTitle);
    if (numeric != null && normalizedDisplay.isNotEmpty) {
      return '$normalizedDisplay 第$numeric话';
    }
  }
  return '全部';
}

String _parentDirectoryTitle(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/').where((e) => e.isNotEmpty).toList();
  if (segments.length < 2) {
    return '';
  }
  return segments[segments.length - 2];
}

bool _isPlainNumericTitle(String value) {
  return RegExp(r'^\d+$').hasMatch(value.trim());
}

String _basenameWithoutExtension(String name) {
  final dotIdx = name.lastIndexOf('.');
  if (dotIdx > 0) return name.substring(0, dotIdx);
  return name;
}

bool _isRescannedLocalRecord(DownloadedItem item, String rawId) {
  if (item is CustomDownloadedItem) {
    return false;
  }
  if (item is DownloadedComic) {
    return !RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(rawId.trim());
  }
  return false;
}

DownloadType _effectiveDownloadTypeForLocalItem(
  DownloadedItem item,
  String rawId,
) {
  if (_isRescannedLocalRecord(item, rawId)) {
    return DownloadType.other;
  }
  return item.type;
}

String _displayNameForDownloaded(
  DownloadedItem item,
  String rawId,
  DownloadType resolvedType,
) {
  if (item is CustomDownloadedItem) {
    return item.sourceDisplayName;
  }
  if (_isRescannedLocalRecord(item, rawId)) {
    return '本地扫描';
  }
  return downloadTypeDisplayName(resolvedType);
}

int _rescanManagedDownloadSource(String rootPath) {
  final root = Directory(rootPath);
  if (!root.existsSync()) {
    return 0;
  }

  final db = sqlite3.open(_joinPath(rootPath, 'download.db'));
  try {
    db.execute('''
      create table if not exists download(
        id text primary key,
        title text,
        subtitle text,
        time int,
        directory text,
        size int,
        json text
      )
    ''');

    final knownIds = db
        .select('select id from download')
        .map((row) => (row['id'] as String? ?? '').trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    final knownDirectories = db
        .select('select directory from download')
        .map((row) => (row['directory'] as String? ?? '').trim())
        .where((directory) => directory.isNotEmpty)
        .toSet();

    var count = 0;
    final hiddenIndex = LocalTrashStore.instance.hiddenIndexSync();
    for (final entry in _safeList(root).whereType<Directory>()) {
      final dirName = _basename(entry.path);
      if (dirName.isEmpty ||
          dirName == _localTrashDirectoryName ||
          hiddenIndex.matchesPath(entry.path) ||
          knownIds.contains(dirName) ||
          knownDirectories.contains(dirName)) {
        continue;
      }

      final subEntries = _safeList(entry);
      final chapterDirs = subEntries
          .whereType<Directory>()
          .where(_containsVisibleImages)
          .toList()
        ..sort((a, b) => _naturalCompare(_basename(a.path), _basename(b.path)));
      final hasFlatImages = subEntries.any(_isVisibleImageFile);
      if (chapterDirs.isEmpty && !hasFlatImages) {
        continue;
      }

      final chapters = <String>[];
      final downloadedChapters = <int>[];
      if (chapterDirs.isNotEmpty) {
        for (final chapterDir in chapterDirs) {
          chapters.add(_basename(chapterDir.path));
          downloadedChapters.add(chapters.length - 1);
        }
      } else {
        chapters.add('第1章');
        downloadedChapters.add(0);
      }

      final comic = DownloadedComic(
        comicId: dirName,
        title: dirName,
        author: '',
        chapters: chapters,
        downloadedChapters: downloadedChapters,
        size: _computeDirectorySizeMb(entry),
        tagList: const <String>[],
      )
        ..time = DateTime.now()
        ..directory = dirName;

      db.execute('''
        insert or replace into download
        values (?,?,?,?,?,?,?)
      ''', [
        comic.id,
        comic.name,
        comic.subTitle,
        comic.time!.millisecondsSinceEpoch,
        dirName,
        comic.comicSize,
        jsonEncode(comic.toJson()),
      ]);
      knownIds.add(dirName);
      knownDirectories.add(dirName);
      count++;
    }

    return count;
  } finally {
    db.dispose();
  }
}

Future<Map<int, List<String>>> _buildDownloadedEpisodeFiles(
  String itemDirectory,
  DownloadedItem? _,
) async {
  final entries = await _listDirectoryEntries(itemDirectory);
  final childDirs = entries.where((entry) => entry.isDirectory).toList();
  final chapterDirs = <_LocalDirectoryEntry>[];
  for (final childDir in childDirs) {
    if (await _containsVisibleImagesForPath(childDir.path)) {
      chapterDirs.add(childDir);
    }
  }
  chapterDirs.sort((a, b) => _naturalCompare(a.name, b.name));

  final result = <int, List<String>>{};
  if (chapterDirs.isNotEmpty) {
    for (int i = 0; i < chapterDirs.length; i++) {
      final files = await _sortedImageFilesForPath(
        chapterDirs[i].path,
        sortMode: localAlbumImageSortNameAsc,
      );
      if (files.isNotEmpty) {
        result[i + 1] = files;
      }
    }
    return result;
  }

  final files = await _sortedImageFilesForPath(
    itemDirectory,
    sortMode: localAlbumImageSortNameAsc,
  );
  if (files.isNotEmpty) {
    result[0] = files;
  }
  return result;
}

Future<List<String>> _buildDownloadedEpisodeFilesForEp(
  String itemDirectory,
  int ep,
) async {
  final entries = await _listDirectoryEntries(itemDirectory);
  final childDirs = entries.where((entry) => entry.isDirectory).toList()
    ..sort((a, b) => _naturalCompare(a.name, b.name));
  if (childDirs.isNotEmpty) {
    final exact =
        childDirs.where((entry) => entry.name == ep.toString()).toList();
    final target = exact.isNotEmpty
        ? exact.first
        : (ep > 0 && ep <= childDirs.length ? childDirs[ep - 1] : null);
    if (target != null) {
      return _sortedImageFilesForPath(
        target.path,
        sortMode: localAlbumImageSortNameAsc,
      );
    }
    if (childDirs.length == 1 && (ep == 0 || ep == 1)) {
      return _sortedImageFilesForPath(
        childDirs.first.path,
        sortMode: localAlbumImageSortNameAsc,
      );
    }
  }
  if (ep == 0 || ep == 1) {
    return _sortedImageFilesForPath(
      itemDirectory,
      sortMode: localAlbumImageSortNameAsc,
    );
  }
  return const <String>[];
}

List<String> _buildLocalEpisodeNames(int episodeCount) {
  if (episodeCount <= 1) {
    return const <String>['全部'];
  }
  return List<String>.generate(episodeCount, (index) => '第${index + 1}章');
}

Future<List<String>> _collectLeafAlbumDirectoryPaths(
  String rootPath,
) async {
  final result = <String>[];

  Future<bool> visit(String path) async {
    if (_basename(path) == _localTrashDirectoryName) {
      return false;
    }
    final children = await _listDirectoryEntries(path);
    final hasImages = children.any(
      (entry) => !entry.isDirectory && _isVisibleImagePath(entry.path),
    );
    var hasAlbumDescendant = false;
    for (final subDir in children.where((entry) => entry.isDirectory)) {
      if (subDir.name == _localTrashDirectoryName) {
        continue;
      }
      if (await visit(subDir.path)) {
        hasAlbumDescendant = true;
      }
    }
    if (hasImages && !hasAlbumDescendant) {
      result.add(path);
      return true;
    }
    return hasImages || hasAlbumDescendant;
  }

  await visit(rootPath);
  result.sort();
  return result;
}

Future<bool> _shouldTreatAsSingleAlbumSource(String rootPath) async {
  final children = await _listDirectoryEntries(rootPath);
  if (children.isEmpty) {
    return false;
  }
  if (children
      .any((entry) => !entry.isDirectory && _isVisibleImagePath(entry.path))) {
    return true;
  }
  final childDirs =
      children.where((entry) => entry.isDirectory).toList(growable: false);
  if (childDirs.isEmpty) {
    return false;
  }
  final imageBearingDirs = <_LocalDirectoryEntry>[];
  for (final childDir in childDirs) {
    if (await _containsVisibleImagesForPath(childDir.path)) {
      imageBearingDirs.add(childDir);
    }
  }
  if (imageBearingDirs.isEmpty || imageBearingDirs.length != childDirs.length) {
    return false;
  }
  return imageBearingDirs.every(
    (entry) => _looksLikeEpisodeDirectoryName(entry.name),
  );
}

bool _looksLikeEpisodeDirectoryName(String name) {
  final normalized = name.trim().toLowerCase();
  if (normalized.isEmpty) {
    return false;
  }
  return RegExp(r'^\d+$').hasMatch(normalized) ||
      RegExp(r'^0\d+$').hasMatch(normalized) ||
      RegExp(r'^第?\d+[话話章节卷卷集册冊]$').hasMatch(normalized) ||
      normalized.startsWith('ep') ||
      normalized.startsWith('episode') ||
      normalized.startsWith('chapter') ||
      normalized.startsWith('chap') ||
      normalized.startsWith('vol');
}

Future<List<String>> _sortedAlbumImagesForPath(String dirPath) {
  return _sortedImageFilesForPath(
    dirPath,
    sortMode: LocalLibraryManager.instance.localAlbumImageSort,
  );
}

Future<List<String>> _sortImagePathsAsync(
  Iterable<String> paths, {
  required String sortMode,
}) async {
  final existing = <String>[];
  for (final path in paths) {
    if (await _fileExists(path)) {
      existing.add(path);
    }
  }
  existing.sort((a, b) => _compareImagePaths(a, b, sortMode));
  return existing;
}

Future<List<String>> _sortedImageFilesForPath(
  String dirPath, {
  required String sortMode,
}) async {
  final files = (await _listDirectoryEntries(dirPath))
      .where((entry) => !entry.isDirectory && _isVisibleImagePath(entry.path))
      .map((entry) => entry.path)
      .toList();
  if (files.isEmpty) {
    return const <String>[];
  }

  files.sort((a, b) => _compareImagePaths(a, b, sortMode));

  final visibleFiles = files.where((path) => !_isCoverLikePath(path)).toList();
  if (visibleFiles.isNotEmpty) {
    return visibleFiles;
  }
  return files;
}

int _compareImagePaths(String a, String b, String sortMode) {
  switch (normalizeLocalAlbumImageSort(sortMode)) {
    case localAlbumImageSortNameDesc:
      return -_naturalCompare(_basename(a), _basename(b));
    case localAlbumImageSortTimeAsc:
      return _compareFileModifiedTime(a, b);
    case localAlbumImageSortTimeDesc:
      return _compareFileModifiedTime(b, a);
    case localAlbumImageSortNameAsc:
    default:
      return _naturalCompare(_basename(a), _basename(b));
  }
}

int _compareFileModifiedTime(String a, String b) {
  try {
    return File(a).statSync().modified.compareTo(File(b).statSync().modified);
  } catch (_) {
    return _naturalCompare(_basename(a), _basename(b));
  }
}

Future<bool> _containsVisibleImagesForPath(String dirPath) async {
  return (await _listDirectoryEntries(dirPath))
      .any((entry) => !entry.isDirectory && _isVisibleImagePath(entry.path));
}

bool _containsVisibleImages(Directory dir) {
  return _safeList(dir).whereType<File>().any(_isVisibleImageFile);
}

Future<String?> _pickCoverPath(
  String dirPath,
  List<String> orderedImages,
) async {
  for (final candidate in [
    'cover.jpg',
    'cover.jpeg',
    'cover.png',
    'cover.webp'
  ]) {
    final path = _joinPath(dirPath, candidate);
    if (await _fileExists(path)) {
      return path;
    }
  }
  return orderedImages.isNotEmpty ? orderedImages.first : null;
}

Future<DateTime> _computeAlbumTimeForPath(
  String dirPath,
  List<String> images,
) async {
  try {
    var latest = Directory(dirPath).statSync().modified;
    for (final path in images) {
      final modified = File(path).statSync().modified;
      if (modified.isAfter(latest)) {
        latest = modified;
      }
    }
    return latest;
  } catch (_) {
    return DateTime.now();
  }
}

double _computeDirectorySizeMb(Directory dir) {
  double bytes = 0;
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File) {
      try {
        bytes += entity.lengthSync();
      } catch (_) {}
    }
  }
  return bytes / 1024 / 1024;
}

Future<double> _computeDirectorySizeMbForPath(String path) async {
  try {
    if (Directory(path).existsSync()) {
      return _computeDirectorySizeMb(Directory(path));
    }
  } catch (_) {}

  double bytes = 0;
  Future<void> visit(String dirPath) async {
    for (final entry in await _listDirectoryEntries(dirPath)) {
      if (entry.isDirectory) {
        await visit(entry.path);
      } else {
        bytes += await _fileLength(entry.path);
      }
    }
  }

  try {
    await visit(path);
  } catch (_) {}
  return bytes / 1024 / 1024;
}

Future<String> _resolveDownloadItemDirectoryFromMetadata(
  String rootPath,
  String rawId,
  String rawDirectory,
  DownloadedItem item,
  Set<String> sourceDirectoryNames, {
  bool trustStorageFromDatabase = false,
}) async {
  final candidates = <String>[
    if (rawDirectory.trim().isNotEmpty) rawDirectory.trim(),
    if (item.directory?.trim().isNotEmpty == true) item.directory!.trim(),
    rawId,
    item.id,
    _sanitizeFileName(rawDirectory.trim().isNotEmpty ? rawDirectory : rawId),
    _sanitizeFileName(item.name),
  ];

  String? firstCandidate;
  final seenPaths = <String>{};
  for (final value in candidates) {
    final normalized = value.trim();
    if (normalized.isEmpty) continue;
    final candidate = p.normalize(
      p.isAbsolute(normalized) ? normalized : p.join(rootPath, normalized),
    );
    firstCandidate ??= candidate;
    if (!seenPaths.add(candidate)) continue;
    // 优先复用已经列出的真实目录；显式字段失效后才尝试 ID/清理后的名称。
    final indexed = _indexedManagedDownloadDirectory(
      rootPath,
      candidate,
      sourceDirectoryNames,
    );
    if (indexed != null) return indexed;
    if (!trustStorageFromDatabase && await _directoryExists(candidate)) {
      return candidate;
    }
  }
  // 没有真实目录时保留原路径，交由“显示全部数据库记录”决定是否展示占位。
  return firstCandidate ?? rootPath;
}

String? _indexedManagedDownloadDirectory(
  String rootPath,
  String itemDirectory,
  Set<String> sourceDirectoryNames,
) {
  final normalizedRoot = p.normalize(rootPath);
  final normalizedItem = p.normalize(itemDirectory);
  // 索引仅列出根目录的直接子项，不能用父目录或同名目录证明其他路径存在。
  if (!p.equals(p.dirname(normalizedItem), normalizedRoot)) return null;
  final candidateName = p.basename(normalizedItem);
  final key = Platform.isWindows ? candidateName.toLowerCase() : candidateName;
  if (sourceDirectoryNames.contains(key)) {
    return p.join(normalizedRoot, candidateName);
  }
  return null;
}

bool _managedDownloadDirectoryExistsInIndex(
  String rootPath,
  String itemDirectory,
  Set<String> sourceDirectoryNames,
) =>
    _indexedManagedDownloadDirectory(
      rootPath,
      itemDirectory,
      sourceDirectoryNames,
    ) !=
    null;

Future<bool> _managedDownloadDirectoryExists(
  String rootPath,
  String itemDirectory,
  Set<String> sourceDirectoryNames,
) async {
  if (_managedDownloadDirectoryExistsInIndex(
    rootPath,
    itemDirectory,
    sourceDirectoryNames,
  )) {
    return true;
  }
  return _directoryExists(itemDirectory);
}

Future<bool> _directoryExists(String path) {
  return PrivilegedStorageAccess.directoryExists(path);
}

Future<bool> _fileExists(String path) {
  return PrivilegedStorageAccess.fileExists(path);
}

Future<bool> _isDownloadDirectoryAsync(String path) {
  return _fileExists(_joinPath(path, 'download.db'));
}

Future<Uint8List?> _readFileBytes(String path) {
  return PrivilegedStorageAccess.readFileBytes(path);
}

Future<int> _fileLength(String path) async {
  final length = await PrivilegedStorageAccess.fileLength(path);
  return length ?? 0;
}

Future<List<_LocalDirectoryEntry>> _listDirectoryEntries(
  String path,
) async {
  final entries = await PrivilegedStorageAccess.listDirectoryEntries(path);
  return entries
      .map(
        (entry) => _LocalDirectoryEntry(
          name: entry.name,
          path: entry.path,
          isDirectory: entry.isDirectory,
        ),
      )
      .toList();
}

Future<bool> _shouldUsePrivilegedFallbackForDirectory(
  String path,
) async {
  if (!Platform.isAndroid) {
    return false;
  }
  if (!_isAndroidPrivilegedAccessEnabled()) {
    return false;
  }
  if (_canAccessDirectoryWithDartIo(path)) {
    return false;
  }
  return true;
}

bool _looksLikeRootOnlyPath(String path) {
  final normalized = path.trim().replaceAll('\\', '/').toLowerCase();
  return normalized == '/data' ||
      normalized.startsWith('/data/') ||
      normalized.startsWith('/apex/') ||
      normalized.startsWith('/system/');
}

Future<bool> _existsWithShizukuAccess(String path) async {
  if (!Platform.isAndroid) {
    return false;
  }
  try {
    return await _storageAccessChannel.invokeMethod<bool>(
          'existsWithShizuku',
          {'path': path},
        ) ??
        false;
  } catch (_) {
    return false;
  }
}

Future<bool> _hasShizukuPermission({
  bool forceRefresh = false,
}) async {
  if (!Platform.isAndroid) {
    return false;
  }
  try {
    return await _storageAccessChannel.invokeMethod<bool>(
          'hasShizukuPermission',
          {'forceRefresh': forceRefresh},
        ) ??
        false;
  } catch (_) {
    return false;
  }
}

Future<bool> _hasRootAccess({
  bool forceRefresh = false,
}) async {
  if (!Platform.isAndroid) {
    return false;
  }
  try {
    return await _storageAccessChannel.invokeMethod<bool>(
          'hasRootAccess',
          {'forceRefresh': forceRefresh},
        ) ??
        false;
  } catch (_) {
    return false;
  }
}

bool _isAndroidPrivilegedAccessEnabled() {
  final rootEnabled =
      normalizeAndroidRootMode(appdata.settings[androidRootModeSettingIndex]) ==
          '1';
  if (rootEnabled) {
    return true;
  }
  return normalizeAndroidShizukuMode(
        appdata.settings[androidShizukuModeSettingIndex],
      ) ==
      '1';
}

bool _canAccessDirectoryWithDartIo(String path) {
  try {
    final directory = Directory(path);
    if (!directory.existsSync()) {
      return false;
    }
    directory.listSync(followLinks: false);
    return true;
  } catch (_) {
    return false;
  }
}

List<FileSystemEntity> _safeList(Directory dir) {
  try {
    return dir.listSync();
  } catch (_) {
    return const <FileSystemEntity>[];
  }
}

bool _isVisibleImageFile(FileSystemEntity entity) {
  if (entity is! File) {
    return false;
  }
  return _isVisibleImagePath(entity.path);
}

bool _isVisibleImagePath(String path) {
  final name = _basename(path).toLowerCase();
  return name.endsWith('.jpg') ||
      name.endsWith('.jpeg') ||
      name.endsWith('.png') ||
      name.endsWith('.webp');
}

bool _isCoverLikePath(String path) {
  final name = _basename(path).toLowerCase();
  return name == 'cover.jpg' ||
      name == 'cover.jpeg' ||
      name == 'cover.png' ||
      name == 'cover.webp';
}

int _naturalCompare(String a, String b) {
  final aa = _splitNatural(a.toLowerCase());
  final bb = _splitNatural(b.toLowerCase());
  final len = aa.length < bb.length ? aa.length : bb.length;
  for (int i = 0; i < len; i++) {
    final left = aa[i];
    final right = bb[i];
    final leftNum = int.tryParse(left);
    final rightNum = int.tryParse(right);
    if (leftNum != null && rightNum != null) {
      final diff = leftNum.compareTo(rightNum);
      if (diff != 0) {
        return diff;
      }
    } else {
      final diff = left.compareTo(right);
      if (diff != 0) {
        return diff;
      }
    }
  }
  return aa.length.compareTo(bb.length);
}

List<String> _splitNatural(String value) {
  return RegExp(r'\d+|\D+').allMatches(value).map((e) => e.group(0)!).toList();
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/').where((e) => e.isNotEmpty).toList();
  return segments.isEmpty ? path : segments.last;
}

String _joinPath(String base, String child) {
  if (base.isEmpty) {
    return child;
  }
  return '$base${Platform.pathSeparator}$child';
}

String _sanitizeFileName(String name) {
  var sanitized = name.trim();
  sanitized = sanitized.replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001F]'), '_');
  if (sanitized.isEmpty) {
    return 'unknown';
  }
  return sanitized;
}

String _safeCacheName(String value) {
  final sanitized = value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  return sanitized.isEmpty ? 'default' : sanitized;
}

bool _looksLikeCanonicalDownloadId(String id) {
  final value = id.trim();
  return value.contains('-') ||
      value.startsWith('jm') ||
      value.startsWith('hitomi') ||
      value.startsWith('nhentai') ||
      value.startsWith('Ht') ||
      RegExp(r'^\d+$').hasMatch(value) ||
      RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(value);
}

int _downloadRowPriority(String id, String directory) {
  final normalizedId = id.trim();
  final normalizedDirectory = directory.trim();
  if (normalizedId.isEmpty) {
    return -1;
  }
  if (_looksLikeCanonicalDownloadId(normalizedId) &&
      normalizedId != normalizedDirectory) {
    return 2;
  }
  if (_looksLikeCanonicalDownloadId(normalizedId)) {
    return 1;
  }
  return 0;
}

// 10号计划修复：本函数曾是 download_model.dart::parseDownloadedItemRecordData
// 的一份并行拷贝，长期与其分叉维护，导致这里缺失了后者已经修复过的
// ehentai 画廊 id（形如 '123-abc'，含连字符）精准拦截——本地库扫描路径下
// EH 已下载记录被 `id.contains('-')` 分支误判为 CustomDownloadedItem
// （DownloadType.other），连带其 comicSize 读取的是 json["comicSize"]
// （DownloadedGallery.toJson 实际写的键是 "size"，两者不匹配），显示为
// “未知大小”。现在直接委托给唯一权威实现，消除重复判定逻辑分叉的可能性。
DownloadedItem? _parseDownloadedItem(
  String id,
  String json,
  DateTime time,
  String? directory,
) {
  return parseDownloadedItemRecordJson(
    id,
    json,
    time: time,
    directory: directory,
  );
}

DownloadedItem? _downloadedItemFromDbRow(
  Row row,
  DateTime time,
  String directory,
) {
  final rawId = _downloadRowText(row, const ['id']) ?? '';
  if (rawId.isEmpty) {
    return null;
  }
  final title = _downloadRowText(row, const [
        'title',
        'name',
        'comicTitle',
        'galleryTitle',
        'label',
      ]) ??
      _basename(directory.isNotEmpty ? directory : rawId);
  final author = _downloadRowText(row, const [
        'subtitle',
        'subTitle',
        'author',
        'artist',
        'artists',
        'uploader',
        'user',
        'creator',
        'group',
        'circle',
      ]) ??
      '';
  final tags = _downloadRowTags(row, const [
    'tags',
    'tag',
    'tagList',
    'metadataTags',
    'categories',
    'category',
    'labels',
  ]);
  final size =
      _downloadRowDouble(row, const ['size', 'comicSize', 'totalSize']);
  final comic = ScannedDownloadedComic(
    comicId: rawId,
    title: title,
    author: author,
    chapters: const <String>['全部'],
    downloadedChapters: const <int>[0],
    size: size,
    tagList: tags,
  )
    ..time = time
    ..directory = directory;
  return comic;
}

double? _downloadRowDouble(Row row, Iterable<String> keys) {
  for (final key in keys) {
    try {
      final raw = row[key];
      if (raw is num) {
        return raw.toDouble();
      }
      final value = double.tryParse(raw?.toString().trim() ?? '');
      if (value != null) {
        return value;
      }
    } catch (_) {}
  }
  return null;
}

String _metadataTitleForDownloadedRow(
  Row row,
  DownloadedItem fallback,
) {
  final fromRow = _downloadRowText(row, const [
    'title',
    'name',
    'comicTitle',
    'galleryTitle',
    'label',
  ]);
  if (fromRow != null) {
    return fromRow;
  }
  return fallback.name;
}

String? _downloadRowText(Row row, Iterable<String> keys) {
  for (final key in keys) {
    try {
      final value = row[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    } catch (_) {}
  }
  return null;
}

List<String> _parseTagValues(Object? raw) {
  if (raw == null) {
    return const <String>[];
  }
  if (raw is List) {
    return raw
        .map((entry) => entry.toString().trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }
  final text = raw.toString().trim();
  if (text.isEmpty) {
    return const <String>[];
  }
  try {
    final decoded = jsonDecode(text);
    if (decoded is List) {
      final values = decoded
          .map((entry) => entry.toString().trim())
          .where((entry) => entry.isNotEmpty)
          .toList(growable: false);
      if (values.isNotEmpty) {
        return values;
      }
    }
  } catch (_) {}
  return text
      .split(RegExp(r'[,，;；|]'))
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty)
      .toList(growable: false);
}

List<String> _downloadRowTags(Row row, Iterable<String> keys) {
  for (final key in keys) {
    try {
      final values = _parseTagValues(row[key]);
      if (values.isNotEmpty) {
        return values;
      }
    } catch (_) {}
  }
  return const <String>[];
}

String _metadataAuthorForDownloadedRow(
  Row row,
  String json,
  DownloadedItem fallback,
) {
  final resolved = resolveDownloadedAuthorsFromRecord(
    fallback.id,
    json,
    fallback: fallback,
  );
  if (resolved.isNotEmpty) {
    return resolved.join(', ');
  }
  if (fallback.type == DownloadType.ehentai ||
      fallback.type == DownloadType.nhentai) {
    return '';
  }
  return resolveDownloadedAuthors(fallback).join(', ');
}

List<String> _metadataTagsForDownloadedRow(
  Row row,
  String json,
  DownloadedItem fallback,
) {
  final fromRow = _downloadRowTags(row, const [
    'tags',
    'tag',
    'tagList',
    'metadataTags',
  ]);
  if (fromRow.isNotEmpty) {
    return fromRow;
  }
  return _metadataTagsForDownloadedJson(json, fallback);
}

List<String> _metadataTagsForDownloadedJson(
  String json,
  DownloadedItem fallback,
) {
  if (fallback.tags.isNotEmpty) {
    return List<String>.from(fallback.tags);
  }

  try {
    final data = jsonDecode(json) as Map<String, dynamic>;
    List<String>? pick(Map data, Iterable<String> keys) {
      for (final key in keys) {
        final raw = data[key];
        if (raw is List) {
          final values = raw
              .map((entry) => entry.toString().trim())
              .where((entry) => entry.isNotEmpty)
              .toList(growable: false);
          if (values.isNotEmpty) {
            return values;
          }
        }
      }
      return null;
    }

    final root = pick(data, const ['tags', 'tagList', 'metadataTags']);
    if (root != null) {
      return root;
    }

    for (final nestedKey in const ['comicItem', 'comic', 'metadata']) {
      final nested = data[nestedKey];
      if (nested is Map) {
        final values = pick(nested, const ['tags', 'tagList', 'metadataTags']);
        if (values != null) {
          return values;
        }
      }
    }
  } catch (_) {}
  return const <String>[];
}

String? _favoriteTargetForDownloaded(DownloadedItem comic, String rawId) {
  final json = comic.toJson();
  String? nonEmpty(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  switch (comic.type) {
    case DownloadType.ehentai:
    case DownloadType.hitomi:
      return nonEmpty(json['link']) ?? rawId;
    case DownloadType.jm:
      return rawId.startsWith('jm') ? rawId.substring(2) : rawId;
    case DownloadType.htmanga:
      if (rawId.startsWith('Ht') || rawId.startsWith('ht')) {
        return rawId.substring(2);
      }
      return rawId;
    case DownloadType.nhentai:
      return rawId.startsWith('nhentai') ? rawId.substring(7) : rawId;
    case DownloadType.other:
    case DownloadType.copyManga:
    case DownloadType.komiic:
      return nonEmpty(json['comicId']) ?? rawId;
    case DownloadType.picacg:
    case DownloadType.favorite:
      return rawId;
  }
}

String _sourceKeyForDownloadType(DownloadType type) {
  switch (type) {
    case DownloadType.picacg:
      return 'picacg';
    case DownloadType.ehentai:
      return 'ehentai';
    case DownloadType.jm:
      return 'jm';
    case DownloadType.hitomi:
      return 'hitomi';
    case DownloadType.htmanga:
      return 'htmanga';
    case DownloadType.nhentai:
      return 'nhentai';
    case DownloadType.copyManga:
      return 'copy_manga';
    case DownloadType.komiic:
      return 'Komiic';
    case DownloadType.favorite:
      return 'local_album';
    case DownloadType.other:
      return 'other';
  }
}

FavoriteType _favoriteTypeForDownloadType(DownloadType type) {
  switch (type) {
    case DownloadType.picacg:
      return FavoriteType.picacg;
    case DownloadType.ehentai:
      return FavoriteType.ehentai;
    case DownloadType.jm:
      return FavoriteType.jm;
    case DownloadType.hitomi:
      return FavoriteType.hitomi;
    case DownloadType.htmanga:
      return FavoriteType.htManga;
    case DownloadType.nhentai:
      return FavoriteType.nhentai;
    case DownloadType.copyManga:
      return FavoriteType.copyManga;
    case DownloadType.komiic:
      return FavoriteType.komiic;
    case DownloadType.favorite:
    case DownloadType.other:
      return const FavoriteType(0);
  }
}

void _sortItems(List<LocalLibraryComicItem> items, String sortMode) {
  switch (normalizeLocalLibraryListSort(sortMode)) {
    case 'time_asc':
      items.sort((a, b) => (a.time ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(b.time ?? DateTime.fromMillisecondsSinceEpoch(0)));
      break;
    case 'name_asc':
      items.sort((a, b) => a.name.compareTo(b.name));
      break;
    case 'name_desc':
      items.sort((a, b) => b.name.compareTo(a.name));
      break;
    case 'size_asc':
      items.sort((a, b) => (a.comicSize ?? 0).compareTo(b.comicSize ?? 0));
      break;
    case 'size_desc':
      items.sort((a, b) => (b.comicSize ?? 0).compareTo(a.comicSize ?? 0));
      break;
    case 'time_desc':
    default:
      items.sort((a, b) => (b.time ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(a.time ?? DateTime.fromMillisecondsSinceEpoch(0)));
      break;
  }
}
