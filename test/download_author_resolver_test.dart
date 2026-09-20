import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/download_model.dart';

void main() {
  test('EH author uses artist tag and never uploader/group', () {
    final item = DownloadedGallery(
      galleryTitle: 'title',
      uploader: '8476411',
      link: 'https://e-hentai.org/g/123/abc/',
      tagList: const [
        'artist:konomi',
        'group:きのこのみ',
        'cosplayer:someone',
      ],
    );
    expect(resolveDownloadedAuthors(item), ['konomi']);
  });

  test('NH author uses only Artists category', () {
    final item = NhentaiDownloadedComic(
      comicID: '605366',
      title: 'title',
      categorizedTags: const {
        'Artists': ['konomi', 'konomi'],
        'Groups': ['きのこのみ'],
        'Tags': ['ordinary'],
      },
    );
    expect(resolveDownloadedAuthors(item), ['konomi']);
  });

  test('managed wrapper resolves canonical author from raw record', () {
    final json = jsonEncode({
      'galleryTitle': 'title',
      'uploader': '8476411',
      'link': 'https://e-hentai.org/g/123/abc/',
      'tagList': ['artist:konomi', 'group:きのこのみ'],
    });
    expect(
      resolveDownloadedAuthorsFromRecord('123-abc', json),
      ['konomi'],
    );
  });

  test('EH/NH rows without reliable metadata stay empty', () {
    expect(resolveDownloadedAuthorsFromRecord('123-abc', '{}'), isEmpty);
    expect(resolveDownloadedAuthorsFromRecord('nhentai605366', '{}'), isEmpty);
  });

  test('source-neutral online resolver keeps EH artist and unknown NH brief',
      () {
    expect(
      resolveSourceAuthors(
        source: 'ehentai',
        flatTags: const ['artist:konomi', 'group:きのこのみ'],
        fallbackAuthor: '8476411',
      ),
      ['konomi'],
    );
    expect(
      resolveSourceAuthors(
        source: 'nhentai',
        flatTags: const ['artist:konomi'],
        fallbackAuthor: '605366',
      ),
      isEmpty,
    );
  });

  test('source-neutral resolver uses explicit author for other sources', () {
    expect(
      resolveSourceAuthors(source: 'picacg', fallbackAuthor: 'A, B'),
      ['A', 'B'],
    );
  });

  // 04 计划追加：列表卡片描述位在源无简介时回退到源标识号。
  group('displaySourceInfoLine', () {
    test('JM 无简介时回退为 jm<id>', () {
      expect(
        displaySourceInfoLine(source: 'jm', comicId: '1466163', description: ''),
        'jm1466163',
      );
    });

    test('NH 无简介时回退为 nhentai<id>', () {
      expect(
        displaySourceInfoLine(
            source: 'nhentai', comicId: '605366', description: ''),
        'nhentai605366',
      );
    });

    test('有简介时一律显示简介，不回退标识号', () {
      for (final source in const ['jm', 'nhentai', 'picacg', 'ehentai']) {
        expect(
          displaySourceInfoLine(
              source: source, comicId: '1466163', description: '作品简介'),
          '作品简介',
          reason: '$source 不应覆盖既有简介',
        );
      }
    });

    test('无简介且源不在回退名单内时保持为空', () {
      for (final source in const ['picacg', 'ehentai', 'unknown']) {
        expect(
          displaySourceInfoLine(source: source, comicId: '1', description: ''),
          isEmpty,
        );
      }
    });

    test('id 为空时不产生残缺前缀', () {
      expect(
        displaySourceInfoLine(source: 'jm', comicId: '', description: ''),
        isEmpty,
      );
      expect(
        displaySourceInfoLine(source: 'jm', comicId: '   ', description: ''),
        isEmpty,
      );
    });

    test('纯空白简介视为无简介', () {
      expect(
        displaySourceInfoLine(source: 'jm', comicId: '9', description: '   '),
        'jm9',
      );
    });
  });
}
