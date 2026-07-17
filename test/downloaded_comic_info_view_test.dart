import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/pages/download_page.dart';

void main() {
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
