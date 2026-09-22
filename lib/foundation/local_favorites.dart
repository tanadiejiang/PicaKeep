// ignore_for_file: no_leading_underscores_for_local_identifiers

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:sqlite3/sqlite3.dart';

part 'local_favorites_folders.dart';
part 'local_favorites_comics.dart';
part 'local_favorites_query.dart';
part 'local_favorites_db.dart';

String getCurTime() {
  return DateTime.now()
      .toIso8601String()
      .replaceFirst("T", " ")
      .substring(0, 19);
}

const _legacyCustomFavoriteSourceKeys = <String>[
  'copy_manga',
  'Komiic',
  'ikmmh',
  'baozi',
];

String? _extractEhGalleryId(String target) {
  final index = target.indexOf('/g/');
  if (index == -1) return null;
  final start = index + 3;
  final end = target.indexOf('/', start);
  if (end == -1) return null;
  final id = target.substring(start, end).trim();
  return id.isEmpty ? null : id;
}

String? _extractHitomiId(String target) {
  final htmlMatch = RegExp(r'(\d+)(?=\.html(?:$|\?))').firstMatch(target);
  if (htmlMatch != null) {
    return htmlMatch.group(1);
  }
  final digitsOnly = RegExp(r'^\d+$').firstMatch(target.trim());
  return digitsOnly?.group(0);
}

String? _preferredCustomFavoriteSourceKey(int type) {
  final mapping = <int, String>{
    7: 'copy_manga',
    8: 'Komiic',
    'copy_manga'.hashCode: 'copy_manga',
    'Komiic'.hashCode: 'Komiic',
    'ikmmh'.hashCode: 'ikmmh',
    'baozi'.hashCode: 'baozi',
  };
  return mapping[type];
}

int? _legacyBuiltInFavoriteTypeForSourceKey(String sourceKey) {
  return switch (sourceKey) {
    'copy_manga' => 7,
    'Komiic' => 8,
    _ => null,
  };
}

Set<int> _equivalentFavoriteTypeKeys(int type) {
  final keys = <int>{type};
  final sourceKey = _preferredCustomFavoriteSourceKey(type);
  if (sourceKey != null) {
    keys.add(sourceKey.hashCode);
    final legacyKey = _legacyBuiltInFavoriteTypeForSourceKey(sourceKey);
    if (legacyKey != null) {
      keys.add(legacyKey);
    }
  }
  return keys;
}

String _canonicalFavoriteTypeIdentity(int type) {
  final sourceKey = _preferredCustomFavoriteSourceKey(type);
  if (sourceKey != null) {
    return 'custom:$sourceKey';
  }
  return 'type:$type';
}

int _preferredStorageTypeKey(int type) {
  final sourceKey = _preferredCustomFavoriteSourceKey(type);
  return sourceKey?.hashCode ?? type;
}

String? _favoriteSourceDisplayName(int type) {
  const builtInNames = <int, String>{
    7: '拷贝漫画',
    8: 'Komiic',
  };
  if (builtInNames.containsKey(type)) {
    return builtInNames[type];
  }
  final sourceKey = _preferredCustomFavoriteSourceKey(type);
  return switch (sourceKey) {
    'copy_manga' => '拷贝漫画',
    'Komiic' => 'Komiic',
    'ikmmh' => '爱看漫',
    'baozi' => '包子漫画',
    _ => null,
  };
}

void _addCandidate(Set<String> candidates, String value) {
  final v = value.trim();
  if (v.isNotEmpty) {
    candidates.add(v);
  }
}

void _addCustomFavoriteCandidates(Set<String> candidates, String target,
    [String? preferredSourceKey]) {
  if (preferredSourceKey != null && preferredSourceKey.isNotEmpty) {
    _addCandidate(candidates, '$preferredSourceKey-$target');
  }
  for (final key in _legacyCustomFavoriteSourceKeys) {
    _addCandidate(candidates, '$key-$target');
  }
}

