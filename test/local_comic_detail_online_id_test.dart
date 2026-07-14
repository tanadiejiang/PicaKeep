import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library.dart';
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

void main() {
  group('resolveOnlineRawId', () {
    test('reads originalId (not the internal itemId) for LocalLibraryComicItem',
        () {
      final item = _localItem(
        itemId: 'local_download::current_download::jm1228705',
        originalId: 'jm1228705',
      );
      expect(resolveOnlineRawId(item), 'jm1228705');
    });

    test('falls back to comic.id for non-LocalLibraryComicItem sources', () {
      final comic = DownloadedJmComic(
        comicId: '1228705',
        name: 'name',
        downloadedChapters: const [0],
      );
      expect(resolveOnlineRawId(comic), 'jm1228705');
    });
  });

  group('extractJmNumericId', () {
    test('extracts numeric id from a legit jm-prefixed rawId', () {
      expect(extractJmNumericId('jm1228705'), '1228705');
    });

    test('rejects rawId that is only the itemId prefix (empty numeric part)',
        () {
      expect(extractJmNumericId('jm'), isNull);
    });

    test('rejects rawId with no jm prefix and non-numeric content', () {
      expect(extractJmNumericId('local_download::current_download::jm123'),
          isNull);
    });

    test('rejects empty rawId', () {
      expect(extractJmNumericId(''), isNull);
    });
  });

  group('extractNhentaiNumericId', () {
    test('extracts numeric id from a legit nhentai-prefixed rawId', () {
      expect(extractNhentaiNumericId('nhentai123456'), '123456');
    });

    test('rejects non-numeric/empty rawId', () {
      expect(extractNhentaiNumericId('nhentai'), isNull);
      expect(extractNhentaiNumericId(''), isNull);
    });
  });

  group('resolveEhGalleryLink', () {
    const link = 'https://e-hentai.org/g/220980/abc123def/';

    test('uses the persisted link on a direct DownloadedGallery', () {
      final gallery = DownloadedGallery(
        galleryTitle: 'EH',
        link: link,
      );

      expect(resolveEhGalleryLink(gallery), link);
    });

    test('restores both current flat and historical nested local JSON', () {
      final current = DownloadedGallery(
        galleryTitle: 'EH',
        link: link,
      );
      final currentItem = _localItem(
        itemId: 'local_download::current_download::220980-abc123def',
        originalId: '220980-abc123def',
        type: DownloadType.ehentai,
        sourceRowJson: jsonEncode(current.toJson()),
      );
      final historicalItem = _localItem(
        itemId: 'local_download::current_download::220981-abc456def',
        originalId: '220981-abc456def',
        type: DownloadType.ehentai,
        sourceRowJson: jsonEncode({
          'gallery': {
            'title': 'legacy EH',
            'link': 'https://exhentai.org/g/220981/abc456def/',
            'tags': <String, List<String>>{},
          },
        }),
      );

      expect(resolveEhGalleryLink(currentItem), link);
      expect(
        resolveEhGalleryLink(historicalItem),
        'https://exhentai.org/g/220981/abc456def/',
      );
    });

    test('rejects missing, non-HTTP, foreign-host and invalid gallery links',
        () {
      DownloadedGallery galleryFor(String value) => DownloadedGallery(
            galleryTitle: 'EH',
            link: value,
          );

      expect(resolveEhGalleryLink(galleryFor('')), isNull);
      expect(resolveEhGalleryLink(galleryFor('220980-abc123def')), isNull);
      expect(
        resolveEhGalleryLink(galleryFor('ftp://e-hentai.org/g/220980/abc/')),
        isNull,
      );
      expect(
        resolveEhGalleryLink(galleryFor('https://example.com/g/220980/abc/')),
        isNull,
      );
      expect(
        resolveEhGalleryLink(galleryFor('https://e-hentai.org/g/not-id/abc/')),
        isNull,
      );
    });
  });
}
