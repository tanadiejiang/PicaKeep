import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/chapter_download_state.dart';
import 'package:picakeep/foundation/state_controller.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/base_online_comic_page.dart';
import 'package:picakeep/pages/online_comic/chapter_download_selection.dart';
import 'package:picakeep/pages/online_comic/online_comic_page_components.dart';
import 'package:picakeep/pages/online_comic/online_comic_page_logic.dart';

class _PartialChaptersPage extends BaseOnlineComicPage<int> {
  const _PartialChaptersPage(this.submit);
  final Future<Res<bool>> Function(List<int>) submit;
  @override
  String get id => 'chapter-flow';
  @override
  String get tag => 'chapter-flow';
  @override
  String get sourceKey => 'jm';
  @override
  String get source => '测试';
  @override
  Future<Res<int>> loadData() async => const Res(4);
  @override
  Future<bool> loadFavoriteState(int data) async => false;
  @override
  String extractTitle(int data) => '部分已下载作品';
  @override
  String extractCover(int data) => '';
  @override
  Map<String, List<String>> extractTags(int data) => {};
  @override
  List<String> extractEpisodes(int data) =>
      List.generate(data, (i) => '第${i + 1}章');
  @override
  bool supportsChapterDownloads(int data) => data > 1;
  @override
  void onTagTap(BuildContext context, String tag, String category) {}
  @override
  void onRead(BuildContext context, int data, {int ep = 1}) {}
  @override
  void onFavorite(BuildContext context, int data) {}
  @override
  Future<void> onDownload(BuildContext context, int data) async {
    await showChapterDownloadSelection(context,
        title: '部分已下载作品',
        chapterNames: extractEpisodes(data),
        identity: 'test-partial/1',
        loadStatuses: () async => {0: ChapterDownloadStatus.downloaded},
        onSubmit: submit);
  }
}

void main() {
  testWidgets('部分已下载详情的下载按钮进入补章面板，取消不删除不入队', (tester) async {
    var submissions = 0;
    await tester.pumpWidget(MaterialApp(home: _PartialChaptersPage((_) async {
      submissions++;
      return const Res(true);
    })));
    await tester.pumpAndSettle();
    final logic =
        StateController.find<OnlineComicPageLogic<int>>(tag: 'chapter-flow');
    logic.downloaded = true;
    logic.update();
    await tester.pump();
    final download = find.widgetWithText(OnlineComicPillButton, '下载');
    await tester.ensureVisible(download);
    await tester.tap(download);
    await tester.pumpAndSettle();
    expect(find.byType(ChapterDownloadSelection), findsOneWidget);
    expect(find.text('重新下载'), findsNothing);
    expect(find.text('已有本地文件，是否删除后重新下载？'), findsNothing);
    expect(find.text('已下载'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(submissions, 0);
    expect(logic.downloaded, isTrue);
    expect(find.byType(ChapterDownloadSelection), findsNothing);
  });
}
