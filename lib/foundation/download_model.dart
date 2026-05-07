// ignore_for_file: prefer_const_constructors, avoid_unused_constructor_parameters, no_leading_underscores_for_local_identifiers

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import '../pages/reader/comic_reading_page.dart';
import 'def.dart';
import 'local_favorites.dart';

ComicType comicTypeForDownloadType(DownloadType type) {
  switch (type) {
    case DownloadType.picacg:
      return ComicType.picacg;
    case DownloadType.ehentai:
      return ComicType.ehentai;
    case DownloadType.jm:
      return ComicType.jm;
    case DownloadType.hitomi:
      return ComicType.hitomi;
    case DownloadType.htmanga:
      return ComicType.htManga;
    case DownloadType.nhentai:
      return ComicType.nhentai;
    case DownloadType.copyManga:
    case DownloadType.komiic:
    case DownloadType.other:
    case DownloadType.favorite:
      return ComicType.other;
  }
}

String downloadTypeDisplayName(DownloadType type) {
  switch (type) {
    case DownloadType.picacg:
      return '哔咔';
    case DownloadType.ehentai:
      return 'E-Hentai';
    case DownloadType.jm:
      return '禁漫';
    case DownloadType.hitomi:
      return 'Hitomi';
    case DownloadType.htmanga:
      return '绅士漫画';
    case DownloadType.nhentai:
      return 'NHentai';
    case DownloadType.copyManga:
      return '拷贝漫画';
    case DownloadType.komiic:
      return 'Komiic';
    case DownloadType.favorite:
      return '收藏';
    case DownloadType.other:
      return '其它';
  }
}

enum DownloadType {
  picacg,
  ehentai,
  jm,
  hitomi,
  htmanga,
  nhentai,
  copyManga,
  komiic,
  other,
  favorite;
}

abstract class DownloadedItem {
  DownloadType get type;

  String get name;

  List<String> get eps;

  List<int> get downloadedEps;

  String get id;

  String get subTitle;

  double? get comicSize;

  DateTime? time;

  List<String> get tags;

  Map<String, dynamic> toJson();

  set comicSize(double? value);

  String? directory;

  String get sourceDisplayName => downloadTypeDisplayName(type);

  String? get localCoverPath => null;

  String? get fileSystemPath => null;

  bool get canDelete => true;

  Widget createReadingPage({int? ep, int? page});
}

DownloadedItem? parseDownloadedItemRecordJson(
  String id,
  String rawJson, {
  DateTime? time,
  String? directory,
}) {
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) {
      return null;
    }
    return parseDownloadedItemRecordData(
      id,
      decoded.map((key, value) => MapEntry(key.toString(), value)),
      time: time,
      directory: directory,
    );
  } catch (_) {
    return null;
  }
}

DownloadedItem? parseDownloadedItemRecordData(
  String id,
  Map<String, dynamic> data, {
  DateTime? time,
  String? directory,
}) {
  final normalizedId = id.trim();
  DownloadedItem? comic;

  bool isPicacgLikeId(String value) {
    return RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(value.trim());
  }

  bool isNumericId(String value) {
    return RegExp(r'^\d+$').hasMatch(value.trim());
  }

  try {
    if (normalizedId.contains('-')) {
      comic = CustomDownloadedItem.fromJson(data);
    } else if (normalizedId.startsWith('jm')) {
      comic = DownloadedJmComic.fromMap(data);
    } else if (normalizedId.startsWith('hitomi')) {
      comic = DownloadedHitomiComic.fromMap(data);
    } else if (normalizedId.startsWith('nhentai')) {
      comic = NhentaiDownloadedComic.fromJson(data);
    } else if (normalizedId.startsWith('Ht')) {
      comic = DownloadedHtComic.fromJson(data);
    } else if (isNumericId(normalizedId)) {
      comic = DownloadedGallery.fromJson(data);
    } else {
      comic = isPicacgLikeId(normalizedId)
          ? DownloadedComic.fromJson(data)
          : ScannedDownloadedComic.fromJson(data);
    }
  } catch (_) {}

  comic ??= _parseDownloadedItemFallback(data);
  if (comic == null) {
    return null;
  }

  comic.time = time;
  comic.directory = directory;
  return comic;
}