List<String> _buildFavoriteDownloadIdCandidates(String target, int type) {
  final candidates = <String>{};
  _addCandidate(candidates, target);

  switch (type) {
    case 1:
      final ehId = _extractEhGalleryId(target);
      if (ehId != null) {
        _addCandidate(candidates, ehId);
      }
      break;
    case 2:
      _addCandidate(candidates, target.startsWith('jm') ? target : 'jm$target');
      break;
    case 3:
      final hitomiId = _extractHitomiId(target);
      if (target.startsWith('hitomi')) {
        _addCandidate(candidates, target);
      } else if (hitomiId != null) {
        _addCandidate(candidates, 'hitomi$hitomiId');
      }
      break;
    case 4:
      if (target.startsWith('Ht') || target.startsWith('ht')) {
        final suffix = target.substring(2);
        _addCandidate(candidates, 'Ht$suffix');
        _addCandidate(candidates, 'ht$suffix');
      } else {
        _addCandidate(candidates, 'Ht$target');
        _addCandidate(candidates, 'ht$target');
      }
      break;
    case 6:
      _addCandidate(
          candidates, target.startsWith('nhentai') ? target : 'nhentai$target');
      break;
    default:
      _addCustomFavoriteCandidates(
          candidates, target, _preferredCustomFavoriteSourceKey(type));
      break;
  }

  return candidates.toList();
}

final class FavoriteType {
  final int key;

  const FavoriteType(this.key);

  static FavoriteType get picacg => const FavoriteType(0);
  static FavoriteType get ehentai => const FavoriteType(1);
  static FavoriteType get jm => const FavoriteType(2);
  static FavoriteType get hitomi => const FavoriteType(3);
  static FavoriteType get htManga => const FavoriteType(4);
  static FavoriteType get nhentai => const FavoriteType(6);
  static FavoriteType get copyManga => const FavoriteType(7);
  static FavoriteType get komiic => const FavoriteType(8);

  String get name {
    const nameMap = {
      0: "Picacg",
      1: "E-Hentai",
      2: "禁漫",
      3: "Hitomi",
      4: "绅士漫画",
      6: "NHentai",
      7: "拷贝漫画",
      8: "Komiic",
    };
    return nameMap[key] ?? _favoriteSourceDisplayName(key) ?? "Other";
  }

  @override
  bool operator ==(Object other) => other is FavoriteType && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

class FavoriteItem {
  String name;
  String author;
  FavoriteType type;
  List<String> tags;
  String target;
  String coverPath;
  String time = getCurTime();

  FavoriteItem({
    required this.target,
    required this.name,
    required this.coverPath,
    required this.author,
    required this.type,
    required this.tags,
  });

  factory FavoriteItem.fromDownloadedItem(
    DownloadedItem comic, {
    required String coverPath,
  }) {
    final json = comic.toJson();
    final explicitFavoriteTarget = json['favoriteTarget']?.toString().trim();
    var target =
        explicitFavoriteTarget != null && explicitFavoriteTarget.isNotEmpty
            ? explicitFavoriteTarget
            : comic.id;
    var type = FavoriteType.picacg;
    switch (comic.type) {
      case DownloadType.picacg:
        target =
            explicitFavoriteTarget != null && explicitFavoriteTarget.isNotEmpty
                ? explicitFavoriteTarget
                : _stripLocalDownloadPrefix(comic.id);
        type = FavoriteType.picacg;
        break;
      case DownloadType.ehentai:
        final link = json['link']?.toString().trim();
        target =
            explicitFavoriteTarget != null && explicitFavoriteTarget.isNotEmpty
                ? explicitFavoriteTarget
                : link != null && link.isNotEmpty
                    ? link
                    : _stripLocalDownloadPrefix(comic.id);
        type = FavoriteType.ehentai;
        break;
      case DownloadType.jm:
        target =
            explicitFavoriteTarget != null && explicitFavoriteTarget.isNotEmpty
                ? explicitFavoriteTarget
                : _stripKnownPrefix(_stripLocalDownloadPrefix(comic.id), 'jm');
        type = FavoriteType.jm;
        break;
      case DownloadType.hitomi:
        final link = json['link']?.toString().trim();
        target =
            explicitFavoriteTarget != null && explicitFavoriteTarget.isNotEmpty
                ? explicitFavoriteTarget
                : link != null && link.isNotEmpty
                    ? link
                    : _stripKnownPrefix(
                        _stripLocalDownloadPrefix(comic.id), 'hitomi');
        type = FavoriteType.hitomi;
        break;
      case DownloadType.htmanga:
        target =
            explicitFavoriteTarget != null && explicitFavoriteTarget.isNotEmpty
                ? explicitFavoriteTarget
                : _stripKnownPrefix(_stripLocalDownloadPrefix(comic.id), 'Ht');
        target = _stripKnownPrefix(target, 'ht');
        type = FavoriteType.htManga;
        break;
      case DownloadType.nhentai:
        target = explicitFavoriteTarget != null &&
                explicitFavoriteTarget.isNotEmpty
            ? explicitFavoriteTarget
            : _stripKnownPrefix(_stripLocalDownloadPrefix(comic.id), 'nhentai');
        type = FavoriteType.nhentai;
        break;
      case DownloadType.copyManga:
        target = _customFavoriteTarget(comic);
        type = FavoriteType.copyManga;
        break;
      case DownloadType.komiic:
        target = _customFavoriteTarget(comic);
        type = FavoriteType.komiic;
        break;
      case DownloadType.other:
      case DownloadType.favorite:
        target = _customFavoriteTarget(comic);
        type = _customFavoriteType(comic);
        break;
    }
    return FavoriteItem(
      target: target,
      name: comic.name,
      coverPath: coverPath,
      author: resolveDownloadedAuthors(comic).join(', '),
      type: type,
      tags: comic.tags,
    );
  }

