/// 设置页**分区主分割线**的真实布局断言。
///
/// ## 需求与实现方式
///
/// 用户真机反馈：「设置页的每个分区没有主要的分割线，需要增加」。
/// 实现放在 `buildTwoColumnLayout` —— 它已经是**所有**设置分页的统一外壳，
/// 而 `SettingsTitle` 的语义就是"从这里开始是新分区"，所以规则是：
/// 「`SettingsTitle` 之前画一条主分割线，列表首个除外」。
///
/// ## 为什么必须有布局断言
///
/// 这条规则有**两个**都可能出错的边界，而且都不会报错：
/// 1. 首个 `SettingsTitle` 之前不该有线（否则页面顶部凭空多一条）；
/// 2. 已经有线的页面不能变成**两条线**（下载设置原来在 `SettingsTitle` 前手写了
///    `Divider`，本轮删掉了那两条）。
///
/// 另外还要证明它**真的作用到了生产页面**，而不只是 `buildTwoColumnLayout` 自己
/// 玩得转 —— 所以下面既测纯布局，也渲染真实的 `SettingsPage` 数线。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/pages/settings/settings_common_widgets.dart';
import 'package:picakeep/pages/settings/settings_page.dart';

/// 36 号起「Pixiv 专属下载目录」那一项要读 `App.dataPath` 才能算出生效路径
/// （默认根是 `<数据目录>/download_pixiv`），而 `App.dataPath` 是 `late` 变量
/// —— 不初始化 App 就渲染设置页会直接抛 `LateInitializationError`。
/// 下面这两个 mock 是最小代价的修法（与 `pixiv_download_root_test.dart` 同款）。
class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final Directory root;

  Future<String> _dir(String name) async =>
      (await Directory(p.join(root.path, name)).create(recursive: true)).path;

  @override
  Future<String?> getApplicationCachePath() => _dir('cache');

  @override
  Future<String?> getApplicationSupportPath() => _dir('support');
}

/// 把设置页的某一分页挂起来（与 `settings_about_page_test.dart` 同一套挂法）。
Widget _settingsPage({required int page}) {
  return MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(size: Size(360, 800)),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 360,
            child: SettingsPage(initialPage: page),
          ),
        ),
      ),
    ),
  );
}

