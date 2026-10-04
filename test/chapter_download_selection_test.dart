import 'dart:async';
import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/chapter_download_state.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/chapter_download_selection.dart';

Finder chapter(int i) => find.byKey(ValueKey('chapter-download-$i'));
bool selected(WidgetTester tester, int i) =>
    tester.widget<Semantics>(chapter(i)).properties.selected == true;

Future<void> showPanel(
  WidgetTester tester, {
  int count = 30,
  Map<int, ChapterDownloadStatus> states = const {},
  Future<Map<int, ChapterDownloadStatus>> Function()? load,
  Future<Res<bool>> Function(List<int>)? submit,
  VoidCallback? success,
  VoidCallback? cancel,
  Listenable? changes,
  TextDirection direction = TextDirection.ltr,
  double scale = 1,
  double width = 320,
}) async {
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Directionality(
        textDirection: direction,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
              width: width,
              height: 560,
              child: ChapterDownloadSelection(
                title: '测试作品',
                chapterNames: List.generate(count, (i) => '章节 ${i + 1}'),
                loadStatuses: load ?? () async => states,
                onSubmit: submit ?? (_) async => const Res(true),
                onSuccess: success ?? () {},
                onCancel: cancel ?? () {},
                statusChanges: changes,
              )),
        )),
  ))));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('320dp 大字长错误信息可滚动查看，提交期间返回不关闭面板', (tester) async {
    await showPanel(tester, scale: 1.8, load: () async {
      throw StateError(List.filled(20, '状态读取失败，请重试。').join());
    });
    expect(tester.takeException(), isNull);
    expect(find.text('重试读取状态'), findsOneWidget);
    final pending = Completer<Res<bool>>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      onPressed: () => showChapterDownloadSelection(context,
                          title: '忙态',
                          chapterNames: const ['第一章', '第二章'],
                          loadStatuses: () async => {},
                          onSubmit: (_) => pending.future),
                      child: const Text('打开'),
                    )))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(chapter(0));
    await tester.pump();
    await tester.tap(find.text('下载所选（1）'));
    await tester.pump();
    final navigator =
        Navigator.of(tester.element(find.byType(ChapterDownloadSelection)));
    await navigator.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(ChapterDownloadSelection), findsOneWidget);
    pending.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(find.byType(ChapterDownloadSelection), findsNothing);
  });

  testWidgets('切换章节列表后忽略旧提交完成结果', (tester) async {
    final pending = Completer<Res<bool>>();
    var successes = 0;
    await showPanel(tester,
        submit: (_) => pending.future, success: () => successes++);
    await tester.tap(chapter(0));
    await tester.pump();
    await tester.tap(find.text('下载所选（1）'));
    await tester.pump();
    await showPanel(tester, count: 2, success: () => successes++);
    pending.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(successes, 0);
    expect(find.text('共 2 章，已选 0 章'), findsOneWidget);
  });
  testWidgets('六种状态清楚标记，禁选非available，全选反选清空只处理可下载', (tester) async {
    await showPanel(tester, states: {
      0: ChapterDownloadStatus.downloaded,
      1: ChapterDownloadStatus.queued,
      2: ChapterDownloadStatus.downloading,
      3: ChapterDownloadStatus.paused,
      4: ChapterDownloadStatus.failed,
    });
    expect(find.text('已下载'), findsOneWidget);
    expect(find.text('已排队'), findsOneWidget);
    await tester.tap(chapter(0));
    expect(selected(tester, 0), isFalse);
    await tester.tap(find.text('全选可下载'));
    await tester.pump();
    expect(find.text('共 30 章，已选 25 章'), findsOneWidget);
    await tester.tap(find.text('反选'));
    await tester.pump();
    expect(find.text('共 30 章，已选 0 章'), findsOneWidget);
    await tester.tap(find.text('全选可下载'));
    await tester.tap(find.text('清空'));
    await tester.pump();
    expect(find.text('共 30 章，已选 0 章'), findsOneWidget);
  });

  testWidgets('状态读取失败不假装可下载，重试读回后才允许选择', (tester) async {
    var attempts = 0;
    await showPanel(tester, load: () async {
      if (++attempts == 1) throw StateError('无法读取');
      return {0: ChapterDownloadStatus.downloaded};
    });
    expect(find.textContaining('读取章节状态失败'), findsOneWidget);
    expect(chapter(0), findsNothing);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '全选可下载'))
            .onPressed,
        isNull);
    await tester.tap(find.text('重试读取状态'));
    await tester.pumpAndSettle();
    expect(find.text('已下载'), findsOneWidget);
    await tester.tap(chapter(1));
    await tester.pump();
    expect(selected(tester, 1), isTrue);
  });

  testWidgets('取消零提交，成功返回有序原始索引，失败保留选择，忙态只提交一次', (tester) async {
    var calls = 0, cancelled = 0, successes = 0;
    final pending = Completer<Res<bool>>();
    List<int>? indexes;
    await showPanel(tester,
        submit: (chosen) {
          calls++;
          indexes = chosen;
          return calls == 1
              ? Future.value(const Res.error('入队失败'))
              : pending.future;
        },
        cancel: () => cancelled++,
        success: () => successes++);
    await tester.tap(find.text('取消'));
    expect([cancelled, calls], [1, 0]);
    await tester.tap(chapter(3));
    await tester.tap(chapter(1));
    await tester.pump();
    await tester.tap(find.text('下载所选（2）'));
    await tester.pumpAndSettle();
    expect(indexes, [1, 3]);
    expect(find.text('入队失败'), findsOneWidget);
    expect(selected(tester, 1), isTrue);
    final submitButton = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '下载所选（2）'));
    submitButton.onPressed!();
    submitButton.onPressed!();
    await tester.pump();
    expect(calls, 2);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '正在加入队列'))
            .onPressed,
        isNull);
    pending.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(successes, 1);
  });

  testWidgets('外部状态变化撤销已排队选择，销毁后读取完成安全', (tester) async {
    final changes = ValueNotifier(0);
    var states = <int, ChapterDownloadStatus>{};
    await showPanel(tester, changes: changes, load: () async => states);
    await tester.tap(chapter(0));
    states = {0: ChapterDownloadStatus.queued};
    changes.value++;
    await tester.pump(const Duration(milliseconds: 121));
    await tester.pumpAndSettle();
    expect(selected(tester, 0), isFalse);
    expect(find.text('已排队'), findsOneWidget);
    final pending = Completer<Map<int, ChapterDownloadStatus>>();
    await tester.pumpWidget(MaterialApp(
        home: SizedBox(
            height: 500,
            child: ChapterDownloadSelection(
              title: '异步',
              chapterNames: const ['第一章'],
              loadStatuses: () => pending.future,
              onSubmit: (_) async => const Res(true),
              onSuccess: () {},
              onCancel: () {},
            ))));
    await tester.pumpWidget(const SizedBox());
    pending.complete({});
    await tester.pump();
    expect(tester.takeException(), isNull);
    changes.dispose();
  });

  testWidgets('长按滑选跳过已下载，回退恢复范围，已选起点滑动取消', (tester) async {
    await showPanel(tester, states: {1: ChapterDownloadStatus.downloaded});
    final gesture = await tester.startGesture(tester.getCenter(chapter(0)));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(tester.getCenter(chapter(3)));
    await tester.pump();
    expect([
      selected(tester, 0),
      selected(tester, 1),
      selected(tester, 2),
      selected(tester, 3)
    ], [
      true,
      false,
      true,
      true
    ]);
    await gesture.moveTo(tester.getCenter(chapter(2)));
    await tester.pump();
    expect(selected(tester, 3), isFalse);
    await gesture.up();
    await tester.pumpAndSettle();
    final remove = await tester.startGesture(tester.getCenter(chapter(2)));
    await tester.pump(const Duration(milliseconds: 600));
    await remove.moveTo(tester.getCenter(chapter(0)));
    await remove.up();
    await tester.pumpAndSettle();
    expect(find.text('共 30 章，已选 0 章'), findsOneWidget);
  });

  testWidgets('普通滑动滚动，长按靠边自动滚动；销毁停止ticker', (tester) async {
    await showPanel(tester, count: 120);
    final grid = find.byKey(const Key('chapter-download-grid'));
    final scrollable = tester.state<ScrollableState>(
        find.descendant(of: grid, matching: find.byType(Scrollable)).first);
    await tester.drag(grid, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));
    scrollable.position.jumpTo(0);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(chapter(0)));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture
        .moveTo(tester.getRect(grid).bottomCenter - const Offset(0, 4));
    await tester.pump(const Duration(milliseconds: 600));
    expect(scrollable.position.pixels, greaterThan(100));
    expect(
        tester
            .widget<Text>(find.byKey(const Key('chapter-download-count')))
            .data,
        isNot('共 120 章，已选 1 章'));
    await tester.pumpWidget(const SizedBox());
    await gesture.up();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('RTL、大字、窄屏与读屏动作仍能选择', (tester) async {
    final semantics = tester.ensureSemantics();
    await showPanel(tester,
        count: 5, direction: TextDirection.rtl, scale: 1.8, width: 320);
    final node = tester.getSemantics(chapter(0));
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pump();
    expect(selected(tester, 0), isTrue);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('sheet取消不入队；双开入口仅一个面板', (tester) async {
    var submitted = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      onPressed: () => showChapterDownloadSelection(context,
                          title: '作品',
                          chapterNames: const ['第一章', '第二章'],
                          identity: 'fake/1',
                          loadStatuses: () async => {},
                          onSubmit: (_) async {
                            submitted++;
                            return const Res(true);
                          }),
                      child: const Text('打开选章'),
                    )))));
    final open =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '打开选章'));
    open.onPressed!();
    open.onPressed!();
    await tester.pumpAndSettle();
    expect(find.byType(ChapterDownloadSelection), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(submitted, 0);
    expect(find.byType(ChapterDownloadSelection), findsNothing);
  });
}