DownloadedItem? _parseDownloadedItemFallback(Map<String, dynamic> data) {
  if (data.containsKey('comicItem')) {
    return DownloadedComic.fromJson(data);
  }
  if (data.containsKey('galleryTitle') || data.containsKey('gallery')) {
    return DownloadedGallery.fromJson(data);
  }
  if (data.containsKey('comicID')) {
    return NhentaiDownloadedComic.fromJson(data);
  }
  if (data.containsKey('sourceKey')) {
    return CustomDownloadedItem.fromJson(data);
  }
  return null;
}

class DownloadedComic extends DownloadedItem {
  String comicId;
  String title;
  String author;
  String description;
  String thumbUrl;
  List<String> chapters;
  List<int> downloadedChapters;
  double? size;
  List<String> tagList;

  DownloadedComic({
    required this.comicId,
    required this.title,
    required this.author,
    this.description = '',
    this.thumbUrl = '',
    required this.chapters,
    required this.downloadedChapters,
    this.size,
    this.tagList = const [],
  });

  @override
  Map<String, dynamic> toJson() => {
        "comicId": comicId,
        "title": title,
        "author": author,
        "description": description,
        "thumbUrl": thumbUrl,
        "chapters": chapters,
        "size": size,
        "downloadedChapters": downloadedChapters,
        "tagList": tagList,
      };

  DownloadedComic.fromJson(Map<String, dynamic> json)
      : comicId = json["comicId"] ?? json["comicItem"]?["id"] ?? '',
        title = json["title"] ?? json["comicItem"]?["title"] ?? '',
        author = json["author"] ?? json["comicItem"]?["author"] ?? '',
        description =
            json["description"] ?? json["comicItem"]?["description"] ?? '',
        thumbUrl = json["thumbUrl"] ?? json["comicItem"]?["thumbUrl"] ?? '',
        chapters = _parseChapters(json),
        size = json["size"]?.toDouble(),
        tagList = const [],
        downloadedChapters = [] {
    if (json["downloadedChapters"] != null) {
      downloadedChapters = List<int>.from(json["downloadedChapters"]);
    } else {
      for (int i = 0; i < chapters.length; i++) {
        downloadedChapters.add(i);
      }
    }
    tagList = _parseTagsList(json["tagList"] ?? json["comicItem"]?["tags"]);
  }

  static List<String> _parseChapters(Map<String, dynamic> json) {
    final rootChapters = json["chapters"];
    if (rootChapters is List) {
      return List<String>.from(rootChapters);
    }
    final comicItem = json["comicItem"];
    if (comicItem is Map) {
      final ciChapters = comicItem["chapters"];
      if (ciChapters is List) {
        return List<String>.from(ciChapters);
      }
      if (ciChapters is Map) {
        final entries = ciChapters.entries.toList()
          ..sort((a, b) => (int.tryParse(a.key.toString()) ?? 0)
              .compareTo(int.tryParse(b.key.toString()) ?? 0));
        return entries.map((e) {
          final v = e.value;
          if (v is Map) {
            return v["title"]?.toString() ??
                v["name"]?.toString() ??
                "Ch ${e.key}";
          }
          if (v is String) { return v; }
          return "Ch ${e.key}";
        }).toList();
      }
    }
    return [];
  }

  static List<String> _parseTagsList(dynamic tags) {
    if (tags == null) return [];
    if (tags is List) return tags.map((e) => e.toString()).toList();
    return [tags.toString()];
  }

  @override
  DownloadType get type => DownloadType.picacg;

