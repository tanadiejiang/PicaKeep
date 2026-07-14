import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_model.dart';

void main() {
  group('DownloadedJmComic works/actors', () {
    test('round trip through toMap/fromMap preserves works and actors', () {
      final comic = DownloadedJmComic(
        comicId: '1228705',
        name: 'test name',
        author: '作者A, 作者B',
        downloadedChapters: const [0, 1],
        epNames: const ['第1章', '第2章'],
        tagList: const ['tag1', 'tag2'],
        works: const ['原作A'],
        actors: const ['演员A', '演员B'],
      );
      final map = comic.toMap();
      // toMap 不再写死空列表常量，必须是真实字段值。
      expect(map['comic']['works'], const ['原作A']);
      expect(map['comic']['actors'], const ['演员A', '演员B']);

      final restored = DownloadedJmComic.fromMap(map);
      expect(restored.works, const ['原作A']);
      expect(restored.actors, const ['演员A', '演员B']);
      expect(restored.comicId, '1228705');
      expect(restored.name, 'test name');
      expect(restored.tagList, const ['tag1', 'tag2']);
    });

    test(
        'fromMap on legacy record missing works/actors keys defaults to empty '
        'lists without throwing', () {
      // 模拟旧版本落盘、不含 works/actors 键的历史 json（07号计划红线：
      // 旧记录必须能被新代码安全读取）。
      final legacyJson = jsonEncode({
        'comic': {
          'name': '旧记录',
          'id': '999',
          'author': ['旧作者'],
          'tags': ['旧标签'],
          'epNames': ['第1章'],
        },
        'size': 12.5,
        'downloadedChapters': [0],
      });
      final decoded = jsonDecode(legacyJson) as Map<String, dynamic>;

      DownloadedJmComic? restored;
      expect(
          () => restored = DownloadedJmComic.fromMap(decoded), returnsNormally);
      expect(restored!.works, isEmpty);
      expect(restored!.actors, isEmpty);
      expect(restored!.name, '旧记录');
      expect(restored!.tagList, const ['旧标签']);
    });

    test('parseDownloadedItemRecordJson safely parses legacy jm json', () {
      final legacyJson = jsonEncode({
        'comic': {
          'name': '旧记录2',
          'id': '888',
          'author': ['旧作者2'],
          'tags': <String>[],
          'epNames': ['第1章'],
        },
        'size': 1.0,
        'downloadedChapters': [0],
      });
      final parsed = parseDownloadedItemRecordJson('jm888', legacyJson);
      expect(parsed, isA<DownloadedJmComic>());
      final jm = parsed as DownloadedJmComic;
      expect(jm.works, isEmpty);
      expect(jm.actors, isEmpty);
    });
  });

  group('DownloadedComic chineseTeam/categories', () {
    test('round trip through toJson/fromJson preserves new fields', () {
      final comic = DownloadedComic(
        comicId: 'abc123',
        title: 'picacg title',
        author: 'picacg author',
        chapters: const ['ch1', 'ch2'],
        downloadedChapters: const [0, 1],
        tagList: const ['tagA'],
        chineseTeam: '汉化组X',
        categories: const ['分类1', '分类2'],
      );
      final json = comic.toJson();
      expect(json['chineseTeam'], '汉化组X');
      expect(json['categories'], const ['分类1', '分类2']);

      final restored = DownloadedComic.fromJson(json);
      expect(restored.chineseTeam, '汉化组X');
      expect(restored.categories, const ['分类1', '分类2']);
      expect(restored.title, 'picacg title');
    });

    test(
        'fromJson on legacy record missing chineseTeam/categories keys '
        'defaults to empty string/list without throwing', () {
      final legacyJson = jsonEncode({
        'comicId': 'legacy1',
        'title': '旧picacg记录',
        'author': '旧作者',
        'chapters': ['ch1'],
        'downloadedChapters': [0],
        'tagList': ['t1'],
      });
      final decoded = jsonDecode(legacyJson) as Map<String, dynamic>;

      DownloadedComic? restored;
      expect(
          () => restored = DownloadedComic.fromJson(decoded), returnsNormally);
      expect(restored!.chineseTeam, '');
      expect(restored!.categories, isEmpty);
      expect(restored!.title, '旧picacg记录');
    });
  });

  group('NhentaiDownloadedComic categorizedTags', () {
    test('round trip through toJson/fromJson preserves categorizedTags', () {
      final comic = NhentaiDownloadedComic(
        comicID: '123456',
        title: 'nhentai title',
        tagList: const ['flat1', 'flat2'],
        categorizedTags: const {
          'Parodies': ['原作X'],
          'Characters': ['角色A', '角色B'],
        },
      );
      final json = comic.toJson();
      expect(json['categorizedTags'], const {
        'Parodies': ['原作X'],
        'Characters': ['角色A', '角色B'],
      });

      final restored = NhentaiDownloadedComic.fromJson(json);
      expect(restored.categorizedTags, const {
        'Parodies': ['原作X'],
        'Characters': ['角色A', '角色B'],
      });
      // 现有 tagList 保留、未被删除（其他代码路径可能依赖扁平标签）。
      expect(restored.tagList, const ['flat1', 'flat2']);
    });

    test(
        'fromJson on legacy record missing categorizedTags key defaults to '
        'empty map without throwing', () {
      final legacyJson = jsonEncode({
        'comicID': '999999',
        'title': '旧nhentai记录',
        'size': 5.0,
        'cover': '',
        'tags': ['旧标签1', '旧标签2'],
      });
      final decoded = jsonDecode(legacyJson) as Map<String, dynamic>;

      NhentaiDownloadedComic? restored;
      expect(() => restored = NhentaiDownloadedComic.fromJson(decoded),
          returnsNormally);
      expect(restored!.categorizedTags, isEmpty);
      expect(restored!.tagList, const ['旧标签1', '旧标签2']);
      expect(restored!.title, '旧nhentai记录');
    });

    test('parseDownloadedItemRecordJson safely parses legacy nhentai json', () {
      final legacyJson = jsonEncode({
        'comicID': '777777',
        'title': '旧nhentai记录2',
        'tags': <String>[],
      });
      final parsed = parseDownloadedItemRecordJson('nhentai777777', legacyJson);
      expect(parsed, isA<NhentaiDownloadedComic>());
      final nh = parsed as NhentaiDownloadedComic;
      expect(nh.categorizedTags, isEmpty);
    });
  });

  group('DownloadedGallery tagList compatibility', () {
    test('toJson/fromJson 与公开记录解析都保留新 tagList 键', () {
      final gallery = DownloadedGallery(
        galleryTitle: 'EH tags',
        link: 'https://e-hentai.org/g/220980/abc123def/',
        size: 12.5,
        tagList: const ['female:fox girl', 'parody:azur lane'],
        pageCount: 20,
      );
      final data = gallery.toJson();

      final restored = DownloadedGallery.fromJson(data);
      expect(restored.tagList, const ['female:fox girl', 'parody:azur lane']);

      final parsed = parseDownloadedItemRecordJson(
        '220980-abc123def',
        jsonEncode(data),
      );
      expect(parsed, isA<DownloadedGallery>());
      expect(parsed!.tags, const ['female:fox girl', 'parody:azur lane']);
    });

    test('平铺旧 tags 键仍可读，且新 tagList 键优先', () {
      final restored = DownloadedGallery.fromJson({
        'galleryTitle': 'EH legacy tags',
        'link': 'https://e-hentai.org/g/220981/def456abc/',
        'size': 8.0,
        'tagList': ['female:fox girl'],
        'tags': ['legacy-only-tag'],
      });

      expect(restored.tagList, const ['female:fox girl']);

      final legacy = DownloadedGallery.fromJson({
        'galleryTitle': 'EH old flat tags',
        'link': 'https://e-hentai.org/g/220982/abc456def/',
        'size': 8.0,
        'tags': ['parody:azur lane'],
      });
      expect(legacy.tagList, const ['parody:azur lane']);
    });
  });
}
