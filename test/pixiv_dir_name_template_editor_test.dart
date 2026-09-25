import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart';
import 'package:picakeep/pages/settings/settings_page.dart';

/// 把编辑器放进**真实的 `showDialog` 路由**里。
///
/// 这正是本模块最容易出事、也最必须实测的场景：`ReorderableListView` 放进
/// `AlertDialog` 时若没有确定高度，会抛无界约束异常 —— 而那属于"看代码看不出来、
/// 一上真机就崩"的问题。所以这里走真实路由，而不是把 `AlertDialog` 直接塞进树里。
Widget _hostWithDialog({
  List<String> initialFields = const <String>['title'],
  String initialSeparator = '-',
  required void Function(List<String> fields, String separator) onChanged,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Pixiv 下载目录名模板'),
                content: SizedBox(
                  width: 380,
                  child: SingleChildScrollView(
                    child: PixivDirNameTemplateEditor(
                      initialFields: initialFields,
                      initialSeparator: initialSeparator,
                      onChanged: onChanged,
                    ),
                  ),
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
            child: const Text('打开弹窗'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  /// 长按后向下拖过一行。`ReorderableDelayedDragStartListener` 要求**先长按**
  /// 才进入拖动，所以不能直接用 `tester.drag`。
  Future<void> longPressDragDownOneRow(
    WidgetTester tester,
    String label,
  ) async {
    final start = tester.getCenter(find.text(label));
    final gesture = await tester.startGesture(start);
    // 长按期满才会进入拖动（DelayedMultiDragGestureRecognizer）。
    await tester.pump(kLongPressTimeout);
    await tester.pump(const Duration(milliseconds: 100));
    // 用绝对坐标分步下移：位移要跨过一行（卡片高 + 6 间距约 62dp），
    // 且必须分步 pump，否则落点判定拿不到中间位置。
    for (final dy in <double>[20, 40, 60, 80]) {
      await gesture.moveTo(start + Offset(0, dy));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  group('reorderPixivDirNameFieldOrder · 索引修正', () {
    test('向下拖：newIndex 需减一，否则差一位', () {
      // onReorder(0, 2) 的语义是"把 a 移到 c 之前"⇒ 未修正会得到 ['b','c','a']（错）
      expect(
        reorderPixivDirNameFieldOrder(<String>['a', 'b', 'c'], 0, 2),
        <String>['b', 'a', 'c'],
      );
    });

    test('向下拖到最末', () {
      expect(
        reorderPixivDirNameFieldOrder(<String>['a', 'b', 'c'], 0, 3),
        <String>['b', 'c', 'a'],
      );
    });

    test('向上拖：newIndex 不减', () {
      expect(
        reorderPixivDirNameFieldOrder(<String>['a', 'b', 'c'], 2, 0),
        <String>['c', 'a', 'b'],
      );
    });

    test('向上拖一格', () {
      expect(
        reorderPixivDirNameFieldOrder(<String>['a', 'b', 'c'], 2, 1),
        <String>['a', 'c', 'b'],
      );
    });

    test('oldIndex == newIndex 时顺序不变', () {
      expect(
        reorderPixivDirNameFieldOrder(<String>['a', 'b', 'c'], 1, 1),
        <String>['a', 'b', 'c'],
      );
    });

    test('单元素列表不变', () {
      expect(
        reorderPixivDirNameFieldOrder(<String>['a'], 0, 0),
        <String>['a'],
      );
    });

    test('不修改传入的列表（纯函数）', () {
      final original = <String>['a', 'b', 'c'];
      reorderPixivDirNameFieldOrder(original, 0, 3);
      expect(original, <String>['a', 'b', 'c']);
    });
  });

  group('pixivDirNameTemplatePreview', () {
    test('单字段只输出该字段', () {
      expect(pixivDirNameTemplatePreview(<String>['title'], '-'), '夜の海');
    });

    test('多字段按顺序与分隔符拼接', () {
      expect(
        pixivDirNameTemplatePreview(<String>['title', 'author', 'id'], '-'),
        '夜の海-久蒼穹-150033282',
      );
    });

    test('顺序变化会体现在预览里', () {
      expect(
        pixivDirNameTemplatePreview(<String>['author', 'title'], '-'),
        '久蒼穹-夜の海',
      );
    });

    test('空字段列表返回空串（不落到默认模板兜底）', () {
      expect(pixivDirNameTemplatePreview(<String>[], '-'), '');
    });

    test('勾了页数时预览里能看到 p3（预览走与落盘同一条渲染路径）', () {
      expect(
        pixivDirNameTemplatePreview(<String>['title', 'pages'], '_'),
        '夜の海_p$kPixivDirNamePreviewPages',
      );
      expect(kPixivDirNamePreviewPages, greaterThan(1));
    });
  });

  group('PixivDirNameTemplateEditor · 弹窗内实际可渲染（无界约束验证）', () {
    testWidgets('在真实 showDialog 路由里打开不抛异常', (tester) async {
      await tester.pumpWidget(
        _hostWithDialog(onChanged: (_, __) {}),
      );
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      // 能走到这里说明 AlertDialog + SizedBox + ReorderableListView 的组合成立
      expect(tester.takeException(), isNull);
      expect(find.byType(PixivDirNameTemplateEditor), findsOneWidget);
      expect(find.byType(ReorderableListView), findsOneWidget);
    });

    testWidgets('三个字段行与各自的变量名都渲染出来', (tester) async {
      await tester.pumpWidget(_hostWithDialog(onChanged: (_, __) {}));
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      expect(find.text('标题'), findsOneWidget);
      expect(find.text('作者'), findsOneWidget);
      expect(find.text('作品 ID'), findsOneWidget);
      expect(find.text('{title}'), findsOneWidget);
      expect(find.text('{author}'), findsOneWidget);
      expect(find.text('{id}'), findsOneWidget);
    });

    testWidgets('页数字段也在可选列表里（勾选式 UI 靠字段表自动长出这一行）', (tester) async {
      await tester.pumpWidget(_hostWithDialog(onChanged: (_, __) {}));
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      expect(find.text('页数'), findsOneWidget);
      expect(find.text('{pages}'), findsOneWidget);
    });

    testWidgets('勾选页数后回调报出 pages，预览里出现 p3', (tester) async {
      List<String>? reportedFields;
      await tester.pumpWidget(
        _hostWithDialog(
          onChanged: (fields, _) => reportedFields = fields,
        ),
      );
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('页数'));
      await tester.pumpAndSettle();

      expect(reportedFields, <String>['title', 'pages']);
      expect(find.text('夜の海-p3'), findsOneWidget);
    });

    testWidgets('窄屏（320dp）下也不溢出', (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_hostWithDialog(onChanged: (_, __) {}));
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('PixivDirNameTemplateEditor · 勾选与预览', () {
    testWidgets('默认只勾 title，预览为示例标题', (tester) async {
      await tester.pumpWidget(_hostWithDialog(onChanged: (_, __) {}));
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      expect(find.text('夜の海'), findsOneWidget);
    });

    testWidgets('勾选作者后回调报出 [title, author] 且预览跟着变', (tester) async {
      List<String>? reportedFields;
      String? reportedSeparator;
      await tester.pumpWidget(
        _hostWithDialog(
          onChanged: (fields, separator) {
            reportedFields = fields;
            reportedSeparator = separator;
          },
        ),
      );
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('作者'));
      await tester.pumpAndSettle();

      expect(reportedFields, <String>['title', 'author']);
      expect(reportedSeparator, '-');
      expect(find.text('夜の海-久蒼穹'), findsOneWidget);
    });

    testWidgets('取消勾选 title 后只剩 author，且位置信息不丢', (tester) async {
      List<String>? reportedFields;
      await tester.pumpWidget(
        _hostWithDialog(
          initialFields: const <String>['title', 'author'],
          onChanged: (fields, _) => reportedFields = fields,
        ),
      );
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('标题'));
      await tester.pumpAndSettle();

      expect(reportedFields, <String>['author']);
      // 三个字段行都还在（未勾选的只是取消勾选、不从列表里消失）
      expect(find.text('标题'), findsOneWidget);
      expect(find.text('作者'), findsOneWidget);
      expect(find.text('作品 ID'), findsOneWidget);
    });

    testWidgets('一个都没勾时显示占位与错误提示', (tester) async {
      await tester.pumpWidget(
        _hostWithDialog(onChanged: (_, __) {}),
      );
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('标题'));
      await tester.pumpAndSettle();

      expect(find.text('（未勾选任何字段）'), findsOneWidget);
      expect(find.text('至少要勾选一个字段。'), findsOneWidget);
      expect(find.text('夜の海'), findsNothing);
    });

    testWidgets('初始顺序按传入的字段顺序排列', (tester) async {
      List<String>? reportedFields;
      await tester.pumpWidget(
        _hostWithDialog(
          initialFields: const <String>['author', 'title'],
          onChanged: (fields, _) => reportedFields = fields,
        ),
      );
      // 初始回调不会自动触发；先点一下分隔符触发一次 _emit
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('_'));
      await tester.pumpAndSettle();

      expect(reportedFields, <String>['author', 'title']);
    });
  });

  group('PixivDirNameTemplateEditor · 分隔符', () {
    testWidgets('点分隔符 chip 后回调报出该分隔符，预览跟着变', (tester) async {
      String? reportedSeparator;
      await tester.pumpWidget(
        _hostWithDialog(
          initialFields: const <String>['title', 'author'],
          onChanged: (_, separator) => reportedSeparator = separator,
        ),
      );
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('_'));
      await tester.pumpAndSettle();

      expect(reportedSeparator, '_');
      expect(find.text('夜の海_久蒼穹'), findsOneWidget);
    });

    testWidgets('空分隔符显示为「无」，选中后字段相邻', (tester) async {
      String? reportedSeparator;
      await tester.pumpWidget(
        _hostWithDialog(
          initialFields: const <String>['title', 'author'],
          onChanged: (_, separator) => reportedSeparator = separator,
        ),
      );
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('无'));
      await tester.pumpAndSettle();

      expect(reportedSeparator, '');
      expect(find.text('夜の海久蒼穹'), findsOneWidget);
    });

    testWidgets('空格分隔符显示为「空格」', (tester) async {
      await tester.pumpWidget(_hostWithDialog(onChanged: (_, __) {}));
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      expect(find.text('空格'), findsOneWidget);
    });

    testWidgets('历史值里的非候选分隔符会作为额外选项出现，不被丢弃', (tester) async {
      await tester.pumpWidget(
        _hostWithDialog(
          initialFields: const <String>['title', 'author'],
          initialSeparator: ' · ',
          onChanged: (_, __) {},
        ),
      );
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      expect(find.text(' · '), findsOneWidget);
    });
  });

  group('PixivDirNameTemplateEditor · 连续拖动（回归：只能拖一次）', () {
    // 真机反馈："长按拖动只能拖动一次"。
    // 根因是 onReorder 里用 `_order..clear()..addAll(...)` **原地修改**同一个 List
    // 实例 —— `ReorderableListView` 依赖 children 列表被换成新实例来重建，
    // 原地改会让它只生效一次。修法是整列表替换。
    testWidgets('连续两次长按拖动都生效', (tester) async {
      List<String>? reported;
      await tester.pumpWidget(
        _hostWithDialog(
          initialFields: const <String>['title', 'author', 'id'],
          onChanged: (fields, _) => reported = fields,
        ),
      );
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      await longPressDragDownOneRow(tester, '标题');
      expect(
        reported,
        <String>['author', 'title', 'id'],
        reason: '第一次拖动就应把「标题」下移一位',
      );

      await longPressDragDownOneRow(tester, '标题');
      expect(
        reported,
        <String>['author', 'id', 'title'],
        reason: '第二次拖动必须同样生效（这正是真机上失效的那一步）',
      );
    });

    testWidgets('拖动未勾选的字段不会改变勾选集', (tester) async {
      List<String>? reported;
      await tester.pumpWidget(
        _hostWithDialog(
          // 只勾 title —— author 未勾选，但仍在列表里占位。
          initialFields: const <String>['title'],
          onChanged: (fields, _) => reported = fields,
        ),
      );
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      // 把未勾选的「作者」拖到第一位：勾选集应仍只有 title。
      await longPressDragDownOneRow(tester, '作者');
      expect(reported, <String>['title']);
    });
  });
}