  @override
  List<int> get downloadedEps => downloadedChapters;

  @override
  List<String> get eps => chapters.where((e) => e.isNotEmpty).toList();

  @override
  String get name => title;

  @override
  String get id => comicId;

  @override
  String get subTitle => author;

  @override
  double? get comicSize => size;

  @override
  set comicSize(double? value) => size = value;

  @override
  List<String> get tags => tagList;

  @override
  Widget createReadingPage({int? ep, int? page}) {
    var epsMap = <String, String>{};
    for (int i = 0; i < chapters.length; i++) {
      epsMap[(i + 1).toString()] = chapters[i];
    }
    var data = LocalReadingData(
      title: title,
      id: id,
      downloadId: id,
      sourceKey: 'picacg',
      hasEp: chapters.isNotEmpty,
      comicType: comicTypeForDownloadType(DownloadType.picacg),
      eps: epsMap,
      favoriteType: FavoriteType.picacg,
    );
    data.downloadedEps = downloadedChapters;
    return ComicReadingPage(data, page ?? 1, ep ?? 1);
  }
}

class ScannedDownloadedComic extends DownloadedComic {
  ScannedDownloadedComic({
    required super.comicId,
    required super.title,
    required super.author,
    super.description = '',
    super.thumbUrl = '',
    required super.chapters,
    required super.downloadedChapters,
    super.size,
    super.tagList = const [],
  });

  factory ScannedDownloadedComic.fromJson(Map<String, dynamic> json) {
    final chapters = DownloadedComic._parseChapters(json);
    final downloadedChapters = json["downloadedChapters"] != null
        ? List<int>.from(json["downloadedChapters"])
        : List<int>.generate(chapters.length, (index) => index);
    return ScannedDownloadedComic(
      comicId: json["comicId"] ?? json["comicItem"]?["id"] ?? '',
      title: json["title"] ?? json["comicItem"]?["title"] ?? '',
      author: json["author"] ?? json["comicItem"]?["author"] ?? '',
      description:
          json["description"] ?? json["comicItem"]?["description"] ?? '',
      thumbUrl: json["thumbUrl"] ?? json["comicItem"]?["thumbUrl"] ?? '',
      chapters: chapters,
      downloadedChapters: downloadedChapters,
      size: json["size"]?.toDouble(),
      tagList:
          DownloadedComic._parseTagsList(json["tagList"] ?? json["comicItem"]?["tags"]),
    );
  }

  @override
  DownloadType get type => DownloadType.other;

  @override
  String get sourceDisplayName => '本地扫描';

  @override
  Widget createReadingPage({int? ep, int? page}) {
    var epsMap = <String, String>{};
    for (int i = 0; i < chapters.length; i++) {
      epsMap[(i + 1).toString()] = chapters[i];
    }
    var data = LocalReadingData(
      title: title,
      id: id,
      downloadId: id,
      sourceKey: 'other',
      hasEp: chapters.isNotEmpty,
      comicType: comicTypeForDownloadType(DownloadType.other),
      eps: epsMap,
      favoriteType: const FavoriteType(0),
    );
    data.downloadedEps = downloadedChapters;
    return ComicReadingPage(data, page ?? 1, ep ?? 1);
  }
}

class DownloadedGallery extends DownloadedItem {
  String galleryTitle;
  String subtitle;
  String uploader;
  String link;
  String coverPath;
  double? size;
  List<String> tagList;

  DownloadedGallery({
    required this.galleryTitle,
    this.subtitle = '',
    this.uploader = '',
    required this.link,
    this.coverPath = '',
    this.size,
    this.tagList = const [],
  });

  @override
  Map<String, dynamic> toJson() => {
        "galleryTitle": galleryTitle,
        "subtitle": subtitle,
        "uploader": uploader,
        "link": link,
        "coverPath": coverPath,
        "size": size,
        "tagList": tagList,
      };

