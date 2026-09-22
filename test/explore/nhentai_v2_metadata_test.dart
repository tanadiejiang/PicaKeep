import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/providers/nhentai_explore_provider.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/network/res.dart';

Map<String, Object?> _gallery(int id, int language) => {
      'id': id,
      'english_title': 'Sample $id',
      'thumbnail': 'galleries/$id/thumb.jpg',
      'tag_ids': [language, 20905, 8378, 9999999],
    };

void main() {
  group('NH v2 gallery metadata', () {
    test('list preserves ID and resolves tag IDs with the dynamic CDN', () {
      final item = parseNhentaiV2Gallery(
        _gallery(123456, 12227),
        cdnServer: 'https://thumb.example.test/',
      )!;
      expect(item.id, '123456');
      expect(item.subTitle, '123456');
      expect(item.title, 'Sample 123456');
      expect(
          item.cover, 'https://thumb.example.test/galleries/123456/thumb.jpg');
      expect(item.lang, 'English');
      expect(item.tags, ['full color', 'glasses']);
    });

    test('named tags support new IDs and random detail image/title objects',
        () {
      final item = parseNhentaiV2Gallery({
        'id': '123457',
        'title': {'english': '', 'japanese': 'Sample translated title'},
        'thumbnail': {'path': '/galleries/sample/thumb.webp'},
        'tags': [
          {'id': 29963, 'type': 'language', 'name': 'chinese'},
          {'id': 9999999, 'type': 'tag', 'name': 'sample tag'},
          {'id': 20905, 'type': 'tag', 'name': 'full color'},
        ],
        'tag_ids': [20905],
      }, cdnServer: 'https://thumb.example.test')!;
      expect(item.title, 'Sample translated title');
      expect(
          item.cover, 'https://thumb.example.test/galleries/sample/thumb.webp');
      expect(item.lang, '中文');
      expect(item.tags, ['full color', 'sample tag']);
    });

    test('missing metadata stays empty without a bogus CDN root or Unknown',
        () {
      final item = parseNhentaiV2Gallery({
        'id': 123458,
        'tag_ids': [122270, 9999999],
      }, cdnServer: 'https://thumb.example.test')!;
      expect(item.cover, isEmpty);
      expect(item.title, '123458');
      expect(item.tags, isEmpty);
      expect(item.lang, 'Unknown');
      expect(item.description, isEmpty);
    });

    test('invalid IDs are discarded and absolute covers remain absolute', () {
      for (final id in [null, '', 'null', 'abc', 0, -1]) {
        expect(
          parseNhentaiV2Gallery({'id': id}, cdnServer: 'https://unused.test'),
          isNull,
        );
      }
      final item = parseNhentaiV2Gallery({
        'id': 123459,
        'thumbnail': '//thumb.example.test/sample.jpg',
      }, cdnServer: 'https://unused.test')!;
      expect(item.cover, 'https://thumb.example.test/sample.jpg');
    });
  });

  group('NH home v2 request path', () {
    late List<Uri> requests;
    late NhentaiNetwork network;

    setUp(() {
      requests = [];
      network = NhentaiNetwork.forTesting(get: (url) async {
        final uri = Uri.parse(url);
        requests.add(uri);
        return switch (uri.path) {
          '/api/v2/cdn' => Res(jsonEncode({
              'thumb_servers': ['https://thumb.example.test'],
            })),
          '/api/v2/popular' => Res(jsonEncode({
              'result': [_gallery(101, 12227)],
            })),
          '/api/v2/galleries' => Res(jsonEncode({
              'result': [
                _gallery(uri.queryParameters['page'] == '2' ? 202 : 201, 29963),
                {'id': null},
                'malformed row',
              ],
              'num_pages': 3,
            })),
          '/api/v2/search' => Res(jsonEncode({
              'result': [_gallery(301, 6346)],
              'num_pages': 5,
            })),
          _ => throw StateError('Unexpected request: $url'),
        };
      });
    });

    test('home obtains both sections with tags in three requests, no detail',
        () async {
      final response = await network.getHomePageData(1);
      expect(response.error, isFalse);
      expect(response.data.popular.single.id, '101');
      expect(response.data.popular.single.lang, 'English');
      expect(response.data.latest.single.id, '201');
      expect(response.data.latest.single.lang, '中文');
      expect(response.data.latest.single.tags, ['full color', 'glasses']);
      expect(response.subData, 3);
      expect(
          requests.map((e) => e.path),
          unorderedEquals([
            '/api/v2/cdn',
            '/api/v2/popular',
            '/api/v2/galleries',
          ]));
    });

    test('next page reuses CDN and never repeats Popular', () async {
      final first = await network.getHomePageData(1);
      requests.clear();
      final next = await network.loadMoreHomePageData(first.data);
      expect(next.error, isFalse);
      expect(first.data.page, 2);
      expect(first.data.popular.map((e) => e.id), ['101']);
      expect(first.data.latest.map((e) => e.id), ['201', '202']);
      expect(requests.single.path, '/api/v2/galleries');
      expect(requests.single.queryParameters['page'], '2');
    });

    test('latest and search share metadata parser and retain page totals',
        () async {
      final latest = await network.getLatest(2);
      final search = await network.search('sample', 1);
      expect(latest.data.single.id, '202');
      expect(latest.subData, 3);
      expect(search.data.single.lang, '日本語');
      expect(search.data.single.tags, ['full color', 'glasses']);
      expect(search.subData, 5);
    });
  });

  test('home popular alias is only requested on 404/405, not on 429', () async {
    for (final status in [404, 429]) {
      final paths = <String>[];
      final network = NhentaiNetwork.forTesting(get: (url) async {
        final path = Uri.parse(url).path;
        paths.add(path);
        if (path == '/api/v2/cdn') {
          return Res(jsonEncode({
            'servers': ['https://thumb.example.test']
          }));
        }
        if (path == '/api/v2/popular') {
          return Res.error('Unavailable', statusCode: status);
        }
        return Res(jsonEncode([_gallery(401, 12227)]));
      });
      final response = await network.getHomePageData(1);
      expect(response.error, isFalse);
      expect(paths.contains('/api/v2/galleries/popular'), status == 404);
      if (status == 429) expect(response.data.popularError?.statusCode, 429);
    }
  });

  test('NH overview keeps a successful section when the other request fails',
      () async {
    for (final failedPath in ['/api/v2/popular', '/api/v2/galleries']) {
      final network = NhentaiNetwork.forTesting(get: (url) async {
        final path = Uri.parse(url).path;
        if (path == failedPath) {
          return const Res.error('Temporary failure',
              statusCode: 503, errorCode: ResErrorCode.network);
        }
        return Res(jsonEncode(path == '/api/v2/cdn'
            ? {
                'thumb_servers': ['https://thumb.example.test']
              }
            : {
                'result': [_gallery(401, 12227)]
              }));
      });
      final provider = NhentaiExploreProvider(
          isLoggedInGetter: () => true,
          contextFingerprintGetter: () => 'test',
          network: network);
      final overview = await provider.loadOverview(const ExploreRequest(
          sessionId: 'test',
          sourceKey: 'nhentai',
          entryId: NhentaiExploreEntries.home));
      expect(overview.errorOrNull, isNull);
      expect(overview.dataOrNull!.sections.where((s) => s.error != null),
          hasLength(1));
      expect(overview.dataOrNull!.sections.where((s) => s.items.isNotEmpty),
          hasLength(1));
    }
  });

  test('random uses returned metadata without requesting a second detail',
      () async {
    final paths = <String>[];
    final network = NhentaiNetwork.forTesting(get: (url) async {
      final path = Uri.parse(url).path;
      paths.add(path);
      return Res(jsonEncode(path == '/api/v2/cdn'
          ? {
              'thumb_servers': ['https://thumb.example.test']
            }
          : {
              'id': 501,
              'title': {'english': 'Random sample'},
              'cover': {'path': '/sample/cover.jpg'},
              'tags': [
                {'id': 12227, 'type': 'language', 'name': 'english'},
                {'id': 20905, 'type': 'tag', 'name': 'full color'},
              ],
            }));
    });
    final response = await network.getRandomComic();
    expect(response.error, isFalse);
    expect(response.data.id, '501');
    expect(response.data.lang, 'English');
    expect(response.data.tags, ['full color']);
    expect(paths, ['/api/v2/cdn', '/api/v2/galleries/random']);
  });
}