/// 逐条取分割线的矩形。
///
/// 不能写 `find.byWidget(element.widget)`：`SettingsSectionDivider` 是 const 构造，
/// 所有实例相等，那个 finder 会一次匹配到全部 7 条（实测报 "ambiguously found
/// multiple matching widgets"）。按**下标**取才是单实例。
List<Rect> _dividerRects(WidgetTester tester) {
  final finder = find.byType(SettingsSectionDivider);
  final count = finder.evaluate().length;
  return <Rect>[
    for (var i = 0; i < count; i++) tester.getRect(finder.at(i)),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  late PathProviderPlatform savedPaths;
  late List<String> savedSettings;

  setUpAll(() async {
    savedPaths = PathProviderPlatform.instance;
    savedSettings = List.of(appdata.settings);
    workspace = await Directory.systemTemp.createTemp('picakeep_divider_');
    PathProviderPlatform.instance = _Paths(workspace);
    await App.init(dataPathOverride: p.join(workspace.path, 'data'));
  });

  tearDownAll(() async {
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    PathProviderPlatform.instance = savedPaths;
    try {
      await workspace.delete(recursive: true);
    } catch (_) {}
  });

  group('buildTwoColumnLayout：分区之间插主分割线', () {
    Widget layout(List<Widget> children) {
      return MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: buildTwoColumnLayout(360, children),
          ),
        ),
      );
    }

    testWidgets('每个分区标题之前一条线，**首个除外**', (tester) async {
      await tester.pumpWidget(layout(<Widget>[
        const SettingsTitle('一'),
        const ListTile(title: Text('项 1')),
        const SettingsTitle('二'),
        const ListTile(title: Text('项 2')),
        const SettingsTitle('三'),
      ]));
      await tester.pump();

      expect(find.byType(SettingsSectionDivider), findsNWidgets(2));
      expect(find.byType(SettingsTitle), findsNWidgets(3));

      // 首个标题**之上**没有线：它上面只有页面顶部。
      final firstTitleTop = tester.getTopLeft(find.text('一')).dy;
      for (final rect in _dividerRects(tester)) {
        expect(
          rect.top,
          greaterThan(firstTitleTop),
          reason: '不能有分割线出现在首个分区标题之上',
        );
      }
    });

    testWidgets('没有分区标题的页面不产生任何线（例如整页只有一组设置项）',
        (tester) async {
      await tester.pumpWidget(layout(<Widget>[
        const ListTile(title: Text('项 1')),
        const ListTile(title: Text('项 2')),
      ]));
      await tester.pump();
      expect(find.byType(SettingsSectionDivider), findsNothing);
    });

    testWidgets('线画在标题**之前**（在上面），不是在标题下面', (tester) async {
      await tester.pumpWidget(layout(<Widget>[
        const SettingsTitle('一'),
        const ListTile(title: Text('项 1')),
        const SettingsTitle('二'),
        const ListTile(title: Text('项 2')),
      ]));
      await tester.pump();

      final divider = tester.getRect(find.byType(SettingsSectionDivider));
      final secondTitle = tester.getRect(find.text('二'));
      final firstItem = tester.getRect(find.text('项 1'));
      expect(divider.top, greaterThan(firstItem.bottom));
      expect(divider.bottom, lessThanOrEqualTo(secondTitle.top + 0.5));
    });

    testWidgets('分割线比普通 Divider 更"重"（用户要的是主要分割线）',
        (tester) async {
      await tester.pumpWidget(layout(<Widget>[
        const SettingsTitle('一'),
        const ListTile(title: Text('项 1')),
        const SettingsTitle('二'),
      ]));
      await tester.pump();
      final divider = tester.widget<Divider>(
        find.descendant(
          of: find.byType(SettingsSectionDivider),
          matching: find.byType(Divider),
        ),
      );
      expect(divider.thickness, SettingsSectionDivider.thickness);
      expect(divider.thickness, greaterThan(1.0),
          reason: '默认为 1 的细线不足以表达"分区"，用户要的是主要分割线');
      expect(divider.color, isNotNull);
    });
  });

  group('「浏览」设置页：真实渲染，分区之间确有主分割线', () {
    testWidgets('8 个分区 → 7 条线，且每个分区标题（除首个）上面都有一条',
        (tester) async {
      await tester.pumpWidget(_settingsPage(page: 0));
      await tester.pump();

      const sectionTitles = <String>[
        '启动与运行',
        '列表与视图',
        '卡片显示',
        '插画列表',
        '在线浏览',
        '阅读器',
        '内容过滤',
        '其它',
      ];
      for (final title in sectionTitles) {
        expect(find.text(title), findsOneWidget, reason: '缺少分区「$title」');
      }

      final dividers = find.byType(SettingsSectionDivider);
      expect(dividers, findsNWidgets(sectionTitles.length - 1));

      final rects = _dividerRects(tester);
      // 逐条验证：除首个分区外，每个分区标题的正上方都有一条线，
      // 且**只**有一条（防止"两条紧挨着"的退化）。
      for (var i = 1; i < sectionTitles.length; i++) {
        final titleTop = tester.getTopLeft(find.text(sectionTitles[i])).dy;
        final above = rects.where(
          (rect) => rect.bottom <= titleTop + 0.5 && titleTop - rect.top < 40,
        );
        expect(
          above.length,
          1,
          reason: '「${sectionTitles[i]}」与上一条线之间应恰好有一条主分割线',
        );
      }

      // 首个分区标题之上没有线
      final firstTop = tester.getTopLeft(find.text(sectionTitles.first)).dy;
      for (final rect in rects) {
        expect(rect.top, greaterThan(firstTop));
      }
      // 线之间不重叠（不是"同一个位置画了两条"）
      for (var i = 1; i < rects.length; i++) {
        expect(rects[i].top, greaterThan(rects[i - 1].bottom - 0.5));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('勾选/排序入口在「插画列表」分区里（用户要的"和下载命名一样"）',
        (tester) async {
      await tester.pumpWidget(_settingsPage(page: 0));
      await tester.pump();
      expect(find.text('卡片底部信息'), findsOneWidget);
      expect(find.text('瀑布流列数'), findsOneWidget);
      expect(find.text('视图切换按钮位置'), findsOneWidget);
      // 入口在分区标题下方（属于「插画列表」这一区）
      final sectionTop = tester.getTopLeft(find.text('插画列表')).dy;
      final entryTop = tester.getTopLeft(find.text('卡片底部信息')).dy;
      expect(entryTop, greaterThan(sectionTop));
    });
  });

  group('「下载」设置页：分区线一并统一且不会变成两条', () {
    testWidgets('两个分区 → 恰好 2 条线（原来手写在标题前的细线已删掉）',
        (tester) async {
      await tester.pumpWidget(_settingsPage(page: 7));
      await tester.pump();

      expect(find.text('禁漫 (jm) 网络'), findsOneWidget);
      expect(find.text('Pixiv'), findsOneWidget);
      expect(find.byType(SettingsTitle), findsNWidgets(2));
      // 关键：不能是 4（原来那两条手写 Divider + 两条主分割线）
      expect(find.byType(SettingsSectionDivider), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });
}