  factory DownloadedGallery.fromJson(Map<String, dynamic> json) {
    if (json.containsKey("gallery")) {
      final g = json["gallery"] as Map<String, dynamic>;
      return DownloadedGallery(
        galleryTitle: g["title"] ?? g["galleryTitle"] ?? '',
        subtitle: g["subTitle"] ?? g["subtitle"] ?? '',
        uploader: g["uploader"] ?? '',
        link: g["link"] ?? '',
        coverPath: g["cover"] ?? g["coverPath"] ?? '',
        size: json["size"]?.toDouble(),
        tagList: _parseTags(g["tags"]),
      );
    }
    return DownloadedGallery(
      galleryTitle: json["galleryTitle"] ?? '',
      subtitle: json["subtitle"] ?? '',
      uploader: json["uploader"] ?? '',
      link: json["link"] ?? '',
      coverPath: json["coverPath"] ?? '',
      size: json["size"]?.toDouble(),
      tagList: _parseTags(json["tags"]),
    );
  }

  static List<String> _parseTags(dynamic tags) {
    if (tags == null) return [];
    if (tags is List) return tags.map((e) => e.toString()).toList();
    if (tags is Map) {
      return tags.values.expand((v) {
        if (v is List) return v.map((e) => e.toString());
        return [v.toString()];
      }).toList();
    }
    return [];
  }

  @override
  DownloadType get type => DownloadType.ehentai;

  @override
  List<int> get downloadedEps => [0];

  @override
  List<String> get eps => ["EP 1"];

  @override
  String get name => subtitle.isNotEmpty ? subtitle : galleryTitle;

  @override
  String get id {
    var match = RegExp(r"/g/(\d+)/([a-z0-9]+)").firstMatch(link);
    if (match != null) {
      return "${match.group(1)}-${match.group(2)}";
    }
    return link;
  }

  @override
  String get subTitle => uploader;

  @override
  double? get comicSize => size;

  @override
  set comicSize(double? value) => size = value;

  @override
  List<String> get tags => tagList;

  @override
  Widget createReadingPage({int? ep, int? page}) {
    var data = LocalReadingData(
      title: name,
      id: id,
      downloadId: id,
      sourceKey: 'ehentai',
      hasEp: true,
      comicType: comicTypeForDownloadType(DownloadType.ehentai),
      eps: {"1": "EP 1"},
      favoriteType: FavoriteType.ehentai,
    );
    data.downloadedEps = [0];
    return ComicReadingPage(data, page ?? 1, ep ?? 1);
  }
}

class DownloadedJmComic extends DownloadedItem {
  String comicId;
  @override
  String name;
  String author;
  double? size;
  List<int> downloadedChapters;
  List<String> epNames;
  List<String> tagList;

  DownloadedJmComic({
    required this.comicId,
    required this.name,
    this.author = '',
    this.size,
    required this.downloadedChapters,
    this.epNames = const [],
    this.tagList = const [],
  });

  Map<String, dynamic> toMap() => {
        "comic": {
          "name": name,
          "id": comicId,
          "author": _buildAuthorList(author),
          "description": "",
          "likes": "",
          "views": "",
          "series": _buildSeriesMap(comicId, downloadedChapters, epNames),
          "tags": tagList,
          "works": const <String>[],
          "actors": const <String>[],
          "relatedComics": const <dynamic>[],
          "liked": "",
          "favorite": "",
          "epNames": epNames,
        },
        "size": size,
        "downloadedChapters": downloadedChapters,
      };

  DownloadedJmComic.fromMap(Map<String, dynamic> map)
      : comicId = map["comicId"] ?? map["comic"]?["id"] ?? '',
        name = map["name"] ?? map["comic"]?["name"] ?? '',
        author = _parseAuthor(map["author"] ?? map["comic"]?["author"]),
        size = map["size"]?.toDouble(),
        epNames = const [],
        tagList = const [],
        downloadedChapters = [] {
    if (map["downloadedChapters"] != null) {
      downloadedChapters = List<int>.from(map["downloadedChapters"]);
    }
    epNames =
        List<String>.from(map["epNames"] ?? map["comic"]?["epNames"] ?? []);
    tagList = List<String>.from(map["tagList"] ?? map["comic"]?["tags"] ?? []);
  }

