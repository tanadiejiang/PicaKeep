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
}
