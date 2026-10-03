import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/foundation/pixiv_library.dart';

LocalLibraryComicItem item(String path, String source, {int pages = 1}) =>
    LocalLibraryComicItem(
      itemId: path,
      originalId: 'same-work',
      type: DownloadType.other,
      name: '作品',
      subTitle: '作者',
      tags: const [],
      sourceDisplayName: source,
      fileSystemPath: path,
      episodeFiles: const {},
      downloadedEps: const [0],
      eps: const ['全部'],
      localCoverPath: null,
      localStorageExists: true,
      canDelete: false,
      aliases: const [],
      sourceRowJson: jsonEncode({'sourceKey': source, 'pageCount': pages}),
    );

void main() {
  test('counts match snapshot membership, with copies and mixed artifacts', () {
    final entries = buildIllustEntries([
      item('/pixiv/root.png', 'pixiv'),
      item('/pixiv/normal/multi.zip', 'pixiv', pages: 12),
      item('/pixiv/normal/copy.png', 'pixiv'),
      item('/pixiv/normal/legacy-work-folder', 'pixiv', pages: 3),
      item('/pixiv/normal/manga.zip', 'other'),
      item('/another-root/other.png', 'pixiv'),
    ]);
    final folders = countIllustFolders(const [
      PixivFolder(
          root: '/pixiv',
          libraryId: 'lib',
          id: 'root',
          name: '主目录',
          relativePath: '.',
          isDefault: true),
      PixivFolder(
          root: '/pixiv',
          libraryId: 'lib',
          id: 'normal',
          name: '正常的',
          relativePath: './normal'),
      PixivFolder(
          root: '/pixiv',
          libraryId: 'lib',
          id: 'empty',
          name: '空',
          relativePath: 'empty'),
    ], entries);
    expect(folders.map((f) => f.count), [1, 3, 0]);
    expect(entries.length, 5, reason: 'all includes the other managed root');
    expect(folders.first.isDefault, isTrue);
    expect(folders[1].sourceId, 'pixiv_folder::lib::normal');
  });
}
