import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

FavoriteItem _item(String target,
        [FavoriteType type = const FavoriteType(2)]) =>
    FavoriteItem(
      target: target,
      name: 'A title unrelated to its ID',
      coverPath: '',
      author: '',
      type: type,
      tags: [],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
      OperatingSystem.windows,
      () =>
          DynamicLibrary.open('${Directory.current.path}/windows/sqlite3.dll'));
  final manager = LocalFavoritesManager();
  late Directory root;
  late List<String> settings;

  setUp(() async {
    settings = List.of(appdata.settings);
    root = await Directory.systemTemp.createTemp('pk_membership_');
    await manager.init(dataRoots: [root.path]);
    manager.createFolder('A');
    manager.createFolder('B');
  });
  tearDown(() async {
    manager.dispose();
    appdata.settings
      ..clear()
      ..addAll(settings);
    await root.delete(recursive: true);
  });

  test('source identity isolates equal IDs and preserves legacy aliases', () {
    manager.addComic('A', _item('123'));
    manager.addComic('A', _item('45', FavoriteType.copyManga));
    manager.addComic(
        'A', _item('https://e-hentai.org/g/8/token/', FavoriteType.ehentai));
    expect(manager.isComicFavorited('123', FavoriteType.jm), isTrue);
    expect(manager.isComicFavorited('jm123', FavoriteType.jm), isTrue);
    expect(manager.isComicFavorited('123', FavoriteType.nhentai), isFalse);
    expect(manager.isComicFavorited('123', FavoriteType.picacg), isFalse);
    expect(manager.isComicFavorited('45', FavoriteType('copy_manga'.hashCode)),
        isTrue);
    expect(
        manager.isComicFavorited(
            'https://exhentai.org/g/8/token/', FavoriteType.ehentai),
        isTrue);
    expect(manager.isExist('local_download::current_download::jm123'), isTrue);
    expect(manager.existsMany(['jm123', 'absent']),
        {'jm123': true, 'absent': false});
  });

  test('mutations invalidate one shared snapshot across folders', () {
    expect(manager.isComicFavorited('123', FavoriteType.jm), isFalse);
    manager.addComic('A', _item('123'));
    expect(manager.isComicFavorited('123', FavoriteType.jm), isTrue);
    manager.addComic('B', _item('123'));
    manager.deleteComic('A', _item('123'));
    expect(manager.isComicFavorited('123', FavoriteType.jm), isTrue);
    manager.rename('B', 'Renamed');
    expect(manager.isComicFavorited('123', FavoriteType.jm), isTrue);
    manager.reorder([_item('456')], 'Renamed');
    expect(manager.isComicFavorited('123', FavoriteType.jm), isFalse);
    expect(manager.isComicFavorited('456', FavoriteType.jm), isTrue);
    manager.deleteFolder('Renamed');
    expect(manager.isComicFavorited('456', FavoriteType.jm), isFalse);
    expect(manager.isExist('jm456'), isFalse);
  });

  test('batch yield exposes committed membership before its final notification',
      () async {
    final observed = <bool>[];
    await manager.addComicsToFolders(
      ['A'],
      [for (var i = 0; i < 70; i++) _item('$i')],
      onProgress: (done, total) {
        observed.add(manager.isComicFavorited('${done - 1}', FavoriteType.jm));
        if (done < total) {
          expect(manager.isComicFavorited('$done', FavoriteType.jm), isFalse);
        }
      },
    );
    expect(observed, [true, true, true]);
    expect(manager.isComicFavorited('69', FavoriteType.jm), isTrue);
  });

  test('warm lookups use memory until external writers notify', () {
    manager.addComic('A', _item('123'));
    expect(manager.isComicFavorited('123', FavoriteType.jm), isTrue);
    final writer = sqlite3.open('${root.path}/local_favorite.db');
    try {
      writer.execute('delete from "A";');
      writer.execute('begin exclusive;');
      // Any new schema/row read through the manager connection would now fail
      // with SQLITE_BUSY. Repeated positive and negative lookups must be memory.
      for (var i = 0; i < 200; i++) {
        expect(manager.isComicFavorited('123', FavoriteType.jm), isTrue);
        expect(manager.isComicFavorited('absent', FavoriteType.jm), isFalse);
      }
      writer.execute('commit;');
      manager.notifyFoldersChanged();
      expect(manager.isComicFavorited('123', FavoriteType.jm), isFalse);
      expect(manager.isExist('jm123'), isFalse);
    } finally {
      writer.dispose();
    }
  });

  test('switching or reopening stores clears previous membership', () async {
    manager.addComic('A', _item('123'));
    expect(manager.isComicFavorited('123', FavoriteType.jm), isTrue);
    final other = await Directory('${root.path}/other').create();
    await manager.init(dataRoots: [other.path]);
    expect(manager.isComicFavorited('123', FavoriteType.jm), isFalse);
    manager.createFolder('Other');
    manager.addComic('Other', _item('456'));
    await manager.init(dataRoots: [root.path, other.path]);
    expect(manager.isComicFavorited('123', FavoriteType.jm), isTrue);
    expect(manager.isComicFavorited('456', FavoriteType.jm), isTrue);
    manager.dispose();
    expect(manager.isComicFavorited('123', FavoriteType.jm), isFalse);
    expect(manager.isExist('jm123'), isFalse);
    await manager.init(dataRoots: [root.path]);
    expect(manager.isComicFavorited('123', FavoriteType.jm), isTrue);
    expect(manager.isComicFavorited('456', FavoriteType.jm), isFalse);
  });

  testWidgets('kept online cards use their ID and update badges on mutations',
      (tester) async {
    appdata.settings[44] = '0';
    appdata.settings[72] = '1';
    appdata.settings[73] = '0';
    final source = ComicSource.named(key: 'jm', name: 'JM');
    const comic =
        CustomComic('A title unrelated to its ID', '', '', '123', [], '', 'jm');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: OnlineComicListItem(source: source, comic: comic)),
    ));
    await tester.pumpAndSettle();
    final card =
        tester.widget<DownloadedComicTile>(find.byType(DownloadedComicTile));
    expect(card.favoriteTarget, '123');
    expect(card.favoriteType, FavoriteType.jm);
    expect(find.byIcon(Icons.bookmark_rounded), findsNothing);
    manager.addComic('A', _item('123', FavoriteType.nhentai));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.bookmark_rounded), findsNothing);
    manager.addComic('A', _item('123'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.bookmark_rounded), findsOneWidget);
    expect(tester.widget<DownloadedComicTile>(find.byType(DownloadedComicTile)),
        same(card));
    manager.deleteComicWithTarget('A', '123', FavoriteType.jm);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.bookmark_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
