/// 图集页顶栏的**真实渲染契约**（33 号立，36 号更新第 2 条）：
///
/// 1. **标题随「图集 / 插画」视图切换**（用户原话「顶部的画集标题应该随着按钮的
///    切换而切换」）。真机截图里内容已是插画、标题仍是「图集」，所以这条必须在
///    **真实页面**上断言 —— 标题的三条来源（视图 / `widget.title` / `albumOnly`）
///    互相覆盖，只测某一个函数看不出优先级对不对。
/// 2. **「资源库显示设置」按钮点击直达设置面板，档位折叠在面板里**。
///    33 号曾把档位三档与设置并进同一个弹出菜单，真机反馈暴露两个问题：
///    设置变成二级（要多点一次）、档位在远程不可用时整块不出现（用户找不到）。
///    下面那组用例把这两点都钉住。
///
/// 另外钉住一条宽度约束：工具栏只能容下 **4 个 action**。36 号撤回弹出菜单后
/// action 数量与 33 号持平（档位不再单独占一个图标位），所以这条算术没有变化。
library;

import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/pages/local_library_illust_switcher.dart';
import 'package:picakeep/pages/local_library_page.dart';
import 'package:sqlite3/open.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final Directory root;

  Future<String> directory(String name) async =>
      (await Directory(p.join(root.path, name)).create(recursive: true)).path;

  @override
  Future<String?> getApplicationCachePath() => directory('cache');
  @override
  Future<String?> getApplicationSupportPath() => directory('support');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open(
          p.join(Directory.current.path, 'windows', 'sqlite3.dll')));

  late Directory workspace;
  late Directory root;
  late List<String> savedSettings;
  late String savedMode;
  late PathProviderPlatform savedPaths;

  setUpAll(() async {
    savedSettings = List.of(appdata.settings);
    savedMode = managedDataSourceMode;
    savedPaths = PathProviderPlatform.instance;
    workspace = await Directory.systemTemp.createTemp('picakeep_pk33_page_');
    PathProviderPlatform.instance = _Paths(workspace);
    await App.init(dataPathOverride: p.join(workspace.path, 'data'));
  });

  setUp(() async {
    root = await Directory(p.join(workspace.path, 'root')).create();
    appdata.settings[22] = root.path;
    appdata.settings[localLibraryShowAllDatabaseRecordsSettingIndex] = '0';
    // 「仅显示图集」开：视图切换按钮才会出现（`shouldShowIllustViewSwitcher`），
    // 标题的"视图优先"那条分支也才会生效。
    appdata.settings[localLibraryAlbumOnlySettingIndex] = '1';
    appdata.settings[illustLibraryViewSettingIndex] = 'album';
    // 非客户端模式：`_checkRemoteAvailability()` 直接返回 false（不联网），
    // 于是 `_showSourceSelector` 为假 —— 这正是要验证的"远程不可用"形态。
    appdata.settings[appRuntimeModeSettingIndex] = appRuntimeModeServer;
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
  });

  tearDownAll(() async {
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    setManagedDataSourceMode(savedMode);
    PathProviderPlatform.instance = savedPaths;
    // 临时目录里的 sqlite 句柄可能还被缓存持着（Windows 上删除会报
    // "另一个程序正在使用此文件"）。删不掉就留着 —— 它在系统临时目录里，
    // 不该因为清理失败把一个已经通过的用例判红。
    try {
      await workspace.delete(recursive: true);
    } catch (_) {}
  });

  /// **按生产的方式**挂载：图集页是被 push 进来的（`me_page.dart:450-460`），
  /// 所以 AppBar 里那个返回按钮（48dp）**必须在场** —— 它就是标题宽度的
  /// 主要竞争者之一，`MaterialApp(home: ...)` 那种挂法会让 `canPop()` 为假、
  /// 悄悄多出 48dp，宽度用例就失去意义了。
  ///
  /// [albumOnlySetting] 是 `settings[94]`（"仅显示图集"）。它与
  /// `LocalLibraryPage.albumOnly` **或**起来决定生效的 `_isAlbumOnly`
  /// （`local_library_page.dart:755-757`），所以要测「资源库」形态时必须**两个都为假**。
  Future<void> pushPage(
    WidgetTester tester, {
    bool albumOnly = true,
    String? title,
    String albumOnlySetting = '1',
  }) async {
    appdata.settings[localLibraryAlbumOnlySettingIndex] = albumOnlySetting;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => LocalLibraryPage(
                        albumOnly: albumOnly,
                        title: title,
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // 首次加载走真实文件扫描（临时空目录），等它落地。
    await tester.pumpAndSettle();
  }

  /// **顶栏里**的那个标题（不是悬浮按钮上的档位名、也不是菜单项）。
  Finder appBarTitle(String text) => find.descendant(
        of: find.byType(SliverAppbar),
        matching: find.text(text),
      );

  group('标题随视图切换（33 号第 3 条）', () {
    testWidgets('从「我」页进图集页：初始「图集」→ 切插画 →「插画」→ 切回「图集」',
        (tester) async {
      // `title: '图集'` 就是「我」页传进来的那一份（`me_page.dart:454-457`）。
      // 这条用例同时守住"视图 > widget.title"这个优先级：
      // 若按"widget.title 优先"实现，切到插画后标题仍是「图集」= 真机截图里的症状。
      await pushPage(tester, albumOnly: true, title: '图集');
      expect(appBarTitle('图集'), findsOneWidget);

      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(illustViewOptionKey(IllustLibraryView.illust)));
      await tester.pumpAndSettle();

      expect(appBarTitle('插画'), findsOneWidget,
          reason: '切到插画视图后，顶部标题必须变成「插画」');
      expect(appBarTitle('图集'), findsNothing);

      // 切回图集：标题回到「图集」（与该页传进来的 title 逐字相同）。
      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(illustViewOptionKey(IllustLibraryView.album)));
      await tester.pumpAndSettle();
      expect(appBarTitle('图集'), findsOneWidget);
      expect(appBarTitle('插画'), findsNothing);
    });

    testWidgets('`widget.title` 仍优先于 `albumOnly`（既有分支没被破坏）',
        (tester) async {
      // 「远程 · 资源库」这类显式标题必须原样显示。它不是可切换视图的根列表
      // （`albumOnly` 为假），所以"视图"那条分支不会截走它。
      await pushPage(
        tester,
        albumOnly: false,
        albumOnlySetting: '0',
        title: '远程 · 资源库',
      );
      expect(appBarTitle('远程 · 资源库'), findsOneWidget);
      expect(appBarTitle('图集'), findsNothing);
      expect(appBarTitle('插画'), findsNothing);
    });

    testWidgets('没有显式 title 时仍按 albumOnly 落到「资源库」（既有兜底）',
        (tester) async {
      await pushPage(tester, albumOnly: false, albumOnlySetting: '0');
      expect(appBarTitle('资源库'), findsOneWidget);
    });
  });

  group('「资源库显示设置」入口与档位折叠区（36 号形态）', () {
    testWidgets('内容区顶部那行分段按钮已删除，设置入口在工具栏', (tester) async {
      await pushPage(tester, albumOnly: true, title: '图集');
      // `SegmentedButton` 的泛型参数是这个页面私有的枚举，测试里没法按类型精确匹配，
      // 所以用 `is` 判据（`SegmentedButton<X>` 是 `SegmentedButton` 的子类型）。
      expect(
        find.byWidgetPredicate((widget) => widget is SegmentedButton),
        findsNothing,
        reason: '档位不再是内容区顶部那行分段按钮',
      );
      expect(find.byIcon(Icons.tune), findsOneWidget);
      expect(find.byTooltip('资源库显示设置'), findsOneWidget);
    });

    testWidgets('点按钮**直接**打开设置面板 —— 不再有中间菜单（36 号修复点）',
        (tester) async {
      // 用户真机反馈原话：「为什么资源库设置的点击需要进到二级点击才会显示」。
      // 33 号把档位与设置并进同一个 `PopupMenuButton`，于是要先弹菜单、
      // 再点「资源库显示设置」那一项才进得去。
      await pushPage(tester, albumOnly: true, title: '图集');
      await tester.tap(find.byTooltip('资源库显示设置'));
      await tester.pumpAndSettle();

      expect(
        find.text('仅显示图集'),
        findsOneWidget,
        reason: '一次点击就要看到设置面板本身',
      );
      expect(find.text('视图切换按钮位置'), findsOneWidget);
    });

    testWidgets('档位三档**直接平铺**在面板里，不需要再展开一次（36 号第二轮）',
        (tester) async {
      // 用户真机反馈原话：「最好保持展开样式，不要折叠那三档」。
      // 第一轮实现的是 `ExpansionTile`（默认收起），这里钉住"一进面板就看到三档"。
      await pushPage(tester, albumOnly: true, title: '图集');
      await tester.tap(find.byTooltip('资源库显示设置'));
      await tester.pumpAndSettle();

      expect(find.text('档位'), findsOneWidget, reason: '小标题行要在场');
      expect(find.text('本地图集'), findsOneWidget);
      expect(find.text('聚合'), findsOneWidget);
      expect(
        find.text('远程 · 图集'),
        findsOneWidget,
        reason: '三档必须直接可见，不能藏在折叠区里',
      );
      expect(
        find.byType(ExpansionTile),
        findsNothing,
        reason: '档位区不该再有折叠控件',
      );
    });

    testWidgets('远程不可用 → 后两档置灰并写明原因（而不是消失）', (tester) async {
      await pushPage(tester, albumOnly: true, title: '图集');
      await tester.tap(find.byTooltip('资源库显示设置'));
      await tester.pumpAndSettle();

      // **这是 36 号与 33 号最关键的行为差异**：33 号在远程不可用时
      // 一个档位项都不显示（旧测试正是那么断言的），用户因此以为功能没了。
      expect(find.text('聚合'), findsOneWidget);
      expect(find.text('远程 · 图集'), findsOneWidget);
      expect(find.text('远程服务不可用'), findsNWidgets(2),
          reason: '聚合与远程两档各写明一次原因');
    });

    testWidgets('置灰的档位点不动：远程不可用时点「远程」不会切档', (tester) async {
      await pushPage(tester, albumOnly: true, title: '图集');
      await tester.tap(find.byTooltip('资源库显示设置'));
      await tester.pumpAndSettle();

      // `settings[104]` 是档位的持久化位置（`_setView` 写它）。
      final before = appdata.settings[localLibraryViewSettingIndex];
      await tester.tap(find.text('远程 · 图集'));
      await tester.pumpAndSettle();

      expect(
        appdata.settings[localLibraryViewSettingIndex],
        before,
        reason: '置灰的档位点不动：不该写设置，更不该换数据源',
      );
      // 弹窗仍在（没有被"切档 → 关弹窗"带走）。
      expect(find.text('仅显示图集'), findsOneWidget);
    });
  });

  group('工具栏宽度：只能容下 4 个 action（窄屏不被挤爆）', () {
    Future<void> setWidth(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('320dp（最窄档）：标题仍有位置，且**不比改动前少**一个像素',
        (tester) async {
      // 顶栏那一行的算术（`components/appbar.dart:176-201`，实测值）：
      //   320 = 8 + 返回 48 + 24 + 标题 + 4×48 + 8  →  标题 = 40dp
      // 合并档位按钮**没有减少**这个宽度：改动前图集页的 action 也是 4 个
      // （刷新 / 资源库显示设置 / 排序 / 搜索），新按钮只是替掉了其中"设置"那一个。
      // 反过来说，**第 5 个 action 会让标题变成 0** —— 这条断言就是那个守卫。
      await setWidth(tester, 320);
      await pushPage(tester, albumOnly: true, title: '图集');

      final titleWidth = tester.getSize(appBarTitle('图集')).width;
      expect(
        titleWidth,
        greaterThanOrEqualTo(40),
        reason: '工具栏 action 每多一个就吃掉 48dp；多到第 5 个时标题宽度会归零',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('360dp（最常见机型宽度）：切到插画后标题「插画」完整显示',
        (tester) async {
      // 360 = 8 + 48 + 24 + 标题 + 192 + 8 → 标题 = 80dp；
      // 实测「插画」两个汉字的固有宽度 44dp，所以这里必须完整显示、不被省略。
      await setWidth(tester, 360);
      await pushPage(tester, albumOnly: true, title: '图集');

      await tester.tap(find.byKey(illustViewSwitcherFabKey));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(illustViewOptionKey(IllustLibraryView.illust)));
      await tester.pumpAndSettle();

      final paragraph =
          tester.renderObject<RenderParagraph>(appBarTitle('插画'));
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: '标题被省略号截断 = 用户看不出当前是哪个视图',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
