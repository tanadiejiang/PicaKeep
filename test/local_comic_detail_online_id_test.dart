import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/pages/local_comic_detail_page.dart';

LocalLibraryComicItem _localItem({
  required String itemId,
  required String originalId,
  DownloadType type = DownloadType.jm,
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
}