  static List<String> _buildAuthorList(String author) {
    return author
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
  }

  static Map<String, String> _buildSeriesMap(
    String comicId,
    List<int> downloadedChapters,
    List<String> epNames,
  ) {
    int count = epNames.length;
    if (downloadedChapters.isNotEmpty) {
      final maxIndex = downloadedChapters.reduce((a, b) => a > b ? a : b) + 1;
      if (maxIndex > count) {
        count = maxIndex;
      }
    }
    if (count <= 0) {
      count = 1;
    }
    return {
      for (int i = 1; i <= count; i++) i.toString(): comicId,
    };
  }

  static String _parseAuthor(dynamic author) {
    if (author == null) return '';
    if (author is List) return author.join(", ");
    return author.toString();
  }

  @override
  DownloadType get type => DownloadType.jm;

  @override
  List<int> get downloadedEps => downloadedChapters;

  @override
  List<String> get eps => epNames.isEmpty
      ? List<String>.generate(
          downloadedChapters.isEmpty ? 1 : downloadedChapters.length,
          (index) => "第${index + 1}章")
      : epNames;

  @override
  String get id => "jm$comicId";

  @override
  String get subTitle => author;

  @override
  double? get comicSize => size;

  @override
  Map<String, dynamic> toJson() => toMap();

  @override
  set comicSize(double? value) => size = value;

  @override
  List<String> get tags => tagList;

  @override
  Widget createReadingPage({int? ep, int? page}) {
    var epsMap = <String, String>{};
    for (int i = 0; i < epNames.length; i++) {
      epsMap[(i + 1).toString()] = epNames[i];
    }
    if (epsMap.isEmpty) {
      for (int i = 0; i < downloadedChapters.length; i++) {
        epsMap[(i + 1).toString()] = "第${i + 1}章";
      }
    }
    var data = LocalReadingData(
      title: name,
      id: id,
      downloadId: id,
      sourceKey: 'jm',
      hasEp: epsMap.isNotEmpty,
      comicType: comicTypeForDownloadType(DownloadType.jm),
      eps: epsMap,
      favoriteType: FavoriteType.jm,
    );
    data.downloadedEps = downloadedChapters;
    return ComicReadingPage(data, page ?? 1, ep ?? 1);
  }
}

class DownloadedHitomiComic extends DownloadedItem {
  String comicId;
  @override
  String name;
  List<String> artists;
  List<String> tagList;
  double? size;
  String cover;
  String link;

  DownloadedHitomiComic({
    required this.comicId,
    required this.name,
    this.artists = const [],
    this.tagList = const [],
    this.size,
    this.cover = '',
    required this.link,
  });

  Map<String, dynamic> toMap() => {
        "comicId": comicId,
        "name": name,
        "artists": artists,
        "tagList": tagList,
        "size": size,
        "cover": cover,
        "link": link,
      };

  DownloadedHitomiComic.fromMap(Map<String, dynamic> map)
      : comicId = map["comicId"] ?? '',
        name = map["name"] ?? '',
        artists = List<String>.from(map["artists"] ?? []),
        tagList = List<String>.from(map["tagList"] ?? []),
        size = map["size"],
        cover = map["cover"] ?? '',
        link = map["link"] ?? '';

  @override
  double? get comicSize => size;

  @override
  List<int> get downloadedEps => [0];

  @override
  List<String> get eps => ["第一章"];

  @override
  String get id => "hitomi$comicId";

  @override
  String get subTitle => artists.isEmpty ? "未知" : artists.first;

