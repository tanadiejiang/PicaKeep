import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/pages/downloading/downloading_page.dart';

class _Queue extends OnlineDownloadManager {
  _Queue(this.items) : super.forTesting(downloadRoot: '');

  final List<OnlineDownloadTask> items;
  final pausedIds = <String>[];
  final resumedIds = <String>[];
  final cancelledIds = <String>[];
  final removedIds = <String>[];

  @override
  List<OnlineDownloadTask> get tasks => List.of(items);

  @override
  void pauseOne(String id) {
    pausedIds.add(id);
    items.firstWhere((task) => task.id == id).paused = true;
    version.value++;
  }

  @override
  void resumeOne(String id) {
    resumedIds.add(id);
    items.firstWhere((task) => task.id == id).paused = false;
    version.value++;
  }

  @override
  void cancelAll(List<String> ids) {
    cancelledIds.addAll(ids);
    for (final task in items.where((task) => ids.contains(task.id))) {
      task.cancelled = true;
    }
    version.value++;
  }

  @override
  void removeAll(List<String> ids) {
    removedIds.addAll(ids);
    items.removeWhere((task) => ids.contains(task.id));
    version.value++;
  }
}

OnlineDownloadTask _task(String id, String title) {
  return OnlineDownloadTask.picacg(
    comic: PicacgComicItem.fromApi(
      json: {'_id': id, 'title': title},
      eps: List.generate(44, (index) => '${index + 1}'),
      recommendation: const [],
    ),
  )
    ..totalEps = 44
    ..chapterIndexes = List.generate(12, (index) => index)
    ..currentEp = 2
    ..currentEpName = '02'
    ..totalPages = 10
    ..currentPage = 3;
}

void main() {
  testWidgets('long press selects the whole row and tapping empties selection',
      (tester) async {
    final manager = _Queue([
      _task('first', 'First queue item'),
      _task('second', 'Second queue item'),
    ]);
    addTearDown(manager.version.dispose);
    final theme = ThemeData(colorSchemeSeed: Colors.purple);
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: DownloadingPage(manager: manager),
    ));
    await tester.pumpAndSettle();
    expect(find.text('第 2/12 章：02'), findsNWidgets(2));

    await tester.longPress(find.text('First queue item'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 个项目'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byIcon(Icons.more_horiz), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(tester.widget<AppBar>(find.byType(AppBar)).backgroundColor,
        theme.colorScheme.primaryContainer);
    final overlay = find.byKey(const ValueKey('download-selection-first'));
    expect(overlay, findsOneWidget);
    expect(tester.getSize(overlay).width, greaterThan(300));

    await tester.tap(find.text('Second queue item'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 个项目'), findsOneWidget);
    await tester.tap(find.text('First queue item'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second queue item'));
    await tester.pumpAndSettle();
    expect(find.text('下载管理器'), findsOneWidget);
    expect(find.byIcon(Icons.more_horiz), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection menu preserves select all and task actions',
      (tester) async {
    final manager = _Queue([
      _task('first', 'First queue item'),
      _task('second', 'Second queue item'),
    ]);
    addTearDown(manager.version.dispose);
    await tester.pumpWidget(MaterialApp(
      home: DownloadingPage(manager: manager),
    ));
    await tester.pumpAndSettle();

    Future<void> choose(String label) async {
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    await tester.longPress(find.text('First queue item'));
    await tester.pumpAndSettle();
    await choose('全选');
    expect(find.text('已选择 2 个项目'), findsOneWidget);
    await choose('暂停所选');
    expect(manager.pausedIds, ['first', 'second']);
    expect(find.text('下载管理器'), findsOneWidget);

    await tester.longPress(find.text('First queue item'));
    await tester.pumpAndSettle();
    await choose('继续所选');
    expect(manager.resumedIds, ['first']);
    await tester.longPress(find.text('First queue item'));
    await tester.pumpAndSettle();
    await choose('取消所选');
    expect(manager.cancelledIds, ['first']);
    await tester.longPress(find.text('First queue item'));
    await tester.pumpAndSettle();
    await choose('从列表移除');
    expect(manager.removedIds, ['first']);
    expect(find.text('First queue item'), findsNothing);
    expect(find.text('Second queue item'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
