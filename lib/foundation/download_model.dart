// ignore_for_file: prefer_const_constructors, avoid_unused_constructor_parameters, no_leading_underscores_for_local_identifiers

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';
import 'package:picakeep/foundation/def.dart';
import 'package:picakeep/foundation/local_favorites.dart';

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

  // ehentai 画廊 id 形如 '123-abc'（getGalleryId(link)，含连字符），必须在
  // 下面 contains('-') → CustomDownloadedItem 分支之前精准拦截，否则
  // ehentai 已下载条目会被误判为自定义源条目，导致本地无法解析回 DownloadedGallery。
  bool isEhentaiGalleryId(String value) {
    return RegExp(r'^\d+-[a-z0-9]+$').hasMatch(value.trim());
  }

  try {
    if (isEhentaiGalleryId(normalizedId) &&
        (data.containsKey('galleryTitle') || data.containsKey('gallery'))) {
      comic = DownloadedGallery.fromJson(data);
    } else if (normalizedId.contains('-')) {
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
  // 汉化组 / 分类：仅 picacg 来源元数据标签，07号计划"更新信息"覆盖目标。
  // 旧记录（升级前写入的 json）不含这两个键，fromJson 必须安全兜底为空
  // 字符串/空列表，不能因为键缺失而抛异常（详情见类顶注释与07号计划回写记录）。
  String chineseTeam;
  List<String> categories;

  /// 来源站最近更新时间。下载时间仍由 [DownloadedItem.time] 承载，不能混用。
  /// 旧 download.db 记录没有此键时保留空字符串。
  String sourceTime;

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
    this.chineseTeam = '',
    this.categories = const [],
    this.sourceTime = '',
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
        "chineseTeam": chineseTeam,
        "categories": categories,
        "sourceTime": sourceTime,
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
        chineseTeam =
            (json["chineseTeam"] ?? json["comicItem"]?["chineseTeam"] ?? '')
                .toString(),
        categories = const [],
        sourceTime =
            (json["sourceTime"] ?? json["comicItem"]?["sourceTime"] ?? '')
                .toString(),
        downloadedChapters = [] {
    if (json["downloadedChapters"] != null) {
      downloadedChapters = List<int>.from(json["downloadedChapters"]);
    } else {
      for (int i = 0; i < chapters.length; i++) {
        downloadedChapters.add(i);
      }
    }
    tagList = _parseTagsList(json["tagList"] ?? json["comicItem"]?["tags"]);
    categories =
        _parseTagsList(json["categories"] ?? json["comicItem"]?["categories"]);
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
          if (v is String) {
            return v;
          }
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
      tagList: DownloadedComic._parseTagsList(
          json["tagList"] ?? json["comicItem"]?["tags"]),
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

  /// 来源站显示的上传/更新时间。旧记录缺失时为空，不使用本地下载时间回填。
  String sourceTime;

  /// 真实页数（ehentai 单画廊多图、无章节）。页图平铺在下载目录根，
  /// 文件名为 1.{ext}…pageCount.{ext}。旧数据缺该键时回退 1（向后兼容）。
  int pageCount;

  DownloadedGallery({
    required this.galleryTitle,
    this.subtitle = '',
    this.uploader = '',
    required this.link,
    this.coverPath = '',
    this.size,
    this.tagList = const [],
    this.sourceTime = '',
    this.pageCount = 1,
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
        "sourceTime": sourceTime,
        "pageCount": pageCount,
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
        size: _parseSize(json["size"] ?? g["size"]),
        tagList: _parseTags(g["tagList"] ?? g["tags"]),
        sourceTime: (json["sourceTime"] ?? g["sourceTime"] ?? '').toString(),
        pageCount: _parsePageCount(json["pageCount"] ?? g["maxPage"]),
      );
    }
    return DownloadedGallery(
      galleryTitle: json["galleryTitle"] ?? '',
      subtitle: json["subtitle"] ?? '',
      uploader: json["uploader"] ?? '',
      link: json["link"] ?? '',
      coverPath: json["coverPath"] ?? '',
      size: _parseSize(json["size"]),
      tagList: _parseTags(json["tagList"] ?? json["tags"]),
      sourceTime: (json["sourceTime"] ?? '').toString(),
      pageCount: _parsePageCount(json["pageCount"]),
    );
  }

  /// 兼容历史 download.db 中字符串化的 MB 大小；坏值保留为未知大小。
  static double? _parseSize(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().trim() ?? '');
  }

  /// 安全解析页数：支持 int / String / null（旧数据），下限 1。
  static int _parsePageCount(dynamic value) {
    if (value is int) return value > 0 ? value : 1;
    final parsed = int.tryParse(value?.toString() ?? '');
    return (parsed != null && parsed > 0) ? parsed : 1;
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

  /// 无章节：始终单一逻辑章（index 0）已下载。
  @override
  List<int> get downloadedEps => [0];

  /// 无章节：单逻辑章。真实页数由 [pageCount] 表达，不靠 eps 数量。
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
      hasEp: false,
      comicType: comicTypeForDownloadType(DownloadType.ehentai),
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
  // 07号计划新增：作品/演员，用于"更新信息"整体覆盖来源元数据标签。
  // 旧记录没有这两个键时 fromMap 默认空列表，不抛异常（见下方 fromMap）。
  List<String> works;
  List<String> actors;

  DownloadedJmComic({
    required this.comicId,
    required this.name,
    this.author = '',
    this.size,
    required this.downloadedChapters,
    this.epNames = const [],
    this.tagList = const [],
    this.works = const [],
    this.actors = const [],
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
          "works": works,
          "actors": actors,
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
        works = const [],
        actors = const [],
        downloadedChapters = [] {
    if (map["downloadedChapters"] != null) {
      downloadedChapters = List<int>.from(map["downloadedChapters"]);
    }
    epNames =
        List<String>.from(map["epNames"] ?? map["comic"]?["epNames"] ?? []);
    tagList = List<String>.from(map["tagList"] ?? map["comic"]?["tags"] ?? []);
    works = List<String>.from(map["works"] ?? map["comic"]?["works"] ?? []);
    actors = List<String>.from(map["actors"] ?? map["comic"]?["actors"] ?? []);
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
  // 07号计划新增：保留在线接口返回的分类桶结构（原作/角色/团队/语言/分类等），
  // 现有 tagList 是拍扁后的单一列表，丢失分类信息，故新增此字段而不是改造 tagList
  // （tagList 可能被其他代码路径依赖做扁平标签展示/搜索匹配，保留不删）。
  // 旧记录没有这个键时 fromJson 默认空 Map，不抛异常。
  Map<String, List<String>> categorizedTags;

  NhentaiDownloadedComic({
    required String comicID,
    required String title,
    this.size,
    this.cover = '',
    List<String>? tagList,
    Map<String, List<String>>? categorizedTags,
  })  : _comicID = comicID,
        _title = title,
        tagList = tagList ?? [],
        categorizedTags = categorizedTags ?? {};

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
        "categorizedTags": categorizedTags,
      };

  factory NhentaiDownloadedComic.fromJson(Map<String, dynamic> json) {
    final comicTags = json["tags"];
    final rawCategorized = json["categorizedTags"];
    Map<String, List<String>> parsedCategorized = const {};
    if (rawCategorized is Map) {
      parsedCategorized = rawCategorized.map((key, value) {
        final values = value is List
            ? value.map((e) => e.toString()).toList()
            : <String>[];
        return MapEntry(key.toString(), values);
      });
    }
    return NhentaiDownloadedComic(
      comicID: json["comicID"] ?? '',
      title: json["title"] ?? '',
      size: json["size"],
      tagList: comicTags != null ? List<String>.from(comicTags) : const [],
      cover: json["cover"] ?? '',
      categorizedTags: parsedCategorized,
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
  String get sourceDisplayName =>
      sourceName.isEmpty ? downloadTypeDisplayName(type) : sourceName;

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
