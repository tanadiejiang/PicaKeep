import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_result_item.dart';
import 'package:picakeep/network/soutubot_network/soutubot_models.dart';

void main() {
  Map<String, Object?> sampleResponse() => {
        'data': [
          {
            'source': 'nhentai',
            'page': 3,
            'title': 'Sample NH Comic',
            'language': 'cn',
            'pagePath': '/g/480041/3/',
            'subjectPath': '/g/480041',
            'previewImageUrl': 'https://t.nhentai.net/galleries/1/3t.jpg',
            'similarity': 97.5,
          },
          {
            'source': 'ehentai',
            'page': 1,
            'title': 'Sample EH Comic',
            'language': 'jp',
            'pagePath': '/s/abc/2837167-1',
            'subjectPath': '/g/2837167/f9a0a17b17',
            'previewImageUrl': 'https://ehgt.org/x/y.jpg',
            'similarity': 88.2,
          },
          {
            'source': 'panda',
            'page': 5,
            'title': 'Sample Panda Comic',
            'language': 'gb',
            'pagePath': null,
            'subjectPath': '/gallery/12345/',
            'previewImageUrl': 'https://panda.chaika.moe/thumb/12345.jpg',
            'similarity': 61.0,
          },
        ],
        'id': '2025102006392555',
        'factor': 1.2,
        'imageUrl': 'https://soutubot.moe/storage/img/abc.jpg',
        'searchOption': {'factor': 1.2},
        'executionTime': 3.14,
      };

  group('SoutubotSearchResult.fromJson', () {
    test('顶层字段解析', () {
      final result = SoutubotSearchResult.fromJson(sampleResponse());
      expect(result.items, hasLength(3));
      expect(result.id, '2025102006392555');
      expect(result.factor, 1.2);
      expect(result.imageUrl, 'https://soutubot.moe/storage/img/abc.jpg');
      expect(result.searchOption, {'factor': 1.2});
      expect(result.executionTime, 3.14);
    });

    test('未知响应结构报适配错误，空结果列表仍成功', () {
      expect(() => SoutubotSearchResult.fromJson(const {}), throwsFormatException);
      expect(SoutubotSearchResult.fromJson(const {'results': []}).items, isEmpty);
      expect(SoutubotSearchResult.fromJson(const {'data': []}).items, isEmpty);
      expect(SoutubotSearchResult.fromJson(const {'data': [], 'id': 'legacy-id'},
          response: const {'format': 'soutubot_v2', 'idPath': 'result_id'}).id, 'legacy-id');
    });

    test('similarity/page 为 int 或 string 时容错', () {
      final item = SoutubotSearchItem.fromJson(const {
        'source': 'nhentai',
        'page': '7',
        'title': 't',
        'similarity': 90,
      });
      expect(item.page, 7);
      expect(item.similarity, 90.0);
      expect(item.language, '');
      expect(item.pagePath, isNull);
      expect(item.subjectPath, isNull);
      expect(item.previewImageUrl, '');
    });
  });

  group('toAiResultItemJson', () {
    test('nhentai 条目：id 为纯数字画廊号', () {
      final result = SoutubotSearchResult.fromJson(sampleResponse());
      final json = result.items[0].toAiResultItemJson();
      expect(json['id'], '480041');
      expect(json['source'], 'nhentai');
      expect(json['title'], 'Sample NH Comic');
      expect(json['coverUrl'], 'https://t.nhentai.net/galleries/1/3t.jpg');
      final availability = json['availability'] as Map;
      expect(availability['webUrl'], 'https://nhentai.net/g/480041');
      expect(availability['similarity'], 97.5);
      expect(availability['language'], 'cn');
      expect(availability['matchedPage'], 3);
    });

    test('nhentai 条目 subjectPath 抠不出数字时降级 source 为空串', () {
      final item = SoutubotSearchItem.fromJson(const {
        'source': 'nhentai',
        'title': 'weird',
        'subjectPath': '/search?q=x',
        'similarity': 50,
      });
      final json = item.toAiResultItemJson();
      expect(json['source'], '');
      expect(json['id'], '/search?q=x');
    });

    test('ehentai 条目：id 为画廊完整 URL（gid+token 齐全）', () {
      final result = SoutubotSearchResult.fromJson(sampleResponse());
      final json = result.items[1].toAiResultItemJson();
      expect(json['id'], 'https://e-hentai.org/g/2837167/f9a0a17b17');
      expect(json['source'], 'ehentai');
      final availability = json['availability'] as Map;
      expect(
        availability['webUrl'],
        'https://e-hentai.org/g/2837167/f9a0a17b17',
      );
    });

    test('ehentai 条目缺 token 时降级 source 为空串', () {
      final item = SoutubotSearchItem.fromJson(const {
        'source': 'ehentai',
        'title': 'no token',
        'subjectPath': '/g/2837167',
        'similarity': 70,
      });
      final json = item.toAiResultItemJson();
      expect(json['source'], '');
      expect(json['id'], '/g/2837167');
    });

    test('panda 条目：source 空串且严禁映射成 ehentai，webUrl 指向 chaika', () {
      final result = SoutubotSearchResult.fromJson(sampleResponse());
      final panda = result.items[2];
      expect(panda.pagePath, isNull);
      expect(panda.source, 'panda');
      final json = panda.toAiResultItemJson();
      expect(json['source'], '');
      expect(json['source'], isNot('ehentai'));
      expect(json['id'], '/gallery/12345/');
      final availability = json['availability'] as Map;
      expect(availability['webUrl'], 'https://panda.chaika.moe/gallery/12345/');
    });

    test('panda 条目经 AiResultItem.decodeToolData 不丢弃且 webUrl 原样保留', () {
      final result = SoutubotSearchResult.fromJson(sampleResponse());
      final report = AiResultItem.decodeToolData({
        'items': [result.items[2].toAiResultItemJson()],
      });
      expect(report.discardedCount, 0);
      expect(report.items, hasLength(1));
      final item = report.items.single;
      expect(item.source, '');
      expect(item.source, isNot('ehentai'));
      expect(item.id, '/gallery/12345/');
      expect(item.title, 'Sample Panda Comic');
      expect(
        item.availability['webUrl'],
        'https://panda.chaika.moe/gallery/12345/',
      );
      expect(item.availability['similarity'], 61.0);
    });
  });

  group('新版多路径结果', () {
    test('Pixiv作品ID误填page_no时不作为真实命中页数', () {
      final item = SoutubotSearchItem.fromSegment({
        'source_key': 'pixiv', 'external_id': '119465864',
        'page_no': 119465864, 'source_url': 'https://www.pixiv.net/artworks/119465864',
      }, score: 80);
      expect(item.page, 0);
      expect(item.toAiResultItemJson()['availability'] as Map, isNot(contains('matchedPage')));
      expect(item.toAiResultItemJson()['id'], '119465864');
    });
    Map<String, Object?> response(List<Map<String, Object?>> paths) => {
      'result_id': 'test-query',
      'query': {'requested_params': {'factor': 1.2}},
      'results': [{'score': 83.5, 'path_segments': paths}],
    };
    Map<String, Object?> segment(String source, String id, String url) => {
      'metadata': {'source': {'key': source, 'id': id}, 'title': {'primary': '标题'}, 'language': 'ja'},
      'page_no': 2,
      'links': {'source_url': url, 'thumbnail_url': 'https://images.example/thumb.jpg'},
    };

    test('同一命中保留所有来源，内置源得到准确原生ID', () {
      final result = SoutubotSearchResult.fromJson(response([
        segment('nhentai', '123', 'https://nhentai.net/g/123/'),
        segment('ehentai', '456', 'https://exhentai.org/g/456/abcdef1234/'),
        segment('pixiv', '789', 'https://www.pixiv.net/artworks/789'),
        segment('jmcomic', '987', 'https://18comic.vip/album/987/'),
        segment('danbooru', '543', 'https://danbooru.donmai.us/posts/543'),
      ]));
      expect(result.id, 'test-query');
      expect(result.factor, 1.2);
      final mapped = result.items.map((item) => item.toAiResultItemJson()).toList();
      expect(mapped.map((item) => item['source']), ['nhentai', 'ehentai', 'pixiv', 'jm', '']);
      expect(mapped.map((item) => item['id']), ['123', 'https://exhentai.org/g/456/abcdef1234/', '789', '987', 'https://danbooru.donmai.us/posts/543']);
      expect(result.items.every((item) => item.page == 2 && item.similarity == 83.5), isTrue);
      expect(AiResultItem.decodeToolData({'items': mapped}).discardedCount, 0);
      expect((mapped.last['availability'] as Map)['webUrl'], 'https://danbooru.donmai.us/posts/543');
    });

    test('不把完整链接重复拼接、不将未知或不完整链接路由成内置作品', () {
      final result = SoutubotSearchResult.fromJson(response([
        segment('nhentai', '123', 'https://unrelated.example/g/123/'),
        segment('ehentai', '456', 'https://e-hentai.org/g/456/'),
        segment('jmcomic', '987', 'https://18comic.vip/photo/987/'),
        segment('jmcomic', '987', 'https://unrelated.example/album/987/'),
        segment('pixiv', '789', 'javascript:alert(1)'),
      ]));
      final items = result.items.map((item) => item.toAiResultItemJson()).toList();
      expect(items.every((item) => item['source'] == ''), isTrue);
      expect((items.first['availability'] as Map)['webUrl'], 'https://unrelated.example/g/123/');
      expect((items.last['availability'] as Map)['webUrl'], '');
    });

    test('缺导入元数据时显示来源ID，适配器字段路径可覆盖', () {
      final result = SoutubotSearchResult.fromJson({
        'answer': {'id': 'r1', 'matches': [{
          'rank': 77,
          'paths': [{'source': 'pixiv', 'id': '123', 'href': 'https://www.pixiv.net/artworks/123'}],
        }]}
      }, response: {
        'format': 'soutubot_v2', 'resultsPath': 'answer.matches', 'idPath': 'answer.id',
        'segmentsPath': 'paths', 'scorePath': 'rank',
        'fieldPaths': {'source': ['source'], 'sourceId': ['id'], 'url': ['href']},
      });
      expect(result.id, 'r1');
      expect(result.items.single.title, 'pixiv #123');
      expect(result.items.single.toAiResultItemJson()['id'], '123');
      expect(result.items.single.similarity, 77);
    });

    test('非列表/非对象/缺路径的非空响应明确报错', () {
      for (final raw in <Map<String, Object?>>[
        {'results': {}}, {'results': [null]}, {'results': [{'score': 1}]},
        {'results': [{'path_segments': [3]}]},
        {'results': [{'path_segments': [{}]}]},
      ]) {
        expect(() => SoutubotSearchResult.fromJson(raw), throwsFormatException);
      }
      expect(SoutubotSearchResult.fromJson(response([])).items, isEmpty);
    });
  });
}
