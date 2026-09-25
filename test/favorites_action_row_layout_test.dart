/// 本地收藏页操作区的布局契约：五个按钮必须排在同一行。
///
/// ## 为什么有这个文件
///
/// 真机反馈：这一行的五个按钮里，最后一个「更新卡片信息」被挤到了第二行。
/// 换行与否取决于「条目宽度 × 条目数 + 间隔 + 页面内边距」与屏幕宽度的算术
/// 关系，靠看代码估宽度不可靠，所以这里在几种常见手机逻辑宽度下直接量布局
/// 结果，而不是截图比对：
///
/// 1. 整行高度必须等于单行高度 —— 折行会立刻变成两行高；
/// 2. 五个文案的垂直中心必须一致 —— 掉到第二行会差出一整行高度；
/// 3. 同一排的文案必须都是单行 —— 字高一致即行数一致（与字体度量无关），
///    文案折成两行会让图标与同排其它按钮错位；
/// 4. 每个按钮的可点区域不得小于 [minTapTarget]。
///
/// 与 `test/ui_preview/directory_browser_actions_preview_test.dart` 同类：断言
/// 的是布局结果而非像素值，因此**不需要加载中文字体**（缺字形只影响观感，
/// 不影响位置）。
///
/// ⚠️ 这里复刻了页面上那五个按钮的文案；`main_favorites_page.dart` 里改了
/// 文案，这个文件的 [_localActions] 要一起改，否则契约失效。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/favorites/main_favorites_page.dart';

/// 要覆盖的手机逻辑宽度（dp）。
///
/// 320 是老小屏，360 是主流下限，393/412 覆盖 Pixel 与多数国产机。
/// 五个按钮都要在这些宽度下保持单行：条目宽度按可用宽度均分，最窄的
/// 320 dp 下每个仍有 52 dp。
const List<double> _screenWidths = <double>[320, 360, 393, 412];

/// 收藏页操作区左右各 12 dp 的内边距（与页面里的 `Padding` 一致）。
const double _pageHorizontalPadding = 12;

/// 单个按钮的最小可点区域（一边）。
const double minTapTarget = 40;

/// 一个操作按钮的文案配置（图标 + 文案 + 可选 tooltip）。
class _ActionSpec {
  const _ActionSpec({required this.icon, required this.label, this.tooltip});

  final IconData icon;
  final String label;
  final String? tooltip;
}

/// 本地收藏视图操作区的五个按钮（与页面里那五个条目一一对应）。
const List<_ActionSpec> _localActions = <_ActionSpec>[
  _ActionSpec(icon: Icons.create_new_folder_outlined, label: '新建'),
  _ActionSpec(icon: Icons.search, label: '搜索收藏'),
  _ActionSpec(icon: Icons.manage_search, label: '搜索全部'),
  _ActionSpec(icon: Icons.reorder, label: '排序'),
  // 文案为放下一行收成 4 个字，完整语义交给 tooltip。
  _ActionSpec(
    icon: Icons.cloud_sync_outlined,
    label: '更新信息',
    tooltip: '更新卡片信息',
  ),
];

/// 远程收藏视图操作区的两个按钮（只有两个，不应被拉宽）。
const List<_ActionSpec> _remoteActions = <_ActionSpec>[
  _ActionSpec(icon: Icons.create_new_folder_outlined, label: '新建'),
  _ActionSpec(icon: Icons.refresh, label: '重新加载'),
];

/// 把某个逻辑宽度固定给测试视图。
void _setScreenWidth(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width * 3, 400 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// 按页面里的同一份配置渲染操作区：外层是「左右各 12 dp 内边距」，
/// 与 `_buildFoldersDrawer` 里的结构一致（内边距算错会量出偏乐观的结果）。
Widget _buildRow(
  List<_ActionSpec> specs, {
  void Function(String label)? onTap,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _pageHorizontalPadding,
        ),
        child: FavoritesActionRow(
          actions: [
            for (final spec in specs)
              FavoritesActionItem(
                icon: spec.icon,
                label: spec.label,
                tooltip: spec.tooltip,
                onTap: () => onTap?.call(spec.label),
              ),
          ],
        ),
      ),
    ),
  );
}

double _rowHeight(WidgetTester tester) =>
    tester.getSize(find.byType(FavoritesActionRow)).height;

