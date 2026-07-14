import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/jm_network/jm_models.dart';
import 'package:picakeep/network/nhentai_network/models.dart';
import 'package:picakeep/network/picacg_network/models.dart';
import 'package:picakeep/pages/local_comic_detail_page.dart';

LocalLibraryComicItem _localItem({
  required String itemId,
  required String originalId,
  DownloadType type = DownloadType.jm,
  String? sourceRowJson,
}) {
  return LocalLibraryComicItem(
    itemId: itemId,
    originalId: originalId,
    type: type,
    name: 'name',
    subTitle: '',
    tags: const [],
    sourceDisplayName: '',
    fileSystemPath: '',
    episodeFiles: const {},
    downloadedEps: const [0],
    eps: const ['第一章'],
    localCoverPath: null,
    localStorageExists: true,
    canDelete: false,
    aliases: const [],
    sourceRowJson: sourceRowJson,
  );
}

JmComicInfo _jmInfo({
  List<String> authors = const ['新作者'],
  List<String> works = const ['新作品'],
  List<String> actors = const ['新演员'],
  List<String> tags = const ['新标签'],
}) {
  return JmComicInfo(
    id: '1228705',
    title: 'title',
    authors: authors,
    description: '',
    likes: 0,
    views: 0,
    comments: 0,
    tags: tags,
    works: works,
    actors: actors,
    series: const {1: '1228705'},
    epNames: const ['第1章'],
    isFavourite: false,
    isLiked: false,
    coverUrl: '',
    relatedComics: const [],
  );
}

PicacgComicItem _picacgInfo({
  String author = '新作者',
  String chineseTeam = '新汉化组',
  List<String> categories = const ['新分类'],
  List<String> tags = const ['新标签'],
  String updatedAt = '2026-07-14T12:34:56Z',
}) {
  return PicacgComicItem(
    id: 'abc',
    title: 'title',
    author: author,
    likes: 0,
    path: '',
    tags: tags,
    creator: const PicacgProfile(
      id: '',
      avatarUrl: '',
      email: '',
      exp: 0,
      level: 0,
      name: '',
      title: '',
    ),
    detailDescription: '',
    chineseTeam: chineseTeam,
    categories: categories,
    comments: 0,
    isLiked: false,
    isFavourite: false,
    epsCount: 0,
    pagesCount: 0,
    updatedAt: updatedAt,
    eps: const [],
    recommendation: const [],
  );
}

NhentaiComic _nhentaiInfo({
  Map<String, List<String>> tags = const {
    'Parodies': ['新原作'],
    'Tags': ['新标签'],
  },
}) {
  return NhentaiComic(
    '123456',
    'title',
    'subtitle',
    'cover',
    tags,
    false,
    const [],
    const [],
    '',
  );
}

Gallery _ehInfo() {
  return Gallery(
    '在线标题',
    'type',
    '7 months ago',
    '新上传者',
    0,
    null,
    'online-cover',
    {
      'artist': ['新画师'],
      'language': ['english'],
    },
    const [],
    null,
    false,
    'https://e-hentai.org/g/220980/abc123def/',
    '99',
    20,
    const [],
    'jpg',
    100,
    'online subtitle',
  );
}

