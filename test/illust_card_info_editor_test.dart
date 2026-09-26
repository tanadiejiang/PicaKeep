/// 插画卡片底部信息编辑器的**真实渲染契约**：勾选、拖拽排序、分隔符、预览。
///
/// ## 为什么走真实 `showDialog` 路由
///
/// 与 `pixiv_dir_name_template_editor_test.dart` 同一条理由（两者是同一套形态）：
/// `ReorderableListView` 放进 `AlertDialog` 时若没有确定高度，会抛**无界约束**
/// 异常 —— 那是典型的"看代码看不出来、一上真机就崩"。所以这里必须在真实路由里
/// 构造它，而不是把 `AlertDialog` 直接塞进树里。
///
/// 覆盖 32 号计划「验收标准 2」的"信息配置"一条：
/// - 默认值 = 标题 + 作者（与改动前观感一致）；
/// - 勾选/取消勾选、拖动排序都会经 `onChanged` 报出**当前顺序**；
/// - 一个字段都不勾时 `onChanged` 报空列表（宿主据此禁用「确定」）；
/// - 预览与真实渲染走同一条取值路径。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/illust_card_info_config.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart'
    show
        kPixivDirNamePreviewAuthor,
        kPixivDirNamePreviewPages,
        kPixivDirNamePreviewTitle;