  static String _stripLocalDownloadPrefix(String id) {
    const marker = '::';
    if (!id.startsWith('local_download::')) {
      return id;
    }
    final index = id.lastIndexOf(marker);
    return index == -1 ? id : id.substring(index + marker.length);
  }

  static String _stripKnownPrefix(String value, String prefix) {
    return value.startsWith(prefix) ? value.substring(prefix.length) : value;
  }

  static String _customFavoriteTarget(DownloadedItem comic) {
    if (comic is CustomDownloadedItem && comic.comicId.trim().isNotEmpty) {
      return comic.comicId.trim();
    }
    final json = comic.toJson();
    final comicId = json['comicId']?.toString().trim();
    if (comicId != null && comicId.isNotEmpty) {
      return comicId;
    }
    return _stripLocalDownloadPrefix(comic.id);
  }

  static FavoriteType _customFavoriteType(DownloadedItem comic) {
    if (comic is CustomDownloadedItem && comic.sourceKey.trim().isNotEmpty) {
      return FavoriteType(comic.sourceKey.hashCode);
    }
    return const FavoriteType(0);
  }

  /// Convert favorite target to download DB ID.
  /// The first candidate is the preferred local download ID; callers that need
  /// robust compatibility should use [candidateDownloadIds].
  String toDownloadId() {
    return candidateDownloadIds().first;
  }

  List<String> candidateDownloadIds() =>
      _buildFavoriteDownloadIdCandidates(target, type.key);

  Map<String, dynamic> toJson() => {
        "name": name,
        "author": author,
        "type": type.key,
        "tags": tags,
        "target": target,
        "coverPath": coverPath,
        "time": time
      };

  FavoriteItem.fromJson(Map<String, dynamic> json)
      : name = json["name"],
        author = json["author"],
        type = FavoriteType(json["type"]),
        tags = List<String>.from(json["tags"]),
        target = json["target"],
        coverPath = json["coverPath"],
        time = json["time"];

  FavoriteItem.fromRow(Row row)
      : name = row["name"],
        author = row["author"],
        type = FavoriteType(row["type"]),
        tags = (row["tags"] as String).split(","),
        target = row["target"],
        coverPath = row["cover_path"],
        time = row["time"] {
    tags.remove("");
  }

  @override
  bool operator ==(Object other) {
    return other is FavoriteItem &&
        other.target == target &&
        other.type == type;
  }

  @override
  int get hashCode => target.hashCode ^ type.hashCode;
}

class FavGroup {
  final String name;
  int order;

  FavGroup(this.name, {this.order = 0});

  @override
  bool operator ==(Object other) => other is FavGroup && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

class FavoriteItemWithFolderInfo {
  FavoriteItem comic;
  String folder;

  FavoriteItemWithFolderInfo(this.comic, this.folder);

  @override
  bool operator ==(Object other) {
    return other is FavoriteItemWithFolderInfo &&
        other.comic == comic &&
        other.folder == folder;
  }

  @override
  int get hashCode => comic.hashCode ^ folder.hashCode;
}

class _FolderRecord {
  const _FolderRecord({required this.folderName, required this.tableName});