double _textCenterY(WidgetTester tester, String label) =>
    tester.getCenter(find.text(label)).dy;

void main() {
  group('操作区始终单行', () {
    for (final width in _screenWidths) {
      testWidgets('${width.toInt()} dp 屏幕五个按钮在同一行', (tester) async {
        _setScreenWidth(tester, width);

        await tester.pumpWidget(_buildRow(_localActions));
        await tester.pumpAndSettle();

        expect(
          _rowHeight(tester),
          closeTo(FavoritesActionRow.itemHeight, 1),
          reason: '${width.toInt()} dp 下操作区折成了多行',
        );

        final firstY = _textCenterY(tester, _localActions.first.label);
        for (final action in _localActions.skip(1)) {
          expect(
            _textCenterY(tester, action.label),
            closeTo(firstY, 1),
            reason: '${width.toInt()} dp 下「${action.label}」掉到了第二行',
          );
        }
      });
    }

    testWidgets('主流下限 360 dp 下同排文案都是单行，图标不会错位', (tester) async {
      _setScreenWidth(tester, 360);

      await tester.pumpWidget(_buildRow(_localActions));
      await tester.pumpAndSettle();

      // 「新建」只有两个字，任何字体度量下都不会折行，拿它当单行基准。
      final singleLineHeight = tester.getSize(find.text('新建')).height;
      for (final action in _localActions.skip(1)) {
        expect(
          tester.getSize(find.text(action.label)).height,
          closeTo(singleLineHeight, 0.5),
          reason: '「${action.label}」折成了两行，图标会和同排其它按钮错位',
        );
      }
    });

    testWidgets('360 dp 下有余量，不是刚好卡住', (tester) async {
      _setScreenWidth(tester, 360);

      await tester.pumpWidget(_buildRow(_localActions));
      await tester.pumpAndSettle();

      // 量的是五个条目加间隔的**总宽**，不是整行宽度：折行时整行宽度只是
      // 其中一排的宽度，会量出偏乐观的结果（一排四个也小于内容区宽度）。
      final items = find.byType(FavoritesActionItem);
      var used = FavoritesActionRow.spacing * (items.evaluate().length - 1);
      for (var i = 0; i < items.evaluate().length; i++) {
        used += tester.getSize(items.at(i)).width;
      }
      const available = 360 - _pageHorizontalPadding * 2;
      expect(
        used,
        lessThan(available),
        reason: '360 dp 内容区 $available dp，操作区已占 $used dp —— '
            '没有余量，字体度量一变就会折行',
      );
    });

    testWidgets('远程视图只有两个按钮，不会被拉宽', (tester) async {
      _setScreenWidth(tester, 412);

      await tester.pumpWidget(_buildRow(_remoteActions));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byType(FavoritesActionItem).first).width,
        closeTo(FavoritesActionRow.itemMaxWidth, 0.5),
        reason: '条目宽度应以原宽度 72 dp 封顶，均分逻辑不能把两个条目拉宽',
      );
    });
  });

  group('按钮仍可点', () {
    testWidgets('最窄的 320 dp 下可点区域也不小于 $minTapTarget dp', (tester) async {
      _setScreenWidth(tester, _screenWidths.first);

      await tester.pumpWidget(_buildRow(_localActions));
      await tester.pumpAndSettle();

      final itemCount = find.byType(FavoritesActionItem).evaluate().length;
      expect(itemCount, _localActions.length);
      for (var i = 0; i < itemCount; i++) {
        final size = tester.getSize(find.byType(FavoritesActionItem).at(i));
        expect(
          size.width,
          greaterThanOrEqualTo(minTapTarget),
          reason: '「${_localActions[i].label}」的可点宽度只剩 ${size.width} dp',
        );
        expect(size.height, greaterThanOrEqualTo(minTapTarget));
      }
    });

    testWidgets('点击每个按钮分别触发自己的回调', (tester) async {
      _setScreenWidth(tester, 360);

      final tapped = <String>[];
      await tester.pumpWidget(_buildRow(_localActions, onTap: tapped.add));
      await tester.pumpAndSettle();

      for (final action in _localActions) {
        await tester.tap(find.text(action.label));
        await tester.pump();
      }

      expect(
        tapped,
        _localActions.map((action) => action.label).toList(),
        reason: '按顺序点五个按钮应依次触发各自的回调',
      );
    });
  });
}