void main() {
  group('supportsUpdateInfo', () {
    test('jm/picacg/nhentai/ehentai are supported', () {
      expect(supportsUpdateInfo(DownloadType.jm), isTrue);
      expect(supportsUpdateInfo(DownloadType.picacg), isTrue);
      expect(supportsUpdateInfo(DownloadType.nhentai), isTrue);
      expect(supportsUpdateInfo(DownloadType.ehentai), isTrue);
    });

    test('other sources are not supported', () {
      expect(supportsUpdateInfo(DownloadType.hitomi), isFalse);
      expect(supportsUpdateInfo(DownloadType.htmanga), isFalse);
      expect(supportsUpdateInfo(DownloadType.copyManga), isFalse);
      expect(supportsUpdateInfo(DownloadType.komiic), isFalse);
      expect(supportsUpdateInfo(DownloadType.other), isFalse);
      expect(supportsUpdateInfo(DownloadType.favorite), isFalse);
    });
  });

  group('restoreConcreteDownloadedRecord', () {
    test('restores DownloadedJmComic from a valid sourceRowJson', () {
      final jm = DownloadedJmComic(
        comicId: '1228705',
        name: 'name',
        author: '旧作者',
        downloadedChapters: const [0],
        works: const ['旧作品'],
        actors: const ['旧演员'],
      );
      final item = _localItem(
        itemId: 'local_download::current_download::jm1228705',
        originalId: 'jm1228705',
        sourceRowJson: jsonEncode(jm.toMap()),
      );
      final restored = restoreConcreteDownloadedRecord(item);
      expect(restored, isA<DownloadedJmComic>());
      expect((restored as DownloadedJmComic).works, ['旧作品']);
      expect(restored.actors, ['旧演员']);
    });

    test('returns null for non-LocalLibraryComicItem sources', () {
      final comic = DownloadedJmComic(
        comicId: '1228705',
        name: 'name',
        downloadedChapters: const [0],
      );
      expect(restoreConcreteDownloadedRecord(comic), isNull);
    });

    test('returns null (not throw) when sourceRowJson is null', () {
      final item = _localItem(
        itemId: 'local_download::current_download::jm1228705',
        originalId: 'jm1228705',
        sourceRowJson: null,
      );
      expect(restoreConcreteDownloadedRecord(item), isNull);
    });

    test('returns null (not throw) when sourceRowJson is malformed', () {
      final item = _localItem(
        itemId: 'local_download::current_download::jm1228705',
        originalId: 'jm1228705',
        sourceRowJson: '{not valid json',
      );
      expect(restoreConcreteDownloadedRecord(item), isNull);
    });

    test('returns null (not throw) when sourceRowJson is empty string', () {
      final item = _localItem(
        itemId: 'local_download::current_download::jm1228705',
        originalId: 'jm1228705',
        sourceRowJson: '   ',
      );
      expect(restoreConcreteDownloadedRecord(item), isNull);
    });
  });

  group('buildUpdatedDownloadedRecord (整体覆盖契约)', () {
    test('jm: overwrites author/tags/works/actors, preserves id/eps/size', () {
      final existing = DownloadedJmComic(
        comicId: '1228705',
        name: '旧标题',
        author: '旧作者',
        size: 42.0,
        downloadedChapters: const [0, 1],
        epNames: const ['第1章', '第2章'],
        tagList: const ['旧标签'],
        works: const ['旧作品'],
        actors: const ['旧演员'],
      );
      final result = UpdateInfoFetchResult.jm(_jmInfo());
      final updated = buildUpdatedDownloadedRecord(existing, result);
      expect(updated, isA<DownloadedJmComic>());
      final jm = updated as DownloadedJmComic;
      // 整体覆盖：来源元数据标签字段用新值替换旧值。
      expect(jm.author, '新作者');
      expect(jm.tagList, ['新标签']);
      expect(jm.works, ['新作品']);
      expect(jm.actors, ['新演员']);
      // ID/结构性字段保持不变，不被在线数据覆盖。
      expect(jm.comicId, '1228705');
      expect(jm.size, 42.0);
      expect(jm.downloadedChapters, [0, 1]);
      expect(jm.epNames, ['第1章', '第2章']);
    });

    test('jm: overwrites even when new value is empty (no merge)', () {
      final existing = DownloadedJmComic(
        comicId: '1228705',
        name: '旧标题',
        author: '旧作者',
        downloadedChapters: const [0],
        works: const ['旧作品'],
        actors: const ['旧演员'],
      );
      final result = UpdateInfoFetchResult.jm(_jmInfo(
        authors: const [],
        works: const [],
        actors: const [],
      ));
      final updated =
          buildUpdatedDownloadedRecord(existing, result) as DownloadedJmComic;
      expect(updated.author, ''); // authors.join 空列表 -> ''
      expect(updated.works, isEmpty);
      expect(updated.actors, isEmpty);
    });

    test('picacg: overwrites author/tags/chineseTeam/categories, preserves id',
        () {
      final existing = DownloadedComic(
        comicId: 'abc123',
        title: '旧标题',
        author: '旧作者',
        description: '旧简介',
        chapters: const ['第1章'],
        downloadedChapters: const [0],
        size: 10.0,
        tagList: const ['旧标签'],
        chineseTeam: '旧汉化组',
        categories: const ['旧分类'],
      );
      final result = UpdateInfoFetchResult.picacg(_picacgInfo());
      final updated =
          buildUpdatedDownloadedRecord(existing, result) as DownloadedComic;
      expect(updated.author, '新作者');
      expect(updated.tagList, ['新标签']);
      expect(updated.chineseTeam, '新汉化组');
      expect(updated.categories, ['新分类']);
      expect(updated.sourceTime, '2026-07-14T12:34:56Z');
      // ID/结构性字段不变。
      expect(updated.comicId, 'abc123');
      expect(updated.size, 10.0);
      expect(updated.chapters, ['第1章']);
    });

    test('nhentai: replaces categorizedTags wholesale, preserves comicID/cover',
        () {
      final existing = NhentaiDownloadedComic(
        comicID: '123456',
        title: '旧标题',
        size: 5.0,
        cover: 'cover.jpg',
        tagList: const ['旧标签'],
        categorizedTags: const {
          'Parodies': ['旧原作'],
        },
      );
      final result = UpdateInfoFetchResult.nhentai(_nhentaiInfo());
      final updated = buildUpdatedDownloadedRecord(existing, result)
          as NhentaiDownloadedComic;
      expect(updated.categorizedTags, {
        'Parodies': ['新原作'],
        'Tags': ['新标签'],
      });
      // 拍扁后的 tagList 由新分类桶重新生成，不保留旧值。
      expect(updated.tagList, containsAll(['新原作', '新标签']));
      expect(updated.comicID, '123456');
      expect(updated.cover, 'cover.jpg');
      expect(updated.size, 5.0);
    });

    test(
        'ehentai: overwrites uploader/tags/source time and preserves local structure',
        () {
      final existing = DownloadedGallery(
        galleryTitle: '本地标题',
        subtitle: '本地副标题',
        uploader: '旧上传者',
        link: 'https://exhentai.org/g/220980/abc123def/',
        coverPath: 'local-cover',
        size: 12.5,
        tagList: const ['artist:旧画师'],
        sourceTime: 'old source time',
        pageCount: 12,
      );

      final updated = buildUpdatedDownloadedRecord(
        existing,
        UpdateInfoFetchResult.ehentai(_ehInfo()),
      ) as DownloadedGallery;

      expect(updated.uploader, '新上传者');
      expect(updated.tagList, ['artist:新画师', 'language:english']);
      expect(updated.sourceTime, '7 months ago');
      expect(updated.galleryTitle, '本地标题');
      expect(updated.subtitle, '本地副标题');
      expect(updated.link, 'https://exhentai.org/g/220980/abc123def/');
      expect(updated.coverPath, 'local-cover');
      expect(updated.size, 12.5);
      expect(updated.pageCount, 12);
    });

    test('returns null when existing type does not match fetch result type',
        () {
      final existing = DownloadedComic(
        comicId: 'abc123',
        title: 'title',
        author: 'author',
        chapters: const [],
        downloadedChapters: const [],
      );
      final result = UpdateInfoFetchResult.jm(_jmInfo());
      expect(buildUpdatedDownloadedRecord(existing, result), isNull);
    });
  });
}