  final String folderName;
  final String tableName;
}

enum FavoriteFolderCreateTarget {
  current,
  original,
}

enum LocalFavoriteAddStatus { added, alreadyPresent, failed }

class LocalFavoriteRelationResult {
  const LocalFavoriteRelationResult(
      this.folder, this.target, this.type, this.status,
      {this.error});
  final String folder;
  final String target;
  final FavoriteType type;
  final LocalFavoriteAddStatus status;
  final String? error;
  (String, String) get comicIdentity =>
      (target, _canonicalFavoriteTypeIdentity(type.key));
}

class LocalFavoriteBatchResult {
  LocalFavoriteBatchResult(
    Iterable<LocalFavoriteRelationResult> relations, {
    Iterable<String> createdFolders = const [],
    Map<String, String> folderCreationFailures = const {},
  })  : relations = List.unmodifiable(relations),
        createdFolders = List.unmodifiable(createdFolders),
        folderCreationFailures = Map.unmodifiable(folderCreationFailures);

  final List<LocalFavoriteRelationResult> relations;
  final List<String> createdFolders;
  final Map<String, String> folderCreationFailures;
  int _count(LocalFavoriteAddStatus status) =>
      relations.where((r) => r.status == status).length;
  int get addedRelations => _count(LocalFavoriteAddStatus.added);
  int get alreadyPresentRelations =>
      _count(LocalFavoriteAddStatus.alreadyPresent);
  int get failedRelations => _count(LocalFavoriteAddStatus.failed);
  int get addedComics => relations
      .where((r) => r.status == LocalFavoriteAddStatus.added)
      .map((r) => r.comicIdentity)
      .toSet()
      .length;
  int get totalComics => relations.map((r) => r.comicIdentity).toSet().length;
  int get completedComics {
    final failed = relations
        .where((r) => r.status == LocalFavoriteAddStatus.failed)
        .map((r) => r.comicIdentity)
        .toSet();
    return totalComics - failed.length;
  }

  int get folderCount => relations.map((r) => r.folder).toSet().length;
  bool get allCompleted =>
      relations.isNotEmpty &&
      failedRelations == 0 &&
      folderCreationFailures.isEmpty;
}

class LocalFavoritesManager {
  factory LocalFavoritesManager() =>
      cache ?? (cache = LocalFavoritesManager._create());

  LocalFavoritesManager._create();

  static LocalFavoritesManager? cache;

  late Database _db;
  Database? _secondaryDb;
  late String _dbPath;

  final _foldersController = StreamController<List<FavGroup>>.broadcast();
  final _cachedFavoritedTargets = <String, bool>{};
  final _cachedFavoritedComics = <(String, String)>{};
  bool _favoritedTargetsDirty = true;
  int _storageGeneration = 0;
  bool _storageReady = false;

  /// [dataRoots] allows isolated stores in tests; normal callers use configured roots.
  Future<void> init({List<String>? dataRoots}) async {
    _storageGeneration++;
    _storageReady = false;
    _favoritedTargetsDirty = true;
    _cachedFavoritedTargets.clear();
    _cachedFavoritedComics.clear();
    final roots = dataRoots ?? await getManagedDataRoots();
    final primaryPath = managedDataFilePath(roots.first, 'local_favorite.db');
    File(primaryPath).parent.createSync(recursive: true);

    Database? previousDb;
    try {
      previousDb = _db;
    } catch (_) {}
    final previousSecondaryDb = _secondaryDb;

    final nextDb = sqlite3.open(primaryPath);
    _checkAndCreate(nextDb);

    _dbPath = primaryPath;
    _db = nextDb;
    _secondaryDb = null;
    await readData();

    Database? nextSecondaryDb;
    if (roots.length > 1) {
      final secondaryPath = managedDataFilePath(roots[1], 'local_favorite.db');
      final secondaryFile = File(secondaryPath);
      if (secondaryFile.existsSync()) {
        final openedSecondaryDb = sqlite3.open(secondaryPath);
        _checkAndCreate(openedSecondaryDb);
        nextSecondaryDb = openedSecondaryDb;
      }
    }
    _secondaryDb = nextSecondaryDb;
    _storageReady = true;
    _emitFolders();

    if (!identical(previousDb, nextDb)) {
      try {
        previousDb?.dispose();
      } catch (_) {}
    }
    if (!identical(previousSecondaryDb, nextSecondaryDb)) {
      try {
        previousSecondaryDb?.dispose();
      } catch (_) {}
    }
  }

  void dispose() {
    _storageGeneration++;
    _storageReady = false;
    _favoritedTargetsDirty = true;
    _cachedFavoritedTargets.clear();
    _cachedFavoritedComics.clear();
    try {
      _db.dispose();
    } catch (_) {}
    try {
      _secondaryDb?.dispose();
    } catch (_) {}
    _secondaryDb = null;
  }
}