import 'package:picakeep/pages/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 把编辑器放进**真实的 `showDialog` 路由**里。
Widget _hostWithDialog({
  List<String> initialFields = kDefaultIllustCardInfoFields,
  String initialSeparator = kDefaultIllustCardInfoSeparator,
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
                title: const Text('插画卡片底部信息'),
                content: SizedBox(
                  width: 380,
                  child: SingleChildScrollView(
                    child: IllustCardInfoEditor(
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

Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(find.text('打开弹窗'));
  await tester.pumpAndSettle();
}

/// 某个字段行的勾选框当前是否勾上。
bool _isChecked(WidgetTester tester, String key) {
  final row = find.byKey(ValueKey<String>('illust-card-info-field-$key'));
  final checkbox = tester.widget<Checkbox>(
    find.descendant(of: row, matching: find.byType(Checkbox)),
  );
  return checkbox.value ?? false;
}

/// 点某个字段行切换勾选态。
Future<void> _toggle(WidgetTester tester, String key) async {
  await tester.tap(
    find.byKey(ValueKey<String>('illust-card-info-field-$key')),
  );
  await tester.pumpAndSettle();
}

/// 长按后向下拖过一行。
///
/// `ReorderableDelayedDragStartListener` 要求**先长按**才进入拖动，
/// 所以不能直接用 `tester.drag`。
Future<void> _longPressDragDownOneRow(
  WidgetTester tester,
  String label,
) async {
  await _longPressDragByRow(tester, label, 1);
}

/// 长按后向上拖过一行（与向下拖是两条不同的索引修正路径，都要覆盖）。
Future<void> _longPressDragUpOneRow(
  WidgetTester tester,
  String label,
) async {
  await _longPressDragByRow(tester, label, -1);
}

/// 长按后沿纵轴拖过 [rows] 行。
///
/// 位移分步 pump：`ReorderableListView` 的落点判定要靠中间帧，
/// 一次性跳到位会被当成"没经过中间位置"。
Future<void> _longPressDragByRow(
  WidgetTester tester,
  String label,
  int rows,
) async {
  final start = tester.getCenter(find.text(label));
  final gesture = await tester.startGesture(start);
  await tester.pump(kLongPressTimeout);
  await tester.pump(const Duration(milliseconds: 100));
  for (final step in <double>[0.25, 0.5, 0.75, 1.0]) {
    await gesture.moveTo(start + Offset(0, rows * 80 * step));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  group('初始态：勾选与顺序来自传入的配置', () {
    testWidgets('四个候选字段都列出来，各自带勾选框', (tester) async {
      await tester.pumpWidget(_hostWithDialog(onChanged: (_, __) {}));
      await _openDialog(tester);

      for (final key in kIllustCardInfoFieldKeys) {
        expect(
          find.byKey(ValueKey<String>('illust-card-info-field-$key')),
          findsOneWidget,
          reason: '$key 应该在候选列表里',
        );
        expect(
          find.descendant(
            of: find.byKey(ValueKey<String>('illust-card-info-field-$key')),
            matching: find.byType(Checkbox),
          ),
          findsOneWidget,
        );
      }
      // 字段的中文名与变量名都要显示（用户要知道勾的是什么）
      expect(find.text('标题'), findsOneWidget);
      expect(find.text('{title}'), findsOneWidget);
      expect(find.text('页数'), findsOneWidget);
      expect(find.text('尺寸'), findsOneWidget);
      expect(find.text('{size}'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('默认配置：标题 + 作者勾上，页数 / 尺寸没勾', (tester) async {
      await tester.pumpWidget(_hostWithDialog(onChanged: (_, __) {}));
      await _openDialog(tester);

      expect(_isChecked(tester, 'title'), isTrue);
      expect(_isChecked(tester, 'author'), isTrue);
      expect(_isChecked(tester, 'pages'), isFalse);
      expect(_isChecked(tester, 'size'), isFalse);
    });

    testWidgets('默认预览显示"标题 + 换行 + 作者"（样例是真实形态的值）',
        (tester) async {
      await tester.pumpWidget(_hostWithDialog(onChanged: (_, __) {}));
      await _openDialog(tester);
      expect(
        find.text('$kPixivDirNamePreviewTitle\n'
            '$kPixivDirNamePreviewAuthor'),
        findsOneWidget,
      );
    });

    testWidgets('分隔符候选里"换行"默认选中，且带可读标签', (tester) async {
      await tester.pumpWidget(_hostWithDialog(onChanged: (_, __) {}));
      await _openDialog(tester);
      // 空串 / 空格 / 换行都看不出差别，所以必须给可读标签
      for (final label in <String>['换行', '空格', '无']) {
        expect(find.text(label), findsOneWidget);
      }
      final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
      final selected = chips.where((c) => c.selected).toList();
      expect(selected.length, 1);
      expect((selected.single.label as Text).data, '换行');
    });
  });

  group('勾选变化 → onChanged 报出当前字段（按列表顺序）', () {
    testWidgets('勾上「尺寸」→ 报出 [title, author, size]', (tester) async {
      final reported = <List<String>>[];
      await tester.pumpWidget(_hostWithDialog(
        onChanged: (fields, _) => reported.add(fields),
      ));
      await _openDialog(tester);
      await _toggle(tester, 'size');

      expect(reported.last, <String>['title', 'author', 'size']);
      expect(_isChecked(tester, 'size'), isTrue);
      // 预览跟着更新：勾了尺寸就能看到尺寸样例（预览是含换行的整段文本，
      // 所以要按整段断相等，不能用 find.text('1200×1600')）
      expect(
        find.text('$kPixivDirNamePreviewTitle\n$kPixivDirNamePreviewAuthor\n'
            '$kIllustCardInfoPreviewSize'),
        findsOneWidget,
      );
    });

    testWidgets('取消勾选「作者」→ 报出 [title]，且位置不被挤掉',
        (tester) async {
      final reported = <List<String>>[];
      await tester.pumpWidget(_hostWithDialog(
        onChanged: (fields, _) => reported.add(fields),
      ));
      await _openDialog(tester);
      await _toggle(tester, 'author');

      expect(reported.last, <String>['title']);
      expect(_isChecked(tester, 'author'), isFalse);
      // 取消勾选只改勾选态、**不动位置**：重新勾上还应在标题后面
      await _toggle(tester, 'author');
      expect(reported.last, <String>['title', 'author']);
    });

    testWidgets('一个字段都不勾 → 报空列表，并给出错误提示（宿主据此拦截保存）',
        (tester) async {
      final reported = <List<String>>[];
      await tester.pumpWidget(_hostWithDialog(
        onChanged: (fields, _) => reported.add(fields),
      ));
      await _openDialog(tester);
      await _toggle(tester, 'title');
      await _toggle(tester, 'author');

      expect(reported.last, isEmpty);
      expect(find.text('至少要勾选一个字段。'), findsOneWidget);
      expect(find.text('（未勾选任何字段）'), findsOneWidget);
    });

    testWidgets('勾选顺序决定报出顺序：先取消全部、再按 尺寸→标题 勾',
        (tester) async {
      final reported = <List<String>>[];
      await tester.pumpWidget(_hostWithDialog(
        onChanged: (fields, _) => reported.add(fields),
      ));
      await _openDialog(tester);
      await _toggle(tester, 'title');
      await _toggle(tester, 'author');
      // 列表初始顺序是 [title, author, pages, size]，
      // 所以"先勾 size 再勾 title"报出的顺序仍是 [title, size]（按列表顺序）。
      await _toggle(tester, 'size');
      await _toggle(tester, 'title');
      expect(reported.last, <String>['title', 'size']);
    });

    testWidgets('分隔符切换 → 报出的字段不变、分隔符变', (tester) async {
      final separators = <String>[];
      await tester.pumpWidget(_hostWithDialog(
        onChanged: (fields, separator) => separators.add(separator),
      ));
      await _openDialog(tester);
      await tester.tap(find.text('空格'));
      await tester.pumpAndSettle();
      expect(separators.last, ' ');
      // 预览跟着变成同一行
      expect(
        find.text('$kPixivDirNamePreviewTitle '
            '$kPixivDirNamePreviewAuthor'),
        findsOneWidget,
      );
      await tester.tap(find.text('无'));
      await tester.pumpAndSettle();
      expect(separators.last, '');
    });
  });

  group('拖拽排序：真的能拖，且报出的顺序跟着变', () {
    testWidgets('把「标题」向下拖过一行 → 报出 [author, title, pages, size]',
        (tester) async {
      final reported = <List<String>>[];
      // 初始勾上全部四个，避免"拖动目标行没勾选"的干扰
      await tester.pumpWidget(_hostWithDialog(
        initialFields: kIllustCardInfoFieldKeys,
        onChanged: (fields, _) => reported.add(fields),
      ));
      await _openDialog(tester);

      // 初始顺序 [title, author, pages, size]；标题下移一行 = 与作者换位。
      await _longPressDragDownOneRow(tester, '标题');
      expect(
        reported.last,
        <String>['author', 'title', 'pages', 'size'],
        reason: 'ReorderableListView 的 newIndex 是"移除该项之前的目标位置"，'
            '向下拖必须减一。少了那一减，这里会变成 [author, pages, title, size]'
            '（多走一格）或 [author, title, pages, size] 之外的顺序',
      );
    });

    testWidgets('把「尺寸」向上拖过一行 → 报出 [title, author, size, pages]',
        (tester) async {
      final reported = <List<String>>[];
      await tester.pumpWidget(_hostWithDialog(
        initialFields: kIllustCardInfoFieldKeys,
        onChanged: (fields, _) => reported.add(fields),
      ));
      await _openDialog(tester);

      await _longPressDragUpOneRow(tester, '尺寸');
      expect(reported.last, <String>['title', 'author', 'size', 'pages']);
    });

    testWidgets('拖动后预览顺序跟着变（预览用的是报出的顺序）', (tester) async {
      final reported = <List<String>>[];
      await tester.pumpWidget(_hostWithDialog(
        initialFields: kIllustCardInfoFieldKeys,
        onChanged: (fields, _) => reported.add(fields),
      ));
      await _openDialog(tester);
      await _longPressDragDownOneRow(tester, '标题');
      expect(reported.last, <String>['author', 'title', 'pages', 'size']);
      // 预览按新顺序渲染：作者在第一行。
      // 页数样例是 `p3`（33 号起与下载命名同口径，见 `pixivPagesSuffix`）。
      expect(
        find.text('$kPixivDirNamePreviewAuthor\n$kPixivDirNamePreviewTitle\n'
            'p$kPixivDirNamePreviewPages\n$kIllustCardInfoPreviewSize'),
        findsOneWidget,
      );
    });

    testWidgets('拖动过程中不抛异常（弹窗里有确定高度，约束是有界的）',
        (tester) async {
      await tester.pumpWidget(_hostWithDialog(
        initialFields: kIllustCardInfoFieldKeys,
        onChanged: (_, __) {},
      ));
      await _openDialog(tester);
      await _longPressDragDownOneRow(tester, '页数');
      expect(tester.takeException(), isNull);
    });

    testWidgets('重新打开弹窗时，上次报出的字段与顺序成为初始态', (tester) async {
      // 模拟宿主的编排：把 onChanged 的结果当成下次的 initial*
      var fields = <String>['size', 'title'];
      var separator = ' - ';
      Widget host() => _hostWithDialog(
            initialFields: fields,
            initialSeparator: separator,
            onChanged: (f, s) {
              fields = f;
              separator = s;
            },
          );
      await tester.pumpWidget(host());
      await _openDialog(tester);

      expect(_isChecked(tester, 'size'), isTrue);
      expect(_isChecked(tester, 'title'), isTrue);
      expect(_isChecked(tester, 'author'), isFalse);
      // 候选列表顺序 = 已勾选在前（保持用户排好的顺序）
      final sizeRow = tester.getTopLeft(
        find.byKey(const ValueKey<String>('illust-card-info-field-size')),
      );
      final titleRow = tester.getTopLeft(
        find.byKey(const ValueKey<String>('illust-card-info-field-title')),
      );
      expect(sizeRow.dy, lessThan(titleRow.dy));
      // 历史值里手写的分隔符（不在候选内）被保留成额外选项
      expect(find.text(' - '), findsOneWidget);
      // 预览按 [size, title] 顺序渲染
      expect(
        find.text('$kIllustCardInfoPreviewSize - $kPixivDirNamePreviewTitle'),
        findsOneWidget,
      );
    });
  });

  group('设置入口：真的写进 settings[158]，并通知图集页刷新', () {
    late String original;

    setUp(() {
      // 弹窗的「确定」会 `await appdata.updateSettings()`，它内部要走
      // `SharedPreferences.getInstance()`。测试环境下不 mock 这个通道，
      // 那句 await 永远不完成 —— **await 之后的通知就不会发生**，
      // 症状是"设置写进去了但页面不刷新"（本组用例正是为了守住它）。
      SharedPreferences.setMockInitialValues(<String, Object>{});
      original = appdata.settings[illustCardInfoSettingIndex];
    });

    tearDown(() {
      appdata.settings[illustCardInfoSettingIndex] = original;
    });

    /// 把真实的「浏览」设置页挂起来（入口就在「插画列表」分区里）。
    ///
    /// 视口刻意开得**很高**（400 × 2400）：整页设置项一次全部落在屏幕内，
    /// 不需要滚动就点得到「卡片底部信息」。这是必要的 —— 设置页本体是
    /// `SingleChildScrollView` + 横滑分页，`ensureVisible` 之后的坐标会落在
    /// 横滑手势区上，`tap` 会"命中不到"（实测 warnIfMissed 警告）。
    Widget settingsHost() {
      return const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(400, 2400)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                child: SettingsPage(initialPage: 0),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> setTallScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
    }

    /// 打开「卡片底部信息」弹窗。
    Future<void> openTileDialog(WidgetTester tester) async {
      await tester.pumpWidget(settingsHost());
      await tester.pump();
      expect(find.text('卡片底部信息'), findsOneWidget);
      await tester.tap(find.text('卡片底部信息'), warnIfMissed: false);
      await tester.pumpAndSettle();
    }

    testWidgets('用户路径：点入口 → 勾字段 → 确定 → 写入设置并发出刷新通知',
        (tester) async {
      await setTallScreen(tester);
      appdata.settings[illustCardInfoSettingIndex] =
          kDefaultIllustCardInfoTemplate;
      var notified = 0;
      void listener() => notified++;
      App.displaySettingsVersion.addListener(listener);
      addTearDown(
        () => App.displaySettingsVersion.removeListener(listener),
      );

      await tester.pumpWidget(settingsHost());
      await tester.pump();

      // 1. 分区里的入口
      expect(find.text('卡片底部信息'), findsOneWidget);
      await tester.tap(find.text('卡片底部信息'));
      await tester.pumpAndSettle();

      // 2. 弹窗打开，默认勾的是标题 + 作者
      expect(find.text('插画卡片底部信息'), findsWidgets);
      expect(_isChecked(tester, 'title'), isTrue);
      expect(_isChecked(tester, 'author'), isTrue);
      expect(_isChecked(tester, 'size'), isFalse);

      // 3. 勾上「尺寸」
      await _toggle(tester, 'size');

      // 4. 确定
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(
        appdata.settings[illustCardInfoSettingIndex],
        buildIllustCardInfoTemplate(
          <String>['title', 'author', 'size'],
          kDefaultIllustCardInfoSeparator,
        ),
      );
      // 5. **关键**：必须通知。设置页是非 opaque 路由，pop 回图集页不会重建，
      //    不通知的话用户看到的是"改了没用"（实测数据见
      //    `foundation/app.dart` 的 displaySettingsVersion 注释）。
      expect(
        notified,
        greaterThan(0),
        reason: '保存后必须发出显示设置变更通知，否则图集页不会重建',
      );
      // 弹窗已关闭
      expect(find.text('插画卡片底部信息'), findsNothing);
    });

    testWidgets('点「取消」不写盘、也不通知', (tester) async {
      await setTallScreen(tester);
      appdata.settings[illustCardInfoSettingIndex] =
          kDefaultIllustCardInfoTemplate;
      var notified = 0;
      void listener() => notified++;
      App.displaySettingsVersion.addListener(listener);
      addTearDown(
        () => App.displaySettingsVersion.removeListener(listener),
      );

      await openTileDialog(tester);
      await _toggle(tester, 'size');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(
        appdata.settings[illustCardInfoSettingIndex],
        kDefaultIllustCardInfoTemplate,
        reason: '取消不该改设置',
      );
      expect(notified, 0);
    });

    testWidgets('一个字段都不勾时「确定」不可用（不能把设置写坏）', (tester) async {
      await setTallScreen(tester);
      appdata.settings[illustCardInfoSettingIndex] =
          kDefaultIllustCardInfoTemplate;
      await openTileDialog(tester);

      await _toggle(tester, 'title');
      await _toggle(tester, 'author');

      final confirm = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '确定'),
      );
      expect(confirm.onPressed, isNull);
      expect(find.text('至少要勾选一个字段。'), findsOneWidget);
    });
  });
}
