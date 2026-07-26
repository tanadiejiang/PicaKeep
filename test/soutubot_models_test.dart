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

    test('缺字段时全部落缺省值', () {
      final result = SoutubotSearchResult.fromJson(const {});
      expect(result.items, isEmpty);
      expect(result.id, '');
      expect(result.factor, 0);
      expect(result.imageUrl, '');
      expect(result.searchOption, isNull);
      expect(result.executionTime, 0);
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
}
