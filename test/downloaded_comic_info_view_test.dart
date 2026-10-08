import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/pages/download_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('download-preview-031-');
    await App.init(
      dataPathOverride: workspace.path,
      cachePathOverride: workspace.path,
    );
  });
  tearDownAll(() => workspace.delete(recursive: true));

  testWidgets('partial download header counts only valid completed chapters',
      (tester) async {
    final item = DownloadedComic(
      comicId: 'partial-preview',
      title: 'Partial preview',
      author: '',
      chapters: List.generate(44, (index) => '${index + 1}'),
      downloadedChapters: [...List.generate(12, (index) => index), 0, -1, 44],
    );
    await tester.pumpWidget(_host(item));
    await tester.pumpAndSettle();
    expect(find.text('已下载 12 / 共 44 章节'), findsOneWidget);

    // Reopening after a chapter was removed uses the current completed record.
    await tester.pumpWidget(const SizedBox.shrink());
    item.downloadedChapters.remove(11);
    await tester.pumpWidget(_host(item));
    await tester.pumpAndSettle();
    expect(find.text('已下载 11 / 共 44 章节'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    item.downloadedChapters = List.generate(44, (index) => index);
    await tester.pumpWidget(_host(item));
    await tester.pumpAndSettle();
    expect(find.text('已下载 44 / 共 44 章节'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('archive header counts contained chapters without download state',
      (tester) async {
    final archive = LocalLibraryComicItem(
      itemId: 'local_archive::count-test',
      originalId: 'count-test',
      type: DownloadType.other,
      name: 'Archive preview',
      subTitle: '',
      tags: const [],
      sourceDisplayName: '压缩包',
      fileSystemPath: '',
      episodeFiles: const {},
      downloadedEps: const [],
      eps: const ['One', 'Two', 'Three'],
      localCoverPath: null,
      localStorageExists: true,
      canDelete: false,
      aliases: const [],
    );
    await tester.pumpWidget(_host(archive));
    await tester.pumpAndSettle();
    expect(find.text('3 章节'), findsOneWidget);
    expect(find.textContaining('已下载'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'downloaded preview folds author and tags independently while footer stays fixed',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final item = _longDownloadedComic();
    await tester.pumpWidget(_host(item));
    await tester.pumpAndSettle();

    const authorKey = ValueKey('downloaded-preview-author-disclosure');
    const tagsKey = ValueKey('downloaded-preview-tags-disclosure');
    expect(find.byKey(authorKey), findsOneWidget);
    expect(find.byKey(tagsKey), findsOneWidget);
    expect(find.text('展开作者'), findsOneWidget);
    expect(find.text('展开标签'), findsOneWidget);
    expect(find.text('tag-29'), findsNothing);

    final footerY = tester.getTopLeft(find.text('阅读')).dy;
    await tester.ensureVisible(find.byKey(authorKey));
    await tester.tap(find.byKey(authorKey));
    await tester.pumpAndSettle();
    expect(find.text('收起作者'), findsOneWidget);
    expect(find.text('展开标签'), findsOneWidget);

    await tester.ensureVisible(find.byKey(tagsKey));
    await tester.tap(find.byKey(tagsKey));
    await tester.pumpAndSettle();
    expect(find.text('收起标签'), findsOneWidget);
    expect(find.text('tag-29'), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('阅读')).dy, closeTo(footerY, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('short preview metadata does not show disclosure controls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final item = DownloadedComic(
      comicId: 'short-preview',
      title: 'Short preview',
      author: 'one artist',
      chapters: const ['Chapter 1'],
      downloadedChapters: const [0],
      tagList: const ['short-tag'],
    );
    await tester.pumpWidget(_host(item));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('downloaded-preview-author-disclosure')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('downloaded-preview-tags-disclosure')),
      findsNothing,
    );
    expect(find.text('查看详情'), findsOneWidget);
    expect(find.text('阅读'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _host(DownloadedItem item) {
  return MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(
        size: Size(360, 640),
        textScaler: TextScaler.linear(1),
      ),
      child: SizedBox(
        width: 360,
        height: 640,
        child: Scaffold(
          body: DownloadedComicInfoView(item, null),
        ),
      ),
    ),
  );
}

DownloadedComic _longDownloadedComic() {
  return DownloadedComic(
    comicId: 'long-preview',
    title: 'Long downloaded preview',
    author: List<String>.generate(14, (index) => 'artist-$index').join(', '),
    chapters: List<String>.generate(20, (index) => 'Chapter ${index + 1}'),
    downloadedChapters: List<int>.generate(20, (index) => index),
    tagList: List<String>.generate(30, (index) => 'tag-$index'),
  );
}