  @override
  DownloadType get type => DownloadType.hitomi;

  @override
  Map<String, dynamic> toJson() => toMap();

  @override
  set comicSize(double? value) => size = value;

  @override
  List<String> get tags => tagList;

  @override
  Widget createReadingPage({int? ep, int? page}) {
    var data = LocalReadingData(
      title: name,
      id: id,
      downloadId: id,
      sourceKey: 'hitomi',
      hasEp: true,
      comicType: comicTypeForDownloadType(DownloadType.hitomi),
      eps: {"1": "第一章"},
      favoriteType: FavoriteType.hitomi,
    );
    data.downloadedEps = [0];
    return ComicReadingPage(data, page ?? 1, ep ?? 1);
  }
}

class DownloadedHtComic extends DownloadedItem {
  String comicId;
  @override
  String name;
  String uploader;
  String coverPath;
  double? size;
  List<String> tagList;

  DownloadedHtComic({
    required this.comicId,
    required this.name,
    this.uploader = '',
    this.coverPath = '',
    this.size,
    this.tagList = const [],
  });

  @override
  double? get comicSize => size;

  @override
  List<int> get downloadedEps => [0];

  @override
  List<String> get eps => ["EP 1"];

  @override
  String get id => "Ht$comicId";

  @override
  String get subTitle => uploader;

  @override
  DownloadType get type => DownloadType.htmanga;

  @override
  Map<String, dynamic> toJson() => {
        "comicId": comicId,
        "name": name,
        "uploader": uploader,
        "coverPath": coverPath,
        "size": size,
        "tagList": tagList,
      };

  DownloadedHtComic.fromJson(Map<String, dynamic> json)
      : comicId = json["comicId"] ?? json["comic"]?["id"] ?? '',
        name = json["name"] ?? json["comic"]?["name"] ?? '',
        uploader = json["uploader"] ?? json["comic"]?["uploader"] ?? '',
        coverPath = json["coverPath"] ?? json["comic"]?["coverPath"] ?? '',
        size = json["size"],
        tagList =
            List<String>.from(json["tagList"] ?? json["comic"]?["tags"] ?? []);

  @override
  set comicSize(double? value) => size = value;

  @override
  List<String> get tags => tagList;

  @override
  Widget createReadingPage({int? ep, int? page}) {
    var data = LocalReadingData(
      title: name,
      id: id,
      downloadId: id,
      sourceKey: 'htmanga',
      hasEp: true,
      comicType: comicTypeForDownloadType(DownloadType.htmanga),
      eps: {"1": "EP 1"},
      favoriteType: FavoriteType.htManga,
    );
    data.downloadedEps = [0];
    return ComicReadingPage(data, page ?? 1, ep ?? 1);
  }
}

class NhentaiDownloadedComic extends DownloadedItem {
  String get comicID => _comicID;
  final String _comicID;
  String get title => _title;
  final String _title;
  double? size;
  String cover;
  List<String> tagList;

  NhentaiDownloadedComic({
    required String comicID,
    required String title,
    this.size,
    this.cover = '',
    List<String>? tagList,
  })  : _comicID = comicID,
        _title = title,
        tagList = tagList ?? [];

  @override
  double? get comicSize => size;

  @override
  List<int> get downloadedEps => [0];

  @override
  List<String> get eps => ["第一章"];

  @override
  String get id => "nhentai$comicID";

  @override
  String get name => title;

  @override
  String get subTitle => "";

  @override
  DownloadType get type => DownloadType.nhentai;

  @override
  Map<String, dynamic> toJson() => {
        "comicID": comicID,
        "title": title,
        "size": size,
        "cover": cover,
        "tags": tagList,
      };

  factory NhentaiDownloadedComic.fromJson(Map<String, dynamic> json) {
    final comicTags = json["tags"];
    return NhentaiDownloadedComic(
      comicID: json["comicID"] ?? '',
      title: json["title"] ?? '',
      size: json["size"],
      tagList: comicTags != null ? List<String>.from(comicTags) : const [],
      cover: json["cover"] ?? '',
    );
  }

  @override
  set comicSize(double? value) => size = value;

  @override
  List<String> get tags => tagList;

  @override
  Widget createReadingPage({int? ep, int? page}) {
    var data = LocalReadingData(
      title: name,
      id: id,
      downloadId: id,
      sourceKey: 'nhentai',
      hasEp: true,
      comicType: comicTypeForDownloadType(DownloadType.nhentai),
      eps: {"1": "第一章"},
      favoriteType: FavoriteType.nhentai,
    );
    data.downloadedEps = [0];
    return ComicReadingPage(data, page ?? 1, ep ?? 1);
  }
}

class CustomDownloadedItem extends DownloadedItem {
  @override
  double? comicSize;

  @override
  final List<int> downloadedEps;

  final Map<String, String>? chapters;

  @override
  List<String> get eps => chapters?.values.toList() ?? ["EP 1"];

  final String comicId;

  @override
  final String id;

  @override
  final String name;

  @override
  final String subTitle;

  @override
  final List<String> tags;

  @override
  DownloadType get type => DownloadType.other;

  final String sourceKey;

  final String sourceName;

  final String cover;

  CustomDownloadedItem({
    this.comicSize,
    required this.downloadedEps,
    this.chapters,
    required this.id,
    required this.name,
    required this.subTitle,
    required this.tags,
    required this.sourceKey,
    required this.sourceName,
    required this.cover,
    required this.comicId,
  });

  @override
  String get sourceDisplayName => sourceName.isEmpty ? downloadTypeDisplayName(type) : sourceName;

  @override
  String? get localCoverPath {
    if (cover.isEmpty) {
      return null;
    }
    final file = File(cover);
    return file.existsSync() ? file.path : null;
  }

  @override
  Map<String, dynamic> toJson() => {
        "comicSize": comicSize,
        "downloadedEps": downloadedEps,
        "chapters": chapters,
        "id": id,
        "name": name,
        "subTitle": subTitle,
        "tags": tags,
        "sourceKey": sourceKey,
        "sourceName": sourceName,
        "cover": cover,
        "comicId": comicId,
      };

  CustomDownloadedItem.fromJson(Map<String, dynamic> json)
      : comicSize = json["comicSize"],
        downloadedEps = List<int>.from(json["downloadedEps"] ?? []),
        chapters = json["chapters"] != null
            ? Map<String, String>.from(json["chapters"])
            : null,
        id = json["id"] ?? '',
        name = json["name"] ?? '',
        subTitle = json["subTitle"] ?? '',
        tags = List<String>.from(json["tags"] ?? []),
        sourceKey = json["sourceKey"] ?? '',
        sourceName = json["sourceName"] ?? '',
        cover = json["cover"] ?? '',
        comicId = json["comicId"] ?? '';

  @override
  Widget createReadingPage({int? ep, int? page}) {
    var epsMap = <String, String>{};
    if (chapters != null) {
      epsMap.addAll(chapters!);
    } else {
      epsMap["1"] = "EP 1";
    }
    FavoriteType favType;
    if (sourceKey == 'copy_manga') {
      favType = FavoriteType.copyManga;
    } else if (sourceKey == 'Komiic') {
      favType = FavoriteType.komiic;
    } else {
      favType = const FavoriteType(0);
    }
    var data = LocalReadingData(
      title: name,
      id: id,
      downloadId: id,
      sourceKey: sourceKey,
      hasEp: epsMap.isNotEmpty,
      comicType: comicTypeForDownloadType(type),
      eps: epsMap,
      favoriteType: favType,
    );
    data.downloadedEps = downloadedEps;
    return ComicReadingPage(data, page ?? 1, ep ?? 1);
  }
}
